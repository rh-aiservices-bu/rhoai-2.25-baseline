# Resolver — Feature Store (post-upgrade)

**rhai-cli signal:** user-facing label is `[feast]`. Covers migration guide §4.3 (citation only). Verify-only — confirm the feast operator, every FeatureStore, and its CronJobs survived the upgrade, then tell users the dashboard URL changed. Skip entirely if you didn't use Feature Store in 2.25.

> **EMIT — DON'T EXECUTE.** Print these commands for the admin to run; do not run them yourself. One step at a time, wait for "done".

## Fill in these first

| Placeholder | What it is | Get it with |
| --- | --- | --- |
| `<NAMESPACE>` | a FeatureStore's namespace | `oc get featurestore -A` |
| `<CRONJOB_NAME>` | a CronJob in that namespace | `oc get cronjobs -n <NAMESPACE>` |
| `<FEATURESTORE_NAME>` | a FeatureStore that is not Ready | `oc get featurestores --all-namespaces` |

## DO THIS

Per migration guide §4.3 (three verify steps + a dashboard verification).

1. Verify the operator pod is up.
   ```sh
   oc get pods -n redhat-ods-applications | grep feast-operator
   ```
   → Expected: `feast-operator-controller-manager-*  1/1  Running`.

2. Verify all FeatureStore instances are Ready.
   ```sh
   oc get featurestores --all-namespaces
   ```
   → Expected: `STATUS=Ready` for each row.
   → if any row is not Ready: see Notes → "If a FeatureStore is not Ready".

3. Exercise each FeatureStore's CronJobs. List them, then create a real Job from one to confirm the schedule wiring survived — this is the guide's explicit verification, not just listing the CronJobs.
   ```sh
   for ns in $(oc get featurestore -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' | sort -u); do
     echo "--- $ns ---"
     oc get cronjobs -n "$ns"
   done
   ```
   Then, per namespace, pick a CronJob and trigger it (this **creates a real test Job** — emit for the admin to run):
   ```sh
   NS=<NAMESPACE>; CJ=<CRONJOB_NAME>
   oc create job "postupgradetest-$(date +%s)" --from=cronjob/"$CJ" -n "$NS"
   oc get jobs -n "$NS"
   ```
   → Expected: the new Job shows `STATUS=Complete` within ~1 minute.

4. Dashboard verification (user task). **The dashboard URL changed at 3.x.** Migration guide §4.3 says: "The URL for the OpenShift AI 3.3.2 dashboard uses Gateway API access and is different from the 2.25.4 URL. The 2.25.4 dashboard URL is no longer accessible. If you have bookmarked the OpenShift AI dashboard URL, you must update the bookmark to point to the 3.3.2 URL."

   Tell each Feature Store user to:
   1. Open the new 3.3.2 dashboard (Gateway API URL):
      ```sh
      oc get gatewayconfigs -A -o jsonpath='{range .items[*]}{.spec.hostname}{"\n"}{end}'
      ```
   2. Navigate to **Develop & train → Feature Store**.
   3. For each FeatureStore they configured in 2.25, confirm the UI still shows the expected features, entities, feature-views, data sources, and feature services.

## Verify (read-only)

```sh
oc get pods -n redhat-ods-applications | grep feast-operator
oc get featurestores --all-namespaces
```
→ Expected: operator pod `1/1 Running`; every FeatureStore `STATUS=Ready`; the test Job from Step 3 reached `Complete`.

## Why (reference)

Feature Store was Tech Preview in 2.25.4 and goes GA in 3.3.2. The component itself is functionally unchanged between versions — only the support status moves. No architectural change driver.

## Notes & edge cases (reference)

- **Skip this section entirely if you didn't use Feature Store in 2.25.**
- **If a FeatureStore is not Ready:**
  ```sh
  oc describe featurestore <FEATURESTORE_NAME> -n <NAMESPACE>
  oc logs -n <NAMESPACE> -l app=<FEATURESTORE_NAME> --tail=50
  ```
  Common post-upgrade cause: the feast-operator controller hadn't finished reconciling yet — wait ~2 minutes and re-check. If it stays non-Ready for more than 5 minutes, open a support case with the describe + logs output.

<!--
maintainer history — IGNORE when running the resolver. Not for the user.
Earlier revisions of this resolver claimed "Feature Store does not move in the dashboard nav
between 2.x and 3.x. Users can use their existing bookmarks." Both halves were wrong and were
dropped. The correct instruction (dashboard URL changed at 3.x — update bookmarks, nav is
Develop & train → Feature Store) now stands in DO THIS Step 4.
-->
