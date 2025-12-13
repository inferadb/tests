#!/usr/bin/env bash
# =============================================================================
# InferaDB Multi-Region Test Environment Setup
# =============================================================================
# Creates two kind clusters to simulate multi-region deployment for testing
#
# Usage:
#   ./tests/scripts/k8s-multi-region-start.sh
#
# Environment Variables:
#   CLUSTER_PREFIX - Prefix for cluster names (default: inferadb-mr)
#   FDB_VERSION    - FoundationDB version (default: 7.3.43)
#   SKIP_BUILD     - Skip Docker image build if set to "true"

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_PREFIX="${CLUSTER_PREFIX:-inferadb-mr}"
PRIMARY_CLUSTER="${CLUSTER_PREFIX}-primary"
DR_CLUSTER="${CLUSTER_PREFIX}-dr"
FDB_VERSION="${FDB_VERSION:-7.3.43}"
SKIP_BUILD="${SKIP_BUILD:-false}"
NAMESPACE="inferadb"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "${BLUE}[SECTION]${NC} $1"
}

check_prerequisites() {
    log_section "Checking prerequisites..."

    local missing=()

    if ! command -v kind &> /dev/null; then
        missing+=("kind")
    fi

    if ! command -v kubectl &> /dev/null; then
        missing+=("kubectl")
    fi

    if ! command -v docker &> /dev/null; then
        missing+=("docker")
    fi

    if ! command -v helm &> /dev/null; then
        missing+=("helm")
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_error "Please install them before running this script."
        exit 1
    fi

    # Check Docker is running
    if ! docker info &> /dev/null; then
        log_error "Docker is not running. Please start Docker."
        exit 1
    fi

    log_info "All prerequisites satisfied"
}

create_cluster() {
    local cluster_name="$1"
    local region_label="$2"
    local api_port="$3"

    log_info "Creating kind cluster: ${cluster_name}"

    if kind get clusters 2>/dev/null | grep -q "^${cluster_name}$"; then
        log_warn "Cluster '${cluster_name}' already exists. Skipping creation."
        return 0
    fi

    cat <<EOF | kind create cluster --name "${cluster_name}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/region=${region_label}"
    extraPortMappings:
      - containerPort: 30080
        hostPort: ${api_port}
        protocol: TCP
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/region=${region_label},workload=general"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/region=${region_label},workload=fdb"
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "topology.kubernetes.io/region=${region_label},workload=fdb"
networking:
  podSubnet: "10.${api_port: -1}0.0.0/16"
  serviceSubnet: "10.${api_port: -1}1.0.0/16"
EOF

    log_info "Cluster '${cluster_name}' created successfully"
}

build_images() {
    if [ "${SKIP_BUILD}" = "true" ]; then
        log_info "Skipping image build (SKIP_BUILD=true)"
        return 0
    fi

    log_section "Building Docker images..."

    # Build engine image
    if [ -f "${PROJECT_ROOT}/engine/Dockerfile" ]; then
        log_info "Building inferadb-engine:local..."
        docker build -t inferadb-engine:local "${PROJECT_ROOT}/engine" || {
            log_warn "Engine build failed, continuing with existing image if available"
        }
    fi

    # Build control image
    if [ -f "${PROJECT_ROOT}/control/Dockerfile" ]; then
        log_info "Building inferadb-control:local..."
        docker build -t inferadb-control:local "${PROJECT_ROOT}/control" || {
            log_warn "Control build failed, continuing with existing image if available"
        }
    fi
}

load_images() {
    local cluster_name="$1"

    log_info "Loading images into cluster: ${cluster_name}"

    # Load images if they exist
    if docker image inspect inferadb-engine:local &> /dev/null; then
        kind load docker-image inferadb-engine:local --name "${cluster_name}"
    fi

    if docker image inspect inferadb-control:local &> /dev/null; then
        kind load docker-image inferadb-control:local --name "${cluster_name}"
    fi
}

