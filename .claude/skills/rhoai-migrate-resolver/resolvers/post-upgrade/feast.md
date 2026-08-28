# Resolver — Feature Store (post-upgrade)

*Covers migration guide §4.3 — citation only; user-facing label is `[feast]`.*

## Why

Feature Store was Tech Preview in 2.25 and goes **GA in 3.5**. The component itself is functionally unchanged between versions — only the support status moves. No architectural change driver.

Skip this section entirely if you didn't use Feature Store in 2.25.

## Verify

Per migration guide §4.3 (three steps + a dashboard verification).

### Step 1 — operator pod

```
oc get pods -n redhat-ods-applications | grep feast-operator
# expect: feast-operator-controller-manager-*  1/1  Running
```

### Step 2 — all FeatureStore instances Ready

```
oc get featurestores --all-namespaces
# expect: STATUS=Ready for each row
```

### Step 3 — exercise each FeatureStore's CronJobs

For each FeatureStore namespace, list its CronJobs and *create a real Job from one* to confirm the schedule wiring survived the upgrade. This is the guide's explicit verification — not just listing the CronJobs.

```
for ns in $(oc get featurestore -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get cronjobs -n "$ns"
done

# Per namespace, pick a CronJob and trigger it:
NS=<namespace>; CJ=<cronjob-name>
oc create job "postupgradetest-$(date +%s)" --from=cronjob/"$CJ" -n "$NS"
oc get jobs -n "$NS"
# expect the new Job to show STATUS=Complete within ~1 minute
```

### Step 4 — dashboard verification (user task)

> **The dashboard URL changed at 3.x.** Migration guide §4.3 says: "The URL for the OpenShift AI 3.5 dashboard uses Gateway API access and is different from the 2.25 URL. The 2.25 dashboard URL is no longer accessible. If you have bookmarked the OpenShift AI dashboard URL, you must update the bookmark to point to the 3.5 URL."
>
> Earlier revisions of this resolver claimed "Feature Store does not move in the dashboard nav between 2.x and 3.x. Users can use their existing bookmarks." Both halves were wrong. Drop them.

Tell each Feature Store user to:

1. Open the new 3.5 dashboard (Gateway API URL — `oc get gatewayconfigs -A -o jsonpath='{range .items[*]}{.spec.hostname}{"\n"}{end}'`).
2. Navigate to **Develop & train → Feature Store**.
3. For each FeatureStore they configured in 2.25, confirm the UI still shows the expected features, entities, feature-views, data sources, and feature services.

## If a FeatureStore is not Ready

```
oc describe featurestore <name> -n <namespace>
oc logs -n <namespace> -l app=<name> --tail=50
```

Common post-upgrade cause: the feast-operator controller hadn't finished reconciling yet — wait ~2 minutes and re-check. If it stays non-Ready for more than 5 minutes, open a support case with the describe + logs output.
