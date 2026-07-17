# Resolver — Workbenches

**rhai-cli signal:** `workload / notebook / *` — image-version, custom-image, stopped.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc patch` / `oc annotate` / `oc tag` / `oc start-build` / `podman` command yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are fine.
> Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<NAMESPACE>` | the workbench's namespace | the survey `jq` command at the top of each sub-issue prints `namespace<TAB>name` |
| `<NOTEBOOK>` | the Notebook CR name | same survey command |
| `<IMAGESTREAM>` | a BYON ImageStream name | `oc get imagestream -n redhat-ods-applications -l app.kubernetes.io/created-by=byon` |
| `<TAG>` | the original image tag being made gateway-ready | the existing tag on that BYON ImageStream |
| `<DEV_INTERNAL_REGISTRY>` | the source cluster's internal-registry host holding the tested `-gw` image | on the source cluster: `oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}'` |

## DO THIS

### Sub-issue 1 — code-server workbenches must be on `2025.2` before upgrade

code-server workbenches on older image tags break in 3.x. Update the Notebook CRs to the `2025.2` tag.

1. List current code-server workbenches and their image tag (read-only).

   ```sh
   oc get notebooks -A -o json \
     | jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("code-?server")) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.template.spec.containers[0].image)"'
   ```
   → Expected: a `namespace<TAB>name<TAB>image` row per code-server workbench (empty = none to fix).

2. For each one, patch to tag `2025.2`. ⚠️ Destructive — mutates the Notebook CR. Confirm first.

   ```sh
   NS=<NAMESPACE>; NAME=<NOTEBOOK>
   oc patch notebook "$NAME" -n "$NS" --type=json \
     -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/code-server-notebook:2025.2"}]'
   ```
   → Expected: `notebook.kubeflow.org/<NOTEBOOK> patched`. (code-server is CPU-only — the `2025.2`
   GPU Error 803 caveat in Notes does NOT apply here.)

### Sub-issue 2 — RStudio workbenches must use the `latest` tag

RStudio images are built per-cluster via BuildConfigs (licensing constraint). The tag must be `latest`
— the build recreates that tag after the 3.x upgrade.

1. Ensure the BuildConfigs are present and the latest build has succeeded (read-only).

   ```sh
   oc get bc -n redhat-ods-applications | grep rstudio
   oc get is rstudio-rhel9 cuda-rstudio-rhel9 -n redhat-ods-applications
   ```
   → Expected: rstudio BuildConfigs listed and the two ImageStreams present. If the ImageStreams have
   no built tag, see Notes → "RStudio is Tech Preview and not built by default" before proceeding.

2. List current RStudio notebooks (read-only).

   ```sh
   oc get notebooks -A -o json \
     | jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("rstudio")) | "\(.metadata.namespace)\t\(.metadata.name)\t\(.spec.template.spec.containers[0].image)"'
   ```
   → Expected: a `namespace<TAB>name<TAB>image` row per RStudio workbench.

3. Update each to the `latest` tag. ⚠️ Destructive — mutates the Notebook CR. Confirm first.

   ```sh
   NS=<NAMESPACE>; NAME=<NOTEBOOK>
   oc patch notebook "$NAME" -n "$NS" --type=json \
     -p='[{"op":"replace","path":"/spec/template/spec/containers/0/image","value":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/rstudio-rhel9:latest"}]'
   ```
   → Expected: `notebook.kubeflow.org/<NOTEBOOK> patched`. Post-upgrade the image must be rebuilt
   (see architectural-changes.md § *Networking and Authentication Changes*); that step happens after
   the 3.3.2 upgrade itself.

### Sub-issue 3 — Custom ("BYON") workbench images must be rebuilt for Gateway API + kube-rbac-proxy

For every custom ImageStream in `redhat-ods-applications` with labels
`app.kubernetes.io/created-by: byon` and `opendatahub.io/notebook-image: "true"`.

1. Enumerate BYON images (IS objects that may or may not have active Notebooks) — read-only.

   ```sh
   oc get imagestream -n redhat-ods-applications -l app.kubernetes.io/created-by=byon \
     -o custom-columns='NAME:.metadata.name,CREATOR:.metadata.annotations.opendatahub\.io/notebook-image-creator,URL:.metadata.annotations.opendatahub\.io/notebook-image-url'
   ```
   → Expected: one row per BYON ImageStream. Exclude any `^runtime-*` image — those are AI-Pipeline
   runtime base images, not workbenches (see Notes).

2. Survey who owns each BYON IS (read-only).

   ```sh
   oc get imagestream -n redhat-ods-applications -l app.kubernetes.io/created-by=byon \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.opendatahub\.io/notebook-image-creator}{"\n"}{end}'
   ```
   → Expected: `imagestream<TAB>creator` per BYON image.

3. Each owner rebuilds their Dockerfile to:
   - Remove the oauth-proxy sidecar config; 3.x uses kube-rbac-proxy injected by the platform.
   - Use path-based routing via Gateway API (3.x), not the 2.x Route-based path handling.

   The owner then pushes the new image (new tag, by convention `<original-tag>-gw` for
   "gateway-ready"), updates the ImageStream, and recreates the Notebook. Red Hat does not provide an
   automated rebuild — this is an application-owner task.

4. If you already have a tested `-gw` image on another cluster, you can reuse it as-is rather than
   rebuilding per cluster — see Notes → "Reuse the same `-gw` image across multiple clusters".

### Sub-issue 4 — All workbenches must be Stopped before the upgrade

**rhai-cli signal:** `workload / notebook / stopped`.

1. Survey which workbenches are running — by pod count, not annotation (read-only; see Verify note).

   ```sh
   for nb in $(oc get notebooks -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
     ns="${nb%/*}"; name="${nb##*/}"
     pods=$(oc -n "$ns" get pods -l notebook-name="$name" --no-headers 2>/dev/null | wc -l | tr -d ' ')
     [ "$pods" -gt 0 ] && echo "$nb has $pods pod(s) running"
   done
   ```
   → Expected: one line per running workbench (empty = all already stopped).

2. Stop one — set the annotation to an ISO timestamp (this is what the dashboard does). ⚠️ Destructive
   — disconnects that user's active session.

   ```sh
   NS=<NAMESPACE>; NAME=<NOTEBOOK>
   oc annotate notebook "$NAME" -n "$NS" \
     kubeflow-resource-stopped="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite
   ```
   → Expected: `notebook.kubeflow.org/<NOTEBOOK> annotated`.

3. Stop all. ⚠️ Destructive — disconnects ALL active users. Do this in the maintenance window itself,
   not earlier. Confirm first.

   ```sh
   STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
   for row in $(oc get notebooks -A --no-headers | awk '{print $1"/"$2}'); do
     oc annotate notebook "${row##*/}" -n "${row%%/*}" \
       kubeflow-resource-stopped="$STAMP" --overwrite
   done
   ```
   → Expected: an `annotated` line per notebook. Confirm with Verify.

## Verify (read-only)

The notebook controller treats `kubeflow-resource-stopped` as "stopped if present and non-empty" — the
dashboard sets it to an ISO timestamp, not the literal `"true"`. Filters that check for `== "true"`
report stopped notebooks as still running. The reliable check is **pod count**:

```sh
# No workbenches still running — pod-count gate (the rhai-cli check uses this signal too)
for nb in $(oc get notebooks -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'); do
  ns="${nb%/*}"; name="${nb##*/}"
  pods=$(oc -n "$ns" get pods -l notebook-name="$name" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "$pods" -gt 0 ] && echo "$nb still has $pods pod(s)"
done
```
→ Expected: empty output = all stopped.

For the annotation-only check (faster but blind to "annotation missing entirely yet pod is gone" cases):

```sh
oc get notebooks -A -o json \
  | jq -r '.items[] | select((.metadata.annotations."kubeflow-resource-stopped" // "") == "") | "\(.metadata.namespace)/\(.metadata.name)"'
```
→ Expected: empty output = all stopped via annotation.

Then re-run the lint check:

```sh
rhai-cli lint --target-version 3.3.2 --checks "*notebook*"
```
→ Expected: the notebook check reports passing.

## Why (reference)

> Existing custom workbench images and RStudio images will fail due to routing conflicts with the new auth mechanism — they must be rebuilt. All running workbenches must be stopped before migration; unmigrated workbenches will experience redirection loops.
>
> — architectural-changes.md § *Networking and Authentication Changes*

> oauth-proxy is tightly coupled to the internal OpenShift OAuth Server and cannot support external Identity Providers. […] Custom workbench images built for the oauth-proxy flow will need to be rebuilt.
>
> — architectural-changes.md § *Authentication: oauth-proxy to kube-rbac-proxy*

The migration changes routing (Route → Gateway API) and auth (oauth-proxy → kube-rbac-proxy). Images built for 2.x embed the oauth-proxy sidecar config; under 3.x they hit redirect loops.

## Notes & edge cases (reference)

### Don't double-count Pipeline runtime images

ImageStreams matching `^runtime-` (e.g. `runtime-pytorch`, `runtime-rocm-tensorflow`) are AI-Pipeline
runtime base images, not workbenches. The operator auto-updates them on upgrade — exclude them from the
BYON list in Sub-issue 3.

### Reuse the same `-gw` image across multiple clusters (dev → preprod → prod)

Once a `-gw` image is built and tested on one cluster, it can be reused as-is on other clusters with the
same source image — no rebuild per cluster. Pull from the source cluster's internal registry (or any
external registry the image was pushed to), then push to the target's internal registry:

```sh
# On the target cluster
SRC_IMAGE=<DEV_INTERNAL_REGISTRY>/redhat-ods-applications/<IMAGESTREAM>:<TAG>-gw
INTERNAL_REG=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')

podman login "${INTERNAL_REG}" -u "$(oc whoami)" -p "$(oc whoami -t)" --tls-verify=false
podman pull "$SRC_IMAGE"
podman tag  "$SRC_IMAGE" "${INTERNAL_REG}/redhat-ods-applications/<IMAGESTREAM>:<TAG>-gw"
podman push "${INTERNAL_REG}/redhat-ods-applications/<IMAGESTREAM>:<TAG>-gw" --tls-verify=false

# Import as a tag on the target cluster's ImageStream
oc tag "${INTERNAL_REG}/redhat-ods-applications/<IMAGESTREAM>:<TAG>-gw" \
       "<IMAGESTREAM>:<TAG>-gw" \
       -n redhat-ods-applications --reference-policy=local --insecure=true
```

`--reference-policy=local` makes the IS pin the image to the local registry (rather than re-resolving
against the source registry, which the target cluster can't reach). `--insecure=true` is needed for the
default OpenShift internal registry self-signed cert.

### Known RStudio `-gw` build gotchas

If you're building the RStudio `-gw` image yourself (or auditing one), two specific NGINX config bugs
to watch for:

1. **Redirect strips `NB_PREFIX`.** The stock RStudio image redirects to `/rstudio/` without the
   workbench's `NB_PREFIX`, which works under 2.x Routes but produces "page not found" under 3.x
   Gateway API path-based routing. Fix: keep `NB_PREFIX` in every `Location:` header NGINX emits.
2. **`/api` endpoint `SCRIPT_FILENAME` resolution.** An inline rewrite + FastCGI for `${NB_PREFIX}/api`
   breaks `SCRIPT_FILENAME` because the variable depends on the NGINX `root` directive in the original
   `/api/` block. Fix: revert `/api` endpoints to a 302 redirect pattern, not an inline rewrite.
   Symptom of the bug: pod 2/2 Ready but readiness probe returns 403; users see "Service Unavailable".

Both bugs were observed in real-world `-gw` builds and require a rebuild after fixing the NGINX config.

### RStudio is Tech Preview and not built by default

The `rstudio-rhel9` and `cuda-rstudio-rhel9` ImageStreams ship with the RHOAI operator but have **no
built tag** — the BuildConfig requires RHEL subscription credentials and must be triggered manually:

```sh
# Check whether the BuildConfigs have ever produced a usable tag
oc get is rstudio-rhel9 cuda-rstudio-rhel9 -n redhat-ods-applications -o custom-columns='NAME:.metadata.name,TAGS:.status.tags[*].tag'
# Empty TAGS column = never built. Trigger:
oc start-build rstudio-server-rhel9 -n redhat-ods-applications --follow
oc start-build cuda-rstudio-server-rhel9 -n redhat-ods-applications --follow
```

Plan separately: building RStudio for the first time usually needs the cluster admin to attach a RHEL
entitlement to the cluster, which is its own ticket.

### GPU workbench using a sha256 digest

Some users hard-code the image as `image: ...@sha256:<digest>` in the Notebook spec. Two problems:

- The digest can disappear from the source registry (image GC, retention policy) — workbench then fails
  to start.
- It's invisible to BYON discovery (`oc get is -l app.kubernetes.io/created-by=byon` won't list it).

After the upgrade — or as part of pre-upgrade hygiene — switch to an ImageStream tag reference. First
find sha256-pinned notebooks:

```sh
oc get notebooks -A -o json | jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("@sha256:")) | "\(.metadata.namespace)/\(.metadata.name)  image=\(.spec.template.spec.containers[0].image)"'
```

Then, ⚠️ destructive — mutates the Notebook CR. Example for a CUDA Jupyter workbench:

```sh
NS=<NAMESPACE>; NAME=<NOTEBOOK>
oc patch notebook "$NAME" -n "$NS" --type=merge -p '{
  "spec":{"template":{"spec":{"containers":[{
    "name":"'"$NAME"'",
    "image":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/custom-rh-cuda-jupyter-datascience-py311-main:jupyter-datascience-c9s-py311-cuda-devel-main"
  }]}}}}'
