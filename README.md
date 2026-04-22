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
| [30-samples/](rhoai-2254-install/30-samples/) | Flag-gated sample workloads covering every §2.x "Before upgrade" step: workbenches, KServe (serverless + modelmesh), LLM ISVC, Ray, KFTO, TrustyAI, AI Pipelines, Feature Store (Feast), Llama Stack, Model Registry |

## Prerequisites

- An OpenShift cluster you are logged into (`oc whoami` works)
- `oc`, `jq`, `envsubst` on your PATH
- A default `StorageClass`

The preflight check in [lib/common.sh](rhoai-2254-install/lib/common.sh) verifies all of the above before anything is applied.

## Usage

Install everything:

```sh
cd rhoai-2254-install
./install.sh
```

Skip the GPU phase or individual sample workloads via environment variables (all default to `1`):

```sh
INSTALL_GPU=0 \
INSTALL_RAY=0 \
INSTALL_TRUSTYAI=0 \
  ./install.sh
```

Full list of sample flags is at the top of [30-samples/run.sh](rhoai-2254-install/30-samples/run.sh). If a single sample fails, the phase keeps going and the failed samples are reported at the end — rerun just that one with `./30-samples/<name>/run.sh`.

Tear it all down (best-effort, reverse order):

```sh
./uninstall.sh
```

`uninstall.sh` does not remove cluster-wide CRDs — if you need a guaranteed-clean slate, reinstall against a fresh cluster.

## After the install

1. Run the migration assessment from chapter 1 of the migration guide.
2. Walk through chapter 2 (§2.x steps) to upgrade 2.25.4 → 3.3.2 against the workloads this repo deployed.
