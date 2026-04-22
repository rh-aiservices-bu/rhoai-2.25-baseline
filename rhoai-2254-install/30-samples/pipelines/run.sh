#!/usr/bin/env bash
# §2.4 AI Pipelines — deploys a DataSciencePipelinesApplication with embedded MariaDB + MinIO.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd datasciencepipelinesapplications.datasciencepipelinesapplications.opendatahub.io 600
apply_manifest "${SCRIPT_DIR}/dspa.yaml"
log "pipelines: DSPA applied"
