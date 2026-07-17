# Resolver — LLMInferenceService (distributed inference)

**rhai-cli signal:** `workload / llminferenceservice / *`.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / `oc annotate` yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<LLM_NAMESPACE>` | namespace holding an LLMInferenceService | `oc get llminferenceservice -A` |
| `<LLM_ISVC_NAME>` | the LLMInferenceService name | `oc get llminferenceservice -n <LLM_NAMESPACE>` |
| `<MODEL_URL>` | the served model's external URL (for the client curl test) | `oc get route -n <LLM_NAMESPACE>` |

→ If you do NOT use LLMInferenceService, skip this entire resolver.

## DO THIS

### Step 1 — Install Red Hat Connectivity Link (RHCL)

Migration guide §2.8.10.1. RHCL replaces the standalone Authorino operator and becomes the auth/policy control plane for every LLM endpoint.

**Confirmed subscription fields** (verified on RHCL v1.3.3 / RHOAI 3.3.3 cluster):

| Field | Value |
| --- | --- |
| Display name | Red Hat Connectivity Link |
| Package name | `rhcl-operator` |
| Catalog source | `redhat-operators` |
| Channel | `stable` |
| Install mode | **AllNamespaces only** (`OwnNamespace` is *not* supported for RHCL v1.3.3) |
| Install location | `openshift-operators` (which ships an AllNamespaces OperatorGroup by default) |

⚠️ Do NOT install the **community** edition (`kuadrant-operator` in `community-operators`) — it is not supported for RHOAI 3.x and its CRD versions may not match what KServe LLM-d expects. Always use `rhcl-operator` from `redhat-operators`.

Apply the Subscription (AllNamespaces into `openshift-operators`; the Kuadrant CR + Authorino TLS resources still live in `kuadrant-system`, only the Subscription moves):

```sh
oc create ns kuadrant-system 2>/dev/null || true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata: { name: rhcl-operator, namespace: openshift-operators }
spec:
  channel: stable
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

`openshift-operators` already has the default `global-operators` AllNamespaces OperatorGroup — no OperatorGroup needs to be applied.

→ **Expected:** all four CSVs (rhcl, dns, limitador, authorino) reach `Succeeded`:

```sh
oc get csv -n openshift-operators | grep -iE "rhcl|dns-operator|limitador|authorino"
```

→ If instead you see `phase: Failed` / `reason: UnsupportedOperatorGroup` from a prior OwnNamespace attempt: run the cleanup below, then re-apply the Subscription above.

**Recovery from a prior OwnNamespace failure** — ⚠️ Destructive (deletes the failed CSVs, Subscription, and OperatorGroup):

```sh
# Delete the failed CSVs, Subscription, and the kuadrant-system OperatorGroup
oc delete subscription -n kuadrant-system rhcl-operator --ignore-not-found
oc delete csv -n kuadrant-system \
  rhcl-operator.v1.3.3 dns-operator.v1.3.0 limitador-operator.v1.3.0 \
  --ignore-not-found
oc delete operatorgroup -n kuadrant-system kuadrant-system --ignore-not-found
```

After the CSV reaches `Succeeded`, create the Kuadrant CR so RHCL provisions Authorino and Limitador:

```sh
oc apply -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata: { name: kuadrant, namespace: kuadrant-system }
EOF
```

→ **Do not block on Kuadrant `Ready=True` pre-upgrade.** Pre-upgrade, Kuadrant typically sits at `Ready=False / MissingDependency: [Gateway API provider (istio / envoy gateway)] is not installed`. That is expected: the rhai-cli `kuadrant-readiness` check is satisfied by the Kuadrant CR *existing*, not by it being `Ready=True`. Some clusters reach `Ready=True` pre-upgrade anyway; either state passes the lint. See Notes for why. ⚠️ Do NOT hand-install Sail / Istio / IstioCNI CRs to force readiness (see Notes).

### Step 1b — Enable TLS on the Authorino listener

