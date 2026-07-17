# Resolver — TrustyAI (post-upgrade)

**rhai-cli signal:** user-facing label is `[trustyai]`. Covers migration guide §4.6 (citation only). Four sub-steps, run in order — each one assumes the previous one is clean. Do not skip ahead.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / helper script yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<NAMESPACE>` | a namespace running a TrustyAIService / GuardrailsOrchestrator / GPU ISVC | `oc get trustyaiservice -A` / `oc get guardrailsorchestrator -A` |
| `<GORCH_NAME>` | a GuardrailsOrchestrator name | `oc get guardrailsorchestrator -A` |
| `<NODE>` | a GPU node to inspect | `oc get nodes` |
| `<LLM_SERVICE>` | the LLM service host (ConfigMap template only) | `oc get svc -n <NAMESPACE>` |
| `<DETECTOR_SERVICE>` | the detector service host (ConfigMap template only) | `oc get svc -n <NAMESPACE>` |

## DO THIS

### Sub-step 1 — Check backups

Figure out whether any TrustyAIService lost data during the schema upgrade.

1. Confirm the operator is healthy.
   ```sh
   oc wait --for=condition=Available deployment/trustyai-service-operator-controller-manager \
     -n redhat-ods-applications --timeout=120s
   ```
   → Expected: `deployment.apps/trustyai-service-operator-controller-manager condition met`.

2. List namespaces that have backups (inside the rhai-cli pod).
   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- bash -c '
     export BACKUP_DIR=/tmp/rhoai-upgrade-backup/trustyai
     ls ${BACKUP_DIR}/trustyai-metrics-*.json 2>/dev/null \
       | sed "s|.*/trustyai-metrics-||;s|-[0-9]\{8\}-[0-9]\{6\}\.json||" \
       | sort -u
   '
   ```
   → if nothing comes back: no data was backed up — skip to Sub-step 2 (Guardrails). Otherwise continue with Step 3 for each namespace listed.

