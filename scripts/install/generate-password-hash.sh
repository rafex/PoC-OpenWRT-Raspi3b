#!/usr/bin/env bash
# ============================================================================
# generate-password-hash.sh — Genera hash SHA-512 de root e inyecta en secrets
#
# Uso:
#   scripts/install/generate-password-hash.sh <ENV>
#   ENV: dev | prod  (requerido)
#
# Pide la contraseña en modo oculto, genera el hash $6$ (SHA-512-crypt)
# compatible con /etc/shadow de OpenWRT, y lo guarda directamente en
# environments/<ENV>/secrets.enc.yaml sin mostrarlo en pantalla.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

ENV="${1:-}"
KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"
export SOPS_AGE_KEY_FILE="${KEYFILE}"

# ---------------------------------------------------------------------------
# Verificar argumento ENV
# ---------------------------------------------------------------------------
_check_env() {
    if [ -z "${ENV}" ]; then
        log_error "Debes indicar el entorno: just create-password dev  o  just create-password prod"
        exit 1
    fi
    if [ "${ENV}" != "dev" ] && [ "${ENV}" != "prod" ]; then
        log_error "Entorno inválido: '${ENV}'. Usa 'dev' o 'prod'."
        exit 1
    fi
    local secrets_file="environments/${ENV}/secrets.enc.yaml"
    if [ ! -f "${secrets_file}" ]; then
        log_error "Archivo de secrets no encontrado: ${secrets_file}"
        echo "   Solución: just create-environments"
        exit 1
    fi
    if [ ! -f "${KEYFILE}" ]; then
        log_error "Clave age no encontrada: ${KEYFILE}"
        echo "   Solución: just generate-age-key"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Detectar herramienta para generar hash SHA-512-crypt
# ---------------------------------------------------------------------------
_find_openssl_with_sha512() {
    for candidate in \
        "openssl" \
        "/opt/homebrew/opt/openssl/bin/openssl" \
        "/usr/local/opt/openssl/bin/openssl"
    do
        if command -v "$candidate" &>/dev/null 2>&1; then
            if "$candidate" passwd -6 '' &>/dev/null 2>&1; then
                echo "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

_find_hash_method() {
    if OPENSSL=$(_find_openssl_with_sha512 2>/dev/null); then
        echo "openssl:${OPENSSL}"
        return 0
    fi
    if python3 -c "
import crypt, sys
h = crypt.crypt('x', crypt.mksalt(crypt.METHOD_SHA512))
sys.exit(0 if h.startswith('\$6\$') else 1)
" 2>/dev/null; then
        echo "python3"
        return 0
    fi
    return 1
}

_generate_hash() {
    local password="$1"
    local method="$2"
    if [[ "$method" == openssl:* ]]; then
        "${method#openssl:}" passwd -6 "$password"
    elif [[ "$method" == "python3" ]]; then
        python3 - "$password" << 'PYEOF'
import crypt, sys
pw = sys.argv[1]
print(crypt.crypt(pw, crypt.mksalt(crypt.METHOD_SHA512)))
PYEOF
    fi
}

# ---------------------------------------------------------------------------
# Pedir contraseña en modo oculto con doble confirmación
# ---------------------------------------------------------------------------
_read_password() {
    local password confirm

    while true; do
        IFS= read -r -s -p "  Contraseña root: " password < /dev/tty
        printf '\n' > /dev/tty

        if [ -z "$password" ]; then
            printf '  ⚠️  La contraseña no puede estar vacía.\n' > /dev/tty
            continue
        fi

        if [ "${#password}" -lt 8 ]; then
            printf '  ⚠️  Mínimo 8 caracteres.\n' > /dev/tty
            continue
        fi

        IFS= read -r -s -p "  Confirmar:       " confirm < /dev/tty
        printf '\n' > /dev/tty

        if [ "$password" != "$confirm" ]; then
            printf '  ❌ No coinciden. Intenta de nuevo.\n\n' > /dev/tty
            continue
        fi

        printf '%s' "$password"
        return 0
    done
}

# ---------------------------------------------------------------------------
# Inyectar hash directamente en el archivo de secrets encriptado
# ---------------------------------------------------------------------------
_inject_hash() {
    local hash="$1"
    local secrets_file="environments/${ENV}/secrets.enc.yaml"

    sops set "${secrets_file}" '["ROOT_PASSWORD_HASH"]' "\"${hash}\""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    log_step "Generador de contraseña root — entorno: ${ENV}"
    echo ""

    _check_env

    # Detectar método de hash
    local method
    if ! method=$(_find_hash_method); then
        log_error "No se encontró herramienta para generar hash SHA-512."
        echo ""
        echo "  macOS: brew install openssl"
        echo "  Linux: disponible de forma nativa"
        exit 1
    fi

    # Leer contraseña (modo oculto)
    local password
    password=$(_read_password)
    echo ""

    # Generar hash (no se imprime)
    local hash
    hash=$(_generate_hash "$password" "$method")

    # Limpiar variable de contraseña en memoria
    password=""

    # Inyectar en secrets.enc.yaml directamente
    _inject_hash "$hash"

    # Limpiar variable de hash
    hash=""

    echo ""
    log_info "✅ ROOT_PASSWORD_HASH guardado en environments/${ENV}/secrets.enc.yaml"
    log_info "   El hash no se mostró en pantalla para evitar exposición accidental."
    echo ""
}

main "$@"
