# Resolver — KServe / Model Serving

This is the largest migration section. It covers every `component / kserve`, `component / modelmeshserving`, `workload / kserve`, and `dependency / {servicemesh-operator-v2, serverless-operator, authorino-operator}` check from rhai-cli.

## Why

> The model serving architecture is evolving to support advanced LLM inference topologies through LLM-d. Neither KServe Serverless nor ModelMesh were designed for the routing and scaling patterns that distributed LLM inference requires. Additionally, KServe Serverless depends on Knative, which is incompatible with OpenShift Service Mesh 3 (embedded in OCP 4.19+).
>
> — architectural-changes.md § *Model Serving: Removal of ModelMesh and KServe Serverless*

> All model serving workloads must be converted to RawDeployment (Standard) mode before the migration. […] Models left unconverted will return HTTP 503 errors after the upgrade.
>
> — architectural-changes.md § *Model Serving Migration*

## The migration sequence matters

Per migration guide §2.10.3, in this order. Skipping ahead leaves the cluster in a half-migrated state where the RHOAI operator reconciler fights against workloads.

1. **Back up** the `inferenceservice-config` ConfigMap (§2.10.6)
2. **Convert** every Serverless `InferenceService` to RawDeployment via `modelserving.serverless-to-raw` — cluster-wide, non-interactive (§2.10.7.1)
3. **Convert** every ModelMesh `InferenceService` to RawDeployment via `modelserving.modelmesh-to-raw` — in-place in each namespace, including its multi-model `ServingRuntime` (§2.10.7.2)
4. **Verify** InferenceServices are healthy on the new mode (§2.10.7.3)
5. **Update** the `inferenceservice-config` ConfigMap with the hardware-profile ignorelist via `modelserving.hardwareprofiles-ignorelist` (§2.10.8)
6. Set `kserve.serving.managementState: Removed` on the DSC (§2.10.9)
7. Set `modelmeshserving.managementState: Removed` on the DSC
8. Set `serviceMesh.managementState: Removed` on the DSCI
9. Uninstall the three operators: OpenShift Serverless, Service Mesh v2, standalone Authorino

> **Helper scripts are gone in 3.5.** The `/opt/rhai-upgrade-helpers/*.sh` scripts no longer ship. Every conversion step is now a `rhai-cli migrate run --migration <name> --target-version 3.5.0` action run inside the rhai-cli pod. The two model-serving conversions changed shape: `serverless-to-raw` now runs **cluster-wide and non-interactive** (no per-namespace loop, no model-selection prompts), and `modelmesh-to-raw` now runs **in-place in a single namespace** (the old `--from-ns`/`--target-ns` source→target model is gone).

Re-run `rhai-cli lint --target-version 3.5 --checks "*kserve*" --checks "*modelmesh*"` after each major step.

> **⚠️ The order is load-bearing — getting it backwards strands your ISVCs undeletable.** Steps 2–4 (convert **and delete** every legacy Serverless/ModelMesh ISVC) must complete *while Serverless and Service Mesh are still installed* (steps 8–9). A Serverless-mode `InferenceService` carries a KServe finalizer whose cleanup logic garbage-collects the Knative `Service` and the Istio `VirtualService` it owns. If you set `serving.managementState: Removed` / `serviceMesh: Removed` or uninstall the Serverless/Service Mesh operators **before** those ISVCs are deleted, the finalizer can never run — it tries to reach `services.serving.knative.dev` / `virtualservices.networking.istio.io` API groups that no longer exist, errors out, and never clears itself. The ISVC then hangs in `Terminating` forever. This is the same finalizer-ordering trap documented for the SMMR in *§ Uninstall Service Mesh v2* (delete the finalizer-bearing object *before* removing the controller that processes its finalizer). Recovery once wedged is in *§ Recover a stuck (Terminating) InferenceService* below.
>
> The `modelserving.serverless-to-raw` action converts **and deletes** the legacy Serverless ISVCs in one pass. The deadlock is triggered by removing Serverless/Service Mesh (steps 8–9) *before* that conversion has finished deleting them — so keep both operators installed until step 4's verify is clean.

---

## § Convert Serverless InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing Serverless ISVCs.

