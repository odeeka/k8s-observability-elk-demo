#!/usr/bin/env bash
# =============================================================================
#  cleanup.sh  –  Tear down the entire observability demo
#
#  This script:
#    - Deletes the KIND cluster (removes all pods, volumes, and config)
#    - Optionally removes the locally-built Docker images
# =============================================================================
set -euo pipefail

CLUSTER_NAME="observability-demo"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo -e "${RED}╔═══════════════════════════════════════════╗${NC}"
echo -e "${RED}║  Deleting KIND cluster: ${CLUSTER_NAME}  ║${NC}"
echo -e "${RED}╚═══════════════════════════════════════════╝${NC}"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  kind delete cluster --name "${CLUSTER_NAME}"
  info "Cluster '${CLUSTER_NAME}' deleted."
else
  warn "Cluster '${CLUSTER_NAME}' not found – nothing to delete."
fi

# ── Optional: remove locally-built images ─────────────────────────────────────
if [[ "${1:-}" == "--remove-images" ]]; then
  for img in user-service:latest payment-service:latest; do
    if docker image inspect "$img" &>/dev/null; then
      docker rmi "$img"
      info "Removed image: $img"
    fi
  done
fi

info "Cleanup complete."
