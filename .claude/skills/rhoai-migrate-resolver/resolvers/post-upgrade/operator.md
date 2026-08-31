# Resolver — OpenShift AI Operator (post-upgrade)

*Covers migration guide §4.1 — citation only; user-facing label is `[operator]`.*

Verify the 3.5 operator, DSC/DSCI, pods, and Gateway. Covers the platform-level health check that every other post-upgrade task assumes is green.

## Why

The 2.25.x operator and 3.5 operator have fundamentally different reconcile models — chapter 3's in-place upgrade uninstalls the old CSV and installs the new one in the same namespace. If the DSC is not `Ready` after the upgrade, every other component resolver will hit transient failures as the operator replays its reconcile loop. Validate the operator first, then move on.

Kueue (and its new **JobSet** dependency) and leftover Service Mesh 2 Istio CRDs get specific callouts below because each is known to block the operator from reaching `Ready` after a 2.25→3.5 upgrade.

## Verify

```
# Operator + CSV
oc get csv -n redhat-ods-operator -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,DISPLAY:.spec.displayName'
# expect: rhods-operator.3.5.0, Succeeded. No rhods-operator.2.* CSV should remain.

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

## What the operator handles automatically

On startup, the 3.5 operator performs several migrations that used to be manual admin tasks. **Do not run these by hand** — this callout exists so you recognize them in the reconcile logs (and in a briefly-churning DSC status right after upgrade) and don't try to redo them:

- **HardwareProfile migration** — AcceleratorProfiles are converted to HardwareProfiles, and Notebooks / InferenceServices are annotated to reference them. Create-only: existing HardwareProfile customizations are preserved.
- **GatewayConfig ingressMode preservation** — an existing LoadBalancer ingressMode is carried forward; the operator prevents a regression back to `OcpRoute`.
- **Kueue ValidatingAdmissionPolicyBinding cleanup** — deprecated pre-v2.29 Kueue VAP resources are removed.
- **DSC v1→v2 API conversion** — via the conversion webhook: `datasciencepipelines` → `aipipelines`, and the components removed in 3.5 (`modelmeshserving`, `codeflare`) are dropped from the DSC.

If the DSC shows these components appearing/disappearing in the seconds after the upgrade, that's the auto-conversion settling, not a failure.

## Install the JobSet operator (Kueue dependency)

3.5 makes the **JobSet operator** a mandatory dependency of Kueue. Without it the DSC stays `Not Ready` with `KueueReady=False`. It installs into **its own namespace** with an OwnNamespace OperatorGroup — do **not** install it into `openshift-operators`.

> If the chapter-3 upgrade already installed JobSet, just run the verification block at the end of this section and move on.

```
# 1. Namespace + OwnNamespace OperatorGroup (targetNamespaces = the install namespace)
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: jobset-system
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: jobset-operator-group
  namespace: jobset-system
spec:
  targetNamespaces:
    - jobset-system
EOF

# 2. Subscription — package job-set, channel stable-v1.0, source redhat-operators
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: job-set
  namespace: jobset-system
spec:
  channel: stable-v1.0
  name: job-set
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# 3. Wait for the CSV to succeed
oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/jobset-operator.v1.0.0 -n jobset-system --timeout=5m
```

Then create the `JobSetOperator` CR named `cluster` — this is what installs the `jobsets.jobset.x-k8s.io` CRD:

```
# Confirm the operand CRD's API group first (the CSV ships it), then create the CR named `cluster`
oc get crd -o name | grep -i jobsetoperator

oc apply -f - <<'EOF'
apiVersion: operator.jobset.x-k8s.io/v1alpha1
kind: JobSetOperator
metadata:
  name: cluster
EOF
```

> If `oc get crd` above reports a different API group than `operator.jobset.x-k8s.io`, use that group in the `apiVersion` (run `oc explain jobsetoperator` to confirm the served version).

Verify:

```
oc get csv jobset-operator.v1.0.0 -n jobset-system -o jsonpath='phase={.status.phase}{"\n"}'
# expect: phase=Succeeded

oc get crd jobsets.jobset.x-k8s.io
# expect: the CRD exists

