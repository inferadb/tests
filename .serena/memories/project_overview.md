# InferaDB Integration Tests - Project Overview

## Purpose
E2E test suite validating InferaDB Engine and Control services in Kubernetes. Tests run against a Tailscale-based dev environment.

## Tech Stack
- **Language**: Rust 1.92 (2021 edition)
- **Runtime**: Tokio async runtime
- **HTTP Client**: reqwest (with cookies, JSON support)
- **JWT**: jsonwebtoken (EdDSA/Ed25519)
- **Serialization**: serde/serde_json
- **Testing**: Built-in Rust test framework with tokio::test

## Architecture
Tests use a `TestFixture` pattern that:
1. Registers a test user via Control API
2. Creates organization, vault, client, and certificate
3. Generates JWTs signed with Ed25519 keys
4. Makes authenticated requests to Engine (Access) API
5. Cleans up resources on Drop

## Test Categories (33 total tests)
| Category        | Count | Focus                                     |
|-----------------|-------|-------------------------------------------|
| Authentication  | 7     | JWT validation, Ed25519, expiration       |
| Vault Isolation | 4     | Multi-tenant separation                   |
| Cache Behavior  | 4     | Hit/miss, expiration, concurrency         |
| Concurrency     | 5     | Parallel requests, race conditions        |
| E2E Workflows   | 2     | Registration → authorization journeys     |
| Management      | 5     | Org suspension, client deactivation       |
| Resilience      | 6     | Recovery, degradation, error propagation  |

## Key Files
- `integration/mod.rs` - TestFixture, TestContext, API types
- `integration/auth_jwt_tests.rs` - JWT authentication tests
- `integration/vault_isolation_tests.rs` - Multi-tenancy tests
- `integration/cache_tests.rs` - Caching behavior tests
- `integration/concurrency_tests.rs` - Parallel operation tests
- `integration/e2e_workflows_tests.rs` - Full journey tests
- `integration/control_integration_tests.rs` - Management tests
- `integration/resilience_tests.rs` - Failure scenario tests

## API Endpoints
Tests target a unified Tailscale endpoint (auto-discovered):
- Control API: `{base}/control/v1/*`
- Engine (Access) API: `{base}/access/v1/*`

## Environment Variables
| Variable          | Purpose                      |
|-------------------|------------------------------|
| `INFERADB_API_URL`| Override auto-discovered URL |
