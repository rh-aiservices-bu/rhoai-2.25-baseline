#!/usr/bin/env bash
# Deploys flag-gated sample workloads so each §2.x "Before upgrade" step has a resource
# to operate on. Everything is on by default; set INSTALL_<component>=0 to skip.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

: "${INSTALL_WORKBENCHES:=1}"       # §2.6
: "${INSTALL_KSERVE_SERVERLESS:=1}" # §2.8.7.1
: "${INSTALL_KSERVE_MODELMESH:=1}"  # §2.8.7.2
: "${INSTALL_LLM_ISVC:=1}"          # §2.8.10
: "${INSTALL_RAY:=1}"               # §2.7
: "${INSTALL_KFTO:=1}"              # §2.9
: "${INSTALL_TRUSTYAI:=1}"          # §2.5
: "${INSTALL_PIPELINES:=1}"         # §2.4 (AI Pipelines)
: "${INSTALL_FEAST:=1}"             # §2.4 (Feature Store)
: "${INSTALL_LLAMA_STACK:=1}"       # §2.5 (Llama Stack)
: "${INSTALL_MODEL_REGISTRY:=1}"    # §2.3

run_sub() {
  local flag="$1" name="$2"
  if [[ "$flag" != "1" ]]; then
    log "skip ${name} (flag=${flag})"
    return
  fi
  local dir="${SCRIPT_DIR}/${name}"
  [[ -x "${dir}/run.sh" ]] || die "missing ${dir}/run.sh"
  log "--- ${name} ---"
  "${dir}/run.sh"
}

run_sub "$INSTALL_MODEL_REGISTRY"    model-registry
run_sub "$INSTALL_FEAST"             feast
run_sub "$INSTALL_LLAMA_STACK"       llama-stack
run_sub "$INSTALL_PIPELINES"         pipelines
run_sub "$INSTALL_TRUSTYAI"          trustyai
run_sub "$INSTALL_WORKBENCHES"       workbenches
run_sub "$INSTALL_RAY"               ray
run_sub "$INSTALL_KFTO"              kfto
run_sub "$INSTALL_KSERVE_MODELMESH"  kserve-modelmesh
run_sub "$INSTALL_KSERVE_SERVERLESS" kserve-serverless
run_sub "$INSTALL_LLM_ISVC"          llm-isvc

log "30-samples: done"
