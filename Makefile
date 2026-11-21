# Required versions
REQUIRED_GO_VERSION = $(shell sed -n 's/^go //p' go.mod)
REQUIRED_DOCKER_VERSION = 24.0.0

# Tool paths and versions
GO ?= go
GOLANGCI_LINT ?= golangci-lint
GOSEC ?= gosec
GOVULNCHECK ?= govulncheck
OSV_SCANNER ?= osv-scanner
DOCKER ?= docker
COSIGN ?= cosign
SYFT ?= syft
DUPL ?= dupl

# Version information
VERSION ?= $(shell git describe --tags --always)
COMMIT ?= $(shell git rev-parse --short HEAD)
BUILD_DATE ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')

# Build flags
BUILD_FLAGS ?= -v
TEST_FLAGS ?= -v -race -cover
LINT_FLAGS ?= run --timeout=5m

# Coverage output paths
COVERAGE_PROFILE = coverage.out
COVERAGE_HTML = coverage.html
UNIT_PACKAGES = $(shell $(GO) list ./pkg/... | grep -v '/pkg/test/e2e$$')

# Binary information
BINARY_NAME = ghactions-updater
BINARY_PATH = bin/$(BINARY_NAME)

# Docker information
DOCKER_REGISTRY ?= threatflux
DOCKER_IMAGE = $(DOCKER_REGISTRY)/$(BINARY_NAME)
DOCKER_TAG ?= $(VERSION)
DOCKER_LATEST = $(DOCKER_IMAGE):latest
DOCKER_DEV_IMAGE = $(DOCKER_REGISTRY)/go-dev

.PHONY: all build test test-e2e lint clean docker-build check-versions check-github-token install-tools install-lint-tool install-security-tools security help version-info coverage coverage-unit coverage-report dupl-check docker-push docker-sign docker-verify install docker-run fmt docker-test docker-tests docker-dev-build docker-fmt docker-lint docker-security docker-coverage docker-dupl-check docker-all docker-shell

# Version check targets
check-versions: ## Check all required tool versions
	@echo "Checking required tool versions..."
	@echo "Checking Go version..."
	@$(GO) list -m >/dev/null
	@echo "Checking Docker version..."
	@$(DOCKER) --version | grep -q "$(REQUIRED_DOCKER_VERSION)" || (echo "Warning: Recommended Docker version $(REQUIRED_DOCKER_VERSION) not found")
	@echo "All version checks completed"

check-github-token: ## Validate GitHub token
	@echo "Validating GitHub token..."
	@if [ -z "$$GITHUB_TOKEN" ]; then \
		echo "Error: GITHUB_TOKEN environment variable is not set"; \
		echo "Please set GITHUB_TOKEN with a valid GitHub personal access token"; \
		echo "The token needs 'repo' scope for private repositories or 'public_repo' for public ones"; \
		echo "Generate one at: https://github.com/settings/tokens"; \
		exit 1; \
	fi
	@echo "Testing GitHub API access..."
	@curl -s -f -H "Authorization: token $$GITHUB_TOKEN" https://api.github.com/user > /dev/null && \
		echo "✓ GitHub token is valid and has API access" || \
		(echo "✗ GitHub token is invalid or expired" && \
		 echo "Please check your token at: https://github.com/settings/tokens" && \
		 exit 1)

# Install required tools
install-tools: install-lint-tool install-security-tools ## Install required Go tools
	@$(GO) install github.com/sigstore/cosign/v2/cmd/cosign@v2.6.5
	@$(GO) install github.com/anchore/syft/cmd/syft@v1.57.2
	@$(GO) install github.com/mibk/dupl@v1.1.0

install-lint-tool:
	@$(GO) install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.15.0

install-security-tools:
	@$(GO) install github.com/securego/gosec/v2/cmd/gosec@v2.30.0
	@$(GO) install golang.org/x/vuln/cmd/govulncheck@v1.10.0
	@$(GO) install github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.7.1

build: check-versions ## Build the application
	@echo "Building application..."
	@mkdir -p bin
	cd pkg/cmd/$(BINARY_NAME)/ && $(GO) build $(BUILD_FLAGS) \
		-ldflags="-X main.Version=$(VERSION) -X main.Commit=$(COMMIT)" \
		-o ../../../$(BINARY_PATH)

fmt: ## Format Go source files
	@echo "Formatting Go files..."
	@find pkg -name "*.go" -type f -exec $(GO) fmt {} \;

lint: install-lint-tool ## Run golangci-lint for code analysis
	@echo "Running linters..."
	$(GOLANGCI_LINT) $(LINT_FLAGS) ./...

test: check-github-token ## Run unit tests with coverage
	@echo "Running tests..."
	@echo "Configuring Git to use SSH for GitHub operations..."
	@git config url."git@github.com:".insteadOf "https://github.com/" 2>/dev/null || true
	@$(GO) test $(TEST_FLAGS) ./pkg/...

coverage: check-github-token ## Generate test coverage report
	@echo "Generating coverage report..."
	@echo "Configuring Git to use SSH for GitHub operations..."
	@git config url."git@github.com:".insteadOf "https://github.com/" 2>/dev/null || true
	@$(GO) test -coverprofile=$(COVERAGE_PROFILE) ./pkg/...
	@$(MAKE) coverage-report

coverage-unit: ## Generate coverage without GitHub integration credentials
	@$(GO) test -coverprofile=$(COVERAGE_PROFILE) $(UNIT_PACKAGES)
	@$(MAKE) coverage-report

test-e2e: check-github-token ## Run the live GitHub end-to-end tests
	@$(GO) test $(TEST_FLAGS) ./pkg/test/e2e

