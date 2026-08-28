# Resolver — Llama Stack / OGX

**rhai-cli signal:** `workload / llamastackdistribution / *`.

## Why

> **Llama Stack → OGX:** In 3.5, Llama Stack is renamed **OGX (Open GenAI Stack)** and the `LlamaStackDistribution` CR is replaced by **`OGXServer` (v1beta1)**. Existing data (agent state, telemetry, vector databases) is not portable across the rename and will be lost. Manually archive before migration and recreate resources afterward.
>
> — architectural-changes.md § *Data Considerations*

This is the one component where the migration guide explicitly documents **data loss**. The 2.25 Llama Stack stores everything in SQLite inside the pod's ephemeral storage; 3.5 rebrands the whole stack to OGX — the `LlamaStackDistribution` kind goes away, the CR becomes `OGXServer`, and the agent/vector APIs change shape. Upgrading without archiving = data gone.

## Enumerate every LlamaStackDistribution

```
oc get llamastackdistribution -A
```

If there are none, skip — nothing to archive.

## Archive every LlamaStackDistribution's data

In 3.5 the archive step runs through a `rhai-cli migrate prepare` action — `llamastack.backup` (it replaces the old `backup-all-llamastack.sh` helper). The migration guide §2.5 still puts the responsibility on the LSD owner (not the cluster admin) to confirm what needs archiving, because in-pod SQLite/emptyDir data is not portable across the OGX rename.

Preview what would be archived first with `--dry-run`:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate prepare --migration llamastack.backup \
  --target-version 3.5.0 --output-dir /tmp/rhoai-upgrade-backup/llamastack --dry-run
```

Then run it for real (drop `--dry-run`):

```
oc exec -n rhai-migration rhai-cli-0 -- \
  /opt/rhai-cli/bin/rhai-cli migrate prepare --migration llamastack.backup \
  --target-version 3.5.0 --output-dir /tmp/rhoai-upgrade-backup/llamastack
```

Copy the archive off the pod to your workstation:

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/llamastack ./llamastack-backup
```

If you need to confirm where a given LSD keeps its data before trusting the archive (Milvus on PVC, SQLite on emptyDir, etc.), inspect the pod's mounts:

```
NS=<llama-stack-namespace>
LSD=<llamastackdistribution-name>

POD=$(oc get pod -n "$NS" -l app.kubernetes.io/instance="$LSD" -o jsonpath='{.items[0].metadata.name}')
oc describe pod "$POD" -n "$NS" | grep -A1 -E 'Mounts:|Volume'

# Typical in-pod data paths:
#   /opt/app-root/src/milvus.db               (Milvus vector DB)
#   /opt/app-root/src/.llama/                 (agent state, SQLite)
#   /opt/app-root/src/telemetry.db            (SQLite telemetry)
```

## Callouts

- **`llamastack.backup` snapshots what it can, but it is not a portability guarantee.** The archive is a safety net for a known transition with breaking changes — data that lives only in the pod's SQLite/emptyDir may still not survive the OGX rename. Treat it as "capture everything you can before you delete", not "restore later".
- If the LSD data is already stored in an **external** Milvus/Postgres/S3 outside the pod, it survives. Only in-pod SQLite / emptyDir storage is lost.
- After the upgrade, owners must recreate their workloads as **`OGXServer` (v1beta1)** CRs — the `LlamaStackDistribution` kind no longer exists in 3.5. They cannot restore the old CR YAML because the kind changed and the spec schema changed (VectorDB API removed, Inference API became OpenAI-compatible, etc.); client apps must port to the new OGX APIs.

## Delete the LlamaStackDistribution CRs before upgrade

Once each LSD is archived (or you've decided its data isn't worth keeping), **delete the `LlamaStackDistribution` CRs before the upgrade** — they are recreated as `OGXServer` CRs afterward. The kind is removed in 3.5, so leaving them in place has nothing to reconcile against:

```
oc delete llamastackdistribution <name> -n <namespace>
```

For a workload whose data isn't worth archiving at all, deleting now and recreating fresh post-upgrade is the pragmatic choice — often the right call for Tech Preview workloads.

## After

Re-run `rhai-cli lint --target-version 3.5 --checks "*llamastack*"`. The check should no longer flag unarchived LSDs (rhai-cli can't tell if you actually archived — it just confirms you've acknowledged the data-loss warning by either archiving or deleting each LSD).

Post-upgrade, owners recreate their workloads as **`OGXServer` (v1beta1)** CRs and port client apps to the OGX APIs — the archive and the old `llsd-backup.yaml` serve only as a reference for the new spec. See the RHOAI 3.5 `working_with_ogx` documentation (formerly `working_with_llama_stack`) for the OGX APIs.
