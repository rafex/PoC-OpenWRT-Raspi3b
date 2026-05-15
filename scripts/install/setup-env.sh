#!/usr/bin/env bash
# ============================================================================
# setup-env.sh — Download and extract OpenWRT Image Builder
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.2}"
TARGET="${TARGET:-ath79}"
SUBTARGET="${SUBTARGET:-generic}"
BUILD_DIR="${BUILD_DIR:-$(pwd)/openwrt-builder}"

# ---------------------------------------------------------------------------
check_deps() {
    log_step "Checking system dependencies..."
    local deps=("wget" "make" "gcc" "g++" "awk" "find" "tar")
    local missing=()

    # Check for zstd or unzstd
    if ! command -v zstd &>/dev/null && ! command -v unzstd &>/dev/null; then
        deps+=("zstd")
    fi

    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo "  Debian/Ubuntu: sudo apt-get install ${missing[*]} build-essential libncurses-dev zstd"
        echo "  macOS:         brew install ${missing[*]} coreutils zstd"
        echo "  Fedora:        sudo dnf install ${missing[*]} make gcc gcc-c++ ncurses-devel zstd"
        return 1
    fi
    log_info "All dependencies found."
    return 0
}

# ---------------------------------------------------------------------------
download() {
    local url="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64.tar.zst"
    local filename
    filename=$(basename "${url}")
    local dest="${BUILD_DIR}/${filename}"

    mkdir -p "${BUILD_DIR}"

    if [ -f "${dest}" ]; then
        log_info "Already downloaded: ${dest}"
        return
    fi

    log_info "Downloading Image Builder..."
    log_info "  URL: ${url}"

    if ! wget -q --show-progress -O "${dest}" "${url}" 2>&1; then
        # Fallback to .tar.xz
        url="${url%.tar.zst}.tar.xz"
        filename=$(basename "${url}")
        dest="${BUILD_DIR}/${filename}"
        log_warn ".tar.zst not found, trying .tar.xz..."
        wget -q --show-progress -O "${dest}" "${url}" || {
            log_error "Download failed. Check version ${OPENWRT_VERSION} at downloads.openwrt.org"
            return 1
        }
    fi
    log_info "Download complete."
    return 0
}

# ---------------------------------------------------------------------------
extract() {
    # shellcheck disable=SC2012
    local archive
    # shellcheck disable=SC2012
    archive=$(ls -t "${BUILD_DIR}"/openwrt-imagebuilder-*.tar.* 2>/dev/null | head -1)

    if [ -z "${archive}" ]; then
        log_error "No archive found in ${BUILD_DIR}"
        return 1
    fi

    local extract_dir
    extract_dir=$(basename "${archive}" .tar.zst)
    extract_dir=$(basename "${extract_dir}" .tar.xz)
    extract_dir="${BUILD_DIR}/${extract_dir}"

    if [ -d "${extract_dir}" ]; then
        log_info "Already extracted: ${extract_dir}"
        return
    fi

    log_info "Extracting ${archive}..."
    if [[ "${archive}" == *.zst ]]; then
        tar --zstd -xf "${archive}" -C "${BUILD_DIR}"
    elif [[ "${archive}" == *.xz ]]; then
        tar -xJf "${archive}" -C "${BUILD_DIR}"
    else
        log_error "Unknown archive format: ${archive}"
        return 1
    fi
    log_info "Extraction complete."
    echo "  Builder ready at: ${extract_dir}"
    return 0
}

# ---------------------------------------------------------------------------
main() {
    echo "==============================================="
    echo " OpenWRT Image Builder Setup"
    echo " Version: ${OPENWRT_VERSION}"
    echo " Target: ${TARGET}/${SUBTARGET}"
    echo "==============================================="
    echo ""

    check_deps || exit 1
    download || exit 1
    extract || exit 1

    echo ""
    log_info "Setup complete!"
    echo "  Next: ./scripts/build/openwrt.sh"
}

# Allow running standalone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
