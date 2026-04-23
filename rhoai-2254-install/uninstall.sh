#!/usr/bin/env bash
# Tear down everything install.sh created, in reverse order. Best-effort: continues on failure.
# Does NOT uninstall cluster-wide CRDs — rerun install.sh against a fresh cluster if you
# need a guaranteed-clean slate.

set -Euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

delete_ns() {
  local ns="$1"
  if oc get ns "$ns" >/dev/null 2>&1; then
    log "deleting namespace ${ns}"
    oc delete ns "$ns" --ignore-not-found --wait=false || true
  fi
}

delete_sub_and_csvs() {
  local ns="$1" sub="$2"
  if oc -n "$ns" get subscription "$sub" >/dev/null 2>&1; then
    local csv
    csv=$(oc -n "$ns" get subscription "$sub" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    oc -n "$ns" delete subscription "$sub" --ignore-not-found || true
    [[ -n "$csv" ]] && oc -n "$ns" delete csv "$csv" --ignore-not-found || true
  fi
}

main() {
  require_cmd oc
  require_oc_login

  log "=== sample namespaces ==="
  for ns in \
      ml-project-a ml-project-b ml-project-c ml-project-raw \
      llm-project-a \
      raytest \
      pytorch-training \
      test-trustyaiservice test-trustyaiservice-db \
      test-guardrails-builtin-upgrade \
      workbenches-regular workbenches-hwp \
      rhods-notebooks \
      project-alpha \
      ldap-user17-rag-225 \
      dspa-sample \
      ; do
    delete_ns "$ns"
  done

  log "=== BYON ImageStream ==="
  oc -n redhat-ods-applications delete imagestream custom-scipy-notebook --ignore-not-found || true

  log "=== DSC + DSCI ==="
  oc delete dsc default-dsc --ignore-not-found --wait=false || true
  oc delete dsci default-dsci --ignore-not-found --wait=false || true

  log "=== rhoai-model-registries ==="
  delete_ns rhoai-model-registries

  log "=== RHOAI operator ==="
  delete_sub_and_csvs redhat-ods-operator rhods-operator
  delete_ns redhat-ods-applications
  delete_ns redhat-ods-monitoring
  delete_ns redhat-ods-operator

  log "=== Authorino operator ==="
  delete_sub_and_csvs openshift-operators authorino-operator

  log "=== OpenShift Serverless ==="
  oc delete knativeserving knative-serving -n knative-serving --ignore-not-found --wait=false || true
  delete_ns knative-serving
  delete_sub_and_csvs openshift-serverless serverless-operator
  delete_ns openshift-serverless

  log "=== Service Mesh v2 ==="
  oc delete servicemeshcontrolplane data-science-smcp -n istio-system --ignore-not-found --wait=false || true
  delete_ns istio-system
  delete_sub_and_csvs openshift-operators servicemeshoperator
  delete_sub_and_csvs openshift-operators kiali-ossm

  log "=== NVIDIA GPU Operator ==="
  oc delete clusterpolicy gpu-cluster-policy --ignore-not-found --wait=false || true
  delete_sub_and_csvs nvidia-gpu-operator gpu-operator-certified
  delete_ns nvidia-gpu-operator

  log "=== NFD ==="
  oc delete nodefeaturediscovery nfd-instance -n openshift-nfd --ignore-not-found --wait=false || true
  delete_sub_and_csvs openshift-nfd nfd
  delete_ns openshift-nfd

  log "Uninstall requested. Some deletions run asynchronously; give the cluster a few minutes to finish."
}

main "$@"
