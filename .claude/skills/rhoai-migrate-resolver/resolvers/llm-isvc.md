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
3. Configure `AuthPolicy` for each LLMInferenceService (§2.8.10.3)
4. Freeze LLMInferenceService template annotations (§2.8.10.4)

### 1. Install Red Hat Connectivity Link

Skip this if you do not use LLMInferenceService. Otherwise:

> **Important:** RHCL does **not** support `OwnNamespace` install mode (`CSV status: OwnNamespace InstallModeType not supported`). Install it in `openshift-operators` (which ships an AllNamespaces OperatorGroup), not in a per-namespace OG with `targetNamespaces`. A `kuadrant-system` namespace is still used for the Kuadrant CR itself.

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

Verify the authorino + kuadrant readiness checks pass:

```
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo
oc get authorino -A
```

### 2. Disconnected environments

If this is a disconnected cluster, mirror the RHCL images into your registry using `oc-mirror`. See migration guide §2.8.10.2 for the exact image list (it spans RHCL operator, Authorino, Limitador, and dependencies). Consult Red Hat Support — the list changes per RHCL version.

### 3. Configure authentication for each LLMInferenceService

For each LLMInferenceService, create an `AuthPolicy` that tells RHCL how to authenticate callers. Minimal example using bearer tokens issued by the OCP OAuth server:

```
NS=<llm-namespace>; NAME=<llm-isvc-name>
oc apply -f - <<EOF
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: ${NAME}-auth
  namespace: ${NS}
spec:
  targetRef:
    group: serving.kserve.io
    kind: LLMInferenceService
    name: ${NAME}
  rules:
    authentication:
      openshift-oauth:
        kubernetesTokenReview: {}
EOF
```

Replace with your real auth scheme (external OIDC, API keys, etc.). The exact shape depends on RHCL version and your IdP.

### 4. Freeze the LLMInferenceService template annotations

Pin every LLMInferenceService to the 2.25 template set. Enumerate:

```
oc get llminferenceservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name'
```

For each, add the freeze annotations. Use the rhai-cli helper if it's available in your image:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli llm freeze-templates
```

Or patch by hand:

```
NS=<ns>; NAME=<llm-isvc>
oc annotate llminferenceservice "$NAME" -n "$NS" --overwrite \
  serving.kserve.io/config-llm-template=v2.25 \
  serving.kserve.io/config-llm-decode-template=v2.25 \
  serving.kserve.io/config-llm-worker-data-parallel=v2.25 \
  serving.kserve.io/config-llm-decode-worker-data-parallel=v2.25 \
  serving.kserve.io/config-llm-prefill-template=v2.25 \
  serving.kserve.io/config-llm-prefill-worker-data-parallel=v2.25 \
  serving.kserve.io/config-llm-scheduler=v2.25 \
  serving.kserve.io/config-llm-router-route=v2.25
```

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