```

### Image registry change between 2.x tags

The OOTB workbench images switched their source registry between tag generations:

| Tag | Source registry |
|---|---|
| `1.2`–`2024.2` | `quay.io/modh/*` or `quay.io/opendatahub/*` (community) |
| `2025.1`+ | `registry.redhat.io/rhoai/odh-workbench-*` (GA) |
| `2025.2`+ | Same `registry.redhat.io/...` plus Python 3.12 / UBI 9 base |

Both remain functional after the 3.3.2 upgrade. The migration just bumps the operator-managed
ImageStreams; existing Notebook CRs keep their existing image refs unless the owner explicitly bumps
the tag.

### GPU workbench Error 803 on the `2025.2` image tag

> **Before you bump GPU workbenches to `2025.2`:** the `2025.2` tag of the CUDA images (`pytorch`,
> `tensorflow`, `minimal-gpu`) has a known regression on some NVIDIA driver versions — a stray
> `/usr/local/cuda/compat` entry in the loader path shadows the host `libcuda.so.1` and CUDA init fails
> with `Error 803: system has unsupported display driver / cuda driver combination` (JIRA AIPCC-7894,
> support case 04488542). It only surfaces once the workbench is started post-upgrade. Plan to either
> keep GPU workbenches on `2025.1` or apply the `LD_LIBRARY_PATH=/lib64` workaround — see
> [post-upgrade/workbenches.md § GPU workbench Error 803 on the 2025.2 image tag](post-upgrade/workbenches.md).
> CPU/Jupyter images are unaffected.

<!--
maintainer history — IGNORE when running the resolver. Not for the user.
No crossed-out commands recorded for this resolver. All four sub-issues, the -gw reuse/build gotchas,
the RStudio Tech-Preview build path, the sha256-digest fix, the registry-change table, and the 2025.2
GPU Error 803 warning are preserved from the original; only reorganized (mutating steps into DO THIS,
gotchas/edge cases into Notes).
-->
