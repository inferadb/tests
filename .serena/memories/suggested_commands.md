# InferaDB Integration Tests - Commands

## Prerequisites
- InferaDB CLI installed (`inferadb` command available)
- Docker Desktop or compatible container runtime
- Run `inferadb dev doctor` to verify all requirements

## Development Cluster Management

The development cluster is managed via the InferaDB CLI:

```bash
# Check prerequisites
inferadb dev doctor

# Start local Talos cluster
inferadb dev start

# Check cluster status
inferadb dev status

# View cluster logs
inferadb dev logs

# Stop cluster (preserves data)
inferadb dev stop

# Destroy cluster completely
inferadb dev stop --destroy

# Reset all cluster data
inferadb dev reset
```

## Testing Commands

```bash
# Run all integration tests
cargo test --test integration -- --test-threads=1

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
cargo clean                        # Clean build artifacts
inferadb dev stop --destroy        # Remove cluster completely
```

## Environment Override

```bash
# Use custom URLs instead of cluster service discovery
CONTROL_URL=http://localhost:9090 cargo test --test integration
ENGINE_URL=http://localhost:8080 cargo test --test integration
```
