# Resolver — KServe / Model Serving

**rhai-cli signal:** the largest migration section. Covers every `component / kserve`, `component / modelmeshserving`, `workload / kserve`, and `dependency / {servicemesh-operator-v2, serverless-operator, authorino-operator}` check from rhai-cli. Each `§` section below repeats its own specific signal.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / helper script yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## The migration sequence matters — READ THIS FIRST

Per migration guide §2.8.3, do the sections in this order. Skipping ahead leaves the cluster in a half-migrated state where the RHOAI operator reconciler fights against workloads.

1. **Back up** the `inferenceservice-config` ConfigMap (§2.8.6) — *§ Back up and update the inferenceservice-config ConfigMap*
2. **Convert** every Serverless `InferenceService` to RawDeployment via `serverless-to-raw.sh` (§2.8.7.1) — *§ Convert Serverless InferenceServices*
3. **Convert** every ModelMesh `InferenceService` to RawDeployment via `modelmesh-to-raw.sh`, including its multi-model `ServingRuntime` (§2.8.7.2) — *§ Convert ModelMesh InferenceServices*
4. **Verify** InferenceServices are healthy on the new mode (§2.8.7.3)
5. **Update** the `inferenceservice-config` ConfigMap with the hardware-profile ignorelist via `hardwareprofiles-ignorelist.sh` (§2.8.8) — *§ Back up and update...*
6. Set `kserve.serving.managementState: Removed` on the DSC (§2.8.9) — *§ Disable Serverless mode*
7. Set `modelmeshserving.managementState: Removed` on the DSC — *§ Disable ModelMesh*
8. Set `serviceMesh.managementState: Removed` on the DSCI — *§ Disable Service Mesh*
9. Uninstall the three operators: OpenShift Serverless, Service Mesh v2, standalone Authorino

Re-run `rhai-cli lint --checks "*kserve*" --checks "*modelmesh*"` after each major step.

> **⚠️ The order is load-bearing — getting it backwards strands your ISVCs undeletable.** Steps 2–4 (convert **and delete** every legacy Serverless/ModelMesh ISVC) must complete *while Serverless and Service Mesh are still installed* (steps 8–9). A Serverless-mode `InferenceService` carries a KServe finalizer whose cleanup logic garbage-collects the Knative `Service` and the Istio `VirtualService` it owns. If you set `serving.managementState: Removed` / `serviceMesh: Removed` or uninstall the Serverless/Service Mesh operators **before** those ISVCs are deleted, the finalizer can never run — it tries to reach `services.serving.knative.dev` / `virtualservices.networking.istio.io` API groups that no longer exist, errors out, and never clears itself. The ISVC then hangs in `Terminating` forever. This is the same finalizer-ordering trap documented for the SMMR in *§ Uninstall Service Mesh v2* (delete the finalizer-bearing object *before* removing the controller that processes its finalizer). Recovery once wedged is in *§ Recover a stuck (Terminating) InferenceService* below.
>
> **Two mistakes that combine to trigger it:** (a) running `serverless-to-raw.sh` without `--delete-existing` (or the `-raw` side-by-side path) and then skipping the manual delete of the legacy ISVCs; **then** (b) removing Serverless/Service Mesh before going back to delete them. Either one alone is survivable — together they deadlock.

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<NAMESPACE>` | a namespace holding InferenceServices | `oc get isvc -A` |
| `<ISVC_NAME>` | an InferenceService name | `oc get isvc -n <NAMESPACE>` |
| `<SOURCE_NAMESPACE>` | namespace the ModelMesh ISVCs live in | `oc get isvc -A` |
| `<TARGET_NAMESPACE>` | destination namespace for a cross-namespace ModelMesh conversion | you choose it |
| `<PVC_NAME>` | the PVC backing a ModelMesh model | from the original ISVC's `spec.predictor.model.storage` |
| `<PATH>` | the model path inside the PVC | from the original ISVC's `storage.path` |

Constants — leave literal, do NOT placeholder-ize: `rhai-migration`, `rhai-cli-0`, `redhat-ods-applications`, `istio-system`, `knative-serving`, `openshift-serverless`, `openshift-operators`.

---

## § Convert Serverless InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing Serverless ISVCs.

Migration guide §2.8.7.1 ships `serverless-to-raw.sh` as the **official** conversion path. The helper is at `/opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh` inside the rhai-cli container.

### DO THIS

1. Enumerate the Serverless ISVCs (matches the guide's discovery step).

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --verbose \
     --checks "*kserve*" --isvc-deployment-mode serverless
   ```

   → Expected: a list of Serverless-mode ISVCs to convert. If none, skip this section.

