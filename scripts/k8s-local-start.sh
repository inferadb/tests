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
DASHBOARD_IMAGE="${DASHBOARD_IMAGE:-inferadb-dashboard:local}"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

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

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: brew install ${missing[*]}"
        exit 1
    fi

    if ! docker ps &> /dev/null; then
        log_error "Docker is not running. Please start Docker Desktop."
        exit 1
    fi

    log_info "All prerequisites satisfied ✓"
}

create_cluster() {
    if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
        log_warn "Cluster '${CLUSTER_NAME}' already exists. Skipping creation."
        return 0
    fi

    log_info "Creating kind cluster '${CLUSTER_NAME}'..."

    cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8080
    protocol: TCP
  - containerPort: 30090
    hostPort: 9090
    protocol: TCP
  - containerPort: 30091
    hostPort: 9091
    protocol: TCP
  - containerPort: 30030
    hostPort: 3030
    protocol: TCP
- role: worker
- role: worker
EOF

    log_info "Cluster created ✓"
    kubectl cluster-info --context "kind-${CLUSTER_NAME}"
}

build_images() {
    log_info "Building Docker images..."

    # Determine the repo root (parent of tests directory)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root
    repo_root="$(cd "${script_dir}/../.." && pwd)"

    # Build engine
    log_info "Building engine image..."
    docker build -t "${SERVER_IMAGE}" "${repo_root}/engine/" || {
        log_error "Failed to build engine image"
        exit 1
    }

    # Build control
    log_info "Building control image..."
    docker build -f "${repo_root}/control/Dockerfile.integration" -t "${CONTROL_IMAGE}" "${repo_root}/control/" || {
        log_error "Failed to build control image"
        exit 1
    }

    # Build dashboard
    log_info "Building dashboard image..."
    docker build -t "${DASHBOARD_IMAGE}" "${repo_root}/dashboard/" || {
        log_error "Failed to build dashboard image"
        exit 1
    }

    log_info "Images built ✓"
}

load_images() {
    log_info "Loading images into kind cluster..."

    kind load docker-image "${SERVER_IMAGE}" --name "${CLUSTER_NAME}"
    kind load docker-image "${CONTROL_IMAGE}" --name "${CLUSTER_NAME}"
    kind load docker-image "${DASHBOARD_IMAGE}" --name "${CLUSTER_NAME}"

    log_info "Images loaded ✓"
}

create_namespace() {
    log_info "Creating namespace '${NAMESPACE}'..."

    kubectl create namespace "${NAMESPACE}" 2>/dev/null || true
    kubectl config set-context --current --namespace="${NAMESPACE}"

    log_info "Namespace ready ✓"
}

deploy_rbac() {
    log_info "Deploying RBAC resources..."

    # Determine the repo root (parent of tests directory)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local repo_root
    repo_root="$(cd "${script_dir}/../.." && pwd)"

    kubectl apply -f "${repo_root}/engine/k8s/rbac.yaml" -n "${NAMESPACE}"
    kubectl apply -f "${repo_root}/control/k8s/rbac.yaml" -n "${NAMESPACE}"

    log_info "RBAC deployed ✓"
}

deploy_foundationdb() {
    log_info "Deploying FoundationDB..."

    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: foundationdb-cluster-file
  namespace: ${NAMESPACE}
data:
  fdb.cluster: "docker:docker@foundationdb-0.foundationdb:4500"
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: foundationdb
  namespace: ${NAMESPACE}
spec:
  serviceName: foundationdb
  replicas: 1
  selector:
    matchLabels:
      app: foundationdb
  template:
    metadata:
      labels:
        app: foundationdb
    spec:
      containers:
      - name: foundationdb
        image: foundationdb/foundationdb:7.3.69
        ports:
        - containerPort: 4500
        env:
        - name: FDB_NETWORKING_MODE
          value: container
        volumeMounts:
        - name: data
          mountPath: /var/fdb/data
        - name: logs
          mountPath: /var/fdb/logs
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
  - metadata:
      name: logs
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: foundationdb
  namespace: ${NAMESPACE}
spec:
  clusterIP: None
  sessionAffinity: None
  selector:
    app: foundationdb
  ports:
  - port: 4500
    targetPort: 4500
---
apiVersion: v1
kind: Service
metadata:
  name: foundationdb-cluster
  namespace: ${NAMESPACE}
spec:
  selector:
    app: foundationdb
  ports:
  - port: 4500
    targetPort: 4500
EOF

    log_info "Waiting for FoundationDB pod to be ready..."
    kubectl wait --for=condition=ready pod -l app=foundationdb -n "${NAMESPACE}" --timeout=120s

    log_info "FoundationDB pod deployed ✓"
}

