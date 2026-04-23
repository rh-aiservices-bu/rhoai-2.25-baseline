# Resolver — Llama Stack

**rhai-cli signal:** `workload / llamastackdistribution / *`.

## Why

> **Llama Stack:** Transitioning from SQLite to PostgreSQL. All existing data (agent state, telemetry, vector databases) will be lost. Manually archive before migration and recreate resources afterward.
>
> — architectural-changes.md § *Data Considerations*

This is the one component where the migration guide explicitly documents **data loss**. The 2.25 Llama Stack stores everything in SQLite inside the pod's ephemeral storage; 3.x uses PostgreSQL and the agent/vector APIs change shape. Upgrading without archiving = data gone.

## Enumerate every LlamaStackDistribution

```
oc get llamastackdistribution -A
```

If there are none, skip — nothing to archive.

## For each LSD, archive its data

The data lives inside the LSD's own pod. Which directories matter depends on how the user configured it (Milvus on PVC, SQLite on emptyDir, etc.). The migration guide §2.3.2 puts the responsibility on the LSD owner (not the cluster admin) to know what to archive.

Give the LSD owner this checklist. They need to run these for their own LSD:

```
NS=<llama-stack-namespace>
LSD=<llamastackdistribution-name>

# Find the pod
POD=$(oc get pod -n "$NS" -l app.kubernetes.io/instance="$LSD" -o jsonpath='{.items[0].metadata.name}')

# Inspect where data lives for this LSD
oc describe pod "$POD" -n "$NS" | grep -A1 -E 'Mounts:|Volume'

# Typical archive paths (adjust based on the pod's actual volume mounts):
#   /opt/app-root/src/milvus.db               (Milvus vector DB)
#   /opt/app-root/src/.llama/                 (agent state, SQLite)
#   /opt/app-root/src/telemetry.db            (SQLite telemetry)

# Tar them up locally
oc cp "$NS/$POD:/opt/app-root/src" ./lsd-archive-"$NS"-"$LSD"-$(date +%Y%m%d%H%M)
```

## Callouts

- **There is no tool that does this automatically.** Red Hat does not provide a migration script for Llama Stack data — it's a known TP-to-TP transition with breaking changes.
- If the LSD data is already stored in an **external** Milvus/Postgres/S3 outside the pod, it survives. Only in-pod SQLite / emptyDir storage is lost.
- After the upgrade, LSD owners must recreate LlamaStackDistribution CRs from scratch — they cannot restore the old CR YAML because the spec schema changed (VectorDB API removed, Inference API became OpenAI-compatible, etc.).

## Consider deferring

If the LSD's data isn't worth losing but isn't worth doing a custom archive for either, consider deleting the LSD before upgrade and recreating fresh post-upgrade. This is often the pragmatic choice for Tech Preview workloads:

```
oc delete llamastackdistribution <name> -n <namespace>
```

## After

Re-run `rhai-cli lint --target-version 3.3.2 --checks "*llamastackdistribution*"`. The check should no longer flag unarchived LSDs (rhai-cli can't tell if you actually archived — it just confirms you've acknowledged the data-loss warning by either archiving or deleting each LSD).
