#!/usr/bin/env bash
# §2.9 Kubeflow Training Operator — PyTorchJob running on the KFTO v1 API (deprecated in 3.x).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd pytorchjobs.kubeflow.org 600
apply_manifest "${SCRIPT_DIR}/pytorchjob.yaml"
log "kfto: PyTorchJob applied"
