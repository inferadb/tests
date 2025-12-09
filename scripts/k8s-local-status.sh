#!/usr/bin/env bash
#
# Start local Kubernetes cluster for InferaDB
#
# This script creates a kind cluster and deploys all InferaDB components:
# - FoundationDB
# - Control (with Kubernetes service discovery)
# - Engine (with Kubernetes service discovery)
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

show_status() {
    log_info "Deployment Status:"
    echo ""
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    kubectl get svc -n "${NAMESPACE}"
    echo ""

    log_info "Access URLs:"
    echo "  Engine:   http://localhost:8080"
    echo "  Control:  http://localhost:9090"
    echo ""

    log_info "Useful Commands:"
    echo "  # Watch engine logs (look for discovery messages)"
    echo "  kubectl logs -f deployment/inferadb-engine -n ${NAMESPACE} | grep -i discovery"
    echo ""
    echo "  # Watch control logs"
    echo "  kubectl logs -f deployment/inferadb-control -n ${NAMESPACE} | grep -i discovery"
    echo ""
    echo "  # Scale control and watch engine discover new endpoints"
    echo "  kubectl scale deployment/inferadb-control --replicas=4 -n ${NAMESPACE}"
    echo ""
    echo "  # Update deployment with new changes"
    echo "  ./tests/scripts/k8s-local-update.sh"
    echo ""
    echo "  # Run integration tests"
    echo "  ./tests/scripts/k8s-local-run-integration-tests.sh"
    echo ""
    echo "  # Stop and tear down cluster"
    echo "  ./tests/scripts/k8s-local-stop.sh"
}

main() {
    log_info "Checking status of InferaDB local Kubernetes cluster..."

    echo ""
    show_status
}

# Run main function
main "$@"