# KueueReady on the DSC
oc get dsc -o jsonpath='{range .items[0].status.conditions[?(@.type=="KueueReady")]}{.status} {.reason}{"\n"}{end}'
```

> **If Kueue was set to `Removed` pre-upgrade**, `KueueReady=False` with reason `Removed` is **expected** — it is not a failure. Install JobSet anyway so Kueue can be re-enabled later (as `Managed`/`Unmanaged`) without a separate operator install. `KueueReady=True` is only expected when Kueue is actively enabled.

## Switch the subscription channel off the migration channel

Once the upgrade is complete (CSV `rhods-operator.3.5.0` Succeeded, DSC + DSCI `Ready`), the subscription is still pointed at `support-required-upgrade-3.5` — the gated channel whose only job is to trigger the cross-major 2.25→3.5 migration. Leaving it there means **no ongoing z-stream updates**: the migration channel doesn't advance to 3.5.1, 3.5.2, etc. **3.5 is GA**, so move the subscription onto the stable 3.5 channel to receive 3.5.x patch releases normally.

```
# Confirm you're on 3.5.0 first
oc get csv -n redhat-ods-operator -o jsonpath='{range .items[?(@.spec.displayName=="Red Hat OpenShift AI")]}{.metadata.name} {.status.phase}{"\n"}{end}'
# expect: rhods-operator.3.5.0 Succeeded

# See which channels the catalog offers (stable-3.5 stays on the 3.5 z-stream;
# stable-3.x / eus-3.5 would track forward into 3.6+)
oc get packagemanifest rhods-operator -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}  {.currentCSV}{"\n"}{end}'

# Switch to the stable 3.5 channel
oc patch subscription rhods-operator -n redhat-ods-operator --type=merge \
  -p '{"spec":{"channel":"stable-3.5"}}'
```

Verify:

```
oc get subscription rhods-operator -n redhat-ods-operator \
  -o jsonpath='channel={.spec.channel}  state={.status.state}  installedCSV={.status.installedCSV}{"\n"}'
# expect: channel=stable-3.5  state=AtLatestKnown  installedCSV=rhods-operator.3.5.0
```

> Keep `installPlanApproval: Manual` if the customer wants to gate future z-stream bumps; flip it to `Automatic` only if they want unattended patching. `stable-3.5` will surface 3.5.x patch InstallPlans; `stable-3.x` would eventually offer a 3.6 minor upgrade, which is a separate planning decision, not a patch — pick `stable-3.5` unless the customer explicitly wants to ride the latest minor.

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

## CRITICAL: Data Science Gateway won't provision — leftover Service Mesh 2 Istio CRDs

**This is the most common post-upgrade DSC blocker on a 2.25→3.5 migration (gap report "Gap 2").** If you uninstalled the Service Mesh 2 operator pre-upgrade, its CRDs were left behind (OLM operator uninstall never removes CRDs), and those stale CRDs shadow the ones the 3.5 Data Science Gateway needs.

**Symptoms (a whole cascade, all from one root cause):**

- DSC stays `Not Ready`: `ProvisioningFailed: modelregistry`.
- `GatewayConfig/default-gateway` error: `failed to lookup … DestinationRule in version "networking.istio.io/v1"`.
- `Gateway/data-science-gateway` (in `openshift-ingress`): `Programmed=False`, listener `Bad TLS configuration`.
- `istiod-openshift-gateway` pod stuck **0/1**; log shows `failed to list *v1.VirtualService: the server could not find the requested resource`.
- `ingress-operator` log: `"Istio CRDs are managed by an unknown party"`.
- ModelRegistry: `failed to compute gateway domain: gateway domain is missing`.

**Root cause:** uninstalling the SM2 operator leaves its Maistra-2.6.17 `*.istio.io` CRDs, which serve only `v1beta1`/`v1alpha3`. On OCP 4.20.31+/4.21.22+/4.22+ the OCP built-in "sail" Istio (the Gateway API provider — **Service Mesh 3 is NOT required** on these OCP versions) needs the `networking.istio.io/v1` CRDs, but it **refuses to overwrite CRDs it doesn't own** (`"managed by an unknown party"`), so it never installs the `v1` versions → gateway never programs → ModelRegistry/DSC never Ready.

**Diagnose:**

```
# Is istiod stuck, and are the CRDs Maistra leftovers?
oc get pods -n openshift-ingress -l app=istiod
oc get crd -l maistra-version -o custom-columns='NAME:.metadata.name,MAISTRA_VER:.metadata.labels.maistra-version'
oc get crd destinationrules.networking.istio.io -o jsonpath='{range .spec.versions[*]}{.name}{" "}{end}{"\n"}'
# blocked state: only v1beta1/v1alpha3 served, no v1
```

**Safety check first — confirm there is no Istio data to lose (there should be zero CRs):**

```
for k in destinationrules virtualservices gateways serviceentries sidecars \
         envoyfilters workloadentries workloadgroups proxyconfigs; do
  echo "$k.networking.istio.io: $(oc get "$k.networking.istio.io" -A --no-headers 2>/dev/null | wc -l)"
