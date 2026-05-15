#!/usr/bin/env bash
# ============================================================================
# openwrt.sh — Main OpenWRT build orchestrator
# ============================================================================
# Uses modular scripts from scripts/build/, scripts/commons/, scripts/install/
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source commons and utilities
source "${SCRIPT_DIR}/../commons/logging.sh"
source "${SCRIPT_DIR}/../commons/utils.sh"

PROFILE="${PROFILE:-tplink_tl-wdr3600-v1}"
PACKAGES_FILE="${PACKAGES_FILE:-${REPO_ROOT}/config/openwrt-packages.txt}"
BUILDER_DIR="${BUILDER_DIR:-}"
OVERLAY_DIR="${OVERLAY_DIR:-}"

# ---------------------------------------------------------------------------
# Parse command-line arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)  PROFILE="$2"; shift 2 ;;
            --packages) PACKAGES_FILE="$2"; shift 2 ;;
            --builder)  BUILDER_DIR="$2"; shift 2 ;;
            --overlay)  OVERLAY_DIR="$2"; shift 2 ;;
            --help|-h)  usage; exit 0 ;;
            *) log_error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --profile PROFILE      Target profile (default: tplink_tl-wdr3600-v1)
  --packages FILE        Packages config file (default: config/openwrt-packages.txt)
  --builder DIR          Path to extracted Image Builder directory
  --overlay DIR          Path to config overlay directory (for custom configs)
  --help, -h             Show this help

Environment:
  PROFILE                Override default profile
  PACKAGES_FILE          Override packages config file
  BUILDER_DIR            Override Image Builder directory
  OVERLAY_DIR            Override config overlay directory

Example:
  ./scripts/install/setup-env.sh                # First: download builder
  ./scripts/build/openwrt.sh --builder openwrt-builder/   # Then: build
EOF
}

# ---------------------------------------------------------------------------
# Report results
# ---------------------------------------------------------------------------
report_results() {
    local builder="$1"

    echo ""
    echo "==============================================="
    echo " Build Results"
    echo "==============================================="

    local bin_dir="${builder}/bin/targets"

    if [ -d "${bin_dir}" ]; then
        echo ""
        log_info "Generated files:"
        find "${bin_dir}" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "sha256sums*" \) 2>/dev/null | while read -r f; do
            local size
            size=$(du -h "${f}" | awk '{print $1}')
            printf "  %s\t%s\n" "${size}" "${f}"
        done

        echo ""
        log_info "Next steps:"
        echo "  1. Verify the image:"
        echo "     ${SCRIPT_DIR}/verify.sh ${bin_dir}/ath79/generic"
        echo ""
        echo "  2. Flash the router:"
        echo "     See docs/FLASH_INSTRUCTIONS.md"
    else
        log_warn "No binaries directory found. Build may have failed."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    echo "==============================================="
    echo " OpenWRT Custom Build"
    echo " Profile: ${PROFILE}"
    echo "==============================================="
    echo ""

    # Step 1: Find builder
    log_step "Locating Image Builder..."
    local builder
    builder=$(find_builder "${BUILDER_DIR}") || {
        log_error "Could not find Image Builder directory."
        log_error "Run scripts/install/setup-env.sh first, or specify with --builder DIR."
        exit 1
    }
    log_info "Found: ${builder}"

    # Step 2: Parse packages
    log_step "Parsing package configuration..."
    local packages
    packages=$(parse_packages "${PACKAGES_FILE}") || {
        log_error "Packages file not found: ${PACKAGES_FILE}"
        exit 1
    }
    local count
    count=$(echo "${packages}" | wc -w | xargs)
    log_info "Packages: ${count} from ${PACKAGES_FILE}"

    # Step 3: Compile
    "${SCRIPT_DIR}/compile.sh" "${builder}" "${packages}" "${PROFILE}" || exit $?

    # Step 4: Report
    report_results "${builder}"
}

# Allow running standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