install_fdb_operator() {
    local cluster_name="$1"
    local context="kind-${cluster_name}"

    log_info "Installing FDB Kubernetes Operator in ${cluster_name}..."

    # Add FDB Helm repo
    helm repo add fdb https://foundationdb.github.io/fdb-kubernetes-operator/ 2>/dev/null || true
    helm repo update fdb

    # Create namespace
    kubectl --context="${context}" create namespace fdb-system 2>/dev/null || true

    # Install operator
    helm upgrade --install fdb-operator fdb/fdb-kubernetes-operator \
        --namespace fdb-system \
        --kube-context="${context}" \
        --set image.tag=v1.38.0 \
        --wait \
        --timeout 5m

    log_info "FDB Operator installed in ${cluster_name}"
}

create_namespace() {
    local cluster_name="$1"
    local context="kind-${cluster_name}"

    log_info "Creating namespace '${NAMESPACE}' in ${cluster_name}..."
    kubectl --context="${context}" create namespace "${NAMESPACE}" 2>/dev/null || true
}

deploy_fdb_cluster() {
    local cluster_name="$1"
    local context="kind-${cluster_name}"
    local is_primary="$2"
    local region_id="$3"

    log_info "Deploying FDB cluster in ${cluster_name} (primary=${is_primary})..."

    local priority=2
    if [ "${is_primary}" = "true" ]; then
        priority=1
    fi

    # Create FDB cluster manifest
    cat <<EOF | kubectl --context="${context}" apply -f -
apiVersion: apps.foundationdb.org/v1beta2
kind: FoundationDBCluster
metadata:
  name: inferadb-fdb
  namespace: ${NAMESPACE}
spec:
  version: ${FDB_VERSION}

  databaseConfiguration:
    redundancy_mode: double
    storage_engine: ssd-2

  processCounts:
    storage: 2
    log: 2
    stateless: 2

  processes:
    general:
      podTemplate:
        spec:
          containers:
            - name: foundationdb
              resources:
                requests:
                  memory: 512Mi
                  cpu: 250m
                limits:
                  memory: 1Gi
                  cpu: 500m

  routing:
    defineDNSLocalityFields: true

  labels:
    "topology.kubernetes.io/region": "${region_id}"
EOF

    log_info "FDB cluster manifest applied in ${cluster_name}"
}

wait_for_fdb() {
    local cluster_name="$1"
    local context="kind-${cluster_name}"
    local timeout=300
    local interval=10
    local elapsed=0

    log_info "Waiting for FDB cluster to be ready in ${cluster_name}..."

    while [ $elapsed -lt $timeout ]; do
        local status
        status=$(kubectl --context="${context}" get fdb inferadb-fdb -n "${NAMESPACE}" -o jsonpath='{.status.generations.reconciled}' 2>/dev/null || echo "0")
        local desired
        desired=$(kubectl --context="${context}" get fdb inferadb-fdb -n "${NAMESPACE}" -o jsonpath='{.metadata.generation}' 2>/dev/null || echo "1")

        if [ "${status}" = "${desired}" ] && [ "${status}" != "0" ]; then
            log_info "FDB cluster is ready in ${cluster_name}"
            return 0
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
        echo -n "."
    done

    echo ""
    log_warn "FDB cluster may not be fully ready in ${cluster_name} (timeout after ${timeout}s)"
}

