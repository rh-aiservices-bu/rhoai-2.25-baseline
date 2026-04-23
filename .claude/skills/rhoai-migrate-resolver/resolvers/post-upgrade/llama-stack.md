# Resolver — Llama Stack (post-upgrade)

*Covers migration guide §4.4 — citation only; user-facing label is `[llama-stack]`.*

## Why

> **Llama Stack:** Transitioning from SQLite to PostgreSQL. All existing data (agent state, telemetry, vector databases) will be lost. Manually archive before migration and recreate resources afterward.
>
> — architectural-changes.md § *Data Considerations*

The old LSD CRs cannot be restored — the spec schema changed between 2.25 and 3.3.2 (VectorDB API removed, Inference API switched to OpenAI-compatible, Embedding API changed). Post-upgrade you recreate new LSDs from the data you archived during the pre-upgrade Llama Stack step.

**Skip this section if:**

- You didn't use Llama Stack in 2.25, or
- You are on a disconnected cluster (Llama Stack requires 3.0+ for disconnected — check your support window).

## Key 2.25 → 3.3.2 differences

| Field | 2.25 | 3.3.2 |
| --- | --- | --- |
| Database | SQLite (in-pod) | PostgreSQL 14+ (external) |
| Embedding provider | Implicit | **Must** be explicitly enabled (e.g. `sentence-transformers`) |
| Vector API | VectorDB (deprecated) | Vector_IO |
| Config file | `run.yaml` | `config.yaml` |
| Client library | `llama-stack-client` 0.2.x | `llama-stack-client` 0.4.x |

## Recreate LSDs from the pre-upgrade archive

1. Locate the `llsd-backup.yaml` files each LSD owner produced during the pre-upgrade archive step.
2. For each LSD, rewrite the CR to the 3.3.2 schema:
   - Rename/rewrite config references (`run.yaml` → `config.yaml`).
   - Add an explicit embedding provider.
   - Replace any VectorDB references with Vector_IO.
3. Apply the new CR:
   ```
   NS=<namespace>
   oc apply -f ./llsd-<NS>-<name>-3.3.2.yaml -n "$NS"
   ```
4. Recreate applications (agents, RAG pipelines) that depended on the LSD — they cannot reuse old state from the 2.x SQLite.

Follow the [Deploying a Llama Stack server](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/working_with_llama_stack/deploying-llama-stack-server_rag) docs for the 3.3.2 CR shape.

## Verify

```
oc get llamastackdistribution -A
# expect: PHASE=Ready for each (or Initializing briefly)

# Pod health per LSD
for ns in $(oc get llamastackdistribution -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get pods -n "$ns" -l app.kubernetes.io/name=llama-stack
done
```

## Callouts

- **Data is gone.** Telemetry, agent state, vector embeddings from 2.25 cannot be recovered — they live in ephemeral SQLite inside the old pod. Set expectations with LSD owners up front.
- **Client library bump.** Anyone calling the LSD from a workbench needs to bump `llama-stack-client` to 0.4.x. Pinned 0.2.x clients will fail against the new API shape.
