# GitOps install path (Argo CD / OpenShift GitOps)

This directory is an Argo CD deployment of the same pre-migration cluster the bash
`install.sh` builds. It runs **alongside** the script path — pick whichever fits
your workflow. Both end at the same state: RHOAI 2.25.6 + Service Mesh v2 +
Serverless + standalone Authorino + a fully `Managed` DataScienceCluster, plus
the optional sample workloads.

## How it's structured

```
gitops/
├── bootstrap.sh            ← one-shot driver (installs GitOps + applies root app)
├── render.sh               ← seds REPO_URL/TARGET_REVISION into apps/*.yaml (run per fork)
├── uninstall.sh            ← tears down Applications, OpenShift GitOps, RHOAI, samples
├── .env.example            ← copy to .env to set REPO_URL / TARGET_REVISION / OVERLAY
├── bootstrap/              ← cluster prereqs (GitOps operator, ArgoCD config, RBAC, root Application)
├── apps/                   ← one Argo CD Application per phase / per sample
├── overlays/
│   ├── all/                ← full pre-migration state (parity with install.sh defaults)
│   └── minimal/            ← operators + DSC only, no samples
├── manifests/20-dsc/       ← rendered DSC/DSCI (envsubst defaults baked in)
└── hooks/                  ← sync-hook Jobs (InstallPlan approval, modelmesh rollout)
```

The Applications under `apps/` point back at the **existing** phase directories
(`10-operators/`, `20-dsc/`, `30-samples/<sample>/`). Argo CD's directory source
ignores the `run.sh` files and only applies the YAMLs. The two cases where the
bash path does something beyond `oc apply` are handled by post-sync hook Jobs:

- **RHOAI InstallPlan approval** ([hooks/approve-installplan.yaml](hooks/approve-installplan.yaml)) — the RHOAI Subscription uses `installPlanApproval=Manual` to pin `rhods-operator.2.25.6`. Argo CD won't approve InstallPlans, so a PostSync Job approves any pending InstallPlan in `redhat-ods-operator`. Idempotent and safe to re-run.
- **ModelMesh controller rollout** ([hooks/rollout-modelmesh-controller.yaml](hooks/rollout-modelmesh-controller.yaml)) — the ModelMesh sample applies a `model-serving-config` ConfigMap that the controller only reads at startup. A PostSync Job restarts the deployment so `allowAnyPVC=true` + `podsPerRuntime=1` take effect.

## Sync waves

Argo CD applies child Applications in order of `argocd.argoproj.io/sync-wave`:

| Wave | What runs                                                                 |
| ---: | :------------------------------------------------------------------------ |
|  -5  | namespaces (istio-system, knative-serving, openshift-serverless, redhat-ods-operator) |
|   0  | Service Mesh v2, Serverless, standalone Authorino Subscriptions           |
|   5  | RHOAI Subscription + InstallPlan-approval PostSync Job                    |
|  10  | DSCInitialization + DataScienceCluster                                    |
|  20  | All sample workloads (workbenches, kserve-*, ray, kfto, trustyai, …)      |

Within a wave Argo CD applies Applications in parallel and **retries** rather
than blocks on CRD readiness — `wait_for_crd` is replaced by `retry.backoff`.
A sample that needs a CRD installed by the DSC will fail its first sync, sleep,
and re-sync until the CRD lands.

For that retry-until-CRD-lands pattern to work reliably, every `30-sample-*`
Application uses:

* `retry.limit: 60` with `backoff.duration: 30s`, `factor: 2`,
  `maxDuration: 2m` — ~2h of retry budget, covering a slow RHOAI operator
  install (KServe CRDs in particular can lag DSC creation by 20+ minutes).
* `syncOptions.SkipDryRunOnMissingResource=true` — Argo CD's early dry-run
  check tolerates the target CRD being absent instead of failing fast.
* `syncOptions.RespectIgnoreDifferences=true` — the dry-run check honours the
  Application's `ignoreDifferences` block so operator-defaulted fields on a
  half-applied resource don't spuriously re-mark it OutOfSync.

If you see a sample sitting `OutOfSync / Missing` for more than ~30 min after
the DSC reports `Ready`, that budget wasn't the issue — check the app's
`.status.operationState.message` for the underlying failure.

## Bootstrap