Migration guide §2.8.10.1: use OpenShift's built-in service signer to mint the listener cert — no cert-manager needed. TLS is enabled on the **listener only**; `oidcServer.tls.enabled` stays `false`.

```sh
# Annotate the Authorino service so OpenShift's service signer issues the cert
oc annotate svc/authorino-authorino-authorization \
  service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert \
  -n kuadrant-system
sleep 2

# Apply the Authorino CR with TLS on the listener only
oc apply -f - <<'EOF'
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: kuadrant-system
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: true
      certSecretRef:
        name: authorino-server-cert
  oidcServer:
    tls:
      enabled: false
EOF

oc wait --for=condition=ready pod -l authorino-resource=authorino -n kuadrant-system --timeout=150s
```

**Verify:**

```sh
oc get secret authorino-server-cert -n kuadrant-system
oc get authorino authorino -n kuadrant-system -o jsonpath='listener={.spec.listener.tls.enabled} oidc={.spec.oidcServer.tls.enabled}'; echo
oc get pods -n kuadrant-system -l authorino-resource=authorino
```

→ Expected: the `authorino-server-cert` secret exists; `listener=true oidc=false`; the authorino pod is Running.

### Step 2 — Disconnected environments

→ If this is a connected cluster: skip. If disconnected: mirror the RHCL images into your registry using `oc-mirror`. See migration guide §2.8.10.2 for the exact image list (it spans RHCL operator, Authorino, Limitador, and dependencies). Consult Red Hat Support — the list changes per RHCL version.

### Step 3 — Configure authentication for each LLMInferenceService

Migration guide §2.8.10.3. → Pick **ONE** method per LLMInferenceService: Method 1 (dev/test) or Method 2 (recommended). ⚠️ Auth is configured via annotation or plain Kubernetes RBAC — NOT via a Kuadrant `AuthPolicy` (the RHCL webhook rejects `targetRef.kind: LLMInferenceService`; see Notes).

#### Method 1 — Disable auth (dev/test only)

Fastest path. Makes the model reachable with no token. ⚠️ Not for production — leaves the endpoint open.

```sh
NS=<LLM_NAMESPACE>; NAME=<LLM_ISVC_NAME>
oc annotate llminferenceservice "$NAME" -n "$NS" \
  security.opendatahub.io/enable-auth=false --overwrite
```

**Verify:**

```sh
oc get llminferenceservice "$NAME" -n "$NS" -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/enable-auth}'; echo
```

→ Expected: `false`

#### Method 2 — RBAC with ServiceAccount + Role + RoleBinding (recommended)

Keeps the model secure. Clients authenticate with a bearer token minted for the ServiceAccount.

```sh
NS=<LLM_NAMESPACE>; NAME=<LLM_ISVC_NAME>
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NAME}-sa
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NAME}-role
  namespace: ${NS}
rules:
  - apiGroups: ["serving.kserve.io"]
    resources: ["llminferenceservices"]
    resourceNames: ["${NAME}"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NAME}-rolebinding
  namespace: ${NS}
subjects:
  - kind: ServiceAccount
    name: ${NAME}-sa
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${NAME}-role
EOF
```

Clients then include a bearer token:

```sh
TOKEN=$(oc create token "${NAME}-sa" -n "$NS")
curl -H "Authorization: Bearer $TOKEN" https://<MODEL_URL>/v2/models/...
```

→ Expected: the curl returns the model response (HTTP 200), not 401/403.

### Step 4 — Freeze the LLMInferenceService template annotations

Pin every LLMInferenceService to the 2.25.4 template set so the chapter-3 upgrade doesn't rewrite templates under a running scheduler. The pins go on `.status.annotations` (via the status subresource), **not** `.metadata.annotations` — and the values are the literal `kserve-config-llm-*` strings the 2.25 scheduler reads, not version labels.

Enumerate:

```sh
oc get llmisvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'
```

