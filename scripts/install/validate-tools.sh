#!/usr/bin/env bash
# ============================================================================
# validate-tools.sh — Validar herramientas requeridas para el proyecto
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# Herramientas requeridas por el proyecto
REQUIRED_TOOLS=("just" "make" "sops" "age" "shellcheck" "wget" "yq" "python3")

# ---------------------------------------------------------------------------
# Validar herramienta individual
# ---------------------------------------------------------------------------
validate_tool() {
    local tool=$1

    if command -v "${tool}" &>/dev/null; then
        case "${tool}" in
            just)
                version=$(just --version 2>/dev/null | cut -d' ' -f2)
                log_info "  ✅ ${tool} ${version}"
                ;;
            make)
                version=$(make --version 2>/dev/null | head -1 | cut -d' ' -f3-)
                log_info "  ✅ ${tool} ${version}"
                ;;
            sops|age|shellcheck|wget|yq|python3)
                version=$(${tool} --version 2>/dev/null | head -1)
                log_info "  ✅ ${tool} — ${version}"
                ;;
            *)
                log_info "  ✅ ${tool}"
                ;;
        esac
        return 0
    else
        log_warn "  ❌ ${tool} (NO INSTALADA)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Validar todas las herramientas
# ---------------------------------------------------------------------------
validate_all_tools() {
    log_step "Validando herramientas requeridas..."
    echo ""

    local missing=()
    local all_ok=true

    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! validate_tool "${tool}"; then
            missing+=("${tool}")
            all_ok=false
        fi
    done

    echo ""

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Herramientas faltantes: ${missing[*]}"
        echo ""
        echo "📦 Instala con:"
        echo ""

        case "$(uname -s)" in
            Darwin)
                echo "  brew install ${missing[*]}"
                ;;
            Linux)
                echo "  sudo apt-get update && sudo apt-get install -y ${missing[*]}"
                ;;
            *)
                echo "  Consulta: https://github.com/rafex/PoC-OpenWRT-Raspi3b#quick-start"
                ;;
        esac

        echo ""
        return 1
    fi

    log_info "✅ Todas las herramientas requeridas están instaladas"
    return 0
}

# ---------------------------------------------------------------------------
# Allow running standalone
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate_all_tools "$@"
fi
