# Resolver — OpenShift version

**rhai-cli signal:** `service / openshift / version-requirement` with impact `critical` or `prohibited`.

## Why

> OCP Version | **4.19.9 or higher**
>
> — architectural-changes.md § *Platform Prerequisites*

RHOAI 3.3.2 embeds Service Mesh 3 and Gateway API, both of which are only GA on OCP 4.19.9+. The migration guide §1.2 makes this a hard gate — upgrading RHOAI on an older OCP will leave the cluster in a broken state.

## Verify current version

```
oc get clusterversion version -o jsonpath='{.status.desired.version}'; echo
```

## Commands to run

Upgrade the OCP cluster using the standard upgrade path. The OpenShift upgrade channel to use depends on where you are:

```
# Check current channel + update status
oc get clusterversion

# Set a channel that includes 4.19.9 or later (typical channels: stable-4.19, fast-4.19, eus-4.19)
oc adm upgrade channel stable-4.19

# Check available updates
oc adm upgrade

# Apply the upgrade (replace <target> with a version ≥ 4.19.9)
oc adm upgrade --to=<target>
```

If the cluster is on 4.18 or older, plan an incremental upgrade — OCP supports upgrades one minor version at a time. See the [OpenShift Update Policy](https://access.redhat.com/support/policy/updates/openshift) for supported upgrade paths.

## Callouts

- OCP upgrades are themselves disruptive — treat this as a separate maintenance window from the RHOAI migration.
- Do not proceed with any RHOAI migration steps until the OCP upgrade is fully complete (`ClusterVersion` shows `Available=True` and no `Progressing` condition).

## After

Re-run `rhai-cli lint --target-version 3.3.2` to confirm the `version-requirement` check passes.
