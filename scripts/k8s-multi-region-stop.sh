#!/usr/bin/env bash
# =============================================================================
# InferaDB Multi-Region Test Environment Teardown
# =============================================================================
# Removes the kind clusters created by k8s-multi-region-start.sh
#
# Usage:
#   ./tests/scripts/k8s-multi-region-stop.sh
#
# Environment Variables:
#   CLUSTER_PREFIX - Prefix for cluster names (default: inferadb-mr)

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_PREFIX="${CLUSTER_PREFIX:-inferadb-mr}"
PRIMARY_CLUSTER="${CLUSTER_PREFIX}-primary"
DR_CLUSTER="${CLUSTER_PREFIX}-dr"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

delete_cluster() {
    local cluster_name="$1"

    if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
        log_info "Deleting kind cluster: ${cluster_name}"
        kind delete cluster --name "${cluster_name}"
        log_info "Cluster '${cluster_name}' deleted"
    else
        log_warn "Cluster '${cluster_name}' does not exist, skipping"
    fi
}

main() {
    log_info "Stopping InferaDB Multi-Region Test Environment"

    delete_cluster "${PRIMARY_CLUSTER}"
    delete_cluster "${DR_CLUSTER}"

    log_info "Multi-region test environment stopped"
}

main "$@"
