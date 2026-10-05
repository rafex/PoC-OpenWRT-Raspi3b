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
    local overlay="${4:-}"
    local artifact_dir="${5:-}"

    log_step "Starting compilation..."
    log_info "Profile:  ${profile}"
    log_info "Builder:  ${builder}"
    if [ -n "${overlay}" ]; then
        log_info "Overlay:  ${overlay}"
    fi
    echo ""

    if [ ! -f "${builder}/Makefile" ]; then
        log_error "Makefile not found in ${builder}"
        log_error "Ensure you're pointing to an extracted Image Builder directory."
        return 1
    fi

    cd "${builder}"

    log_info "Running make image..."
    echo ""

    if [ -n "${overlay}" ] && [ ! -d "${overlay}" ]; then
        log_error "Overlay directory not found: ${overlay}"
        return 1
    fi

    # Run the build. FILES injects the generated OpenWRT overlay.
    if [ -n "${overlay}" ]; then
        # shellcheck disable=SC2086
        make image PROFILE="${profile}" PACKAGES="${packages}" FILES="${overlay}" 2>&1 | \
            tee "/tmp/openwrt-build-$$.log"
    else
        # shellcheck disable=SC2086
        make image PROFILE="${profile}" PACKAGES="${packages}" 2>&1 | \
            tee "/tmp/openwrt-build-$$.log"
    fi

    local exit_code=${PIPESTATUS[0]}

    echo ""
    if [ "${exit_code}" -eq 0 ]; then
        log_info "BUILD SUCCESSFUL"
    else
        log_error "BUILD FAILED (exit code: ${exit_code})"
        log_error "See full log: /tmp/openwrt-build-$$.log"
        return 1
    fi

    if [ -n "${artifact_dir}" ]; then
        local target_dir="${builder}/bin/targets/ath79/generic"
        local -a images=()
        mapfile -t images < <(find "${target_dir}" -maxdepth 1 -type f \
            \( -name "*-${profile}-squashfs-factory.bin" -o -name "*-${profile}-squashfs-sysupgrade.bin" \) -print 2>/dev/null)
        if [ "${#images[@]}" -eq 0 ]; then
            log_error "No factory/sysupgrade images found under ${target_dir}"
            return 1
        fi
        mkdir -p "${artifact_dir}"
        find "${artifact_dir}" -mindepth 1 -maxdepth 1 -type f -delete
        cp "${images[@]}" "${artifact_dir}/"
        find "${target_dir}" -maxdepth 1 -type f -name '*.manifest' -exec cp {} "${artifact_dir}/" \;
        (cd "${artifact_dir}" && sha256sum ./*.bin > sha256sums)
        log_info "Variant artifacts copied to: ${artifact_dir}"
    fi

    return 0
}

# Allow running standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    BUILDER="${1:-${BUILDER_DIR:-}}"
    PACKAGES="${2:-}"
    PROFILE="${3:-tplink_tl-wdr3600-v1}"
    OVERLAY="${4:-${OVERLAY_DIR:-}}"
    ARTIFACT_DIR="${5:-${ARTIFACT_DIR:-}}"
    compile_image "${BUILDER}" "${PACKAGES}" "${PROFILE}" "${OVERLAY}" "${ARTIFACT_DIR}"
fi
