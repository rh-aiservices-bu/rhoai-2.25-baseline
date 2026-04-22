#!/usr/bin/env bash
# §2.7 Ray — deploys two RayClusters so the migration's ray_cluster_migration.py pre-upgrade
# script has YAML to back up to /tmp/rhoai-upgrade-backup/ray/Rhoai-2.x/.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/common.sh
source "${SCRIPT_DIR}/../../lib/common.sh"

wait_for_crd rayclusters.ray.io 600
apply_manifest "${SCRIPT_DIR}/raycluster.yaml"
log "ray: RayClusters applied"