Migration guide §2.10.7.1 replaces the old `serverless-to-raw.sh` helper with the **`modelserving.serverless-to-raw` migrate action**. In 3.5 this runs **cluster-wide and non-interactive** — it converts every Serverless ISVC across all namespaces in one pass (no per-namespace `-n` loop, no ISVC-selection or naming prompts), and it deletes the legacy Serverless ISVC + ServingRuntime + auth resources + Istio route as part of the conversion.

Enumerate first via rhai-cli (matches the guide's discovery step):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli lint --target-version 3.5 --verbose \
  --checks "*kserve*" --isvc-deployment-mode serverless
```

Dry-run first, then apply. Both run inside the rhai-cli pod; no `-it` is needed since the action is non-interactive:

```
# Preview every conversion across all namespaces
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
  --migration modelserving.serverless-to-raw --target-version 3.5.0 --dry-run

# Once the dry-run looks right, apply for real (cluster-wide)
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
  --migration modelserving.serverless-to-raw --target-version 3.5.0
```

Generated files land under `/tmp/rhoai-upgrade-backup/model-serving/serverless-to-raw/<isvc>/` inside the pod (an `original/` snapshot for rollback + the raw rewrite). The action handles auth resources automatically based on each ISVC's `security.opendatahub.io/enable-auth` annotation.

> **GitOps self-heal races the conversion.** On a real 2.25.10 run the first `serverless-to-raw` apply *timed out waiting for deletion* because ArgoCD re-created the ISVCs as Serverless the moment the action deleted them. If the ISVCs are managed by ArgoCD/GitOps, pause auto-sync on that Application before running the conversion, then re-run the action.

If any Serverless ISVCs remain after the action (e.g. it skipped one it couldn't rewrite), delete them by hand once their raw replacements serve correctly (guide §2.10.7.1):

```
NS=<namespace>
oc get isvc -n "$NS" -o json | jq -r '.items[]
  | select(.status.deploymentMode == "Serverless"
        or .metadata.annotations["serving.kserve.io/deploymentMode"] == "Serverless")
  | .metadata.name' \
  | while read -r name; do oc delete isvc "$name" -n "$NS"; done
```

### Fallback — manual recreate

Only if the `modelserving.serverless-to-raw` action fails on a workload it can't handle. The KServe admission webhook refuses in-place `deploymentMode` changes (`update rejected: deploymentMode cannot be changed from 'Serverless' to 'RawDeployment'`), so the manual path is back-up, delete, recreate. Full procedure: https://access.redhat.com/articles/7134025.

```
NS=<namespace>; NAME=<isvc>
oc get isvc "$NAME" -n "$NS" -o yaml \
  | yq eval 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status)' - \
  > "/tmp/isvc-${NS}-${NAME}.yaml"
yq -i '.metadata.annotations."serving.kserve.io/deploymentMode" = "RawDeployment"' "/tmp/isvc-${NS}-${NAME}.yaml"
oc delete isvc "$NAME" -n "$NS"
oc apply -f "/tmp/isvc-${NS}-${NAME}.yaml"
```

### Verify

```
oc get isvc -n "$NS" -o json \
  | jq -r '["NAME","DEPLOYMENT_MODE","READY"], (.items[] | [.metadata.name, .status.deploymentMode, (.status.conditions[] | select(.type=="Ready") | .status)]) | @tsv' \
  | column -t
```

All converted ISVCs should show `DEPLOYMENT_MODE=RawDeployment`, `READY=True`.

> **Pre- vs post-upgrade display.** Pre-upgrade (still on 2.25.x) the column reads `RawDeployment`. After the upgrade to 3.5, RawDeployment is renamed **`Standard`** — the same services then show `DEPLOYMENT_MODE=Standard`. Both mean the same mode; don't treat the post-upgrade `Standard` value as a regression.

---

## § Convert ModelMesh InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing ModelMesh ISVCs (multi-model serving).

Migration guide §2.10.7.2 replaces the old `modelmesh-to-raw.sh` helper with the **`modelserving.modelmesh-to-raw` migrate action**. In 3.5 the source→target namespace model (`--from-ns`/`--target-ns`) is gone: the action converts ModelMesh ISVCs **in-place in a single namespace**, non-interactively, and its summary reports one "Namespace." It sets the runtime `multiModel=false`, renames the container to `kserve-container`, removes the `modelmesh-enabled` namespace label, and creates the single-model RawDeployment.

Enumerate first:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli lint --target-version 3.5 --verbose \
  --checks "*kserve*" --isvc-deployment-mode modelmesh
```

