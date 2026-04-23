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

Do these in order. Skipping ahead leaves the cluster in a half-migrated state where the RHOAI operator reconciler fights against workloads.

1. Convert every Serverless `InferenceService` to RawDeployment
2. Convert every ModelMesh `InferenceService` to RawDeployment (convert its multi-model `ServingRuntime` too)
3. Verify InferenceServices are healthy on the new mode
4. Update the `inferenceservice-config` ConfigMap (adds the hardware-profile ignorelist)
5. Set `kserve.serving.managementState: Removed` on the DSC
6. Set `modelmeshserving.managementState: Removed` on the DSC
7. Set `serviceMesh.managementState: Removed` on the DSCI
8. Uninstall the three operators: OpenShift Serverless, Service Mesh v2, standalone Authorino

Re-run `rhai-cli lint --checks "*kserve*" --checks "*modelmesh*"` after each major step.

---

## § Convert Serverless InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing Serverless ISVCs.

Enumerate them first:

```
oc get isvc -A -o json \
  | jq -r '.items[] | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") == "Serverless" or (.status.deploymentMode // "") == "Serverless") | "\(.metadata.namespace)\t\(.metadata.name)"'
```

> Note: earlier versions of this guide referenced `rhai-cli modelserving convert-to-raw` and `rhai-cli modelserving update-config` helpers. Those subcommands do **not** exist in the shipped `rhai-cli` image (v3.3.2 only exposes `lint`).
>
> **Also: the KServe admission webhook refuses in-place `deploymentMode` changes** (`update rejected: deploymentMode cannot be changed from 'Serverless' to 'RawDeployment'`). So you cannot convert by annotation patch. You must **back up, delete, and recreate** the ISVC with the new annotation.

Per-ISVC procedure:

```
NS=<namespace>; NAME=<isvc>
# 1. Back up the spec (metadata stripped) for recreation
oc get isvc "$NAME" -n "$NS" -o yaml \
  | yq eval 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status)' - \
  > "/tmp/isvc-${NS}-${NAME}.yaml"

# 2. Flip the deploymentMode annotation in the backup
yq -i '.metadata.annotations."serving.kserve.io/deploymentMode" = "RawDeployment"' "/tmp/isvc-${NS}-${NAME}.yaml"

# 3. Delete the old ISVC
oc delete isvc "$NAME" -n "$NS"

# 4. Recreate from backup
oc apply -f "/tmp/isvc-${NS}-${NAME}.yaml"
```

If the ISVCs are sample/demo workloads the user does not care about, skip steps 2 + 4 and just delete.

### Verify

```
oc get isvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ANNOT:.metadata.annotations.serving\.kserve\.io/deploymentMode,STATUS:.status.deploymentMode,READY:.status.conditions[?(@.type=="Ready")].status'
```

All converted ISVCs should show `ANNOT=RawDeployment`, `STATUS=RawDeployment`, `READY=True`.

---

## § Convert ModelMesh InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing ModelMesh ISVCs (multi-model serving).

ModelMesh is more involved because each multi-model `ServingRuntime` (`spec.multiModel: true`) must be replaced with an equivalent single-model runtime. There is no `rhai-cli modelserving` helper; do it by hand:

1. Identify the ModelMesh ISVCs and multi-model `ServingRuntime`s they reference.
2. For each ISVC, either delete it and recreate it against a single-model ServingRuntime that supports its format, or (if the model isn't worth migrating) delete the ISVC.
3. Delete the orphaned multi-model `ServingRuntime`.

```
# Enumerate
oc get isvc -A -o json | jq -r '.items[] | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") == "ModelMesh") | "\(.metadata.namespace)/\(.metadata.name)"'
oc get servingruntime -A -o json | jq -r '.items[] | select(.spec.multiModel==true) | "\(.metadata.namespace)/\(.metadata.name)"'

# Delete a ModelMesh ISVC
oc delete isvc <name> -n <namespace>

# Delete its multi-model ServingRuntime (only after no ISVCs reference it)
oc delete servingruntime <name> -n <namespace>
```

### Verify

```
# No ServingRuntime with multiModel=true should remain in use
oc get servingruntime -A -o json \
  | jq -r '.items[] | select(.spec.multiModel==true) | "\(.metadata.namespace)/\(.metadata.name)"'
```

---

## § Update the inferenceservice-config ConfigMap

**rhai-cli signal:** `component / kserve / configmap` (wording varies).

Back up and add the hardware-profile ignorelist expected by 3.x:

```
oc get cm inferenceservice-config -n redhat-ods-applications -o yaml \
  > /tmp/inferenceservice-config-backup-$(date +%Y%m%d%H%M).yaml
```

Patch the ConfigMap by hand (the `rhai-cli modelserving update-config` helper does not exist in the shipped image):

```
# 1. Mark the ConfigMap unmanaged so the RHOAI operator doesn't overwrite it
oc annotate configmap inferenceservice-config -n redhat-ods-applications \
  opendatahub.io/managed=false --overwrite

# 2. Add the hardware-profile annotations to serviceAnnotationDisallowedList
oc get cm inferenceservice-config -n redhat-ods-applications -o json \
  | jq '.data.inferenceService |= (fromjson
      | .serviceAnnotationDisallowedList += ["opendatahub.io/hardware-profile-name","opendatahub.io/hardware-profile-namespace"]
      | tojson)' \
  | oc apply -f -
```

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

# Uninstall operator
oc get subscription -n openshift-operators servicemeshoperator -o jsonpath='{.status.installedCSV}{"\n"}' \
  | xargs -I{} oc delete csv {} -n openshift-operators --ignore-not-found
oc delete subscription servicemeshoperator -n openshift-operators --ignore-not-found

# Kiali / Jaeger if installed for v2:
oc delete subscription kiali-ossm -n openshift-operators --ignore-not-found
oc delete subscription jaeger-product -n openshift-operators --ignore-not-found
```

---

## § Uninstall standalone Authorino

**rhai-cli signal:** `dependency / authorino-operator / uninstall`.

Standalone Authorino is replaced by Red Hat Connectivity Link (RHCL) in 3.x. Uninstalling the standalone operator is safe once no LLMInferenceService or other KServe auth workload depends on it.

```
oc get subscription -n openshift-operators authorino-operator -o jsonpath='{.status.installedCSV}{"\n"}' \
  | xargs -I{} oc delete csv {} -n openshift-operators --ignore-not-found
oc delete subscription authorino-operator -n openshift-operators --ignore-not-found
```

**Do not** uninstall if you have RHCL (also bundles Authorino) already deployed — RHCL will manage it.

---

## After

Re-run:

```
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --verbose --checks "*kserve*" --checks "*modelmesh*"
```

All `critical` / `prohibited` rows in this group should now be gone.
