# Resolver — Ray / CodeFlare

**rhai-cli signal:** `component / ray / *` or `component / codeflare / *`.

> **Important:** the DSC spec has **two separate components** — `codeflare` and `ray` — even though rhai-cli reports the CodeFlare blocker under the `ray/removal` key. Flip **both** to `Removed`:
>
> ```
> oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{"spec":{"components":{"codeflare":{"managementState":"Removed"},"ray":{"managementState":"Removed"}}}}'
> ```

## Why

> The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.
>
> — architectural-changes.md § *Training: Removal of Codeflare Operator*

RHOAI 2.x used CodeFlare to wrap Ray; 3.x drops CodeFlare entirely. KubeRay continues to manage Ray clusters directly. RayCluster CRs survive the upgrade intact, but:

- The CodeFlare Operator is uninstalled as a side effect of the pre-upgrade helper.
- You should back up each RayCluster YAML first, in case reconciliation loses fields during the controller swap.

## Back up all RayCluster YAMLs

```
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py pre-upgrade
```

This:

- Writes each RayCluster CR to `/tmp/rhoai-upgrade-backup/ray/Rhoai-2.x/<ns>_<name>.yaml`
- Also writes the 3.x-equivalent shape to `/tmp/rhoai-upgrade-backup/ray/Rhoai-3.x/<ns>_<name>.yaml`
- Uninstalls the CodeFlare Operator (destructive side effect)

**Callout:** only run this when you're ready to commit to the upgrade. Removing CodeFlare mid-development will break any automation that depends on its APIs.

To enumerate RayClusters without touching CodeFlare:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list
```

Or directly:

```
oc get raycluster -A
```

## Copy the backup to your workstation

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/ray ./ray-backup
```

## Verify

```
# CodeFlare subscription should be gone
oc get subscription -A | grep -i codeflare || echo "codeflare uninstalled — good"

# RayClusters still exist, KubeRay managing them
oc get raycluster -A
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=kuberay-operator
```

## Callouts

- RayJobs/RayServices are managed by the same KubeRay operator; same backup applies.
- User Ray workloads keep running through the controller swap — no pod restarts are triggered by the CodeFlare removal alone.
