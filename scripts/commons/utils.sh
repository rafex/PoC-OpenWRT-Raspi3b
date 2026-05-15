#!/usr/bin/env bash
# ============================================================================
# utils.sh — Utility functions shared across build scripts
# ============================================================================
# Source this file in other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../commons/utils.sh"
# ============================================================================

# ---------------------------------------------------------------------------
# Find the Image Builder directory
# ---------------------------------------------------------------------------
find_builder() {
    local builder_dir="${1:-}"

    if [ -n "${builder_dir}" ] && [ -d "${builder_dir}" ]; then
        echo "${builder_dir}"
        return
    fi

    local candidates=(
        "${builder_dir}"
        "${REPO_ROOT}/openwrt-builder/openwrt-imagebuilder-"*
        "${REPO_ROOT}/../openwrt-imagebuilder-"*
        "${REPO_ROOT}/openwrt-imagebuilder-"*
    )

    for candidate in "${candidates[@]}"; do
        if [ -d "${candidate}" ] && [ -f "${candidate}/Makefile" ]; then
            echo "${candidate}"
            return
        fi
    done

    return 1
}

# ---------------------------------------------------------------------------
# Parse packages file into PACKAGES variable
# ---------------------------------------------------------------------------
parse_packages() {
    local packages_file="$1"

    if [ ! -f "${packages_file}" ]; then
        return 1
    fi

    grep -v '^\s*#' "${packages_file}" | grep -v '^\s*$' | tr '\n' ' ' | sed 's/\s\+/ /g' | xargs
}

# ---------------------------------------------------------------------------
# Get repo root directory
# ---------------------------------------------------------------------------
get_repo_root() {
    git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || \
        cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
}
