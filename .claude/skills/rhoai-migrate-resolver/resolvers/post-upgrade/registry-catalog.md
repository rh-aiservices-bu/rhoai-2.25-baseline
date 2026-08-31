# Resolver — AI Hub Registry + Catalog (post-upgrade)

*Covers migration guide §4.2 — citation only; user-facing label is `[registry]`.*

## Why

In 2.x the dashboard nav was **Models → Model registry** and **Models → Model catalog**. In 3.5 it moved to **AI hub → Model registry** and **AI hub → Models** (the old **AI hub → Catalog** item), and registry configuration lives under **Settings → … → Model registry settings** (formerly *AI registry settings*). The underlying pods are the same, but the catalog side now runs **two** pods (`model-catalog` + `model-catalog-postgres`) instead of one — if the second is missing, the catalog UI won't load.

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

1. **Settings → Model resources and operations → Model registry settings** — each registry must show **Available**. (Renamed from *AI registry settings* at 3.5 — migration guide §4.2.)
2. **AI hub → Model registry** — registries display correctly; models previously registered are listed.
3. **AI hub → Models** — default catalog + any custom catalogs display correctly. (The old **AI hub → Catalog** nav item is **AI hub → Models** at 3.5 — migration guide §4.2.)

## ModelRegistry depends on the Data Science Gateway (3.5)

In 3.5 ModelRegistry is provisioned through the new **Data Science Gateway** — it needs the gateway to be Ready with a resolved domain before a registry can compute its endpoint. If a registry never becomes **Available** (or the DSC reports `ProvisioningFailed: modelregistry`), the root cause is usually a gateway that has no domain:

```
oc get gatewayconfig default-gateway -o jsonpath='phase={.status.phase}  domain={.status.domain}{"\n"}'
oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

If the gateway is not Ready / has no domain (commonly because **leftover Service Mesh 2 Istio CRDs** block the OCP Gateway API control plane from installing its `networking.istio.io/v1` CRDs), fix the gateway first — see the Data Science Gateway gotcha in [operator.md](operator.md). ModelRegistry recovers on its own once the gateway reaches Ready.

## Tell users about the nav change

Users will otherwise search "Model registry" and not find it. Surface the new path (**AI hub → Model registry** / **AI hub → Models**, **Settings → … → Model registry settings**) in whatever internal docs/chat you use.

## Callouts

- **Disk pressure risk** — the new `model-catalog-postgres` pod creates a new PVC. Check `oc get pvc -n rhoai-model-registries` and confirm the default StorageClass had room for a fresh bind.
- 2.x registry clients (UI, SDK) that hardcoded the old Route URL will fail. Update to the Gateway-based URL from `oc get gatewayconfigs -A`.
