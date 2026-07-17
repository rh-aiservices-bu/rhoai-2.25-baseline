# Resolver — Model Serving (post-upgrade)

*Covers migration guide §4.9 — citation only; user-facing label is `[model-serving]`.*

**rhai-cli signal:** `post-upgrade-validate.sh` emits `[model-serving]` (FAIL or TODO). Restore the `inferenceservice-config` ConfigMap management annotation, verify the 3.x controllers are running, and troubleshoot any leftover 2.x operators / unconverted workloads.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / helper script yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## Fill in these first

`redhat-ods-applications`, `rhai-migration`, and `rhai-cli-0` are real constants — leave them literal. Only these are fill-ins:

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<ISVC_NAMESPACE>` | namespace hosting a 503-affected model / the NetworkPolicy `internal-1` | `oc get isvc -A` |
| `<ISVC_ROUTE>` | external route/host of the model endpoint you're curling | `oc get route -n <ISVC_NAMESPACE>` |

## DO THIS

### Step 1 — Finalize the inferenceservice-config ConfigMap (TODO)

Post-upgrade this ConfigMap must be flipped back to `managed=true` so the 3.x operator owns it again.

→ if you customized `inferenceservice-config` yourself: SKIP this step. Otherwise restore management.

Use the helper in the rhai-cli container:

```sh
# Use the helper in the rhai-cli container
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-upgrade-helpers/model-serving/after-upgrade/managed-inferenceservice-config.sh \
  -n redhat-ods-applications
```

Or by hand:

```sh
oc annotate configmap inferenceservice-config -n redhat-ods-applications \
  opendatahub.io/managed=true --overwrite

