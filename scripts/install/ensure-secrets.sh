#!/usr/bin/env bash
# ============================================================================
# ensure-secrets.sh — Garantiza disponibilidad de secrets para el build
#
# Flujo:
#   1. Si no existe la clave age → crearla + guiar al usuario a llenar secrets
#   2. Si existe pero no descifra → informar que la clave no corresponde
#   3. Si descifra → reportar campos vacíos (no son error) y exportar variables
#
# Uso: source scripts/install/ensure-secrets.sh <ENV>
#      O ejecutado directamente para verificar.
#
# Salida:
#   - /tmp/secrets-<ENV>.yaml con los valores descifrados
#   - Exit 0: secrets listos (pueden haber campos vacíos)
#   - Exit 1: requiere acción del usuario
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

ENV="${1:-prod}"
KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"
SECRETS_FILE="environments/${ENV}/secrets.enc.yaml"
OUTPUT_FILE="/tmp/secrets-${ENV}.yaml"
export SOPS_AGE_KEY_FILE="${KEYFILE}"

# ---------------------------------------------------------------------------
# Verificar herramientas requeridas
# ---------------------------------------------------------------------------
_check_tools() {
    for tool in sops age age-keygen yq; do
        if ! command -v "${tool}" &>/dev/null; then
            log_error "Herramienta requerida no encontrada: ${tool}"
            echo "   Solución: just install-tools"
            return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Crear clave age si no existe
# ---------------------------------------------------------------------------
_ensure_age_key() {
    if [ -f "${KEYFILE}" ]; then
        return 0
    fi

    echo ""
    log_warn "Clave age no encontrada: ${KEYFILE}"
    echo "   Creando clave nueva para este proyecto..."
    echo ""

    mkdir -p "$(dirname "${KEYFILE}")"
    age-keygen -o "${KEYFILE}" 2>/dev/null
    chmod 600 "${KEYFILE}"

    # Actualizar clave pública en el repo
    grep "public key" "${KEYFILE}" | awk '{print $3}' > .age-pubkey.txt
    chmod 644 .age-pubkey.txt

    log_info "✅ Clave generada: ${KEYFILE}"
    log_info "✅ Clave pública actualizada: .age-pubkey.txt"
    echo ""
    log_warn "⚠️  Los secrets existentes fueron encriptados con otra clave."
    echo "   Debes re-encriptar el archivo con tu nueva clave y llenar los datos:"
    echo ""
    echo "   just edit-secrets ${ENV}"
    echo ""
    echo "   Una vez llenados, vuelve a ejecutar el build."
    return 1
}

# ---------------------------------------------------------------------------
# Intentar descifrar secrets
# ---------------------------------------------------------------------------
_decrypt_secrets() {
    if [ ! -f "${SECRETS_FILE}" ]; then
        log_error "Archivo de secrets no encontrado: ${SECRETS_FILE}"
        echo "   Solución: just create-environments"
        return 1
    fi

    if ! sops -d "${SECRETS_FILE}" > "${OUTPUT_FILE}" 2>/dev/null; then
        echo ""
        log_warn "No se pudo descifrar los secrets con la clave actual."
        echo "   Clave usada: ${KEYFILE}"
        echo ""
        echo "   Causas posibles:"
        echo "   • El archivo fue encriptado con una clave diferente"
        echo "   • La clave privada está incompleta o corrupta"
        echo ""
        echo "   Opciones:"
        echo "   a) Re-inicializar secrets con tu clave local (recomendado):"
        echo "      just reinit-secrets ${ENV}"
        echo ""
        echo "   b) Si tienes acceso a la clave original, colócala en:"
        echo "      ${KEYFILE}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Reportar campos vacíos (no es error — se omiten en la compilación)
# ---------------------------------------------------------------------------
_report_empty_fields() {
    local empty=()
    local configured=()

    while IFS= read -r line; do
        local key value
        key=$(echo "${line}" | cut -d: -f1 | tr -d ' ')
        value=$(echo "${line}" | cut -d: -f2- | tr -d ' "')
        if [ -z "${value}" ]; then
            empty+=("${key}")
        else
            configured+=("${key}")
        fi
    done < <(grep -v '^sops:' "${OUTPUT_FILE}" | grep ':' || true)

    if [ ${#configured[@]} -gt 0 ]; then
        log_info "Secrets configurados: ${configured[*]}"
    fi

    if [ ${#empty[@]} -gt 0 ]; then
        echo "   ℹ️  Vacíos (no se configurarán): ${empty[*]}"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_step "Verificando secrets para entorno: ${ENV}"
    echo ""

    _check_tools || exit 1
    _ensure_age_key || exit 1
    _decrypt_secrets || exit 1

    log_info "✅ Secrets disponibles: ${OUTPUT_FILE}"
    _report_empty_fields
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
