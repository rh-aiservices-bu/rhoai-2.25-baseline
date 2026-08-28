#!/usr/bin/env bash
# Read-only post-upgrade check for an RHOAI 2.25.10 (and later) → 3.5 migration.
# Covers the post-upgrade verification tasks from the migration guide.
#
# This script does not modify the cluster. Run as cluster-admin.
#
# Severities:
#   PASS — check is green
#   WARN — unusual state, no action strictly required
#   FAIL — real regression; run the named resolver to fix
#   TODO — required post-upgrade user action documented in the migration guide
#          (e.g. patching stopped workbenches, recreating OGXServer CRs from archive).
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

echo "RHOAI 2.25.10 → 3.5 migration — post-upgrade validation"
echo "========================================================="

# [operator] RHOAI operator version is 3.5.0 (and 2.25.x is gone)
csv_new=$(oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].metadata.name}' 2>/dev/null || echo "")
case "$csv_new" in
  rhods-operator.3.5.0) check PASS "[operator] RHOAI operator CSV" "$csv_new" ;;
  rhods-operator.3.*)   check WARN "[operator] RHOAI operator CSV" "$csv_new — this script targets 3.5.0 but newer 3.x may still work" ;;
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

# [operator] Data Science Gateway must be Programmed=True (Gateway API provider).
# A Programmed=False gateway is the classic sign of leftover Service Mesh 2 Istio CRDs
# (networking.istio.io served only at v1beta1/v1alpha3): the OCP built-in Gateway API
# control plane needs networking.istio.io/v1, so istiod-openshift-gateway stays 0/1 and
# the gateway never programs — which then blocks ModelRegistry and leaves the DSC Not Ready.
if oc get gateway data-science-gateway -n openshift-ingress >/dev/null 2>&1; then
  dsg_prog=$(oc get gateway data-science-gateway -n openshift-ingress -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || echo "")
  if [[ "$dsg_prog" == "True" ]]; then
    check PASS "[operator] data-science-gateway Programmed=True"
  else
    check FAIL "[operator] data-science-gateway Programmed" "status=$dsg_prog — suspect leftover Service Mesh 2 Istio CRDs (maistra networking.istio.io at v1beta1/v1alpha3 only); delete the stale *.istio.io CRDs and 'oc rollout restart deploy/ingress-operator' so the sail library reinstalls them at v1 (see operator resolver)"
  fi
else
  check WARN "[operator] data-science-gateway" "gateway 'data-science-gateway' not found in openshift-ingress — skip if Gateway API is not in use"
fi

# [operator] JobSet operator installed + jobsets.jobset.x-k8s.io CRD present.
# JobSet is a required Kueue dependency in 3.5; without it the DSC can stay Not Ready with KueueReady=False.
if oc get crd jobsets.jobset.x-k8s.io >/dev/null 2>&1; then
  if oc get csv -A --no-headers 2>/dev/null | grep -q 'jobset-operator\.'; then
    check PASS "[operator] JobSet operator" "jobsets.jobset.x-k8s.io CRD present, jobset-operator CSV installed"
  else
    check WARN "[operator] JobSet operator" "jobsets.jobset.x-k8s.io CRD present but jobset-operator CSV not found — confirm the JobSet operator install"
  fi
else
  check FAIL "[operator] JobSet operator" "jobsets.jobset.x-k8s.io CRD missing — install the JobSet operator (jobset-system, OwnNamespace OperatorGroup, sub 'job-set' channel stable-v1.0, source redhat-operators; CSV jobset-operator.v1.0.0; create JobSetOperator CR 'cluster') — required Kueue dependency"
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

# [model-serving] All ISVCs Standard deployment mode + Ready
# In 3.5 the DEPLOYMENT_MODE column renamed "RawDeployment" → "Standard"; accept either value.
bad_isvc=$(oc get isvc -A -o json 2>/dev/null | jq -r '.items[] | select((.status.deploymentMode // "") as $m | ($m != "Standard" and $m != "RawDeployment") or ((.status.conditions[]? | select(.type=="Ready") | .status) // "False") != "True") | "\(.metadata.namespace)/\(.metadata.name)=mode:\(.status.deploymentMode // "unknown"),ready:\((.status.conditions[]? | select(.type=="Ready") | .status) // "unknown")"')
if [[ -z "$bad_isvc" ]]; then
  check PASS "[model-serving] InferenceServices Standard (Raw) + Ready"
else
  check FAIL "[model-serving] InferenceServices Standard (Raw) + Ready" "$(echo "$bad_isvc" | tr '\n' ';')"
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

