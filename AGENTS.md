# InferaDB Integration Tests

End-to-end tests validating InferaDB Server and Management API in Kubernetes.

## Quick Commands

```bash
# Environment Management
make start              # Start local K8s environment
make stop               # Stop environment (preserves data)
make status             # Check deployment health
make purge              # Remove all resources and data

# Running Tests
make test               # Run all E2E tests
cargo test --test integration auth_jwt    # Specific test module
cargo test test_name -- --nocapture       # Single test with output

# Code Quality
make check              # Format + lint + audit
cargo clippy -- -D warnings
cargo +nightly fmt --all
```

## Test Suites

| Module                         | Tests | Coverage                                       |
| ------------------------------ | ----- | ---------------------------------------------- |
| `auth_jwt_tests`               | 7     | JWT validation, Ed25519 signatures, expiration |
| `vault_isolation_tests`        | 4     | Multi-tenant separation, cross-vault access    |
| `cache_tests`                  | 4     | Hit/miss patterns, expiration, concurrent load |
| `concurrency_tests`            | 5     | Parallel requests, race conditions             |
| `e2e_workflows_tests`          | 2     | User journeys from registration to authz       |
| `management_integration_tests` | 5     | Org suspension, client deactivation            |
| `resilience_tests`             | 6     | Service recovery, graceful degradation         |

## Architecture

### Test Harness

All tests use `TestFixture` from `integration/mod.rs`:

```rust
let fixture = TestFixture::create().await?;

// Generate JWT with scopes
let jwt = fixture.generate_jwt(None, &["inferadb.check"])?;

// Call server endpoint
let response = fixture
    .call_server_evaluate(&jwt, "document:1", "viewer", "user:alice")
    .await?;

fixture.cleanup().await?;
```

### Environment Variables

| Variable             | Default                 | Purpose                  |
| -------------------- | ----------------------- | ------------------------ |
| `SERVER_API_URL`     | `http://localhost:8080` | InferaDB Server endpoint |
| `MANAGEMENT_API_URL` | `http://localhost:8081` | Management API endpoint  |
| `TEST_TIMEOUT_SECS`  | `30`                    | Per-test timeout         |

### K8s Services

Tests run against services in `inferadb` namespace:

| Service        | Port | Purpose                 |
| -------------- | ---- | ----------------------- |
| Server API     | 8080 | Authorization endpoints |
| Management API | 8081 | Tenant/vault management |
| Metrics        | 9090 | Prometheus metrics      |

## Writing Tests

### Standard Pattern

```rust
#[tokio::test]
async fn test_vault_isolation() {
    let fixture = TestFixture::create().await.expect("setup failed");

    // Generate tokens for different vaults
    let jwt_a = fixture.generate_jwt(Some(vault_a), &["inferadb.check"])?;
    let jwt_b = fixture.generate_jwt(Some(vault_b), &["inferadb.check"])?;

    // Verify isolation
    let response = fixture.call_server_evaluate(&jwt_a, "doc:1", "view", "user:x").await?;
    assert_eq!(response.status(), StatusCode::OK);

    fixture.cleanup().await?;
}
```

### Test Fixture Methods

| Method                   | Purpose                   |
| ------------------------ | ------------------------- |
| `create()`               | Initialize test context   |
| `generate_jwt()`         | Create Ed25519-signed JWT |
| `call_server_evaluate()` | Call /v1/check endpoint   |
| `call_management_api()`  | Call Management API       |
| `cleanup()`              | Teardown test resources   |

## Critical Patterns

### 1. JWT Generation

Tests generate Ed25519 JWTs matching production format:

```rust
pub fn generate_jwt(
    &self,
    vault: Option<Uuid>,
    scopes: &[&str],
) -> Result<String> {
    let claims = Claims {
        sub: self.user_id.to_string(),
        vault: vault.unwrap_or(self.default_vault).to_string(),
        scopes: scopes.iter().map(|s| s.to_string()).collect(),
        exp: (Utc::now() + Duration::hours(1)).timestamp(),
    };
    // Sign with Ed25519
}
```

### 2. Vault Isolation

**Always test cross-vault access is denied:**

```rust
// Create resources in vault A
// Attempt access from vault B
// Assert denial
```

### 3. Cleanup

**Always cleanup after tests to prevent state leakage:**

```rust
fixture.cleanup().await.expect("cleanup failed");
```

## Scripts

| Script                                       | Purpose                      |
| -------------------------------------------- | ---------------------------- |
| `scripts/k8s-local-start.sh`                 | Deploy stack to local K8s    |
| `scripts/k8s-local-stop.sh`                  | Stop services, preserve data |
| `scripts/k8s-local-purge.sh`                 | Remove all resources         |
| `scripts/k8s-local-status.sh`                | Check deployment health      |
| `scripts/k8s-local-run-integration-tests.sh` | Execute test suite           |

## Troubleshooting

| Issue                 | Solution                                                                              |
| --------------------- | ------------------------------------------------------------------------------------- |
| Services not starting | `kubectl get pods -n inferadb && kubectl logs -n inferadb deployment/inferadb-server` |
| Port conflicts        | `lsof -i :8080 -i :8081` or `make purge && make start`                                |
| Tests timing out      | Increase `TEST_TIMEOUT_SECS`, check Docker RAM (4GB+)                                 |
| Connection refused    | Restart port-forwarding: `make start`                                                 |

## Code Quality

- **Format:** `cargo +nightly fmt --all`
- **Lint:** `cargo clippy -- -D warnings`
- **Run before PR:** `make check && make test`

All tests must pass before merging.