3. For each namespace with a backup, fetch the current live metric count.
   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- bash -c '
     export NS=<NAMESPACE>
     export TAS_NAME=$(oc get trustyaiservice -n "$NS" -o jsonpath="{.items[0].metadata.name}")
     export SVC_PORT=$(oc get svc -n "$NS" "$TAS_NAME" -o jsonpath="{.spec.ports[?(@.name==\"http\")].port}")

     # Port-forward + fetch current metric count
     oc port-forward -n "$NS" "svc/$TAS_NAME" 8080:$SVC_PORT &
     sleep 3
     curl -sk -H "Authorization: Bearer $(oc whoami -t)" \
       http://localhost:8080/metrics/all/requests | jq ".requests | length"
     kill %1 2>/dev/null
   '
   ```
   → Compare the live count to the backup count. if live < backup: that namespace lost data — run Sub-step 3 (Restore lost data). if live >= backup: no loss, continue.

### Sub-step 2 — Guardrails

Migration guide §4.6.2 prescribes a five-step procedure for every GuardrailsOrchestrator. The official helpers do most of the work — use them before any hand-patching.

1. List and identify.
   ```sh
   oc get guardrailsorchestrator -A
   ```
   → if `No resources found`: skip this entire sub-step, go to Sub-step 3.

2. ⚠️ `--fix` edits the deployment and waits for rollout. Confirm before running. For each `(namespace, orchestrator)` pair, patch deployments missing the ReadinessProbe.
   ```sh
   export NS=<NAMESPACE>
   export GORCH_NAME=<GORCH_NAME>

   cd /opt/rhai-upgrade-helpers/trustyai

   ./patch-guardrails-deployment.sh --gorch-name $GORCH_NAME --namespace $NS --check
   ```
   → if output is `OK readinessProbe already set`: next namespace. if output is `NEEDS PATCH`:
   ```sh
   ./patch-guardrails-deployment.sh --gorch-name $GORCH_NAME --namespace $NS --fix
   ```

3. Check the otelExporter schema. `--check` first, then `--fix` rewrites keys under `spec.otelExporter` to the 3.x shape.
   ```sh
   ./migrate-gorch-otel-exporter.sh --namespace $NS --check
   ```
   → if output is `already on new otelExporter schema`: skip the fix. Otherwise ⚠️ (rewrites the CR):
   ```sh
   ./migrate-gorch-otel-exporter.sh --namespace $NS --fix
   ```

4. Verify each orchestrator via `/info`.
   ```sh
   export GORCH_NAME=<GORCH_NAME>
   export GORCH_ROUTE_HEALTH=$(oc get routes -n $NS "${GORCH_NAME}-health" -o jsonpath='{.spec.host}')
   curl -sSk "https://${GORCH_ROUTE_HEALTH}/info" -H "Authorization: Bearer $(oc whoami -t)" | jq .
   ```
   → Expected: all listed services report `status: HEALTHY`.
   → if an orchestrator is stuck / unhealthy: see Notes → "Gotcha 1" (missing ConfigMap) and "Gotcha 2" (scrubbed otelExporter).

### Sub-step 3 — Restore lost data

Only run this if Sub-step 1 reported DATA LOSS for a namespace and you have a corresponding `trustyai-metrics-<NS>-*.json` backup file.

The migration guide's TrustyAI "Restore data" section provides a long sequence: (1) export the namespace and locate its TrustyAIService, (2) port-forward to the service, (3) replay each backed-up metric via the `POST /metrics/*` endpoints.

⚠️ Writes metrics back into the live TrustyAIService. Use the helper if available — it requires **both** `--namespace` and `--file` (missing `-f` produces `[ERROR] Backup file is required. Use -f flag.`):
```sh
NS=<NAMESPACE>
BACKUP_FILE=$(oc exec -n rhai-migration rhai-cli-0 -- bash -c \
  "ls /tmp/rhoai-upgrade-backup/trustyai/trustyai-metrics-${NS}-*.json 2>/dev/null | tail -1")

oc exec -n rhai-migration rhai-cli-0 -- \
  bash /opt/rhai-upgrade-helpers/trustyai/restore-metrics.sh \
  --namespace "$NS" --file "$BACKUP_FILE"
```
The script also supports `-d/--dry-run` (preview without applying) and `-s/--skip-existing` (idempotent re-run, checks by model ID + metric type).

→ if the helper is not present in your image: walk the migration guide's "TrustyAI - After upgrade - Restore data" section by hand — ~40 steps of port-forwarding + curl POST per metric, too long to mirror here. Do not improvise a different approach: TrustyAI metrics have internal consistency constraints that fail silently if uploaded in the wrong order.

### Sub-step 4 — GPU deployment deadlock

**Symptom:** a new GPU-backed InferenceService pod sits `Pending` indefinitely while the old pod stays Running. Happens specifically when multiple GPU ISVCs share a namespace that also runs a TrustyAI service.

1. Diagnose.
   ```sh
   oc get pods -A | grep predictor
   ```
   → Look for one namespace with a mix of Running and `0/2` Pending predictor pods. Then check with the helper:
   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- bash -c '
     cd /opt/rhai-upgrade-helpers/trustyai && \
     ./break-gpu-deadlock.sh --namespace <NAMESPACE> --check
   '
   ```
   → Expected: either `No deadlocks detected` or `DEADLOCK: <predictor-list>`.

2. ⚠️ Destructive — deletes the older pod so the scheduler can place the new one. Confirm before running. Fix:
   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- bash -c '
     cd /opt/rhai-upgrade-helpers/trustyai && \
     ./break-gpu-deadlock.sh --namespace <NAMESPACE> --fix
   '
   ```
   The script waits for the new pod to become Running before returning.
   → if it fails: do not retry blindly — `oc describe pod` on the still-pending pod and check GPU allocatable on the node (`oc describe node <NODE>`).

## Verify (read-only)

```sh
# Operator healthy
oc get deployment -n redhat-ods-applications trustyai-service-operator-controller-manager

# All TrustyAIServices Ready
oc get trustyaiservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase'
```
→ Expected: operator deployment shows its replicas available; every TrustyAIService `STATUS` phase is Ready. Also re-run `break-gpu-deadlock.sh --check` per GPU namespace and confirm no deadlocks remain.

## Why (reference)

Covers migration guide §4.6. TrustyAIServices back their metrics with storage whose schema changed at 3.x, so data can be lost and must be restored from the pre-upgrade backup. GuardrailsOrchestrators need deployment/schema patches to reconcile on 3.x. And GPU ISVCs sharing a namespace with a TrustyAI service can deadlock the scheduler during rollout.

## Notes & edge cases (reference)

The gotchas below are operational issues observed on real clusters — **not** in migration guide §4.6.2. Keep them as fallback after the official helpers (Sub-step 2) have run.

### Gotcha 1 — missing orchestratorConfig ConfigMap

A GuardrailsOrchestrator whose `spec.orchestratorConfig: <name>` points at a **ConfigMap that doesn't exist in the same namespace** stays silently stuck in `phase=Progressing, reason=ReconcileInit` with **zero pods** and **no operator log entries** — the controller is running, but it doesn't surface the missing dependency. Verify:

```sh
NS=<NAMESPACE>; CM=$(oc get guardrailsorchestrator -n "$NS" -o jsonpath='{.items[0].spec.orchestratorConfig}')
oc get cm "$CM" -n "$NS" || echo "ConfigMap $CM is MISSING — this is why the CR won't reconcile"
```

The ConfigMap must contain a `config.yaml` key. Minimum viable content (the orchestrator Rust binary requires at least one detector entry or it exits with `Error: no detectors configured`):

```yaml
openai:
  service:
    hostname: <LLM_SERVICE>.<NAMESPACE>.svc
    port: 8080
detectors:
  placeholder:
    type: text_contents
    service:
      hostname: <DETECTOR_SERVICE>.<NAMESPACE>.svc
      port: 8080
    chunker_id: whole_doc_chunker
    default_threshold: 0.5
```

Notes:
- `chat_generation` is deprecated in 3.x — use `openai` instead.
- After creating the ConfigMap, force a reconcile by bumping any annotation on the CR: `oc annotate guardrailsorchestrator <GORCH_NAME> -n <NAMESPACE> reconcile-trigger="$(date +%s)" --overwrite`

### Gotcha 2 — scrubbed otelExporter fields

The 3.x CRD renamed the 2.x otelExporter fields. If you see warnings like `unknown field "spec.otelExporter.otlpEndpoint"` when patching, the 2.x → 3.x mapping is:

| 2.x field | 3.x field |
| --- | --- |
| `otlpEndpoint` | `otlpMetricsEndpoint` and/or `otlpTracesEndpoint` (split per signal) |
| `otlpExport: "metrics,traces"` | `enableMetrics: true` + `enableTraces: true` |
| `protocol` | `otlpProtocol` |

Use `oc explain guardrailsorchestrator.spec.otelExporter` to confirm the current schema before patching.

If `otelExporter` was scrubbed during upgrade, restore it from the backup you captured in the pre-upgrade Guardrails step (⚠️ patches the live CR):

```sh
# Restore the otelExporter block from your pre-upgrade backup file
NS=<NAMESPACE>; NAME=<GORCH_NAME>
oc patch guardrailsorchestrator "$NAME" -n "$NS" --type=merge -p @trustyai-guardrails-otel-backup-*.json
```

<!--
maintainer history — IGNORE when running the resolver. Not for the user.
Earlier revisions of this resolver missed the official §4.6.2 Guardrails helpers
(patch-guardrails-deployment.sh / migrate-gorch-otel-exporter.sh) and hand-patched instead.
The CURRENT correct path — run the helpers first (Sub-step 2), fall back to the Gotcha 1/2
manual fixes only if an orchestrator is still stuck — now stands in DO THIS.
-->