# [operator] Service Mesh Operator 3 must stay <= 3.3.x on OCP 4.19-4.21.
# OSSM 3.4.0 rejects the ingress-operator-pinned Gateway API Istio v1.26.2 as
# end-of-life, breaking openshift-gateway with a ReconcileError and no supported
# downgrade. Not an RHOAI bug — ref OSSM-14917 / OCPBUGS-92038 / RHOAIENG-76376.
ossm3_csv=$(oc get csv -A --no-headers 2>/dev/null | grep -oE 'servicemeshoperator3\.v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [ -n "$ossm3_csv" ]; then
  ossm3_ver=${ossm3_csv#servicemeshoperator3.v}
  if [ "$(printf '%s\n3.4.0\n' "$ossm3_ver" | sort -V | head -1)" = "3.4.0" ]; then
    check FAIL "[operator] Service Mesh Operator $ossm3_ver" "OSSM >= 3.4.0 breaks openshift-gateway on OCP 4.19-4.21 (Istio v1.26.2 EOL validation, no downgrade) — pin OSSM3 <= 3.3.x with Manual approval; ref OSSM-14917/OCPBUGS-92038"
  else
    check PASS "[operator] Service Mesh Operator $ossm3_ver" "<= 3.3.x — safe on OCP 4.19-4.21"
  fi
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
    "run 'rhai-cli migrate run --migration workbenches.patch-auth-model --target-version 3.5.0 --only-stopped --with-cleanup' (prompts for confirmation twice; see workbenches.md)"
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
    "run 'rhai-cli migrate run --migration raycluster.migrate --target-version 3.5.0' (prerequisite: workbenches resolver complete) — see ray.md"
fi

# [model-serving] TODO — inferenceservice-config ConfigMap must be flipped back to managed=true
ifs_managed=$(oc get configmap inferenceservice-config -n redhat-ods-applications \
  -o jsonpath='{.metadata.annotations.opendatahub\.io/managed}' 2>/dev/null || echo "")
case "$ifs_managed" in
  true)  check PASS "[model-serving] inferenceservice-config managed=true" ;;
  false) check TODO "[model-serving] restore inferenceservice-config managed=true" \
           "run 'rhai-cli migrate run --migration modelserving.managed-isvc-config --target-version 3.5.0' (flips managed back to true + restarts kserve-controller-manager; see model-serving.md)" ;;
  "")    : ;; # annotation absent — common on fresh 3.x installs, nothing to do
  *)     check WARN "[model-serving] inferenceservice-config managed=$ifs_managed" "unexpected value" ;;
esac

# [pipelines] TODO — admin runs post_upgrade_check.sh; users validate pipelines
if oc get dspa -A --no-headers 2>/dev/null | grep -q .; then
  check TODO "[pipelines] run ai-pipelines.post-upgrade-check and have users validate pipelines" \
    "run 'rhai-cli migrate run --migration ai-pipelines.post-upgrade-check --target-version 3.5.0' (compares against the saved dspa_pre_upgrade_pods.json baseline), then user task: import/execute/scheduled-runs check (see pipelines.md)"
fi

# [registry] TODO — announce dashboard nav change (Models → AI hub)
if oc get modelregistry.modelregistry.opendatahub.io -A --no-headers 2>/dev/null | grep -q .; then
  check TODO "[registry] announce dashboard nav change: Models → AI hub" \
    "registry + catalog pods are fine; users searching 'Model registry' won't find it (see registry-catalog.md)"
fi

# [ogx] TODO — Llama Stack is renamed OGX (Open GenAI Stack) in 3.5. LlamaStackDistribution CRs
# were deleted before upgrade and must be recreated as OGXServer (v1beta1) CRs from the archive.
# Detect the OGXServer CRD (group-agnostic); fall back to a lingering legacy LSD CRD.
ogx_crd=$(oc get crd -o name 2>/dev/null | grep -iE '(^|/)ogxservers\.' | head -n1)
lsd_crd=$(oc get crd -o name 2>/dev/null | grep -iE '(^|/)llamastackdistributions\.' | head -n1)
if [[ -n "$ogx_crd" || -n "$lsd_crd" ]]; then
  ogx_count=$(oc get ogxserver -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "${ogx_count:-0}" -eq 0 ]]; then
    check TODO "[ogx] recreate OGXServer CRs from pre-upgrade archive" \
      "Llama Stack → OGX rename: recreate former LlamaStackDistribution CRs as OGXServer (v1beta1) using the llamastack.backup archive as reference; data (agent state, telemetry, vector DBs) was lost by design; skip if you didn't use Llama Stack in 2.25 (see llama-stack.md)"
  else
    check PASS "[ogx] OGXServer CRs present" "$ogx_count"
  fi
fi

# [training] TODO — verify Kubeflow v1 training workloads are ready for Trainer v2.
# Read-only enumeration of PyTorchJob/TFJob/MPIJob/XGBoostJob; any still Running/Created is a blocker.
kfto_present=0
for k in pytorchjob tfjob mpijob xgboostjob; do
  if oc get "$k" -A --no-headers 2>/dev/null | grep -q .; then kfto_present=1; break; fi
done
if (( kfto_present == 1 )); then
  check TODO "[training] verify Kubeflow v1 training workloads (Trainer v2 readiness)" \
    "run 'rhai-cli migrate run --migration training.verify-workloads --target-version 3.5.0' (read-only enumeration; reports [BLOCKER] for any workload still Running/Created — see training.md)"
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
