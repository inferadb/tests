# Makefile for InferaDB Integration Tests
# Provides convenient shortcuts for test execution against the Tailscale dev environment
#
# Prerequisites:
#   - Tailscale installed and running
#   - Dev environment deployed via: inferadb dev start
#
# Quick start:
#   make test     - Run all integration tests
#   make check    - Run code quality checks
#
# Use 'make help' to see all available commands

.PHONY: help setup test test-suite test-single check format lint audit deny clean

# Use mise exec if available, otherwise use system cargo
CARGO := $(shell command -v mise > /dev/null 2>&1 && echo "mise exec -- cargo" || echo "cargo")

# Default target - show help
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "InferaDB Integration Tests"
	@echo ""
	@echo "Prerequisites:"
	@echo "  - Tailscale installed and running"
	@echo "  - Dev environment deployed via: inferadb dev start"
	@echo ""
	@echo "Testing:"
	@grep -E '^test.*:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Code Quality:"
	@grep -E '^(check|format|lint|audit|deny):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Setup:"
	@grep -E '^(setup|clean):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Environment:"
	@echo "  INFERADB_API_URL   Override API URL (auto-discovered from Tailscale)"
	@echo ""

setup: ## One-time development environment setup
	@echo "Setting up integration tests environment..."
	@if command -v mise > /dev/null 2>&1; then \
		mise trust && mise install; \
	else \
		echo "Warning: mise not found - using system cargo"; \
	fi
	@$(CARGO) fetch
	@echo "Setup complete!"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Ensure Tailscale is running: tailscale status"
	@echo "  2. Deploy dev environment: inferadb dev start"
	@echo "  3. Run tests: make test"

# ============================================================================
# Testing
# ============================================================================

test: ## Run all integration tests
	@echo "Running integration tests against Tailscale dev environment..."
	@echo ""
	@# Show discovered URL
	@tailscale status --json 2>/dev/null | grep -o '"DNSName":"[^"]*"' | head -1 | sed 's/"DNSName":"\([^.]*\)\.\([^"]*\)\."/  Tailnet: \2/' || echo "  Warning: Could not detect Tailscale tailnet"
	@echo ""
	@$(CARGO) test --test integration -- --test-threads=1

test-suite: ## Run specific test suite (usage: make test-suite SUITE=auth_jwt)
	@if [ -z "$(SUITE)" ]; then \
		echo "Please specify a test suite: make test-suite SUITE=auth_jwt"; \
		echo ""; \
		echo "Available suites:"; \
		echo "  auth_jwt              - JWT authentication tests"; \
		echo "  vault_isolation       - Multi-tenant isolation tests"; \
		echo "  cache                 - Cache effectiveness tests"; \
		echo "  concurrency           - Parallel operation tests"; \
		echo "  e2e_workflows         - Full user journey tests"; \
		echo "  control_integration   - Management operation tests"; \
		echo "  resilience            - Failure scenario tests"; \
		exit 1; \
	fi
	@echo "Running $(SUITE) tests..."
	@$(CARGO) test --test integration $(SUITE) -- --nocapture --test-threads=1

test-single: ## Run a single test (usage: make test-single TEST=test_valid_jwt)
	@if [ -z "$(TEST)" ]; then \
		echo "Please specify a test name: make test-single TEST=test_valid_jwt"; \
		exit 1; \
	fi
	@echo "Running test: $(TEST)"
	@$(CARGO) test --test integration $(TEST) -- --nocapture --exact

test-verbose: ## Run all tests with full output
	@echo "Running integration tests (verbose)..."
	@$(CARGO) test --test integration -- --nocapture --test-threads=1

# ============================================================================
# Code Quality
# ============================================================================

check: ## Run code quality checks (format, lint, audit)
	@echo "Running code quality checks..."
	@$(MAKE) format
	@$(MAKE) lint
	@$(MAKE) audit
	@echo "All checks passed!"

format: ## Format code (rustfmt)
	@echo "Formatting code..."
	@$(CARGO) +nightly fmt --all
	@echo "Formatting complete!"

lint: ## Run linters (clippy)
	@echo "Running linters..."
	@$(CARGO) clippy --all-targets -- -D warnings

audit: ## Run security audit
	@echo "Running security audit..."
	@$(CARGO) audit 2>/dev/null || echo "Warning: cargo-audit not installed, skipping..."

deny: ## Check dependencies with cargo-deny
	@echo "Checking dependencies..."
	@$(CARGO) deny check 2>/dev/null || echo "Warning: cargo-deny not installed, skipping..."

# ============================================================================
# Maintenance
# ============================================================================

clean: ## Clean build artifacts
	@echo "Cleaning build artifacts..."
	@$(CARGO) clean
	@rm -rf target
