# Resolver — Model Serving (post-upgrade)

*Covers migration guide §4.9 — citation only; user-facing label is `[model-serving]`.*

Restore the `inferenceservice-config` ConfigMap management annotation, verify the 3.x controllers are running, and troubleshoot any leftover 2.x operators / unconverted workloads.

## Why

During the pre-upgrade ConfigMap step (guide §2.10.8), `inferenceservice-config` is annotated with `opendatahub.io/managed=false` so manual edits survive the upgrade. Post-upgrade, it needs to be flipped back to `managed=true` so the 3.x operator owns it again. Leaving it unmanaged silently breaks future config changes.

Unconverted ISVCs return **HTTP 503** after the upgrade (architectural-changes.md § *Model Serving Migration*: "Models left unconverted will return HTTP 503 errors"). You can still convert them post-upgrade — the pre-upgrade path is just less disruptive.

## Finalize the inferenceservice-config ConfigMap

If you customized `inferenceservice-config` yourself, skip this — otherwise restore management:

```
# 3.5: the after-upgrade helper scripts are gone — use the rhai-cli migrate action
# (auto-detects the post-upgrade phase; runs cluster-wide)
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
  --migration modelserving.managed-isvc-config --target-version 3.5.0
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

# All ISVCs — every row should show Standard + True
# NOTE: 3.5 renamed the RawDeployment deployment mode to Standard. Services that showed
# DEPLOYMENT_MODE=RawDeployment before the upgrade now report Standard — same mode, new label.
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

### Converted ModelMesh model (PVC-backed OVMS) won't become Ready

**Symptom:** the ISVC *was* converted (shows `Standard`/RawDeployment, `multiModel=false`, container renamed `kserve-container`), but the predictor never reaches Ready — it crash-loops or stays `0/1`. This is a **different** failure mode from the 503 "not converted" cases above: the metadata migrated, the model didn't start.

**Cause (gap report "Gap 1"):** `modelserving.modelmesh-to-raw` migrates the ISVC/runtime metadata but does **not** rewrite three things for a PVC-backed OVMS model, despite the guide implying storage is handled automatically:

1. **Storage** — ModelMesh `storage: {key, path}` (`pvc` type) is left in place; the KServe pod-mutator webhook rejects it: `storage type [pvc] is not supported, must be one of [s3, hdfs, webhdfs]`.
2. **OVMS launch args** — the runtime keeps multi-model args (`--config_path=/models/model_config_list.json`) → `Configuration file is invalid` crash-loop. KServe Standard serves one model from `/mnt/models`.
3. **Readiness probe / port** — the converted runtime declares no container port, so KServe defaults the probe to `tcpSocket:8080`, but OVMS serves REST on **8888** → pod runs but never passes readiness (`0/1`).

**Fix (example — ISVC `my-modelmesh-isvc` in `ml-project-c`, runtime `ovms-mm`, PVC `model-store`, model path `mobilenet`; resolve the PVC name from the `storage-config` secret's key). Adjust names for your model:**

```
# 1. PVC storage → storageUri
oc patch isvc my-modelmesh-isvc -n ml-project-c --type=merge \
  -p '{"spec":{"predictor":{"model":{"storageUri":"pvc://model-store/mobilenet","storage":null}}}}'

# 2. OVMS multi-model args → single-model
oc patch servingruntime ovms-mm -n ml-project-c --type=json -p '[{"op":"replace","path":"/spec/containers/0/args","value":[
  "--model_name=my-modelmesh-isvc","--model_path=/mnt/models","--port=8001","--rest_port=8888",
  "--file_system_poll_wait_seconds=0","--grpc_bind_address=0.0.0.0","--rest_bind_address=0.0.0.0"]}]'

# 3. Declare container port + readiness probe on the OVMS REST port
oc patch servingruntime ovms-mm -n ml-project-c --type=json -p '[
  {"op":"add","path":"/spec/containers/0/ports","value":[{"containerPort":8888,"protocol":"TCP"}]},
  {"op":"add","path":"/spec/containers/0/readinessProbe","value":{"tcpSocket":{"port":8888},"periodSeconds":10,"failureThreshold":3,"timeoutSeconds":5}}]'

oc rollout restart deployment my-modelmesh-isvc-predictor -n ml-project-c
```

This is best handled **pre-upgrade** while ModelMesh is still active (see the pre-upgrade [../kserve.md](../kserve.md) ModelMesh conversion coverage), but the same three patches work post-upgrade on a model that came across down. See KB [7134025](https://access.redhat.com/articles/7134025).

### Legacy Serverless ISVC stuck in Terminating (finalizer deadlock)

**Symptom:** an old Serverless-mode `InferenceService` won't delete — `oc delete isvc <name>` hangs, the object keeps showing a `deletionTimestamp` with finalizers still set, and the KServe controller logs show it failing to reach Knative/Istio APIs ("the delete command seems to be looking for serverless and service mesh").

**Cause:** the ISVC was left undeleted while Serverless / Service Mesh were removed, so its finalizer can't garbage-collect the Knative `Service` / Istio `VirtualService` it owns — the API groups are gone and the finalizer never clears. This is the ordering trap from the pre-upgrade sequence; it surfaces post-upgrade when someone tries to clean up a leftover ISVC.

**Resolution:** full diagnosis + both recovery paths (reinstate the operators and let the finalizer run, or force-clear the finalizer and recreate as RawDeployment) are in [../kserve.md](../kserve.md) § *Recover a stuck (Terminating) InferenceService — finalizer deadlock*. Post-upgrade the operators are usually already uninstalled, so the fallback (force-clear finalizer → recreate from backup) is typically the applicable path.

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

### Inference 503s from a NetworkPolicy that pins ingress to a specific router shard

**Symptom:** ISVC pods Running, ISVC `Ready=True`, but `curl https://<isvc-route>/v1/models` from outside the cluster returns HTTP 503.

**Cause:** in tightly-controlled environments, namespaces hosting models often have a NetworkPolicy (commonly named `internal-1`) that allows ingress only from a specific router shard pod selector — for example, `internal-router-shard`. RHOAI 3.x creates ISVC routes against the **default** router (and the data-science-gateway's HTTPRoute attaches there), so traffic from the default router pods gets dropped by the NetworkPolicy and the user sees a 503.

This is a common post-upgrade finding on clusters with namespace-scoped router-shard isolation; it can affect any number of model-hosting namespaces. Diagnose by listing NetworkPolicies in any 503-affected namespace and inspecting the `from` selector.

**Fix:** broaden the `from` selector to match the `openshift-ingress` namespace (which contains both the default router and the data-science-gateway), instead of pinning to a specific router pod label:

```
NS=<isvc-namespace>
oc patch networkpolicy internal-1 -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/spec/ingress/0/from/0","value":{"namespaceSelector":{"matchLabels":{"name":"openshift-ingress"}}}}]'
```

(Adjust `/spec/ingress/0/from/0` if your NetworkPolicy structure is different — `oc get networkpolicy internal-1 -n "$NS" -o yaml` first.)

If you have many namespaces with the same NetworkPolicy:

```
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