2. Dry-run the conversion per namespace. The script is interactive — step through **two prompts**:
   - *Selection prompt*: choose which ISVCs to migrate. Type `all` (or specific numbers like `1 3 5`).
   - *Naming prompt*: option `1` for original names (in-place replacement) or `2` for `-raw` suffix (side-by-side). → if the original name matters for downstream callers (workshop default): choose `1`. → if you want side-by-side validation before retiring the originals: choose `2`.

   ```sh
   NS=<NAMESPACE>

   oc exec -n rhai-migration rhai-cli-0 -it -- \
     /opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh \
     --dry-run -n "$NS"
   ```

   → Expected: the dry-run prints the rewritten RawDeployment YAML without changing anything.

3. ⚠️ Destructive — apply for real once the dry-run looks right. With option 1 (in-place), `--delete-existing` makes the script delete the legacy ISVC + ServingRuntime + auth resources + Istio route before applying the rewritten YAML.

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -it -- \
     /opt/rhai-upgrade-helpers/model-serving/before-upgrade/serverless-to-raw.sh \
     --delete-existing -n "$NS"
   ```

   → if you chose option `2` (`-raw` suffix) in step 2: the script does NOT touch the legacy resources — go to step 4. → if you chose option `1` with `--delete-existing`: legacy resources are already gone — skip to Verify.

4. ⚠️ Destructive — only if you used option `2`. Delete the legacy Serverless resources by hand once you're satisfied the `-raw` copies serve correctly (guide §2.8.7.1 step 5).

   ```sh
   oc get isvc -n "$NS" -o json | jq -r '.items[]
     | select(.status.deploymentMode == "Serverless"
           or .metadata.annotations["serving.kserve.io/deploymentMode"] == "Serverless")
     | .metadata.name' \
     | while read -r name; do oc delete isvc "$name" -n "$NS"; done
   ```

### Verify (read-only)

```sh
oc get isvc -n "$NS" -o json \
  | jq -r '["NAME","DEPLOYMENT_MODE","READY"], (.items[] | [.metadata.name, .status.deploymentMode, (.status.conditions[] | select(.type=="Ready") | .status)]) | @tsv' \
  | column -t
```

→ Expected: all converted ISVCs show `DEPLOYMENT_MODE=RawDeployment`, `READY=True`.

### Notes & edge cases

- Generated files land under `/tmp/rhoai-upgrade-backup/model-serving/serverless-to-raw/<ISVC_NAME>/` inside the pod (an `original/` snapshot for rollback + a `raw-original-names/` rewrite). The script handles auth resources automatically based on the ISVC's `security.opendatahub.io/enable-auth` annotation.
- **Fallback — manual recreate.** Only if the helper script is unavailable or fails on a workload it can't handle. The KServe admission webhook refuses in-place `deploymentMode` changes (`update rejected: deploymentMode cannot be changed from 'Serverless' to 'RawDeployment'`), so the manual path is back-up, delete, recreate. Full procedure: https://access.redhat.com/articles/7134025.

  ```sh
  NS=<NAMESPACE>; NAME=<ISVC_NAME>
  oc get isvc "$NAME" -n "$NS" -o yaml \
    | yq eval 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status)' - \
    > "/tmp/isvc-${NS}-${NAME}.yaml"
  yq -i '.metadata.annotations."serving.kserve.io/deploymentMode" = "RawDeployment"' "/tmp/isvc-${NS}-${NAME}.yaml"
  oc delete isvc "$NAME" -n "$NS"
  oc apply -f "/tmp/isvc-${NS}-${NAME}.yaml"
  ```

---

## § Convert ModelMesh InferenceServices to RawDeployment

**rhai-cli signal:** `workload / kserve / impacted-workloads` referencing ModelMesh ISVCs (multi-model serving).

Migration guide §2.8.7.2 ships `modelmesh-to-raw.sh` as the **official** path. The helper discovers ModelMesh ISVCs in `--from-ns`, prompts you to select models and a runtime template, configures storage, and creates the new single-model RawDeployment ServingRuntime + InferenceService.

### DO THIS

1. Enumerate the ModelMesh ISVCs.

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --verbose \
     --checks "*kserve*" --isvc-deployment-mode modelmesh
   ```

   → Expected: a list of ModelMesh-mode ISVCs. If none, skip this section.

