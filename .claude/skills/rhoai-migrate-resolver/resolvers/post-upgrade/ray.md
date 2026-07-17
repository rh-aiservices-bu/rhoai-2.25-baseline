# Resolver — Ray Training Operator (post-upgrade)

**rhai-cli signal:** user-facing label is `[ray]`. Covers migration guide §4.8 (citation only). Run the Ray cluster migration script to bring each RayCluster over to 3.x KubeRay controller conventions (Gateway API routes, no CodeFlare dependency).

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / helper script yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<RAY_CLUSTER>` | a RayCluster name | `oc get raycluster -A` |
| `<NAMESPACE>` | the RayCluster's namespace | `oc get raycluster -A` |

## DO THIS

1. **Prerequisite — complete the Workbenches resolver first.** Running the Ray migration before workbench controllers are reconciled produces inconsistent owner-references. Also confirm you are inside the rhai-cli pod or can exec into it. Do not proceed until both are true.

2. List the current migration state.
   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list
   ```
   → Expected: a table like
   ```
   RayCluster Migration Status:
   Name                 Namespace    Status    Workers  Migration Status
   ----------------------------------------------------------------------
   comprehensive-mixed  raytest      ready     2        [NEEDS MIGRATION]
   sdk-configurations   raytest      ready     1        [NEEDS MIGRATION]
   Migration Summary: 0 migrated, 2 need migration
   ```
   → if every cluster already shows migrated: nothing to do, go to Verify.

3. Preview with `--dry-run` before committing. Always dry-run first.
   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade --dry-run
   ```
   → if the summary prints `Migrated: N` but a later `list` still shows `[NEEDS MIGRATION]`: see Notes → "Known quirk". The workload may already be 3.x-shaped and safe to leave alone.

4. ⚠️ Destructive — rewrites each RayCluster CR in place and restarts its head + worker pods. Confirm before running. Pick the scope: single cluster, whole namespace, or whole cluster.
   ```sh
   # Single RayCluster
   oc exec -n rhai-migration rhai-cli-0 -- \
     python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade \
     --cluster <RAY_CLUSTER> --namespace <NAMESPACE>

   # Every cluster in a namespace
   oc exec -n rhai-migration rhai-cli-0 -- \
     python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade \
     --namespace <NAMESPACE>

   # Every RayCluster on the cluster
   oc exec -n rhai-migration rhai-cli-0 -- \
     python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade
   ```
   → The script prompts `Proceed with migration? (yes/no):` — answer `yes`. Expect each migrated cluster to restart its head + worker pods.

## Verify (read-only)

```sh
# Migration status should show "migrated" for each cluster
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list

# Clusters back to ready
oc get raycluster -A
```
→ Expected: `list` shows "migrated" for each cluster; `oc get raycluster -A` shows Status=ready with Available Workers matching Desired.

The migration script prints the Gateway API dashboard route URLs at the end — allow a moment for HTTPRoutes to propagate before hitting them.

## Why (reference)

> The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.
>
> — architectural-changes.md § *Training: Removal of Codeflare Operator*

The 2.x RayClusters carry CodeFlare-specific config and Route-based dashboard exposure. 3.x needs KubeRay-only config and Gateway API dashboard routing. The migration script rewrites each CR in place, which causes a brief RayCluster restart per cluster.

## Notes & edge cases (reference)

- **Known quirk — "Migrated: N" but `list` still says [NEEDS MIGRATION].** If the 2.x install never actually had CodeFlare TLS/OAuth sidecars or a dashboard Route (clean upstream KubeRay CRs), `post-upgrade` prints `Migrated: N` in its summary but skips the annotation write, so `list` still shows `[NEEDS MIGRATION]` afterwards. Verify by describing the CR — if there is no legacy sidecar/ServiceAccount to remove and pods are all `Running` with `status=ready`, the workload is already 3.x-shaped and safe to leave alone.
- **Downtime** — each RayCluster has a brief pod restart. Plan during a maintenance window or coordinate per-user.
- The script is idempotent — running it again on already-migrated clusters is safe (prints "already migrated").
- If a cluster fails to come back `ready`, describe the RayCluster and the head pod:
  ```sh
  oc describe raycluster <RAY_CLUSTER> -n <NAMESPACE>
  oc describe pod -n <NAMESPACE> -l ray.io/cluster=<RAY_CLUSTER>,ray.io/node-type=head
  ```
