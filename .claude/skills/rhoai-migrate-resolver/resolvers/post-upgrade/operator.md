# Resolver — OpenShift AI Operator (post-upgrade)

*Covers migration guide §4.1 — citation only; user-facing label is `[operator]`.*

**rhai-cli signal:** `post-upgrade-validate.sh` emits `[operator]` (FAIL or TODO). Verify the 3.3.2 operator, DSC/DSCI, pods, and Gateway. Covers the platform-level health check that every other post-upgrade task assumes is green.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / helper script yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

*(No placeholders in this resolver — every command is literal. `redhat-ods-operator`, `redhat-ods-applications`, `openshift-operators`, and `openshift-ingress` are real namespace constants; run them as written.)*

## DO THIS

### Step 1 — Verify operator + platform health (read-only)

This is the core `[operator]` check every other post-upgrade task assumes is green.

```sh
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

→ Expected: CSV `rhods-operator.3.3.2` = `Succeeded`, no `rhods-operator.2.*` CSV remaining; DSC and DSCI both `Ready`; operator- and applications-namespace pods `READY=True`; `default-gateway` `READY=True`.
→ if DSC/DSCI is not Ready and the condition message mentions Kueue: go to **Fix A — Kueue recovery**.
→ if `default-gateway` shows `READY=False`: go to **Fix B — GatewayConfig stuck Not Ready**.
→ if all green: go to Step 2.

### Step 2 — Switch the subscription channel off the migration channel (TODO)

Once the upgrade is complete, the subscription is still on `support-required-upgrade` — the gated migration channel that never advances to 3.3.x z-streams (no ongoing patch updates). Move it to `stable-3.3` so the cluster receives 3.3.x patches normally.

```sh
# Confirm you're on 3.3.2 first
oc get csv -n redhat-ods-operator -o jsonpath='{range .items[?(@.spec.displayName=="Red Hat OpenShift AI")]}{.metadata.name} {.status.phase}{"\n"}{end}'
# expect: rhods-operator.3.3.2 Succeeded

# See which channels the catalog offers (stable-3.3 stays on the 3.3 z-stream;
# stable-3.x / fast-3.x would track forward into 3.4+)
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}  {.currentCSV}{"\n"}{end}'

# Switch to the stable 3.3 channel
oc patch subscription rhods-operator -n redhat-ods-operator --type=merge \
  -p '{"spec":{"channel":"stable-3.3"}}'
```

→ Expected (first command): `rhods-operator.3.3.2 Succeeded` before you patch.

Verify:

```sh
oc get subscription rhods-operator -n redhat-ods-operator \
  -o jsonpath='channel={.spec.channel}  state={.status.state}  installedCSV={.status.installedCSV}{"\n"}'
# expect: channel=stable-3.3  state=AtLatestKnown  installedCSV=rhods-operator.3.3.2
```

→ Expected: `channel=stable-3.3  state=AtLatestKnown  installedCSV=rhods-operator.3.3.2`

> **Channel-planning note.** Keep `installPlanApproval: Manual` if the customer wants to gate future z-stream bumps; flip it to `Automatic` only if they want unattended patching. `stable-3.3` surfaces 3.3.x patch InstallPlans; `stable-3.x` would eventually offer a 3.4 minor upgrade, which is a separate planning decision, not a patch — pick `stable-3.3` unless the customer explicitly wants to ride the latest minor.

## Conditional fixes (triggered by a specific FAIL)

### Fix A — Kueue recovery (if pre-upgrade Kueue step was skipped)

Trigger: `KueueReady=False` with message `Kueue managementState Managed is not supported, please use Removed or Unmanaged`.

Confirm the symptom:

```sh
oc get dsc -o jsonpath='{.items[0].status.conditions[?(@.type=="KueueReady")].status}{"\n"}{.items[0].status.conditions[?(@.type=="KueueReady")].message}{"\n"}'
```

→ if the message matches the trigger above: apply the recovery patch (flip Kueue to `Removed`, same patch as the pre-upgrade resolver). Otherwise this fix does not apply.

```sh
oc patch $(oc get dsc -o name | head -n1) --type=merge -p '{
  "spec": { "components": { "kueue": { "managementState": "Removed" } } }
}'
```

Verify:

```sh
oc get dsc -o jsonpath='{range .items[0].status.conditions[?(@.type=="KueueReady")]}{.status} {.reason}{"\n"}{end}'
# expect: True  OR  False Removed
```

→ Expected: `True` OR `False Removed`.

Note: Kueue features can be re-enabled post-upgrade via the Red Hat Build of Kueue operator (see architectural-changes.md § *Workload Scheduling: Kueue Transition*) — that's a separate setup step after the migration.

### Fix B — GatewayConfig stuck "Not Ready" (NetworkPolicy webhook blocks it)

**Symptom:** post-upgrade, `oc get gatewayconfig default-gateway --all-namespaces -o wide` shows `READY: False`, and the dashboard URL doesn't resolve.

**Cause:** the RHOAI 3.x GatewayConfig reconciler creates a NetworkPolicy in `openshift-ingress` to allow ingress to `data-science-gateway`. On clusters with an SRE-managed admission webhook (typical name: `sre-networkpolicies-validation`) restricting NetworkPolicy creation in `openshift-*` namespaces, that POST is rejected → GatewayConfig sits Not Ready forever.

→ if your cluster has any webhook restricting NetworkPolicy creation in `openshift-*` namespaces: apply the fix below. if you don't run an SRE webhook (most non-managed-OpenShift clusters): the default `networkPolicy.ingress.enabled=true` is fine — you don't need this patch.

**Fix:** disable the operator-managed NetworkPolicy for the GatewayConfig (the SRE webhook's own ingress isolation still applies; you're just opting RHOAI out of writing one too).

```sh
oc patch gatewayconfig default-gateway --type=merge \
  -p '{"spec":{"networkPolicy":{"ingress":{"enabled":false}}}}'
