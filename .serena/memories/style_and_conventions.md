# InferaDB Integration Tests - Style & Conventions

## Rust Formatting (.rustfmt.toml)
- **Edition**: 2024 style
- **Imports**: Group by StdExternalCrate, crate-level granularity
- **Line width**: Uses MAX heuristics
- **Comment width**: 100 chars, wrap/normalize enabled
- **Newlines**: Unix style
- **Derives**: Don't merge (each derive separate)
- **Format nightly**: `cargo +nightly fmt`

## Code Style Patterns

### Test Structure
```rust
#[tokio::test]
async fn test_descriptive_name() {
    // Setup
    let fixture = TestFixture::create().await.expect("Failed to create test fixture");
    
    // Action
    let jwt = fixture.generate_jwt(None, &["scope"]).expect("...");
    let response = fixture.call_server_evaluate(&jwt, ...).await.expect("...");
    
    // Assert
    assert_eq!(response.status(), StatusCode::OK, "context message");
    
    // Cleanup
    fixture.cleanup().await.expect("Failed to cleanup");
}
```

### Error Handling
- Use `anyhow::Result<T>` for test setup
- Use `.expect("descriptive message")` for infallible operations
- Use `.context("message")` for contextual errors

### Naming Conventions
- Test functions: `test_<what>_<scenario>` (e.g., `test_jwt_with_expired_token`)
- Request types: `<Entity>Request` (e.g., `CreateVaultRequest`)
- Response types: `<Entity>Response` (e.g., `VaultResponse`)
- Constants: `SCREAMING_SNAKE_CASE`

### Documentation
- Module-level doc comments explain purpose
- Inline comments for non-obvious logic
- No docstrings on individual test functions (test name should be descriptive)

### Assertions
- Use `assert_eq!` with failure message context
- Use `assert!` with descriptive conditions
- Use `assert_matches!` for pattern matching (from assert_matches crate)

### Imports
```rust
// Standard library first (handled by rustfmt)
use std::{...};

// External crates
use anyhow::{Context, Result};
use reqwest::StatusCode;
// etc.

// Crate imports
use super::*;  // For test modules
```

## Clippy
- All warnings treated as errors (`-D warnings`)
- No `#[allow(...)]` without justification
