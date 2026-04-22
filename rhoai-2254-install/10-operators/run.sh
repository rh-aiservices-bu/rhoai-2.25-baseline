#!/usr/bin/env bash
# Installs operator prerequisites for RHOAI 2.25.4 in the pre-migration stack:
#   - Service Mesh 2 (+ Jaeger, Kiali)        -- replaced by Service Mesh 3 in 3.x
#   - OpenShift Serverless                    -- removed in 3.x (no Serverless KServe mode)
#   - Standalone Authorino Operator           -- replaced by Red Hat Connectivity Link in 3.x
#   - RHOAI operator, channel stable-2.25, pinned to CSV 2.25.4 (Manual approval)
#
# cert-manager is intentionally NOT installed — migration §2.1 installs it.
# Red Hat Connectivity Link is intentionally NOT installed — migration §2.8.10.1 installs it.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

apply_manifest "${SCRIPT_DIR}/namespaces.yaml"

apply_manifest "${SCRIPT_DIR}/servicemesh-v2.yaml"
wait_for_csv_succeeded openshift-operators servicemeshoperator 900
wait_for_csv_succeeded openshift-operators kiali-operator 600

apply_manifest "${SCRIPT_DIR}/serverless.yaml"
wait_for_csv_succeeded openshift-serverless serverless-operator 900

apply_manifest "${SCRIPT_DIR}/authorino.yaml"
wait_for_csv_succeeded openshift-operators authorino-operator 600

apply_manifest "${SCRIPT_DIR}/rhoai-operator.yaml"
# Subscription uses installPlanApproval=Manual with startingCSV=rhods-operator.2.25.4.
# Approve the initial install plan so 2.25.4 actually installs; future upgrade plans
# will still require manual approval and will be ignored (keeping us pinned at 2.25.4).
approve_installplan redhat-ods-operator 600
wait_for_csv_succeeded redhat-ods-operator rhods-operator.2.25.4 1200

# Wait for the DSCI/DSC CRDs the operator installs before phase 20 tries to use them.
wait_for_crd dscinitializations.dscinitialization.opendatahub.io 300
wait_for_crd datascienceclusters.datasciencecluster.opendatahub.io 300

log "10-operators: done"
