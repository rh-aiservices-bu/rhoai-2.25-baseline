#!/usr/bin/env bash
# Creates the DSCInitialization + DataScienceCluster for the 2.25.4 pre-migration stack.
# The RHOAI operator will:
#   - create the Service Mesh control plane (SMCP) in istio-system
#   - install KNative Serving in knative-serving (Serverless KServe)
#   - deploy ModelMesh controllers in redhat-ods-applications
#   - deploy Kueue (embedded), dashboard, pipelines, workbenches, ray, KFTO, TrustyAI,
#     Feast, Llama Stack, ModelRegistry controllers

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

apply_manifest "${SCRIPT_DIR}/dsci.yaml"
wait_for_dsci_ready default-dsci 900

apply_manifest "${SCRIPT_DIR}/dsc.yaml"
wait_for_dsc_ready default-dsc 1800

# Sanity-check the pre-migration component states.
log "verifying pre-migration component states..."
oc get dsc default-dsc -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}'; echo
oc get dsc default-dsc -o jsonpath='{.spec.components.kserve.defaultDeploymentMode}' \
  | grep -qx Serverless || die "kserve.defaultDeploymentMode must be Serverless"
oc get dsc default-dsc -o jsonpath='{.spec.components.kueue.managementState}' \
  | grep -qx Managed || die "kueue.managementState must be Managed (pre-migration)"
oc get dsc default-dsc -o jsonpath='{.spec.components.modelmeshserving.managementState}' \
  | grep -qx Managed || die "modelmeshserving.managementState must be Managed (pre-migration)"
oc get dsci default-dsci -o jsonpath='{.spec.serviceMesh.managementState}' \
  | grep -qx Managed || die "serviceMesh.managementState must be Managed (pre-migration)"

log "20-dsc: done"
