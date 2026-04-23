#!/usr/bin/env bash
# BYON ImageStream sample — orphan custom notebook ImageStream in redhat-ods-applications.
# Mirrors the leftover-BYON pattern seen on long-lived RHOAI 2.25.4 clusters where dashboard
# users created custom notebook images that persist after their Notebooks were deleted.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

# redhat-ods-applications is created by the RHOAI operator; wait briefly if 20-dsc just finished
for _ in 1 2 3 4 5 6; do
  oc get ns redhat-ods-applications >/dev/null 2>&1 && break
  sleep 5
done
oc get ns redhat-ods-applications >/dev/null 2>&1 \
  || die "redhat-ods-applications namespace not found (did 20-dsc finish?)"

apply_manifest "${SCRIPT_DIR}/imagestream.yaml"
log "byon-imagestream: custom BYON ImageStream applied"