2. Convert. → Pick ONE path. The two flag combinations do NOT compose (see Notes).

   **Path A — cross-namespace (preview-friendly, supports `--dry-run`):**

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -it -- \
     /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
     --from-ns <SOURCE_NAMESPACE> --target-ns <TARGET_NAMESPACE> --dry-run
   ```

   → Expected: prints generated YAML. ⚠️ Then apply for real:

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -it -- \
     /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
     --from-ns <SOURCE_NAMESPACE> --target-ns <TARGET_NAMESPACE>
   ```

   **Path B — same-namespace in-place** (keeps the original name, no cross-namespace storage permission setup; ⚠️ destructive, no dry-run — the interactive prompts are the safety net):

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -it -- \
     /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
     --from-ns <NAMESPACE> --preserve-namespace
   ```

   → To inspect generated YAML *before* an in-place run: dry-run against a scratch target namespace, review the files inside the rhai-cli pod, then drop the scratch namespace and execute `--preserve-namespace`:

   ```sh
   oc create ns mm-preview 2>/dev/null || true
   oc exec -n rhai-migration rhai-cli-0 -it -- \
     /opt/rhai-upgrade-helpers/model-serving/before-upgrade/modelmesh-to-raw.sh \
     --from-ns <NAMESPACE> --target-ns mm-preview --dry-run
   oc delete ns mm-preview
   ```

3. → if the new ModelMesh ISVC used **PVC storage** and its ReplicaSet stays at 0 with `storage type must be one of [s3, hdfs, webhdfs]. storage type [pvc] is not supported`: apply the PVC patch (known script bug — see Notes). → if S3-backed: it migrates cleanly, skip to step 4.

4. ⚠️ Destructive — once the new RawDeployment is `Ready=True`, delete the legacy ModelMesh ISVCs and multi-model ServingRuntimes per guide §2.8.7.2 step 5.

   ```sh
   oc get isvc -n <SOURCE_NAMESPACE> -o json | jq -r '.items[]
     | select(.status.deploymentMode == "ModelMesh"
           or .metadata.annotations["serving.kserve.io/deploymentMode"] == "ModelMesh")
     | .metadata.name' \
     | while read -r name; do oc delete isvc "$name" -n <SOURCE_NAMESPACE>; done

   oc get servingruntimes.serving.kserve.io -n <SOURCE_NAMESPACE> -o json \
     | jq -r '.items[] | select(.spec.multiModel==true) | .metadata.name' \
     | while read -r name; do oc delete servingruntime "$name" -n <SOURCE_NAMESPACE>; done
   ```

### Verify (read-only)

```sh
oc get servingruntime -A -o json \
  | jq -r '.items[] | select(.spec.multiModel==true) | "\(.metadata.namespace)/\(.metadata.name)"'
