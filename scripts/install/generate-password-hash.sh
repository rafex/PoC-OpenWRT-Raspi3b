#!/usr/bin/env bash
# ============================================================================
# generate-password-hash.sh — Genera el hash SHA-512 de la contraseña root
#
# Uso:
#   scripts/install/generate-password-hash.sh
#
# Interactivo: pide la contraseña en modo oculto, la confirma, y genera
# el hash $6$ (SHA-512-crypt) compatible con /etc/shadow de OpenWRT.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# ---------------------------------------------------------------------------
# Detectar el método disponible para generar hash SHA-512
# ---------------------------------------------------------------------------
_find_openssl() {
    # Prioridad: openssl del sistema → brew ARM → brew Intel
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
    # Método 1: openssl con soporte -6
    if OPENSSL=$(_find_openssl 2>/dev/null); then
        echo "openssl:${OPENSSL}"
        return 0
    fi

    # Método 2: python3 con módulo crypt (Linux con glibc)
    if python3 -c "
import crypt, sys
h = crypt.crypt('test', crypt.mksalt(crypt.METHOD_SHA512))
sys.exit(0 if h.startswith('\$6\$') else 1)
" 2>/dev/null; then
        echo "python3"
        return 0
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Generar hash con el método detectado
# ---------------------------------------------------------------------------
_generate_hash() {
    local password="$1"
    local method="$2"

    if [[ "$method" == openssl:* ]]; then
        local openssl_bin="${method#openssl:}"
        "$openssl_bin" passwd -6 "$password"
    elif [[ "$method" == "python3" ]]; then
        python3 -c "
import crypt
print(crypt.crypt('${password//\'/\\\'}', crypt.mksalt(crypt.METHOD_SHA512)))
"
    fi
}

# ---------------------------------------------------------------------------
# Pedir contraseña en modo oculto con confirmación
# ---------------------------------------------------------------------------
_read_password() {
    local password confirm

    while true; do
        read -r -s -p "  Contraseña: " password
        echo ""

        if [ -z "$password" ]; then
            echo "  ⚠️  La contraseña no puede estar vacía. Intenta de nuevo."
            continue
        fi

        if [ ${#password} -lt 8 ]; then
            echo "  ⚠️  La contraseña debe tener al menos 8 caracteres."
            continue
        fi

        read -r -s -p "  Confirmar:  " confirm
        echo ""

        if [ "$password" != "$confirm" ]; then
            echo "  ❌ Las contraseñas no coinciden. Intenta de nuevo."
            echo ""
            continue
        fi

        echo "$password"
        return 0
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    log_step "Generador de hash de contraseña root para OpenWRT"
    echo ""
    echo "  El hash generado ($6\$...) se puede usar como ROOT_PASSWORD_HASH"
    echo "  en: just edit-secrets <env>"
    echo ""

    # Detectar método de hash
    local method
    if ! method=$(_find_hash_method); then
        log_error "No se encontró una herramienta para generar hash SHA-512."
        echo ""
        echo "  Opciones:"
        echo "  macOS: brew install openssl"
        echo "         (el openssl del sistema no soporta SHA-512)"
        echo ""
        echo "  Linux: disponible de forma nativa (python3 -c 'import crypt')"
        exit 1
    fi

    local method_label
    case "$method" in
        openssl:*) method_label="openssl $(${method#openssl:} version 2>/dev/null | cut -d' ' -f2)" ;;
        python3)   method_label="python3 crypt (glibc)" ;;
    esac
    log_info "Método: ${method_label}"
    echo ""

    # Leer contraseña
    local password
    password=$(_read_password)
    echo ""

    # Generar hash
    local hash
    hash=$(_generate_hash "$password" "$method")

    # Mostrar resultado
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────┐"
    echo "  │ Hash SHA-512 generado:                                      │"
    echo "  └─────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ${hash}"
    echo ""
    log_info "Copia este hash en ROOT_PASSWORD_HASH al editar tus secrets:"
    echo ""
    echo "    just edit-secrets dev   # o prod"
    echo ""
}

main "$@"
