# Resolver — OpenShift version

**rhai-cli signal:** `service / openshift / version-requirement` with impact `critical` or `prohibited`.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc adm upgrade` / `oc adm upgrade channel` yourself unless the user explicitly said "run it"
> for THIS resolver. Read-only `oc get`/`oc adm upgrade` (no args) are fine. Work one step at a
> time — after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<TARGET_VERSION>` | an OCP version ≥ 4.19.9 that is offered as an available update | `oc adm upgrade` (lists available target versions) |

## DO THIS

1. Check the current version and channel / update status (read-only).

   ```sh
   oc get clusterversion version -o jsonpath='{.status.desired.version}'; echo
   oc get clusterversion
   ```

   → if already ≥ 4.19.9: nothing to do — skip to Verify.
   → if on 4.18 or older: plan an incremental upgrade — OCP supports upgrades one minor version at a time. See the [OpenShift Update Policy](https://access.redhat.com/support/policy/updates/openshift) for supported upgrade paths.

2. Set a channel that includes 4.19.9 or later (typical channels: `stable-4.19`, `fast-4.19`, `eus-4.19`).

   ```sh
   oc adm upgrade channel stable-4.19
   ```

3. List the available updates (read-only) and pick `<TARGET_VERSION>` ≥ 4.19.9 from the output.

   ```sh
   oc adm upgrade
   ```

4. ⚠️ Disruptive — OCP upgrades reboot nodes; treat this as a separate maintenance window from the RHOAI migration. Apply the upgrade.

   ```sh
   oc adm upgrade --to=<TARGET_VERSION>
   ```

## Verify (read-only)

Do not proceed with any RHOAI migration steps until the OCP upgrade is fully complete.

```sh
oc get clusterversion version -o jsonpath='{.status.desired.version}'; echo
oc get clusterversion
```

→ Expected: desired version ≥ 4.19.9, `ClusterVersion` shows `Available=True` and no `Progressing` condition.

Then re-run `rhai-cli lint --target-version 3.3.2` to confirm the `version-requirement` check passes.

## Why (reference)

> OCP Version | **4.19.9 or higher**
>
> — architectural-changes.md § *Platform Prerequisites*

RHOAI 3.3.2 embeds Service Mesh 3 and Gateway API, both of which are only GA on OCP 4.19.9+. The migration guide §1.2 makes this a hard gate — upgrading RHOAI on an older OCP will leave the cluster in a broken state.

## Notes & edge cases (reference)

- OCP upgrades are themselves disruptive — treat this as a separate maintenance window from the RHOAI migration.
- Do not proceed with any RHOAI migration steps until the OCP upgrade is fully complete (`ClusterVersion` shows `Available=True` and no `Progressing` condition).
