#!/usr/bin/env bash
# Reads an `rhai-cli lint --output yaml` assessment file and runs install.sh
# parameterized to reproduce a cluster that would yield a similar assessment.
#
# Tier 1 semantics (approximate match):
#   - Per-kind workload toggles: if the assessment mentions a kind with count>0
#     (or an impacted issue) we deploy that sample; otherwise we skip it.
#   - DSC component states: each DSC component with an explicit management-state
#     annotation in the assessment is mapped to a DSC_*_STATE env var.
#   - Operator install toggles: SM v2, Serverless, standalone Authorino are
#     installed only if the assessment indicates they exist on the source cluster.
#   - Same-issues/blockers goal: we aim for the reproduced cluster to yield a
#     similar assessment report, NOT byte-identical workload specs.
#
# Tier 1 does NOT:
#   - Reproduce specific namespace names (we use our standard sample namespaces).
#   - Inject deprecated schema fields (e.g. DSPA .spec.apiServer.managedPipelines.instructLab).
#     Those issues won't appear in a follow-up lint of the reproduced cluster.
#     A summary of skipped issues is printed at the end.
#
# Usage:
#   ./install-from-assessment.sh <path-to-assessment.yaml> [--dry-run]
#
# Requires: yq (Mike Farah v4 — the Go one), oc, jq, envsubst, bash 4+ or 3.2+.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ASSESSMENT="${1:-}"
DRY_RUN="${2:-}"

if [[ -z "$ASSESSMENT" ]]; then
  cat <<EOF
usage: $0 <assessment.yaml> [--dry-run]

Reads an rhai-cli lint YAML assessment and invokes install.sh with matching env vars.
--dry-run prints the derived env vars + planned install.sh invocation, then exits.
EOF
  exit 1
fi

[[ -f "$ASSESSMENT" ]] || die "assessment file not found: $ASSESSMENT"
require_cmd yq jq envsubst oc

# Sanity check the assessment file
if ! yq eval '.results' "$ASSESSMENT" >/dev/null 2>&1; then
  die "'$ASSESSMENT' doesn't parse as a rhai-cli lint YAML (missing .results?)"
fi

cv=$(yq eval '.clusterVersion // "unknown"' "$ASSESSMENT")
tv=$(yq eval '.targetVersion // "unknown"' "$ASSESSMENT")
log "assessment: clusterVersion=$cv  targetVersion=$tv"

# --- helpers for extracting signals -------------------------------------------

# True if a specific check (group, kind, name) has a condition with given reason.
has_check_reason() {
  local group="$1" kind="$2" name="$3" reason="$4"
  local hit
  hit=$(yq eval ".results[] | select(.group==\"$group\" and .kind==\"$kind\" and .name==\"$name\") | .status.conditions[] | select(.reason==\"$reason\") | .reason" "$ASSESSMENT" 2>/dev/null)
  [[ -n "$hit" ]]
}

# Pulls impacted-count annotation for a kind; 0 if absent or non-numeric.
count_for_kind() {
  local kind="$1"
  local val
  val=$(yq eval "[.results[] | select(.kind==\"$kind\" and .annotations[\"workload.opendatahub.io/impacted-count\"])] | map(.annotations[\"workload.opendatahub.io/impacted-count\"] | tonumber) | max // 0" "$ASSESSMENT" 2>/dev/null)
  [[ "$val" =~ ^[0-9]+$ ]] || val=0
  printf '%s\n' "$val"
}

# Pulls the component management-state annotation for a DSC component (by kind match).
dsc_component_state() {
  local kind="$1"
  yq eval "[.results[] | select(.kind==\"$kind\" and .annotations[\"component.opendatahub.io/management-state\"])] | .[0].annotations[\"component.opendatahub.io/management-state\"] // \"\"" "$ASSESSMENT"
}

# True if any result matches (group, kind, name) at all.
has_check() {
  local group="$1" kind="$2" name="$3"
  local hit
  hit=$(yq eval "[.results[] | select(.group==\"$group\" and .kind==\"$kind\" and .name==\"$name\")] | length" "$ASSESSMENT")
  (( hit > 0 ))
}

# --- operator install toggles -------------------------------------------------

# SM v2: check "dependency / servicemesh-operator-v2 / upgrade" — Compatible=True + VersionCompatible means NOT installed.
if has_check_reason dependency servicemesh-operator-v2 upgrade VersionCompatible; then
  export INSTALL_SERVICE_MESH_V2=0
