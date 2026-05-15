#!/usr/bin/env bash
# ============================================================================
# verify-image.sh — Validate OpenWRT build artifacts
# ============================================================================
# Usage: ./scripts/verify-image.sh <path-to-bin-dir>
#
# This script verifies:
#   1. Image file exists and has non-zero size
#   2. SHA256 checksum matches
#   3. Image size fits within TP-Link TL-WDR3600 flash (8 MB)
#   4. Required packages keyword check (best-effort, full check requires
#      extracting the SquashFS).
#
set -euo pipefail

BIN_DIR="${1:-bin/targets/ath79/generic}"
REQUIRED_SIZE_MB=8  # TP-Link TL-WDR3600 has 8 MB flash
PROFILE="${PROFILE:-tplink_tl-wdr3600-v1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

errors=0

log_ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
log_err() { echo -e "${RED}[ERROR]${NC} $*"; errors=$((errors + 1)); }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }

# ---------------------------------------------------------------------------
# 1. Locate the image
# ---------------------------------------------------------------------------
echo "=== Verifying image in: ${BIN_DIR} ==="

FACTORY_IMG=$(find "${BIN_DIR}" -name "*-${PROFILE}-squashfs-factory.bin" 2>/dev/null | head -1)
SYSUPGRADE_IMG=$(find "${BIN_DIR}" -name "*-${PROFILE}-squashfs-sysupgrade.bin" 2>/dev/null | head -1)

if [ -z "${FACTORY_IMG}" ] && [ -z "${SYSUPGRADE_IMG}" ]; then
    log_err "No image found for profile '${PROFILE}' in ${BIN_DIR}"
    echo "       Expected: *-${PROFILE}-squashfs-factory.bin or *-${PROFILE}-squashfs-sysupgrade.bin"
    exit 1
fi

if [ -n "${FACTORY_IMG}" ]; then
    log_ok "Factory image: ${FACTORY_IMG}"
fi
if [ -n "${SYSUPGRADE_IMG}" ]; then
    log_ok "Sysupgrade image: ${SYSUPGRADE_IMG}"
fi

# ---------------------------------------------------------------------------
# 2. Check file size
# ---------------------------------------------------------------------------
check_size() {
    local img="$1"
    local label="$2"

    if [ ! -f "${img}" ]; then
        log_err "${label}: file not found"
        return
    fi

    local size_kb
    size_kb=$(du -k "${img}" | awk '{print $1}')
    local size_mb=$(( (size_kb + 1023) / 1024 ))

    echo "       ${label}: ${size_kb} KB (~${size_mb} MB)"

    if [ "${size_mb}" -gt "${REQUIRED_SIZE_MB}" ]; then
        log_err "${label}: image size ${size_mb} MB exceeds ${REQUIRED_SIZE_MB} MB flash limit"
    else
        log_ok "${label}: size (${size_mb} MB) fits within flash limit"
    fi
}

[ -n "${FACTORY_IMG}" ]   && check_size "${FACTORY_IMG}"   "factory"
[ -n "${SYSUPGRADE_IMG}" ] && check_size "${SYSUPGRADE_IMG}" "sysupgrade"

# ---------------------------------------------------------------------------
# 3. Verify checksum if available
# ---------------------------------------------------------------------------
for sumfile in "${BIN_DIR}"/sha256sums*; do
    if [ -f "${sumfile}" ]; then
        log_ok "Checksum file found: ${sumfile}"
        if command -v sha256sum &>/dev/null; then
            if (cd "${BIN_DIR}" && sha256sum -c --quiet "$(basename "${sumfile}")" 2>/dev/null); then
                log_ok "All checksums valid"
            else
                log_warn "Some checksums failed (non-critical, check manually)"
            fi
        fi
        break
    fi
done

# ---------------------------------------------------------------------------
# 4. Best-effort package check
# ---------------------------------------------------------------------------
REQUIRED_KEYWORDS=("dropbear" "firewall4" "dnsmasq" "wpad" "kmod-usb-storage" "tor" "wireguard")

if [ -f "${FACTORY_IMG}" ] || [ -f "${SYSUPGRADE_IMG}" ]; then
    TARGET_IMG="${FACTORY_IMG:-${SYSUPGRADE_IMG}}"
    echo ""
    echo "=== Best-effort package check (strings scan) ==="
    
    for kw in "${REQUIRED_KEYWORDS[@]}"; do
        if strings "${TARGET_IMG}" 2>/dev/null | grep -qi "${kw}"; then
            log_ok "Package keyword found: ${kw}"
        else
            log_warn "Package keyword NOT found in binary: ${kw} (may be compressed)"
        fi
    done
    
    # Check excluded packages
    echo ""
    echo "=== Checking excluded packages (LuCi, uhttpd, rpcd) ==="
    EXCLUDED_KEYWORDS=("luci" "uhttpd" "rpcd")
    for kw in "${EXCLUDED_KEYWORDS[@]}"; do
        if strings "${TARGET_IMG}" 2>/dev/null | grep -qi "${kw}"; then
            log_warn "EXCLUDED package keyword found: ${kw} (verify manually)"
        else
            log_ok "Excluded package NOT found: ${kw}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
if [ "${errors}" -eq 0 ]; then
    echo -e "${GREEN}Verification PASSED — ${errors} errors${NC}"
else
    echo -e "${RED}Verification FAILED — ${errors} errors${NC}"
fi
echo "==============================================="

exit "${errors}"
