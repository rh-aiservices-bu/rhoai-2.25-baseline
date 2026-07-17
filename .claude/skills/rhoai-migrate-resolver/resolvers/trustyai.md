# Resolver — TrustyAI + Guardrails

**rhai-cli signal:** `component / trustyai / *`, `workload / guardrails / *`.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc exec` helper script / `oc port-forward` / `oc cp` yourself unless the user explicitly said
> "run it" for THIS resolver. Read-only `oc get`/`describe` are fine. Work one step at a time —
> after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<NAMESPACE>` | a namespace that has a TrustyAIService to back up | `oc get trustyaiservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STORAGE:.spec.storage.format'` |

## DO THIS

1. **Is TrustyAI even managed?** Skip everything below if it was never enabled.

   ```sh
   oc get dsc -o jsonpath='{.items[0].spec.components.trustyai.managementState}'; echo
   ```

   → if `Managed`: continue to Step 2.
   → if `Removed` or empty: skip — no data to back up.

2. **Prepare for backup.** Create the backup dir inside the rhai-cli pod's PVC, then list the TrustyAIServices so you know what to back up.

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- mkdir -p /tmp/rhoai-upgrade-backup/trustyai

   oc get trustyaiservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STORAGE:.spec.storage.format'
   ```

3. **Back up metrics (per §2.5.2 — no helper script).** There is **no** `backup-metrics.sh` helper shipped with rhai-cli. Metrics are captured per-namespace with a manual port-forward + curl flow, exactly as written in guide §2.5.2. For each namespace that has a TrustyAIService:

   ```sh
   export NS=<NAMESPACE>
   export TAS_NAME=$(oc get trustyaiservice -n "$NS" -o jsonpath='{.items[0].metadata.name}')
   export SVC_PORT=$(oc get svc -n "$NS" "$TAS_NAME" -o jsonpath='{.spec.ports[?(@.name=="http")].port}')

   # If $SVC_PORT is empty, pick the http port manually from:
   #   oc get svc -n "$NS" "$TAS_NAME" -o jsonpath='{range .spec.ports[*]}{.name}:{.port}{"\n"}{end}'

   oc port-forward -n "$NS" "svc/$TAS_NAME" 8080:${SVC_PORT} &
   export PF_PID=$!; sleep 3

   curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
     "http://localhost:8080/metrics/all/requests" \
     -o "${BACKUP_DIR}/trustyai-metrics-${NS}-$(date +%Y%m%d-%H%M%S).json"

   kill $PF_PID 2>/dev/null
   ```

   → Verify the capture: `jq empty ${BACKUP_DIR}/trustyai-metrics-${NS}-*.json && echo OK` should print `OK`.

4. **Back up data storage (per §2.5.3 — `backup-data.sh`).** The helper script's name is `backup-data.sh` (hyphen). It auto-detects PVC vs DATABASE-backed services per TrustyAIService.

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- bash -c '
     cd /opt/rhai-upgrade-helpers/trustyai
     ./backup-data.sh --namespace <NAMESPACE>
   '
   ```

   → Result for **PVC**-backed: `/tmp/rhoai-upgrade-backup/trustyai/trustyai-data-<namespace>-<timestamp>/data/*.csv`
   → Result for **DATABASE**-backed: `/tmp/rhoai-upgrade-backup/trustyai/trustyai-db-<namespace>-<timestamp>/dump.sql`
   → The `cannot use rsync: rsync not available in container` warning the guide describes (§2.5.3) is expected — `oc rsync` falls back to `tar`. Backup completes successfully regardless.

5. **Guardrails — back up OpenTelemetry exporter config.** If you have `GuardrailsOrchestrator` CRs with `spec.otelExporter` set (traces/metrics going to an external OTLP endpoint), capture the block so you can restore it post-upgrade.

   ```sh
   oc get guardrailsorchestrator -A -o json \
     | jq -r '.items[] | select(.spec.otelExporter != null) | {ns: .metadata.namespace, name: .metadata.name, otelExporter: .spec.otelExporter}' \
     > trustyai-guardrails-otel-backup-$(date +%Y%m%d%H%M).json
   ```

6. **Copy backups to your workstation.**

   ```sh
   oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/trustyai ./trustyai-backup
   ```

## Verify (read-only)

```sh
# Inside the pod, list what was backed up
oc exec -n rhai-migration rhai-cli-0 -- ls -la /tmp/rhoai-upgrade-backup/trustyai
```

→ Expected: one `trustyai-data-<namespace>-<timestamp>/` or `trustyai-db-<namespace>-<timestamp>/` directory per TrustyAIService namespace you backed up.

## Why (reference)

TrustyAI's storage schema changed between 2.x and 3.x. Without a pre-upgrade backup, historical bias-detection metrics and training data can become unreadable after the migration. GuardrailsOrchestrator's `otelExporter` config survives, but must be captured before the schema migration in case you need to restore manually.

No architectural change driver for TrustyAI itself — this is a data-safety step from migration guide §2.5.

## Notes & edge cases (reference)

- TrustyAI backups go on **your** timeline — do them a few days before the upgrade, then repeat just before if data is still accumulating.
- GPU-deployed guardrails have a known deadlock issue in 3.x (migration guide §4.6.4) — if you use GPU guardrails, open a support case before the migration so Red Hat can advise on sequencing.

<!--
maintainer history — IGNORE when running the resolver. Not for the user.
- Earlier revisions of this resolver invoked `backup_metrics.sh` for metrics; that command does
  not exist. The CORRECT path (DO THIS Step 3) is the manual port-forward + curl flow per §2.5.2.
- Earlier revisions called the data-storage helper `backup_storage.sh`; that path does not exist.
  The CORRECT helper (DO THIS Step 4) is `backup-data.sh` (hyphen).
-->
