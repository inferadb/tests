<div align="center">
    <p><a href="https://inferadb.com"><img src=".github/inferadb.png" width="100" alt="InferaDB Logo" /></a></p>
    <h1>InferaDB Integration Tests</h1>
    <p>
        <a href="https://discord.gg/inferadb"><img src="https://img.shields.io/badge/Discord-Join%20us-5865F2?logo=discord&logoColor=white" alt="Discord" /></a>
        <a href="#license"><img src="https://img.shields.io/badge/license-MIT%2FApache--2.0-blue.svg" alt="License" /></a>
    </p>
    <p>E2E test suite validating Engine and Control in Kubernetes</p>
</div>

> [!IMPORTANT]
> Under active development. Not production-ready.

## Quick Start

```bash
# Check prerequisites
inferadb dev doctor

# Start development cluster
inferadb dev start

# Run tests
cargo test --test integration -- --test-threads=1

# Stop cluster (preserves data)
inferadb dev stop

# Destroy cluster completely
inferadb dev stop --destroy
```

Run specific suites:

```bash
cargo test --test integration auth_jwt -- --test-threads=1
cargo test --test integration vault_isolation -- --test-threads=1
cargo test --test integration cache -- --test-threads=1
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

## CLI Commands

The development cluster is managed via the [InferaDB CLI](https://github.com/inferadb/cli):

| Command                       | Purpose                         |
| ----------------------------- | ------------------------------- |
| `inferadb dev doctor`         | Check development prerequisites |
| `inferadb dev start`          | Start local Talos cluster       |
| `inferadb dev stop`           | Pause cluster (preserves data)  |
| `inferadb dev stop --destroy` | Destroy cluster completely      |
| `inferadb dev status`         | Show cluster status             |
| `inferadb dev logs`           | View cluster logs               |
| `inferadb dev reset`          | Reset all cluster data          |

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

| Issue                 | Solution                                                                               |
| --------------------- | -------------------------------------------------------------------------------------- |
| Services not starting | `inferadb dev status` or `inferadb dev logs`                                           |
| Port in use           | `inferadb dev stop --destroy && inferadb dev start`                                    |
| Tests timing out      | Check Docker RAM (4GB+ recommended), run `inferadb dev logs` for errors                |
| Prerequisites missing | Run `inferadb dev doctor` to check requirements                                        |

## Community

Join us on [Discord](https://discord.gg/inferadb) to discuss InferaDB, get help with your projects, and connect with other developers. Whether you have questions, want to share what you're building, or are interested in contributing, we'd love to have you!

## License

Licensed under either of:

- [Apache License, Version 2.0](LICENSE-APACHE)
- [MIT License](LICENSE-MIT)

at your option.