Run the in-place conversion (repeat once per namespace that holds ModelMesh ISVCs):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
  --migration modelserving.modelmesh-to-raw --target-version 3.5.0
```

> ### ⚠️ GOTCHA — `modelmesh-to-raw` does NOT fully migrate a PVC-backed OVMS model
>
> **This is a field-verified product gap (gap report Gap 1), not a warning you can skip.** For a PVC-backed ModelMesh OVMS model the action reports `Migration completed successfully!` but the new RawDeployment predictor **crash-loops and never becomes Ready**. The action converts the ISVC/runtime *metadata* only — it does **not** rewrite storage, OVMS launch args, or the readiness probe. S3-backed ModelMesh ISVCs migrate cleanly (S3 is a supported KServe storage type); **only PVC-backed OVMS models hit this**. Three manual fixes are required after the action runs.
>
> The failure surfaces in three stages: (1) the KServe pod-mutator webhook rejects the pod — `storage type must be one of [s3, hdfs, webhdfs]. storage type [pvc] is not supported`; (2) after fixing storage the OVMS container crash-loops — `Configuration file is invalid /models/model_config_list.json`; (3) after fixing args the pod runs but stays `0/1` because the readiness probe never passes.
>
> Emit these three patches (example uses ISVC `my-modelmesh-isvc` in `ml-project-c`, runtime `ovms-mm`, PVC `model-store`, model path `mobilenet` — substitute the real values; **resolve the PVC name from the `storage-config` secret's key** referenced by the ModelMesh `storage.key`):
>
> ```
> # 1. PVC storage → storageUri (null out the old ModelMesh storage block)
> oc patch isvc my-modelmesh-isvc -n ml-project-c --type=merge \
>   -p '{"spec":{"predictor":{"model":{"storageUri":"pvc://model-store/mobilenet","storage":null}}}}'
>
> # 2. OVMS multi-model args → single-model (drop --config_path, serve one model from /mnt/models)
> oc patch servingruntime ovms-mm -n ml-project-c --type=json -p='[{"op":"replace","path":"/spec/containers/0/args","value":[
>   "--model_name=my-modelmesh-isvc","--model_path=/mnt/models","--port=8001","--rest_port=8888",
>   "--file_system_poll_wait_seconds=0","--grpc_bind_address=0.0.0.0","--rest_bind_address=0.0.0.0"]}]'
>
> # 3. Declare the container port + readinessProbe on the OVMS REST port (KServe defaults the probe to 8080; OVMS serves REST on 8888)
> oc patch servingruntime ovms-mm -n ml-project-c --type=json -p='[
>   {"op":"add","path":"/spec/containers/0/ports","value":[{"containerPort":8888,"protocol":"TCP"}]},
>   {"op":"add","path":"/spec/containers/0/readinessProbe","value":{"tcpSocket":{"port":8888},"periodSeconds":10,"failureThreshold":3,"timeoutSeconds":5}}]'
>
> # Roll the predictor so all three patches take effect
> oc rollout restart deployment my-modelmesh-isvc-predictor -n ml-project-c
> ```
>
> Recommend the user run these only after confirming the predictor is stuck (webhook rejection in the pod events, or OVMS `--config_path` in the runtime args). Emit-only — do not execute.

> **Storage-class gotcha (RWO PVCs):** if the ModelMesh runtime mounts a `ReadWriteOnce` PVC (common with `gp3-csi`), the new predictor pod can land on a different node than the old one and hang with `Multi-Attach error`. If that happens, scale the old ModelMesh `ServingRuntime` to `replicas: 0` and wait for its pod to terminate before the new pod schedules. On RWX storage this is unnecessary.

Once the new RawDeployment is `Ready=True`, delete any legacy ModelMesh ISVCs and multi-model ServingRuntimes the action left behind, per guide §2.10.7.2:

```
NS=<namespace>
oc get isvc -n "$NS" -o json | jq -r '.items[]
  | select(.status.deploymentMode == "ModelMesh"
        or .metadata.annotations["serving.kserve.io/deploymentMode"] == "ModelMesh")
  | .metadata.name' \
  | while read -r name; do oc delete isvc "$name" -n "$NS"; done

