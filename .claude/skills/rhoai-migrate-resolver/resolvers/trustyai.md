# Resolver — TrustyAI + Guardrails

**rhai-cli signal:** `component / trustyai / *`, `workload / guardrails / *`.

## Why

TrustyAI's storage schema changed between 2.x and 3.x. Without a pre-upgrade backup, historical bias-detection metrics and training data can become unreadable after the migration. GuardrailsOrchestrator's `otelExporter` config survives, but must be captured before the schema migration in case you need to restore manually.

No architectural change driver for TrustyAI itself — this is a data-safety step from migration guide §2.7.

## Is TrustyAI even managed?

Skip this section if TrustyAI was never enabled:

```
oc get dsc -o jsonpath='{.items[0].spec.components.trustyai.managementState}'; echo
# Managed → continue. Removed or empty → skip; no data to back up.
```

## § Prepare for backup

Create the backup dir inside the rhai-cli pod's PVC — this is the `--output-dir` the backup actions below write to:

```
oc exec -n rhai-migration rhai-cli-0 -- mkdir -p /tmp/rhoai-upgrade-backup/trustyai
```

List the TrustyAIServices so you know what to back up (the actions run cluster-wide, but this tells you what to expect):

```
oc get trustyaiservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STORAGE:.spec.storage.format'
```

## § Back up metrics (§2.7 — `trustyai.metrics`)

The per-namespace port-forward + curl flow (and the `backup-metrics.sh` helper it replaced) are gone. Metrics backup is now the cluster-wide `trustyai.metrics` **prepare** action. `--output-dir` is **required** when running inside the rhai-cli pod — the container root filesystem is read-only, so writing anywhere else fails with `permission denied`. Point it at the pod's backup PVC:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate prepare \
  --migration trustyai.metrics \
  --target-version 3.5.0 \
  --output-dir /tmp/rhoai-upgrade-backup/trustyai
```

> The action operates **cluster-wide** (every namespace with a TrustyAIService) and may emit a benign `phase pre-upgrade but effective phase is post-upgrade` warning — ignore it.

**Verify from your workstation.** `jq` is no longer present in the container, so read the backup JSON out of the pod's PVC and validate it locally (§2.7):

```
# list what the action wrote
oc exec -n rhai-migration rhai-cli-0 -- ls -la /tmp/rhoai-upgrade-backup/trustyai

# validate each metrics JSON from the workstation
for f in $(oc exec -n rhai-migration rhai-cli-0 -- sh -c 'ls /tmp/rhoai-upgrade-backup/trustyai/*metrics*.json'); do
  oc exec -n rhai-migration rhai-cli-0 -- cat "$f" | jq empty && echo "OK: $f"
done
```

## § Back up data storage (§2.7 — `trustyai.data`)

`backup-data.sh` is gone; data-storage backup is the `trustyai.data` **prepare** action. It auto-detects PVC- vs DATABASE-backed services per TrustyAIService and runs **cluster-wide** (no `--namespace` loop). As with the metrics action, `--output-dir` is **required** inside the pod (read-only root fs → else `permission denied`):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate prepare \
  --migration trustyai.data \
  --target-version 3.5.0 \
  --output-dir /tmp/rhoai-upgrade-backup/trustyai
```

Results (under the `--output-dir` you passed):

- **PVC:** `/tmp/rhoai-upgrade-backup/trustyai/trustyai-data-<namespace>-<timestamp>/data/*.csv`
- **DATABASE:** `/tmp/rhoai-upgrade-backup/trustyai/trustyai-db-<namespace>-<timestamp>/dump.sql`

> A `cannot use rsync: rsync not available in container` warning may appear — expected; the copy falls back to `tar` and the backup completes regardless. The benign `phase pre-upgrade but effective phase is post-upgrade` warning may also appear — ignore it.

## § Guardrails — back up OpenTelemetry exporter config

If you have `GuardrailsOrchestrator` CRs with `spec.otelExporter` set (traces/metrics going to an external OTLP endpoint), capture the block so you can restore it post-upgrade:

```
oc get guardrailsorchestrator -A -o json \
  | jq -r '.items[] | select(.spec.otelExporter != null) | {ns: .metadata.namespace, name: .metadata.name, otelExporter: .spec.otelExporter}' \
  > trustyai-guardrails-otel-backup-$(date +%Y%m%d%H%M).json
```

## Copy backups to your workstation

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/trustyai ./trustyai-backup
```

## Verify

```
# Inside the pod, list what was backed up
oc exec -n rhai-migration rhai-cli-0 -- ls -la /tmp/rhoai-upgrade-backup/trustyai
```

## Callouts

- TrustyAI backups go on **your** timeline — do them a few days before the upgrade, then repeat just before if data is still accumulating.
- GPU-deployed guardrails have a known deadlock issue in 3.x (migration guide §4.6; the post-upgrade fix is the `trustyai.break-gpu-deadlock` action) — if you use GPU guardrails, open a support case before the migration so Red Hat can advise on sequencing.