done
for k in authorizationpolicies peerauthentications requestauthentications; do
  echo "$k.security.istio.io: $(oc get "$k.security.istio.io" -A --no-headers 2>/dev/null | wc -l)"
done
echo "telemetries: $(oc get telemetries.telemetry.istio.io -A --no-headers 2>/dev/null | wc -l)"
echo "wasmplugins: $(oc get wasmplugins.extensions.istio.io -A --no-headers 2>/dev/null | wc -l)"
# every count must be 0 before deleting the CRDs below
```

**Fix (only if all counts are 0):** delete the 14 stale `*.istio.io` CRDs, then restart the ingress-operator so sail reinstalls them at `v1`:

```
oc delete crd destinationrules.networking.istio.io virtualservices.networking.istio.io \
  gateways.networking.istio.io serviceentries.networking.istio.io sidecars.networking.istio.io \
  envoyfilters.networking.istio.io workloadentries.networking.istio.io workloadgroups.networking.istio.io \
  proxyconfigs.networking.istio.io authorizationpolicies.security.istio.io \
  peerauthentications.security.istio.io requestauthentications.security.istio.io \
  telemetries.telemetry.istio.io wasmplugins.extensions.istio.io

# Trigger the sail controller to reinstall the Istio CRDs at v1:
oc rollout restart deploy/ingress-operator -n openshift-ingress-operator
```

**Recovery cascade (self-healing after the above, may take a few minutes):**
`DestinationRule` CRD reappears serving `v1` → `istiod-openshift-gateway` **1/1** → Gateway `Programmed=True` → `GatewayConfig` **Ready** (domain assigned) → **ModelRegistry Ready** → **DSC Ready**.

```
oc get pods -n openshift-ingress -l app=istiod            # expect 1/1
oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'  # expect True
oc get gatewayconfig default-gateway -o jsonpath='phase={.status.phase}{"\n"}'  # expect Ready
oc get dsc -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'          # expect Ready
```

> The `*.maistra.io` CRDs (servicemeshcontrolplanes, federation, etc.) are harmless leftovers with 0 CRs — they don't block sail and can optionally be removed too. Only the `*.istio.io` ones cause this failure.

## GatewayConfig stuck "Not Ready" — NetworkPolicy webhook blocks it

**Symptom:** post-upgrade, `oc get gatewayconfig default-gateway --all-namespaces -o wide` shows `READY: False`, and the dashboard URL doesn't resolve.

**Cause:** the RHOAI 3.x GatewayConfig reconciler creates a NetworkPolicy in the `openshift-ingress` namespace to allow ingress traffic to `data-science-gateway`. On clusters with an SRE-managed admission webhook (typical name: `sre-networkpolicies-validation`) restricting NetworkPolicy creation in `openshift-*` namespaces, that POST gets rejected → GatewayConfig sits Not Ready forever.

This has been observed on multiple managed-OpenShift clusters with SRE-managed admission webhooks. Reproducible enough to call a known issue rather than environment-specific — if your cluster has any webhook restricting NetworkPolicy creation in `openshift-*` namespaces, expect to need this fix.

**Fix:** disable the operator-managed NetworkPolicy for the GatewayConfig. The cluster's ingress isolation continues to be enforced by whatever the SRE webhook set up; you're just opting RHOAI out of also writing one.

```
oc patch gatewayconfig default-gateway --type=merge \
  -p '{"spec":{"networkPolicy":{"ingress":{"enabled":false}}}}'
