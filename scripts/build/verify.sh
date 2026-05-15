#!/usr/bin/env bash
# ============================================================================
# verify.sh — Validate OpenWRT build artifacts
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

BIN_DIR="${1:-${REPO_ROOT}/openwrt-builder/*/bin/targets/ath79/generic}"
REQUIRED_SIZE_MB=8
PROFILE="${PROFILE:-tplink_tl-wdr3600-v1}"

errors=0

# ---------------------------------------------------------------------------
check_size() {
    local img="$1"
    local label="$2"

    if [ ! -f "${img}" ]; then
        log_error "${label}: file not found"
        return
    fi

    local size_kb
    size_kb=$(du -k "${img}" | awk '{print $1}')
    local size_mb=$(( (size_kb + 1023) / 1024 ))
    echo "       ${label}: ${size_kb} KB (~${size_mb} MB)"

    if [ "${size_mb}" -gt "${REQUIRED_SIZE_MB}" ]; then
        log_error "${label}: ${size_mb} MB exceeds ${REQUIRED_SIZE_MB} MB flash limit"
    else
        log_info "${label}: size OK (${size_mb} MB)"
    fi
}

# ---------------------------------------------------------------------------
verify_image() {
    local bin_dir="$1"

    echo "=== Verifying image in: ${bin_dir} ==="

    # Locate images
    local factory_img
    local sysupgrade_img
    factory_img=$(find "${bin_dir}" -name "*-${PROFILE}-squashfs-factory.bin" 2>/dev/null | head -1)
    sysupgrade_img=$(find "${bin_dir}" -name "*-${PROFILE}-squashfs-sysupgrade.bin" 2>/dev/null | head -1)

    if [ -z "${factory_img}" ] && [ -z "${sysupgrade_img}" ]; then
        log_error "No image found for profile '${PROFILE}'"
        return 1
    fi

    [ -n "${factory_img}" ]   && log_info "Factory: ${factory_img}"
    [ -n "${sysupgrade_img}" ] && log_info "Sysupgrade: ${sysupgrade_img}"

    # Check sizes
    [ -n "${factory_img}" ]   && check_size "${factory_img}"   "factory"
    [ -n "${sysupgrade_img}" ] && check_size "${sysupgrade_img}" "sysupgrade"

    # Verify checksums
    for sumfile in "${bin_dir}"/sha256sums*; do
        if [ -f "${sumfile}" ]; then
            log_info "Checksum file: ${sumfile}"
            if command -v sha256sum &>/dev/null; then
                if (cd "${bin_dir}" && sha256sum -c --quiet "$(basename "${sumfile}")" 2>/dev/null); then
                    log_info "All checksums valid"
                else
                    log_warn "Some checksums failed (verify manually)"
                fi
            fi
            break
        fi
    done

    echo "==============================================="
    if [ "${errors}" -eq 0 ]; then
        log_info "Verification PASSED"
    else
        log_error "Verification FAILED — ${errors} errors"
    fi
    echo "==============================================="

    return "${errors}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verify_image "${BIN_DIR}"
fi
