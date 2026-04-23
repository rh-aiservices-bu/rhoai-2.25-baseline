#!/usr/bin/env bash
# Read-only check of the static platform prerequisites for an RHOAI 2.25.4 → 3.3.2 migration.
# See architectural-changes.md § Platform Prerequisites.
#
# This script does not modify the cluster. Run as a user with cluster-admin context.
# Exit code: 0 if all checks PASS, 1 otherwise.

# pipefail omitted intentionally — several checks pipe `oc ... | grep -q ...`, and
# grep exiting early on match would surface as SIGPIPE (exit 141) and invert the check.
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

echo "RHOAI 2.25.4 → 3.3.2 migration — platform prereqs"
echo "==================================================="

# 1. Logged in
if ! oc whoami >/dev/null 2>&1; then
  check FAIL "oc login" "not logged in — run 'oc login' first"
  exit 1
fi
check PASS "oc login" "user: $(oc whoami), server: $(oc whoami --show-server)"

# 2. Cluster-admin
if oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1; then
  check PASS "cluster-admin access"
else
  check FAIL "cluster-admin access" "current user cannot perform '*' on all namespaces"
fi

# 3. OCP version ≥ 4.19.9 (architectural-changes.md § Platform Prerequisites)
ocp_raw=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "")
if [[ -z "$ocp_raw" ]]; then
  check FAIL "OCP version" "could not read clusterversion"
else
  # Parse X.Y.Z, require >= 4.19.9
  IFS='.' read -r major minor patch <<<"$ocp_raw"
  patch="${patch%%-*}"  # strip pre-release suffix if any
  ok=0
  if [[ "$major" == "4" ]]; then
    if (( minor > 19 )); then ok=1
    elif (( minor == 19 )) && (( patch >= 9 )); then ok=1
    fi
  elif (( major > 4 )); then
    ok=1
  fi
  if (( ok == 1 )); then
    check PASS "OCP version" "$ocp_raw (≥ 4.19.9 required)"
  else
    check FAIL "OCP version" "$ocp_raw — must be ≥ 4.19.9; upgrade OCP first"
  fi
fi

# 4. Default StorageClass
default_sc=$(oc get sc -o json 2>/dev/null \
  | jq -r '.items[] | select(.metadata.annotations."storageclass.kubernetes.io/is-default-class"=="true") | .metadata.name' \
  | head -n1)
if [[ -n "$default_sc" ]]; then
  check PASS "default StorageClass" "$default_sc"
else
  check FAIL "default StorageClass" "no StorageClass is annotated as default"
fi

# 5. Pull secret has registry.redhat.io
if oc get secret pull-secret -n openshift-config >/dev/null 2>&1; then
  auths=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null \
    | base64 -d 2>/dev/null \
    | jq -r '.auths | keys | .[]' 2>/dev/null || true)
  if echo "$auths" | grep -qx "registry.redhat.io"; then
    check PASS "pull secret" "registry.redhat.io auth present"
  else
    check FAIL "pull secret" "registry.redhat.io missing from openshift-config/pull-secret"
  fi
else
  check FAIL "pull secret" "openshift-config/pull-secret not readable"
fi

# 6. DataScienceCluster + DSCInitialization exist (proves RHOAI 2.x operator is installed)
if oc get dsci --no-headers 2>/dev/null | grep -q .; then
  dsci_phase=$(oc get dsci -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo unknown)
  check PASS "DSCInitialization present" "phase=$dsci_phase"
else
  check FAIL "DSCInitialization present" "no DSCI found — is the RHOAI operator installed?"
fi
if oc get dsc --no-headers 2>/dev/null | grep -q .; then
  dsc_phase=$(oc get dsc -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo unknown)
  dsc_ver=$(oc get dsc -o jsonpath='{.items[0].status.release.version}' 2>/dev/null || echo unknown)
  case "$dsc_ver" in
    2.25.*) check PASS "DataScienceCluster present" "version=$dsc_ver phase=$dsc_phase" ;;
    "" | unknown) check WARN "DataScienceCluster present" "version unknown — ensure 2.25.4" ;;
    *) check WARN "DataScienceCluster present" "version=$dsc_ver — this skill targets 2.25.4" ;;
  esac
else
  check FAIL "DataScienceCluster present" "no DSC found"
fi

# 7. Backup advisory — we can't verify, so remind
check WARN "cluster backup" "in-place migration requires a verified backup (architectural-changes.md § In-Place Migration)"

echo
echo "==================================================="
printf 'Summary: %b%d PASS%b  %b%d WARN%b  %b%d FAIL%b\n' \
  "$c_pass" "$PASS" "$c_off" "$c_warn" "$WARN" "$c_off" "$c_fail" "$FAIL" "$c_off"
if (( FAIL > 0 )); then
  echo "Fix all FAIL items before continuing. WARN items are informational."
  exit 1
fi
echo "Platform prereqs OK. Run 'rhai-cli lint --target-version 3.3.2' next to enumerate migration blockers."
