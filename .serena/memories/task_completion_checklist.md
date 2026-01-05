# InferaDB Integration Tests - Task Completion Checklist

## Before Committing

### 1. Format Code
```bash
make format
# Or: mise exec -- cargo +nightly fmt --all
```

### 2. Run Linter
```bash
make lint
# Or: mise exec -- cargo clippy --all-targets -- -D warnings
```

### 3. Run Tests (if environment available)
```bash
make test
# Tests require: Tailscale running + dev environment deployed
```

### 4. Security Audit (if dependencies changed)
```bash
make audit
make deny
```

## Quick Validation
```bash
# Full check (format + lint + audit)
make check
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
