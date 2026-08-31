#!/usr/bin/env bash
# §2.8.7.2 ModelMesh InferenceService + multi-model ServingRuntime.
# Migration will convert this to RawDeployment with an equivalent single-model runtime.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd servingruntimes.serving.kserve.io 600
wait_for_crd inferenceservices.serving.kserve.io 600
apply_manifest "${SCRIPT_DIR}/isvc.yaml"

# The manifest's model-serving-config ConfigMap sets:
#   allowAnyPVC: true     — required to mount the model PVC at all
#   podsPerRuntime: 1     — required on a RWO storage class (gp3-csi, etc.) to avoid
#                           a Multi-Attach race when the controller surges a 2nd pod
# The modelmesh-controller reads this config at startup, so restart it to pick it up
# (the controller is already running from the DSC reconcile in phase 20).
log "kserve-modelmesh: restarting modelmesh-controller to apply allowAnyPVC + podsPerRuntime..."
oc -n redhat-ods-applications rollout restart deploy/modelmesh-controller >/dev/null 2>&1 || true
oc -n redhat-ods-applications rollout status deploy/modelmesh-controller --timeout=180s >/dev/null 2>&1 || true

log "kserve-modelmesh: PVC + ONNX seed job + OVMS multi-model ServingRuntime + ISVC applied (ModelMesh mode)"
log "  the seed job downloads MobileNetV2 (~14 MB ONNX) into the PVC at mobilenet/1/"
log "  the ISVC loads via ModelMesh from the PVC; it may take 1-2 min to reach Ready"
log "  the migration (workshop Module 2) re-hosts this model as a single-model KServe RawDeployment OVMS ISVC"
log "  VALIDATED on RHOAI 2.25.4 (install bumped to 2.25.10 — re-validate if you change the runtime spec)"
log "  Runtime spec is from the OOTB 'ovms' template (grpc endpoints required,"
log "  or the modelmesh-controller panics); model serves from PVC with allowAnyPVC=true + podsPerRuntime=1"
