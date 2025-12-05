# InferaDB Integration Tests

**InferaDB end-to-end integration test suite** - validates Server and Management API in Kubernetes environments.

> [!IMPORTANT]
> Under active development. Not production-ready.

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

**Prerequisites:** Docker Desktop with Kubernetes, Rust 1.85+, `kubectl`

```bash
./scripts/k8s-local-start.sh                    # Start K8s environment
./scripts/k8s-local-run-integration-tests.sh    # Run tests
./scripts/k8s-local-stop.sh                     # Stop environment
```

Run specific suites:

```bash
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

## Scripts

| Script                               | Purpose                       |
| ------------------------------------ | ----------------------------- |
| `k8s-local-start.sh`                 | Deploy stack to local K8s     |
| `k8s-local-stop.sh`                  | Stop services, preserve data  |
| `k8s-local-purge.sh`                 | Remove all resources and data |
| `k8s-local-status.sh`                | Check deployment health       |
| `k8s-local-update.sh`                | Rebuild and redeploy images   |
| `k8s-local-run-integration-tests.sh` | Execute test suite            |

## Test Environment

Services in `inferadb` namespace:

| Service        | URL                     | Purpose                 |
| -------------- | ----------------------- | ----------------------- |
| Server API     | `http://localhost:8080` | Authorization endpoints |
| Management API | `http://localhost:8081` | Tenant/vault management |
| Metrics        | `http://localhost:9090` | Prometheus metrics      |
| FoundationDB   | Internal only           | Cluster storage         |

### Environment Variables

| Variable             | Default                 | Purpose                  |
| -------------------- | ----------------------- | ------------------------ |
| `SERVER_API_URL`     | `http://localhost:8080` | InferaDB Server endpoint |
| `MANAGEMENT_API_URL` | `http://localhost:8081` | Management API endpoint  |
| `TEST_TIMEOUT_SECS`  | `30`                    | Per-test timeout         |

The harness handles JWT generation (Ed25519), user/session management, vault creation, and cleanup.

## Writing Tests

Tests use `TestFixture` from `integration/mod.rs`:

```rust
use super::*;
use reqwest::StatusCode;

#[tokio::test]
async fn test_my_feature() {
    let fixture = TestFixture::create()
        .await
        .expect("Failed to create test fixture");

    // Generate JWT with scopes
    let jwt = fixture
        .generate_jwt(None, &["inferadb.check"])
        .expect("Failed to generate JWT");

    // Call server endpoint
    let response = fixture
        .call_server_evaluate(&jwt, "document:1", "viewer", "user:alice")
        .await
        .expect("Failed to call server");

    assert!(response.status() == StatusCode::OK || response.status() == StatusCode::NOT_FOUND);

    fixture.cleanup().await.expect("Failed to cleanup");
}
```

## CI/CD

```yaml
- name: Run Integration Tests
  run: |
    ./scripts/k8s-local-start.sh
    ./scripts/k8s-local-run-integration-tests.sh
```

## Troubleshooting

| Issue                 | Solution                                                                                            |
| --------------------- | --------------------------------------------------------------------------------------------------- |
| Services not starting | `kubectl get pods -n inferadb` then `kubectl logs -n inferadb deployment/inferadb-server`           |
| Port in use           | `lsof -i :8080 -i :8081 -i :9090` or `./scripts/k8s-local-purge.sh && ./scripts/k8s-local-start.sh` |
| Tests timing out      | `./scripts/k8s-local-status.sh`, increase `TEST_TIMEOUT_SECS=60`, check Docker RAM (4GB+)           |
| Connection refused    | Restart port-forwarding: `./scripts/k8s-local-start.sh`                                             |

## Related

- [Server](https://github.com/inferadb/server) | [Management API](https://github.com/inferadb/management) | [InferaDB](https://github.com/inferadb/inferadb)

## License

Apache-2.0