oc get servingruntimes.serving.kserve.io -n "$NS" -o json \
  | jq -r '.items[] | select(.spec.multiModel==true) | .metadata.name' \
  | while read -r name; do oc delete servingruntime "$name" -n "$NS"; done
```

### Verify

```
oc get servingruntime -A -o json \
  | jq -r '.items[] | select(.spec.multiModel==true) | "\(.metadata.namespace)/\(.metadata.name)"'
```

No `multiModel=true` ServingRuntime should remain.

#### Stale ModelMesh resources are common

Even after every active ModelMesh ISVC is converted, **leftover** ServingRuntimes (`multiModel: true`) and unreferenced ISVCs are easy to miss — they live in user namespaces and don't show up in dashboards once dashboards switch from "Multi-model serving" to KServe-only. Sweep:

```
# ServingRuntimes with multiModel=true and no ISVC referencing them
oc get servingruntime -A -o json | jq -r '
  .items[]
  | select(.spec.multiModel==true)
  | "\(.metadata.namespace)/\(.metadata.name)  (age: \((now - (.metadata.creationTimestamp | fromdateiso8601)) / 86400 | floor) days)"
'

# ModelMesh ISVCs (annotation OR status mode) — even if 0 from the active sweep above,
# also check status.deploymentMode in case rhai-cli only matched one source
oc get isvc -A -o json | jq -r '
  .items[]
  | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") == "ModelMesh"
           or (.status.deploymentMode // "") == "ModelMesh")
  | "\(.metadata.namespace)/\(.metadata.name)  status.ready=\((.status.conditions[]? | select(.type=="Ready") | .status) // "unknown")"
'
```

Real-world counts: long-lived 2.x clusters often carry forgotten ModelMesh test resources from years prior — 1 stale ISVC and 3 multi-model ServingRuntimes 200+ days old is a typical sweep result, sometimes older. None are active workloads, but the deprecated CRDs need clearing before upgrade. Delete with `oc delete isvc <name> -n <ns>` and `oc delete servingruntime <name> -n <ns>`.

> **Don't confuse v1alpha1 ServingRuntime with ModelMesh.** Several KServe single-model ServingRuntimes (`multiModel: false`) ship at `serving.kserve.io/v1alpha1` — that's just the API version, not a sign of ModelMesh. They're safe to leave untouched. The only signal for ModelMesh is `spec.multiModel: true`.

---

## § Back up and update the inferenceservice-config ConfigMap

**rhai-cli signal:** `component / kserve / configmap` (wording varies).

Two steps from migration guide §2.10.6 and §2.10.8. **Run these AFTER every ISVC is converted to RawDeployment**, not before — the guide's order is back up → convert ISVCs → update ConfigMap.

Back up first (per §2.10.6):

```
mkdir -p /tmp/rhoai-upgrade-backup
oc get configmap inferenceservice-config -n redhat-ods-applications -o yaml \
  > /tmp/rhoai-upgrade-backup/inferenceservice-config-backup.yaml
```

Then apply the hardware-profile ignorelist via the `modelserving.hardwareprofiles-ignorelist` migrate action (per §2.10.8). The action marks the ConfigMap `opendatahub.io/managed=false` *and* adds the hardware-profile annotations to `serviceAnnotationDisallowedList` in one shot:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
  --migration modelserving.hardwareprofiles-ignorelist --target-version 3.5.0
```

Verify:

```
oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o yaml | grep "hardware" -B 2 -A 2
oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o jsonpath='managed={.metadata.annotations.opendatahub\.io/managed}{"\n"}'
```

`managed=false` and the ignorelist should both be present.

### Restore post-upgrade

After the upgrade, run the `modelserving.managed-isvc-config` migrate action to restore `managed=true` (per §4.9.1). Post-upgrade the action auto-detects the post-upgrade phase — no phase flag needed:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
  --migration modelserving.managed-isvc-config --target-version 3.5.0
```

> The `managed=false` annotation prevents the upgrade from redeploying ISVCs. If a workload owner wanted fresh runtime images post-upgrade (newer vLLM build etc.), they restart their own predictors after this step.

---

## § Disable Serverless mode on the DSC

**rhai-cli signal:** `component / kserve / serving-removal` or `serverless-removal` with impact `critical`.

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": {
    "components": {
      "kserve": {
        "defaultDeploymentMode": "RawDeployment",
        "serving": { "managementState": "Removed" }
      }
    }
  }
}'
```

### Verify

```
oc get dsc -o jsonpath='{.items[0].spec.components.kserve.defaultDeploymentMode}'; echo
oc get dsc -o jsonpath='{.items[0].spec.components.kserve.serving.managementState}'; echo
# expect: RawDeployment / Removed
```

---

## § Disable ModelMesh on the DSC

**rhai-cli signal:** `component / modelmeshserving / removal` with impact `critical`.

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "modelmeshserving": { "managementState": "Removed" } } }
}'
```

> **v1 field name is intentional pre-upgrade.** The `modelmeshserving` key is a DSC **v1** field. Use it as-is on the 2.25.x cluster — the 3.5 operator converts the DSC v1→v2 automatically on startup (it removes `modelmeshserving` and `codeflare` during the conversion, per changes-doc §4.1). Do not try to pre-rename it.

### Verify

```
oc get dsc -o jsonpath='{.items[0].spec.components.modelmeshserving.managementState}'; echo
# expect: Removed
# ModelMesh controllers should disappear from redhat-ods-applications
oc get pods -n redhat-ods-applications | grep -i modelmesh || echo "no modelmesh pods — good"
```

---

## § Disable Service Mesh on the DSCI

**rhai-cli signal:** `dependency / servicemesh-operator-v2 / upgrade` or the DSCI check.

```
oc patch $(oc get dsci -o name | head -n1) --type=merge -p '{
  "spec": { "serviceMesh": { "managementState": "Removed" } }
}'
```

> **v1 field name is intentional pre-upgrade.** `serviceMesh` is a DSCI **v1** field. Patch it as written on the 2.25.x cluster; the 3.5 operator handles the v1→v2 API conversion after upgrade. No manual pre-rename.

### Verify

```
oc get dsci -o jsonpath='{.items[0].spec.serviceMesh.managementState}'; echo
# expect: Removed
# SMCP should be removed or transitioning
oc get smcp -n istio-system
```

---

## § Uninstall OpenShift Serverless

**rhai-cli signal:** `dependency / serverless-operator / uninstall`.

```
# Remove KNativeServing CR first (if present)
oc delete knativeserving knative-serving -n knative-serving --ignore-not-found

