#!/usr/bin/env bash
# §2.8.10 LLMInferenceService — pre-migration state has no authentication and no RHCL.
# The LLMInferenceService CRD ships with KServe; this sample exists so migration
# §2.8.10.3 / §2.8.10.4 have something to annotate and secure.
#
# CPU variant using tinyllama (see llm-isvc.yaml caveat): no GPU required, schedules
# on any worker. Pod Ready-ness is not guaranteed — LLM-d is architected for GPU —
# but the CR exists for migration detection either way.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

if ! oc get crd llminferenceservices.serving.kserve.io >/dev/null 2>&1; then
  warn "LLMInferenceService CRD not present in this RHOAI 2.25.4 install — skipping sample"
  warn "  (distributed inference is a Technology Preview; only some 2.25.4 channels ship the CRD)"
  exit 0
fi
apply_manifest "${SCRIPT_DIR}/llm-isvc.yaml"
log "llm-isvc: LLMInferenceService applied (unauthenticated, pre-RHCL)"
