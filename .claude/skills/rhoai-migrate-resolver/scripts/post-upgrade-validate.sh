#!/usr/bin/env bash
# Read-only post-upgrade check for an RHOAI 2.25.4 → 3.3.2 migration.
# Covers the post-upgrade verification tasks from the migration guide.
#
# This script does not modify the cluster. Run as cluster-admin.
# Exit code: 0 if all checks PASS, 1 if any critical FAIL.

# pipefail omitted: many checks pipe `oc ... | grep -q ...`, and grep exiting early
# on match surfaces as SIGPIPE (exit 141) and inverts the boolean.
set -u

PASS=0
FAIL=0
WARN=0
c_pass=$'\033[1;32m'
c_fail=$'\033[1;31m'
c_warn=$'\033[1;33m'
c_dim=$'\033[2m'
c_off=$'\033[0m'

check() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    PASS) printf '%b[PASS]%b %s%s%b\n' "$c_pass" "$c_off" "$name" "${detail:+  $c_dim$detail$c_off}" "" ; PASS=$((PASS+1)) ;;
    FAIL) printf '%b[FAIL]%b %s%s%b\n' "$c_fail" "$c_off" "$name" "${detail:+  $detail}" "" ; FAIL=$((FAIL+1)) ;;
    WARN) printf '%b[WARN]%b %s%s%b\n' "$c_warn" "$c_off" "$name" "${detail:+  $detail}" "" ; WARN=$((WARN+1)) ;;
  esac
}

oc whoami >/dev/null 2>&1 || { echo "not logged in — run 'oc login'"; exit 1; }

echo "RHOAI 2.25.4 → 3.3.2 migration — post-upgrade validation"
echo "========================================================="

# [operator] RHOAI operator version is 3.3.2 (and 2.25.4 is gone)
csv_new=$(oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].metadata.name}' 2>/dev/null || echo "")
case "$csv_new" in
  rhods-operator.3.3.2) check PASS "[operator] RHOAI operator CSV" "$csv_new" ;;
  rhods-operator.3.*)   check WARN "[operator] RHOAI operator CSV" "$csv_new — this script targets 3.3.2 but newer 3.x may still work" ;;
  rhods-operator.2.*)   check FAIL "[operator] RHOAI operator CSV" "$csv_new — upgrade has not completed; this is the pre-upgrade validator's job" ;;
  "")                   check FAIL "[operator] RHOAI operator CSV" "no CSV found in redhat-ods-operator" ;;
  *)                    check WARN "[operator] RHOAI operator CSV" "$csv_new — unexpected" ;;
esac

if oc get csv -n redhat-ods-operator 2>/dev/null | grep -q 'rhods-operator\.2\.'; then
  check FAIL "[operator] old 2.x operator gone" "a 2.x rhods-operator CSV is still present"
else
  check PASS "[operator] old 2.x operator gone"
fi

