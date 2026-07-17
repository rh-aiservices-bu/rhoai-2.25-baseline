# Resolver — Llama Stack

**rhai-cli signal:** `workload / llamastackdistribution / *`.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc cp` / `oc delete` yourself unless the user explicitly said "run it" for THIS resolver.
> Read-only `oc get`/`describe` are fine. Work one step at a time — after each step, STOP and
> wait for the user to say "done".

> ⚠️ **DATA LOSS.** This is the one component where the migration guide explicitly documents
> data loss. 2.25 Llama Stack stores everything (agent state, telemetry, vector DBs) in SQLite
> inside the pod's ephemeral storage; 3.x uses PostgreSQL. **Upgrading without archiving = data
> gone, with no recovery.** Do not run the upgrade until every LSD's in-pod data is archived or
> the owner has accepted the loss.

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<LSD_NAMESPACE>` | namespace of the LlamaStackDistribution | `oc get llamastackdistribution -A` |
| `<LSD_NAME>` | name of the LlamaStackDistribution | `oc get llamastackdistribution -A` |

## DO THIS

1. **Enumerate every LlamaStackDistribution.**

   ```sh
   oc get llamastackdistribution -A
   ```

   → if there are none: skip — nothing to archive.
   → if one or more exist: archive each (Step 2) or defer each (Step 3).

2. **For each LSD, archive its data.** The data lives inside the LSD's own pod. Which directories matter depends on how the user configured it (Milvus on PVC, SQLite on emptyDir, etc.). Guide §2.3.2 puts the responsibility on the LSD *owner* (not the cluster admin) to know what to archive — give the owner this checklist to run for their own LSD.

   ```sh
   NS=<LSD_NAMESPACE>
   LSD=<LSD_NAME>

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

   → if the LSD data is already stored in an **external** Milvus/Postgres/S3 outside the pod: it survives — no archive needed. Only in-pod SQLite / emptyDir storage is lost.

3. **Consider deferring (optional).** If the LSD's data isn't worth losing but isn't worth a custom archive either, delete the LSD before upgrade and recreate fresh post-upgrade. Often the pragmatic choice for Tech Preview workloads. ⚠️ Destructive — deletes the LlamaStackDistribution and its in-pod data. Confirm with the owner before running.

   ```sh
   oc delete llamastackdistribution <LSD_NAME> -n <LSD_NAMESPACE>
   ```

## Verify (read-only)

Re-run rhai-cli after archiving/deleting each LSD:

```sh
rhai-cli lint --target-version 3.3.2 --checks "*llamastackdistribution*"
```

→ Expected: the check no longer flags unarchived LSDs. (rhai-cli can't tell if you actually archived — it just confirms you've acknowledged the data-loss warning by either archiving or deleting each LSD.)

## Why (reference)

> **Llama Stack:** Transitioning from SQLite to PostgreSQL. All existing data (agent state, telemetry, vector databases) will be lost. Manually archive before migration and recreate resources afterward.
>
> — architectural-changes.md § *Data Considerations*

This is the one component where the migration guide explicitly documents **data loss**. The 2.25 Llama Stack stores everything in SQLite inside the pod's ephemeral storage; 3.x uses PostgreSQL and the agent/vector APIs change shape. Upgrading without archiving = data gone.

## Notes & edge cases (reference)

- **There is no tool that does this automatically.** Red Hat does not provide a migration script for Llama Stack data — it's a known TP-to-TP transition with breaking changes.
- If the LSD data is already stored in an **external** Milvus/Postgres/S3 outside the pod, it survives. Only in-pod SQLite / emptyDir storage is lost.
- After the upgrade, LSD owners must recreate LlamaStackDistribution CRs from scratch — they cannot restore the old CR YAML because the spec schema changed (VectorDB API removed, Inference API became OpenAI-compatible, etc.).
