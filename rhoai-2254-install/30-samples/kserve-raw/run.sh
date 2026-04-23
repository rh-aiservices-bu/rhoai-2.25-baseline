#!/usr/bin/env bash
# RawDeployment KServe sample — CPU-only vLLM with OCI modelcar storage.
# Mirrors the real-world pattern found on long-lived RHOAI 2.25.4 clusters:
# custom per-namespace ServingRuntime + RawDeployment ISVC using oci:// storage.
# Migration §2.8 does NOT convert RawDeployment ISVCs (it creates them from Serverless/ModelMesh)
# but rhai-cli scans them as part of its impacted-workloads count.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd inferenceservices.serving.kserve.io 600
wait_for_crd servingruntimes.serving.kserve.io 600
apply_manifest "${SCRIPT_DIR}/isvc.yaml"
log "kserve-raw: RawDeployment ISVC + custom vLLM-CPU ServingRuntime applied"
