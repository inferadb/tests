# InferaDB Integration Tests

**E2E test suite** — validates Server and Management API in Kubernetes.

> [!IMPORTANT]
> Under active development. Not production-ready.

## Quick Start

```bash
./scripts/k8s-local-start.sh                   # Start K8s stack
./scripts/k8s-local-run-integration-tests.sh   # Run tests
./scripts/k8s-local-stop.sh                    # Stop (preserves data)
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
| `k8s-local-purge.sh`                 | Remove all resources         |
| `k8s-local-status.sh`                | Check deployment health      |
| `k8s-local-run-integration-tests.sh` | Execute test suite           |

## Environment

| Service    | URL                     |
| ---------- | ----------------------- |
| Server     | `http://localhost:8080` |
| Management | `http://localhost:8081` |
| Metrics    | `http://localhost:9090` |

| Variable             | Default                 | Purpose             |
| -------------------- | ----------------------- | ------------------- |
| `SERVER_API_URL`     | `http://localhost:8080` | Server endpoint     |
| `MANAGEMENT_API_URL` | `http://localhost:8081` | Management endpoint |
| `TEST_TIMEOUT_SECS`  | `30`                    | Per-test timeout    |

## Writing Tests

```rust
#[tokio::test]
async fn test_my_feature() {
    let fixture = TestFixture::create().await.unwrap();
    let jwt = fixture.generate_jwt(None, &["inferadb.check"]).unwrap();

    let response = fixture
        .call_server_evaluate(&jwt, "document:1", "viewer", "user:alice")
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    fixture.cleanup().await.unwrap();
}
```

## Troubleshooting

| Issue                 | Solution                                                                              |
| --------------------- | ------------------------------------------------------------------------------------- |
| Services not starting | `kubectl get pods -n inferadb && kubectl logs -n inferadb deployment/inferadb-server` |
| Port in use           | `./scripts/k8s-local-purge.sh && ./scripts/k8s-local-start.sh`                        |
| Tests timing out      | Increase `TEST_TIMEOUT_SECS=60`, check Docker RAM (4GB+)                              |

## License

[Apache-2.0](LICENSE)
