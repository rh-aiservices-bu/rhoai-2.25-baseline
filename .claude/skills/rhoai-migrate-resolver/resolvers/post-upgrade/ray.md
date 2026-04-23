# Resolver — Ray Training Operator (post-upgrade)

*Covers migration guide §4.8 — citation only; user-facing label is `[ray]`.*

Run the Ray cluster migration script to bring each RayCluster over to 3.x KubeRay controller conventions (Gateway API routes, no CodeFlare dependency).

## Why

> The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.
>
> — architectural-changes.md § *Training: Removal of Codeflare Operator*

The 2.x RayClusters carry CodeFlare-specific config and Route-based dashboard exposure. 3.x needs KubeRay-only config and Gateway API dashboard routing. The migration script rewrites each CR in place, which causes a brief RayCluster restart per cluster.

## Prerequisites

- **WARNING:** complete the Workbenches resolver first. Running the Ray migration before workbench controllers are reconciled produces inconsistent owner-references.
- You are inside the rhai-cli pod or can exec into it.

## List current state

```
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list
```

Expected:

```
RayCluster Migration Status:
Name                 Namespace    Status    Workers  Migration Status
----------------------------------------------------------------------
comprehensive-mixed  raytest      ready     2        [NEEDS MIGRATION]
sdk-configurations   raytest      ready     1        [NEEDS MIGRATION]
Migration Summary: 0 migrated, 2 need migration
```

## Preview with --dry-run first

Always dry-run before committing:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade --dry-run
```

## Migrate

Pick the scope — single cluster, namespace, or whole cluster:

```
# Single RayCluster
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade \
  --cluster <my-cluster> --namespace <my-namespace>

# Every cluster in a namespace
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade \
  --namespace <my-namespace>

# Every RayCluster on the cluster
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py post-upgrade
```

The script prompts `Proceed with migration? (yes/no):` — answer `yes`. Expect each migrated cluster to restart its head + worker pods.

## Verify

```
# Migration status should show "migrated" for each cluster
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list

# Clusters back to ready
oc get raycluster -A
# expect: Status=ready, Available Workers matches Desired

# Dashboard route via Gateway API — the script prints URLs at the end;
# allow a moment for HTTPRoutes to propagate
```

## Callouts

- **Downtime** — each RayCluster has a brief pod restart. Plan during a maintenance window or coordinate per-user.
- The script is idempotent — running it again on already-migrated clusters is safe (prints "already migrated").
- If a cluster fails to come back `ready`, describe the RayCluster and the head pod:
  ```
  oc describe raycluster <name> -n <ns>
  oc describe pod -n <ns> -l ray.io/cluster=<name>,ray.io/node-type=head
  ```
