#!/usr/bin/env bash
# Shared helpers for RHOAI 2.25.4 pre-migration install scripts.

set -Eeuo pipefail

: "${SCRIPT_DIR:?SCRIPT_DIR must be set by caller}"
: "${ROOT_DIR:=$(cd "$SCRIPT_DIR/.." && pwd)}"
export ROOT_DIR

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s]\033[0m WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
err()  { printf '\033[1;31m[%s]\033[0m ERR:  %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

require_oc_login() {
  oc whoami >/dev/null 2>&1 || die "not logged into an OpenShift cluster (run 'oc login')"
}

apply_manifest() {
  local path="$1"
  log "apply: $path"
  oc apply -f "$path"
}

apply_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  shopt -s nullglob
  local files=("$dir"/*.yaml)
  shopt -u nullglob
  if ((${#files[@]} == 0)); then
    return 0
  fi
  for f in "${files[@]}"; do
    apply_manifest "$f"
  done
}

wait_for_csv_succeeded() {
  local ns="$1" csv_prefix="$2" timeout="${3:-900}"
  log "waiting for CSV ${csv_prefix}* in ns/${ns} to reach Succeeded (timeout ${timeout}s)"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local csv phase
    csv=$(oc -n "$ns" get csv -o name 2>/dev/null | grep -E "clusterserviceversion.operators.coreos.com/${csv_prefix}" | head -n1 || true)
    if [[ -n "$csv" ]]; then
      phase=$(oc -n "$ns" get "$csv" -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [[ "$phase" == "Succeeded" ]]; then
        log "  ${csv} phase=Succeeded"
        return 0
      fi
      [[ -n "$phase" ]] && log "  ${csv} phase=${phase}"
    fi
    sleep 10
  done
  die "timeout waiting for CSV ${csv_prefix}* in ns/${ns}"
}

approve_installplan() {
  # Approves the first pending InstallPlan in the namespace — used for Manual subscriptions
  # where we want to pin the installed CSV.
  local ns="$1" timeout="${2:-300}"
  log "waiting for pending InstallPlan in ns/${ns} (timeout ${timeout}s)"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local ip
    ip=$(oc -n "$ns" get installplan -o json 2>/dev/null \
      | jq -r '.items[] | select(.spec.approved==false) | .metadata.name' \
      | head -n1 || true)
    if [[ -n "$ip" ]]; then
      log "  approving InstallPlan ${ip}"
      oc -n "$ns" patch installplan "$ip" --type=merge -p '{"spec":{"approved":true}}'
      return 0
    fi
    sleep 5
  done
  die "no pending InstallPlan appeared in ns/${ns}"
}

wait_for_crd() {
  local crd="$1" timeout="${2:-300}"
  log "waiting for CRD ${crd} (timeout ${timeout}s)"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    if oc get crd "$crd" >/dev/null 2>&1; then
      log "  CRD ${crd} present"
      return 0
    fi
    sleep 5
  done
  die "timeout waiting for CRD ${crd}"
}

wait_for_dsc_ready() {
  local name="${1:-default-dsc}" timeout="${2:-1800}"
  log "waiting for DataScienceCluster/${name} phase=Ready (timeout ${timeout}s)"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local phase
    phase=$(oc get dsc "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Ready" ]]; then
      log "  DSC/${name} is Ready"
      return 0
    fi
    [[ -n "$phase" ]] && log "  DSC/${name} phase=${phase}"
    sleep 15
  done
  die "timeout waiting for DSC/${name}"
}

wait_for_dsci_ready() {
  local name="${1:-default-dsci}" timeout="${2:-900}"
  log "waiting for DSCInitialization/${name} phase=Ready (timeout ${timeout}s)"
  local deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    local phase
    phase=$(oc get dsci "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [[ "$phase" == "Ready" ]]; then
      log "  DSCI/${name} is Ready"
      return 0
    fi
    [[ -n "$phase" ]] && log "  DSCI/${name} phase=${phase}"
    sleep 10
  done
  die "timeout waiting for DSCI/${name}"
}

wait_for_rollout() {
  local kind="$1" name="$2" ns="$3" timeout="${4:-600}"
  log "waiting for ${kind}/${name} -n ${ns} rollout (timeout ${timeout}s)"
  oc -n "$ns" rollout status "${kind}/${name}" --timeout="${timeout}s"
}

render_and_apply() {
  # Renders envsubst on a file, then applies. Caller is responsible for exporting vars.
  local path="$1"
  log "apply (envsubst): $path"
  envsubst < "$path" | oc apply -f -
}

preflight_cluster() {
  require_cmd oc jq envsubst
  require_oc_login
  local ocp
  ocp=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
  log "OCP version: ${ocp}"
  local def_sc
  def_sc=$(oc get sc -o json | jq -r '.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true") | .metadata.name' | head -n1)
  [[ -n "$def_sc" ]] || die "no default StorageClass found"
  log "default StorageClass: ${def_sc}"
}
