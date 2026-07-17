# Resolver — Ray / CodeFlare

**rhai-cli signal:** `component / ray / *` or `component / codeflare / *`.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc patch` / `oc exec` / helper script / `oc cp` yourself unless the user explicitly said "run it"
> for THIS resolver. Read-only `oc get`/`describe`/`logs` are fine. Work one blocker at a time —
> after each step, STOP and wait for the user to say "done".

> **Flip `codeflare` to `Removed` — NOT `ray`.** Flipping `ray` to `Removed` tears down KubeRay, the
> controller that continues to manage RayClusters in 3.x. Per migration guide §2.7 the migration sets
> **only** `codeflare.managementState: Removed`. Do not touch `ray`.

## DO THIS

1. **(Optional) Survey RayClusters first, without touching CodeFlare.** Read-only.

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py list
   ```
   Or directly:
   ```sh
   oc get raycluster -A
   ```
   → Expected: a list of RayCluster CRs across namespaces (or none).

2. **Back up all RayCluster YAMLs and set `codeflare` to `Removed`.** ⚠️ Destructive side effect —
   as a reaction the RHOAI operator tears down CodeFlare pods and unsubscribes the operator. Only run
   this when you're ready to commit to the upgrade; once CodeFlare is gone, automation depending on
   its APIs will break. Confirm before running.

   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     python3 /opt/rhai-upgrade-helpers/ray/ray_cluster_migration.py pre-upgrade
   ```

   This:
   - Writes each RayCluster CR to `/tmp/rhoai-upgrade-backup/ray/rhoai-2.x/<ns>_<name>.yaml`
   - Also writes the 3.x-equivalent shape to `/tmp/rhoai-upgrade-backup/ray/rhoai-3.x/<ns>_<name>.yaml`
   - Sets `codeflare.managementState: Removed` on the DataScienceCluster. The helper does *not* call
     `oc delete subscription` or `oc delete csv` directly — the operator tears CodeFlare down as a
     reaction.
   - *Path-case gotcha:* migration guide §2.7 sample output documents these as capitalized
     (`Rhoai-2.x` / `Rhoai-3.x`), but the shipped script writes lowercase. Use lowercase when listing
     or referencing the backup.

3. **Alternative — patch by hand if the helper script isn't available.** ⚠️ Patches ONLY `codeflare`
   to `Removed`; do NOT touch `ray`. (No backup is written by this path — capture RayCluster YAMLs
   yourself if you need them.)

   ```sh
   oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{"spec":{"components":{"codeflare":{"managementState":"Removed"}}}}'
   ```

4. **Copy the backup to your workstation.**

   ```sh
   oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/ray ./ray-backup
   ```
   → Expected: `./ray-backup` populated with the `rhoai-2.x` / `rhoai-3.x` subdirectories.

## Verify (read-only)

```sh
# CodeFlare subscription should be gone
oc get subscription -A | grep -i codeflare || echo "codeflare uninstalled — good"

# RayClusters still exist, KubeRay managing them
oc get raycluster -A
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=kuberay-operator
```

Expected output:

```
codeflare uninstalled — good
```
plus your RayClusters still listed and the `kuberay-operator` pod(s) Running.

## Why (reference)

> The upstream Codeflare project is no longer under active development. KubeRay now handles all Ray cluster management independently.
>
> — architectural-changes.md § *Training: Removal of Codeflare Operator*

RHOAI 2.x used CodeFlare to wrap Ray; 3.x drops CodeFlare entirely. KubeRay continues to manage Ray clusters directly. RayCluster CRs survive the upgrade intact, but you should back up each RayCluster YAML first in case reconciliation loses fields during the controller swap.

## Notes & edge cases (reference)

- RayJobs/RayServices are managed by the same KubeRay operator; same backup applies.
- User Ray workloads keep running through the controller swap — no pod restarts are triggered by the CodeFlare removal alone.

<!--
maintainer history — IGNORE when running the resolver. Not for the user.
- Earlier revisions of this resolver patched **both** `codeflare` and `ray` to `Removed`. That was
  wrong — flipping `ray` to `Removed` tears down KubeRay, which is the controller that continues to
  manage RayClusters in 3.x. The live path now patches ONLY `codeflare` (helper `pre-upgrade`, or the
  hand patch in Step 3). Do not reintroduce a `ray` patch.
- Earlier revisions described the pre-upgrade helper as "uninstalls the CodeFlare Operator
  (destructive side effect)" — that misstated the mechanism. The helper sets
  `codeflare.managementState: Removed`; the RHOAI operator then tears down CodeFlare pods and
  unsubscribes the operator as a reaction. It does not call `oc delete subscription`/`oc delete csv`.
  End result is the same, but the description was corrected.
-->
