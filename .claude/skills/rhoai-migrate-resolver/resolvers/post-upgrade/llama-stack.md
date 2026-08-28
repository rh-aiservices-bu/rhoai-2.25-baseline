# Resolver — OGX / Llama Stack (post-upgrade)

*Covers migration guide §4.4 — citation only; user-facing label is `[llama-stack]`.*

## Why

> **Llama Stack:** Transitioning from SQLite to PostgreSQL. All existing data (agent state, telemetry, vector databases) will be lost. Manually archive before migration and recreate resources afterward.
>
> — architectural-changes.md § *Data Considerations*

In 3.5 Llama Stack is renamed **OGX (Open GenAI Stack)** and the `LlamaStackDistribution` CR is replaced by **`OGXServer` (v1beta1)** — migration guide §4.4. The old CRs cannot be restored: the kind changed, the spec schema changed (VectorDB API removed, Inference API switched to OpenAI-compatible, Embedding API changed), and the data store moved from in-pod SQLite to external PostgreSQL. Post-upgrade you recreate the deployments as new `OGXServer` CRs, using the archive you captured pre-upgrade as a reference.

**Skip this section if:**

- You didn't use Llama Stack in 2.25, or
- The pre-upgrade archive step (`rhai-cli migrate prepare --migration llamastack.backup --target-version 3.5.0`) was never run (check `ls /tmp/rhoai-upgrade-backup/llama-stack/` inside the rhai-cli pod — if the directory is missing, there is nothing to recreate *from*), or
- You are on a disconnected cluster (Llama Stack / OGX requires 3.0+ for disconnected — check your support window).

If you **did** use Llama Stack in 2.25 but the backup is missing, the data cannot be recovered — the 2.x SQLite was wiped by the upgrade. You must rebuild any downstream agents / RAG pipelines from source.

## Key 2.25 → 3.5 differences

| Field | 2.25 | 3.5 |
| --- | --- | --- |
| CR kind | `LlamaStackDistribution` | **`OGXServer` (v1beta1)** — Llama Stack renamed OGX (Open GenAI Stack) |
| Database | SQLite (in-pod) | PostgreSQL 14+ (external) |
| Embedding provider | Implicit | **Must** be explicitly enabled (e.g. `sentence-transformers`) |
| Vector API | VectorDB (deprecated) | Vector_IO |
| Config file | `run.yaml` | `config.yaml` |
| Client library | `llama-stack-client` 0.2.x | OGX APIs / `llama-stack-client` 0.4.x |

## Recreate as OGXServer CRs from the pre-upgrade archive

1. Locate the `llsd-backup.yaml` files each Llama Stack owner produced during the pre-upgrade `llamastack.backup` archive step — use them **as a reference** for the recreated CRs.
2. For each archived `LlamaStackDistribution`, author a new **`OGXServer` (v1beta1)** CR:
   - Translate the spec to the `OGXServer` schema (config references `run.yaml` → `config.yaml`).
   - Add an explicit embedding provider.
   - Replace any VectorDB references with Vector_IO.
3. Apply the new CR:
   ```
   NS=<namespace>
   oc apply -f ./ogxserver-<NS>-<name>.yaml -n "$NS"
   ```
4. Recreate applications (agents, RAG pipelines) that depended on the LSD, porting them to the new **OGX APIs** — they cannot reuse old state from the 2.x SQLite.

Follow the [Deploying an OGX server](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_ogx/deploying-ogx-server_rag) docs for the 3.5 `OGXServer` CR shape.

## Verify

```
oc get ogxserver -A
# expect: PHASE=Ready for each (or Initializing briefly)

# Pod health per OGXServer
for ns in $(oc get ogxserver -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get pods -n "$ns"
done
```

If `oc get ogxserver` returns "server doesn't have a resource type", confirm the kind on the live cluster with `oc api-resources | grep -i ogx` — the CRD ships with the 3.5 operator.

## Callouts

- **Data is gone.** Telemetry, agent state, vector embeddings from 2.25 cannot be recovered — they lived in ephemeral SQLite inside the old pod, and the OGX rename replaces the CR outright. Set expectations with owners up front.
- **Client library / API bump.** Anyone calling the old LSD from a workbench must port to the OGX APIs (bump `llama-stack-client` to 0.4.x). Pinned 0.2.x clients will fail against the new API shape.
