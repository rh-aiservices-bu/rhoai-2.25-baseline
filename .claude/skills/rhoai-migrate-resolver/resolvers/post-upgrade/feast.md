# Resolver — Feature Store (post-upgrade)

*Covers migration guide §4.3 — citation only; user-facing label is `[feast]`.*

## Why

Feature Store was Tech Preview in 2.25.4 and goes GA in 3.3.2. The component itself is functionally unchanged between versions — only the support status moves. No architectural change driver.

Skip this section entirely if you didn't use Feature Store in 2.25.

## Verify

```
# Operator pod
oc get pods -n redhat-ods-applications | grep feast-operator
# expect: feast-operator-controller-manager-*  1/1  Running

# Every FeatureStore instance Ready
oc get featurestores --all-namespaces
# expect: STATUS=Ready for each row

# CronJobs per namespace (user-defined ingestion schedules)
for ns in $(oc get featurestore -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
  echo "--- $ns ---"
  oc get cronjob -n "$ns"
done
```

## If a FeatureStore is not Ready

```
oc describe featurestore <name> -n <namespace>
oc logs -n <namespace> -l app=<name> --tail=50
```

Common post-upgrade cause: the feast-operator controller hadn't finished reconciling yet — wait ~2 minutes and re-check. If it stays non-Ready for more than 5 minutes, open a support case with the describe + logs output.

## No dashboard change

Feature Store does not move in the dashboard nav between 2.x and 3.x. Users can use their existing bookmarks.
