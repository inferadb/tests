# InferaDB Integration Tests - Commands

## Prerequisites
- Kubernetes cluster running (Docker Desktop, minikube, etc.)
- kubectl configured

## Setup
```bash
mise trust && mise install    # One-time tool setup
```

## Kubernetes Stack Management
```bash
./scripts/k8s-local-start.sh   # Deploy stack to local K8s
./scripts/k8s-local-stop.sh    # Stop services, preserve data
./scripts/k8s-local-status.sh  # Check deployment health
./scripts/k8s-local-update.sh  # Rebuild and redeploy images
./scripts/k8s-local-purge.sh   # Remove all resources
```

## Testing Commands

```bash
# Run all integration tests
./scripts/k8s-local-run-integration-tests.sh

# Run specific test suite
cargo test --test integration auth_jwt -- --test-threads=1
cargo test --test integration vault_isolation -- --test-threads=1
cargo test --test integration cache -- --test-threads=1
cargo test --test integration concurrency -- --test-threads=1
cargo test --test integration e2e_workflows -- --test-threads=1
cargo test --test integration control_integration -- --test-threads=1
cargo test --test integration resilience -- --test-threads=1

# Run single test with output
cargo test --test integration test_valid_jwt -- --nocapture --exact

# Verbose output
cargo test --test integration -- --nocapture --test-threads=1
```

## Code Quality

```bash
# Format code
cargo +nightly fmt --all

# Lint
cargo clippy --all-targets -- -D warnings

# Security audit
cargo audit

# Dependency checks
cargo deny check
```

## Cleanup

```bash
cargo clean                    # Clean build artifacts
./scripts/k8s-local-purge.sh   # Remove all K8s resources
```

## Environment Override

```bash
# Use custom URLs instead of K8s service discovery
CONTROL_URL=http://localhost:9090 cargo test --test integration
ENGINE_URL=http://localhost:8080 cargo test --test integration
```

## Unix Utilities (Darwin)

```bash
# Standard utilities
git status
ls -la
grep -r "pattern" .
find . -name "*.rs"
kubectl get pods -n inferadb
```
