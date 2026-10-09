#!/usr/bin/env bash
# ============================================================================
# verify.sh — Validate OpenWRT build artifacts
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"
source "${SCRIPT_DIR}/../commons/utils.sh"

if [ -n "${ENV:-}" ] && [ -f "${REPO_ROOT}/environments/${ENV}/.env.public" ]; then
    # shellcheck source=/dev/null
    source "${REPO_ROOT}/environments/${ENV}/.env.public"
fi

TARGET="${TARGET:-ath79}"
SUBTARGET="${SUBTARGET:-generic}"
if [ $# -gt 0 ]; then
    BIN_DIR="$1"
else
    builder=$(find_builder "${BUILDER_DIR:-}") || {
        log_error "Image Builder no encontrado. Ejecuta: just setup-env ${ENV:-prod}"
        exit 1
    }
    BIN_DIR="${builder}/bin/targets/${TARGET}/${SUBTARGET}"
fi

REQUIRED_SIZE_MB=8
PROFILE="${PROFILE:-tplink_tl-wdr3600-v1}"
VARIANT="${VARIANT:-safe}"

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

    if [[ "${VARIANT}" == "extroot" ]]; then
        if [ "${size_kb}" -gt 5632 ]; then
            log_error "${label}: ${size_kb} KB exceeds the extroot firmware budget of 5632 KB"
            errors=$((errors + 1))
        else
            log_info "${label}: size fits the extroot flash budget"
        fi
    elif [ "${size_mb}" -gt "${REQUIRED_SIZE_MB}" ]; then
        log_error "${label}: ${size_mb} MB exceeds ${REQUIRED_SIZE_MB} MB flash limit"
        errors=$((errors + 1))
    else
        log_info "${label}: size OK (${size_mb} MB)"
    fi
}

# ---------------------------------------------------------------------------
verify_extroot_artifacts() {
    local bin_dir="$1"
    local manifest="${bin_dir}/extroot-image.manifest"
    local image uuid image_uuid image_name size_bytes

    if [[ "${VARIANT}" != "extroot" ]]; then
        return 0
    fi
    if [[ ! -f "${manifest}" ]]; then
        log_error "Missing extroot-image.manifest in ${bin_dir}"
        errors=$((errors + 1))
        return
    fi

    uuid=$(sed -n 's/^uuid=//p' "${manifest}" | head -1)
    local fstab_uuid
    fstab_uuid=$(sed -n 's/^fstab_uuid=//p' "${manifest}" | head -1)
    image_name=$(sed -n 's/^image=//p' "${manifest}" | head -1)
    image="${bin_dir}/${image_name}"

    if [[ -z "${image_name}" || ! -f "${image}" ]]; then
        log_error "Extroot filesystem image is missing"
        errors=$((errors + 1))
        return
    fi
    if [[ "${uuid}" != "${fstab_uuid}" || -z "${uuid}" ]]; then
        log_error "Extroot image UUID and firmware fstab UUID do not match"
        errors=$((errors + 1))
    fi

    size_bytes=$(stat -c '%s' "${image}")
    if [[ "${size_bytes}" -ne $((512 * 1024 * 1024)) ]]; then
        log_error "Extroot image must be exactly 512 MiB; found ${size_bytes} bytes"
        errors=$((errors + 1))
    fi

    if ! command -v tune2fs >/dev/null 2>&1; then
        log_error "tune2fs is required to verify the extroot filesystem image"
        errors=$((errors + 1))
    else
        image_uuid=$(tune2fs -l "${image}" 2>/dev/null | sed -n 's/^Filesystem UUID:[[:space:]]*//p' | head -1)
        if [[ "${image_uuid}" != "${uuid}" ]]; then
            log_error "Extroot image UUID (${image_uuid:-missing}) does not match manifest UUID (${uuid})"
            errors=$((errors + 1))
        else
            log_info "Extroot filesystem UUID verified: ${uuid}"
        fi
    fi

    if command -v e2fsck >/dev/null 2>&1; then
        if e2fsck -fn "${image}" >/dev/null 2>&1; then
            log_info "Extroot ext4 filesystem passes a read-only consistency check"
        else
            log_error "Extroot ext4 filesystem failed its read-only consistency check"
            errors=$((errors + 1))
        fi
    else
        log_error "e2fsck is required to verify extroot filesystem consistency"
        errors=$((errors + 1))
    fi

    if command -v debugfs >/dev/null 2>&1; then
        local package db_contents stat_output fstab_contents
        db_contents=$(debugfs -R "cat /upper/lib/apk/db/installed" "${image}" 2>/dev/null || true)
        for package in e2fsprogs parted usbutils rsync tcpdump bind-dig wireguard-tools kmod-wireguard kmod-usb-net kmod-usb-net-rndis kmod-usb-net-cdc-ether; do
            if ! grep -Fqx "P:${package}" <<< "${db_contents}"; then
                log_error "Extroot package database does not contain ${package}"
                errors=$((errors + 1))
            fi
        done
        for path in /upper /work; do
            stat_output=$(debugfs -R "stat ${path}" "${image}" 2>/dev/null || true)
            if ! grep -q 'Type:.*directory' <<< "${stat_output}"; then
                log_error "Extroot image is missing required ${path} directory"
                errors=$((errors + 1))
            fi
        done
        fstab_contents=$(debugfs -R "cat /upper/etc/config/fstab" "${image}" 2>/dev/null || true)
        if ! grep -Fq "option uuid '${uuid}'" <<< "${fstab_contents}"; then
            log_error "Extroot image fstab does not reference UUID ${uuid}"
            errors=$((errors + 1))
        fi
    else
        log_error "debugfs is required to verify extroot image contents"
        errors=$((errors + 1))
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

    verify_extroot_artifacts "${bin_dir}"

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
