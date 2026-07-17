# Resolver — AI Pipelines (post-upgrade)

**rhai-cli signal:** user-facing label is `[pipelines]`. Covers migration guide §4.5 (citation only). Run the `post_upgrade_check.sh` helper to confirm every DSPA server pod is healthy after the operator swap, then have users validate their pipelines actually run.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run. Do NOT run any
> `oc apply` / `oc patch` / `oc delete` / `oc create` / helper script yourself unless the
> user explicitly said "run it" for THIS resolver. Read-only `oc get`/`describe`/`logs` are
> fine. Work one blocker at a time — after each step, STOP and wait for the user to say "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<DSPA_NAME>` | a DSPA flagged unhealthy | `oc get dspa -A` |
| `<NAMESPACE>` | that DSPA's namespace | `oc get dspa -A` |

## DO THIS

1. Administrator task — run the post-upgrade check helper.
   ```sh
   oc exec -n rhai-migration rhai-cli-0 -- \
     bash /opt/rhai-upgrade-helpers/ai_pipelines/post_upgrade_check.sh
   ```
   → Expected: per-DSPA status, ending in either `All pipelines server pods are healthy` or a note that a pod is in the same state it was before upgrade (idle DSPAs stay idle).
   → if it exits with `ERROR: Pre-upgrade state file not found`: the pre-upgrade check was skipped (the script diffs against `/tmp/rhoai-upgrade-backup/ai_pipelines/dspa_pre_upgrade_pods.json`, written only by `check_before_upgrade.sh`). Fall back to Step 2.

2. Manual verification (only if Step 1 could not run).
   ```sh
   # Every DSPA Ready
   oc get dspa -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'

   # All per-DSPA pods Running (label is component=data-science-pipelines)
   for ns in $(oc get dspa -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
     echo "--- $ns ---"
     oc get pods -n "$ns" -l component=data-science-pipelines
   done
   ```
   → Expected: every DSPA `READY=True`; all `component=data-science-pipelines` pods `Running`.

3. If a specific DSPA is flagged unhealthy, inspect it directly.
   ```sh
   oc get dspa <DSPA_NAME> -n <NAMESPACE> -o yaml | yq .status
   oc get pods -n <NAMESPACE> -l component=data-science-pipelines
   oc logs -n <NAMESPACE> -l component=ds-pipeline-persistenceagent --tail=50
   ```

4. Pipeline user task — tell each user with pipelines to validate:
   1. **Import a pipeline** via the dashboard — confirm it appears on **Pipeline definitions** and on the project's **Pipelines** tab.
   2. **Execute a pipeline run** — confirm it progresses Pending → Running → Succeeded on the **Runs** page.
   3. **Check scheduled runs** — previously-configured schedules must still be enabled on the **Runs** page. 3.x does not re-enable them automatically if they were disabled by the upgrade.
   4. **Re-run any in-progress pipeline** that failed during the upgrade window once the DSPA is confirmed healthy.

## Verify (read-only)

```sh
# Every DSPA shows Ready=True
oc get dspa -A -o json \
  | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)=\((.status.conditions[] | select(.type=="Ready") | .status))"'
```
→ Expected: each line ends `=True`. Plus: at least one pipeline user has successfully imported + run a pipeline, and scheduled runs still show as Enabled on the Runs page.

## Why (reference)

Pipeline runs keep executing across the upgrade, but DSPA spec, endpoint URLs, and permissions can drift. The `post_upgrade_check.sh` helper confirms every DSPA server pod is healthy after the operator swap. Users then validate that their pipelines actually run.

## Notes & edge cases (reference)

- **Endpoint URLs move from Route to Gateway API.** External CI/CD that triggers pipeline runs against the old 2.x Route URL will 404. Audit every integration — bookmarks, GitHub Actions, Jenkins, etc. — and update to the new Gateway-based URL. Architectural-changes.md § *Networking: Routes to Kubernetes Gateway API* is the "why".
