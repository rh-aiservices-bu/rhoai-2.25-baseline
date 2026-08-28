# Resolver — TrustyAI (post-upgrade)

*Covers migration guide §4.6 — citation only; user-facing label is `[trustyai]`.*

Four sub-steps, run in order. Do not skip ahead — each one assumes the previous one is clean.

> **Note on the `trustyai.*` migrate actions below.** The guardrails, otel-exporter, restore-metrics, and GPU-deadlock steps are now `rhai-cli migrate run --migration trustyai.<action> --target-version 3.5.0` actions (`patch-guardrails`, `migrate-gorch-otel-exporter`, `metrics`, `break-gpu-deadlock`). They operate **cluster-wide across all namespaces** — they replace the old per-namespace `*.sh` loops, so there is no `$NS` to set. Preview any of them with `--dry-run` before applying. Each may print a benign `WARNING: migration <name> has phase pre-upgrade but effective phase is post-upgrade` — ignore it.

## Check backups

Figure out whether any TrustyAIService lost data during the schema upgrade.

```
# Operator must be healthy
oc wait --for=condition=Available deployment/trustyai-service-operator-controller-manager \
  -n redhat-ods-applications --timeout=120s
# Expect: deployment.apps/trustyai-service-operator-controller-manager condition met

# Inside the rhai-cli pod, list namespaces that have backups
oc exec -n rhai-migration rhai-cli-0 -- bash -c '
  export BACKUP_DIR=/tmp/rhoai-upgrade-backup/trustyai
  ls ${BACKUP_DIR}/trustyai-metrics-*.json 2>/dev/null \
    | sed "s|.*/trustyai-metrics-||;s|-[0-9]\{8\}-[0-9]\{6\}\.json||" \
    | sort -u
'
```

If nothing comes back, no data was backed up → skip to the *Guardrails* section below. Otherwise, for each namespace with a backup, check whether the post-upgrade service still has all the metrics:

```
oc exec -n rhai-migration rhai-cli-0 -- bash -c '
  export NS=<namespace>
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

Compare the live count to the backup count — if live < backup, that namespace lost data → run the *Restore lost data* step below.

## Guardrails

Migration guide §4.6.2 prescribes a five-step procedure for every GuardrailsOrchestrator. The `trustyai.*` migrate actions do most of the work cluster-wide — earlier revisions of this resolver missed them.

### Step 1 — list and identify

```
oc get guardrailsorchestrator -A
```

If `No resources found`, skip this entire section.

### Step 2 — patch deployments missing the ReadinessProbe (`trustyai.patch-guardrails`)

Cluster-wide — run it once, no per-namespace loop. Preview, then apply:

```
# Preview — reports which GuardrailsOrchestrator deployments need the ReadinessProbe
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.patch-guardrails --target-version 3.5.0 --dry-run

# Apply — edits each deployment and waits for rollout
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.patch-guardrails --target-version 3.5.0
```

### Step 3 — migrate otelExporter schema (`trustyai.migrate-gorch-otel-exporter`)

Also cluster-wide. Preview, then apply:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.migrate-gorch-otel-exporter --target-version 3.5.0 --dry-run

oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.migrate-gorch-otel-exporter --target-version 3.5.0
```

The action rewrites keys under `spec.otelExporter` to the 3.x shape across every namespace. Use it before any hand-patching.

### Step 4 — verify each orchestrator via /info

```
export GORCH_NAME=<gorch-name>
export GORCH_ROUTE_HEALTH=$(oc get routes -n $NS "${GORCH_NAME}-health" -o jsonpath='{.spec.host}')
curl -sSk "https://${GORCH_ROUTE_HEALTH}/info" -H "Authorization: Bearer $(oc whoami -t)" | jq .
```

All listed services should report `status: HEALTHY`.

---

The sections below are operational gotchas observed on real clusters — not in migration guide §4.6.2. Keep them as fallback after the `trustyai.*` migrate actions have run.

### Gotcha 1 — missing orchestratorConfig ConfigMap

A GuardrailsOrchestrator whose `spec.orchestratorConfig: <name>` points at a **ConfigMap that doesn't exist in the same namespace** stays silently stuck in `phase=Progressing, reason=ReconcileInit` with **zero pods** and **no operator log entries** — the controller is running, but it doesn't surface the missing dependency. Verify:

```
NS=<ns>; CM=$(oc get guardrailsorchestrator -n "$NS" -o jsonpath='{.items[0].spec.orchestratorConfig}')
oc get cm "$CM" -n "$NS" || echo "ConfigMap $CM is MISSING — this is why the CR won't reconcile"
```

