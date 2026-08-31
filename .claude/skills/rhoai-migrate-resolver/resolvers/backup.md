# Resolver — Pre-upgrade backup (hard prerequisite)

*Not a `rhai-cli` finding — `prereqs.sh` flags this as a WARN because it can't be verified from inside the cluster. It is still a HARD requirement for any in-place migration: without a verified backup, there is no rollback path if the upgrade fails.*

## Why

> Full, verified backup of OpenShift and OpenShift AI is **mandatory** before an in-place migration. There is no automated rollback once the migration begins. Restoring from a verified backup is the only path back, and may require rebuilding the entire cluster.
>
> — RHOAI 2→3 architectural rationale, *Migration Path: In-Place* / *Risk Factors*

For in-place migrations specifically: the operator version, dependent operators (Service Mesh, Serverless, RHCL), CRD schemas, and component reconciler behaviour all change in a single transition. None of those changes are reversible by patching. The migration guide is explicit that restoring the entire cluster from a verified backup is the *only* supported rollback.

For side-by-side migrations the backup is recommended (you keep the 2.25 cluster running until cutover), but not as critical — the 2.25 cluster itself is the rollback.

## What "verified backup" means here

Three layers, all of which the user owns end-to-end (this resolver guides; it does not execute):

| Layer | Protects | Tool |
| --- | --- | --- |
| **1. etcd snapshot** | Full cluster control plane: OCP itself, RHOAI operator state, every dependent operator (Serverless, Service Mesh, cert-manager, RHCL, etc.), every CR, Secret, and CRD instance | OCP-shipped `cluster-backup.sh` on a control-plane node |
| **2. OADP (Velero)** | User-namespace workloads + PVC contents (workbench storage, pipeline artefacts, model artefacts, etc.) | OADP Operator from `redhat-operators` (channel `stable`) |
| **3. rhai-cli migrate artefacts** | Per-component pre/post-migration backups (TrustyAI metrics, Llama Stack / OGX data, Ray cluster YAMLs, inferenceservice-config) | `/tmp/rhoai-upgrade-backup` PVC inside the rhai-cli pod, generated during migration |

Layers 1 + 2 are the baseline that must be in place **before** running any pre-migration prep step. Layer 3 fills up as you run the `rhai-cli migrate` actions during the prep phase.

**This skill's procedures do NOT include a YAML config export of DSC/DSCI/dashboard-config.** That kind of export duplicates content already in the etcd snapshot, it's incomplete relative to what RHOAI actually owns, and operators self-reconcile so you can't replay it as a restore. Use Layer 1 for the operator-state safety net.

The full procedure (commands, OADP install, S3 wiring, discovery sweep, verification, restore drill) is in [BACKUP-RESTORE.md](../../../../BACKUP-RESTORE.md) at the repo root. This resolver gives the minimum-viable summary for skill use.

## Minimum-viable verification commands

### Layer 1 — etcd snapshot is fresh

```
oc get configmaps -n openshift-etcd | grep cluster-backup    # most recent ConfigMap timestamp
# or, if the user keeps backups off-cluster (the correct pattern), just confirm with them:
#   "When was the last cluster-backup.sh run, and where are the snapshot.db + static_kuberesources.tar.gz files stored?"
```

Two artefacts must exist off-cluster and be reachable for restore:

- `snapshot_<DATETIME>.db`
- `static_kuberesources_<DATETIME>.tar.gz`

If the answer is "we don't have one" or "older than this morning", **stop and run [BACKUP-RESTORE.md § Layer 1](../../../../BACKUP-RESTORE.md) before continuing the migration**.

### Layer 2 — OADP backup of user namespaces is Completed

```
# Is OADP installed?
oc get csv -n openshift-adp 2>/dev/null | grep oadp-operator

# Latest backup
oc get backup -n openshift-adp -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,ERRORS:.status.errors,WARNINGS:.status.warnings,STARTED:.status.startTimestamp' \
  | tail -5

# PVC content actually moved off-cluster (CSI snapshot + DataMover)
NAME=<latest backup name>
oc get datauploads.velero.io -n openshift-adp -l velero.io/backup-name="$NAME" \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,BYTES:.status.progress.bytesDone'
```

Pass criteria for the latest backup:

- `PHASE=Completed`
- `ERRORS=0`
- Every DataUpload row shows `PHASE=Completed` with `BYTES>0`

If any DataUpload is `Failed` or has `BYTES=0`, the PVC content didn't make it to the BSL. Most common causes: missing `VolumeSnapshotClass` for the storage driver, or the snapshot class isn't labeled `velero.io/csi-volumesnapshot-class=true`.

