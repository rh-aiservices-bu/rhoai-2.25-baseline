# Resolver — Kubeflow Training Operator (KFTO, post-upgrade)

*Covers migration guide §4.10 — citation only; user-facing label is `[kfto]`.*

## Why

In 3.x the training story moves to **Kubeflow Trainer v2** (a new `TrainJob` API with native Kueue integration) — architectural-changes.md § *Modern training with Kubeflow Trainer v2*. But the legacy KFTO v1 `PyTorchJob` (and siblings) is still supported for the 2→3 upgrade path: any in-flight PyTorchJobs continue to run and complete normally across the upgrade.

This resolver is a verification only. No configuration change is required.

## Verify

Run the `training.verify-workloads` migrate action. It is a **read-only enumeration** of the Kubeflow v1 workloads on the cluster — `PyTorchJob`, `TFJob`, `MPIJob`, `XGBoostJob` — reporting each one's readiness to migrate to Kubeflow Trainer v2. It **creates nothing and pulls no image** (unlike the old `kubeflow-trainer-verification.sh`, which spun up a test PyTorchJob and pulled a ~7-minute training image).

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate run --migration training.verify-workloads --target-version 3.5.0
```

Expected output:

- **"nothing to migrate" / "safe to proceed"** — no v1 workloads are in a blocking state; you're done.
- **`[BLOCKER]`** for any workload still **Running** or **Created** — that job must **complete or be stopped** before it can migrate to Trainer v2. Wait for it to finish, or stop it, then re-run the action.

A benign `phase pre-upgrade but effective phase is post-upgrade` warning may be printed — **ignore it** (see the migration guide's cross-cutting note).

## Inspect a blocked workload

If the action reports a `[BLOCKER]` and you want to see the underlying job:

```
oc get pytorchjob -A
# Each row shows STATE=Running / Created / Succeeded / Failed
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

Not required for this upgrade. `training.verify-workloads` only reports readiness — it does not perform the migration. Plan the move to `TrainJob` (Kubeflow Trainer v2) as a separate follow-up project. KFTO v1 will stay supported through the RHOAI 3.x stream.
