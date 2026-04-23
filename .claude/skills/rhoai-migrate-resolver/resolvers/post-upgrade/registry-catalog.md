# Resolver — AI Hub Registry + Catalog (post-upgrade)

*Covers migration guide §4.2 — citation only; user-facing label is `[registry]`.*

## Why

In 2.x the dashboard nav was **Models → Model registry** and **Models → Model catalog**. In 3.x it moved to **AI hub → Registry** and **AI hub → Catalog**. The underlying pods are the same, but the catalog side now runs **two** pods (`model-catalog` + `model-catalog-postgres`) instead of one — if the second is missing, the catalog UI won't load.

Architecturally the change is cosmetic — architectural-changes.md does not call out AI Hub as a structural shift.

## Verify pods

```
oc get pods -n rhoai-model-registries
```

Expected pods (one set per registry instance, plus shared catalog):

- `<my-model-registry>-xxx` — the registry
- `db-<my-model-registry>-xxx` — the registry's PostgreSQL
- `model-catalog-xxx` — the catalog API
- `model-catalog-postgres-xxx` — the catalog's PostgreSQL (new in 3.x)

All should show `Running` with `1/1` or `2/2`.

If a pod is not Running, get its logs:

```
oc logs <my-model-registry-pod> -n rhoai-model-registries -c <container-name>
oc logs <my-model-catalog-pod> -n rhoai-model-registries -c catalog
```

## Verify via dashboard

1. **Settings → Model resources and operations → AI registry settings** — each registry must show **Available**.
2. **AI hub → Model registry** — registries display correctly; models previously registered are listed.
3. **AI hub → Catalog** — default catalog + any custom catalogs display correctly.

## Tell users about the nav change

Users will otherwise search "Model registry" and not find it. Surface the new path (AI hub → Registry/Catalog) in whatever internal docs/chat you use.

## Callouts

- **Disk pressure risk** — the new `model-catalog-postgres` pod creates a new PVC. Check `oc get pvc -n rhoai-model-registries` and confirm the default StorageClass had room for a fresh bind.
- 2.x registry clients (UI, SDK) that hardcoded the old Route URL will fail. Update to the Gateway-based URL from `oc get gatewayconfigs -A`.
