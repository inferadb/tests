# InferaDB Integration Tests - Commands

## Prerequisites
- Tailscale running: `tailscale status`
- Dev environment: `inferadb dev start`

## Testing Commands

```bash
# Run all tests (recommended)
make test

# Run specific test suite
make test-suite SUITE=auth_jwt
make test-suite SUITE=vault_isolation
make test-suite SUITE=cache
make test-suite SUITE=concurrency
make test-suite SUITE=e2e_workflows
make test-suite SUITE=control_integration
make test-suite SUITE=resilience

# Run single test
make test-single TEST=test_valid_jwt_from_management_client

# Verbose output
make test-verbose

# Direct cargo (with mise)
mise exec -- cargo test --test integration -- --test-threads=1
mise exec -- cargo test --test integration auth_jwt -- --nocapture
```

## Code Quality

```bash
# Full check (format + lint + audit)
make check

# Individual checks
make format    # rustfmt (nightly)
make lint      # clippy with -D warnings
make audit     # cargo-audit
make deny      # cargo-deny
```

## Setup & Maintenance

```bash
# Initial setup
make setup

# Clean build artifacts
make clean
```

## Environment Override

```bash
# Use custom API URL instead of Tailscale discovery
INFERADB_API_URL=http://localhost:9090 make test
```

## Unix Utilities (Darwin)

```bash
# Standard utilities work the same
git status
ls -la
grep -r "pattern" .
find . -name "*.rs"
```
