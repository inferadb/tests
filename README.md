# InferaDB Integration Tests

**End-to-end integration tests for InferaDB, validating the full stack in Kubernetes.**

This repository contains comprehensive integration tests that verify InferaDB Server and Management API work correctly together in a production-like environment.

## What's Tested

| Category                   | Tests | Coverage                                                     |
| -------------------------- | ----- | ------------------------------------------------------------ |
| **Authentication**         | 7     | JWT validation, Ed25519 signatures, token expiration, scopes |
| **Vault Isolation**        | 4     | Multi-tenant separation, cross-vault access prevention       |
| **Cache Behavior**         | 4     | Hit/miss patterns, expiration, concurrent load               |
| **Concurrency**            | 5     | Parallel requests, race conditions, connection handling      |
| **E2E Workflows**          | 2     | User journeys from registration to authorization             |
| **Management Integration** | 5     | Org suspension, client deactivation, certificate rotation    |
| **Resilience**             | 6     | Service recovery, graceful degradation, error propagation    |
| **Total**                  | 33    | Across 8 modules                                             |

## Quick Start

### Prerequisites

- Docker Desktop with Kubernetes enabled
- Rust 1.78+
- `kubectl` configured for local cluster

### Run Tests

```bash
# Start local Kubernetes environment
./scripts/k8s-local-start.sh

# Run all integration tests
./scripts/k8s-local-run-integration-tests.sh

# Stop environment when done
./scripts/k8s-local-stop.sh
```

### Manual Test Execution

```bash
# With services already running
cargo test --test integration

# Run specific test suite
cargo test --test integration auth_jwt
cargo test --test integration vault_isolation
cargo test --test integration cache
```

## Project Structure

```text
tests/
├── integration/           # Test suites
│   ├── mod.rs             # Test harness and shared utilities
│   ├── auth_jwt_tests.rs  # JWT authentication tests
│   ├── cache_tests.rs     # Caching behavior tests
│   ├── concurrency_tests.rs
│   ├── e2e_workflows_tests.rs
│   ├── management_integration_tests.rs
│   ├── resilience_tests.rs
│   └── vault_isolation_tests.rs
├── scripts/               # Kubernetes automation
│   ├── k8s-local-start.sh
│   ├── k8s-local-stop.sh
│   ├── k8s-local-status.sh
│   ├── k8s-local-update.sh
│   ├── k8s-local-purge.sh
│   └── k8s-local-run-integration-tests.sh
├── Cargo.toml
├── Dockerfile.integration
└── docker-compose.integration.yml
```

## Scripts Reference

| Script                               | Description                               |
| ------------------------------------ | ----------------------------------------- |
| `k8s-local-start.sh`                 | Deploy InferaDB stack to local Kubernetes |
| `k8s-local-stop.sh`                  | Stop services, preserve data              |
| `k8s-local-purge.sh`                 | Remove all resources and data             |
| `k8s-local-status.sh`                | Check deployment health                   |
| `k8s-local-update.sh`                | Rebuild and redeploy images               |
| `k8s-local-run-integration-tests.sh` | Execute full test suite                   |

## Test Environment

Tests run against services deployed in the `inferadb` namespace:

| Service            | URL                     | Description               |
| ------------------ | ----------------------- | ------------------------- |
| Server API         | `http://localhost:8080` | Authorization endpoints   |
| Management API     | `http://localhost:8081` | Tenant/vault management   |
| Metrics (internal) | `http://localhost:9090` | Prometheus metrics        |
| FoundationDB       | Internal                | Cluster storage (no port) |

### Environment Variables

The test harness respects these environment variables:

| Variable             | Default                 | Description              |
| -------------------- | ----------------------- | ------------------------ |
| `SERVER_API_URL`     | `http://localhost:8080` | InferaDB Server endpoint |
| `MANAGEMENT_API_URL` | `http://localhost:8081` | Management API endpoint  |
| `TEST_TIMEOUT_SECS`  | `30`                    | Per-test timeout         |

The test harness automatically handles:

- JWT token generation with Ed25519 signing
- User registration and session management
- Vault creation and access grants
- Cleanup between test runs

## Writing Tests

Tests use the shared harness in `integration/mod.rs`:

```rust
use crate::{TestContext, create_test_user, create_test_vault};

#[tokio::test]
async fn test_my_feature() -> anyhow::Result<()> {
    let ctx = TestContext::new().await?;

    // Create test fixtures
    let user = create_test_user(&ctx).await?;
    let vault = create_test_vault(&ctx, &user).await?;

    // Test your feature
    let token = ctx.generate_vault_jwt(&vault).await?;
    let response = ctx.server_client()
        .post("/v1/evaluate")
        .bearer_auth(&token)
        .json(&request)
        .send()
        .await?;

    assert_eq!(response.status(), 200);
    Ok(())
}
```

## CI/CD Integration

These tests run in GitHub Actions on every PR:

```yaml
- name: Run Integration Tests
  run: |
    ./scripts/k8s-local-start.sh
    ./scripts/k8s-local-run-integration-tests.sh
```

## Troubleshooting

### Services Not Starting

```bash
# Check pod status
kubectl get pods -n inferadb

# View logs for a specific service
kubectl logs -n inferadb deployment/inferadb-server
kubectl logs -n inferadb deployment/inferadb-management-api
```

### Port Already in Use

```bash
# Find and kill processes using test ports
lsof -i :8080 -i :8081 -i :9090 | grep LISTEN
kill -9 <PID>

# Or purge and restart
./scripts/k8s-local-purge.sh
./scripts/k8s-local-start.sh
```

### Tests Timing Out

1. Verify services are healthy: `./scripts/k8s-local-status.sh`
2. Increase timeout: `TEST_TIMEOUT_SECS=60 cargo test --test integration`
3. Check resource limits in Docker Desktop (recommend 4GB+ RAM)

### Connection Refused Errors

Ensure port-forwarding is active:

```bash
# Check existing port-forwards
kubectl get pods -n inferadb -o wide

# Restart port-forwarding (handled by start script)
./scripts/k8s-local-start.sh
```

## Related Documentation

- [Server Documentation](https://github.com/inferadb/server)
- [Management API Documentation](https://github.com/inferadb/management)
- [InferaDB Meta-Repository](https://github.com/inferadb/inferadb)

## License

Apache License 2.0 - See [LICENSE](LICENSE)
