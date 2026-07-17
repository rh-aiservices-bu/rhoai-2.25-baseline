# Resolver — Kueue

**rhai-cli signal:** `component / kueue / *` with impact `critical` or `prohibited`.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / `oc annotate` / helper script yourself
> unless the user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs`
> are fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## DO THIS

1. **Gate on the current `kueue.managementState`.** Per migration guide §2.2 the whole procedure
   branches on this value. Read it first — do nothing else until you have it.

   ```sh
   oc get datasciencecluster -A \
     -o jsonpath='{.items[0].spec.components.kueue.managementState}{"\n"}'
   ```

   - → if output is `Removed` or `Unmanaged`: migration is already complete. STOP — skip the rest
     of this resolver, nothing to do.
   - → if output is `Managed`: you have embedded Kueue and **must migrate to Red Hat Build of Kueue
     (RHBoK) first**. The expected end state is `Unmanaged`, **not** `Removed`. ⚠️ Do **NOT** skip
     ahead and patch `managementState` directly to `Removed` — that destroys embedded Kueue without
     installing RHBoK, leaving any Kueue-using workload broken. Continue to Step 2.
   - → if output is empty, `Failed`, or anything else: the DSC is mid-reconcile. Let it settle or
     open a support case before continuing. STOP.

2. **Preserve your queue frameworks (required if you have workloads).** Annotate the embedded Kueue
   config map before the migration so the framework list survives into RHBoK. Without this, the
   enabled-framework list narrows (see Notes) — you almost certainly want the broader set.

   ```sh
   oc annotate configmap kueue-manager-config -n redhat-ods-applications \
     opendatahub.io/managed=false --overwrite
   ```
   → Expected: `configmap/kueue-manager-config annotated`.

3. **Run the official RHBoK migration procedure.** Follow
   [Migrating to the Red Hat build of Kueue Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html/managing_openshift_ai/managing-workloads-with-kueue#migrating-to-the-rhbok-operator_kueue).
   → **Important** (guide §2.2 step 4): do **NOT** follow the "Next steps" section in the Operator
   migration guide. Return to this resolver after completing the operator migration steps, then run
   the Verify block below.

4. **Do NOT patch `kueue.managementState` to `Removed` after RHBoK migration.** ⚠️ `Unmanaged` is the
   documented end state — `Removed` would tell the RHOAI operator to tear down resources RHBoK is now
   managing. Confirm the end state with Verify.

## Verify (read-only)

Expected end state after RHBoK migration:

```sh
oc get datasciencecluster -A \
  -o jsonpath='{.items[0].spec.components.kueue.managementState}{"\n"}{.items[0].status.conditions[?(@.type=="KueueReady")].status}{"\n"}'
```

Expected output:

```
Unmanaged
True
```

`Unmanaged` plus `KueueReady=True` means the lint blocker is cleared and the cluster is upgrade-ready.

Then re-run the lint check to confirm it passes:

```sh
rhai-cli lint --target-version 3.3.2 --checks "*kueue*"
```
→ Expected: the kueue check reports passing.

## Why (reference)

> **Critical:** The Kueue component management state must be set to "Removed" *before* upgrading. Leaving it as "Managed" causes **unrecoverable cluster instability**.
>
> — architectural-changes.md § *Workload Scheduling: Kueue Transition*

RHOAI 2.25 deprecated the embedded Kueue distribution; RHOAI 3.3 removes it. The failure mode if Kueue is left `Managed` at upgrade time is **cluster-wide, not RHOAI-scoped**: the Kueue admission webhook intercepts Job creation across every namespace. During the OLM-managed operator upgrade, the running webhook server and the new Kueue CRDs fall out of schema-version sync, and the webhook then rejects or mangles Job submissions for any workload on the cluster — RHOAI or otherwise. That includes OLM bundle unpacks, image builds, CronJobs, and other tenants' batch workloads. The only documented recovery once this is in progress is an etcd restore (see [BACKUP-RESTORE.md](../../../../BACKUP-RESTORE.md) Scenario B). After migration, Kueue features can be re-enabled via the **Red Hat Build of Kueue** (RHBoK) operator — but that's a post-upgrade step.

**Upstream fix tracking:** RHOAIENG-48690 (root cause — Closed), RHOAIENG-52872 (webhook fix re-enable — Unassigned at the time of writing), RHAISTRAT-1711 (overall strategy: 2.25.x webhook backport + 3.5 top-level Kueue integration for InferenceService / LLMInferenceService / Notebooks). Until the 2.25.x backport ships, the manual `Removed`/`Unmanaged` step above is the only safeguard.

## Notes & edge cases (reference)

- **Framework list preserved by Step 2.** The guide explicitly warns that without the
  `opendatahub.io/managed=false` annotation the enabled-framework list changes — `batch/job`,
  `kubeflow.org/{mpi,pytorch,tf,xgboost,paddle}job`, `ray.io/{raycluster,rayjob}`,
  `jobset.x-k8s.io/jobset`, `workload.codeflare.dev/appwrapper` get replaced with the smaller default
  set `Deployment`, `Pod`, `PyTorchJob`, `RayCluster`, `RayJob`, `StatefulSet`. Annotate first.

- **The `Managed → Unmanaged` transition stalls.** Known issue (RHOAIENG-61489). Confirm the DSC
  `KueueReady` condition has settled before installing RHBoK. If `Unmanaged` won't complete, open a
  support case — don't proceed.

- **The cluster has *external* RHBoK already, with `kueue.managementState: Removed` in the DSC.**
  Nothing to do — you're already past the migration.

- **The cluster has *no* Kueue users.** Going from `Managed` straight to `Removed` (skipping RHBoK
  install) is technically possible *if* no workload depends on Kueue. Verify with the following first
  — any output means there are real users and you must install RHBoK:

  ```sh
  oc get -A workloads.kueue.x-k8s.io,localqueues.kueue.x-k8s.io,clusterqueues.kueue.x-k8s.io 2>/dev/null
  ```
  → Expected: empty output means no Kueue users; any rows mean install RHBoK.

<!--
maintainer history — IGNORE when running the resolver. Not for the user.
No crossed-out commands recorded for this resolver. The live path above is the current correct
procedure: for Managed clusters the end state is Unmanaged (via RHBoK), never Removed.
-->
