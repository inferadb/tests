#!/usr/bin/env bash
#
# InferaDB E2E Test Runner
#
# This script runs the end-to-end test suite against a Docker Compose stack.
# It handles startup, health checks, test execution, and cleanup.
#
# Usage:
#   ./run-e2e.sh              # Run all E2E tests
#   ./run-e2e.sh --keep       # Keep containers running after tests
#   ./run-e2e.sh --no-build   # Skip building images (use existing)
#   ./run-e2e.sh <test_name>  # Run specific test pattern
#
# Examples:
#   ./run-e2e.sh cache_invalidation
#   ./run-e2e.sh e2e_workflows
#   ./run-e2e.sh --keep vault_isolation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$ROOT_DIR/docker-compose.e2e.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
KEEP_CONTAINERS=false
NO_BUILD=false
TEST_PATTERN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --keep)
      KEEP_CONTAINERS=true
      shift
      ;;
    --no-build)
      NO_BUILD=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS] [TEST_PATTERN]"
      echo ""
      echo "Options:"
      echo "  --keep      Keep containers running after tests"
      echo "  --no-build  Skip building images (use existing)"
      echo "  --help      Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                           Run all E2E tests"
      echo "  $0 cache_invalidation        Run cache invalidation tests"
      echo "  $0 --keep e2e_workflows      Run workflow tests, keep containers"
      exit 0
      ;;
    *)
      TEST_PATTERN="$1"
      shift
      ;;
  esac
done

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
  if [[ "$KEEP_CONTAINERS" == "false" ]]; then
    log_info "Stopping containers..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  else
    log_info "Keeping containers running (use 'docker compose -f $COMPOSE_FILE down -v' to stop)"
  fi
}

# Set up cleanup trap
trap cleanup EXIT

# Check prerequisites
if ! command -v docker &> /dev/null; then
  log_error "Docker is not installed. Please install Docker first."
  exit 1
fi

if ! docker info &> /dev/null; then
  log_error "Docker daemon is not running. Please start Docker."
  exit 1
fi

log_info "Starting InferaDB E2E Test Suite"
echo ""

# Build or pull images
if [[ "$NO_BUILD" == "false" ]]; then
  log_info "Building Docker images..."
  docker compose -f "$COMPOSE_FILE" build
else
  log_info "Skipping image build (--no-build specified)"
fi

# Start services
log_info "Starting services..."
docker compose -f "$COMPOSE_FILE" up -d

# Wait for services to be healthy
log_info "Waiting for services to be healthy..."

TIMEOUT=120
ELAPSED=0

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  LEDGER_HEALTHY=$(docker inspect --format='{{.State.Health.Status}}' inferadb-e2e-ledger 2>/dev/null || echo "unknown")
  CONTROL_HEALTHY=$(docker inspect --format='{{.State.Health.Status}}' inferadb-e2e-control 2>/dev/null || echo "unknown")
  ENGINE_HEALTHY=$(docker inspect --format='{{.State.Health.Status}}' inferadb-e2e-engine 2>/dev/null || echo "unknown")

  if [[ "$LEDGER_HEALTHY" == "healthy" ]] && \
     [[ "$CONTROL_HEALTHY" == "healthy" ]] && \
     [[ "$ENGINE_HEALTHY" == "healthy" ]]; then
    log_success "All services are healthy!"
    break
  fi

  printf "  Ledger: %s | Control: %s | Engine: %s (${ELAPSED}s)\r" \
    "$LEDGER_HEALTHY" "$CONTROL_HEALTHY" "$ENGINE_HEALTHY"
  
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

echo ""

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  log_error "Services did not become healthy within ${TIMEOUT}s"
  log_error "Check logs with: docker compose -f $COMPOSE_FILE logs"
  exit 1
fi

# Set environment variables for tests
export INFERADB_API_URL="http://localhost:9090"
export ENGINE_URL="http://localhost:8080"
export ENGINE_GRPC_URL="http://localhost:8081"
export ENGINE_MESH_URL="http://localhost:8082"
export CONTROL_URL="http://localhost:9090"

# Show service URLs
echo ""
log_info "Service endpoints:"
echo "  - Control API: $CONTROL_URL"
echo "  - Engine HTTP: $ENGINE_URL"
echo "  - Engine gRPC: $ENGINE_GRPC_URL"
echo "  - Ledger gRPC: http://localhost:50051"
echo ""

# Run tests
log_info "Running E2E tests..."
cd "$SCRIPT_DIR"

TEST_CMD="cargo test --test integration"
if [[ -n "$TEST_PATTERN" ]]; then
  TEST_CMD="$TEST_CMD $TEST_PATTERN"
fi
TEST_CMD="$TEST_CMD -- --test-threads=1 --nocapture"

log_info "Executing: $TEST_CMD"
echo ""

set +e
eval "$TEST_CMD"
TEST_EXIT_CODE=$?
set -e

echo ""
if [[ $TEST_EXIT_CODE -eq 0 ]]; then
  log_success "All E2E tests passed!"
else
  log_error "Some E2E tests failed (exit code: $TEST_EXIT_CODE)"
fi

exit $TEST_EXIT_CODE