deploy_inferadb() {
    local cluster_name="$1"
    local context="kind-${cluster_name}"
    local is_primary="$2"

    log_info "Deploying InferaDB Engine in ${cluster_name}..."

    # Get FDB cluster file from the cluster
    local cluster_file
    cluster_file=$(kubectl --context="${context}" get secret inferadb-fdb-config -n "${NAMESPACE}" -o jsonpath='{.data.cluster-file}' 2>/dev/null | base64 -d || echo "")

    if [ -z "${cluster_file}" ]; then
        log_warn "Could not get FDB cluster file, using placeholder"
        cluster_file="inferadb:inferadb@127.0.0.1:4500"
    fi

    # Deploy Engine
    cat <<EOF | kubectl --context="${context}" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inferadb-engine
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: inferadb-engine
  template:
    metadata:
      labels:
        app.kubernetes.io/name: inferadb-engine
    spec:
      containers:
        - name: engine
          image: inferadb-engine:local
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
              name: http
            - containerPort: 8081
              name: grpc
          env:
            - name: INFERADB__HTTP_PORT
              value: "8080"
            - name: INFERADB__GRPC_PORT
              value: "8081"
            - name: INFERADB__STORE__TYPE
              value: "foundationdb"
            - name: INFERADB__FOUNDATIONDB__CLUSTER_FILE
              value: "/etc/fdb/fdb.cluster"
          volumeMounts:
            - name: fdb-config
              mountPath: /etc/fdb
              readOnly: true
          resources:
            requests:
              memory: 256Mi
              cpu: 100m
            limits:
              memory: 512Mi
              cpu: 500m
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 30
      volumes:
        - name: fdb-config
          secret:
            secretName: inferadb-fdb-config
---
apiVersion: v1
kind: Service
metadata:
  name: inferadb-engine
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: inferadb-engine
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      nodePort: 30080
    - name: grpc
      port: 8081
      targetPort: 8081
EOF

    log_info "InferaDB Engine deployed in ${cluster_name}"
}

print_summary() {
    log_section "Multi-Region Test Environment Ready"

    echo ""
    echo "Clusters:"
    echo "  Primary: ${PRIMARY_CLUSTER}"
    echo "  DR:      ${DR_CLUSTER}"
    echo ""
    echo "Contexts:"
    echo "  Primary: kind-${PRIMARY_CLUSTER}"
    echo "  DR:      kind-${DR_CLUSTER}"
    echo ""
    echo "Access Engine API:"
    echo "  Primary: http://localhost:30080"
    echo "  DR:      http://localhost:30081"
    echo ""
    echo "Switch contexts:"
    echo "  kubectl config use-context kind-${PRIMARY_CLUSTER}"
    echo "  kubectl config use-context kind-${DR_CLUSTER}"
    echo ""
    echo "Check FDB status:"
    echo "  kubectl exec -it inferadb-fdb-storage-0 -n inferadb -c foundationdb -- fdbcli --exec 'status'"
    echo ""
    echo "Cleanup:"
    echo "  ./tests/scripts/k8s-multi-region-stop.sh"
    echo ""
}

main() {
    log_section "Starting InferaDB Multi-Region Test Environment"

    check_prerequisites

    # Create clusters
    create_cluster "${PRIMARY_CLUSTER}" "us-west-1" 30080
    create_cluster "${DR_CLUSTER}" "eu-central-1" 30081

    # Build and load images
    build_images
    load_images "${PRIMARY_CLUSTER}"
    load_images "${DR_CLUSTER}"

    # Install FDB Operator in both clusters
    install_fdb_operator "${PRIMARY_CLUSTER}"
    install_fdb_operator "${DR_CLUSTER}"

    # Create namespaces
    create_namespace "${PRIMARY_CLUSTER}"
    create_namespace "${DR_CLUSTER}"

    # Deploy FDB clusters
    deploy_fdb_cluster "${PRIMARY_CLUSTER}" "true" "us-west-1"
    deploy_fdb_cluster "${DR_CLUSTER}" "false" "eu-central-1"

    # Wait for FDB to be ready
    wait_for_fdb "${PRIMARY_CLUSTER}"
    wait_for_fdb "${DR_CLUSTER}"

    # Deploy InferaDB
    deploy_inferadb "${PRIMARY_CLUSTER}" "true"
    deploy_inferadb "${DR_CLUSTER}" "false"

    print_summary
}

main "$@"
