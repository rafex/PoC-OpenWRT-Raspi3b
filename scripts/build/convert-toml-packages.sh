#!/usr/bin/env bash
# ============================================================================
# convert-toml-packages.sh — Convert TOML package config to legacy TXT format
# ============================================================================
# Usage:
#   ./convert-toml-packages.sh [--toml <file>] [--output <file>]
#
# Options:
#   --toml FILE    TOML config file (default: config/openwrt-packages.toml)
#   --output FILE  Output TXT file (default: stdout)
#   --help, -h     Show this help
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source TOML parser
source "${SCRIPT_DIR}/../commons/toml-parser.sh"

TOML_FILE="${REPO_ROOT}/config/openwrt-packages.toml"
OUTPUT_FILE=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Converts config/openwrt-packages.toml to legacy .txt format.

Options:
  --toml FILE     TOML config file (default: config/openwrt-packages.toml)
  --output FILE   Output TXT file (default: stdout)
  --help, -h      Show this help
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --toml)   TOML_FILE="$2"; shift 2 ;;
            --output) OUTPUT_FILE="$2"; shift 2 ;;
            --help|-h) usage; exit 0 ;;
            *) echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [ ! -f "${TOML_FILE}" ]; then
        echo "ERROR: TOML file not found: ${TOML_FILE}" >&2
        exit 1
    fi

    if [ -n "${OUTPUT_FILE}" ]; then
        convert_toml_to_txt "${TOML_FILE}" "${OUTPUT_FILE}"
        echo "Generated: ${OUTPUT_FILE}"
    else
        parse_packages_toml "${TOML_FILE}"
    fi
}

main "$@"
