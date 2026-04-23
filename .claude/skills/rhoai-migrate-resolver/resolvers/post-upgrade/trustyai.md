# Resolver — TrustyAI (post-upgrade)

*Covers migration guide §4.6 — citation only; user-facing label is `[trustyai]`.*

Four sub-steps, run in order. Do not skip ahead — each one assumes the previous one is clean.

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

If you have `GuardrailsOrchestrator` CRs, verify each one came back Ready and has its `otelExporter` config intact:

```
oc get guardrailsorchestrator -A
oc get guardrailsorchestrator -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)  otel=\(.spec.otelExporter // "none")"'
```

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

Use the helper if available:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  bash /opt/rhai-upgrade-helpers/trustyai/restore_metrics.sh --namespace <ns>
```

If the helper is not present in your image, walk the migration guide's "TrustyAI - After upgrade - Restore data" section by hand — it covers ~40 steps of port-forwarding + curl POST per metric, and is too long to mirror here. Do not improvise a different approach: TrustyAI metrics have internal consistency constraints that fail silently if uploaded in the wrong order.

## GPU deployment deadlock

**Symptom:** a new GPU-backed InferenceService pod sits `Pending` indefinitely while the old pod stays Running. Happens specifically when multiple GPU ISVCs share a namespace that also runs a TrustyAI service.

**Diagnose:**

```
oc get pods -A | grep predictor
# Look for one namespace with a mix of Running and 0/2 Pending predictor pods

oc exec -n rhai-migration rhai-cli-0 -- bash -c '
  cd /opt/rhai-upgrade-helpers/trustyai && \
  ./break-gpu-deadlock.sh --namespace <namespace> --check
'
# Output is either "No deadlocks detected" or "DEADLOCK: <predictor-list>"
```

**Fix** (destructive — deletes the older pod so the scheduler can place the new one):

```
oc exec -n rhai-migration rhai-cli-0 -- bash -c '
  cd /opt/rhai-upgrade-helpers/trustyai && \
  ./break-gpu-deadlock.sh --namespace <namespace> --fix
'
```

The script waits for the new pod to become Running before returning. If it fails, do not retry blindly — `oc describe pod` on the still-pending pod and check GPU allocatable on the node (`oc describe node <node>`).

## Verify (all sub-steps)

```
# Operator healthy
oc get deployment -n redhat-ods-applications trustyai-service-operator-controller-manager

# All TrustyAIServices Ready
oc get trustyaiservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase'

# No deadlocks remain (run --check per GPU namespace)
```
