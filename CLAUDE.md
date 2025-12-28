# InferaDB Integration Tests

End-to-end tests validating InferaDB Engine and Control against the Tailscale dev environment.

## Prerequisites

1. **Tailscale** - Must be installed and connected to your tailnet
2. **Dev Environment** - Must be running via `inferadb dev start`

## Quick Commands

```bash
# Running Tests (requires dev environment to be running)
make test               # Run all E2E tests
make test-suite SUITE=auth_jwt    # Specific test module
make test-single TEST=test_valid_jwt    # Single test with output
make test-verbose       # All tests with full output

# Code Quality
make check              # Format + lint + audit
cargo clippy -- -D warnings
cargo +nightly fmt --all
```

## Test Suites

| Module                      | Tests | Coverage                                       |
| --------------------------- | ----- | ---------------------------------------------- |
| `auth_jwt_tests`            | 7     | JWT validation, Ed25519 signatures, expiration |
| `vault_isolation_tests`     | 4     | Multi-tenant separation, cross-vault access    |
| `cache_tests`               | 4     | Hit/miss patterns, expiration, concurrent load |
| `concurrency_tests`         | 5     | Parallel requests, race conditions             |
| `e2e_workflows_tests`       | 2     | User journeys from registration to authz       |
| `control_integration_tests` | 5     | Org suspension, client deactivation            |
| `resilience_tests`          | 6     | Service recovery, graceful degradation         |

## Architecture

### URL Discovery

Tests automatically discover the API URL from the local Tailscale CLI:

```rust
// Discovers tailnet from: tailscale status --json
// Builds URL: https://inferadb-api.<tailnet>.ts.net

let ctx = TestContext::new();
ctx.control_url("/auth/register")  // -> https://inferadb-api.<tailnet>.ts.net/control/v1/auth/register
ctx.engine_url("/evaluate")        // -> https://inferadb-api.<tailnet>.ts.net/access/v1/evaluate
```

Override with `INFERADB_API_URL` environment variable if needed.

### Test Harness

All tests use `TestFixture` from `integration/mod.rs`:

```rust
let fixture = TestFixture::create().await?;

// Generate JWT with scopes
let jwt = fixture.generate_jwt(None, &["inferadb.check"])?;

// Call engine endpoint
let response = fixture
    .call_server_evaluate(&jwt, "document:1", "viewer", "user:alice")
    .await?;

fixture.cleanup().await?;
```

### API Endpoints

| Service | Path Prefix    | Purpose                 |
| ------- | -------------- | ----------------------- |
| Control | `/control/v1/` | Tenant/vault management |
| Engine  | `/access/v1/`  | Authorization endpoints |

### Environment Variables

| Variable          | Default                                  | Purpose                 |
| ----------------- | ---------------------------------------- | ----------------------- |
| `INFERADB_API_URL`| Auto-discovered from Tailscale           | API base URL override   |

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
| `call_server_evaluate()` | Call /access/v1/evaluate  |
| `cleanup()`              | Teardown test resources   |

## Critical Patterns

### 1. JWT Generation

Tests generate Ed25519 JWTs matching production format:

```rust
pub fn generate_jwt(
    &self,
    vault: Option<i64>,
    scopes: &[&str],
) -> Result<String> {
    let claims = ClientClaims {
        sub: format!("client:{}", self.client_id),
        vault_id: vault.unwrap_or(self.vault_id).to_string(),
        scope: scopes.join(" "),
        exp: (Utc::now() + Duration::hours(1)).timestamp(),
        // ... other claims
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

## Starting the Dev Environment

Before running tests, start the dev environment:

```bash
inferadb dev start
```

This deploys InferaDB to a Kubernetes cluster with Tailscale ingress, making it available at `https://inferadb-api.<your-tailnet>.ts.net`.

## Troubleshooting

| Issue                      | Solution                                                       |
| -------------------------- | -------------------------------------------------------------- |
| Tailscale not detected     | Run `tailscale status` to verify connection                    |
| Connection refused         | Start dev environment: `inferadb dev start`                    |
| 404 errors                 | Check API path prefixes (/control/v1/, /access/v1/)            |
| Certificate errors         | Tests use `danger_accept_invalid_certs(true)` for self-signed  |
| Tests timing out           | Check dev environment health, increase timeouts                |

## Code Quality

- **Format:** `cargo +nightly fmt --all`
- **Lint:** `cargo clippy -- -D warnings`
- **Run before PR:** `make check && make test`

All tests must pass before merging.
