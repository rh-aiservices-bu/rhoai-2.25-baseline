# Resolver — AI Hub Registry + Catalog (post-upgrade)

**rhai-cli signal:** user-facing label is `[registry]`. Covers migration guide §4.2 (citation only). Verify-only — confirm the registry and catalog pods came back after the upgrade and tell users about the dashboard nav change.

> **EMIT — DON'T EXECUTE.** Print these read-only commands for the admin to run; do not run them yourself. Work one step at a time and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<MODEL_REGISTRY_POD>` | a registry pod that is not Running | `oc get pods -n rhoai-model-registries` |
| `<MODEL_CATALOG_POD>` | a catalog pod that is not Running | `oc get pods -n rhoai-model-registries` |
| `<CONTAINER_NAME>` | container inside the failing registry pod | `oc get pod <MODEL_REGISTRY_POD> -n rhoai-model-registries -o jsonpath='{.spec.containers[*].name}'` |

## DO THIS

1. Verify the registry + catalog pods.
   ```sh
   oc get pods -n rhoai-model-registries
   ```
   → Expected pods (one set per registry instance, plus the shared catalog), all `Running` with `1/1` or `2/2`:
   - `<my-model-registry>-xxx` — the registry
   - `db-<my-model-registry>-xxx` — the registry's PostgreSQL
   - `model-catalog-xxx` — the catalog API
   - `model-catalog-postgres-xxx` — the catalog's PostgreSQL (new in 3.x)
   → if a pod is not Running: get its logs (Step 2). Note the catalog now runs **two** pods (`model-catalog` + `model-catalog-postgres`); if the second is missing the catalog UI won't load.

2. If a pod is not Running, get its logs.
   ```sh
   oc logs <MODEL_REGISTRY_POD> -n rhoai-model-registries -c <CONTAINER_NAME>
   oc logs <MODEL_CATALOG_POD> -n rhoai-model-registries -c catalog
   ```

3. Verify via the dashboard (user-driven; hand these to the admin/user):
   1. **Settings → Model resources and operations → AI registry settings** — each registry must show **Available**.
   2. **AI hub → Model registry** — registries display correctly; models previously registered are listed.
   3. **AI hub → Catalog** — default catalog + any custom catalogs display correctly.

4. Tell users about the nav change. In 2.x the path was **Models → Model registry** / **Models → Model catalog**; in 3.x it is **AI hub → Registry** / **AI hub → Catalog**. Users will otherwise search "Model registry" and not find it. Surface the new path in whatever internal docs/chat you use.

## Verify (read-only)

```sh
oc get pods -n rhoai-model-registries
```
→ Expected: all registry, `db-*`, `model-catalog`, and `model-catalog-postgres` pods `Running` (`1/1` or `2/2`). Dashboard shows registries **Available** and catalogs loading under **AI hub**.

## Why (reference)

In 2.x the dashboard nav was **Models → Model registry** and **Models → Model catalog**. In 3.x it moved to **AI hub → Registry** and **AI hub → Catalog**. The underlying pods are the same, but the catalog side now runs **two** pods (`model-catalog` + `model-catalog-postgres`) instead of one — if the second is missing, the catalog UI won't load.

Architecturally the change is cosmetic — architectural-changes.md does not call out AI Hub as a structural shift.

## Notes & edge cases (reference)

- **Disk pressure risk** — the new `model-catalog-postgres` pod creates a new PVC. Check `oc get pvc -n rhoai-model-registries` and confirm the default StorageClass had room for a fresh bind.
- 2.x registry clients (UI, SDK) that hardcoded the old Route URL will fail. Update to the Gateway-based URL from `oc get gatewayconfigs -A`.
