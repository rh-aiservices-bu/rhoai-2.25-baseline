#!/usr/bin/env bash
# §2.5 Llama Stack — deploys a LlamaStackDistribution so the migration's pre-upgrade
# data-export step has something to enumerate.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

if ! oc get crd llamastackdistributions.llamastack.io >/dev/null 2>&1; then
  warn "LlamaStackDistribution CRD not present — llamastackoperator may still be reconciling"
  wait_for_crd llamastackdistributions.llamastack.io 300 || {
    warn "giving up on llamastack CRD; skipping sample"
    exit 0
  }
fi
apply_manifest "${SCRIPT_DIR}/lsd.yaml"
log "llama-stack: LlamaStackDistribution applied"