# Restart KServe controller to pick up the new annotation
oc rollout restart deployment/kserve-controller-manager -n redhat-ods-applications
```

### Step 2 — Verify no ISVC was redeployed (read-only)

A redeploy would show multiple ReplicaSets per ISVC with some at 0 replicas:

```sh
for ns in $(oc get isvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get replicasets -n "$ns" -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,REPLICAS:.status.replicas
done
```

→ Expected: each ISVC has exactly one active ReplicaSet.

### Step 3 — Verify 3.x controllers (read-only)

```sh
# KServe controller
oc get pods -n redhat-ods-applications -l control-plane=kserve-controller-manager

# ODH Model Controller
oc get pods -n redhat-ods-applications -l control-plane=odh-model-controller

# All ISVCs — every row should show RawDeployment + True
oc get isvc -A -o json | jq -r '["NAMESPACE","NAME","DEPLOYMENT_MODE","READY"], (.items[] | [.metadata.namespace, .metadata.name, .status.deploymentMode, (.status.conditions[] | select(.type=="Ready") | .status)]) | @tsv' | column -t

# LLMInferenceServices (if any)
oc get llminferenceservices --all-namespaces
# READY column must show True and URL must be present
```

→ Expected: KServe controller and ODH Model Controller pods `Running`; every ISVC row shows `RawDeployment` + `True`; any LLMInferenceService shows `READY=True` with a populated URL.

## Troubleshooting (conditional fixes)

### Serverless ISVC not converted before upgrade

**Symptom:** ISVC shows `READY=True` but all inference calls return **HTTP 503**.

**Resolution:** Convert post-upgrade. Because the KServe admission webhook rejects in-place `deploymentMode` annotation changes, use the backup-delete-recreate procedure from [../kserve.md](../kserve.md) § *Convert Serverless InferenceServices to RawDeployment*. Or follow the KB: [Converting ModelMesh and Serverless InferenceServices to RawDeployment (Standard) Mode](https://access.redhat.com/articles/7134025).

### ModelMesh ISVC not converted before upgrade

**Symptom:** ISVC appears healthy but requests fail with **HTTP 503** and an "Application Not Available" page.

**Resolution:** Same KB article above. Must be recreated against a single-model ServingRuntime (`spec.multiModel: false`).

### Legacy Serverless ISVC stuck in Terminating (finalizer deadlock)

**Symptom:** an old Serverless-mode `InferenceService` won't delete — `oc delete isvc <name>` hangs, the object keeps showing a `deletionTimestamp` with finalizers still set, and the KServe controller logs show it failing to reach Knative/Istio APIs ("the delete command seems to be looking for serverless and service mesh").

**Cause:** the ISVC was left undeleted while Serverless / Service Mesh were removed, so its finalizer can't garbage-collect the Knative `Service` / Istio `VirtualService` it owns — the API groups are gone and the finalizer never clears. This is the ordering trap from the pre-upgrade sequence; it surfaces post-upgrade when someone tries to clean up a leftover ISVC.

**Resolution:** full diagnosis + both recovery paths (reinstate the operators and let the finalizer run, or force-clear the finalizer and recreate as RawDeployment) are in [../kserve.md](../kserve.md) § *Recover a stuck (Terminating) InferenceService — finalizer deadlock*. Post-upgrade the operators are usually already uninstalled, so the fallback (force-clear finalizer → recreate from backup) is typically the applicable path.

### OpenShift Serverless operator not removed

**Symptom:** `KnativeServing` still Ready, idle pods in `knative-serving`.

**Impact:** None for ISVCs (RawDeployment uses Deployment, not Knative). Only wastes resources.

**Resolution:** → only uninstall if nothing else on the cluster uses Serverless. ⚠️ Destructive — deletes the KnativeServing CR, the operator subscription/CSV, and the `knative-serving` namespace. Confirm no other workload depends on Serverless before running.

```sh
oc delete knativeserving knative-serving -n knative-serving --ignore-not-found

CSV=$(oc get subscription serverless-operator -n openshift-serverless -o jsonpath='{.status.installedCSV}' 2>/dev/null)
oc delete subscription serverless-operator -n openshift-serverless --ignore-not-found
[[ -n "$CSV" ]] && oc delete csv "$CSV" -n openshift-serverless --ignore-not-found

oc delete namespace knative-serving --ignore-not-found
```

### Standalone Authorino operator not removed

**Symptom:** Standalone Authorino still Ready in `openshift-operators`.

**Impact:**
- **ISVC (RawDeployment):** No impact — kube-rbac-proxy sidecar handles auth.
- **LLMInferenceService:** **Critical conflict.** LLM-d requires RHCL (which bundles its own Authorino). Standalone Authorino won't work.

**Resolution:**

→ if you have `LLMInferenceService` resources: install RHCL first (see [../llm-isvc.md](../llm-isvc.md)), THEN uninstall standalone Authorino with the commands below.
→ if no LLMInferenceService exists: the operator is harmless but wasted — same uninstall commands apply when convenient.

⚠️ Destructive — deletes the standalone Authorino subscription and CSV. If you have LLMInferenceServices, do NOT run this until RHCL is installed.

```sh
CSV=$(oc get subscription authorino-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null)
oc delete subscription authorino-operator -n openshift-operators --ignore-not-found
[[ -n "$CSV" ]] && oc delete csv "$CSV" -n openshift-operators --ignore-not-found
```

### Inference 503s from a NetworkPolicy that pins ingress to a specific router shard

**Symptom:** ISVC pods Running, ISVC `Ready=True`, but `curl https://<ISVC_ROUTE>/v1/models` from outside the cluster returns HTTP 503.

**Cause:** in tightly-controlled environments, namespaces hosting models often have a NetworkPolicy (commonly named `internal-1`) that allows ingress only from a specific router shard pod selector — for example, `internal-router-shard`. RHOAI 3.x creates ISVC routes against the **default** router (and the data-science-gateway's HTTPRoute attaches there), so traffic from the default router pods gets dropped by the NetworkPolicy and the user sees a 503.

Diagnose by listing NetworkPolicies in any 503-affected namespace and inspecting the `from` selector. Confirm the current structure first:

```sh
oc get networkpolicy internal-1 -n "$NS" -o yaml
```

**Fix:** broaden the `from` selector to match the `openshift-ingress` namespace (which contains both the default router and the data-science-gateway), instead of pinning to a specific router pod label:

```sh
NS=<ISVC_NAMESPACE>
oc patch networkpolicy internal-1 -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/spec/ingress/0/from/0","value":{"namespaceSelector":{"matchLabels":{"name":"openshift-ingress"}}}}]'
```

→ Adjust `/spec/ingress/0/from/0` if your NetworkPolicy structure is different (that's why you ran the `-o yaml` check above).

If you have many namespaces with the same NetworkPolicy:

```sh
for ns in $(oc get networkpolicy -A -o json | jq -r '.items[] | select(.metadata.name=="internal-1") | .metadata.namespace'); do
  echo "patching $ns"
  oc patch networkpolicy internal-1 -n "$ns" --type=json \
    -p='[{"op":"replace","path":"/spec/ingress/0/from/0","value":{"namespaceSelector":{"matchLabels":{"name":"openshift-ingress"}}}}]'
done
```

Verify by curling a previously-503'ing model endpoint.

### Service Mesh v2 operator not removed

**Symptom:** OSSM v2 resources remain; Gateway API resources don't function correctly.

**Impact:**
- **LLMInferenceService:** **Critical conflict** — cannot be used.
- **Dashboard:** Won't work correctly.
- **Gateway API:** Cluster Ingress Operator fails to install OSSM v3 components while v2 is present.

**Resolution:** Same sequence as the pre-upgrade resolver in [../kserve.md](../kserve.md) § *Uninstall Service Mesh v2*. **First** confirm no non-RHOAI workload depends on SM v2, or migrate those to v3 via the OSSM docs: [Migrating from Service Mesh 2 to Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/migrating_from_service_mesh_2_to_service_mesh_3/).

## Why (reference)

During the pre-upgrade ConfigMap step (guide §2.8.8), `inferenceservice-config` is annotated with `opendatahub.io/managed=false` so manual edits survive the upgrade. Post-upgrade, it needs to be flipped back to `managed=true` so the 3.x operator owns it again. Leaving it unmanaged silently breaks future config changes.

Unconverted ISVCs return **HTTP 503** after the upgrade (architectural-changes.md § *Model Serving Migration*: "Models left unconverted will return HTTP 503 errors"). You can still convert them post-upgrade — the pre-upgrade path is just less disruptive.

## Notes & edge cases (reference)

- The router-shard NetworkPolicy 503 (`internal-1`) is a common post-upgrade finding on clusters with namespace-scoped router-shard isolation; it can affect any number of model-hosting namespaces — the per-namespace loop above handles the bulk case.
