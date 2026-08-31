# Resolver — AI Pipelines (DataSciencePipelinesApplication)

**rhai-cli signal:** `component / datasciencepipelines / *`.

## Why

Pipelines themselves keep running across the 2→3 upgrade, but the DSPA schema changed between 2.25 and 3.x. Deprecated fields (the old `instructLab` block) and legacy v1alpha1 DSPA CRs must be detected before upgrade. Custom RBAC that predates the 2.25 permission refactor also needs review.

No architectural change driver here — this is a schema-deprecation scan (migration guide §2.6).

## Run the pre-upgrade check

The helper scripts are gone in 3.5 — `check_before_upgrade.sh` is now the `ai-pipelines.pre-upgrade-check` migrate action. Run it from your workstation via `oc exec` into the rhai-cli pod; it scans every DSPA in the cluster (all namespaces):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
    --migration ai-pipelines.pre-upgrade-check --target-version 3.5.0
```

It reports one of:

- **OK** → re-run `rhai-cli lint --target-version 3.5` and move on.
- **Warning: deprecated `instructLab` field** → safe to ignore (guide §2.6 says this does not affect the upgrade).
- **Deprecated v1alpha1 DSPA found** → follow the remediation guidance to update each CR (see fallback below).
- **Custom RBAC roles need updates** → run the `ai-pipelines.update-dsp-role` action (next section).

### Save the pre-upgrade baseline snapshot (new in 3.5)

Separately, run the `prepare` variant. It writes a baseline snapshot of the running DSPA pods that the post-upgrade check (`ai-pipelines.post-upgrade-check`) diffs against — so it **must survive the upgrade**:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate prepare \
    --migration ai-pipelines.pre-upgrade-check --target-version 3.5.0
```

This writes `/tmp/rhoai-upgrade-backup/ai_pipelines/dspa_pre_upgrade_pods.json` onto the PVC mounted at `/tmp/rhoai-upgrade-backup` on the rhai-cli pod. **Do not delete the rhai-cli PVC/StatefulSet before the post-upgrade check runs** — deleting it early destroys the baseline and the post-upgrade comparison has nothing to diff against (cleanup of the StatefulSet + `backup-rhai-cli-0` PVC is a Chapter 5 step, *after* post-upgrade). Confirm the file exists:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  ls -l /tmp/rhoai-upgrade-backup/ai_pipelines/dspa_pre_upgrade_pods.json
```

## Update custom RBAC roles via ai-pipelines.update-dsp-role

Only needed if the pre-upgrade check reports **custom RBAC roles needing updates**. If it doesn't report any, skip this section entirely. Per migration guide §2.6, coordinate with the AI Pipelines users, then run the remediation action:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
    --migration ai-pipelines.update-dsp-role --target-version 3.5.0
```

After it completes, re-run `ai-pipelines.pre-upgrade-check` to confirm the issues are gone (guide §2.6).

> Earlier revisions of this resolver included a hand-edited `apiVersion: …/v1` + invented `spec.dspVersion: v2` recipe. That field is not in guide §2.6 and the manual recreate is not the documented path — drop it. The migrate actions do the right thing.

## Patch the DSPA CRD's storedVersions

> **Not in guide §2.6.** This step is operational knowledge from real-cluster runs, not a documented migration step. Use it when the OLM upgrade hits the "new CRD removes version vX that is listed as a stored version" error.

Even after every DSPA *resource* is at `v1`, the CRD itself may still list `v1alpha1` in `.status.storedVersions` — a leftover from the days the cluster did serve v1alpha1. The 3.5 operator's CRD bump refuses to apply when storedVersions includes a removed version (same class of OLM error as `risk of data loss updating "<crd>": new CRD removes version v1alpha1 that is listed as a stored version`).

Check + patch:

```
oc get crd datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io \
  -o jsonpath='{.status.storedVersions}'; echo
# Expected: ["v1"]   — proceed.
# If you see ["v1alpha1","v1"]: patch.

oc patch crd datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io \
  --subresource=status --type=merge -p '{"status":{"storedVersions":["v1"]}}'
```

Only safe to do this once `oc get dspa -A | grep -c v1alpha1` returns `0`.

## ArgoCD-managed roles — advisory only

The `ai-pipelines.pre-upgrade-check` action flags any `Role` / `ClusterRole` granting `update` on `datasciencepipelinesapplications/api` that doesn't match the 3.x role name list. On clusters where DSPA-related roles are deployed by ArgoCD (or any other GitOps tool), you'll see lines like:

```
WARNING: Role pipeline-runner in namespace mlops-prod has unexpected verbs on dspa/api
```

**Don't try to fix these by hand.** Patches you apply will be immediately reverted by ArgoCD's reconciliation. Two valid responses:

1. **Leave them.** The 3.x operator auto-creates the 3.x roles in addition; your old ArgoCD-managed roles continue to work or quietly become no-ops. Confirmed advisory on real clusters with 12+ such roles.
2. **Update the GitOps source-of-truth.** If you'd rather have a clean `ai-pipelines.pre-upgrade-check` run, update the role definitions in your ArgoCD application repo to match the 3.x verb list, then sync.

Either way, this isn't a migration blocker.

## Verify

```
# All DSPAs at apiVersion …/v1
oc get dspa -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,API:.apiVersion'

# ai-pipelines.pre-upgrade-check reports no remaining issues
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run \
    --migration ai-pipelines.pre-upgrade-check --target-version 3.5.0

# the baseline snapshot survived on the PVC (needed by the post-upgrade check)
oc exec -n rhai-migration rhai-cli-0 -- \
  ls -l /tmp/rhoai-upgrade-backup/ai_pipelines/dspa_pre_upgrade_pods.json
```

## Callouts

- Pipelines themselves (runs, Argo workflows) continue across the upgrade — you don't need to stop them. But pipeline *endpoint URLs* change because of the Route → Gateway API shift (architectural-changes.md § *Networking*), so any external CI/CD that triggers pipelines will need URL updates post-upgrade.
- The DSPA's `objectStorage.minio.deploy: true` option still works in 3.x for dev environments, but production-scale DSPAs should plan to migrate to external S3 per Red Hat guidance.