1. Fork this repo to a Git remote Argo CD can reach.
2. Set the env vars (either inline or in `.env`):

   ```sh
   cp gitops/.env.example gitops/.env
   $EDITOR gitops/.env       # set REPO_URL at minimum
   ```

3. Bake the repo URL and revision into `apps/*.yaml`, then commit + push:

   ```sh
   ./gitops/render.sh                      # writes REPO_URL/TARGET_REVISION into gitops/apps/*.yaml
   git add gitops/apps
   git commit -m "gitops: render apps for <your-fork>"
   git push
   ```

   Argo CD reads `apps/*.yaml` directly from Git via kustomize — placeholder
   values (`${REPO_URL}`) can't be substituted at bootstrap time because
   `envsubst` never sees those files. `render.sh` handles this once per fork
   and is idempotent, so re-running it after changing `.env` is safe.

4. Log in to the cluster as `cluster-admin` and run:

   ```sh
   ./gitops/bootstrap.sh
   ```

   The script installs the OpenShift GitOps operator, waits for the
   `openshift-gitops-server` Deployment to be Available, grants the application
   controller `cluster-admin`, and applies the root Application.

4. Watch progress:

   ```sh
   oc -n openshift-gitops get applications.argoproj.io
   oc -n openshift-gitops get route openshift-gitops-server \
     -o jsonpath='https://{.spec.host}{"\n"}'
   ```

The full install takes ~15-25 minutes end-to-end — most of which is the RHOAI
CSV becoming Ready and the DSC reconciling all of its component operators.

## Picking an overlay

`OVERLAY=all` (the default) gives you everything the bash `install.sh` deploys
with its default flags. `OVERLAY=minimal` skips the sample workloads — useful
when you want a clean RHOAI 2.25.6 install and will hand-deploy your own samples.

To make a custom overlay, copy `overlays/all/` to `overlays/<name>/`, remove the
lines you don't want, and set `OVERLAY=<name>` before running `bootstrap.sh`.

## Coexistence with `install.sh`

Both paths read from the same source manifests under `05-gpu/`, `10-operators/`,
`20-dsc/`, and `30-samples/<sample>/`, so a change to those directories is
picked up by **both** paths automatically. The GitOps-specific files are:

- `gitops/manifests/20-dsc/{dsci,dsc}.yaml` — rendered defaults (the originals use `envsubst`)
- `gitops/hooks/*.yaml` — sync-hook Jobs that replace bash orchestration
- `gitops/apps/*.yaml` and `gitops/bootstrap/*.yaml` — Argo CD plumbing

Running `install.sh` after a GitOps bootstrap (or vice versa) is safe — both are
idempotent `oc apply` — but Argo CD will mark anything that drifts from Git as
`OutOfSync` and (if automated sync is on) revert it on the next reconcile loop.

## Why the ArgoCD instance is patched

`gitops/bootstrap/15-argocd-config.yaml` sets `kustomizeBuildOptions:
"--load-restrictor=LoadRestrictionsNone"` on the openshift-gitops ArgoCD CR.
Kustomize's default `LoadRestrictionsRootOnly` forbids `resources:` entries
that reference files above the kustomization directory — the overlays here
reference `../../apps/*.yaml`, which trips that check. Setting
`LoadRestrictionsNone` disables the restriction globally on the ArgoCD
repo-server. If your platform team runs a shared openshift-gitops instance and
this patch is unacceptable, refactor the overlays into self-contained
directories (copy the Application YAMLs directly into each overlay) so no
`..` traversal is needed.

## Limitations

- **InstallPlan pinning.** The RHOAI Subscription stays Manual approval, but the
  approval Job approves *every* pending InstallPlan in `redhat-ods-operator`, so a
  future upgrade plan would also get auto-approved if you re-sync after the
  operator's channel head moves. That's fine for a lab install and matches what
  the bash path does, but it's not the production pinning behavior.
- **No GPU phase yet.** The `05-gpu/` install isn't exposed as a GitOps overlay —
  the bash path skips it by default (`INSTALL_GPU=0`) and the lab samples are
  CPU-only. Add a `05-gpu` Application + an `all-gpu` overlay if you need it.
- **The assessment-driven install (`install-from-assessment.sh`) has no GitOps
  equivalent** — the env-var derivation it does is shell-specific. Build the
  state you want by hand-editing `manifests/20-dsc/dsc.yaml` and the overlay
  resource list.
