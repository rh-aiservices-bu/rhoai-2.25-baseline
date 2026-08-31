#!/usr/bin/env bash
# GitOps bootstrap for rhoai-2254-install.
#
# What it does:
#   1. Install the OpenShift GitOps operator (Argo CD) if not present
#   2. Wait for the default openshift-gitops ArgoCD instance to be ready
#   3. Grant the Argo CD application controller cluster-admin
#   4. Apply the root app-of-apps Application pointing at the selected overlay
#
# Inputs (env vars or .env file in this directory):
#   REPO_URL          Git repository URL hosting rhoai-2254-install/
#                     (required — no default; example: https://github.com/<org>/rhoai-migrations.git)
#   TARGET_REVISION   Git revision to track (default: release-3.5)
#   OVERLAY           Overlay name under gitops/overlays/ (default: all)
#
# Usage:
#   REPO_URL=https://github.com/yourorg/rhoai-migrations.git ./gitops/bootstrap.sh
# or
#   cp gitops/.env.example gitops/.env && edit gitops/.env && ./gitops/bootstrap.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env if present.
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/.env"
fi

: "${TARGET_REVISION:=release-3.5}"
: "${OVERLAY:=all}"

if [[ -z "${REPO_URL:-}" ]]; then
  echo "ERROR: REPO_URL is required (env var or in gitops/.env)" >&2
  echo "  example: REPO_URL=https://github.com/yourorg/rhoai-migrations.git" >&2
  exit 1
fi

if [[ ! -d "${SCRIPT_DIR}/overlays/${OVERLAY}" ]]; then
  echo "ERROR: overlay '${OVERLAY}' does not exist under gitops/overlays/" >&2
  echo "  available: $(ls "${SCRIPT_DIR}/overlays" | tr '\n' ' ')" >&2
  exit 1
fi

log()  { echo "[bootstrap] $*"; }
die()  { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

# Argo CD reads apps/*.yaml directly from Git; their repoURL/targetRevision
# have to be committed with real values (envsubst can't reach them). Reject
# early if the placeholders are still in place — that means render.sh either
# hasn't been run or its output wasn't committed and pushed.
if grep -q '\${REPO_URL}' "${SCRIPT_DIR}/apps/"*.yaml 2>/dev/null; then
  die "gitops/apps/*.yaml still contains \${REPO_URL} placeholders. Run:
    ./gitops/render.sh
    git add gitops/apps && git commit -m 'render apps' && git push
  then re-run bootstrap.sh."
fi

oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (oc whoami failed)"

log "installing OpenShift GitOps operator (if absent)"
oc apply -f "${SCRIPT_DIR}/bootstrap/00-gitops-operator.yaml"

log "waiting for the openshift-gitops ArgoCD instance to be ready (up to 10 min)"
for _ in $(seq 1 60); do
  if oc -n openshift-gitops get deploy openshift-gitops-server >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
oc -n openshift-gitops rollout status deploy/openshift-gitops-server --timeout=300s \
  || die "openshift-gitops-server did not become Available"

log "granting cluster-admin to the Argo CD application controller"
oc apply -f "${SCRIPT_DIR}/bootstrap/10-argocd-rbac.yaml"

log "patching ArgoCD CR with --load-restrictor=LoadRestrictionsNone (kustomize overlays need this)"
oc apply -f "${SCRIPT_DIR}/bootstrap/15-argocd-config.yaml"
oc -n openshift-gitops rollout status deploy/openshift-gitops-repo-server --timeout=180s \
  || die "openshift-gitops-repo-server did not restart after config patch"

log "rendering root Application (REPO_URL=${REPO_URL}, TARGET_REVISION=${TARGET_REVISION}, OVERLAY=${OVERLAY})"
export REPO_URL TARGET_REVISION OVERLAY
envsubst < "${SCRIPT_DIR}/bootstrap/20-root-application.yaml" | oc apply -f -

log "root Application applied. Track progress with:"
log "  oc -n openshift-gitops get applications.argoproj.io"
log "  oc -n openshift-gitops get applications.argoproj.io rhoai-2254-root -o yaml"
log "Argo CD UI:"
log "  oc -n openshift-gitops get route openshift-gitops-server -o jsonpath='https://{.spec.host}{\"\\n\"}'"
