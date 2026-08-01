#!/usr/bin/env bash
# ============================================================================
# secrets.sh — Centralized secrets handling (decrypt, cleanup, preflight)
# ============================================================================
set -euo pipefail

COMMONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${COMMONS_DIR}/logging.sh"

DEFAULT_KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"

# ---------------------------------------------------------------------------
# check_sops_binary — verifica que sops esté instalado y sea un binario
# ---------------------------------------------------------------------------
check_sops_binary() {
    if ! command -v sops &>/dev/null; then
        log_error "'sops' no encontrado en PATH"
        echo "   Solución: just install-tools"
        return 1
    fi
    local spath
    spath="$(command -v sops)"
    if file "${spath}" 2>/dev/null | grep -qi 'text'; then
        log_error "'sops' en ${spath} no es un binario válido (texto/HTML)"
        echo "   Solución: just install-tools force=true"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# check_age_key — verifica que exista la clave age privada
# ---------------------------------------------------------------------------
check_age_key() {
    local keyfile="${1:-${DEFAULT_KEYFILE}}"
    if [ ! -f "${keyfile}" ]; then
        log_error "Clave age no encontrada: ${keyfile}"
        echo "   Solución: just generate-age-key"
        return 1
    fi
    export SOPS_AGE_KEY_FILE="${keyfile}"
}

# ---------------------------------------------------------------------------
# decrypt_secrets — descifra secrets en un archivo temporal seguro
#
# Uso:
#   SECRETS_TMP=$(decrypt_secrets prod)
#   echo "Secrets en: ${SECRETS_TMP}"
#
# El archivo temporal se crea con umask 077 (permisos 600).
# El caller DEBE llamar a cleanup_secrets al terminar.
# ---------------------------------------------------------------------------
SECRETS_TMP_FILE=""

decrypt_secrets() {
    local env="${1:-prod}"
    local keyfile="${2:-${DEFAULT_KEYFILE}}"
    local secrets_enc="environments/${env}/secrets.enc.yaml"
    local repo_root

    repo_root="$(git -C "${COMMONS_DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "${repo_root}" ]; then
        repo_root="$(cd "${COMMONS_DIR}/../.." && pwd)"
    fi

    local full_path="${repo_root}/${secrets_enc}"

    check_sops_binary || return 2
    check_age_key "${keyfile}" || return 2

    if [ ! -f "${full_path}" ]; then
        log_error "Archivo de secrets no encontrado: ${full_path}"
        echo "   Solución: just create-environments"
        return 2
    fi

    SECRETS_TMP_FILE="$(mktemp /tmp/secrets-${env}-XXXXXX.yaml)"
    chmod 600 "${SECRETS_TMP_FILE}"

    if ! sops -d "${full_path}" > "${SECRETS_TMP_FILE}" 2>/dev/null; then
        rm -f "${SECRETS_TMP_FILE}"
        SECRETS_TMP_FILE=""
        log_warn "No se pudo descifrar secrets con la clave actual"
        echo "   Clave usada: ${keyfile}"
        echo "   Solución: just reinit-secrets ${env}"
        return 2
    fi

    echo "${SECRETS_TMP_FILE}"
}

# ---------------------------------------------------------------------------
# cleanup_secrets — elimina el archivo temporal de secrets
# Pensado para ser usado con trap: trap cleanup_secrets EXIT
# ---------------------------------------------------------------------------
cleanup_secrets() {
    if [ -n "${SECRETS_TMP_FILE:-}" ] && [ -f "${SECRETS_TMP_FILE}" ]; then
        rm -f "${SECRETS_TMP_FILE}"
        SECRETS_TMP_FILE=""
    fi
}

# ---------------------------------------------------------------------------
# get_secret_value — lee un valor individual del YAML descifrado
# Uso: val=$(get_secret_value "WIFI_KEY_24" "${SECRETS_TMP}")
# ---------------------------------------------------------------------------
get_secret_value() {
    local key="$1"
    local secrets_file="$2"
    yq eval -r ".\"${key}\" // \"\"" "${secrets_file}"
}

# ---------------------------------------------------------------------------
# report_empty_fields — imprime qué campos están vacíos
# ---------------------------------------------------------------------------
report_empty_fields() {
    local secrets_file="$1"
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
    done < <(grep -v '^sops:' "${secrets_file}" | grep ':' || true)

    if [ ${#configured[@]} -gt 0 ]; then
        log_info "Secrets configurados: ${configured[*]}"
    fi

    if [ ${#empty[@]} -gt 0 ]; then
        echo "   ℹ️  Vacíos (no se configurarán): ${empty[*]}"
    fi
}
