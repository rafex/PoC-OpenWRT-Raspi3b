#!/usr/bin/env bash
# ============================================================================
# build-openwrt.sh — Build custom OpenWRT image for TP-Link TL-WDR3600 v1.0
# ============================================================================
# Orchestrates the full build pipeline:
#   1. Reads package configuration
#   2. Runs make image with the profile
#   3. Reports results
#
# Usage:
#   ./build-openwrt.sh
#   ./build-openwrt.sh --packages config/openwrt-packages.txt
#   ./build-openwrt.sh --builder /path/to/imagebuilder
#
set -euo pipefail

PROFILE="${PROFILE:-tplink_tl-wdr3600-v1}"
PACKAGES_FILE="${PACKAGES_FILE:-config/openwrt-packages.txt}"
BUILDER_DIR="${BUILDER_DIR:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

# ---------------------------------------------------------------------------
# Parse command-line arguments
# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)  PROFILE="$2"; shift 2 ;;
            --packages) PACKAGES_FILE="$2"; shift 2 ;;
            --builder)  BUILDER_DIR="$2"; shift 2 ;;
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
  --help, -h             Show this help

Environment:
  PROFILE                Override default profile
  PACKAGES_FILE          Override packages config file
  BUILDER_DIR            Override Image Builder directory

Example:
  ./scripts/setup-build-env.sh                    # First: download builder
  ./build-openwrt.sh --builder openwrt-builder/   # Then: build
EOF
}

# ---------------------------------------------------------------------------
# Find the Image Builder
# ---------------------------------------------------------------------------
find_builder() {
    if [ -n "${BUILDER_DIR}" ] && [ -d "${BUILDER_DIR}" ]; then
        echo "${BUILDER_DIR}"
        return
    fi
    
    # Search common locations
    local candidates=(
        "${BUILDER_DIR}"
        openwrt-builder/openwrt-imagebuilder-*
        ../openwrt-imagebuilder-*
        ./openwrt-imagebuilder-*
    )
    
    for candidate in "${candidates[@]}"; do
        if [ -d "${candidate}" ] && [ -f "${candidate}/Makefile" ]; then
            echo "${candidate}"
            return
        fi
    done
    
    log_error "Could not find Image Builder directory."
    log_error "Run scripts/setup-build-env.sh first, or specify with --builder DIR."
    exit 1
}

# ---------------------------------------------------------------------------
# Parse packages file into PACKAGES variable
# ---------------------------------------------------------------------------
parse_packages() {
    if [ ! -f "${PACKAGES_FILE}" ]; then
        log_error "Packages file not found: ${PACKAGES_FILE}"
        exit 1
    fi
    
    # Extract package names: ignore comments (#) and blank lines, join with spaces
    PACKAGES=$(grep -v '^\s*#' "${PACKAGES_FILE}" | grep -v '^\s*$' | tr '\n' ' ' | sed 's/\s\+/ /g' | xargs)
    
    if [ -z "${PACKAGES}" ]; then
        log_error "No packages defined in ${PACKAGES_FILE}"
        exit 1
    fi
    
    # Count packages
    local count
    count=$(echo "${PACKAGES}" | wc -w | xargs)
    log_info "Packages file: ${PACKAGES_FILE} (${count} packages)"
    
    # Separate includes and excludes for display
    local includes excludes
    includes=$(echo "${PACKAGES}" | tr ' ' '\n' | grep -c -v '^-' | xargs)
    excludes=$(echo "${PACKAGES}" | tr ' ' '\n' | grep -c '^-' | xargs)
    log_info "  Included: ${includes} packages"
    log_info "  Excluded: ${excludes} packages"
}

# ---------------------------------------------------------------------------
# Build the image
# ---------------------------------------------------------------------------
build_image() {
    local builder="$1"
    local packages="$2"
    
    log_step "Starting build..."
    echo "  Profile:  ${PROFILE}"
    echo "  Builder:  ${builder}"
    echo ""
    
    cd "${builder}"
    
    # Show available profiles (informational)
    if [ -f "Makefile" ]; then
        log_info "Running make image..."
        echo ""
        
        # Run the build
        # shellcheck disable=SC2086
        make image PROFILE="${PROFILE}" PACKAGES="${packages}" 2>&1 | \
            tee /tmp/openwrt-build-$$.log
        
        local exit_code=${PIPESTATUS[0]}
        
        echo ""
        if [ "${exit_code}" -eq 0 ]; then
            log_info "BUILD SUCCESSFUL"
        else
            log_error "BUILD FAILED (exit code: ${exit_code})"
            log_error "See full log: /tmp/openwrt-build-$$.log"
            exit "${exit_code}"
        fi
    else
        log_error "Makefile not found in ${builder}"
        log_error "Make sure you're pointing to the extracted Image Builder directory."
        exit 1
    fi
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
        echo "     ./scripts/verify-image.sh ${bin_dir}/ath79/generic"
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
    builder=$(find_builder)
    log_info "Found: ${builder}"
    
    # Step 2: Parse packages
    log_step "Parsing package configuration..."
    parse_packages
    
    # Step 3: Build
    build_image "${builder}" "${PACKAGES}"
    
    # Step 4: Report
    report_results "${builder}"
}

main "$@"