# Then remove the operator subscription + CSV
oc get subscription -n openshift-serverless serverless-operator -o jsonpath='{.status.installedCSV}{"\n"}' \
  | xargs -I{} oc delete csv {} -n openshift-serverless --ignore-not-found
oc delete subscription serverless-operator -n openshift-serverless --ignore-not-found

# Clean up the namespace if unused
oc delete namespace knative-serving --ignore-not-found
oc delete namespace openshift-serverless --ignore-not-found
```

---

## § Uninstall Service Mesh v2

**rhai-cli signal:** `dependency / servicemesh-operator-v2 / uninstall`.

**Callout:** if any non-RHOAI workload on the cluster depends on Service Mesh v2, upgrade them to v3 first. Do NOT uninstall v2 and leave v2-dependent workloads stranded.

```
# Delete the SMCP (if not already gone from the DSCI change above)
oc delete servicemeshcontrolplane data-science-smcp -n istio-system --ignore-not-found

# Delete any leftover SMMR — DSCI's serviceMesh=Removed deletes the SMCP but does NOT
# delete the SMMR; it lingers with a maistra.io/istio-operator finalizer and is invisible
# to the upgrade until you trigger it explicitly. Do this WHILE the SM v2 operator is
# still installed so the operator can process the finalizer:
oc delete smmr -n istio-system default --ignore-not-found

# Uninstall operator (SMMR must be gone first or this hangs)
oc get subscription -n openshift-operators servicemeshoperator -o jsonpath='{.status.installedCSV}{"\n"}' \
  | xargs -I{} oc delete csv {} -n openshift-operators --ignore-not-found