```

Verify:

```
oc get gatewayconfig default-gateway -o jsonpath='phase={.status.phase}  ingressMode={.status.ingressMode}{"\n"}'
# expect: phase=Ready  ingressMode=OcpRoute
```

If you don't run an SRE webhook (most non-managed-OpenShift clusters), the default `networkPolicy.ingress.enabled=true` is fine and you don't need this patch.

## Disconnected-cluster OSSM3 failure

> **First rule out the CRD case above.** If the gateway is failing because the `servicemeshoperator3` **subscription** can't pull its images (disconnected mirror), that's this section. If it's failing because of leftover Maistra `*.istio.io` CRDs and an `istiod-openshift-gateway` pod stuck 0/1 with `"managed by an unknown party"` in the ingress-operator log, that's the *CRITICAL* CRD section above — and on OCP 4.20.31+/4.21.22+/4.22+ you should **not** be installing OSSM3 at all (the built-in sail Istio provides the gateway).

> After upgrading on a disconnected cluster, the `servicemeshoperator3` subscription can fail, leaving DSCI stuck `<not Ready>` and `data-science-gateway` with `Unknown` status.

This is a known issue with a KB article — do not try to resolve inline:

- Confirm the symptom:
  ```
  oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='{.status.state}{"\n"}'
  oc get dsci -o jsonpath='{.items[0].status.phase}{"\n"}'
  oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
  ```
- Follow the KB: [OpenShift Service Mesh 3.x fails to deploy on a disconnected cluster during Red Hat OpenShift AI installation](https://access.redhat.com/solutions/7141146).

## Service Mesh Operator 3.4.0 breaks the gateway on OCP 4.19–4.21

> **Do not approve the `servicemeshoperator3` upgrade to 3.4.0.** After the RHOAI migration, OLM parks an "upgrade available" InstallPlan in front of the Service Mesh Operator 3 subscription. Approving it (fresh installs hit this too) breaks the OpenShift Gateway API.

**Symptom:** the `openshift-gateway` Istio resource enters a permanent `ReconcileError`:

```
validation error: version "v1.26.2" is end-of-life and cannot be installed; use a supported version
```

Deleting the resource recreates it with the same error; manually editing the version to a supported one (e.g. `v1.30.1`) is reverted within seconds.

**Cause:** on OCP 4.19–4.21 the `cluster-ingress-operator` **hardcodes** the Gateway API Istio version to `v1.26.2` and continuously reconciles the `openshift-gateway` resource back to it. OSSM **3.4.0** added a validation gate that rejects `v1.26.2` as end-of-life. So the version the ingress operator insists on is the version the mesh operator refuses — and the ingress operator always wins the reconcile race. This is **not** an RHOAI bug and **not** a migration limitation; RHOAI validates against Service Mesh **3.2** and does not require 3.4.0. There is **no supported OSSM downgrade**, so prevention is the only clean path.

**Prevent (recommended):** keep the Service Mesh Operator 3 subscription on `installPlanApproval: Manual` and pin it ≤ 3.3.x — do **not** approve the 3.4.0 InstallPlan until the fix ships.

```
# Confirm the installed OSSM3 version and that approval is gated
oc get csv -A -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' | grep servicemeshoperator3
oc get subscription servicemeshoperator3 -n openshift-operators -o jsonpath='approval={.spec.installPlanApproval} channel={.spec.channel}{"\n"}'
# If an unapproved 3.4.0 InstallPlan is waiting, leave it unapproved:
oc get installplan -n openshift-operators -o custom-columns='NAME:.metadata.name,CSV:.spec.clusterServiceVersionNames[*],APPROVED:.spec.approved'
```

**Already on 3.4.0:** the gateway cannot be repaired in place and OSSM cannot be safely downgraded — this is a restore-from-backup support situation, not an inline patch. Do not attempt the `startingCSV` / manual-downgrade workarounds circulating informally; they have broken clusters in testing.

**Tracking:** OSSM-14917 and OCPBUGS-92038 (the actual defect, affecting OCP 4.19/4.20/4.21 — a fixed z-stream, not a minor bump, is the resolution); RHOAIENG-76376 (RHOAI-side doc update). Note the affected-versions list includes 4.21, so "upgrade OCP to 4.21" is **not** a workaround.

## Dashboard URL 404 after upgrade

3.x uses Gateway API — the old 2.x Route URL is gone. Users with bookmarks will get 404. Fix:

1. Get the new dashboard URL:
   ```
   oc get gatewayconfigs -A -o jsonpath='{range .items[*]}{.spec.hostname}{"\n"}{end}'
   ```
2. Communicate the new URL to users. See [Resolving dashboard URL 404 errors after upgrading from 2.x to 3.x](https://access.redhat.com/solutions/7137771) for the redirect option.
