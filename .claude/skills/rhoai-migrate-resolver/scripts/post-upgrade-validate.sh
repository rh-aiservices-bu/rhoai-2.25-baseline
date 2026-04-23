#!/usr/bin/env bash
# Read-only post-upgrade check for an RHOAI 2.25.4 → 3.3.2 migration.
# Covers the post-upgrade verification tasks from the migration guide.
#
# This script does not modify the cluster. Run as cluster-admin.
#
# Severities:
#   PASS — check is green
#   WARN — unusual state, no action strictly required
#   FAIL — real regression; run the named resolver to fix
#   TODO — required post-upgrade user action documented in the migration guide
#          (e.g. patching stopped workbenches, recreating LSDs from archive).
#          A clean cluster with no FAILs can still have open TODOs.
#
# Exit code: 0 if no FAIL, 1 if any FAIL. TODOs do not fail the script.
# pipefail omitted: many checks pipe `oc ... | grep -q ...`, and grep exiting early
# on match surfaces as SIGPIPE (exit 141) and inverts the boolean.
set -u

PASS=0
FAIL=0
WARN=0
TODO=0
c_pass=$'\033[1;32m'
c_fail=$'\033[1;31m'
c_warn=$'\033[1;33m'
c_todo=$'\033[1;36m'
c_dim=$'\033[2m'
c_off=$'\033[0m'

check() {
  local status="$1" name="$2" detail="${3:-}"
  case "$status" in
    PASS) printf '%b[PASS]%b %s%s%b\n' "$c_pass" "$c_off" "$name" "${detail:+  $c_dim$detail$c_off}" "" ; PASS=$((PASS+1)) ;;
    FAIL) printf '%b[FAIL]%b %s%s%b\n' "$c_fail" "$c_off" "$name" "${detail:+  $detail}" "" ; FAIL=$((FAIL+1)) ;;
    WARN) printf '%b[WARN]%b %s%s%b\n' "$c_warn" "$c_off" "$name" "${detail:+  $detail}" "" ; WARN=$((WARN+1)) ;;
    TODO) printf '%b[TODO]%b %s%s%b\n' "$c_todo" "$c_off" "$name" "${detail:+  $detail}" "" ; TODO=$((TODO+1)) ;;
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

if oc get csv -n redhat-ods-operator -o name 2>/dev/null | grep -q 'rhods-operator\.2\.'; then
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
has_tas=0
if oc get trustyaiservice -A --no-headers 2>/dev/null | grep -q .; then
  has_tas=1
  if oc -n redhat-ods-applications get deployment trustyai-service-operator-controller-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -qx True; then
    check PASS "[trustyai] operator Available"
  else
    check FAIL "[trustyai] operator Available" "trustyai-service-operator-controller-manager not Available"
  fi
fi