```

→ Expected: no output — no `multiModel=true` ServingRuntime should remain.

### Notes & edge cases

- **Two flag combinations — they don't compose:**
  - `--from-ns <A> --target-ns <B>` (source ≠ target) supports `--dry-run` for safe preview. Source and target equal produces `✗ Error: --from-ns and --target-ns cannot be the same`.
  - `--from-ns <A> --preserve-namespace` runs *in-place*. It is destructive and cannot be combined with `--dry-run` (`✗ Error: --dry-run and --preserve-namespace cannot be used together`).

- **Known script bug — PVC-backed models.** When the original ModelMesh ISVC used PVC storage (`storage: { key: pvc-models, path: ... }`), `modelmesh-to-raw.sh` transcribes that block verbatim into the new RawDeployment ISVC. The KServe admission webhook rejects it with `storage type must be one of [s3, hdfs, webhdfs]. storage type [pvc] is not supported`, and the ReplicaSet stays at 0. Patch the ISVC to the KServe `storageUri` form post-script:

  ```sh
  oc patch isvc <ISVC_NAME> -n <NAMESPACE> --type=json -p='[
    {"op":"remove","path":"/spec/predictor/model/storage"},
    {"op":"add","path":"/spec/predictor/model/storageUri","value":"pvc://<PVC_NAME>/<PATH>"}
  ]'
  ```

  S3-backed ModelMesh ISVCs migrate cleanly (S3 is a supported KServe storage type) — only PVC-backed ones hit this gap.

- **Storage-class gotcha (RWO PVCs):** if the ModelMesh runtime mounts a `ReadWriteOnce` PVC (common with `gp3-csi`), scale the ModelMesh `ServingRuntime` to `replicas: 0` and wait for its pod to terminate *before* applying the new ISVC. Otherwise the new pod can land on a different node and hang with `Multi-Attach error`. On RWX storage this is unnecessary.

- **Stale ModelMesh resources are common.** Even after every active ModelMesh ISVC is converted, **leftover** ServingRuntimes (`multiModel: true`) and unreferenced ISVCs are easy to miss — they live in user namespaces and don't show up in dashboards once dashboards switch from "Multi-model serving" to KServe-only. Sweep:

  ```sh
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

  Real-world counts: long-lived 2.x clusters often carry forgotten ModelMesh test resources from years prior — 1 stale ISVC and 3 multi-model ServingRuntimes 200+ days old is a typical sweep result, sometimes older. None are active workloads, but the deprecated CRDs need clearing before upgrade. Delete with `oc delete isvc <ISVC_NAME> -n <NAMESPACE>` and `oc delete servingruntime <NAME> -n <NAMESPACE>`.

- **Don't confuse v1alpha1 ServingRuntime with ModelMesh.** Several KServe single-model ServingRuntimes (`multiModel: false`) ship at `serving.kserve.io/v1alpha1` — that's just the API version, not a sign of ModelMesh. They're safe to leave untouched. The only signal for ModelMesh is `spec.multiModel: true`.

---

## § Back up and update the inferenceservice-config ConfigMap

**rhai-cli signal:** `component / kserve / configmap` (wording varies).

Two steps from migration guide §2.8.6 and §2.8.8. ⚠️ **Run these AFTER every ISVC is converted to RawDeployment**, not before — the guide's order is back up → convert ISVCs → update ConfigMap.

### DO THIS

1. Back up first (per §2.8.6).

   ```sh
   mkdir -p /tmp/rhoai-upgrade-backup
   oc get configmap inferenceservice-config -n redhat-ods-applications -o yaml \
     > /tmp/rhoai-upgrade-backup/inferenceservice-config-backup.yaml
   ```

   → Expected: the backup file exists and is non-empty.

2. ⚠️ Apply the hardware-profile ignorelist via the official helper (per §2.8.8). The helper marks the ConfigMap `opendatahub.io/managed=false` *and* adds the hardware-profile annotations to `serviceAnnotationDisallowedList` in one shot.

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     /opt/rhai-upgrade-helpers/model-serving/before-upgrade/hardwareprofiles-ignorelist.sh \
     -n redhat-ods-applications
   ```

### Verify (read-only)

```sh
oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o yaml | grep "hardware" -B 2 -A 2
oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o jsonpath='managed={.metadata.annotations.opendatahub\.io/managed}{"\n"}'
```

→ Expected: `managed=false` and the ignorelist both present.

### Notes & edge cases

- **Restore post-upgrade.** After the upgrade, run the after-upgrade helper to restore `managed=true` (per §4.9.1):

  ```sh
  oc exec -n rhai-migration rhai-cli-0 -- \
    /opt/rhai-upgrade-helpers/model-serving/after-upgrade/managed-inferenceservice-config.sh \
    -n redhat-ods-applications
  ```

  The `managed=false` annotation prevents the upgrade from redeploying ISVCs. If a workload owner wanted fresh runtime images post-upgrade (newer vLLM build etc.), they restart their own predictors after this step.

---

## § Disable Serverless mode on the DSC

**rhai-cli signal:** `component / kserve / serving-removal` or `serverless-removal` with impact `critical`.

### DO THIS

1. ⚠️ Destructive — patch the DSC to RawDeployment default + `serving: Removed`. Only after every Serverless ISVC is converted AND deleted (see *The migration sequence matters*).

   ```sh
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

