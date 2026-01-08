# InferaDB Integration Tests - Task Completion Checklist

## Before Committing

### 1. Format Code
```bash
cargo +nightly fmt --all
```

### 2. Run Linter
```bash
cargo clippy --all-targets -- -D warnings
```

### 3. Run Tests (if cluster available)
```bash
# Start cluster if needed
inferadb dev start

# Run tests
cargo test --test integration -- --test-threads=1
```

### 4. Security Audit (if dependencies changed)
```bash
cargo audit
cargo deny check
```

## Quick Validation
```bash
cargo +nightly fmt --all
cargo clippy --all-targets -- -D warnings
cargo audit
```

## When Adding New Tests

1. Place in appropriate test module:
   - `auth_jwt_tests.rs` - Authentication
   - `vault_isolation_tests.rs` - Multi-tenancy
   - `cache_tests.rs` - Caching
   - `concurrency_tests.rs` - Parallel operations
   - `e2e_workflows_tests.rs` - Full journeys
   - `control_integration_tests.rs` - Management ops
   - `resilience_tests.rs` - Failure scenarios

2. Follow test naming: `test_<feature>_<scenario>`

3. Use `TestFixture::create()` for setup

4. Include cleanup: `fixture.cleanup().await`

5. Add descriptive assertion messages

## When Modifying mod.rs

- Update `TestFixture` if adding new API calls
- Add new request/response types as needed
- Document new public functions
- Update imports if adding test modules

## Cluster Management

```bash
inferadb dev doctor    # Check prerequisites
inferadb dev start     # Start cluster
inferadb dev status    # Check status
inferadb dev logs      # View logs
inferadb dev stop      # Pause cluster
```