else
  export INSTALL_SERVICE_MESH_V2=1
fi

# Serverless operator — no direct check; infer from kserve.serving state.
# If kserve serving is Removed OR serverless-removal check is Compatible=True, Serverless isn't needed.
if has_check_reason component kserve serverless-removal VersionCompatible; then
  export INSTALL_SERVERLESS=0
else
  export INSTALL_SERVERLESS=1
fi

# Standalone Authorino — tied to Serverless on 2.x. If Serverless is gone, so is Authorino.
export INSTALL_AUTHORINO_STANDALONE="$INSTALL_SERVERLESS"

# --- DSCI + DSC state overrides ----------------------------------------------

# DSCI.serviceMesh.managementState: look at "service / servicemesh / removal"
if has_check_reason service servicemesh removal VersionCompatible; then
  export DSCI_SERVICEMESH_STATE=Removed
else
  export DSCI_SERVICEMESH_STATE=Managed
fi

# DSC kserve.serving + defaultDeploymentMode
if has_check_reason component kserve serverless-removal VersionCompatible; then
  export DSC_KSERVE_SERVING_STATE=Removed
  export DSC_KSERVE_DEFAULT_MODE=RawDeployment
else
  export DSC_KSERVE_SERVING_STATE=Managed
  export DSC_KSERVE_DEFAULT_MODE=Serverless
fi

# Per-component DSC state from annotations
for kvpair in \
    "kserve:DSC_KSERVE_MANAGEMENT_STATE" \
    "datasciencepipelines:DSC_DATASCIENCEPIPELINES_STATE"; do
  kind="${kvpair%%:*}"; var="${kvpair##*:}"
  state=$(dsc_component_state "$kind")
  [[ -n "$state" ]] && export "$var=$state"
done

# Other DSC components: the assessment rarely emits their management-state
# annotations unless the component is Managed and relevant. Default to Managed
# unless kserve is clearly post-migration (in which case modelmeshserving should
# also be Removed — they're typically removed together).
if [[ "$DSC_KSERVE_SERVING_STATE" == "Removed" ]]; then
  : "${DSC_MODELMESH_STATE:=Removed}"
  : "${DSC_KUEUE_STATE:=Removed}"
fi
export DSC_MODELMESH_STATE="${DSC_MODELMESH_STATE:-Managed}"
export DSC_KUEUE_STATE="${DSC_KUEUE_STATE:-Managed}"

# --- per-sample workload toggles ---------------------------------------------

# Default everything OFF, turn on only what the assessment suggests exists.
# (Assessments typically omit whole families when no workloads of that kind exist.)
export INSTALL_WORKBENCHES=0
export INSTALL_BYON_IMAGESTREAM=0
export INSTALL_KSERVE_SERVERLESS=0
export INSTALL_KSERVE_MODELMESH=0
export INSTALL_KSERVE_RAW=0
export INSTALL_LLM_ISVC=0
export INSTALL_RAY=0
export INSTALL_KFTO=0
export INSTALL_TRUSTYAI=0
export INSTALL_PIPELINES=0
export INSTALL_FEAST=0
export INSTALL_LLAMA_STACK=0
export INSTALL_MODEL_REGISTRY=0

# GPU operator — the assessment doesn't cover GPU, leave it skipped.
export INSTALL_GPU=0

if (( $(count_for_kind notebook) > 0 )); then
  export INSTALL_WORKBENCHES=1
fi
if (( $(count_for_kind datasciencepipelines) > 0 )) || has_check workload datasciencepipelines instructlab-removal; then
  export INSTALL_PIPELINES=1
fi
# KServe ISVC families — broken into Serverless / ModelMesh / Raw by inspecting messages.
# If any kserve check has count>0 or reports impacted Serverless/ModelMesh ISVCs, install the matching family.
# For Tier 1 we err on "install kserve samples if there's any KServe workload signal".
kserve_count=$(count_for_kind kserve)
if (( kserve_count > 0 )); then
  # Default to kserve-raw (the safest migration-state — doesn't need SM/Serverless).
  export INSTALL_KSERVE_RAW=1
  # If Serverless operator is still required, the cluster has Serverless ISVCs.
  if [[ "$INSTALL_SERVERLESS" == "1" ]]; then
    export INSTALL_KSERVE_SERVERLESS=1
  fi