### Verify (read-only)

```sh
oc get dsc -o jsonpath='{.items[0].spec.components.kserve.defaultDeploymentMode}'; echo
oc get dsc -o jsonpath='{.items[0].spec.components.kserve.serving.managementState}'; echo
```

→ Expected: `RawDeployment` / `Removed`.

---

## § Disable ModelMesh on the DSC

**rhai-cli signal:** `component / modelmeshserving / removal` with impact `critical`.

### DO THIS

1. ⚠️ Destructive — patch the DSC to `modelmeshserving: Removed`. Only after every ModelMesh ISVC is converted AND deleted.

   ```sh
   oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
     "spec": { "components": { "modelmeshserving": { "managementState": "Removed" } } }
   }'
   ```

### Verify (read-only)

```sh
oc get dsc -o jsonpath='{.items[0].spec.components.modelmeshserving.managementState}'; echo
oc get pods -n redhat-ods-applications | grep -i modelmesh || echo "no modelmesh pods — good"
```

→ Expected: `Removed`; and the ModelMesh controllers disappear from `redhat-ods-applications` (`no modelmesh pods — good`).

---

## § Disable Service Mesh on the DSCI

**rhai-cli signal:** `dependency / servicemesh-operator-v2 / upgrade` or the DSCI check.

### DO THIS

1. ⚠️ Destructive — patch the DSCI to `serviceMesh: Removed`. Only after every Serverless/ModelMesh ISVC is deleted (finalizer-ordering trap — see *The migration sequence matters*).

   ```sh
   oc patch $(oc get dsci -o name | head -n1) --type=merge -p '{
     "spec": { "serviceMesh": { "managementState": "Removed" } }
   }'
   ```

### Verify (read-only)

```sh
oc get dsci -o jsonpath='{.items[0].spec.serviceMesh.managementState}'; echo
oc get smcp -n istio-system
```

→ Expected: `Removed`; the SMCP is removed or transitioning.

---

## § Uninstall OpenShift Serverless

**rhai-cli signal:** `dependency / serverless-operator / uninstall`.

### DO THIS