The ConfigMap must contain a `config.yaml` key. Minimum viable content (the orchestrator Rust binary requires at least one detector entry or it exits with `Error: no detectors configured`):

```yaml
openai:
  service:
    hostname: <llm-service>.<ns>.svc
    port: 8080
detectors:
  placeholder:
    type: text_contents
    service:
      hostname: <detector-service>.<ns>.svc
      port: 8080
    chunker_id: whole_doc_chunker
    default_threshold: 0.5
```

Notes:
- `chat_generation` is deprecated in 3.x — use `openai` instead.
- After creating the ConfigMap, force a reconcile by bumping any annotation on the CR: `oc annotate guardrailsorchestrator <name> -n <ns> reconcile-trigger="$(date +%s)" --overwrite`

### Gotcha 2 — scrubbed otelExporter fields

The 3.x CRD renamed the 2.x otelExporter fields. If you see warnings like `unknown field "spec.otelExporter.otlpEndpoint"` when patching, the 2.x → 3.x mapping is:

| 2.x field | 3.x field |
| --- | --- |
| `otlpEndpoint` | `otlpMetricsEndpoint` and/or `otlpTracesEndpoint` (split per signal) |
| `otlpExport: "metrics,traces"` | `enableMetrics: true` + `enableTraces: true` |
| `protocol` | `otlpProtocol` |

Use `oc explain guardrailsorchestrator.spec.otelExporter` to confirm the current schema before patching.

If `otelExporter` was scrubbed during upgrade, restore it from the backup you captured in the pre-upgrade Guardrails step:

```
# Restore the otelExporter block from your pre-upgrade backup file
NS=<ns>; NAME=<guardrails-orchestrator-name>
oc patch guardrailsorchestrator "$NAME" -n "$NS" --type=merge -p @trustyai-guardrails-otel-backup-*.json
```

## Restore lost data

Only runs if the *Check backups* step reported DATA LOSS for a namespace and you have a corresponding `trustyai-metrics-<NS>-*.json` backup file.

The migration guide's TrustyAI "Restore data" section provides a long sequence:

1. Export the namespace and locate its TrustyAIService
2. Port-forward to the service
3. Replay each backed-up metric via the `POST /metrics/*` endpoints

Use the `trustyai.metrics` action. It operates **cluster-wide** — it discovers the per-namespace `trustyai-metrics-*.json` backups captured by the pre-upgrade `trustyai.data` step and replays them into each TrustyAIService, so there is no `--namespace`/`--file` to set. Preview first with `--dry-run`, then apply:

```
# Preview — reports which namespaces/metrics would be restored
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.metrics --target-version 3.5.0 --dry-run

# Apply — idempotent; skips metrics that already exist (by model ID + metric type)
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.metrics --target-version 3.5.0
```

If the action reports no backups (or is unavailable in your image), walk the migration guide's "TrustyAI - After upgrade - Restore data" section by hand — it covers ~40 steps of port-forwarding + curl POST per metric, and is too long to mirror here. Do not improvise a different approach: TrustyAI metrics have internal consistency constraints that fail silently if uploaded in the wrong order.

## GPU deployment deadlock

**Symptom:** a new GPU-backed InferenceService pod sits `Pending` indefinitely while the old pod stays Running. Happens specifically when multiple GPU ISVCs share a namespace that also runs a TrustyAI service.

**Diagnose:**

```
oc get pods -A | grep predictor
# Look for one namespace with a mix of Running and 0/2 Pending predictor pods

# --dry-run scans all namespaces and reports deadlocks without deleting anything
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.break-gpu-deadlock --target-version 3.5.0 --dry-run
# Output is either "No deadlocks detected" or "DEADLOCK: <namespace>/<predictor-list>"
```

**Fix** (destructive — deletes the older pod so the scheduler can place the new one). Cluster-wide across all namespaces:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration trustyai.break-gpu-deadlock --target-version 3.5.0
```

The action waits for the new pod to become Running before returning. If it fails, do not retry blindly — `oc describe pod` on the still-pending pod and check GPU allocatable on the node (`oc describe node <node>`).

## Verify (all sub-steps)

```
# Operator healthy
oc get deployment -n redhat-ods-applications trustyai-service-operator-controller-manager

# All TrustyAIServices Ready
oc get trustyaiservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase'

# No deadlocks remain (run --check per GPU namespace)
```