Patch each one (`llmisvc` is the short kind name the guide uses for `LLMInferenceService`):

```sh
NS=<LLM_NAMESPACE>; NAME=<LLM_ISVC_NAME>
oc patch llmisvc "$NAME" -n "$NS" \
  --subresource=status --type=merge -p '{
    "status": {
      "annotations": {
        "serving.kserve.io/config-llm-template":                        "kserve-config-llm-template",
        "serving.kserve.io/config-llm-decode-template":                 "kserve-config-llm-decode-template",
        "serving.kserve.io/config-llm-worker-data-parallel":            "kserve-config-llm-worker-data-parallel",
        "serving.kserve.io/config-llm-decode-worker-data-parallel":     "kserve-config-llm-decode-worker-data-parallel",
        "serving.kserve.io/config-llm-prefill-template":                "kserve-config-llm-prefill-template",
        "serving.kserve.io/config-llm-prefill-worker-data-parallel":    "kserve-config-llm-prefill-worker-data-parallel",
        "serving.kserve.io/config-llm-scheduler":                       "kserve-config-llm-scheduler",
        "serving.kserve.io/config-llm-router-route":                    "kserve-config-llm-router-route"
      }
    }
  }'
```

**Verify:**

```sh
oc get llmisvc "$NAME" -n "$NS" -o jsonpath='{.status.annotations}' | jq '.'
```

→ Expected: all eight `serving.kserve.io/config-llm-*` keys present.

## Verify (read-only)

```sh
# RHCL operator installed
oc get csv -n kuadrant-system | grep rhcl-operator

# Every LLMInferenceService has the eight freeze annotations
oc get llminferenceservice -A -o json \
  | jq -r '.items[] | {ns:.metadata.namespace, name:.metadata.name, pins: [.metadata.annotations | to_entries[] | select(.key | startswith("serving.kserve.io/config-llm-")) | .key]}'
```

→ Expected: the RHCL CSV shows `Succeeded`, and each LLMInferenceService lists all eight `config-llm-*` annotations.

## Why (reference)

> Distributed inference via LLMInferenceService requires RHCL for security and policy management. Pin LLM configurations to 2.25 templates during migration to prevent scheduler failures.
>
> — architectural-changes.md § *Model Serving Migration*

> Authorization: Adoption of Red Hat Connectivity Link (RHCL). RHCL (upstream: Kuadrant) consolidates security (Authorino), rate limiting (Limitador), and policy management with the Gateway API. It is required by LLM-d and is the foundation for MaaS governance.
>
> — architectural-changes.md § *Authorization: Adoption of Red Hat Connectivity Link*

LLM-d's router and scheduler templates evolved between 2.25 and 3.x. During the upgrade the templates in the `inferenceservice-config` ConfigMap get rewritten; if an LLMInferenceService was relying on a specific template version (directly or implicitly), the scheduler will drop its pods. Pinning the template annotations freezes the 2.25 behaviour across the upgrade. RHCL replaces the standalone Authorino operator and becomes the auth/policy control plane for every LLM endpoint.

The four sub-steps map to the guide as: install RHCL (§2.8.10.1), mirror RHCL images for disconnected clusters (§2.8.10.2), configure authentication per LLMInferenceService (§2.8.10.3), freeze template annotations (§2.8.10.4).

## Notes & edge cases (reference)

- **Why Kuadrant sits `Ready=False` pre-upgrade.** Kuadrant requires a Gateway API provider (Sail-managed Istio or Envoy Gateway). The OCP 4.19+ Cluster Ingress Operator carries the SMv3 install recipe (env vars `GATEWAY_API_OPERATOR_VERSION` / `_CHANNEL` / `_CATALOG` on the `ingress-operator` deployment) but only triggers the install once a `GatewayConfig` CR exists — which is created by the RHOAI 3.x operator post-upgrade. So pre-upgrade `Ready=False / MissingDependency` is expected and does not block the migration.