initialize_foundationdb() {
    log_info "Initializing FoundationDB cluster..."

    # Get the FDB pod name
    local fdb_pod
    fdb_pod=$(kubectl get pods -l app=foundationdb -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')

    if [ -z "$fdb_pod" ]; then
        log_error "FoundationDB pod not found"
        return 1
    fi

    # Wait for FDB server to be responsive (it takes a moment after pod is ready)
    log_info "Waiting for FDB server to be responsive..."
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if kubectl exec -n "${NAMESPACE}" "$fdb_pod" -- fdbcli --exec "status minimal" 2>/dev/null | grep -q "The database is"; then
            log_info "FDB server is responsive"
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    if [ $attempt -eq $max_attempts ]; then
        log_warn "FDB still not fully responsive, attempting configuration anyway..."
    fi

    # Check if database is already configured
    local status
    status=$(kubectl exec -n "${NAMESPACE}" "$fdb_pod" -- fdbcli --exec "status minimal" 2>/dev/null || true)

    if echo "$status" | grep -q "The database is available"; then
        log_info "FDB cluster already configured and available ✓"
        return 0
    fi

    # Initialize cluster with single SSD configuration (or memory for faster tests)
    log_info "Configuring FDB cluster (new single ssd)..."
    if kubectl exec -n "${NAMESPACE}" "$fdb_pod" -- fdbcli --exec "configure new single ssd" 2>/dev/null; then
        log_info "FDB cluster configured successfully"
    else
        # If configure fails, it might already be configured - check status
        local recheck_status
        recheck_status=$(kubectl exec -n "${NAMESPACE}" "$fdb_pod" -- fdbcli --exec "status minimal" 2>/dev/null || true)
        if echo "$recheck_status" | grep -q "The database is available"; then
            log_info "FDB cluster already configured ✓"
        else
            log_warn "FDB configuration may have failed, but proceeding..."
        fi
    fi

    # Wait for cluster to become available
    log_info "Waiting for FDB cluster to become available..."
    local init_max_attempts=30
    local init_attempt=0

    while [ $init_attempt -lt $init_max_attempts ]; do
        local cluster_status
        cluster_status=$(kubectl exec -n "${NAMESPACE}" "$fdb_pod" -- fdbcli --exec "status minimal" 2>/dev/null || true)

        if echo "$cluster_status" | grep -q "The database is available"; then
            log_info "FDB cluster is available ✓"
            return 0
        fi
        init_attempt=$((init_attempt + 1))
        sleep 2
    done

    log_warn "FDB cluster availability check timed out, but proceeding..."
    return 0
}

deploy_mailpit() {
    log_info "Deploying Mailpit (email catcher for testing)..."

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mailpit
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mailpit
  template:
    metadata:
      labels:
        app: mailpit
    spec:
      containers:
      - name: mailpit
        image: axllent/mailpit:latest
        ports:
        - containerPort: 1025
          name: smtp
        - containerPort: 8025
          name: http
---
apiVersion: v1
kind: Service
metadata:
  name: mailpit
  namespace: ${NAMESPACE}
spec:
  selector:
    app: mailpit
  ports:
  - name: smtp
    port: 1025
    targetPort: 1025
  - name: http
    port: 8025
    targetPort: 8025
    nodePort: 30025
  type: NodePort
EOF

    log_info "Waiting for Mailpit to be ready..."
    kubectl wait --for=condition=available deployment/mailpit -n "${NAMESPACE}" --timeout=60s

    log_info "Mailpit deployed ✓"
    log_info "  - SMTP: mailpit:1025 (internal)"
    log_info "  - Web UI: http://localhost:30025"
}

deploy_control() {
    log_info "Deploying Control..."

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
        # Listen configuration (control section)
        - name: INFERADB__CONTROL__LISTEN__HTTP
          value: "0.0.0.0:9090"
        - name: INFERADB__CONTROL__LISTEN__GRPC
          value: "0.0.0.0:9091"
        - name: INFERADB__CONTROL__LISTEN__MESH
          value: "0.0.0.0:9092"
        # Storage configuration
        - name: INFERADB__CONTROL__STORAGE
          value: "foundationdb"
        - name: INFERADB__CONTROL__FOUNDATIONDB__CLUSTER_FILE
          value: "/var/fdb/fdb.cluster"
        # Mesh configuration (how control connects to engine)
        - name: INFERADB__CONTROL__MESH__URL
          value: "http://inferadb-engine"
        - name: INFERADB__CONTROL__MESH__GRPC
          value: "8080"
        - name: INFERADB__CONTROL__MESH__PORT
          value: "8082"
        # Service discovery
        - name: INFERADB__CONTROL__DISCOVERY__MODE__TYPE
          value: "kubernetes"
        - name: INFERADB__CONTROL__DISCOVERY__CACHE_TTL
          value: "30"
        - name: KUBERNETES_NAMESPACE
          value: "${NAMESPACE}"
        # Audience for engine-to-control JWT auth (must match engine's MESH__URL)
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
        # Health probes (Kubernetes conventions: /livez, /readyz, /startupz)
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
---
apiVersion: v1
kind: Service
metadata:
  name: inferadb-control
  namespace: ${NAMESPACE}
spec:
  selector:
    app: inferadb-control
  ports:
  - name: public
    port: 9090
    targetPort: 9090
    nodePort: 30090
  - name: internal
    port: 9092
    targetPort: 9092
    nodePort: 30092
  type: NodePort
EOF

    log_info "Waiting for Control to be ready..."
    kubectl wait --for=condition=available deployment/inferadb-control -n "${NAMESPACE}" --timeout=120s

    log_info "Control deployed ✓"
}

deploy_engine() {
    log_info "Deploying Engine..."

    # Create engine identity secret if it doesn't exist
    if ! kubectl get secret inferadb-engine-identity -n "${NAMESPACE}" &>/dev/null; then
        log_info "Creating engine identity secret..."
        kubectl create secret generic inferadb-engine-identity -n "${NAMESPACE}" \
            --from-literal=server-identity.pem="-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEICBavKgCnA54kjkPsUVqz4K2or443E+EOQVU/yDZUWz3
-----END PRIVATE KEY-----"
    fi

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
        # Listen configuration (engine section)
        - name: INFERADB__ENGINE__LISTEN__HTTP
          value: "0.0.0.0:8080"
        - name: INFERADB__ENGINE__LISTEN__GRPC
          value: "0.0.0.0:8081"
        - name: INFERADB__ENGINE__LISTEN__MESH
          value: "0.0.0.0:8082"
        # Storage configuration
        - name: INFERADB__ENGINE__STORAGE
          value: "foundationdb"
        - name: INFERADB__ENGINE__FOUNDATIONDB__CLUSTER_FILE
          value: "/var/fdb/fdb.cluster"
        # Mesh configuration (how engine connects to control)
        - name: INFERADB__ENGINE__MESH__URL
          value: "http://inferadb-control:9092"
        # Service discovery configuration
        - name: INFERADB__ENGINE__DISCOVERY__MODE__TYPE
          value: "kubernetes"
        - name: INFERADB__ENGINE__DISCOVERY__CACHE_TTL
          value: "30"
        - name: KUBERNETES_NAMESPACE
          value: "${NAMESPACE}"
        # Server identity for signing requests to control
        - name: INFERADB__ENGINE__PEM
          valueFrom:
            secretKeyRef:
              name: inferadb-engine-identity
              key: server-identity.pem
        volumeMounts:
        - name: fdb-cluster-file
          mountPath: /var/fdb
          readOnly: true
        # Health probes (Kubernetes conventions: /livez, /readyz, /startupz)
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
---
apiVersion: v1
kind: Service
metadata:
  name: inferadb-engine
  namespace: ${NAMESPACE}
spec:
  selector:
    app: inferadb-engine
  ports:
  - name: public
    port: 8080
    targetPort: 8080
    nodePort: 30080
  - name: grpc
    port: 8081
    targetPort: 8081
    nodePort: 30081
  - name: internal
    port: 8082
    targetPort: 8082
    nodePort: 30082
  type: NodePort
EOF

    log_info "Waiting for Engine to be ready..."
    kubectl wait --for=condition=available deployment/inferadb-engine -n "${NAMESPACE}" --timeout=120s

    log_info "Engine deployed ✓"
}

deploy_dashboard() {
    log_info "Deploying Dashboard..."

    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inferadb-dashboard
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: inferadb-dashboard
  template:
    metadata:
      labels:
        app: inferadb-dashboard
    spec:
      containers:
      - name: dashboard
        image: ${DASHBOARD_IMAGE}
        imagePullPolicy: Never
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: NODE_ENV
          value: "production"
        - name: HOST
          value: "0.0.0.0"
        - name: PORT
          value: "3000"
        # Control API URL - within the K8s cluster
        - name: CONTROL_API_URL
          value: "http://inferadb-control:9090"
        livenessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 5
          timeoutSeconds: 3
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: inferadb-dashboard
  namespace: ${NAMESPACE}
spec:
  selector:
    app: inferadb-dashboard
  ports:
  - name: http
    port: 3000
    targetPort: 3000
    nodePort: 30030
  type: NodePort
EOF

    log_info "Waiting for Dashboard to be ready..."
    kubectl wait --for=condition=available deployment/inferadb-dashboard -n "${NAMESPACE}" --timeout=120s

    log_info "Dashboard deployed ✓"
}

show_status() {
    log_info "Deployment Status:"
    echo ""
    kubectl get pods -n "${NAMESPACE}"
    echo ""
    kubectl get svc -n "${NAMESPACE}"
    echo ""

    log_info "Access URLs:"
    echo "  Dashboard: http://localhost:3030"
    echo "  Engine:    http://localhost:8080"
    echo "  Control:   http://localhost:9090"
    echo "  Mailpit:   http://localhost:30025 (email web UI)"
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
    log_info "Starting InferaDB local Kubernetes cluster..."

    check_prerequisites
    create_cluster
    build_images
    load_images
    create_namespace
    deploy_rbac
    deploy_foundationdb
    initialize_foundationdb
    deploy_mailpit
    deploy_control
    deploy_engine
    deploy_dashboard

    log_info "Setup complete! 🎉"
    echo ""
    show_status
}

# Run main function
main "$@"
