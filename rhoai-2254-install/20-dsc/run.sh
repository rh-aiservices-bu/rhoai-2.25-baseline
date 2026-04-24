#!/usr/bin/env bash
# Creates the DSCInitialization + DataScienceCluster for the 2.25.4 pre-migration stack.
# The RHOAI operator will:
#   - create the Service Mesh control plane (SMCP) in istio-system (if serviceMesh=Managed)
#   - install KNative Serving in knative-serving (if kserve.serving=Managed)
#   - deploy ModelMesh controllers in redhat-ods-applications (if modelmeshserving=Managed)
#   - deploy Kueue (embedded), dashboard, pipelines, workbenches, ray, KFTO, TrustyAI,
#     Feast, Llama Stack, ModelRegistry controllers
#
# Every parameterizable component state has an env-var override. Defaults reproduce
# the full pre-migration state.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

# Defaults — full pre-migration state
export DSCI_SERVICEMESH_STATE="${DSCI_SERVICEMESH_STATE:-Managed}"
export DSC_KSERVE_MANAGEMENT_STATE="${DSC_KSERVE_MANAGEMENT_STATE:-Managed}"
export DSC_KSERVE_DEFAULT_MODE="${DSC_KSERVE_DEFAULT_MODE:-Serverless}"
export DSC_KSERVE_SERVING_STATE="${DSC_KSERVE_SERVING_STATE:-Managed}"
export DSC_MODELMESH_STATE="${DSC_MODELMESH_STATE:-Managed}"
export DSC_KUEUE_STATE="${DSC_KUEUE_STATE:-Managed}"
export DSC_WORKBENCHES_STATE="${DSC_WORKBENCHES_STATE:-Managed}"
export DSC_RAY_STATE="${DSC_RAY_STATE:-Managed}"
export DSC_CODEFLARE_STATE="${DSC_CODEFLARE_STATE:-Managed}"
export DSC_TRAININGOPERATOR_STATE="${DSC_TRAININGOPERATOR_STATE:-Managed}"
export DSC_TRUSTYAI_STATE="${DSC_TRUSTYAI_STATE:-Managed}"
export DSC_DATASCIENCEPIPELINES_STATE="${DSC_DATASCIENCEPIPELINES_STATE:-Managed}"
export DSC_MODELREGISTRY_STATE="${DSC_MODELREGISTRY_STATE:-Managed}"
export DSC_FEASTOPERATOR_STATE="${DSC_FEASTOPERATOR_STATE:-Managed}"
export DSC_LLAMASTACK_STATE="${DSC_LLAMASTACK_STATE:-Managed}"

log "DSCI.serviceMesh=${DSCI_SERVICEMESH_STATE}"
log "DSC.kserve=${DSC_KSERVE_MANAGEMENT_STATE} (default_mode=${DSC_KSERVE_DEFAULT_MODE}, serving=${DSC_KSERVE_SERVING_STATE})"
log "DSC.modelmeshserving=${DSC_MODELMESH_STATE}, kueue=${DSC_KUEUE_STATE}"

render_and_apply "${SCRIPT_DIR}/dsci.yaml"
wait_for_dsci_ready default-dsci 900

render_and_apply "${SCRIPT_DIR}/dsc.yaml"
wait_for_dsc_ready default-dsc 1800

# Sanity-check component states match what we asked for.
log "verifying applied component states..."
actual_kserve=$(oc get dsc default-dsc -o jsonpath='{.spec.components.kserve.managementState}')
actual_kserve_serving=$(oc get dsc default-dsc -o jsonpath='{.spec.components.kserve.serving.managementState}')
actual_sm=$(oc get dsci default-dsci -o jsonpath='{.spec.serviceMesh.managementState}')
[[ "$actual_kserve" == "$DSC_KSERVE_MANAGEMENT_STATE" ]] \
  || die "DSC kserve.managementState=$actual_kserve, expected $DSC_KSERVE_MANAGEMENT_STATE"
[[ "$actual_kserve_serving" == "$DSC_KSERVE_SERVING_STATE" ]] \
  || die "DSC kserve.serving.managementState=$actual_kserve_serving, expected $DSC_KSERVE_SERVING_STATE"
[[ "$actual_sm" == "$DSCI_SERVICEMESH_STATE" ]] \
  || die "DSCI serviceMesh.managementState=$actual_sm, expected $DSCI_SERVICEMESH_STATE"

log "20-dsc: done"
