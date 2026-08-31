# Resolver — Kueue

**rhai-cli signal:** `component / kueue / *` with impact `critical` or `prohibited`.

## Why

> **Critical:** Before upgrading, the Kueue component management state must be **`Removed`** or **`Unmanaged`** (external Red Hat build of Kueue). `Managed` is accepted by OLM for backwards compatibility but **rejected at runtime in 3.5** — leaving it `Managed` blocks the DSC from reaching Ready and can cause cluster-wide workload-admission failures during the operator upgrade.
>
> — architectural-changes.md § *Workload Scheduling: Kueue Transition*

RHOAI 2.25 deprecated the embedded Kueue distribution; RHOAI 3.5 no longer ships it as a `Managed` component. The failure mode if Kueue is left `Managed` at upgrade time is **cluster-wide, not RHOAI-scoped**: the Kueue admission webhook intercepts Job creation across every namespace. During the OLM-managed operator upgrade, the running webhook server and the new Kueue CRDs fall out of schema-version sync, and the webhook then rejects or mangles Job submissions for any workload on the cluster — RHOAI or otherwise. That includes OLM bundle unpacks, image builds, CronJobs, and other tenants' batch workloads. The only documented recovery once this is in progress is an etcd restore (see [BACKUP-RESTORE.md](../../../../BACKUP-RESTORE.md) Scenario B).

**Two supported end states in 3.5:**

- **`Removed`** — Kueue is disabled entirely. Choose this if nothing on the cluster uses Kueue.
- **`Unmanaged`** — RHOAI defers to an **externally installed Red Hat build of Kueue (RHBOK)** operator. Choose this to keep Kueue features; it also underpins the top-level 3.5 Kueue integration for InferenceService / LLMInferenceService / Notebooks.

**Upstream fix tracking:** RHOAIENG-48690 (root cause — Closed), RHOAIENG-52872 (webhook fix re-enable), RHAISTRAT-1711 (overall strategy: 2.25.x webhook backport + 3.5 top-level Kueue integration for InferenceService / LLMInferenceService / Notebooks).

## Step 0 — gate on prior `managementState`

Per migration guide §2.2, the procedure branches on the current `kueue.managementState`. Read it first:

```
oc get datasciencecluster -A \
  -o jsonpath='{.items[0].spec.components.kueue.managementState}{"\n"}'
```

Branches:

- **`Removed`** or **`Unmanaged`** → already at a supported end state; the lint blocker is cleared. Skip the rest of this resolver. (If `Unmanaged`, confirm RHBOK is actually installed — see *Verify* below.)
- **`Managed`** → you must move to `Removed` **or** `Unmanaged` before upgrade. Decide based on whether any workload uses Kueue:
  - No Kueue users → **Path A — Removed** is simplest.
  - Kueue users present → **Path B — Unmanaged via RHBOK** preserves scheduling. Do **not** patch straight to `Removed` if workloads depend on Kueue — that destroys queues without a replacement, leaving those workloads broken.
  - Check with: `oc get -A workloads.kueue.x-k8s.io,localqueues.kueue.x-k8s.io,clusterqueues.kueue.x-k8s.io 2>/dev/null` — any output means there are real users.
- Anything else (empty / `Failed`) → DSC is mid-reconcile; let it settle or open a support case before continuing.

## Path A — Removed (disable Kueue)

Only when nothing on the cluster uses Kueue. This tears down the embedded Kueue and disables the component:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge \
  -p '{"spec":{"components":{"kueue":{"managementState":"Removed"}}}}'
```

Note: with Kueue `Removed`, the DSC `KueueReady` condition stays `False` after upgrade — this is expected, not a failure. The JobSet operator installed during the upgrade only flips `KueueReady=True` when Kueue is active.

## Path B — Unmanaged via Red Hat build of Kueue (RHBOK)

### Install / operate the RHBOK operator first

`Unmanaged` tells RHOAI to defer to an externally installed RHBOK operator, so **RHBOK must be installed and operational before** you set the DSC to `Unmanaged`. Two ways to get there:

- **Automated:** run the `rhai-cli` Kueue→RHBOK migration action ("Migrate Kueue to Red Hat build of Kueue" in the *rhai-cli migrate actions* table, guide §1.3.2). It installs/configures RHBOK and hands off the embedded Kueue configuration.
- **Manual:** follow [Migrating to the Red Hat build of Kueue Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html/managing_openshift_ai/managing-workloads-with-kueue#migrating-to-the-rhbok-operator_kueue).

> **Important** (from guide §2.2): do **not** follow the "Next steps" section in the Operator migration guide. Return to this resolver after completing the operator migration steps.

### Preserve your queue frameworks (required if you have workloads)

Annotate the embedded Kueue config map before the migration so the framework list survives into RHBOK:

```
oc annotate $(oc get configmap kueue-manager-config -n redhat-ods-applications -o name) \
  -n redhat-ods-applications opendatahub.io/managed=false --overwrite
