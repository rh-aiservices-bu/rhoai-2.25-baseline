#!/usr/bin/env bash
# route.sh — deterministic rhai-cli-output → resolver router.
#
# Purpose: take the RHOAI 2.25.4 → 3.3.2 `rhai-cli lint` report and print the EXACT,
# priority-ordered list of resolver files the admin must walk, plus which signal matched.
# This offloads the routing/priority reasoning from the model so a weaker model
# (e.g. qwen 3.6 under opencode) doesn't have to infer it from the mapping table.
#
# This script does NOT touch the cluster and does NOT need cluster access — it only
# reads the lint output you give it.
#
# Usage:
#   bash route.sh <rhai-cli-output.(yaml|txt)>     # from a saved report
#   rhai-cli lint --target-version 3.3.2 | bash route.sh   # from a pipe
#   bash route.sh                                  # reads stdin
#
# Matching is whole-document + case-insensitive: for each routing rule it asks
# "does the report mention this KIND together with this CHECK?". It is a routing aid,
# not a counter — it tells you WHICH resolvers and in WHAT order, not how many
# InferenceServices. The resolver itself enumerates specifics.

set -u

# ---- read input (file arg or stdin) ----------------------------------------
if [[ $# -ge 1 && "$1" != "-" ]]; then
  if [[ ! -r "$1" ]]; then
    echo "route.sh: cannot read '$1'" >&2
    exit 2
  fi
  raw=$(cat "$1")
else
  raw=$(cat)
fi

if [[ -z "${raw// /}" ]]; then
  cat >&2 <<'EOF'
route.sh: no input.
  Provide the rhai-cli report as a file or on stdin, e.g.:
    rhai-cli lint --target-version 3.3.2 --output yaml > rhai-cli-output.yaml
    bash route.sh rhai-cli-output.yaml
EOF
  exit 2
fi

# lower-case copy for case-insensitive substring tests
lc=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')

has() { [[ "$lc" == *"$1"* ]]; }

# priority flag for the header
prio_note=""
if has "prohibited"; then prio_note="report contains PROHIBITED items — do those first"; fi
if has "critical" && [[ -z "$prio_note" ]]; then prio_note="report contains CRITICAL items"; fi

# ---- routing rules ----------------------------------------------------------
# Each rule: PRIORITY|KIND_TOKEN|CHECK_TOKENS(space-sep, "*"=any)|RESOLVER|LABEL
# PRIORITY orders the emitted plan (dependencies before dependents). Mirrors
# resolvers/README.md § Priority order. Lower number = earlier.
rules=(
  "2|openshift|version-requirement|resolvers/ocp.md|OCP version < 4.19.9"
  "3|cert-manager|*|resolvers/cert-manager.md|cert-manager Operator not installed"
  "4|kueue|*|resolvers/kueue.md|Kueue managementState must be Removed/Unmanaged"
  "5|notebook|image-version custom-image stopped|resolvers/workbenches.md|Workbench image/stop tasks"
  "6|trustyai|*|resolvers/trustyai.md|TrustyAI metrics + data backup"
  "6|guardrails|*|resolvers/trustyai.md|Guardrails backup (trustyai.md § Guardrails)"
  "6|llamastackdistribution|*|resolvers/llama-stack.md|Llama Stack data archive (data is lost)"
  "6|ray|*|resolvers/ray.md|Ray/CodeFlare — back up RayClusters, codeflare→Removed"
  "6|codeflare|*|resolvers/ray.md|Ray/CodeFlare — back up RayClusters, codeflare→Removed"
  "6|datasciencepipelines|*|resolvers/pipelines.md|DSPA pre-upgrade check"
  "7|kserve|serverless-removal serving-removal|resolvers/kserve.md|KServe — disable Serverless on the DSC"
  "7|modelmeshserving|removal|resolvers/kserve.md|KServe — disable ModelMesh on the DSC"
  "7|kserve|impacted-workloads isvc- servingruntime-|resolvers/kserve.md|KServe — convert InferenceServices to RawDeployment"
  "7|servicemesh-operator-v2|*|resolvers/kserve.md|KServe — uninstall Service Mesh v2"
  "7|serverless-operator|uninstall|resolvers/kserve.md|KServe — uninstall OpenShift Serverless"
  "7|authorino-operator|uninstall|resolvers/kserve.md|KServe — uninstall standalone Authorino"
  "8|llminferenceservice|template-pinning auth|resolvers/llm-isvc.md|LLMInferenceService template pinning + RHCL"
)

matched=()   # "PRIORITY|RESOLVER|LABEL"

for rule in "${rules[@]}"; do
  IFS='|' read -r prio kind checks resolver label <<<"$rule"
  has "$kind" || continue
  if [[ "$checks" == "*" ]]; then
    matched+=("$prio|$resolver|$label")
  else
    for c in $checks; do
      if has "$c"; then
        matched+=("$prio|$resolver|$label")
        break
      fi
    done
  fi
done

# ---- emit the plan ----------------------------------------------------------
echo "RHOAI 2.25.4 → 3.3.2 — pre-upgrade resolver plan"
echo "================================================="
[[ -n "$prio_note" ]] && echo "! $prio_note"
echo
echo "Walk these resolvers IN THIS ORDER. One at a time. Re-run rhai-cli between phases."
echo

# Priority 1 is always-on regardless of the report (can't be inspected from the lint).
echo "  1  resolvers/backup.md               ALWAYS — verified backup is the only rollback path"

if [[ ${#matched[@]} -eq 0 ]]; then
  echo
  echo "No pre-upgrade KIND/CHECK signals matched in the report."
  echo "Either the report is clean, or its format wasn't recognized — fall back to"
  echo "resolvers/README.md § Routing table and match (GROUP, KIND, CHECK) by hand."
  exit 0
fi

# stable sort by priority, dedup on RESOLVER (first/highest-priority label wins)
printf '%s\n' "${matched[@]}" \
  | sort -t'|' -k1,1n -k2,2 \
  | awk -F'|' '!seen[$2]++ { printf "  %s  %-32s %s\n", $1, $2, $3 }'

echo
echo "After each resolver: re-run  rhai-cli lint --target-version 3.3.2  and re-run this"
echo "router — some checks only appear once prior items are resolved (e.g. the DSCI"
echo "serviceMesh check fires only after Serverless ISVCs are gone)."
echo
echo "When rhai-cli is clean, run:  bash scripts/validate.sh"