# [operator] DSC + DSCI Ready
dsc_phase=$(oc get dsc -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
dsci_phase=$(oc get dsci -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
[[ "$dsc_phase" == "Ready" ]]  && check PASS "[operator] DSC phase=Ready"  || check FAIL "[operator] DSC phase"  "$dsc_phase (expected Ready)"
[[ "$dsci_phase" == "Ready" ]] && check PASS "[operator] DSCI phase=Ready" || check FAIL "[operator] DSCI phase" "$dsci_phase (expected Ready)"

# [operator] All operator-namespace pods Running + Ready
not_ready_op=$(oc get pods -n redhat-ods-operator --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}')
if [[ -z "$not_ready_op" ]]; then
  check PASS "[operator] redhat-ods-operator pods" "all Running"
else
  check FAIL "[operator] redhat-ods-operator pods" "not Running: $(echo $not_ready_op | tr '\n' ' ')"
fi

not_ready_app=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}')
if [[ -z "$not_ready_app" ]]; then
  check PASS "[operator] redhat-ods-applications pods" "all Running"
else
  check FAIL "[operator] redhat-ods-applications pods" "not Running: $(echo $not_ready_app | tr '\n' ' ')"
fi

# [operator] Gateway ready (3.x uses Gateway API)
if oc get gatewayconfigs --all-namespaces >/dev/null 2>&1; then
  gw_ready=$(oc get gatewayconfigs -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name=="default-gateway") | .status.conditions[]? | select(.type=="Ready") | .status' | head -n1)
  if [[ "$gw_ready" == "True" ]]; then
    check PASS "[operator] default-gateway Ready"
  else
    check FAIL "[operator] default-gateway Ready" "status=$gw_ready — check gatewayconfigs -A -o wide"
  fi
else
  check WARN "[operator] Gateway API" "gatewayconfigs CRD not found — dashboard/Gateway check skipped"
fi

# [operator] Kueue component — status should be Ready or Removed
kueue_st=$(oc get dsc -o jsonpath='{.items[0].status.conditions[?(@.type=="KueueReady")].status}' 2>/dev/null || echo "")
kueue_rs=$(oc get dsc -o jsonpath='{.items[0].status.conditions[?(@.type=="KueueReady")].reason}' 2>/dev/null || echo "")
if [[ "$kueue_st" == "True" ]] || ([[ "$kueue_st" == "False" ]] && [[ "$kueue_rs" == "Removed" ]]); then
  check PASS "[operator] Kueue recovery" "status=$kueue_st reason=$kueue_rs"
else
  check FAIL "[operator] Kueue recovery" "status=$kueue_st reason=$kueue_rs — migrate to Red Hat Build of Kueue or set Removed"
fi

# [registry] Model registry + catalog pods
if oc get ns rhoai-model-registries >/dev/null 2>&1; then
  not_mr=$(oc get pods -n rhoai-model-registries --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}')
  if [[ -z "$not_mr" ]]; then
    check PASS "[registry] rhoai-model-registries pods" "all Running"
  else
    check FAIL "[registry] rhoai-model-registries pods" "not Running: $(echo $not_mr | tr '\n' ' ')"
  fi
else
  check WARN "[registry] rhoai-model-registries ns" "not present — skip if you don't use Model Registry"
fi

# [feast] Feature Store operator (only if FeatureStore CRs exist)
if oc get featurestore -A --no-headers 2>/dev/null | grep -q .; then
  if oc get pods -n redhat-ods-applications -l control-plane=controller-manager -o name 2>/dev/null | grep -q feast-operator; then
    check PASS "[feast] feast-operator controller" "Running"
  else
    feast_ns_pod=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | awk '/feast-operator/ {print $1":"$3}')
    if [[ -n "$feast_ns_pod" ]]; then
      check PASS "[feast] feast-operator pod" "$feast_ns_pod"
    else
      check FAIL "[feast] feast-operator pod" "not found in redhat-ods-applications"
    fi
  fi
  not_fs=$(oc get featurestore -A -o json 2>/dev/null | jq -r '.items[] | select(.status.phase != "Ready") | "\(.metadata.namespace)/\(.metadata.name)=\(.status.phase)"')
  if [[ -z "$not_fs" ]]; then
    check PASS "[feast] FeatureStore CRs Ready"
  else
    check FAIL "[feast] FeatureStore CRs Ready" "$not_fs"
  fi
fi

# [pipelines] DSPA Ready (skip if no DSPA)
if oc get dspa -A --no-headers 2>/dev/null | grep -q .; then
  broken_dspa=$(oc get dspa -A -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status!="True")) | "\(.metadata.namespace)/\(.metadata.name)"')
  if [[ -z "$broken_dspa" ]]; then
    check PASS "[pipelines] DSPA Ready"
  else
    check FAIL "[pipelines] DSPA Ready" "$broken_dspa"
  fi
fi

# [trustyai] TrustyAI operator
if oc get trustyaiservice -A --no-headers 2>/dev/null | grep -q .; then
  if oc -n redhat-ods-applications get deployment trustyai-service-operator-controller-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx True; then
    check PASS "[trustyai] operator Available"
  else
    check FAIL "[trustyai] operator Available" "trustyai-service-operator-controller-manager not Available"
  fi
fi

# [workbenches] Workbench controllers
nb_ok=$(oc -n redhat-ods-applications get deployment odh-notebook-controller-manager notebook-controller-deployment -o json 2>/dev/null \
  | jq -r '.items[]? | "\(.metadata.name)=\(.status.readyReplicas // 0)/\(.spec.replicas)"' 2>/dev/null)
