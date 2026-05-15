#!/usr/bin/env bash
# ============================================================================
# compile.sh — Compile the OpenWRT image
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

compile_image() {
    local builder="$1"
    local packages="$2"
    local profile="${3:-tplink_tl-wdr3600-v1}"

    log_step "Starting compilation..."
    log_info "Profile:  ${profile}"
    log_info "Builder:  ${builder}"
    echo ""

    if [ ! -f "${builder}/Makefile" ]; then
        log_error "Makefile not found in ${builder}"
        log_error "Ensure you're pointing to an extracted Image Builder directory."
        return 1
    fi

    cd "${builder}"

    log_info "Running make image..."
    echo ""

    # Run the build
    # shellcheck disable=SC2086
    make image PROFILE="${profile}" PACKAGES="${packages}" 2>&1 | \
        tee "/tmp/openwrt-build-$$.log"

    local exit_code=${PIPESTATUS[0]}

    echo ""
    if [ "${exit_code}" -eq 0 ]; then
        log_info "BUILD SUCCESSFUL"
    else
        log_error "BUILD FAILED (exit code: ${exit_code})"
        log_error "See full log: /tmp/openwrt-build-$$.log"
        return 1
    fi

    return 0
}

# Allow running standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    BUILDER="${1:-${BUILDER_DIR:-}}"
    PACKAGES="${2:-}"
    PROFILE="${3:-tplink_tl-wdr3600-v1}"
    compile_image "${BUILDER}" "${PACKAGES}" "${PROFILE}"
fi
