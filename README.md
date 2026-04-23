# rhoai-migrations

Scripts and manifests for standing up a Red Hat OpenShift AI (RHOAI) cluster in a known "before" state so the RHOAI **2.25.4 → 3.3.2** migration procedure can be exercised end-to-end.

The install drops a cluster into exactly the configuration that each §2.x step of the migration guide expects to operate on. Once it's up, you run the migration assessment (chapter 1) and walk through the upgrade (chapter 2) against real workloads.

## What it installs

Everything lives under [rhoai-2254-install/](rhoai-2254-install/) and runs in four phases:

| Phase | What it does |
| --- | --- |
| [05-gpu/](rhoai-2254-install/05-gpu/) | NFD + NVIDIA GPU Operator (auto-skipped if GPU capacity is already allocatable) |
| [10-operators/](rhoai-2254-install/10-operators/) | Service Mesh v2, Serverless, Authorino, and the RHOAI 2.25.4 operator (pinned) |
| [20-dsc/](rhoai-2254-install/20-dsc/) | `DSCInitialization` + `DataScienceCluster` — all components Managed, KServe in Serverless mode, ModelMesh Managed |
| [30-samples/](rhoai-2254-install/30-samples/) | Flag-gated sample workloads covering every §2.x "Before upgrade" step: workbenches (incl. a custom upstream Jupyter image), BYON orphan ImageStream, KServe (Serverless + ModelMesh + RawDeployment), LLM ISVC, Ray, KFTO, TrustyAI, AI Pipelines, Feature Store (Feast), Llama Stack, Model Registry |

## Prerequisites

- OpenShift **4.19.9 or newer** (hard requirement from migration guide §1.2)
- Cluster pull secret with auth for `registry.redhat.io` — RHOAI, Service Mesh 2, Serverless, and NFD all pull from there. RHDP / sandbox clusters have this pre-wired; bare OCP installs need `oc set data secret/pull-secret -n openshift-config ...`
- An OpenShift cluster you are logged into (`oc whoami` works) with cluster-admin
- `oc`, `jq`, `envsubst` on your PATH
- A default `StorageClass`

The preflight check in [lib/common.sh](rhoai-2254-install/lib/common.sh) verifies OCP login, default StorageClass, and tool presence before anything is applied.

## Usage

Install everything:

```sh
cd rhoai-2254-install
./install.sh
```

Skip or override individual phases and samples via environment variables:

```sh
INSTALL_RAY=0 \
INSTALL_TRUSTYAI=0 \
  ./install.sh
```

Sample flags (`INSTALL_RAY`, `INSTALL_WORKBENCHES`, etc.) all default to `1`. Full list is at the top of [30-samples/run.sh](rhoai-2254-install/30-samples/run.sh). If a single sample fails, the phase keeps going and the failed samples are reported at the end — rerun just that one with `./30-samples/<name>/run.sh`.

`INSTALL_GPU` is tri-state:

- `auto` (default) — install NFD + NVIDIA GPU Operator only if no node has `nvidia.com/gpu` allocatable; skip otherwise. Safe to re-run.
- `1` — force install even if drivers are already present
- `0` — skip entirely

Tear it all down (best-effort, reverse order):

```sh
./uninstall.sh
```

`uninstall.sh` does not remove cluster-wide CRDs — if you need a guaranteed-clean slate, reinstall against a fresh cluster.

## Expected "not Ready" states

A successful install leaves two workloads in non-Ready states on purpose — don't chase them:

- **RStudio workbench** stays Stopped. The `rstudio-rhel9` ImageStream ships with no built tag; an admin has to run its BuildConfig (licensing dependency) before it can start. Realistic pre-migration state: the Notebook exists but isn't running.
- **ModelMesh ISVC** (`my-modelmesh-isvc`) reports `Ready=False`. Its `storage-config` Secret points at a dummy S3 endpoint. Migration tooling only needs the ISVC + ServingRuntime to exist to detect them; actual model loading is out of scope.

## After the install

1. Run the migration assessment from chapter 1 of the migration guide (`rhai-cli lint --target-version 3.3.2`).
2. Walk through chapter 2 (§2.x steps) to resolve every blocker — the [rhoai-migrate-resolver](.claude/skills/rhoai-migrate-resolver/) skill below guides you through this step-by-step.
3. Proceed to chapter 3 of the migration guide once the readiness validation is clean.

## Resolving migration blockers (Claude Code skill)

A Claude Code skill, [rhoai-migrate-resolver](.claude/skills/rhoai-migrate-resolver/), walks a cluster administrator through resolving every blocker `rhai-cli` reports. The skill is **read-only on the cluster** — it recommends `oc` commands and explains *why* each change is needed (citing [architectural-changes.md](architectural-changes.md)) but never executes mutations itself.

### Use the skill inside Claude Code

Open this project in Claude Code, then:

```
/rhoai-migrate-resolver
```

Claude will ask for the `rhai-cli` output (file path or pasted table), parse the `prohibited` / `critical` rows, and walk you through one resolver at a time.

### Or run the two helper scripts directly

Both scripts are self-contained bash — no Claude Code required — and only use read-only `oc get` / `oc describe`:

```sh
# Before you start — are the platform prerequisites met? (OCP version, pull secret, StorageClass, DSC present)
bash .claude/skills/rhoai-migrate-resolver/scripts/prereqs.sh

# After all migration prep — is every §2.x blocker resolved?
bash .claude/skills/rhoai-migrate-resolver/scripts/validate.sh
```

Exit `0` means all checks pass; `1` means at least one FAIL. Run `validate.sh` *with* `rhai-cli lint`, not instead of it — they cross-check each other.

### What the skill covers

Each resolver under [.claude/skills/rhoai-migrate-resolver/resolvers/](.claude/skills/rhoai-migrate-resolver/resolvers/) maps a class of `rhai-cli` output rows to a fix. See [resolvers/README.md](.claude/skills/rhoai-migrate-resolver/resolvers/README.md) for the full `(GROUP, KIND, CHECK) → resolver` mapping. Coverage spans every migration path the install script deliberately creates — Kueue removal, KServe Serverless/ModelMesh conversion, Service Mesh 2 / Serverless / standalone Authorino uninstall, workbench image rebuilds, TrustyAI + Ray + Llama Stack backups, LLMInferenceService template pinning, and more.
