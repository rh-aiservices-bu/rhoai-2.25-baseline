# Resolver — Model Serving (post-upgrade)

*Covers migration guide §4.9 — citation only; user-facing label is `[model-serving]`.*

Restore the `inferenceservice-config` ConfigMap management annotation, verify the 3.x controllers are running, and troubleshoot any leftover 2.x operators / unconverted workloads.

## Why

During the pre-upgrade ConfigMap step (guide §2.8.8), `inferenceservice-config` is annotated with `opendatahub.io/managed=false` so manual edits survive the upgrade. Post-upgrade, it needs to be flipped back to `managed=true` so the 3.x operator owns it again. Leaving it unmanaged silently breaks future config changes.

Unconverted ISVCs return **HTTP 503** after the upgrade (architectural-changes.md § *Model Serving Migration*: "Models left unconverted will return HTTP 503 errors"). You can still convert them post-upgrade — the pre-upgrade path is just less disruptive.

## Finalize the inferenceservice-config ConfigMap

If you customized `inferenceservice-config` yourself, skip this — otherwise restore management:

```
# Use the helper in the rhai-cli container
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-upgrade-helpers/model-serving/after-upgrade/managed-inferenceservice-config.sh \
  -n redhat-ods-applications
```

Or by hand:

```
oc annotate configmap inferenceservice-config -n redhat-ods-applications \
  opendatahub.io/managed=true --overwrite

# Restart KServe controller to pick up the new annotation
oc rollout restart deployment/kserve-controller-manager -n redhat-ods-applications
```

### Verify no ISVC was redeployed

A redeploy would show multiple ReplicaSets per ISVC with some at 0 replicas:

```
for ns in $(oc get isvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get replicasets -n "$ns" -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp,REPLICAS:.status.replicas
done
```

Each ISVC should have exactly one active ReplicaSet.

## Verify 3.x controllers

```
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

## Troubleshooting

### Serverless ISVC not converted before upgrade

**Symptom:** ISVC shows `READY=True` but all inference calls return **HTTP 503**.

**Resolution:** Convert post-upgrade. Because the KServe admission webhook rejects in-place `deploymentMode` annotation changes, use the backup-delete-recreate procedure from [../kserve.md](../kserve.md) § *Convert Serverless InferenceServices to RawDeployment*. Or follow the KB: [Converting ModelMesh and Serverless InferenceServices to RawDeployment (Standard) Mode](https://access.redhat.com/articles/7134025).

### ModelMesh ISVC not converted before upgrade

**Symptom:** ISVC appears healthy but requests fail with **HTTP 503** and an "Application Not Available" page.

**Resolution:** Same KB article above. Must be recreated against a single-model ServingRuntime (`spec.multiModel: false`).

### OpenShift Serverless operator not removed

**Symptom:** `KnativeServing` still Ready, idle pods in `knative-serving`.

**Impact:** None for ISVCs (RawDeployment uses Deployment, not Knative). Only wastes resources.

**Resolution:** Only uninstall if nothing else on the cluster uses Serverless:

```
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

1. If you have `LLMInferenceService` resources, install RHCL first (see [../llm-isvc.md](../llm-isvc.md)). Then uninstall standalone Authorino:
   ```
   CSV=$(oc get subscription authorino-operator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null)
   oc delete subscription authorino-operator -n openshift-operators --ignore-not-found
   [[ -n "$CSV" ]] && oc delete csv "$CSV" -n openshift-operators --ignore-not-found
   ```
2. If no LLMInferenceService exists, the operator is harmless but wasted — same uninstall commands apply when convenient.

### Service Mesh v2 operator not removed

**Symptom:** OSSM v2 resources remain; Gateway API resources don't function correctly.

**Impact:**
- **LLMInferenceService:** **Critical conflict** — cannot be used.
- **Dashboard:** Won't work correctly.
- **Gateway API:** Cluster Ingress Operator fails to install OSSM v3 components while v2 is present.

**Resolution:** Same sequence as the pre-upgrade resolver in [../kserve.md](../kserve.md) § *Uninstall Service Mesh v2*. **First** confirm no non-RHOAI workload depends on SM v2, or migrate those to v3 via the OSSM docs: [Migrating from Service Mesh 2 to Service Mesh 3](https://docs.redhat.com/en/documentation/red_hat_openshift_service_mesh/3.1/html/migrating_from_service_mesh_2_to_service_mesh_3/).
