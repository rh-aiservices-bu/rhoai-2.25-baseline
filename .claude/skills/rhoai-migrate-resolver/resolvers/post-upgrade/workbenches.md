# Resolver — Workbenches (post-upgrade)

*Covers migration guide §4.7 — citation only; user-facing label is `[workbenches]`.*

Patch each stopped workbench to the 3.x auth layer, and handle users who couldn't stop theirs in time.

## Why

> Workbench images left unmigrated continue to operate on the older 2.25.10 authentication layer. This hybrid environment can result in redirection loops and connectivity failures, primarily due to **NB_PREFIX** routing conflicts for RStudio, code-server, and custom images.
>
> — migration guide, Workbenches after upgrade, "Perform a deferred workbench image migration"

The 2→3 auth change (oauth-proxy → kube-rbac-proxy) and Route → Gateway API routing require workbench pods to be started fresh with new env/sidecar config. The `workbenches.patch-auth-model` migration patches the Notebook CRs in place; it can only do that safely when the Notebook is Stopped.

## Prerequisite — notebook-controller pods

Confirm both controllers are Ready before running the migration:

```
oc get deployment -n redhat-ods-applications odh-notebook-controller-manager notebook-controller-deployment
# Expect: both 1/1 READY
```

## Patch stopped workbenches

Run the migration inside the rhai-cli pod. It prompts twice, so give it a TTY (`-it`):

```
oc exec -it -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration workbenches.patch-auth-model \
  --target-version 3.5.0 --only-stopped --with-cleanup
```