oc delete subscription servicemeshoperator -n openshift-operators --ignore-not-found

# Kiali / Jaeger if installed for v2:
oc delete subscription kiali-ossm -n openshift-operators --ignore-not-found
oc delete subscription jaeger-product -n openshift-operators --ignore-not-found
```

> The SM v2 operator pod (named `istio-operator-*`) runs in `openshift-operators`, not in `istio-system`. The `istio-system` namespace only hosts the SMCP-controlled workloads (Galley, Pilot, ingress/egress gateways) — when the SMCP is gone, that namespace empties out but the operator that processes finalizers is still alive elsewhere. Order matters: SMMR delete → SMMR finalizer fires → operator uninstall.

> **⚠️ Uninstalling the operator does NOT remove its CRDs — and the leftovers block the 3.5 Data Science Gateway (gap report Gap 2).** OLM operator uninstall never deletes CRDs, so ~22 Maistra `*.istio.io` / `*.maistra.io` CRDs (serving only `v1beta1`/`v1alpha3`) survive. On OCP 4.20.31+/4.21.22+/4.22+ the built-in Gateway API (sail Istio) provides Service Mesh 3, but it **refuses to install its `networking.istio.io/v1` CRDs while the foreign Maistra CRDs exist** (`"Istio CRDs are managed by an unknown party"`) — so post-upgrade the DSC never reaches Ready (`istiod-openshift-gateway` stuck `0/1`, Gateway `Programmed=False`, ModelRegistry `gateway domain is missing`). After confirming **zero** Istio custom resources remain (no data loss), delete the stale `*.istio.io` CRDs and restart the ingress-operator so sail reinstalls them at `v1`:
>
> ```
> # Safety check — must show the CRDs but no live CRs before deleting
> oc get crd -l maistra-version -o custom-columns=NAME:.metadata.name,VER:.metadata.labels.maistra-version
>
> oc delete crd destinationrules.networking.istio.io virtualservices.networking.istio.io \
>   gateways.networking.istio.io serviceentries.networking.istio.io sidecars.networking.istio.io \
>   envoyfilters.networking.istio.io workloadentries.networking.istio.io workloadgroups.networking.istio.io \
>   proxyconfigs.networking.istio.io authorizationpolicies.security.istio.io \
>   peerauthentications.security.istio.io requestauthentications.security.istio.io \
>   telemetries.telemetry.istio.io wasmplugins.extensions.istio.io --ignore-not-found
>
> oc rollout restart deploy/ingress-operator -n openshift-ingress-operator
> ```
>
> The `*.maistra.io` CRDs (servicemeshcontrolplanes, federation, etc.) are harmless leftovers with 0 CRs — optional to remove; only the `*.istio.io` ones block the sail controller. Emit-only.

---

## § Uninstall standalone Authorino

**rhai-cli signal:** `dependency / authorino-operator / uninstall`.

Standalone Authorino is replaced by Red Hat Connectivity Link (RHCL) in 3.x. Uninstalling is safe once no LLMInferenceService or other KServe auth workload depends on the standalone install — but **only delete the Subscription**. RHCL also installs into `openshift-operators` (AllNamespaces) and depends on the same `authorino-operator` package; OLM dedupes them to a single shared CSV. Deleting the CSV tears down RHCL's Authorino too.

```
# Subscription-only delete. The CSV stays alive because rhcl-operator's Subscription
# still depends on the same authorino-operator package.
oc delete subscription authorino-operator -n openshift-operators --ignore-not-found
```

Verify the shared CSV is still healthy after the Subscription delete:

```
oc get csv -n openshift-operators | grep authorino-operator
# Expected: authorino-operator.v1.x.y   Authorino Operator   ...   Succeeded
```

> **Earlier revisions** of this resolver had the cleanup capture `installedCSV` from the standalone Subscription and `oc delete csv` it, on the rationale that RHCL lived in a separate namespace (`kuadrant-system`) with its own bundled Authorino CSV. That was only correct when RHCL was installed into `kuadrant-system`. The RHCL v1.3.3 install mode requirement (AllNamespaces / `openshift-operators` — see *§ Install Red Hat Connectivity Link*) shares the CSV with the standalone install. Drop the CSV delete to avoid breaking RHCL.

---

## § Recover a stuck (Terminating) InferenceService — finalizer deadlock

**Symptom:** `oc delete isvc <name>` hangs and never returns (or times out). The ISVC stays listed with a `deletionTimestamp` set but is not removed. The KServe controller logs show it repeatedly failing to reach Knative/Istio APIs — the operator described it as "the delete command was changing / it seems to be looking for serverless and service mesh."

**Cause:** a Serverless-mode ISVC's finalizer cleanup needs the Knative and Service Mesh controllers/CRDs present to garbage-collect the `Service` and `VirtualService` it owns. If Serverless / Service Mesh were removed *before* the ISVC was deleted (the ordering trap in *The migration sequence matters* above), the finalizer errors against the now-absent API groups and never clears. See architectural-changes.md § *Model Serving Migration* for why these ISVCs must be converted+deleted pre-upgrade; the ordering itself is migration guide §2.10.7 → §2.10.9.

### Diagnose first

Confirm it's a finalizer deadlock and not a slow delete before touching anything:

```
NS=<namespace>; NAME=<isvc>

