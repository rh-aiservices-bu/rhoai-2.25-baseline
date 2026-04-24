#!/usr/bin/env bash
# §2.8.7.1 Serverless InferenceServices — the rhai-cli migration tool will flag these
# as needing conversion to RawDeployment.
#
# Two ISVCs in ml-project-a and ml-project-b, each with a per-namespace CPU-only
# vLLM ServingRuntime serving tinyllama via an OCI modelcar. No GPU required —
# schedules on the regular worker nodes. Gives the migration a real working
# Serverless workload to convert (the doc's classic sklearn example needs GCS egress).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd inferenceservices.serving.kserve.io 600
apply_manifest "${SCRIPT_DIR}/isvc.yaml"
log "kserve-serverless: InferenceServices applied (Serverless mode)"
