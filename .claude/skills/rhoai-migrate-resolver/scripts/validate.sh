#!/usr/bin/env bash
# Read-only final-readiness check for an RHOAI 2.25.4 → 3.3.2 migration.
# Complements 'rhai-cli lint' — verifies every migration blocker identified by the
# 2.x → 3.x migration guide has been resolved.
#
# This script does not modify the cluster. Run as cluster-admin.
# Exit code: 0 if all checks PASS, 1 if any critical FAIL.

# Deliberately not using `pipefail`: many checks pipe `oc get csv -A | grep -q ...`,
# and `grep -q` exiting early on match causes `oc` to SIGPIPE (exit 141), which
# pipefail would surface as a non-zero pipeline status and silently invert the check.
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

echo "RHOAI 2.25.4 → 3.3.2 migration — readiness validation"
echo "======================================================"

# §2.1 cert-manager
if oc get csv -A 2>/dev/null | grep -q 'cert-manager-operator'; then
  check PASS "§2.1 cert-manager Operator installed"
else
  check FAIL "§2.1 cert-manager Operator installed" "install from OperatorHub → 'cert-manager Operator for Red Hat OpenShift'"
fi

# §2.2 Kueue = Removed
kueue_state=$(oc get dsc -o jsonpath='{.items[0].spec.components.kueue.managementState}' 2>/dev/null || echo "")
case "$kueue_state" in
  Removed) check PASS "§2.2 kueue.managementState" "Removed" ;;
  "")     check FAIL "§2.2 kueue.managementState" "not set — DSC missing or kueue block absent" ;;
  *)      check FAIL "§2.2 kueue.managementState" "$kueue_state — must be Removed before upgrade" ;;
esac

# §2.6 workbenches — all Stopped
if running=$(oc get notebooks -A -o json 2>/dev/null | jq -r '.items[] | select((.metadata.annotations."kubeflow-resource-stopped" // "false") != "true") | "\(.metadata.namespace)/\(.metadata.name)"'); then
  if [[ -n "$running" ]]; then
    n=$(echo "$running" | wc -l | tr -d ' ')
    check FAIL "§2.6.2 workbenches stopped" "$n Notebook(s) not Stopped: $(echo "$running" | tr '\n' ' ')"
  else
    check PASS "§2.6.2 workbenches stopped" "all Notebook CRs annotated kubeflow-resource-stopped=true"
  fi
fi

# §2.8.7 No Serverless ISVCs remain
sl_count=$(oc get isvc -A -o json 2>/dev/null | jq '[.items[] | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") == "Serverless" or (.status.deploymentMode // "") == "Serverless")] | length')
if [[ "${sl_count:-0}" == "0" ]]; then
  check PASS "§2.8.7.1 Serverless InferenceServices" "none remain"
else
  check FAIL "§2.8.7.1 Serverless InferenceServices" "$sl_count still in Serverless mode — convert to RawDeployment"
fi

# §2.8.7 No ModelMesh ISVCs remain
mm_count=$(oc get isvc -A -o json 2>/dev/null | jq '[.items[] | select((.metadata.annotations."serving.kserve.io/deploymentMode" // "") == "ModelMesh" or (.status.deploymentMode // "") == "ModelMesh")] | length')
if [[ "${mm_count:-0}" == "0" ]]; then
  check PASS "§2.8.7.2 ModelMesh InferenceServices" "none remain"
else
  check FAIL "§2.8.7.2 ModelMesh InferenceServices" "$mm_count still in ModelMesh mode — convert to RawDeployment"
fi

# §2.8.9 DSC kserve.serving = Removed
kserve_serving=$(oc get dsc -o jsonpath='{.items[0].spec.components.kserve.serving.managementState}' 2>/dev/null || echo "")
case "$kserve_serving" in
  Removed) check PASS "§2.8.9 kserve.serving.managementState" "Removed" ;;
  *)       check FAIL "§2.8.9 kserve.serving.managementState" "$kserve_serving — must be Removed" ;;
esac

# §2.8.9 DSC modelmeshserving = Removed
mm_state=$(oc get dsc -o jsonpath='{.items[0].spec.components.modelmeshserving.managementState}' 2>/dev/null || echo "")
case "$mm_state" in
  Removed) check PASS "§2.8.9 modelmeshserving.managementState" "Removed" ;;
  *)       check FAIL "§2.8.9 modelmeshserving.managementState" "$mm_state — must be Removed" ;;
esac

# §2.8.9 DSCI serviceMesh = Removed
sm_state=$(oc get dsci -o jsonpath='{.items[0].spec.serviceMesh.managementState}' 2>/dev/null || echo "")
case "$sm_state" in
  Removed) check PASS "§2.8.9 DSCI serviceMesh.managementState" "Removed" ;;
  *)       check FAIL "§2.8.9 DSCI serviceMesh.managementState" "$sm_state — must be Removed" ;;
esac

# §2.8.9 OpenShift Serverless uninstalled
if oc get csv -A 2>/dev/null | grep -q 'serverless-operator\.'; then
  check FAIL "§2.8.9 OpenShift Serverless" "still installed — uninstall before upgrade"
else
  check PASS "§2.8.9 OpenShift Serverless" "uninstalled"
fi

# §2.8.9 Service Mesh v2 uninstalled
if oc get csv -A 2>/dev/null | grep -qE 'servicemeshoperator\.v2\.'; then
  check FAIL "§2.8.9 Service Mesh v2" "servicemeshoperator v2 still installed — uninstall (or upgrade to v3 if other workloads need it)"
else
  check PASS "§2.8.9 Service Mesh v2" "uninstalled"
fi

# §2.8.9 Standalone Authorino uninstalled
# (RHCL also bundles Authorino — we want standalone gone, RHCL ok)
if oc get csv -n openshift-operators 2>/dev/null | grep -q 'authorino-operator\.'; then
  check FAIL "§2.8.9 standalone Authorino" "authorino-operator still present in openshift-operators — uninstall; RHCL replaces it"
else
  check PASS "§2.8.9 standalone Authorino" "uninstalled"
fi

# DSC overall Ready
dsc_phase=$(oc get dsc -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
if [[ "$dsc_phase" == "Ready" ]]; then
  check PASS "DSC phase=Ready"
else
  check WARN "DSC phase" "$dsc_phase — expected Ready; transient mid-reconciliation is OK"
fi

# §2.10 RHOAI operator version — should still be 2.25.4 until chapter 3
csv_name=$(oc get csv -n redhat-ods-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift AI")].metadata.name}' 2>/dev/null || echo "")
case "$csv_name" in
  rhods-operator.2.25.4) check PASS "§2.10 RHOAI operator" "$csv_name (ready for chapter-3 upgrade)" ;;
  rhods-operator.2.25.*) check WARN "§2.10 RHOAI operator" "$csv_name — this skill targets 2.25.4" ;;
  "")                    check FAIL "§2.10 RHOAI operator" "not found in redhat-ods-operator namespace" ;;
  *)                     check WARN "§2.10 RHOAI operator" "$csv_name — unexpected version" ;;
esac

echo
echo "======================================================"
printf 'Summary: %b%d PASS%b  %b%d WARN%b  %b%d FAIL%b\n' \
  "$c_pass" "$PASS" "$c_off" "$c_warn" "$WARN" "$c_off" "$c_fail" "$FAIL" "$c_off"
if (( FAIL > 0 )); then
  echo "Not ready to upgrade — resolve FAIL items first, then re-run 'rhai-cli lint'."
  exit 1
fi
echo "All migration blockers resolved. Run 'rhai-cli lint --target-version 3.3.2' once more to confirm, then proceed to chapter 3."
