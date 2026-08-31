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

1. Install Red Hat Connectivity Link (§2.10.10.1 of the migration guide)
2. For disconnected clusters, mirror the RHCL images (§2.10.10.2)
3. Configure authentication for each LLMInferenceService — annotation or RBAC (§2.10.10.3)
4. Freeze LLMInferenceService template annotations (§2.10.10.4)

### 1. Install Red Hat Connectivity Link

Skip this if you do not use LLMInferenceService. Otherwise:

**Confirmed subscription fields** (verified on RHCL v1.3.3 / RHOAI 3.5 cluster):

| Field | Value |
| --- | --- |
| Display name | Red Hat Connectivity Link |
| Package name | `rhcl-operator` |
| Catalog source | `redhat-operators` |
| Channel | `stable` |
| Install mode | **AllNamespaces only** (`OwnNamespace` is *not* supported for RHCL v1.3.3) |
| Install location | `openshift-operators` (which ships an AllNamespaces OperatorGroup by default) |

The **community** edition lives at `kuadrant-operator` in `community-operators`. **Do not** install that one — it is not supported for RHOAI 3.x and its CRD versions may not match what KServe LLM-d expects. Always use `rhcl-operator` from `redhat-operators`.

> **History — this resolver has bounced on the install mode.** Migration guide §2.10.10.1 directs OperatorHub installation into `kuadrant-system` with mode "A specific namespace on the cluster" (i.e., OwnNamespace). On RHCL v1.3.3 that produces:
>
> ```
> phase: Failed
> reason: UnsupportedOperatorGroup
> message: OwnNamespace InstallModeType not supported, cannot configure to watch own namespace
> ```
>
> The bundled `dns-operator` and `limitador-operator` CSVs fail with the same error. Only Authorino installs (it supports OwnNamespace) but is stranded without the rest. The guide pre-dates this constraint — install AllNamespaces into `openshift-operators` instead. The Kuadrant CR + Authorino TLS resources still live in `kuadrant-system`; only the Subscription moves.

```
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

`openshift-operators` already has the default `global-operators` AllNamespaces OperatorGroup — no OperatorGroup needs to be applied. Wait for all four CSVs (rhcl, dns, limitador, authorino) to reach `Succeeded`:

```
oc get csv -n openshift-operators | grep -iE "rhcl|dns-operator|limitador|authorino"
```

### Recovery from the OwnNamespace failure

If a prior install attempt produced the `UnsupportedOperatorGroup` Failed state, clean it up first:

```
# Delete the failed CSVs, Subscription, and the kuadrant-system OperatorGroup
oc delete subscription -n kuadrant-system rhcl-operator --ignore-not-found
oc delete csv -n kuadrant-system \
  rhcl-operator.v1.3.3 dns-operator.v1.3.0 limitador-operator.v1.3.0 \
  --ignore-not-found
oc delete operatorgroup -n kuadrant-system kuadrant-system --ignore-not-found
```

Then re-apply the AllNamespaces Subscription above.

After the CSV reaches `Succeeded`, create the Kuadrant CR so RHCL provisions Authorino and Limitador:

```
oc apply -f - <<'EOF'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata: { name: kuadrant, namespace: kuadrant-system }
EOF
```

> **Do not block on Kuadrant `Ready=True` pre-RHOAI-upgrade.** Kuadrant requires a Gateway API provider (Sail-managed Istio or Envoy Gateway). The OCP 4.19+ Cluster Ingress Operator carries the SMv3 install recipe (env vars `GATEWAY_API_OPERATOR_VERSION` / `_CHANNEL` / `_CATALOG` on the `ingress-operator` deployment) but only triggers the install once a `GatewayConfig` CR exists — which is created by the RHOAI 3.x operator post-upgrade. Pre-upgrade, Kuadrant typically sits at `Ready=False / MissingDependency: [Gateway API provider (istio / envoy gateway)] is not installed`. That is **expected** and does not block the migration: the rhai-cli `kuadrant-readiness` check is satisfied by the Kuadrant CR *existing*, not by it being `Ready=True`. On some clusters Kuadrant's reconciler accepts the Gateway API CRDs alone and reaches `Ready=True` pre-upgrade anyway; either state passes the lint. Earlier revisions of this resolver had `oc wait Kuadrant ... --for=condition=Ready --timeout=10m`; that times out on roughly half of pre-upgrade clusters and was misleading.

> **Don't install Sail / Istio / IstioCNI CRs by hand.** Migration guide §2.10.10.1 doesn't include them and the OCP Cluster Ingress Operator owns the SMv3 install (connected) or expects the admin to mirror its image (disconnected, per §2.10.10.2). If Kuadrant is *still* `Ready=False` on a *post-upgrade* cluster, the Cluster Ingress Operator itself is unhealthy — diagnose there. Do not pre-install Sail.

### 1b. Enable TLS on the Authorino listener

Per migration guide §2.10.10.1, use OpenShift's built-in service signer to mint the listener cert — no cert-manager needed. The Authorino CR enables TLS on the **listener only**; `oidcServer.tls.enabled` stays `false`. Earlier revisions of this resolver instructed cert-manager `ClusterIssuer` + two `Certificate` CRs and TLS on the OIDC server; both were wrong.

```
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

