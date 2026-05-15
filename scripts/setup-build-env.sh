#!/usr/bin/env bash
# ============================================================================
# setup-build-env.sh — Prepare OpenWRT Image Builder environment
# ============================================================================
# Downloads and extracts the OpenWRT Image Builder for ath79/generic.
#
# Usage: ./scripts/setup-build-env.sh [--version 25.12.2]
#
set -euo pipefail

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.2}"
TARGET="${TARGET:-ath79}"
SUBTARGET="${SUBTARGET:-generic}"
BUILD_DIR="${BUILD_DIR:-$(pwd)/openwrt-builder}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Check dependencies
# ---------------------------------------------------------------------------
check_deps() {
    log_info "Checking required dependencies..."
    
    DEPS=("wget" "make" "gcc" "g++" "awk" "find" "tar" "unzip" "file")
    if command -v zstd &>/dev/null; then
        : # zstd available
    elif command -v unzstd &>/dev/null; then
        : # unzstd available
    else
        DEPS+=("zstd")
    fi
    
    MISSING=()
    for dep in "${DEPS[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            MISSING+=("${dep}")
        fi
    done
    
    if [ ${#MISSING[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${MISSING[*]}"
        echo ""
        echo "Install them with:"
        echo "  Debian/Ubuntu: sudo apt-get install ${MISSING[*]} build-essential libncurses-dev zstd"
        echo "  macOS (Homebrew): brew install ${MISSING[*]} coreutils zstd"
        echo "  Fedora: sudo dnf install ${MISSING[*]} make automake gcc gcc-c++ ncurses-devel zstd"
        exit 1
    fi
    log_info "All dependencies found."
}

# ---------------------------------------------------------------------------
# Download Image Builder
# ---------------------------------------------------------------------------
download_builder() {
    local url="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${SUBTARGET}/openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET}-${SUBTARGET}.Linux-x86_64.tar.zst"
    
    # Alternative: try .tar.xz if .tar.zst doesn't exist
    local filename
    filename=$(basename "${url}")
    local dest="${BUILD_DIR}/${filename}"
    
    mkdir -p "${BUILD_DIR}"
    
    if [ -f "${dest}" ]; then
        log_info "Image Builder already downloaded: ${dest}"
        echo "       Remove ${dest} to re-download."
    else
        log_info "Downloading Image Builder..."
        log_info "URL: ${url}"
        
        if ! wget -q --show-progress -O "${dest}" "${url}" 2>&1; then
            # Try .tar.xz as fallback
            url="${url%.tar.zst}.tar.xz"
            filename=$(basename "${url}")
            dest="${BUILD_DIR}/${filename}"
            log_warn ".tar.zst not found, trying .tar.xz..."
            log_info "URL: ${url}"
            wget -q --show-progress -O "${dest}" "${url}" || {
                log_error "Download failed."
                log_error "Check that version ${OPENWRT_VERSION} exists at downloads.openwrt.org"
                exit 1
            }
        fi
        log_info "Download complete: ${dest}"
    fi
}

# ---------------------------------------------------------------------------
# Extract Image Builder
# ---------------------------------------------------------------------------
extract_builder() {
    local archive
    # shellcheck disable=SC2012
    archive=$(ls -t "${BUILD_DIR}"/openwrt-imagebuilder-*.tar.* 2>/dev/null | head -1)

    if [ -z "${archive}" ]; then
        log_error "No Image Builder archive found in ${BUILD_DIR}"
        exit 1
    fi
    
    local extract_dir
    extract_dir=$(basename "${archive}" .tar.zst)
    extract_dir=$(basename "${extract_dir}" .tar.xz)
    extract_dir="${BUILD_DIR}/${extract_dir}"
    
    if [ -d "${extract_dir}" ]; then
        log_info "Image Builder already extracted: ${extract_dir}"
    else
        log_info "Extracting ${archive}..."
        if [[ "${archive}" == *.zst ]]; then
            tar --zstd -xf "${archive}" -C "${BUILD_DIR}"
        elif [[ "${archive}" == *.xz ]]; then
            tar -xJf "${archive}" -C "${BUILD_DIR}"
        else
            log_error "Unknown archive format: ${archive}"
            exit 1
        fi
        log_info "Extraction complete."
    fi
    
    # Verify extraction
    if [ -f "${extract_dir}/.targetinfo" ] || [ -f "${extract_dir}/Makefile" ]; then
        log_info "Image Builder ready at: ${extract_dir}"
        echo ""
        echo "Next step: cd ${extract_dir} && make info"
    else
        log_error "Extraction appears incomplete. Check ${extract_dir}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "==============================================="
    echo " OpenWRT Image Builder Setup"
    echo " Version: ${OPENWRT_VERSION}"
    echo " Target: ${TARGET}/${SUBTARGET}"
    echo " Build Dir: ${BUILD_DIR}"
    echo "==============================================="
    echo ""
    
    # Parse CLI args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) OPENWRT_VERSION="$2"; shift 2 ;;
            --target)  TARGET="$2"; shift 2 ;;
            --dir)     BUILD_DIR="$2"; shift 2 ;;
            *) log_warn "Unknown option: $1"; shift ;;
        esac
    done
    
    check_deps
    download_builder
    extract_builder
    
    echo ""
    log_info "Setup complete!"
    echo ""
    echo "Run the build script:"
    echo "  ./build-openwrt.sh --builder ${BUILD_DIR}/openwrt-imagebuilder-*"
}

main "$@"
