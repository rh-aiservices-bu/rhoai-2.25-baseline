#!/usr/bin/env bash
# Driver: installs RHOAI 2.25.4 in its pre-migration ("before") state so the
# 2.25.4 -> 3.3.2 migration procedure has something to operate on.
#
# Phases:
#   05-gpu         - installs NFD + NVIDIA GPU Operator (auto-skips if GPU already allocatable)
#   10-operators   - installs Service Mesh v2, Serverless, Authorino, RHOAI 2.25.4 operator (pinned)
#   20-dsc         - creates DSCInitialization + DataScienceCluster with all components Managed,
#                    KServe in Serverless mode, ModelMesh Managed
#   30-samples     - deploys flag-gated sample workloads that exercise every §2.x "before" step
#
# Toggle individual sample workloads with INSTALL_* env vars (all default to 1).
# See 30-samples/run.sh for the full list. Set INSTALL_GPU=0 to skip 05-gpu.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

run_phase() {
  local phase="$1"
  local dir="${SCRIPT_DIR}/${phase}"
  [[ -x "${dir}/run.sh" ]] || die "missing or non-executable ${dir}/run.sh"
  log "=== phase ${phase} ==="
  "${dir}/run.sh"
}

main() {
  preflight_cluster

  run_phase 05-gpu
  run_phase 10-operators
  run_phase 20-dsc
  run_phase 30-samples

  log "==="
  log "RHOAI 2.25.4 pre-migration install complete."
  log "Next: run the migration assessment from chapter 1, then follow chapter 2 to upgrade to 3.3.2."
}

main "$@"
