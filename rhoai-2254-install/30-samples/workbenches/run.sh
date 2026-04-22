#!/usr/bin/env bash
# §2.6 Workbenches — deploy Notebook CRs with older (2025.1) Jupyter/code-server/RStudio images.
# Migration §2.6 requires upgrading these to 2025.2 (or "latest" for RStudio) before upgrade.
# All notebooks are created in the Stopped state (kubeflow-resource-stopped: "true") per §2.6.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd notebooks.kubeflow.org 300
apply_manifest "${SCRIPT_DIR}/notebooks.yaml"
log "workbenches: deployed (Stopped state — start from the dashboard if you want them running)"