The action **prompts for interactive confirmation twice** — once before patching, once before the OAuth cleanup. Enter `y` at each prompt (this is why the command needs `-it`; without a TTY the prompt can't be answered).

You may also see a benign warning that can be **ignored**:

```
WARNING: migration workbenches.patch-auth-model has phase pre-upgrade but effective phase is post-upgrade
```

Expected final lines:

```
Processed N workbenches: all succeeded.
Cleanup: all N workbenches completed successfully.
```

After this, users can start their workbenches again. Notify them.

## Verify

```
oc exec -n rhai-migration rhai-cli-0 -- \
  rhai-cli migrate run --migration workbenches.verify-migration --target-version 3.5.0
# Expect: OK: All workbenches have been migrated.
```

Also ask users to confirm the IDE loads over HTTP/S (common failure is a redirect loop on stale sessions — a browser-side full reload with cleared cookies usually clears it).

## Deferred migration for workbenches that stayed running

Some users couldn't stop theirs during the maintenance window. Those Notebooks still use the 2.x auth layer and will hit redirect loops. Each user must migrate their own workbench post-upgrade:

### User task — pick one of:

1. **Dashboard-driven** — edit the workbench description in the dashboard and save. The dashboard patches the Notebook CR automatically. Guide:
   - Dashboard → Data Science Projects → pick project → Workbenches → Edit → Save
2. **Delete and recreate** — more invasive, but simpler for custom images. Use the **same PVC** to preserve data:
   ```
   NS=<namespace>; NAME=<notebook>
   # Preserve the PVC
   oc get pvc -n "$NS" -l notebook-name="$NAME"
   # Delete the Notebook (pod gets terminated, PVC survives)
   oc delete notebook "$NAME" -n "$NS"
   # Recreate via dashboard — reuse the existing PVC when prompted
   ```

### Image-version reminders

- **Jupyter-based:** bump to 2025.2 (recommended) — **except GPU images**, where the 2025.2 tag has a known CUDA regression on some driver versions (see § *GPU workbench Error 803 on the 2025.2 image tag* below).
- **code-server:** **must** bump to 2025.2. Older tags are broken under 3.x routing.
- **RStudio BuildConfig users:** tag must be `latest`. You also need a **new build** after the upgrade to pick up the Gateway API / kube-rbac-proxy image layers:
  ```
  oc start-build cuda-rstudio-server-rhel9 -n redhat-ods-applications --follow
  oc start-build rstudio-server-rhel9 -n redhat-ods-applications --follow
  ```
- **Custom images ("BYON"):** must be rebuilt for the [Kubernetes Gateway API path-based routing](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/managing_resources/introducing-kubernetes-gateway-api_resource-mgmt) and kube-rbac-proxy. This is a per-owner task — no platform-level fix. See the pre-upgrade [workbenches.md § Reuse the same `-gw` image across multiple clusters](../workbenches.md) for the dev → preprod → prod image-promotion pattern, and § Known RStudio `-gw` build gotchas for the two NGINX bugs that were caught in production.
  - **Exception — custom image built FROM the 2025.2 base:** a custom image whose Dockerfile is `FROM` the 2025.2 OOTB base **inherits** the Gateway API / NB_PREFIX support and kube-rbac-proxy layers. It needs only a **re-import** into the dashboard plus the `workbenches.patch-auth-model` patch above — no rebuild. Watch for the false-friend case: an image merely **tagged** `2025.2` but still built on an **older base** does *not* inherit any of this and still needs a full Gateway API rebuild.

## GPU notebooks pinned to a sha256 digest

Some users hard-code an image sha256 digest in the Notebook spec (`image: ...@sha256:<digest>`). Post-upgrade, switch to an ImageStream tag reference so the workbench survives image GC at the source registry:

```
# Find sha256-pinned notebooks
oc get notebooks -A -o json \
  | jq -r '.items[] | select(.spec.template.spec.containers[0].image | test("@sha256:")) | "\(.metadata.namespace)/\(.metadata.name)  image=\(.spec.template.spec.containers[0].image)"'

# Patch one — adjust the IS reference to match the cluster's actual ImageStream
NS=<ns>; NAME=<notebook>
oc patch notebook "$NAME" -n "$NS" --type=merge -p '{
  "spec":{"template":{"spec":{"containers":[{
    "name":"'"$NAME"'",
    "image":"image-registry.openshift-image-registry.svc:5000/redhat-ods-applications/custom-rh-cuda-jupyter-datascience-py311-main:jupyter-datascience-c9s-py311-cuda-devel-main"
  }]}}}}'
```

## Freezing default ImageStream reconciliation (hide ROCm, preserve older tags)

> Field-discovered on a 3.4 cluster (support case 04488542) — not yet documented in the migration guide. The fix follows KCS 7127886 (converting a managed image to BYON/unmanaged).

In 3.x the **Workbenches component of the DataScienceCluster owns the default (OOTB) notebook ImageStreams and reconciles them continuously.** There is no supported native toggle to hide default images yet (the RFE is approved but unshipped as of 3.4). Because of the reconcile loop:

- Deleting a default ImageStream → it is recreated.
- Removing `opendatahub.io/notebook-image` / `opendatahub.io/dashboard` labels → they are re-added.
- Once a newer tag exists (e.g. `2025.2`), the controller annotates older tags (`2025.1`) with `opendatahub.io/image-tag-outdated: "true"` and hides them from the dashboard dropdown. Manually deleting the annotation → it is re-added.
- Re-adding an old image through the dashboard's BYON flow creates a **separate, duplicate** dropdown entry — not a replacement for the hidden one.

### Fix — freeze the ImageStream so the controller stops managing it

Relabel the **existing** managed ImageStream as user-owned. `app.kubernetes.io/created-by=byon` signals BYON ownership, and the controller then leaves it alone — no recreation, no re-annotation, and no duplicate dropdown entry (it's still the same ImageStream object).

```sh
# Freeze — do this first, before any other label/annotation edit sticks
oc label imagestream <name> -n redhat-ods-applications \
  app.kubernetes.io/created-by=byon --overwrite
```

Then apply the outcome you want on the now-frozen ImageStream:

```sh
# (a) Hide it — e.g. ROCm images on an NVIDIA-only cluster
oc label imagestream <name> -n redhat-ods-applications \
  opendatahub.io/notebook-image=false opendatahub.io/dashboard=false --overwrite

# (b) Keep an older tag usable — strip the outdated annotation from that tag
oc annotate imagestreamtag <name>:2025.1 -n redhat-ods-applications \
  opendatahub.io/image-tag-outdated-
```

Find the ROCm ImageStreams to freeze/hide:

```sh
oc get imagestream -n redhat-ods-applications -o name | grep -i rocm
```

> **Tradeoff — say this to the user explicitly.** A frozen ImageStream no longer receives operator updates: no new tags, no CVE-patched digests. You now own its lifecycle. Keep a list of which images you froze so a later maintainer knows why they've stopped tracking the release stream. This is a deliberate escape hatch, not a default — revisit it once the hide-default-images RFE ships.

### Verify

```sh
# Which ImageStreams are now user-owned (frozen)
oc get imagestream -n redhat-ods-applications -l app.kubernetes.io/created-by=byon \
  -o custom-columns='NAME:.metadata.name,NOTEBOOK:.metadata.labels.opendatahub\.io/notebook-image,DASHBOARD:.metadata.labels.opendatahub\.io/dashboard'

# Confirm the outdated annotation is gone (empty output = cleared and staying cleared)
oc get imagestreamtag <name>:2025.1 -n redhat-ods-applications \
  -o jsonpath='{.metadata.annotations.opendatahub\.io/image-tag-outdated}'
```

Then confirm in the dashboard: the ROCm images are gone from the dropdown, and the preserved `2025.1` tag is selectable without a duplicate BYON entry.

## GPU workbench Error 803 on the 2025.2 image tag (CUDA compat path)

> Field-discovered on a 3.4 cluster (support case 04488542); root cause tracked in JIRA **AIPCC-7894**. This is an **image regression**, not a cluster misconfiguration.

**Symptom.** A GPU workbench started from the **`2025.2`** tag of a CUDA image (`pytorch`, `tensorflow`, `minimal-gpu`) can't reach the GPU: `torch.cuda.is_available()` is `False`, and CUDA init raises

```
Error 803: system has unsupported display driver / cuda driver combination
```

`nvidia-smi` works in the `nvidia-driver-daemonset` pod and the same image's `2025.1` / `3.4` tags work — only `2025.2` fails.

**Root cause.** The `2025.2` image ships an **active** `/usr/local/cuda/compat` entry in `/etc/ld.so.conf.d/*cuda*`, which puts the container's CUDA *compat* `libcuda.so.1` ahead of the **host driver's** `libcuda.so.1` that the NVIDIA Container Toolkit bind-mounts into `/lib64`. The compat lib then mismatches the host kernel driver → Error 803. Fixed images comment the compat line out; per AIPCC-7894 the compat path must come **after** `/lib64`.

### Diagnose (run inside the workbench terminal)

```sh
cat /etc/ld.so.conf.d/*cuda*                 # a *non-commented* /usr/local/cuda/compat line = affected
env | grep -E 'CUDA|NVIDIA|NUMBA'            # NUMBA_CUDA_DRIVER=/usr/local/cuda/compat/libcuda.so.1 confirms it
ldconfig -p | grep -i libcuda
```

### Fix — force the host driver path ahead of compat

Set `LD_LIBRARY_PATH=/lib64` on the workbench so the loader finds the host `libcuda.so.1` first. First check whether the container already defines `LD_LIBRARY_PATH` — that decides `add` vs `replace`:

```sh
NS=<ns>; NAME=<notebook>
oc get notebook "$NAME" -n "$NS" \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}{"\n"}{end}' | grep -n LD_LIBRARY_PATH
```

If it is **not** present, append it:

```sh
NS=<ns>; NAME=<notebook>
oc patch notebook "$NAME" -n "$NS" --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"LD_LIBRARY_PATH","value":"/lib64"}}
]'
```

If it **is** present at index `<i>` (from the grep line number, zero-based), replace that element instead:

```sh
NS=<ns>; NAME=<notebook>
oc patch notebook "$NAME" -n "$NS" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/env/<i>","value":{"name":"LD_LIBRARY_PATH","value":"/lib64"}}
]'
```

Restart the workbench (stop/start) so the new env takes effect.

**Alternative — pin to the `2025.1` tag** (which lacks the bad compat ordering) until a fixed `2025.2` image ships. If that tag has been hidden by the outdated-annotation behavior, un-hide it first via § *Freezing default ImageStream reconciliation* above.

### Verify (inside the workbench)

```sh
python3 -c 'import torch; print(torch.cuda.is_available()); print(torch.cuda.get_device_name(0))'
```

Expect `True` and the GPU model name (e.g. `NVIDIA L4`).

## Callouts

- **Do this resolver before the Ray resolver.** The Ray migration assumes the workbench controllers are already reconciled against 3.x config. Running Ray first can leave RayClusters in an inconsistent owner-reference state.
- If the migration reports `Failed: N` — do **not** force-start those Notebooks. Inspect each Notebook's events (`oc describe notebook <name> -n <ns>`) and open a support case rather than improvising.
- **Test one workbench before announcing.** A real-world `-gw` RStudio image had two NGINX bugs (`/api` 403 + redirect strips `NB_PREFIX`) that only surfaced when a user actually started the workbench post-upgrade. Pick one workbench per image variant, start it, hit the IDE in a browser, then notify users.
