#!/usr/bin/env bash
# ============================================================================
# ensure-secrets.sh — Garantiza disponibilidad de secrets para el build
#
# Flujo:
#   1. Si no existe la clave age → crearla + guiar al usuario a llenar secrets
#   2. Si existe pero no descifra → informar que la clave no corresponde
#   3. Si descifra → reportar campos vacíos (no son error)
#
# Uso:
#   source scripts/install/ensure-secrets.sh  # define funciones
#   SECRETS_TMP=$(ensure_secrets prod)        # descifra y devuelve ruta
#
# Salida:
#   - Ruta al archivo temporal con los valores descifrados (stdout)
#   - Exit 0: secrets listos (pueden haber campos vacíos)
#   - Exit 1: requiere acción del usuario
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"
source "${SCRIPT_DIR}/../commons/secrets.sh"

ENV="${1:-prod}"
KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"
SECRETS_FILE="environments/${ENV}/secrets.enc.yaml"

# ---------------------------------------------------------------------------
# Crear clave age si no existe (solo en modo interactivo)
# ---------------------------------------------------------------------------
_ensure_age_key() {
    if [ -f "${KEYFILE}" ]; then
        return 0
    fi

    echo ""
    log_warn "Clave age no encontrada: ${KEYFILE}"
    echo "   Creando clave nueva para este proyecto..."
    echo ""

    if ! command -v age-keygen &>/dev/null; then
        log_error "'age-keygen' no encontrado en PATH"
        echo "   Solución: just install-tools"
        return 1
    fi

    mkdir -p "$(dirname "${KEYFILE}")"
    age-keygen -o "${KEYFILE}" 2>/dev/null
    chmod 600 "${KEYFILE}"

    grep -oE 'age1[a-z0-9]+' "${KEYFILE}" | head -1 > .age-pubkey.txt
    chmod 644 .age-pubkey.txt

    log_info "✅ Clave generada: ${KEYFILE}"
    log_info "✅ Clave pública actualizada: .age-pubkey.txt"
    echo ""
    log_warn "⚠️  Los secrets existentes fueron encriptados con otra clave."
    echo "   Re-encripta con tu nueva clave y llena los datos:"
    echo ""
    echo "   just reinit-secrets ${ENV}"
    echo ""
    echo "   Una vez llenados, vuelve a ejecutar el build."
    return 1
}

# ---------------------------------------------------------------------------
# ensure_secrets — función principal (usada como sourced + llamada)
# ---------------------------------------------------------------------------
ensure_secrets() {
    local env="${1:-${ENV}}"

    # stdout is the function's machine-readable contract: only the temp path.
    # Keep progress output on stderr so command substitution remains safe.
    log_step "Verificando secrets para entorno: ${env}" >&2
    echo "" >&2

    check_sops_binary || return 1
    _ensure_age_key || return 1

    local secrets_tmp
    secrets_tmp=$(decrypt_secrets "${env}" "${KEYFILE}") || return 1

    log_info "✅ Secrets disponibles: ${secrets_tmp}" >&2
    report_empty_fields "${secrets_tmp}" >&2
    echo "" >&2

    echo "${secrets_tmp}"
}

# ---------------------------------------------------------------------------
# Ejecución directa
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_secrets "$@"
fi
