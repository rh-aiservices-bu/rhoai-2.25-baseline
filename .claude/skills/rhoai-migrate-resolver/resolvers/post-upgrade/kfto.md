# Resolver — Kubeflow Training Operator (KFTO, post-upgrade)

*Covers migration guide §4.10 — citation only; user-facing label is `[kfto]`.*

## Why

In 3.x the training story moves to **Kubeflow Trainer v2** (a new `TrainJob` API with native Kueue integration) — architectural-changes.md § *Modern training with Kubeflow Trainer v2*. But the legacy KFTO v1 `PyTorchJob` (and siblings) is still supported for the 2→3 upgrade path: any in-flight PyTorchJobs continue to run and complete normally across the upgrade.

This resolver is a quick verification only. No configuration change is required.

## Verify

```
oc get pytorchjob -A
# Each row should show STATE=Running or Succeeded
```

If a PyTorchJob got stuck during the upgrade:

```
oc describe pytorchjob <name> -n <namespace>
oc get pods -n <namespace> -l training.kubeflow.org/job-name=<name>
oc logs -n <namespace> <master-pod> --previous 2>/dev/null || true
```

Common causes:

- **OCP upgrade happened during the job** — if the worker nodes were drained mid-job and the PyTorchJob didn't have checkpointing, the job may be Failed. Restart it.
- **GPU driver swap** — if NFD/GPU operator pods cycled during the RHOAI upgrade, GPU-using workers may have briefly lost `nvidia.com/gpu` allocatable. Verify:
  ```
  oc get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
  ```

## Migrate off KFTO v1?

Not required for this upgrade. Plan the move to `TrainJob` (Kubeflow Trainer v2) as a separate follow-up project. KFTO v1 will stay supported through the RHOAI 3.x stream.