coverage-report:
	@$(GO) tool cover -html=$(COVERAGE_PROFILE) -o $(COVERAGE_HTML)
	@$(GO) tool cover -func=$(COVERAGE_PROFILE)

dupl-check: install-tools ## Check for duplicate code
	@echo "Checking for duplicate code..."
	@$(DUPL) -t 75 -plumbing -verbose ./pkg/
	@echo "Duplicate code check completed"

security: install-security-tools ## Run security scans
	@echo "Running security scans..."
	@$(GOSEC) ./...
	@$(GOVULNCHECK) ./...
	@$(OSV_SCANNER) scan source --lockfile=go.mod --no-call-analysis=go

docker-build: check-versions ## Build Docker image
	@echo "Building Docker image..."
	@$(DOCKER) build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		-t $(DOCKER_IMAGE):$(DOCKER_TAG) \
		-t $(DOCKER_LATEST) \
		.

docker-sign: ## Sign Docker image with cosign
	@echo "Signing Docker image..."
	@$(COSIGN) sign --key cosign.key $(DOCKER_IMAGE):$(DOCKER_TAG)
	@$(COSIGN) sign --key cosign.key $(DOCKER_LATEST)

docker-test: ## Test Docker image with
	@echo "Testing Docker image..."
	@$(DOCKER) run \
		--cap-drop=ALL \
		-e GITHUB_TOKEN \
		$(DOCKER_IMAGE):$(DOCKER_TAG) -h

docker-verify: ## Verify Docker image signature
	@echo "Verifying Docker image signature..."
	@$(COSIGN) verify --key cosign.pub $(DOCKER_IMAGE):$(DOCKER_TAG)

docker-run: ## Run Docker container with security options
	@echo "Running Docker container with security options..."
	@$(DOCKER) run \
		--cap-drop=ALL \
		-e GITHUB_TOKEN \
		$(DOCKER_IMAGE):$(DOCKER_TAG)

docker-push: docker-build docker-sign ## Push Docker image to registry
	@echo "Pushing Docker image..."
	@$(DOCKER) push $(DOCKER_IMAGE):$(DOCKER_TAG)
	@$(DOCKER) push $(DOCKER_LATEST)

install: build ## Install the binary
	@echo "Installing $(BINARY_NAME)..."
	@install -m 755 $(BINARY_PATH) /usr/local/bin/$(BINARY_NAME)

clean: ## Remove build artifacts and generated files
	@echo "Cleaning all artifacts and generated files..."
	@rm -f $(BINARY_PATH)
	@rm -f $(COVERAGE_PROFILE)
	@rm -f $(COVERAGE_HTML)
	@rm -rf vendor/
	@rm -rf bin/
	@rm -f *.log
	@rm -f *.out
	@rm -f *.test
	@rm -f *.prof
	@rm -rf dist/
	@go clean -cache -testcache -modcache -fuzzcache

all: fmt test security lint dupl-check build docker-build ## Run all checks and build

help: ## Display available commands
	@echo "Available commands:"
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

version-info: ## Display version information
	@echo "Build Information:"
	@echo "  Version:    $(VERSION)"
	@echo "  Commit:     $(COMMIT)"
	@echo "  Build Date: $(BUILD_DATE)"
	@echo "\nRequired Versions:"
	@echo "  Go:     $(REQUIRED_GO_VERSION)+"
	@echo "  Docker: $(REQUIRED_DOCKER_VERSION)+"
	@echo "\nInstalled Versions:"
	@$(GO) version
	@$(DOCKER) --version

# Docker development environment targets
docker-dev-build: ## Build the development Docker image
	@echo "Building development Docker image..."
	@$(DOCKER) build -t $(DOCKER_DEV_IMAGE) -f Dockerfile.dev .

docker-fmt: docker-dev-build ## Format Go source files using Docker
	@echo "Formatting Go files using Docker..."
	@$(DOCKER) run -v $(CURDIR):/workspace $(DOCKER_DEV_IMAGE) fmt

docker-lint: docker-dev-build ## Run golangci-lint for code analysis using Docker
	@echo "Running linters using Docker..."
	@$(DOCKER) run -v $(CURDIR):/workspace $(DOCKER_DEV_IMAGE) lint

docker-security: docker-dev-build ## Run security scans using Docker
	@echo "Running security scans using Docker..."
	@$(DOCKER) run -v $(CURDIR):/workspace $(DOCKER_DEV_IMAGE) security

docker-tests: docker-dev-build ## Run unit tests with coverage using Docker
	@echo "Running tests using Docker..."
	@$(DOCKER) run -v $(CURDIR):/workspace -e GITHUB_TOKEN=$(GITHUB_TOKEN) $(DOCKER_DEV_IMAGE) test

docker-coverage: docker-dev-build ## Generate test coverage report using Docker
	@echo "Generating coverage report using Docker..."
	@$(DOCKER) run -v $(CURDIR):/workspace -e GITHUB_TOKEN=$(GITHUB_TOKEN) $(DOCKER_DEV_IMAGE) coverage

docker-dupl-check: docker-dev-build ## Check for duplicate code using Docker
	@echo "Checking for duplicate code using Docker..."
	@$(DOCKER) run -v $(CURDIR):/workspace $(DOCKER_DEV_IMAGE) dupl-check

docker-all: docker-dev-build ## Run all checks and tests using Docker
	@echo "Running all checks and tests using Docker..."
	@$(DOCKER) run -v $(CURDIR):/workspace -e GITHUB_TOKEN=$(GITHUB_TOKEN) $(DOCKER_DEV_IMAGE) all dupl-check

docker-shell: docker-dev-build ## Start a shell in the development container
	@echo "Starting shell in development container..."
	@$(DOCKER) run -it -v $(CURDIR):/workspace $(DOCKER_DEV_IMAGE) shell