```

The guide explicitly warns that without this annotation the enabled-framework list changes — `batch/job`, `kubeflow.org/{mpi,pytorch,tf,xgboost,paddle}job`, `ray.io/{raycluster,rayjob}`, `jobset.x-k8s.io/jobset`, `workload.codeflare.dev/appwrapper` get replaced with the smaller default set `Deployment`, `Pod`, `PyTorchJob`, `RayCluster`, `RayJob`, `StatefulSet`. Annotate first; you almost certainly want the broader set.

### Rename any LocalQueue named `default`

RHBOK **reserves the LocalQueue name `default`**. If you have an existing LocalQueue named `default`, rename it (e.g. to `rhoai-kueue-default`) before enabling RHBOK, or admission breaks. Find them:

```
oc get localqueues.kueue.x-k8s.io -A --field-selector=metadata.name=default
```

LocalQueue names are immutable, so rename via backup-and-recreate: export the CR, change `metadata.name`, strip server-managed fields (`resourceVersion`, `uid`, `creationTimestamp`, `generation`, `managedFields`, `status`), re-apply under the new name, then delete the old one, and repoint any workload `kueue.x-k8s.io/queue-name` annotations at the new name.

### Set the DSC to Unmanaged

Once RHBOK is running:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": {
    "components": {
      "kueue": {
        "managementState": "Unmanaged"
      }
    }
  }
}'
```

Optionally set `defaultClusterQueueName` / `defaultLocalQueueName` to have RHBOK auto-provision default queues (omit both to accept RHBOK defaults):

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": {
    "components": {
      "kueue": {
        "managementState": "Unmanaged",
        "defaultClusterQueueName": "rhoai-kueue-default",
        "defaultLocalQueueName": "rhoai-kueue-default"
      }
    }
  }
}'
```

### Label Kueue project namespaces

RHBOK gates admission per namespace. Label every namespace that runs Kueue-managed workloads:

```
oc label namespace <ns> kueue.openshift.io/managed=true --overwrite
```

**Warning:** on a labeled namespace, these kinds are **rejected at admission unless they carry the `kueue.x-k8s.io/queue-name` annotation** pointing at a valid LocalQueue:

- `pytorchjob`
- `notebook`
- `rayjob`
- `raycluster`
- `inferenceservice`
- `llminferenceservice`

Annotate each such workload before (or immediately as) you label the namespace, e.g.:

```
oc annotate $(oc get notebook <name> -n <ns> -o name) -n <ns> \
  kueue.x-k8s.io/queue-name=<localqueue> --overwrite
```

Label the namespace only after its workloads carry the annotation, or existing workloads fail re-admission.

### Verify

```
oc get datasciencecluster -A \
  -o jsonpath='{.items[0].spec.components.kueue.managementState}{"\n"}'
```

Expected: `Unmanaged`. Confirm the RHBOK operator is installed and running:

```
oc get csv -A | grep -i kueue
```

Then re-run the migration assessment — **Kueue must have no critical findings**. Data-integrity findings (e.g. a workload on a labeled namespace missing the `kueue.x-k8s.io/queue-name` annotation) come back as **advisory warnings**, not blockers; clear them by annotating the workloads as above.

> **Do NOT patch `kueue.managementState` to `Removed` after RHBOK migration.** `Unmanaged` is the documented end state — `Removed` would tell the RHOAI operator to tear down resources RHBOK is now managing.

## Edge cases

- **The cluster already has external RHBOK with `kueue.managementState: Unmanaged` (or `Removed`).** Nothing to do — you're at a supported end state.
- **The `Managed → Unmanaged` transition stalls.** Known issue (RHOAIENG-61489). Confirm the DSC `KueueReady` condition has settled after installing RHBOK. If `Unmanaged` won't complete, open a support case — don't proceed.
- **JobSet dependency.** During the upgrade the guide has you install the JobSet operator (a Kueue dependency). With Kueue `Unmanaged`, `KueueReady` reaches `True` once JobSet is installed; with Kueue `Removed`, `KueueReady` stays `False` by design.

## After

Re-run `rhai-cli lint --target-version 3.5 --checks "*kueue*"` to confirm the check passes (no critical/prohibited findings).
