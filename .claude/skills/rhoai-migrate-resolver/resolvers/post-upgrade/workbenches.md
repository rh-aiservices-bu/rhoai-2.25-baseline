# Resolver — Workbenches (post-upgrade)

*Covers migration guide §4.7 — citation only; user-facing label is `[workbenches]`.*

Patch each stopped workbench to the 3.x auth layer, and handle users who couldn't stop theirs in time.

## Why

> Workbench images left unmigrated continue to operate on the older 2.25.4 authentication layer. This hybrid environment can result in redirection loops and connectivity failures, primarily due to **NB_PREFIX** routing conflicts for RStudio, code-server, and custom images.
>
> — migration guide, Workbenches after upgrade, "Perform a deferred workbench image migration"

The 2→3 auth change (oauth-proxy → kube-rbac-proxy) and Route → Gateway API routing require workbench pods to be started fresh with new env/sidecar config. The helper script patches the Notebook CRs in place; it can only do that safely when the Notebook is Stopped.

## Prerequisite — notebook-controller pods

Confirm both controllers are Ready before running the helper:

```
oc get deployment -n redhat-ods-applications odh-notebook-controller-manager notebook-controller-deployment
# Expect: both 1/1 READY
```

## Patch stopped workbenches

Run the helper inside the rhai-cli container:

```
oc exec -n rhai-migration rhai-cli-0 -- bash -c '
  cd /opt/rhai-upgrade-helpers/workbenches && \
  ./workbench-2.x-to-3.x-upgrade.sh patch --only-stopped --with-cleanup
'
```

Expected final lines:

```
Processed N workbenches: all succeeded.
Cleanup: all N workbenches completed successfully.
```

After this, users can start their workbenches again. Notify them.

## Verify

```
oc exec -n rhai-migration rhai-cli-0 -- bash -c '
  cd /opt/rhai-upgrade-helpers/workbenches && \
  ./workbench-2.x-to-3.x-upgrade.sh list --all
'
# Expect: OK: All workbenches have been migrated.
```

Also ask users to confirm the IDE loads over HTTP/S (common failure is a redirect loop on stale sessions — a browser-side full reload with cleared cookies usually clears it).

## Deferred migration for workbenches that stayed running

Some users couldn't stop theirs during the maintenance window. Those Notebooks still use the 2.x auth layer and will hit redirect loops. Each user must migrate their own workbench post-upgrade:

### User task — pick one of:

1. **Dashboard-driven** — edit the workbench description in the dashboard and save. The dashboard patches the Notebook CR automatically. Guide:
   - Dashboard → Data Science Projects → pick project → Workbenches → Edit → Save
2. **Delete and recreate** — more invasive, but simpler for custom images. Use the **same PVC** to preserve data:
   ```
   NS=<namespace>; NAME=<notebook>
   # Preserve the PVC
   oc get pvc -n "$NS" -l notebook-name="$NAME"
   # Delete the Notebook (pod gets terminated, PVC survives)
   oc delete notebook "$NAME" -n "$NS"
   # Recreate via dashboard — reuse the existing PVC when prompted
   ```

### Image-version reminders

- **Jupyter-based:** bump to 2025.2 (recommended).
- **code-server:** **must** bump to 2025.2. Older tags are broken under 3.x routing.
- **RStudio BuildConfig users:** tag must be `latest`. You also need a **new build** after the upgrade to pick up the Gateway API / kube-rbac-proxy image layers:
  ```
  oc start-build cuda-rstudio-server-rhel9 -n redhat-ods-applications --follow
  oc start-build rstudio-server-rhel9 -n redhat-ods-applications --follow
  ```
- **Custom images ("BYON"):** must be rebuilt for the [Kubernetes Gateway API path-based routing](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/managing_resources/introducing-kubernetes-gateway-api_resource-mgmt) and kube-rbac-proxy. This is a per-owner task — no platform-level fix.

## Callouts

- **Do this resolver before the Ray resolver.** The Ray migration script assumes the workbench controllers are already reconciled against 3.x config. Running Ray first can leave RayClusters in an inconsistent owner-reference state.
- If the helper reports `Failed: N` — do **not** force-start those Notebooks. Inspect each Notebook's events (`oc describe notebook <name> -n <ns>`) and open a support case rather than improvising.