1. ⚠️ Destructive — remove the KNativeServing CR (if present), then the operator subscription + CSV, then clean up the namespaces if unused. Run only after all Serverless ISVCs are deleted.

   ```sh
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

   → Expected: the KNativeServing CR, the CSV, the Subscription, and (if unused) both namespaces are removed.

---

## § Uninstall Service Mesh v2

**rhai-cli signal:** `dependency / servicemesh-operator-v2 / uninstall`.

⚠️ **Callout:** if any non-RHOAI workload on the cluster depends on Service Mesh v2, upgrade them to v3 first. Do NOT uninstall v2 and leave v2-dependent workloads stranded.

### DO THIS

Order matters: SMMR delete → SMMR finalizer fires → operator uninstall. Do the SMMR delete **while the SM v2 operator is still installed** so the operator can process the finalizer.

1. ⚠️ Destructive — delete the SMCP (if not already gone from the DSCI change above).

   ```sh
   oc delete servicemeshcontrolplane data-science-smcp -n istio-system --ignore-not-found
   ```

2. ⚠️ Destructive — delete any leftover SMMR. The DSCI's `serviceMesh=Removed` deletes the SMCP but does NOT delete the SMMR; it lingers with a `maistra.io/istio-operator` finalizer and is invisible to the upgrade until you trigger it explicitly.

   ```sh
   oc delete smmr -n istio-system default --ignore-not-found
   ```

3. ⚠️ Destructive — uninstall the operator (SMMR must be gone first or this hangs), plus Kiali / Jaeger if installed for v2.

   ```sh
   oc get subscription -n openshift-operators servicemeshoperator -o jsonpath='{.status.installedCSV}{"\n"}' \
     | xargs -I{} oc delete csv {} -n openshift-operators --ignore-not-found
   oc delete subscription servicemeshoperator -n openshift-operators --ignore-not-found

   # Kiali / Jaeger if installed for v2:
   oc delete subscription kiali-ossm -n openshift-operators --ignore-not-found
   oc delete subscription jaeger-product -n openshift-operators --ignore-not-found
   ```

   → Expected: the SMCP, the SMMR, the servicemesh CSV + Subscription, and (if present) Kiali/Jaeger subscriptions are removed.

### Notes & edge cases

- The SM v2 operator pod (named `istio-operator-*`) runs in `openshift-operators`, not in `istio-system`. The `istio-system` namespace only hosts the SMCP-controlled workloads (Galley, Pilot, ingress/egress gateways) — when the SMCP is gone, that namespace empties out but the operator that processes finalizers is still alive elsewhere. Order matters: SMMR delete → SMMR finalizer fires → operator uninstall.

---

## § Uninstall standalone Authorino

**rhai-cli signal:** `dependency / authorino-operator / uninstall`.

Standalone Authorino is replaced by Red Hat Connectivity Link (RHCL) in 3.x. Uninstalling is safe once no LLMInferenceService or other KServe auth workload depends on the standalone install.

### DO THIS

1. ⚠️ Destructive — **Subscription-only delete.** Do NOT delete the CSV: RHCL also installs into `openshift-operators` (AllNamespaces) and depends on the same `authorino-operator` package; OLM dedupes them to a single shared CSV, so `rhcl-operator`'s Subscription keeps that CSV alive. Deleting the CSV tears down RHCL's Authorino too.

   ```sh
   # Subscription-only delete. The CSV stays alive because rhcl-operator's Subscription
   # still depends on the same authorino-operator package.
   oc delete subscription authorino-operator -n openshift-operators --ignore-not-found
   ```

### Verify (read-only)

```sh
oc get csv -n openshift-operators | grep authorino-operator
```

→ Expected: the shared CSV is still healthy after the Subscription delete, e.g. `authorino-operator.v1.x.y   Authorino Operator   ...   Succeeded`.

---

## § Recover a stuck (Terminating) InferenceService — finalizer deadlock

**Symptom:** `oc delete isvc <ISVC_NAME>` hangs and never returns (or times out). The ISVC stays listed with a `deletionTimestamp` set but is not removed. The KServe controller logs show it repeatedly failing to reach Knative/Istio APIs.

**Cause:** a Serverless-mode ISVC's finalizer cleanup needs the Knative and Service Mesh controllers/CRDs present to garbage-collect the `Service` and `VirtualService` it owns. If Serverless / Service Mesh were removed *before* the ISVC was deleted (the ordering trap in *The migration sequence matters* above), the finalizer errors against the now-absent API groups and never clears. See architectural-changes.md § *Model Serving Migration* for why these ISVCs must be converted+deleted pre-upgrade; the ordering itself is migration guide §2.8.7 → §2.8.9.

### DO THIS

1. Diagnose first — confirm it's a finalizer deadlock and not a slow delete before touching anything (read-only).

   ```sh
   NS=<NAMESPACE>; NAME=<ISVC_NAME>

   # deletionTimestamp set + finalizers still present == wedged
   oc get isvc "$NAME" -n "$NS" -o jsonpath='deletionTimestamp={.metadata.deletionTimestamp}{"\n"}finalizers={.metadata.finalizers}{"\n"}deploymentMode={.status.deploymentMode}{"\n"}'

   # controller erroring against the missing APIs confirms the cause
   oc logs -n redhat-ods-applications deploy/kserve-controller-manager --tail=80 \
     | grep -iE 'knative|istio|virtualservice|no matches for kind|not found'
   ```

   → if `deletionTimestamp` is set AND `finalizers` is non-empty AND the log shows Knative/Istio lookup failures: it's the deadlock, continue. → otherwise: it's not this bug, do not force-clear.

2. **Preferred recovery — let the finalizer run properly.** → if the operators aren't yet uninstalled (only `managementState: Removed`): flip Serverless/Service Mesh back to `Managed`, wait for the controllers to come up, then re-issue the delete — it completes normally. → if the operators are already fully uninstalled (CRDs gone): skip to step 3.

   ```sh
   oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{"spec":{"components":{"kserve":{"serving":{"managementState":"Managed"}}}}}'
   oc patch $(oc get dsci -o name | head -n1) --type=merge -p '{"spec":{"serviceMesh":{"managementState":"Managed"}}}'
   # wait for kserve/knative/istio controllers to be Ready, then:
   oc delete isvc "$NAME" -n "$NS"
   ```

   Once every legacy ISVC is deleted, redo the removal steps *in the correct order*.

3. ⚠️ **Fallback recovery — force-clear the finalizer.** Only if the operators are already fully uninstalled and reinstalling them isn't practical. Force-removing the finalizer skips the real cleanup, so any Knative `Service` / Istio `VirtualService` children may be left orphaned — harmless on a cluster where Serverless/Service Mesh are being torn out anyway, but sweep for leftovers (`oc get ksvc,virtualservice -n "$NS"`) if you're not.

   ```sh
   NS=<NAMESPACE>; NAME=<ISVC_NAME>
   oc patch isvc "$NAME" -n "$NS" --type=merge -p '{"metadata":{"finalizers":null}}'
   oc get isvc "$NAME" -n "$NS" 2>/dev/null || echo "deleted"
   ```

   → Expected: `deleted`.

   Batch form for a whole namespace of stuck Serverless ISVCs:

   ```sh
   NS=<NAMESPACE>
   for name in $(oc get isvc -n "$NS" -o json \
     | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name'); do
     echo "force-clearing finalizer on $name"
     oc patch isvc "$name" -n "$NS" --type=merge -p '{"metadata":{"finalizers":null}}'
   done
   ```

   Then recreate each from the backup the conversion script wrote under `/tmp/rhoai-upgrade-backup/model-serving/serverless-to-raw/<ISVC_NAME>/` (or your own export), with `serving.kserve.io/deploymentMode: RawDeployment`.

---

## After

Re-run:

```sh
oc exec -n rhai-migration rhai-cli-0 -- /opt/rhai-cli/bin/rhai-cli lint --target-version 3.3.2 --verbose --checks "*kserve*" --checks "*modelmesh*"
```

→ Expected: all `critical` / `prohibited` rows in this group are gone.

## Why (reference)

> The model serving architecture is evolving to support advanced LLM inference topologies through LLM-d. Neither KServe Serverless nor ModelMesh were designed for the routing and scaling patterns that distributed LLM inference requires. Additionally, KServe Serverless depends on Knative, which is incompatible with OpenShift Service Mesh 3 (embedded in OCP 4.19+).
>
> — architectural-changes.md § *Model Serving: Removal of ModelMesh and KServe Serverless*

> All model serving workloads must be converted to RawDeployment (Standard) mode before the migration. […] Models left unconverted will return HTTP 503 errors after the upgrade.
>
> — architectural-changes.md § *Model Serving Migration*

<!--
maintainer history — IGNORE when running the resolver. Not for the user.

- Serverless conversion helper: earlier revisions of this resolver claimed no helper scripts exist in
  the shipped image — that was wrong. `serverless-to-raw.sh` (and `modelmesh-to-raw.sh`) are the
  official §2.8.7 helpers at /opt/rhai-upgrade-helpers/model-serving/before-upgrade/ inside the
  rhai-cli container. The correct commands stand in the DO THIS blocks above.

- Standalone Authorino uninstall: earlier revisions had the cleanup capture `installedCSV` from the
  standalone Subscription and `oc delete csv` it, on the rationale that RHCL lived in a separate
  namespace (`kuadrant-system`) with its own bundled Authorino CSV. That was only correct when RHCL
  was installed into `kuadrant-system`. The RHCL v1.3.3 install-mode requirement (AllNamespaces /
  `openshift-operators` — see llm-isvc.md § Install Red Hat Connectivity Link) shares the CSV with
  the standalone install. The current DO THIS drops the CSV delete (Subscription-only) to avoid
  breaking RHCL.
-->
