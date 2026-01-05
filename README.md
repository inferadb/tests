<div align="center">
    <p><a href="https://inferadb.com"><img src=".github/inferadb.png" width="100" alt="InferaDB Logo" /></a></p>
    <h1>InferaDB Integration Tests</h1>
    <p>E2E test suite validating Engine and Control in Kubernetes</p>
</div>

> [!IMPORTANT]
> Under active development. Not production-ready.

## Quick Start

```bash
make start    # Start K8s stack
make test     # Run tests
make stop     # Stop (preserves data)
```

Run specific suites:

```bash
cargo test --test integration auth_jwt
cargo test --test integration vault_isolation
cargo test --test integration cache
```

## Test Coverage

| Category        | Tests | Scope                                           |
| --------------- | ----- | ----------------------------------------------- |
| Authentication  | 7     | JWT validation, Ed25519, expiration, scopes     |
| Vault Isolation | 4     | Multi-tenant separation, cross-vault prevention |
| Cache Behavior  | 4     | Hit/miss patterns, expiration, concurrency      |
| Concurrency     | 5     | Parallel requests, race conditions              |
| E2E Workflows   | 2     | Registration → authorization journeys           |
| Management      | 5     | Org suspension, client deactivation             |
| Resilience      | 6     | Recovery, degradation, error propagation        |

## Scripts

| Script                               | Purpose                      |
| ------------------------------------ | ---------------------------- |
| `k8s-local-start.sh`                 | Deploy stack to local K8s    |
| `k8s-local-stop.sh`                  | Stop services, preserve data |
| `k8s-local-status.sh`                | Check deployment health      |
| `k8s-local-update.sh`                | Rebuild and redeploy images  |
| `k8s-local-purge.sh`                 | Remove all resources         |
| `k8s-local-run-integration-tests.sh` | Execute test suite           |

## Environment

Tests run inside K8s using service DNS. Override for local development:

| Variable          | Default (in K8s)               | Purpose               |
| ----------------- | ------------------------------ | --------------------- |
| `CONTROL_URL`     | `http://inferadb-control:9090` | Control HTTP endpoint |
| `ENGINE_URL`      | `http://inferadb-engine:8080`  | Engine HTTP endpoint  |
| `ENGINE_GRPC_URL` | `http://inferadb-engine:8081`  | Engine gRPC endpoint  |
| `ENGINE_MESH_URL` | `http://inferadb-engine:8082`  | Engine mesh endpoint  |

## Writing Tests

```rust
#[tokio::test]
async fn test_my_feature() {
    let fixture = TestFixture::create().await.expect("setup failed");
    let jwt = fixture.generate_jwt(None, &["inferadb.check"]).unwrap();

    let response = fixture
        .call_engine_evaluate(&jwt, "document:1", "viewer", "user:alice")
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}
```

## Troubleshooting

| Issue                 | Solution                                                                              |
| --------------------- | ------------------------------------------------------------------------------------- |
| Services not starting | `kubectl get pods -n inferadb && kubectl logs -n inferadb deployment/inferadb-engine` |
| Port in use           | `make purge && make start`                                                            |
| Tests timing out      | Check Docker RAM (4GB+ recommended), check pod logs for errors                        |

## License

[Apache-2.0](LICENSE)
