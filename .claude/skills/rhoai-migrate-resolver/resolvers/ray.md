# Resolver — Ray / CodeFlare

**rhai-cli signal:** `component / ray / *` or `component / codeflare / *`.

> **CodeFlare flips to `Removed`, not Ray.** Earlier revisions of this resolver patched **both** `codeflare` and `ray` to `Removed`. That was wrong — flipping `ray` to `Removed` tears down KubeRay, which is the controller that continues to manage RayClusters in 3.x. Only `codeflare` goes to `Removed`. Do **not** touch `ray`.

In 3.5, CodeFlare must be set to `Removed` **manually, before** the RayCluster backup runs — the `raycluster.backup` action **fails if CodeFlare is still `Managed`**. Per migration guide §2.9:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge \
  -p '{"spec":{"components":{"codeflare":{"managementState":"Removed"}}}}'
```

(Old behavior: the retired `ray_cluster_migration.py pre-upgrade` helper set this automatically as a side effect. In 3.5 the helper is gone and the `rhai-cli` action does **not** touch the DSC — you must patch CodeFlare yourself first, even if you have no RayClusters.)

## Why

> The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.
>
> — architectural-changes.md § *Training: Removal of Codeflare Operator*

RHOAI 2.x used CodeFlare to wrap Ray; 3.x drops CodeFlare entirely. KubeRay continues to manage Ray clusters directly. RayCluster CRs survive the upgrade intact, but you should back up each RayCluster YAML first in case reconciliation loses fields during the controller swap.

## Back up all RayCluster YAMLs

Preconditions: CodeFlare is `Removed` (above), and cert-manager is installed. The `raycluster.backup` action pre-checks both and fails fast otherwise. Create the backup subdirectory first, then run the action:

```
oc exec -n rhai-migration rhai-cli-0 -- mkdir -p /tmp/rhoai-upgrade-backup/ray_cluster

oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run --migration raycluster.backup \
  --target-version 3.5.0 --raycluster-output-dir /tmp/rhoai-upgrade-backup/ray_cluster
```

This:

- Writes each RayCluster CR under the directory passed via `--raycluster-output-dir` (`/tmp/rhoai-upgrade-backup/ray_cluster/`, which lives on the rhai-cli PVC).
- Runs pre-checks and **fails fast if CodeFlare is still `Managed`** or if the cert-manager CRD is absent.
- Does **not** modify the DSC. Unlike the retired Python helper, it does not set `codeflare.managementState` — that is the manual precondition above.

**RBAC:** the action checks additional ClusterRole rules the rhai-cli service account needs — `routes` (`get`), `datascienceclusters` (`list`), and `selfsubjectaccessreviews` (`create`). If the backup fails a permission pre-check, add these rules to the rhai-cli ClusterRole.

To enumerate RayClusters (the old script's `list` "Migration Status" table is gone):

```
oc get rayclusters -A
```

**Callout:** only run this when you're ready to commit to the upgrade. Once CodeFlare is gone, automation that depends on its APIs will break.

## Copy the backup to your workstation

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/ray_cluster ./ray-backup
```

## Verify

```
# CodeFlare subscription should be gone
oc get subscription -A | grep -i codeflare || echo "codeflare uninstalled — good"

# RayClusters still exist, KubeRay managing them
oc get rayclusters -A
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=kuberay-operator
```

## Callouts

- RayJobs/RayServices are managed by the same KubeRay operator; same backup applies.
- User Ray workloads keep running through the controller swap — no pod restarts are triggered by the CodeFlare removal alone.
- **Post-upgrade counterpart:** after the upgrade, finalize with `rhai-cli migrate run --migration raycluster.migrate --target-version 3.5.0 …` (supports `--dry-run`). See the post-upgrade Ray resolver / guide §4.8.