- **Don't hand-install Sail / Istio / IstioCNI CRs.** Migration guide §2.8.10.1 doesn't include them and the OCP Cluster Ingress Operator owns the SMv3 install (connected) or expects the admin to mirror its image (disconnected, per §2.8.10.2). If Kuadrant is *still* `Ready=False` on a *post-upgrade* cluster, the Cluster Ingress Operator itself is unhealthy — diagnose there. Do not pre-install Sail.

- **Not Kuadrant `AuthPolicy`.** AuthPolicy only accepts `group: gateway.networking.k8s.io` with `kind: HTTPRoute` or `Gateway` — the RHCL webhook rejects `targetRef.kind: LLMInferenceService`. Per §2.8.10.3, LLMInferenceService authentication is configured via annotation (dev/test) or plain Kubernetes RBAC (recommended). Both paths in Step 3 are documented by Red Hat and work pre-upgrade.

- **Why the RBAC path isn't Kuadrant/AuthPolicy on 2.x:** on the pre-upgrade 2.25.4 cluster, LLMInferenceService routes through Service Mesh v2 + Knative, not Gateway API — there are no HTTPRoutes/Gateways for AuthPolicy to target. Gateway API-based auth is a 3.x-era concern handled post-upgrade. The RBAC path in Method 2 works on both 2.25.4 pre-upgrade and 3.3.2 post-upgrade.

- **Scheduler arg changes for 3.x compatibility (only if you override the scheduler).** If you *override* the LLMInferenceService scheduler's `args` or `env` (i.e. you have a `spec.router.scheduler.containers[*]` block), the 3.x breaking changes below apply. If you haven't overridden the scheduler (most users), skip this.
  - `camelCase` → `kebab-case` args (e.g. `--certPath` → `--cert-path`)
  - TLS cert path moved from `/etc/ssl/certs` to `/var/run/kserve/tls`
  - Signed TLS certs via OpenShift service signer are mandatory
  - Must include `--cert-path` arg and `SSL_CERT_DIR` env var
  - Migration guide §2.8.10.4 has the diff of the updated scheduler block.

## Callouts

- Do not uninstall the standalone Authorino operator (covered in [kserve.md](kserve.md)) until RHCL is up and AuthPolicies are in place — you'll drop auth entirely for a window otherwise.
- The template versions (`v2.25` above) are placeholders — the actual values are shipped in the rhai-cli helper. Copy them from the tool's output rather than guessing.

<!--
maintainer history — IGNORE when running the resolver. Not for the user.

- Install mode: migration guide §2.8.10.1 directs OperatorHub installation into `kuadrant-system`
  with mode "A specific namespace on the cluster" (i.e., OwnNamespace). On RHCL v1.3.3 that produces
  `phase: Failed / reason: UnsupportedOperatorGroup / message: OwnNamespace InstallModeType not
  supported, cannot configure to watch own namespace`. The bundled dns-operator and limitador-operator
  CSVs fail the same way; only Authorino installs (it supports OwnNamespace) but is stranded without
  the rest. The guide pre-dates this constraint — Step 1 installs AllNamespaces into
  `openshift-operators` instead. This resolver bounced on the install mode before landing here.

- Kuadrant readiness: earlier revisions had `oc wait Kuadrant ... --for=condition=Ready --timeout=10m`;
  that times out on roughly half of pre-upgrade clusters and was misleading. Dropped — the CR existing
  is what satisfies the lint.

- Authorino TLS: earlier revisions instructed a cert-manager `ClusterIssuer` + two `Certificate` CRs and
  TLS on the OIDC server; both were wrong. Correct path (Step 1b) uses the OpenShift service signer and
  enables TLS on the listener only.

- Auth config: an earlier version recommended creating a `kuadrant.io/v1* AuthPolicy` with
  `targetRef.kind: LLMInferenceService`. The RHCL webhook rejects that. Correct paths are annotation or
  RBAC (Step 3).
-->
