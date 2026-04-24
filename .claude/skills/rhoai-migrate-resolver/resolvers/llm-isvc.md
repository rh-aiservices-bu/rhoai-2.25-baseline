# Resolver — LLMInferenceService (distributed inference)

**rhai-cli signal:** `workload / llminferenceservice / *`.

## Why

> Distributed inference via LLMInferenceService requires RHCL for security and policy management. Pin LLM configurations to 2.25 templates during migration to prevent scheduler failures.
>
> — architectural-changes.md § *Model Serving Migration*

> Authorization: Adoption of Red Hat Connectivity Link (RHCL). RHCL (upstream: Kuadrant) consolidates security (Authorino), rate limiting (Limitador), and policy management with the Gateway API. It is required by LLM-d and is the foundation for MaaS governance.
>
> — architectural-changes.md § *Authorization: Adoption of Red Hat Connectivity Link*

LLM-d's router and scheduler templates evolved between 2.25 and 3.x. During the upgrade the templates in the `inferenceservice-config` ConfigMap get rewritten; if an LLMInferenceService was relying on a specific template version (directly or implicitly), the scheduler will drop its pods. Pinning the template annotations freezes the 2.25 behaviour across the upgrade.

RHCL replaces the standalone Authorino operator and becomes the auth/policy control plane for every LLM endpoint.

## Four sub-steps

1. Install Red Hat Connectivity Link (§2.8.10.1 of the migration guide)
2. For disconnected clusters, mirror the RHCL images (§2.8.10.2)
3. Configure authentication for each LLMInferenceService — annotation or RBAC (§2.8.10.3)
4. Freeze LLMInferenceService template annotations (§2.8.10.4)

### 1. Install Red Hat Connectivity Link

Skip this if you do not use LLMInferenceService. Otherwise:

**Confirmed subscription fields** (verified against `oc get packagemanifest rhcl-operator -n openshift-marketplace`):

| Field | Value |
| --- | --- |
| Display name | Red Hat Connectivity Link |
| Package name | `rhcl-operator` |
| Catalog source | `redhat-operators` |
| Channel | `stable` |
| Install mode | **`AllNamespaces` only** (OwnNamespace / SingleNamespace / MultiNamespace all unsupported) |

The **community** edition lives at `kuadrant-operator` in `community-operators`. **Do not** install that one — it is not supported for RHOAI 3.x and its CRD versions may not match what KServe LLM-d expects. Always use `rhcl-operator` from `redhat-operators`.

> **Important:** Because only `AllNamespaces` is supported, install into `openshift-operators` (which ships an AllNamespaces OperatorGroup). A per-namespace OG with `targetNamespaces` will fail with `CSV status: OwnNamespace InstallModeType not supported`. The `kuadrant-system` namespace is still used for the Kuadrant CR itself — that CR is namespaced even though the operator watches cluster-wide.

```
oc create ns kuadrant-system 2>/dev/null || true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

Wait for the CSV in `openshift-operators`:

```
oc get csv -n openshift-operators -l operators.coreos.com/rhcl-operator.openshift-operators= -w
```

After the CSV reaches `Succeeded`, create a Kuadrant CR so RHCL provisions Authorino (with TLS) and Limitador:

```
oc apply -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
EOF
```

Verify the kuadrant readiness check passes:

```
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo
oc get authorino -A
```

> **Gateway API provider prerequisite:** Kuadrant will sit at `Ready=False` with `MissingDependency: [Gateway API provider (istio / envoy gateway)] is not installed` until a Gateway API provider exists. On OCP 4.19+ install **Service Mesh v3** (`servicemeshoperator3`, channel `stable`, in `openshift-operators`) and create an `Istio` + `IstioCNI` CR:
>
> ```
> oc apply -f - <<'EOF'
> apiVersion: operators.coreos.com/v1alpha1
> kind: Subscription
> metadata: { name: servicemeshoperator3, namespace: openshift-operators }
> spec:
>   channel: stable
>   name: servicemeshoperator3
>   source: redhat-operators
>   sourceNamespace: openshift-marketplace
>   installPlanApproval: Automatic
> ---
> apiVersion: sailoperator.io/v1
> kind: Istio
> metadata: { name: default }
> spec: { version: v1.26.3, namespace: istio-system, updateStrategy: { type: InPlace } }
> ---
> apiVersion: sailoperator.io/v1
> kind: IstioCNI
> metadata: { name: default }
> spec: { version: v1.26.3, namespace: istio-cni }
> EOF
>
> oc create ns istio-cni 2>/dev/null || true
> # Restart kuadrant-operator so it re-detects the provider
> oc delete pod -n openshift-operators -l app.kubernetes.io/name=kuadrant-operator
> ```

### 1b. Enable TLS on the Authorino listener

The rhai-cli `authorino-tls-readiness` check requires `spec.listener.tls.enabled=true` and `spec.oidcServer.tls.enabled=true` on the Authorino CR that RHCL creates. The Kuadrant CR does not expose a field for this, so issue certs via cert-manager and patch the Authorino CR directly:

```
oc apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: authorino-selfsigned }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: authorino-server-cert, namespace: kuadrant-system }
spec:
  secretName: authorino-server-cert
  duration: 87600h
  issuerRef: { name: authorino-selfsigned, kind: ClusterIssuer }
  commonName: authorino-authorization.kuadrant-system.svc
  dnsNames:
    - authorino-authorization.kuadrant-system.svc
    - authorino-authorization.kuadrant-system.svc.cluster.local
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: authorino-oidc-server-cert, namespace: kuadrant-system }
spec:
  secretName: authorino-oidc-server-cert
  duration: 87600h
  issuerRef: { name: authorino-selfsigned, kind: ClusterIssuer }
  commonName: authorino-oidc.kuadrant-system.svc
  dnsNames:
    - authorino-oidc.kuadrant-system.svc
    - authorino-oidc.kuadrant-system.svc.cluster.local
