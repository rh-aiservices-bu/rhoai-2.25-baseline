#!/usr/bin/env bash
# §2.4 Feature Store — FeatureStore CR + ingestion CronJob (suspended).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

if ! oc get crd featurestores.feast.dev >/dev/null 2>&1; then
  warn "FeatureStore CRD not present — feastoperator may still be reconciling. Retrying briefly."
  wait_for_crd featurestores.feast.dev 300 || {
    warn "giving up on feast CRD; skipping sample"
    exit 0
  }
fi
apply_manifest "${SCRIPT_DIR}/featurestore.yaml"
log "feast: FeatureStore + CronJob applied"
