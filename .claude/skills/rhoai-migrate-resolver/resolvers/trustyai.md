# Resolver — TrustyAI + Guardrails

**rhai-cli signal:** `component / trustyai / *`, `workload / guardrails / *`.

## Why

TrustyAI's storage schema changed between 2.x and 3.x. Without a pre-upgrade backup, historical bias-detection metrics and training data can become unreadable after the migration. GuardrailsOrchestrator's `otelExporter` config survives, but must be captured before the schema migration in case you need to restore manually.

No architectural change driver for TrustyAI itself — this is a data-safety step from migration guide §2.5.

## Is TrustyAI even managed?

Skip this section if TrustyAI was never enabled:

```
oc get dsc -o jsonpath='{.items[0].spec.components.trustyai.managementState}'; echo
# Managed → continue. Removed or empty → skip; no data to back up.
```

## § Prepare for backup

Create the backup dir inside the rhai-cli pod's PVC:

```
oc exec -n rhai-migration rhai-cli-0 -- mkdir -p /tmp/rhoai-upgrade-backup/trustyai
```

List the TrustyAIServices so you know what to back up:

```
oc get trustyaiservice -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STORAGE:.spec.storage.format'
```

## § Back up metrics

For each TrustyAIService, fetch the `/metrics/all/requests` JSON and save it. The rhai-cli container includes a helper:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  bash /opt/rhai-upgrade-helpers/trustyai/backup_metrics.sh
```

Output goes to `/tmp/rhoai-upgrade-backup/trustyai/trustyai-metrics-<NS>-<timestamp>.json`.

## § Back up data storage

Two paths depending on `spec.storage.format`:

### PVC-backed (format: PVC)

The helper copies everything from the TrustyAIService pod's `/inputs` directory into the backup PVC:

```
oc exec -n rhai-migration rhai-cli-0 -- \
  bash /opt/rhai-upgrade-helpers/trustyai/backup_storage.sh
```

Result: `/tmp/rhoai-upgrade-backup/trustyai/trustyai-data-<namespace>-<timestamp>/data/*.csv`.

### DATABASE-backed (format: DATABASE)

The helper invokes `mysqldump` against the MariaDB referenced by the `databaseConfigurations` Secret:

```
# Same helper — auto-detects format per TrustyAIService
oc exec -n rhai-migration rhai-cli-0 -- \
  bash /opt/rhai-upgrade-helpers/trustyai/backup_storage.sh
```

Result: `/tmp/rhoai-upgrade-backup/trustyai/trustyai-db-<namespace>-<timestamp>/dump.sql`.

## § Guardrails — back up OpenTelemetry exporter config

If you have `GuardrailsOrchestrator` CRs with `spec.otelExporter` set (traces/metrics going to an external OTLP endpoint), capture the block so you can restore it post-upgrade:

```
oc get guardrailsorchestrator -A -o json \
  | jq -r '.items[] | select(.spec.otelExporter != null) | {ns: .metadata.namespace, name: .metadata.name, otelExporter: .spec.otelExporter}' \
  > trustyai-guardrails-otel-backup-$(date +%Y%m%d%H%M).json
```

## Copy backups to your workstation

```
oc cp rhai-migration/rhai-cli-0:/tmp/rhoai-upgrade-backup/trustyai ./trustyai-backup
```

## Verify

```
# Inside the pod, list what was backed up
oc exec -n rhai-migration rhai-cli-0 -- ls -la /tmp/rhoai-upgrade-backup/trustyai
```

## Callouts

- TrustyAI backups go on **your** timeline — do them a few days before the upgrade, then repeat just before if data is still accumulating.
- GPU-deployed guardrails have a known deadlock issue in 3.x (migration guide §4.6.4) — if you use GPU guardrails, open a support case before the migration so Red Hat can advise on sequencing.
