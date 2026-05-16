#!/usr/bin/env bash
# ============================================================================
# show-packages.sh — Display OpenWRT package configuration
# ============================================================================
# Reads config/openwrt-packages.toml and outputs a structured,
# readable terminal display with validation.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

TOML_FILE="${REPO_ROOT}/config/openwrt-packages.toml"

for arg in "$@"; do
    case "$arg" in
        --toml) shift; TOML_FILE="$1"; shift ;;
        --toml=*) TOML_FILE="${arg#*=}" ;;
    esac
done

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required" >&2
    exit 1
fi

exec python3 "${SCRIPT_DIR}/show-packages.py" --toml "${TOML_FILE}"