# deletionTimestamp set + finalizers still present == wedged
oc get isvc "$NAME" -n "$NS" -o jsonpath='deletionTimestamp={.metadata.deletionTimestamp}{"\n"}finalizers={.metadata.finalizers}{"\n"}deploymentMode={.status.deploymentMode}{"\n"}'

# controller erroring against the missing APIs confirms the cause
oc logs -n redhat-ods-applications deploy/kserve-controller-manager --tail=80 \
  | grep -iE 'knative|istio|virtualservice|no matches for kind|not found'
```

If `deletionTimestamp` is set and `finalizers` is non-empty, and the log shows Knative/Istio lookup failures, it's the deadlock.

### Preferred recovery — let the finalizer run properly

The cleanest fix is to give the finalizer back what it needs, so it does its real cleanup instead of orphaning children. **If the operators aren't yet uninstalled** (only `managementState: Removed`), flip Serverless/Service Mesh back to `Managed` on the DSC/DSCI, wait for the controllers to come up, then re-issue the delete — it completes normally:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{"spec":{"components":{"kserve":{"serving":{"managementState":"Managed"}}}}}'
oc patch $(oc get dsci -o name | head -n1) --type=merge -p '{"spec":{"serviceMesh":{"managementState":"Managed"}}}'
# wait for kserve/knative/istio controllers to be Ready, then:
oc delete isvc "$NAME" -n "$NS"
```

Once every legacy ISVC is deleted, redo the removal steps *in the correct order*.

### Fallback recovery — force-clear the finalizer

If the operators are already fully uninstalled (CRDs gone) and reinstalling them isn't practical, force-remove the finalizer so the object deletes, then recreate the workload as RawDeployment from your backup YAML:

```
NS=<namespace>; NAME=<isvc>
oc patch isvc "$NAME" -n "$NS" --type=merge -p '{"metadata":{"finalizers":null}}'
oc get isvc "$NAME" -n "$NS" 2>/dev/null || echo "deleted"
```

> **Risk (one sentence):** force-clearing the finalizer skips the real cleanup, so any Knative `Service` / Istio `VirtualService` children the finalizer *would* have deleted may be left orphaned — harmless on a cluster where Serverless/Service Mesh are being torn out anyway, but sweep for leftovers (`oc get ksvc,virtualservice -n "$NS"`) if you're not.

Batch form for a whole namespace of stuck Serverless ISVCs:

```
NS=<namespace>
for name in $(oc get isvc -n "$NS" -o json \
  | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name'); do
  echo "force-clearing finalizer on $name"
  oc patch isvc "$name" -n "$NS" --type=merge -p '{"metadata":{"finalizers":null}}'
done
```

Then recreate each from the backup the `modelserving.serverless-to-raw` action wrote under `/tmp/rhoai-upgrade-backup/model-serving/serverless-to-raw/<isvc>/` (or your own export), with `serving.kserve.io/deploymentMode: RawDeployment`.

---

## After

Re-run:

```
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.5 --verbose --checks "*kserve*" --checks "*modelmesh*"
```

All `critical` / `prohibited` rows in this group should now be gone.
