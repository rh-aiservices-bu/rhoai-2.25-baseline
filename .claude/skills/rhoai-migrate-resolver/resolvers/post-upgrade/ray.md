# Resolver — Ray Training Operator (post-upgrade)

*Covers migration guide §4.8 — citation only; user-facing label is `[ray]`.*

Run the Ray cluster migration to bring each RayCluster over to 3.x KubeRay controller conventions (Gateway API routes, no CodeFlare dependency).

## Why

> The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.
>
> — architectural-changes.md § *Training: Removal of Codeflare Operator*

The 2.x RayClusters carry CodeFlare-specific config and Route-based dashboard exposure. 3.x needs KubeRay-only config and Gateway API dashboard routing. The migration rewrites each CR in place, which causes a brief RayCluster restart per cluster.

## Prerequisites

- **WARNING:** complete the Workbenches resolver first. Running the Ray migration before workbench controllers are reconciled produces inconsistent owner-references.
- **Gateway API must be up** (migration guide §4.8 prerequisite). The 3.x Ray dashboard is exposed through Gateway API HTTPRoutes, so the cluster's GatewayConfig has to be `Ready` before you migrate — otherwise the migrated dashboard URL won't resolve. Confirm:
  ```
  oc get gatewayconfig default-gateway --all-namespaces -o wide
  # Expect: READY True
  ```
  If it is not Ready, resolve that first (see [post-upgrade/operator.md § GatewayConfig stuck "Not Ready"](operator.md)).
- You are inside the rhai-cli pod or can exec into it.

## Preview with --dry-run first

There is no separate `list` subcommand — `--dry-run` both reports current state and previews what would change. Always dry-run before committing:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration raycluster.migrate --target-version 3.5.0 --dry-run
```

Expected:

```
=== DRY RUN MODE ===
Name                 Namespace    Status    Workers  Migration Status
----------------------------------------------------------------------
comprehensive-mixed  raytest      ready     2        [NEEDS MIGRATION]
sdk-configurations   raytest      ready     1        [NEEDS MIGRATION]
Summary: 2 to migrate, 0 already migrated
```

A benign `WARNING: migration raycluster.migrate has phase pre-upgrade but effective phase is post-upgrade` may appear — **ignore it**.

### Known quirk — "Migrated: N" but `--dry-run` still says [NEEDS MIGRATION]

If the 2.x install never actually had CodeFlare TLS/OAuth sidecars or a dashboard Route (clean upstream KubeRay CRs), `raycluster.migrate` prints `Migrated: N` in its summary but skips the annotation write, so a follow-up `--dry-run` still shows `[NEEDS MIGRATION]`. Verify by describing the CR — if there is no legacy sidecar/ServiceAccount to remove and pods are all `Running` with `status=ready`, the workload is already 3.x-shaped and safe to leave alone.

## Migrate

Pick the scope — single cluster, namespace, or whole cluster. Note the renamed flags: `--raycluster-cluster` and `--raycluster-namespace` (the old `--cluster` / `--namespace` are gone; `--raycluster-from-backup` replaces `--from-backup`):

```
# Single RayCluster
oc exec -it -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration raycluster.migrate --target-version 3.5.0 \
  --raycluster-cluster <my-cluster> --raycluster-namespace <my-namespace>

# Every cluster in a namespace
oc exec -it -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration raycluster.migrate --target-version 3.5.0 \
  --raycluster-namespace <my-namespace>

# Every RayCluster on the cluster
oc exec -it -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration raycluster.migrate --target-version 3.5.0
```

The action prompts to confirm — answer `yes`. Expect each migrated cluster to restart its head + worker pods.

## Verify

```
# Re-run the dry-run — each cluster should now report "already migrated"
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration raycluster.migrate --target-version 3.5.0 --dry-run

# Clusters back to ready
oc get raycluster -A
# expect: Status=ready, Available Workers matches Desired

# Dashboard route via Gateway API — the action prints URLs at the end;
# allow a moment for HTTPRoutes to propagate
```

## Callouts

- **Downtime** — each RayCluster has a brief pod restart. Plan during a maintenance window or coordinate per-user.
- The migration is idempotent — running it again on already-migrated clusters is safe (prints "already migrated").
- If a cluster fails to come back `ready`, describe the RayCluster and the head pod:
  ```
  oc describe raycluster <name> -n <ns>
  oc describe pod -n <ns> -l ray.io/cluster=<name>,ray.io/node-type=head
  ```
