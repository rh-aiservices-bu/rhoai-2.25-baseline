# Resolver — AI Pipelines (post-upgrade)

*Covers migration guide §4.5 — citation only; user-facing label is `[pipelines]`.*

## Why

Pipeline runs keep executing across the upgrade, but DSPA spec, endpoint URLs, and permissions can drift. The `post_upgrade_check.sh` helper confirms every DSPA server pod is healthy after the operator swap. Users then validate that their pipelines actually run.

## Administrator task

```
oc exec -n rhai-migration rhai-cli-0 -- \
  bash /opt/rhai-upgrade-helpers/ai_pipelines/post_upgrade_check.sh
```

The script prints per-DSPA status. Expect either `All pipelines server pods are healthy` or a note that a pod is in the same state it was before upgrade (idle DSPAs stay idle).

**Prerequisite** — `post_upgrade_check.sh` diffs against `/tmp/rhoai-upgrade-backup/ai_pipelines/dspa_pre_upgrade_pods.json`. That file is written only by `check_before_upgrade.sh` during the pre-upgrade phase. If you skipped the pre-upgrade check, the post-upgrade script exits with `ERROR: Pre-upgrade state file not found`. Fall back to the manual verification below:

```
# Every DSPA Ready
oc get dspa -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status'

# All per-DSPA pods Running (label is component=data-science-pipelines)
for ns in $(oc get dspa -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get pods -n "$ns" -l component=data-science-pipelines
done
```

If the output flags a specific DSPA as unhealthy, inspect directly:

```
oc get dspa <name> -n <namespace> -o yaml | yq .status
oc get pods -n <namespace> -l component=data-science-pipelines
oc logs -n <namespace> -l component=ds-pipeline-persistenceagent --tail=50
```

## Pipeline user task

Tell each user with pipelines to validate:

1. **Import a pipeline** via the dashboard.
   - Confirm it appears on **Pipeline definitions** and on the project's **Pipelines** tab.
2. **Execute a pipeline run.**
   - Confirm it progresses Pending → Running → Succeeded on the **Runs** page.
3. **Check scheduled runs.**
   - Previously-configured schedules must still be enabled on the **Runs** page. 3.x does not re-enable them automatically if they were disabled by the upgrade.
4. **Re-run any in-progress pipeline** that failed during the upgrade window once the DSPA is confirmed healthy.

## Endpoint URLs

DSPA endpoints move from Route to Gateway API. External CI/CD that triggers pipeline runs against the old 2.x Route URL will 404. Audit every integration — bookmarks, GitHub Actions, Jenkins, etc. — and update to the new Gateway-based URL. Architectural-changes.md § *Networking: Routes to Kubernetes Gateway API* is the "why".

## Verify

- Every DSPA shows `Ready=True`:
  ```
  oc get dspa -A -o json \
    | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)=\((.status.conditions[] | select(.type=="Ready") | .status))"'
  ```
- At least one pipeline user has successfully imported + run a pipeline.
- Scheduled runs still show as Enabled on the Runs page.
