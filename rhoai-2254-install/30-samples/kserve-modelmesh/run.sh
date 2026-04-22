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
log "kserve-modelmesh: ServingRuntime + InferenceService applied (ModelMesh mode)"
log "  note: model storage references aws-connection-my-storage — create a matching data connection"
log "  in the dashboard if you want the ISVC to reach Ready; not required for migration to detect it"
