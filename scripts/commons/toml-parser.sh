#!/usr/bin/env bash
# ============================================================================
# toml-parser.sh — TOML package list parser
# ============================================================================
# Provides:
#   parse_packages_toml() — converts config/openwrt-packages.toml → space-separated list
# ============================================================================
set -euo pipefail

# Usar nombre privado para no sobreescribir SCRIPT_DIR del script que hace source
# shellcheck disable=SC2128
_TOML_PARSER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# parse_packages_toml <toml_file>
# Parses config/openwrt-packages.toml and outputs space-separated package list.
# Uses Python helper for reliable TOML parsing.
# ---------------------------------------------------------------------------
parse_packages_toml() {
    local toml_file="$1"

    if [ ! -f "${toml_file}" ]; then
        return 1
    fi

    # Check Python availability
    if ! command -v python3 &>/dev/null; then
        echo "ERROR: python3 is required to parse TOML package config" >&2
        return 1
    fi

    # Parse TOML using Python helper
    local parser="${_TOML_PARSER_DIR}/toml_parser.py"
    if [ ! -f "${parser}" ]; then
        echo "ERROR: TOML parser not found at ${parser}" >&2
        return 1
    fi

    python3 "${parser}" "${toml_file}"
}

# ---------------------------------------------------------------------------
# convert_toml_to_txt <toml_file> <txt_output>
# Reads TOML file and writes legacy .txt format.
# ---------------------------------------------------------------------------
convert_toml_to_txt() {
    local toml_file="$1"
    local txt_output="$2"

    local packages
    packages=$(parse_packages_toml "${toml_file}") || return 1

    {
        echo "# AUTO-GENERATED — DO NOT EDIT"
        echo "# Generated from: $(basename "${toml_file}")"
        echo "# Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo ""
        # Split into individual lines for readability
        for pkg in ${packages}; do
            echo "${pkg}"
        done
    } > "${txt_output}"
}