# [trustyai] GuardrailsOrchestrator — stuck Progressing with zero pods is a known 3.x regression.
# DeploymentReady=True is the operational signal; .status.phase may linger at Progressing
# when a downstream dependency (e.g. InferenceService) isn't ready, which is not a FAIL.
if oc get guardrailsorchestrator -A --no-headers 2>/dev/null | grep -q .; then
  broken_gorch=""
  warn_gorch=""
  while IFS=$'\t' read -r ns name phase dep_ready; do
    [[ -z "$ns" ]] && continue
    if [[ "$dep_ready" == "True" ]]; then
      # Deployment is ready — orchestrator is up regardless of overall phase
      continue
    fi
    # No DeploymentReady=True → check for pods in the namespace
    if oc get pods -n "$ns" -l "app=$name" --no-headers 2>/dev/null | grep -q .; then
      warn_gorch="${warn_gorch}${ns}/${name}=${phase} "
    else
      broken_gorch="${broken_gorch}${ns}/${name} "
    fi
  done < <(oc get guardrailsorchestrator -A -o json 2>/dev/null | jq -r '
    .items[]
    | [
        .metadata.namespace,
        .metadata.name,
        (.status.phase // ""),
        ((.status.conditions[]? | select(.type == "DeploymentReady") | .status) // "")
      ]
    | @tsv
  ')
  if [[ -n "$broken_gorch" ]]; then
    check FAIL "[trustyai] GuardrailsOrchestrator Ready" "stuck + no pods: ${broken_gorch}— see trustyai.md (Guardrails)"
  elif [[ -n "$warn_gorch" ]]; then
    check WARN "[trustyai] GuardrailsOrchestrator phase" "$warn_gorch — reconciling or needs otelExporter restore"
  else
    check PASS "[trustyai] GuardrailsOrchestrator Deployment Ready"
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

# -----------------------------------------------------------------------------
# TODO — required post-upgrade user actions from the migration guide.
# These don't show as FAIL because the cluster isn't "broken" — but a cluster
# cannot be considered finalized until each of these is addressed.
# -----------------------------------------------------------------------------

# [workbenches] TODO — any Notebook still carrying the 2.x inject-oauth annotation
# needs the 2.x→3.x patch helper. Migrated CRs have notebooks.opendatahub.io/inject-auth=true
# and no longer have the legacy inject-oauth marker.
unmigrated_nb=$(oc get notebook -A -o json 2>/dev/null | jq -r '
  [.items[]
    | select(
        (.metadata.annotations."notebooks.opendatahub.io/inject-oauth" == "true")
        and ((.metadata.annotations."notebooks.opendatahub.io/inject-auth" // "") != "true")
      )
  ] | length
')
if [[ "${unmigrated_nb:-0}" -gt 0 ]]; then
  check TODO "[workbenches] patch ${unmigrated_nb} unmigrated workbench(es)" \
    "run workbench-2.x-to-3.x-upgrade.sh patch --only-stopped --with-cleanup -y (see workbenches.md)"
fi

# [workbenches] TODO — custom BYON ImageStreams in redhat-ods-applications won't survive the ns refresh
# Heuristic: list ImageStreams whose name doesn't match a default 3.x image-bundle name.
if oc get notebook -A --no-headers 2>/dev/null | grep -q .; then
  check TODO "[workbenches] re-import any custom BYON ImageStreams" \
    "redhat-ods-applications is refreshed on upgrade; user-managed ImageStreams must be re-imported (see workbenches.md)"
fi

# [ray] TODO — RayClusters still carrying the 2.x `ray.openshift.ai/version: UNKNOWN`
# annotation need the KubeRay migration script. A successful post-upgrade run writes a
# 3.x version value. (If the 2.x install never had CodeFlare sidecars, the post-upgrade
# script is a no-op and the annotation stays UNKNOWN — it's still listed as a TODO so the
# admin confirms this explicitly; see ray.md "Known quirk".)
rc_unmigrated=$(oc get raycluster -A -o json 2>/dev/null | jq -r '
  [.items[]
    | select(
        ((.metadata.annotations."ray.openshift.ai/version" // "UNKNOWN") == "UNKNOWN")
        or ((.metadata.annotations."ray.openshift.ai/version" // "") | startswith("2."))
      )
  ] | length
')
if [[ "${rc_unmigrated:-0}" -gt 0 ]]; then
  check TODO "[ray] migrate ${rc_unmigrated} RayCluster(s) to 3.x KubeRay conventions" \
    "run ray_cluster_migration.py post-upgrade (prerequisite: workbenches resolver complete) — see ray.md"
fi

# [model-serving] TODO — inferenceservice-config ConfigMap must be flipped back to managed=true
ifs_managed=$(oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o jsonpath='{.metadata.annotations.opendatahub\.io/managed}' 2>/dev/null || echo "")
case "$ifs_managed" in
  true)  check PASS "[model-serving] inferenceservice-config managed=true" ;;
  false) check TODO "[model-serving] restore inferenceservice-config managed=true" \
           "was set to false pre-upgrade; flip back + rollout restart kserve-controller-manager (see model-serving.md)" ;;
  "")    : ;; # annotation absent — common on fresh 3.x installs, nothing to do
  *)     check WARN "[model-serving] inferenceservice-config managed=$ifs_managed" "unexpected value" ;;
esac

# [pipelines] TODO — admin runs post_upgrade_check.sh; users validate pipelines
if oc get dspa -A --no-headers 2>/dev/null | grep -q .; then
  check TODO "[pipelines] run post_upgrade_check.sh and have users validate pipelines" \
    "per-DSPA health + user task: import/execute/scheduled-runs check (see pipelines.md)"
fi

# [registry] TODO — announce dashboard nav change (Models → AI hub)
if oc get modelregistry.modelregistry.opendatahub.io -A --no-headers 2>/dev/null | grep -q .; then
  check TODO "[registry] announce dashboard nav change: Models → AI hub" \
    "registry + catalog pods are fine; users searching 'Model registry' won't find it (see registry-catalog.md)"
fi

# [llama-stack] TODO — if LSD CRD exists, user needs to recreate LSDs from pre-upgrade archive
if oc get crd llamastackdistributions.llamastack.io >/dev/null 2>&1 \
   || oc get crd llamastackdistributions.llamastack.opendatahub.io >/dev/null 2>&1; then
  lsd_count=$(oc get llamastackdistribution -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${lsd_count:-0}" -eq 0 ]]; then
    check TODO "[llama-stack] recreate LSDs from pre-upgrade archive" \
      "data (agent state, telemetry, vector DBs) was lost by design; skip if you didn't use Llama Stack in 2.25 (see llama-stack.md)"
  else
    check PASS "[llama-stack] LSDs present" "$lsd_count"
  fi
fi

# [trustyai] TODO — check backups vs live + restore if data loss
if (( has_tas == 1 )); then
  check TODO "[trustyai] verify backups vs live metrics; restore if data loss" \
    "run the Check backups / Restore data steps (see trustyai.md)"
fi

echo
echo "========================================================="
printf 'Summary: %b%d PASS%b  %b%d WARN%b  %b%d FAIL%b  %b%d TODO%b\n' \
  "$c_pass" "$PASS" "$c_off" "$c_warn" "$WARN" "$c_off" "$c_fail" "$FAIL" "$c_off" "$c_todo" "$TODO" "$c_off"
if (( FAIL > 0 )); then
  echo "Post-upgrade issues remain. Walk through the resolvers in resolvers/post-upgrade/ — the label in brackets (e.g. [operator]) is the resolver filename."
  exit 1
fi
if (( TODO > 0 )); then
  echo "Platform healthy — required post-upgrade tasks remain. Walk each [TODO] through its resolver in resolvers/post-upgrade/, then re-run this script."
  exit 0
fi
echo "Post-upgrade validation clean. Finalization is complete."