if [[ -n "$nb_ok" ]]; then
  all_ready=1
  while read -r line; do
    [[ "${line##*=}" != "$(echo "${line##*=}" | awk -F/ '{print $2"/"$2}')" ]] && all_ready=0
  done <<< "$nb_ok"
  if (( all_ready == 1 )); then
    check PASS "[workbenches] controllers Ready" "$(echo $nb_ok | tr '\n' ' ')"
  else
    check FAIL "[workbenches] controllers Ready" "$(echo $nb_ok | tr '\n' ' ')"
  fi
else
  check WARN "[workbenches] controllers" "not found — skip if workbenches component is Removed"
fi

# [ray] KubeRay manages; CodeFlare must be gone
if oc get subscription -A 2>/dev/null | grep -q codeflare; then
  check FAIL "[ray] CodeFlare uninstalled" "codeflare subscription still present; the pre-upgrade helper should have removed it"
else
  check PASS "[ray] CodeFlare uninstalled"
fi

# [model-serving] KServe controller + ODH Model Controller
kserve_ready=$(oc get pods -n redhat-ods-applications -l control-plane=kserve-controller-manager -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
if [[ "${kserve_ready:-0}" -ge 1 ]]; then
  check PASS "[model-serving] KServe controller Ready"
else
  check FAIL "[model-serving] KServe controller Ready" "no Ready kserve-controller-manager pod"
fi

odh_ready=$(oc get pods -n redhat-ods-applications -l control-plane=odh-model-controller -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
if [[ "${odh_ready:-0}" -ge 1 ]]; then
  check PASS "[model-serving] ODH Model Controller Ready"
else
  check FAIL "[model-serving] ODH Model Controller Ready" "no Ready odh-model-controller pod"
fi

# [model-serving] All ISVCs RawDeployment + Ready
bad_isvc=$(oc get isvc -A -o json 2>/dev/null | jq -r '.items[] | select((.status.deploymentMode // "") != "RawDeployment" or ((.status.conditions[]? | select(.type=="Ready") | .status) // "False") != "True") | "\(.metadata.namespace)/\(.metadata.name)=mode:\(.status.deploymentMode // "unknown"),ready:\((.status.conditions[]? | select(.type=="Ready") | .status) // "unknown")"')
if [[ -z "$bad_isvc" ]]; then
  check PASS "[model-serving] InferenceServices RawDeployment + Ready"
else
  check FAIL "[model-serving] InferenceServices RawDeployment + Ready" "$(echo "$bad_isvc" | tr '\n' ';')"
fi

# [model-serving] LLMInferenceServices
if oc get llminferenceservice -A --no-headers 2>/dev/null | grep -q .; then
  bad_llm=$(oc get llminferenceservice -A -o json 2>/dev/null | jq -r '.items[] | select(((.status.conditions[]? | select(.type=="Ready") | .status) // "False") != "True") | "\(.metadata.namespace)/\(.metadata.name)"')
  if [[ -z "$bad_llm" ]]; then
    check PASS "[model-serving] LLMInferenceServices Ready"
  else
    check FAIL "[model-serving] LLMInferenceServices Ready" "$(echo "$bad_llm" | tr '\n' ' ')"
  fi
fi

# [model-serving] Leftover 2.x operators (FAIL if LLMISVC present, WARN otherwise)
has_llm=0
if oc get llminferenceservice -A --no-headers 2>/dev/null | grep -q .; then has_llm=1; fi

if oc get csv -A 2>/dev/null | grep -q 'serverless-operator\.'; then
  check WARN "[model-serving] OpenShift Serverless leftover" "still installed — no impact on ISVCs, wastes resources; uninstall if unused elsewhere"
else
  check PASS "[model-serving] OpenShift Serverless" "uninstalled"
fi

rhcl=0
if oc get csv -A 2>/dev/null | grep -q 'rhcl-operator\.'; then rhcl=1; fi
if oc get csv -n openshift-operators 2>/dev/null | grep -q 'authorino-operator\.' && (( rhcl == 0 )); then
  if (( has_llm == 1 )); then
    check FAIL "[model-serving] standalone Authorino" "LLMInferenceService present and RHCL is NOT installed — install RHCL and uninstall standalone Authorino"
  else
    check WARN "[model-serving] standalone Authorino leftover" "still installed, RHCL not present — OK if no LLMInferenceService, otherwise CRITICAL"
  fi
else
  check PASS "[model-serving] Authorino" "RHCL=$rhcl (or standalone uninstalled)"
fi

if oc get csv -A 2>/dev/null | grep -qE 'servicemeshoperator\.v2\.'; then
  check FAIL "[model-serving] Service Mesh v2 leftover" "SM v2 still present — blocks Gateway API on OSSM3; uninstall or migrate dependents to v3"
else
  check PASS "[model-serving] Service Mesh v2" "uninstalled"
fi

# [kfto] PyTorchJobs
if oc get pytorchjob -A --no-headers 2>/dev/null | grep -q .; then
  check PASS "[kfto] PyTorchJobs present" "$(oc get pytorchjob -A --no-headers 2>/dev/null | wc -l | tr -d ' ') jobs"
fi

echo
echo "========================================================="
printf 'Summary: %b%d PASS%b  %b%d WARN%b  %b%d FAIL%b\n' \
  "$c_pass" "$PASS" "$c_off" "$c_warn" "$WARN" "$c_off" "$c_fail" "$FAIL" "$c_off"
if (( FAIL > 0 )); then
  echo "Post-upgrade issues remain. Walk through the resolvers in resolvers/post-upgrade/ — the label in brackets (e.g. [operator]) is the resolver filename."
  exit 1
fi
echo "Post-upgrade validation clean. Finalization is complete."