```

Verify:

```sh
oc get gatewayconfig default-gateway -o jsonpath='phase={.status.phase}  ingressMode={.status.ingressMode}{"\n"}'
# expect: phase=Ready  ingressMode=OcpRoute
```

→ Expected: `phase=Ready  ingressMode=OcpRoute`.

### Fix C — Disconnected-cluster OSSM3 failure

> After upgrading on a disconnected cluster, the `servicemeshoperator3` subscription can fail, leaving DSCI stuck `<not Ready>` and `data-science-gateway` with `Unknown` status.

Known issue with a KB article — do not try to resolve inline.

Confirm the symptom (read-only):

```sh
oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='{.status.state}{"\n"}'
oc get dsci -o jsonpath='{.items[0].status.phase}{"\n"}'
oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

→ Expected on a healthy cluster: subscription state `AtLatestKnown`, DSCI phase `Ready`, gateway `Programmed=True`. A failed subscription state / non-Ready DSCI / `Unknown` gateway matches this issue.
→ Follow the KB: [OpenShift Service Mesh 3.x fails to deploy on a disconnected cluster during Red Hat OpenShift AI installation](https://access.redhat.com/solutions/7141146).

### Fix D — Service Mesh Operator 3.4.0 breaks the gateway on OCP 4.19–4.21

> **Do not approve the `servicemeshoperator3` upgrade to 3.4.0.** After the RHOAI migration, OLM parks an "upgrade available" InstallPlan in front of the Service Mesh Operator 3 subscription. Approving it (fresh installs hit this too) breaks the OpenShift Gateway API.

**Symptom:** the `openshift-gateway` Istio resource enters a permanent `ReconcileError`:

```
validation error: version "v1.26.2" is end-of-life and cannot be installed; use a supported version
```

Deleting the resource recreates it with the same error; manually editing the version to a supported one (e.g. `v1.30.1`) is reverted within seconds.

**Cause:** on OCP 4.19–4.21 the `cluster-ingress-operator` **hardcodes** the Gateway API Istio version to `v1.26.2` and continuously reconciles the `openshift-gateway` resource back to it. OSSM **3.4.0** added a validation gate that rejects `v1.26.2` as end-of-life. So the version the ingress operator insists on is the version the mesh operator refuses — and the ingress operator always wins the reconcile race. This is **not** an RHOAI bug and **not** a migration limitation; RHOAI validates against Service Mesh **3.2** and does not require 3.4.0. There is **no supported OSSM downgrade**, so prevention is the only clean path.

**Prevent (recommended):** keep the Service Mesh Operator 3 subscription on `installPlanApproval: Manual` and pin it ≤ 3.3.x — do **not** approve the 3.4.0 InstallPlan until the fix ships.

```sh
# Confirm the installed OSSM3 version and that approval is gated
oc get csv -A -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' | grep servicemeshoperator3
oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='approval={.spec.installPlanApproval} channel={.spec.channel}{"\n"}'
# If an unapproved 3.4.0 InstallPlan is waiting, leave it unapproved:
oc get installplan -n openshift-operators -o custom-columns='NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames[*],APPROVED:.spec.approved'
```

→ Expected: `approval=Manual`; any InstallPlan naming `servicemeshoperator3.v3.4.0` shows `APPROVED=false`. Leave it `false`.
→ if already on 3.4.0: the gateway cannot be repaired in place and OSSM cannot be safely downgraded — this is a restore-from-backup support situation, not an inline patch. ⚠️ Do NOT attempt the `startingCSV` / manual-downgrade workarounds circulating informally; they have broken clusters in testing.

**Tracking:** OSSM-14917 and OCPBUGS-92038 (the actual defect, affecting OCP 4.19/4.20/4.21 — a fixed z-stream, not a minor bump, is the resolution); RHOAIENG-76376 (RHOAI-side doc update). Note the affected-versions list includes 4.21, so "upgrade OCP to 4.21" is **not** a workaround.

### Fix E — Dashboard URL 404 after upgrade (TODO)

3.x uses Gateway API — the old 2.x Route URL is gone. Users with bookmarks will get 404.

1. Get the new dashboard URL:
   ```sh
   oc get gatewayconfigs -A -o jsonpath='{range .items[*]}{.spec.hostname}{"\n"}{end}'
   ```
2. Communicate the new URL to users. See [Resolving dashboard URL 404 errors after upgrading from 2.x to 3.x](https://access.redhat.com/solutions/7137771) for the redirect option.

## Why (reference)

The 2.25.4 operator and 3.3.2 operator have fundamentally different reconcile models — chapter 3's in-place upgrade uninstalls the old CSV and installs the new one in the same namespace. If the DSC is not `Ready` after the upgrade, every other component resolver will hit transient failures as the operator replays its reconcile loop. Validate the operator first, then move on.

Kueue and OSSM3 get a specific callout below because both are known to block the operator from reaching `Ready` if the pre-upgrade step was skipped.

## Notes & edge cases (reference)

- The GatewayConfig NetworkPolicy issue (Fix B) has been observed on multiple managed-OpenShift clusters with SRE-managed admission webhooks. Reproducible enough to call a known issue rather than environment-specific — if your cluster has any webhook restricting NetworkPolicy creation in `openshift-*` namespaces, expect to need this fix.
