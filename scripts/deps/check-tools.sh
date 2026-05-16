#!/usr/bin/env bash
# ============================================================================
# check-tools.sh — Verify required tools are installed
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# ---------------------------------------------------------------------------
# Check all required tools
# ---------------------------------------------------------------------------
check_all_tools() {
    log_step "Verifying required tools..."

    local missing=()
    local tools=("just" "make" "sops" "age" "shellcheck" "wget" "yq" "python3")

    for tool in "${tools[@]}"; do
        if command -v "${tool}" &>/dev/null; then
            log_info "  ✓ ${tool}"
        else
            log_warn "  ✗ ${tool} (not installed)"
            missing+=("${tool}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        log_error "Missing tools: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  macOS:  brew install ${missing[*]}"
        echo "  Debian: sudo apt-get install ${missing[*]}"
        echo "  Fedora: sudo dnf install ${missing[*]}"
        return 1
    fi

    log_info "All required tools installed."
    return 0
}

# Allow running standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_all_tools "$@"
fi
