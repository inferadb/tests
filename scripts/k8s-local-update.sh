#!/usr/bin/env bash
#
# Update InferaDB deployment in existing kind cluster
#
# This script rebuilds Docker images and updates the running deployment
# with new binaries and configuration changes. Use this for rapid iteration
# during development without tearing down the entire cluster.
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-inferadb-local}"
NAMESPACE="${NAMESPACE:-inferadb}"
SERVER_IMAGE="${SERVER_IMAGE:-inferadb-engine:local}"
CONTROL_IMAGE="${CONTROL_IMAGE:-inferadb-control:local}"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_cluster_exists() {
    if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        log_error "Cluster '${CLUSTER_NAME}' does not exist."
        log_info "Create it first with: ./tests/scripts/k8s-local-start.sh"
        exit 1
    fi
    log_info "Cluster '${CLUSTER_NAME}' exists ✓"
}

build_and_load_images() {
    log_info "Building Docker images..."

    # Build engine
    log_info "Building engine image..."
    docker build -t "${SERVER_IMAGE}" engine/ || {
        log_error "Failed to build engine image"
        exit 1
    }

    # Build control
    log_info "Building control image..."
    docker build -f control/Dockerfile.integration -t "${CONTROL_IMAGE}" control/ || {
        log_error "Failed to build control image"
        exit 1
    }

    log_info "Images built ✓"

    log_info "Loading images into kind cluster..."
    kind load docker-image "${SERVER_IMAGE}" --name "${CLUSTER_NAME}"
    kind load docker-image "${CONTROL_IMAGE}" --name "${CLUSTER_NAME}"
    log_info "Images loaded ✓"
}

update_rbac() {
    log_info "Updating RBAC resources..."

    kubectl apply -f engine/k8s/rbac.yaml -n "${NAMESPACE}"
    kubectl apply -f control/k8s/rbac.yaml -n "${NAMESPACE}"

    log_info "RBAC updated ✓"
}

restart_deployments() {
    log_info "Restarting deployments to use new images..."

    # Restart management API
    kubectl rollout restart deployment/inferadb-control -n "${NAMESPACE}"
    log_info "Waiting for Management API rollout..."
    kubectl rollout status deployment/inferadb-control -n "${NAMESPACE}" --timeout=120s

    # Restart server
    kubectl rollout restart deployment/inferadb-engine -n "${NAMESPACE}"
    log_info "Waiting for Server rollout..."
    kubectl rollout status deployment/inferadb-engine -n "${NAMESPACE}" --timeout=120s

    log_info "Deployments restarted ✓"
}

show_status() {
    log_info "Current Deployment Status:"
    echo ""
    kubectl get pods -n "${NAMESPACE}"
    echo ""

    log_info "Recent Server Logs:"
    kubectl logs deployment/inferadb-engine -n "${NAMESPACE}" --tail=10
    echo ""

    log_info "Recent Management API Logs:"
    kubectl logs deployment/inferadb-control -n "${NAMESPACE}" --tail=10
}

main() {
    log_info "Updating InferaDB deployment in local Kubernetes cluster..."

    check_cluster_exists
    build_and_load_images
    update_rbac
    restart_deployments

    log_info "Update complete! 🎉"
    echo ""
    show_status
}

# Run main function
main "$@"
