#!/usr/bin/env bash
# Installs NFD + NVIDIA GPU Operator + CRs so nvidia.com/gpu resources become schedulable.
# All samples in this repo are CPU-only by default (tinyllama OCI modelcar) so this
# phase is opt-in.
#
# INSTALL_GPU modes:
#   0 (default)    — skip. Samples run CPU-only.
#   auto           — install only if the cluster has GPU capacity but no driver yet
#                    (no node has nvidia.com/gpu allocatable)
#   1              — force install

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${INSTALL_GPU:=0}"

case "$INSTALL_GPU" in
  0)
    log "INSTALL_GPU=0 — skipping"
    exit 0
    ;;
  auto)
    allocatable=$(oc get nodes -o json 2>/dev/null \
      | jq '[.items[] | (.status.allocatable["nvidia.com/gpu"] // "0" | tonumber)] | add // 0')
    if [[ "${allocatable:-0}" -gt 0 ]]; then
      log "INSTALL_GPU=auto — cluster already has ${allocatable} nvidia.com/gpu allocatable; skipping"
      exit 0
    fi
    log "INSTALL_GPU=auto — no GPU allocatable, proceeding with install"
    ;;
  1)
    log "INSTALL_GPU=1 — forcing install"
    ;;
  *)
    die "INSTALL_GPU must be 0, 1, or auto (got '$INSTALL_GPU')"
    ;;
esac

apply_manifest "${SCRIPT_DIR}/namespaces.yaml"

apply_manifest "${SCRIPT_DIR}/nfd-operator.yaml"
wait_for_csv_succeeded openshift-nfd nfd 900
wait_for_crd nodefeaturediscoveries.nfd.openshift.io 300
apply_manifest "${SCRIPT_DIR}/nodefeaturediscovery.yaml"

apply_manifest "${SCRIPT_DIR}/gpu-operator.yaml"
wait_for_csv_succeeded nvidia-gpu-operator gpu-operator-certified 900
wait_for_crd clusterpolicies.nvidia.com 300
apply_manifest "${SCRIPT_DIR}/clusterpolicy.yaml"

log "waiting up to 20 min for driver rollout — nvidia.com/gpu to become allocatable"
deadline=$(( $(date +%s) + 1200 ))
while (( $(date +%s) < deadline )); do
  total=$(oc get nodes -o json 2>/dev/null \
    | jq '[.items[] | (.status.allocatable["nvidia.com/gpu"] // "0" | tonumber)] | add // 0')
  if [[ "${total:-0}" -gt 0 ]]; then
    log "nvidia.com/gpu=${total} allocatable cluster-wide"
    break
  fi
  sleep 30
done
if [[ "${total:-0}" -eq 0 ]]; then
  warn "no GPU allocatable after 20 min — check pods in nvidia-gpu-operator namespace"
  warn "  oc get pods -n nvidia-gpu-operator"
fi

log "05-gpu: done"