EOF

oc patch authorino authorino -n kuadrant-system --type=merge -p '{
  "spec":{
    "listener":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-server-cert"}}},
    "oidcServer":{"tls":{"enabled":true,"certSecretRef":{"name":"authorino-oidc-server-cert"}}}
  }
}'
```

Verify:

```
oc get authorino authorino -n kuadrant-system -o jsonpath='listener={.spec.listener.tls.enabled} oidc={.spec.oidcServer.tls.enabled} ready={.status.conditions[?(@.type=="Ready")].status}'; echo
```

### 2. Disconnected environments

If this is a disconnected cluster, mirror the RHCL images into your registry using `oc-mirror`. See migration guide §2.8.10.2 for the exact image list (it spans RHCL operator, Authorino, Limitador, and dependencies). Consult Red Hat Support — the list changes per RHCL version.

### 3. Configure authentication for each LLMInferenceService

> **Not Kuadrant `AuthPolicy`.** An earlier version of this resolver recommended creating a `kuadrant.io/v1* AuthPolicy` with `targetRef.kind: LLMInferenceService`. The RHCL webhook rejects that — AuthPolicy only accepts `group: gateway.networking.k8s.io` with `kind: HTTPRoute` or `Gateway`. Per migration guide §2.8.10.3, LLMInferenceService authentication is configured via annotation (dev/test) or plain Kubernetes RBAC (recommended). Both paths below are documented by Red Hat and work pre-upgrade.

Pick **one** of the following methods per LLMInferenceService.

#### Method 1 — Disable auth (dev/test only)

Fastest path. Makes the model reachable with no token. Not for production.

```
NS=<llm-namespace>; NAME=<llm-isvc-name>
oc annotate llminferenceservice "$NAME" -n "$NS" \
  security.opendatahub.io/enable-auth=false --overwrite
```

Verify:

```
oc get llminferenceservice "$NAME" -n "$NS" -o jsonpath='{.metadata.annotations.security\.opendatahub\.io/enable-auth}'; echo
# expect: false
```

#### Method 2 — RBAC with ServiceAccount + Role + RoleBinding (recommended)

Keeps the model secure. Clients authenticate with a bearer token minted for the ServiceAccount.

```
NS=<llm-namespace>; NAME=<llm-isvc-name>
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

```
TOKEN=$(oc create token "${NAME}-sa" -n "$NS")
curl -H "Authorization: Bearer $TOKEN" https://<model-url>/v2/models/...
```

> **Why this isn't Kuadrant/AuthPolicy on 2.x:** on the pre-upgrade 2.25.4 cluster, LLMInferenceService routes through Service Mesh v2 + Knative, not Gateway API — there are no HTTPRoutes/Gateways for AuthPolicy to target. Gateway API-based auth is a 3.x-era concern handled post-upgrade. The RBAC path here works on both 2.25.4 pre-upgrade and 3.3.2 post-upgrade.

### 4. Freeze the LLMInferenceService template annotations

Pin every LLMInferenceService to the 2.25.4 template set so the chapter-3 upgrade doesn't rewrite templates under a running scheduler. The pins go on `.status.annotations` (via the status subresource), **not** `.metadata.annotations` — and the values are the literal `kserve-config-llm-*` strings the 2.25 scheduler reads, not version labels.

Enumerate:

```
oc get llmisvc -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'
```

Patch each one (`llmisvc` is the short kind name the guide uses for `LLMInferenceService`):

```
NS=<ns>; NAME=<llm-isvc>
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

Verify:

```
oc get llmisvc "$NAME" -n "$NS" -o jsonpath='{.status.annotations}' | jq '.'
```

All eight `serving.kserve.io/config-llm-*` keys should be present.

> **Gotcha — scheduler arg changes for 3.x compatibility:** if you *override* the LLMInferenceService scheduler's `args` or `env` (i.e. you have a `spec.router.scheduler.containers[*]` block), the 3.x breaking changes below apply. If you haven't overridden the scheduler (most users), skip this.
>
> - `camelCase` → `kebab-case` args (e.g. `--certPath` → `--cert-path`)
> - TLS cert path moved from `/etc/ssl/certs` to `/var/run/kserve/tls`
> - Signed TLS certs via OpenShift service signer are mandatory
> - Must include `--cert-path` arg and `SSL_CERT_DIR` env var
>
> Migration guide §2.8.10.4 has the diff of the updated scheduler block.

## Verify

```
# RHCL operator installed
oc get csv -n kuadrant-system | grep rhcl-operator

# Every LLMInferenceService has the eight freeze annotations
oc get llminferenceservice -A -o json \
  | jq -r '.items[] | {ns:.metadata.namespace, name:.metadata.name, pins: [.metadata.annotations | to_entries[] | select(.key | startswith("serving.kserve.io/config-llm-")) | .key]}'
```

Each LLMInferenceService should list all eight `config-llm-*` annotations.

## Callouts

- Do not uninstall the standalone Authorino operator (covered in [kserve.md](kserve.md)) until RHCL is up and AuthPolicies are in place — you'll drop auth entirely for a window otherwise.
- The template versions (`v2.25` above) are placeholders — the actual values are shipped in the rhai-cli helper. Copy them from the tool's output rather than guessing.
