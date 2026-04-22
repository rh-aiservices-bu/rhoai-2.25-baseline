#!/usr/bin/env bash
# §2.3 Model Registry + Catalog — creates a ModelRegistry CR in rhoai-model-registries.
# The registriesNamespace is set by the DSC (rhoai-model-registries); the operator creates
# the model-catalog pod automatically. The dashboard also needs a data connection to see
# the registry in the UI — create that manually or let the sample exercise the "pre-upgrade
# verification" path.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

# rhoai-model-registries namespace is created by the operator when modelregistry component is Managed
for _ in 1 2 3 4 5 6; do
  if oc get ns rhoai-model-registries >/dev/null 2>&1; then
    break
  fi
  sleep 10
done
oc get ns rhoai-model-registries >/dev/null 2>&1 \
  || die "rhoai-model-registries namespace did not appear; is modelregistry component Managed and Ready?"

wait_for_crd modelregistries.modelregistry.opendatahub.io 600
apply_manifest "${SCRIPT_DIR}/registry.yaml"
log "model-registry: ModelRegistry applied"
log "  note: a MySQL/MariaDB called my-model-registry-db is expected at spec.mysql.host."
log "  supply your own DB or deploy one alongside. The CR exists regardless, so §2.3 verification has input."
