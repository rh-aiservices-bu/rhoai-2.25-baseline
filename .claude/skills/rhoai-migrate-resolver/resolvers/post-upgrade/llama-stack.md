# Resolver — Llama Stack (post-upgrade)

**rhai-cli signal:** user-facing label is `[llama-stack]`. Covers migration guide §4.4 (citation only). The 2.x SQLite data was lost in the upgrade — you recreate new LSDs from the archive captured during the pre-upgrade Llama Stack step.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / helper script yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<NAMESPACE>` | the LSD's namespace | `oc get llamastackdistribution -A` |
| `<LSD_NAME>` | the LSD name | `oc get llamastackdistribution -A` |

## DO THIS

0. **Skip this section entirely if any of these hold:**
   - You didn't use Llama Stack in 2.25, or
   - The pre-upgrade archive step was never run — check inside the rhai-cli pod:
     ```sh
     oc exec -n rhai-migration rhai-cli-0 -- ls /tmp/rhoai-upgrade-backup/llama-stack/
     ```
     → if the directory is missing: there is nothing to recreate *from*. If you **did** use Llama Stack in 2.25 but the backup is missing, the data cannot be recovered (the 2.x SQLite was wiped by the upgrade) — rebuild any downstream agents / RAG pipelines from source.
   - Or you are on a disconnected cluster (Llama Stack requires 3.0+ for disconnected — check your support window).

   The old LSD CRs cannot be restored — the spec schema changed between 2.25 and 3.3.2 (VectorDB API removed, Inference API switched to OpenAI-compatible, Embedding API changed). You recreate new LSDs from the archived data.

1. Locate the `llsd-backup.yaml` files each LSD owner produced during the pre-upgrade archive step.

2. For each LSD, rewrite the CR to the 3.3.2 schema:
   - Rename/rewrite config references (`run.yaml` → `config.yaml`).
   - Add an explicit embedding provider (e.g. `sentence-transformers`).
   - Replace any VectorDB references with Vector_IO.

   Follow the [Deploying a Llama Stack server](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/working_with_llama_stack/deploying-llama-stack-server_rag) docs for the 3.3.2 CR shape. See Notes for the full 2.25 → 3.3.2 field mapping.

3. ⚠️ Applies a new CR to the cluster. Confirm the rewritten YAML before running. Apply the new CR:
   ```sh
   NS=<NAMESPACE>
   oc apply -f ./llsd-<NAMESPACE>-<LSD_NAME>-3.3.2.yaml -n "$NS"
   ```

4. Recreate applications (agents, RAG pipelines) that depended on the LSD — they cannot reuse old state from the 2.x SQLite.

## Verify (read-only)

```sh
oc get llamastackdistribution -A

# Pod health per LSD
for ns in $(oc get llamastackdistribution -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get pods -n "$ns" -l app.kubernetes.io/name=llama-stack
done
```
→ Expected: `PHASE=Ready` for each LSD (or `Initializing` briefly); the per-LSD pods `Running`.

## Why (reference)

> **Llama Stack:** Transitioning from SQLite to PostgreSQL. All existing data (agent state, telemetry, vector databases) will be lost. Manually archive before migration and recreate resources afterward.
>
> — architectural-changes.md § *Data Considerations*

The old LSD CRs cannot be restored — the spec schema changed between 2.25 and 3.3.2 (VectorDB API removed, Inference API switched to OpenAI-compatible, Embedding API changed). Post-upgrade you recreate new LSDs from the data you archived during the pre-upgrade Llama Stack step.

## Notes & edge cases (reference)

**Key 2.25 → 3.3.2 differences**

| Field | 2.25 | 3.3.2 |
| --- | --- | --- |
| Database | SQLite (in-pod) | PostgreSQL 14+ (external) |
| Embedding provider | Implicit | **Must** be explicitly enabled (e.g. `sentence-transformers`) |
| Vector API | VectorDB (deprecated) | Vector_IO |
| Config file | `run.yaml` | `config.yaml` |
| Client library | `llama-stack-client` 0.2.x | `llama-stack-client` 0.4.x |

- **Data is gone.** Telemetry, agent state, vector embeddings from 2.25 cannot be recovered — they live in ephemeral SQLite inside the old pod. Set expectations with LSD owners up front.
- **Client library bump.** Anyone calling the LSD from a workbench needs to bump `llama-stack-client` to 0.4.x. Pinned 0.2.x clients will fail against the new API shape.
