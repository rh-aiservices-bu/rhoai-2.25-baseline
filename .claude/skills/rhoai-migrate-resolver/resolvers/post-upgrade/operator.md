# Resolver — OpenShift AI Operator (post-upgrade)

*Covers migration guide §4.1 — citation only; user-facing label is `[operator]`.*

Verify the 3.3.2 operator, DSC/DSCI, pods, and Gateway. Covers the platform-level health check that every other post-upgrade task assumes is green.

## Why

The 2.25.4 operator and 3.3.2 operator have fundamentally different reconcile models — chapter 3's in-place upgrade uninstalls the old CSV and installs the new one in the same namespace. If the DSC is not `Ready` after the upgrade, every other component resolver will hit transient failures as the operator replays its reconcile loop. Validate the operator first, then move on.

Kueue and OSSM3 get a specific callout below because both are known to block the operator from reaching `Ready` if the pre-upgrade step was skipped.

## Verify

```
# Operator + CSV
oc get csv -n redhat-ods-operator -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,DISPLAY:.spec.displayName'
# expect: rhods-operator.3.3.2, Succeeded. No rhods-operator.2.* CSV should remain.

# DSC + DSCI phases — both Ready
oc get dsc -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'
oc get dsci -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'

# Operator-namespace pods
oc get pods -n redhat-ods-operator -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,STATUS:.status.phase'

# Applications-namespace pods
oc get pods -n redhat-ods-applications -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,STATUS:.status.phase'

# Gateway API readiness (3.x routes via Gateway API, not Routes)
oc get gatewayconfigs --all-namespaces -o wide
# expect: default-gateway READY=True
```

## Kueue recovery (if pre-upgrade Kueue step was skipped)

If `KueueReady=False` with message `Kueue managementState Managed is not supported, please use Removed or Unmanaged`:

```
oc get dsc -o jsonpath='{.items[0].status.conditions[?(@.type=="KueueReady")].status}{"\n"}{.items[0].status.conditions[?(@.type=="KueueReady")].message}{"\n"}'
```

Recover by flipping Kueue to `Removed` post-upgrade — same patch as in the pre-upgrade resolver:

```
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "kueue": { "managementState": "Removed" } } }
}'
```

Then verify:

```
oc get dsc -o jsonpath='{range .items[0].status.conditions[?(@.type=="KueueReady")]}{.status} {.reason}{"\n"}{end}'
# expect: True  OR  False Removed
```

Kueue features can be re-enabled post-upgrade via the Red Hat Build of Kueue operator (see architectural-changes.md § *Workload Scheduling: Kueue Transition*) — that's a separate setup step after the migration.

## Disconnected-cluster OSSM3 failure

> After upgrading on a disconnected cluster, the `servicemeshoperator3` subscription can fail, leaving DSCI stuck `<not Ready>` and `data-science-gateway` with `Unknown` status.

This is a known issue with a KB article — do not try to resolve inline:

- Confirm the symptom:
  ```
  oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='{.status.state}{"\n"}'
  oc get dsci -o jsonpath='{.items[0].status.phase}{"\n"}'
  oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
  ```
- Follow the KB: [OpenShift Service Mesh 3.x fails to deploy on a disconnected cluster during Red Hat OpenShift AI installation](https://access.redhat.com/solutions/7141146).

## Dashboard URL 404 after upgrade

3.x uses Gateway API — the old 2.x Route URL is gone. Users with bookmarks will get 404. Fix:

1. Get the new dashboard URL:
   ```
   oc get gatewayconfigs -A -o jsonpath='{range .items[*]}{.spec.hostname}{"\n"}{end}'
   ```
2. Communicate the new URL to users. See [Resolving dashboard URL 404 errors after upgrading from 2.x to 3.x](https://access.redhat.com/solutions/7137771) for the redirect option.