Verify:

```
oc get secret authorino-server-cert -n kuadrant-system
oc get authorino authorino -n kuadrant-system -o jsonpath='listener={.spec.listener.tls.enabled} oidc={.spec.oidcServer.tls.enabled}'; echo
oc get pods -n kuadrant-system -l authorino-resource=authorino
```

### 2. Disconnected environments

If this is a disconnected cluster, mirror the RHCL images into your registry using `oc-mirror`. See migration guide §2.10.10.2 for the exact image list (it spans RHCL operator, Authorino, Limitador, and dependencies). Consult Red Hat Support — the list changes per RHCL version.

### 3. Configure authentication for each LLMInferenceService

> **Not Kuadrant `AuthPolicy`.** An earlier version of this resolver recommended creating a `kuadrant.io/v1* AuthPolicy` with `targetRef.kind: LLMInferenceService`. The RHCL webhook rejects that — AuthPolicy only accepts `group: gateway.networking.k8s.io` with `kind: HTTPRoute` or `Gateway`. Per migration guide §2.10.10.3, LLMInferenceService authentication is configured via annotation (dev/test) or plain Kubernetes RBAC (recommended). Both paths below are documented by Red Hat and work pre-upgrade.

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

> **Why this isn't Kuadrant/AuthPolicy on 2.x:** on the pre-upgrade 2.25.x cluster, LLMInferenceService routes through Service Mesh v2 + Knative, not Gateway API — there are no HTTPRoutes/Gateways for AuthPolicy to target. Gateway API-based auth is a 3.x-era concern handled post-upgrade. The RBAC path here works on both 2.25.x pre-upgrade and 3.5 post-upgrade.

### 4. Freeze the LLMInferenceService template annotations

Pin every LLMInferenceService to the 2.25.x template set so the chapter-3 upgrade doesn't rewrite templates under a running scheduler. The pins go on `.status.annotations` (via the status subresource), **not** `.metadata.annotations` — and the values are the literal `kserve-config-llm-*` strings the 2.25 scheduler reads, not version labels.

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
> Migration guide §2.10.10.4 has the diff of the updated scheduler block.

## Verify

```
# RHCL operator installed
oc get csv -n kuadrant-system | grep rhcl-operator

# Every LLMInferenceService has the eight freeze annotations
oc get llminferenceservice -A -o json \
  | jq -r '.items[] | {ns:.metadata.namespace, name:.metadata.name, pins: [.metadata.annotations | to_entries[] | select(.key | startswith("serving.kserve.io/config-llm-")) | .key]}'
```

Each LLMInferenceService should list all eight `config-llm-*` annotations.

Finally, re-run the lint to confirm the LLMInferenceService findings clear. `lint` is pre-upgrade only (it exits as a no-op once the cluster is already on 3.5):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli lint --target-version 3.5 --verbose \
  --checks "*llminferenceservice*"
```

No `critical` / `prohibited` LLMInferenceService rows should remain.

## Callouts

- Do not uninstall the standalone Authorino operator (covered in [kserve.md](kserve.md)) until RHCL is up and AuthPolicies are in place — you'll drop auth entirely for a window otherwise.
- The template values are shipped in the rhai-cli tool output — the literal `kserve-config-llm-*` strings shown above are the 2.25 scheduler's config keys, not version labels. Copy them from the tool's output rather than guessing.
