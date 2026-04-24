#!/usr/bin/env bash
# Installs operator prerequisites for RHOAI 2.25.4.
#
# The three "2.x-era" operators (SM v2, Serverless, standalone Authorino) are gated
# by env vars so install-from-assessment.sh can reproduce a partially-prepped cluster
# that has already removed them. Default stays on (full pre-migration state).
#
#   INSTALL_SERVICE_MESH_V2=1|0         (default 1) — SM v2 + Kiali operator
#   INSTALL_SERVERLESS=1|0              (default 1) — OpenShift Serverless operator
#   INSTALL_AUTHORINO_STANDALONE=1|0    (default 1) — standalone Authorino operator
#
# cert-manager is intentionally NOT installed — migration §2.1 installs it.
# Red Hat Connectivity Link is intentionally NOT installed — migration §2.8.10.1 installs it.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${INSTALL_SERVICE_MESH_V2:=1}"
: "${INSTALL_SERVERLESS:=1}"
: "${INSTALL_AUTHORINO_STANDALONE:=1}"

apply_manifest "${SCRIPT_DIR}/namespaces.yaml"

if [[ "$INSTALL_SERVICE_MESH_V2" == "1" ]]; then
  apply_manifest "${SCRIPT_DIR}/servicemesh-v2.yaml"
  wait_for_csv_succeeded openshift-operators servicemeshoperator 900
  wait_for_csv_succeeded openshift-operators kiali-operator 600
else
  log "INSTALL_SERVICE_MESH_V2=0 — skipping Service Mesh v2 + Kiali"
fi

if [[ "$INSTALL_SERVERLESS" == "1" ]]; then
  apply_manifest "${SCRIPT_DIR}/serverless.yaml"
  wait_for_csv_succeeded openshift-serverless serverless-operator 900
else
  log "INSTALL_SERVERLESS=0 — skipping OpenShift Serverless"
fi

if [[ "$INSTALL_AUTHORINO_STANDALONE" == "1" ]]; then
  apply_manifest "${SCRIPT_DIR}/authorino.yaml"
  wait_for_csv_succeeded openshift-operators authorino-operator 600
else
  log "INSTALL_AUTHORINO_STANDALONE=0 — skipping standalone Authorino"
fi

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
