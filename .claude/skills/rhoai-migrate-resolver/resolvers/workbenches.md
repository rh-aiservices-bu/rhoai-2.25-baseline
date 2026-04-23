# Resolver — Workbenches

**rhai-cli signal:** `workload / notebook / *` — image-version, custom-image, stopped.

## Why

> Existing custom workbench images and RStudio images will fail due to routing conflicts with the new auth mechanism — they must be rebuilt. All running workbenches must be stopped before migration; unmigrated workbenches will experience redirection loops.
>
> — architectural-changes.md § *Networking and Authentication Changes*

> oauth-proxy is tightly coupled to the internal OpenShift OAuth Server and cannot support external Identity Providers. […] Custom workbench images built for the oauth-proxy flow will need to be rebuilt.
>
> — architectural-changes.md § *Authentication: oauth-proxy to kube-rbac-proxy*

The migration changes routing (Route → Gateway API) and auth (oauth-proxy → kube-rbac-proxy). Images built for 2.x embed the oauth-proxy sidecar config; under 3.x they hit redirect loops.

## Three distinct sub-issues

### 1. code-server workbenches must be on 2025.2 before upgrade

code-server workbenches on older image tags will break in 3.x. Update the Notebook CRs to the `2025.2` tag:

```
# List current code-server workbenches and their image tag
oc get notebooks -A -o json \
  | jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("code-?server")) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.template.spec.containers[0].image)"'

# For each one, patch to tag 2025.2 — example shown with oc set image-like patch:
NS=<namespace>; NAME=<notebook>
oc patch notebook "$NAME" -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/code-server-notebook:2025.2"}]'
```

### 2. RStudio workbenches must use the `latest` tag

RStudio images are built per-cluster via BuildConfigs (licensing constraint). The tag must be `latest` — the build recreates that tag after the 3.x upgrade.

```
# Ensure the BuildConfigs are present + latest build has succeeded
oc get bc -n redhat-ods-applications | grep rstudio
oc get is rstudio-rhel9 cuda-rstudio-rhel9 -n redhat-ods-applications

# List current RStudio notebooks
oc get notebooks -A -o json \
  | jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("rstudio")) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.template.spec.containers[0].image)"'

# Update each to the latest tag
NS=<namespace>; NAME=<notebook>
oc patch notebook "$NAME" -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/rstudio-rhel9:latest"}]'
```

Post-upgrade the image must be rebuilt (see architectural-changes.md § *Networking and Authentication Changes*); that step happens after the 3.3.2 upgrade itself.

### 3. Custom ("BYON") workbench images must be rebuilt for Gateway API + kube-rbac-proxy

For every custom ImageStream in `redhat-ods-applications` with labels `app.kubernetes.io/created-by: byon` and `opendatahub.io/notebook-image: "true"`:

```
# Enumerate BYON images (IS objects that may or may not have active Notebooks)
oc get imagestream -n redhat-ods-applications -l app.kubernetes.io/created-by=byon \
  -o custom-columns='NAME:.metadata.name,CREATOR:.metadata.annotations.opendatahub\.io/notebook-image-creator,URL:.metadata.annotations.opendatahub\.io/notebook-image-url'
```

Each owner must rebuild their Dockerfile to:

- Remove the oauth-proxy sidecar config; 3.x uses kube-rbac-proxy injected by the platform.
- Use path-based routing via Gateway API (3.x), not the 2.x Route-based path handling.

The owner pushes the new image (new tag), updates the ImageStream, and recreates the Notebook. Red Hat does not provide an automated rebuild — this is an application-owner task. Survey with:

```
# For each BYON IS, print who owns it (from the notebook-image-creator annotation)
oc get imagestream -n redhat-ods-applications -l app.kubernetes.io/created-by=byon \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.opendatahub\.io/notebook-image-creator}{"\n"}{end}'
```

### 4. All workbenches must be Stopped before the upgrade

**rhai-cli signal:** `workload / notebook / stopped`.

```
# Survey which are running
oc get notebooks -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STOPPED:.metadata.annotations.kubeflow-resource-stopped'

# Stop one
NS=<namespace>; NAME=<notebook>
oc annotate notebook "$NAME" -n "$NS" kubeflow-resource-stopped=true --overwrite

# Stop all (be sure — this disconnects active users)
for row in $(oc get notebooks -A --no-headers | awk '{print $1"/"$2}'); do
  oc annotate notebook "${row##*/}" -n "${row%%/*}" kubeflow-resource-stopped=true --overwrite
done
```

Expect to do this in the maintenance window itself, not earlier — users will lose active sessions.

## Verify

```
# No workbenches still running
oc get notebooks -A -o json \
  | jq -r '.items[] | select((.metadata.annotations."kubeflow-resource-stopped" // "false") != "true") | "\(.metadata.namespace)/\(.metadata.name)"'
# empty output = all stopped
```

## After

Re-run `rhai-cli lint --target-version 3.3.2 --checks "*notebook*"`.
