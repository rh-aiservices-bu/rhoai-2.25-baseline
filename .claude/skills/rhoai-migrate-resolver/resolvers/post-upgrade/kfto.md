# Resolver — Kubeflow Training Operator (KFTO, post-upgrade)

**rhai-cli signal:** user-facing label is `[kfto]`. Covers migration guide §4.10 (citation only). Verify-only — confirm in-flight PyTorchJobs survived the upgrade. No configuration change is required.

> **EMIT — DON'T EXECUTE.** Print these read-only commands for the admin to run; do not run them yourself. One step at a time, wait for "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<PYTORCHJOB>` | a PyTorchJob that got stuck | `oc get pytorchjob -A` |
| `<NAMESPACE>` | that PyTorchJob's namespace | `oc get pytorchjob -A` |
| `<MASTER_POD>` | the job's master pod | `oc get pods -n <NAMESPACE> -l training.kubeflow.org/job-name=<PYTORCHJOB>` |

## DO THIS

1. Verify PyTorchJobs.
   ```sh
   oc get pytorchjob -A
   ```
   → Expected: each row shows `STATE=Running` or `Succeeded`.
   → if a PyTorchJob is stuck / Failed: go to Step 2.

2. Diagnose a stuck PyTorchJob.
   ```sh
   oc describe pytorchjob <PYTORCHJOB> -n <NAMESPACE>
   oc get pods -n <NAMESPACE> -l training.kubeflow.org/job-name=<PYTORCHJOB>
   oc logs -n <NAMESPACE> <MASTER_POD> --previous 2>/dev/null || true
   ```
   Common causes:
   - **OCP upgrade happened during the job** — if the worker nodes were drained mid-job and the PyTorchJob didn't have checkpointing, the job may be Failed. Restart it.
   - **GPU driver swap** — if NFD/GPU operator pods cycled during the RHOAI upgrade, GPU-using workers may have briefly lost `nvidia.com/gpu` allocatable. Verify:
     ```sh
     oc get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
     ```

## Verify (read-only)

```sh
oc get pytorchjob -A
```
→ Expected: each row `STATE=Running` or `Succeeded`.

## Why (reference)

In 3.x the training story moves to **Kubeflow Trainer v2** (a new `TrainJob` API with native Kueue integration) — architectural-changes.md § *Modern training with Kubeflow Trainer v2*. But the legacy KFTO v1 `PyTorchJob` (and siblings) is still supported for the 2→3 upgrade path: any in-flight PyTorchJobs continue to run and complete normally across the upgrade.

## Notes & edge cases (reference)

- **Migrate off KFTO v1?** Not required for this upgrade. Plan the move to `TrainJob` (Kubeflow Trainer v2) as a separate follow-up project. KFTO v1 will stay supported through the RHOAI 3.x stream.
