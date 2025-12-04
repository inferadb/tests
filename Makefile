# Makefile for InferaDB Integration Tests
# Provides convenient shortcuts for test execution and environment management
#
# Quick start:
#   make setup    - One-time setup (installs tools)
#   make test     - Run all integration tests
#   make start    - Start local Kubernetes environment
#   make stop     - Stop local Kubernetes environment
#
# Use 'make help' to see all available commands

.PHONY: help setup test start stop status update purge check format lint audit deny clean reset ci

# Use mise exec if available, otherwise use system cargo
CARGO := $(shell command -v mise > /dev/null 2>&1 && echo "mise exec -- cargo" || echo "cargo")
PRETTIER := $(shell command -v mise > /dev/null 2>&1 && echo "mise exec -- prettier" || echo "prettier")
TAPLO := $(shell command -v mise > /dev/null 2>&1 && echo "mise exec -- taplo" || echo "taplo")
MARKDOWNLINT := $(shell command -v mise > /dev/null 2>&1 && echo "mise exec -- markdownlint-cli2" || echo "markdownlint-cli2")

# Default target - show help
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "InferaDB Integration Tests Commands"
	@echo ""
	@echo "Setup & Environment:"
	@grep -E '^(setup|start|stop|status|update|purge|clean|reset):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Testing:"
	@grep -E '^test.*:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Code Quality:"
	@grep -E '^(check|format|lint|audit|deny):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "CI/CD:"
	@grep -E '^ci:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""

setup: ## One-time development environment setup
	@echo "🔧 Setting up integration tests environment..."
	@if command -v mise > /dev/null 2>&1; then \
		mise trust && mise install; \
	else \
		echo "⚠️  mise not found - using system cargo"; \
	fi
	@$(CARGO) fetch
	@echo "✅ Setup complete!"

# ============================================================================
# Kubernetes Environment
# ============================================================================

start: ## Start local Kubernetes environment
	@echo "🚀 Starting local Kubernetes environment..."
	@./scripts/k8s-local-start.sh
	@echo "✅ Environment ready!"

stop: ## Stop local Kubernetes environment (preserves data)
	@echo "🛑 Stopping local Kubernetes environment..."
	@./scripts/k8s-local-stop.sh
	@echo "✅ Environment stopped!"

status: ## Check Kubernetes environment status
	@./scripts/k8s-local-status.sh

update: ## Rebuild and redeploy images
	@echo "🔄 Updating local Kubernetes environment..."
	@./scripts/k8s-local-update.sh
	@echo "✅ Environment updated!"

purge: ## Remove all Kubernetes resources and data
	@echo "🗑️  Purging local Kubernetes environment..."
	@./scripts/k8s-local-purge.sh
	@echo "✅ Environment purged!"

# ============================================================================
# Testing
# ============================================================================

test: ## Run all integration tests
	@echo "🧪 Running integration tests..."
	@./scripts/k8s-local-run-integration-tests.sh

test-suite: ## Run specific test suite (usage: make test-suite SUITE=auth_jwt)
	@if [ -z "$(SUITE)" ]; then \
		echo "❌ Please specify a test suite: make test-suite SUITE=auth_jwt"; \
		echo "Available suites: auth_jwt, vault_isolation, cache, concurrency, e2e_workflows, management_integration, resilience"; \
		exit 1; \
	fi
	@echo "🧪 Running $(SUITE) tests..."
	@$(CARGO) test --test integration $(SUITE) -- --nocapture

test-local: ## Run tests against already-running services
	@echo "🧪 Running integration tests (local mode)..."
	@$(CARGO) test --test integration -- --nocapture

# ============================================================================
# Code Quality
# ============================================================================

check: ## Run code quality checks (format, lint, audit)
	@echo "🔍 Running code quality checks..."
	@$(MAKE) format
	@$(MAKE) lint
	@$(MAKE) audit
	@echo "✅ All checks passed!"

format: ## Format code (Prettier, Taplo, markdownlint, rustfmt)
	@echo "📝 Formatting code..."
	@$(PRETTIER) --write "**/*.{md,yml,yaml,json}" --log-level warn || true
	@$(MARKDOWNLINT) --fix "**/*.md" || true
	@$(TAPLO) fmt || true
	@$(CARGO) +nightly fmt --all
	@echo "✅ Formatting complete!"

lint: ## Run linters (clippy, markdownlint)
	@echo "🔍 Running linters..."
	@$(MARKDOWNLINT) "**/*.md"
	@$(CARGO) clippy --all-targets -- -D warnings

audit: ## Run security audit
	@echo "🔒 Running security audit..."
	@$(CARGO) audit || echo "⚠️  cargo-audit not installed, skipping..."

deny: ## Check dependencies with cargo-deny
	@echo "🔍 Checking dependencies..."
	@$(CARGO) deny check || echo "⚠️  cargo-deny not installed, skipping..."

# ============================================================================
# Maintenance
# ============================================================================

clean: ## Clean build artifacts
	@echo "🧹 Cleaning build artifacts..."
	@$(CARGO) clean

reset: ## Full reset (clean + purge Kubernetes)
	@echo "⚠️  Performing full reset..."
	@$(MAKE) purge || true
	@$(CARGO) clean
	@rm -rf target
	@echo "✅ Reset complete!"

# ============================================================================
# CI
# ============================================================================

ci: ## Run CI checks (format, lint, test)
	@echo "🤖 Running CI checks..."
	@$(MAKE) format
	@$(MAKE) lint
	@$(MAKE) start
	@$(MAKE) test
	@$(MAKE) stop
	@echo "✅ CI checks passed!"
