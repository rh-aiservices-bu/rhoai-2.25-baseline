# Resolver — cert-manager Operator

**rhai-cli signal:** `dependency / cert-manager / *` with impact `critical`.

## Why

> cert-manager Operator | **Mandatory for JobSet, LeaderWorkerSet, Kueue, and KubeRay**
>
> — architectural-changes.md § *Platform Prerequisites*

In RHOAI 3.x, cert-manager issues the TLS certs that the JobSet + LeaderWorkerSet controllers, the Red Hat build of Kueue, and KubeRay use internally. RHOAI 2.25.x didn't require it, so installing it is a migration-prep step (§2.1 of the migration guide). cert-manager remains a **hard 3.5 prerequisite** — the upgrade will not complete without it.

## Verify current state

```
oc get csv -A | grep cert-manager-operator
oc get subscription -A | grep cert-manager-operator
```

If no CSV matches, cert-manager isn't installed yet.

## Commands to run

Install the **cert-manager Operator for Red Hat OpenShift** (packagemanifest `openshift-cert-manager-operator` on `redhat-operators`, channel `stable-v1`). The guide documents two equivalent methods (§2.1) — pick one.

### Method 1 — OpenShift web console

1. In the OpenShift web console, go to **Operators → OperatorHub**.
2. Search for **cert-manager Operator for Red Hat OpenShift** (the Red Hat build — not the community cert-manager).
3. Click **Install**, then on the install form select **Update channel `stable-v1`** and **Installed Namespace `cert-manager-operator`** (the operator installs into `cert-manager-operator` and creates its operands in `cert-manager`), and click **Install**.
4. Wait for the operator to report **Succeeded**, then jump to [Verify](#verify).

### Method 2 — OpenShift CLI

Create the `cert-manager-operator` namespace, an OperatorGroup, and a Subscription:

```
oc create ns cert-manager-operator 2>/dev/null || true

oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
    - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
```

## Verify

Wait until the CSV succeeds and the three cert-manager pods are running:

```
oc get csv -n cert-manager-operator --watch
oc get pods -n cert-manager
# expect: cert-manager-*, cert-manager-cainjector-*, cert-manager-webhook-* all Running
```

## Callouts

- Use the **Red Hat cert-manager Operator** (`openshift-cert-manager-operator`), not the upstream community cert-manager. Only the Red Hat build is supported for RHOAI 3.x.
- This Operator is also required by the 3.x RHCL stack — install it before touching any KServe / distributed-inference items.
