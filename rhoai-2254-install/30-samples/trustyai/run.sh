#!/usr/bin/env bash
# §2.5 TrustyAI — deploys a PVC-backed and a DATABASE-backed TrustyAIService, plus a
# GuardrailsOrchestrator with otelExporter config. Covers backup paths §2.5.2-§2.5.4.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd trustyaiservices.trustyai.opendatahub.io 600
apply_manifest "${SCRIPT_DIR}/trustyai-pvc.yaml"
apply_manifest "${SCRIPT_DIR}/trustyai-db.yaml"

if oc get crd guardrailsorchestrators.trustyai.opendatahub.io >/dev/null 2>&1; then
  apply_manifest "${SCRIPT_DIR}/guardrails.yaml"
else
  warn "GuardrailsOrchestrator CRD not present — skipping guardrails sample"
fi

log "trustyai: applied (PVC + DATABASE variants, Guardrails if available)"
