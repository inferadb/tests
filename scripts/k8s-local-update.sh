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

update_deployments() {
    log_info "Updating deployment manifests..."

    # Update Control deployment with latest env vars
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inferadb-control
  namespace: ${NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: inferadb-control
  template:
    metadata:
      labels:
        app: inferadb-control
    spec:
      serviceAccountName: inferadb-control
      containers:
      - name: control-api
        image: ${CONTROL_IMAGE}
        imagePullPolicy: Never
        ports:
        - containerPort: 9090
          name: public
        - containerPort: 9091
          name: grpc
        - containerPort: 9092
          name: internal
        env:
        - name: RUST_LOG
          value: "info,inferadb_control_core=debug,inferadb_discovery=debug"
        - name: INFERADB__CONTROL__LISTEN__HTTP
          value: "0.0.0.0:9090"
        - name: INFERADB__CONTROL__LISTEN__GRPC
          value: "0.0.0.0:9091"
        - name: INFERADB__CONTROL__LISTEN__MESH
          value: "0.0.0.0:9092"
        - name: INFERADB__CONTROL__STORAGE
          value: "foundationdb"
        - name: INFERADB__CONTROL__FOUNDATIONDB__CLUSTER_FILE
          value: "/var/fdb/fdb.cluster"
        - name: INFERADB__CONTROL__MESH__URL
          value: "http://inferadb-engine"
        - name: INFERADB__CONTROL__MESH__GRPC
          value: "8080"
        - name: INFERADB__CONTROL__MESH__PORT
          value: "8082"
        - name: INFERADB__CONTROL__DISCOVERY__MODE__TYPE
          value: "kubernetes"
        - name: INFERADB__CONTROL__DISCOVERY__CACHE_TTL
          value: "30"
        - name: KUBERNETES_NAMESPACE
          value: "${NAMESPACE}"
        - name: CONTROL_API_AUDIENCE
          value: "http://inferadb-control:9092"
        # Email configuration (using Mailpit for testing)
        - name: INFERADB__CONTROL__EMAIL__HOST
          value: "mailpit"
        - name: INFERADB__CONTROL__EMAIL__PORT
          value: "1025"
        - name: INFERADB__CONTROL__EMAIL__ADDRESS
          value: "test@inferadb.local"
        - name: INFERADB__CONTROL__EMAIL__NAME
          value: "InferaDB Test"
        - name: INFERADB__CONTROL__EMAIL__INSECURE
          value: "true"
        volumeMounts:
        - name: fdb-cluster-file
          mountPath: /var/fdb
          readOnly: true
        livenessProbe:
          httpGet:
            path: /livez
            port: 9090
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /readyz
            port: 9090
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
        startupProbe:
          httpGet:
            path: /startupz
            port: 9090
          initialDelaySeconds: 0
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 30
      volumes:
      - name: fdb-cluster-file
        configMap:
          name: foundationdb-cluster-file
          items:
          - key: fdb.cluster
            path: fdb.cluster
EOF

    # Update Engine deployment with latest env vars
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inferadb-engine
  namespace: ${NAMESPACE}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: inferadb-engine
  template:
    metadata:
      labels:
        app: inferadb-engine
    spec:
      serviceAccountName: inferadb-engine
      containers:
      - name: inferadb
        image: ${SERVER_IMAGE}
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
          name: public
        - containerPort: 8081
          name: grpc
        - containerPort: 8082
          name: internal
        env:
        - name: RUST_LOG
          value: "info,inferadb_engine=debug,inferadb_discovery=debug"
        - name: INFERADB__ENGINE__LISTEN__HTTP
          value: "0.0.0.0:8080"
        - name: INFERADB__ENGINE__LISTEN__GRPC
          value: "0.0.0.0:8081"
        - name: INFERADB__ENGINE__LISTEN__MESH
          value: "0.0.0.0:8082"
        - name: INFERADB__ENGINE__STORAGE
          value: "foundationdb"
        - name: INFERADB__ENGINE__FOUNDATIONDB__CLUSTER_FILE
          value: "/var/fdb/fdb.cluster"
        - name: INFERADB__ENGINE__MESH__URL
          value: "http://inferadb-control:9092"
        - name: INFERADB__ENGINE__DISCOVERY__MODE__TYPE
          value: "kubernetes"
        - name: INFERADB__ENGINE__DISCOVERY__CACHE_TTL
          value: "30"
        - name: KUBERNETES_NAMESPACE
          value: "${NAMESPACE}"
        - name: INFERADB__ENGINE__PEM
          valueFrom:
            secretKeyRef:
              name: inferadb-engine-identity
              key: server-identity.pem
        volumeMounts:
        - name: fdb-cluster-file
          mountPath: /var/fdb
          readOnly: true
        livenessProbe:
          httpGet:
            path: /livez
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
        startupProbe:
          httpGet:
            path: /startupz
            port: 8080
          initialDelaySeconds: 0
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 30
      volumes:
      - name: fdb-cluster-file
        configMap:
          name: foundationdb-cluster-file
          items:
          - key: fdb.cluster
            path: fdb.cluster
EOF

    log_info "Deployments updated ✓"
}


show_status() {
    log_info "Current Deployment Status:"
    echo ""
    kubectl get pods -n "${NAMESPACE}"
    echo ""

    log_info "Recent Engine Logs:"
    kubectl logs deployment/inferadb-engine -n "${NAMESPACE}" --tail=10
    echo ""

    log_info "Recent Control Logs:"
    kubectl logs deployment/inferadb-control -n "${NAMESPACE}" --tail=10
}

wait_for_deployments() {
    log_info "Waiting for deployments to be ready..."

    kubectl rollout status deployment/inferadb-control -n "${NAMESPACE}" --timeout=120s
    kubectl rollout status deployment/inferadb-engine -n "${NAMESPACE}" --timeout=120s

    log_info "Deployments ready ✓"
}

main() {
    log_info "Updating InferaDB deployment in local Kubernetes cluster..."

    check_cluster_exists
    build_and_load_images
    update_rbac
    update_deployments
    wait_for_deployments

    log_info "Update complete! 🎉"
    echo ""
    show_status
}

# Run main function
main "$@"
