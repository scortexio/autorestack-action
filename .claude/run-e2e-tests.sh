#!/bin/bash
# Idempotent script to install gh CLI, acquire token, and run e2e tests
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
TOKEN_FILE="/tmp/gh_token.txt"

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

# 1. Install gh CLI if not present
install_gh_cli() {
    if command -v gh &> /dev/null; then
        local version=$(gh --version | head -n1)
        log_info "gh CLI already installed: $version"
        return 0
    fi

    log_info "Installing gh CLI..."

    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]]; then
        log_error "Unsupported architecture: $arch (only x86_64 is supported)"
        return 1
    fi

    # Get latest release URL
    local download_url=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | \
        grep "browser_download_url.*linux_amd64.tar.gz\"" | \
        cut -d '"' -f 4)

    if [[ -z "$download_url" ]]; then
        log_error "Failed to get gh CLI download URL"
        return 1
    fi

    log_info "Downloading from: $download_url"

    # Download and install
    cd /tmp
    curl -L -o gh_linux_amd64.tar.gz "$download_url"
    tar -xzf gh_linux_amd64.tar.gz
    sudo cp gh_*/bin/gh /usr/local/bin/
    sudo chmod +x /usr/local/bin/gh
    rm -rf gh_*

    local version=$(gh --version | head -n1)
    log_info "Successfully installed gh CLI: $version"
}

# 2. Acquire GitHub App token
acquire_token() {
    log_info "Acquiring GitHub App token..."

    # Check if required environment variables are set
    if [[ -z "$GH_APP_ID" ]] || [[ -z "$GH_APP_PRIVATE_KEY" ]]; then
        log_error "Missing required environment variables: GH_APP_ID and/or GH_APP_PRIVATE_KEY"
        return 1
    fi

    # Generate token using the Python script
    if ! uv run "$PROJECT_ROOT/tests/get_github_app_token.py" > "$TOKEN_FILE" 2>/dev/null; then
        log_error "Failed to generate GitHub App token"
        return 1
    fi

    local token_preview=$(cat "$TOKEN_FILE" | head -c 10)
    log_info "Successfully acquired token: ${token_preview}..."
}

# 3. Setup git config and gh auth
setup_git_and_gh() {
    log_info "Setting up git configuration..."

    # Save current git config state
    ORIGINAL_GPGSIGN=$(git config --global --get commit.gpgsign || echo "not-set")

    # Disable commit signing for tests
    git config --global commit.gpgsign false

    # Setup gh authentication (gh uses GH_TOKEN)
    export GH_TOKEN="$(cat "$TOKEN_FILE")"

    log_info "Configuring gh auth..."
    gh auth setup-git

    log_info "Git and gh authentication configured"
}

# 4. Restore git config
restore_git_config() {
    log_info "Restoring git configuration..."

    if [[ "$ORIGINAL_GPGSIGN" == "not-set" ]]; then
        git config --global --unset commit.gpgsign || true
    else
        git config --global commit.gpgsign "$ORIGINAL_GPGSIGN"
    fi

    log_info "Git configuration restored"
}

# 5. Run e2e tests
run_e2e_tests() {
    log_info "Running e2e tests..."

    # GH_TOKEN is already exported from setup_git_and_gh, no need to re-export

    # Run the tests (timeout should be handled externally)
    if bash "$PROJECT_ROOT/tests/test_e2e.sh"; then
        log_info "✅ E2E tests completed successfully!"
        return 0
    else
        local exit_code=$?
        log_error "❌ E2E tests failed with exit code: $exit_code"
        return $exit_code
    fi
}

# Main execution
main() {
    log_info "Starting E2E test setup and execution..."
    log_info "Project root: $PROJECT_ROOT"

    # Trap to ensure cleanup happens
    trap restore_git_config EXIT

    # Execute steps
    install_gh_cli || exit 1
    acquire_token || exit 1
    setup_git_and_gh || exit 1

    # Run tests (allow failure to be handled by exit code)
    if run_e2e_tests; then
        log_info "🎉 All steps completed successfully!"
        exit 0
    else
        log_error "Tests failed, but cleanup will still occur"
        exit 1
    fi
}

# Run main function
main "$@"