> **Important — do NOT trust PodVolumeBackup phase=Completed alone.** RHOAI workbenches are managed as StatefulSets. With `defaultVolumesToFsBackup: true` the kopia-style filesystem backup completes cleanly and the PodVolumeBackup shows non-zero bytes, but on restore the StatefulSet controller deletes the Velero-injected Pod (the one carrying the `restore-wait` init container) and recreates it from its template — leaving the PVC empty. The supported approach is CSI snapshot + DataMover (`defaultVolumesToFsBackup: false`, `snapshotMoveData: true`); see [BACKUP-RESTORE.md](../../../../BACKUP-RESTORE.md) for the DPA + Backup CR shape that was validated end-to-end on a 2.25.10 (and later) rehearsal cluster.

### Namespace discovery sanity check

Layer 2's discovery key is the Tier-1 and Tier-2 K8s CRD types from the [OpenShift AI API Tiers KB (article 7047935)](https://access.redhat.com/articles/7047935). The legacy `opendatahub.io/dashboard=true` label is **not** a reliable discovery signal — any namespace can host RHOAI workloads now, regardless of label.

Quick spot-check that the workload namespaces in the latest Velero Backup match what's actually deployed:

```
# Namespaces in the backup
NAME=<latest backup name>
oc get backup -n openshift-adp "$NAME" -o jsonpath='{.spec.includedNamespaces}' | tr ',' '\n'

# Namespaces actually hosting Tier-1/2 RHOAI workloads
for kind in notebooks.kubeflow.org pytorchjobs.kubeflow.org rayclusters.ray.io rayjobs.ray.io \
            inferenceservices.serving.kserve.io llminferenceservices.serving.kserve.io \
            servingruntimes.serving.kserve.io trustyaiservices.trustyai.opendatahub.io \
            mlflows.opendatahub.io modelregistries.modelregistry.opendatahub.io; do
  oc get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null
done | sort -u
```

The second list should be a subset of the first. Anything in the second list missing from the backup means a user workload type was created in a namespace the discovery sweep missed.

If the cluster uses Beta/Alpha/Tier-4 APIs that customers commonly rely on (DSPAs, LlamaStackDistributions, GuardrailsOrchestrators, FeatureStores), those aren't Red Hat–supported tiers but are typically still in scope for backup — see the [optional extended sweep](../../../../BACKUP-RESTORE.md#optional--extend-discovery-for-alphabetatier-4-workloads-you-actually-use) in BACKUP-RESTORE.md.

## Don't ship without these

1. **Both etcd backup files** (`snapshot.db` and `static_kuberesources.tar.gz`) are off-cluster and reachable from the workstation that will run a restore if needed.
2. **OADP `Backup` resource is `Completed`** with `Errors=0`, all PodVolumeBackups Completed with `BYTES>0`.
3. **A restore drill has been done at least once** before the production migration — restore a single namespace from Layer 2 into a scratch namespace and confirm the workloads come back. The first time you exercise the restore path should not be when the upgrade has just failed.

## Pre-upgrade ordering

Backup belongs **before** any of the other pre-upgrade resolvers (Kueue → Removed, cert-manager install, KServe conversions, etc.). The reason: those resolvers all mutate state. If anything goes sideways at step N, you want the backup to capture state from before step 1.

The skill's `prereqs.sh` script flags the backup as a `WARN` because it cannot be verified from inside the cluster — the off-cluster storage and "restore drill complete" status are out of scope for a single oc-based check. Treat the WARN as an explicit user attestation that the backup is in place, **not** as a checkbox the script ticked for you.

## When the user opts you into execute mode

Running the actual backup is a meaningful action with off-cluster side effects (writes to an S3 bucket). Under the skill's *execute mode* rules:

- **Layer 1 (etcd snapshot):** safe to execute on the user's behalf if they have explicitly opted in. The `oc debug node` invocation is read-only on the cluster and writes only to the node's local filesystem.
- **Off-cluster `cat`-over-stdout copy:** safe — read-only.
- **OADP install:** if not already installed, this creates a subscription + OperatorGroup in `openshift-adp`. Treat as a mutating action with the standard execute-mode disclosure ("creating subscription redhat-oadp-operator in openshift-adp") before running.
- **`DataProtectionApplication` apply:** requires real S3 credentials. **Never embed credentials in commands you run on the user's behalf** — always have the user provide the credentials interactively or via a pre-staged Secret; emit a placeholder template, not real keys.
- **`Backup` CR apply:** safe; OADP does the rest.

If the user has not opted in, emit the commands from [BACKUP-RESTORE.md](../../../../BACKUP-RESTORE.md) and let them run them.
