#!/usr/bin/env bash
# §2.8.7.1 Serverless InferenceServices — the rhai-cli migration tool will flag these
# as needing conversion to RawDeployment.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd inferenceservices.serving.kserve.io 600
apply_manifest "${SCRIPT_DIR}/isvc.yaml"
log "kserve-serverless: InferenceServices applied (Serverless mode)"