fi
if (( $(count_for_kind ray) > 0 )); then
  export INSTALL_RAY=1
fi
if (( $(count_for_kind trainingoperator) > 0 )); then
  export INSTALL_KFTO=1
fi
if (( $(count_for_kind trustyai) > 0 )) || (( $(count_for_kind guardrails) > 0 )); then
  export INSTALL_TRUSTYAI=1
fi
if (( $(count_for_kind featurestore) > 0 )); then
  export INSTALL_FEAST=1
fi
if (( $(count_for_kind llamastackdistribution) > 0 )); then
  export INSTALL_LLAMA_STACK=1
fi
if (( $(count_for_kind modelregistry) > 0 )); then
  export INSTALL_MODEL_REGISTRY=1
fi
if (( $(count_for_kind llminferenceservice) > 0 )); then
  export INSTALL_LLM_ISVC=1
fi

# --- print summary -----------------------------------------------------------

echo "-----------------------------------------------------------------"
echo "Derived install parameters from: $ASSESSMENT"
echo "-----------------------------------------------------------------"
echo "Operators:"
printf '  %-30s %s\n' \
  INSTALL_SERVICE_MESH_V2       "$INSTALL_SERVICE_MESH_V2" \
  INSTALL_SERVERLESS            "$INSTALL_SERVERLESS" \
  INSTALL_AUTHORINO_STANDALONE  "$INSTALL_AUTHORINO_STANDALONE" \
  INSTALL_GPU                   "$INSTALL_GPU"
echo "DSC/DSCI state:"
printf '  %-30s %s\n' \
  DSCI_SERVICEMESH_STATE          "$DSCI_SERVICEMESH_STATE" \
  DSC_KSERVE_MANAGEMENT_STATE     "${DSC_KSERVE_MANAGEMENT_STATE:-Managed}" \
  DSC_KSERVE_DEFAULT_MODE         "$DSC_KSERVE_DEFAULT_MODE" \
  DSC_KSERVE_SERVING_STATE        "$DSC_KSERVE_SERVING_STATE" \
  DSC_MODELMESH_STATE             "$DSC_MODELMESH_STATE" \
  DSC_KUEUE_STATE                 "$DSC_KUEUE_STATE" \
  DSC_DATASCIENCEPIPELINES_STATE  "${DSC_DATASCIENCEPIPELINES_STATE:-Managed}"
echo "Samples:"
printf '  %-30s %s\n' \
  INSTALL_WORKBENCHES             "$INSTALL_WORKBENCHES" \
  INSTALL_BYON_IMAGESTREAM        "$INSTALL_BYON_IMAGESTREAM" \
  INSTALL_PIPELINES               "$INSTALL_PIPELINES" \
  INSTALL_KSERVE_SERVERLESS       "$INSTALL_KSERVE_SERVERLESS" \
  INSTALL_KSERVE_MODELMESH        "$INSTALL_KSERVE_MODELMESH" \
  INSTALL_KSERVE_RAW              "$INSTALL_KSERVE_RAW" \
  INSTALL_LLM_ISVC                "$INSTALL_LLM_ISVC" \
  INSTALL_RAY                     "$INSTALL_RAY" \
  INSTALL_KFTO                    "$INSTALL_KFTO" \
  INSTALL_TRUSTYAI                "$INSTALL_TRUSTYAI" \
  INSTALL_FEAST                   "$INSTALL_FEAST" \
  INSTALL_LLAMA_STACK             "$INSTALL_LLAMA_STACK" \
  INSTALL_MODEL_REGISTRY          "$INSTALL_MODEL_REGISTRY"

# --- Tier-2 caveat: list issues we CAN'T faithfully reproduce in Tier 1 -----
echo
echo "Issues in this assessment that Tier 1 cannot reproduce (would need Tier 2 field injection):"
yq eval '.results[] | select(.status.conditions[] | select(.status=="False" and .type=="Compatible")) | "  - \(.group)/\(.kind)/\(.name): \(.status.conditions[0].message)"' "$ASSESSMENT" | grep -E 'instructLab|ConfigurationUnmanaged|managed=false|deprecated field' || echo "  (none detected)"

echo "-----------------------------------------------------------------"

if [[ "$DRY_RUN" == "--dry-run" ]]; then
  log "--dry-run — not invoking install.sh"
  exit 0
fi

log "invoking install.sh with derived env..."
exec "${SCRIPT_DIR}/install.sh"
