# Resolver — Kueue

**rhai-cli signal:** `component / kueue / *` with impact `critical` or `prohibited`.

## Why

> **Critical:** The Kueue component management state must be set to "Removed" *before* upgrading. Leaving it as "Managed" causes **unrecoverable cluster instability**.
>
> — architectural-changes.md § *Workload Scheduling: Kueue Transition*

RHOAI 2.25 deprecated the embedded Kueue distribution; RHOAI 3.3 removes it. If the DSC still manages the old Kueue at upgrade time, the RHOAI operator reconciler loops fighting against resources the new stack expects, corrupting the DSC status. After migration, Kueue features can be re-enabled via the **Red Hat Build of Kueue** (RHBoK) operator — but that's a post-upgrade step.

## Preserve your queue frameworks (optional but recommended)

If you have workloads using Kueue and want the framework list to survive into RHBoK post-upgrade, annotate the config map before flipping management state:

```
oc annotate configmap kueue-manager-config -n redhat-ods-applications \
  opendatahub.io/managed=false --overwrite
```

This tells the RHOAI operator not to purge the `kueue-manager-config` ConfigMap when Kueue becomes `Removed`.

## Commands to run

Set `kueue.managementState` to `Removed` on the DSC:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "kueue": { "managementState": "Removed" } } }
}'
```

> Note: `oc get dsc -o name` already returns `datasciencecluster.datasciencecluster.opendatahub.io/<name>`, so the `dsc` argument is omitted from `oc patch` to avoid "there is no need to specify a resource type as a separate argument when passing arguments in resource/name form".

## Verify

```
# spec should say Removed
oc get dsc -o jsonpath='{.items[0].spec.components.kueue.managementState}'; echo

# status should confirm (KueueReady=True means Removed handled cleanly; False with reason Removed is also OK)
oc get dsc -o jsonpath='{range .items[0].status.conditions[?(@.type=="KueueReady")]}{.status} {.reason}{"\n"}{end}'

# kueue pods gone from redhat-ods-applications
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=kueue
```

## Callouts

- **Do not** skip directly to uninstalling the Red Hat Build of Kueue if you have it installed separately — that's for external users. The `Removed` state above handles only the RHOAI-embedded Kueue.
- If you had embedded Kueue (`Managed`), migrating to the external Red Hat Build of Kueue is a separate pre-migration step and involves switching `managementState` to `Unmanaged` first, installing the external operator, then setting `Removed`. See migration guide §2.2 for the exact sequence.

## After

Re-run `rhai-cli lint --target-version 3.3.2 --checks "*kueue*"` to confirm the check passes.
