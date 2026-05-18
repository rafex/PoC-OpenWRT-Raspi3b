#!/usr/bin/env bash
# ============================================================================
# setup-auth.sh — Configura autenticación SSH y contraseña root en OpenWRT
#
# Qué hace:
#   1. Copia la clave SSH pública local a /etc/dropbear/authorized_keys
#      en el router (evita duplicados)
#   2. Establece contraseña para root (sesión interactiva via SSH)
#
# ⚠️  IMPORTANTE: ejecutar antes de establecer contraseña para no bloquearse.
#     Si solo se setea contraseña sin copiar la clave, el acceso posterior
#     requiere escribir la contraseña en cada conexión.
#
# Uso:
#   scripts/build/setup-auth.sh [--ip <IP>] [--env <env>] [--key <path>]
#
# Opciones:
#   --ip <IP>      IP del router (default: ROUTER_IP de .env.public o 192.168.1.1)
#   --env <env>    Entorno para leer .env.public (default: prod)
#   --key <path>   Ruta a clave pública SSH (default: auto-detectar ~/.ssh/id_*.pub)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
_ENV="prod"
_CLI_IP=""
_KEY=""

# ---------------------------------------------------------------------------
# Parsear argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)
            _CLI_IP="${2:?--ip requiere un argumento}"
            shift 2
            ;;
        --env)
            _ENV="${2:?--env requiere un argumento}"
            shift 2
            ;;
        --key)
            _KEY="${2:?--key requiere un argumento}"
            shift 2
            ;;
        -h|--help)
            echo "Uso: $0 [--ip <IP>] [--env <env>] [--key <path>]"
            echo ""
            echo "  --ip <IP>     IP del router (default: ROUTER_IP de .env.public o 192.168.1.1)"
            echo "  --env         Entorno para leer .env.public (default: prod)"
            echo "  --key <path>  Ruta a clave pública SSH (default: auto-detectar)"
            exit 0
            ;;
        *)
            log_error "Argumento desconocido: $1"
            echo "   Uso: $0 [--ip <IP>] [--env <env>] [--key <path>]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Cargar variables del entorno
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a
fi

ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# Helper SSH (sin BatchMode: primer arranque no tiene contraseña)
# ---------------------------------------------------------------------------
_ssh() {
    ssh -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

# ---------------------------------------------------------------------------
# Verificar conectividad SSH
# ---------------------------------------------------------------------------
_check_ssh() {
    log_step "Verificando conectividad SSH con el router..."
    if ! ssh -q -p "${SSH_PORT}" \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -o BatchMode=yes \
            "root@${ROUTER_IP}" "exit" 2>/dev/null; then
        log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
        echo ""
        echo "   Verifica:"
        echo "   • El router está encendido y conectado por cable Ethernet"
        echo "   • La IP es correcta (usa --ip <IP>)"
        echo "   • SSH está habilitado en el router"
        echo "   • Si ya tiene contraseña, SSH con clave debe funcionar"
        exit 1
    fi
    log_info "✅ Conectado a root@${ROUTER_IP}"
}

# ---------------------------------------------------------------------------
# Auto-detectar clave SSH pública
# ---------------------------------------------------------------------------
_find_ssh_key() {
    if [ -n "${_KEY}" ]; then
        if [ ! -f "${_KEY}" ]; then
            log_error "Clave no encontrada: ${_KEY}"
            exit 1
        fi
        echo "${_KEY}"
        return
    fi

    for key in ~/.ssh/id_ed25519.pub ~/.ssh/id_ecdsa.pub ~/.ssh/id_rsa.pub; do
        if [ -f "${key}" ]; then
            echo "${key}"
            return
        fi
    done

    log_error "No se encontró clave SSH pública en ~/.ssh/"
    echo ""
    echo "   Genera una con:"
    echo "   ssh-keygen -t ed25519 -C \"$(whoami)@$(hostname)\""
    exit 1
}

# ---------------------------------------------------------------------------
# Copiar clave SSH al router (evita duplicados)
# ---------------------------------------------------------------------------
_copy_ssh_key() {
    local key_file="$1"
    local pub_key
    pub_key=$(cat "${key_file}")

    log_step "Copiando clave SSH al router..."
    log_info "   Clave: ${key_file}"

    # Inyectar clave en heredoc (expansión local), verificar duplicados en router
    _ssh sh - <<REMOTE
set -eu
KEY="${pub_key}"
AUTHKEYS="/etc/dropbear/authorized_keys"
mkdir -p /etc/dropbear
chmod 700 /etc/dropbear
if [ -f "\${AUTHKEYS}" ] && grep -qF "\${KEY}" "\${AUTHKEYS}" 2>/dev/null; then
    echo "      ℹ️  Clave ya presente en \${AUTHKEYS}"
else
    echo "\${KEY}" >> "\${AUTHKEYS}"
    chmod 600 "\${AUTHKEYS}"
    echo "      ✅ Clave copiada a \${AUTHKEYS}"
fi
REMOTE
}

# ---------------------------------------------------------------------------
# Establecer contraseña root (sesión interactiva)
# ---------------------------------------------------------------------------
_set_password() {
    log_step "Estableciendo contraseña root..."
    echo ""
    echo "   Se abrirá una sesión interactiva. Escribe la nueva contraseña dos veces."
    echo "   (La contraseña no se muestra al escribir)"
    echo ""

    # -t fuerza asignación de PTY para que passwd pueda leer del terminal
    ssh -t -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" passwd

    log_info "✅ Contraseña establecida"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "==============================================="
    echo " OpenWRT — Autenticación SSH + Contraseña Root"
    echo "==============================================="
    echo ""

    _check_ssh

    local key_file
    key_file=$(_find_ssh_key)

    echo ""
    log_step "Resumen:"
    echo "   Router:  root@${ROUTER_IP}:${SSH_PORT}"
    echo "   Clave:   ${key_file}"
    echo ""
    echo "   Pasos:"
    echo "   1. Copiar clave SSH al router"
    echo "   2. Establecer contraseña root (interactivo)"
    echo ""
    read -r -p "¿Continuar? (s/N) " answer
    answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
    if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi

    echo ""
    _copy_ssh_key "${key_file}"

    echo ""
    _set_password

    echo ""
    log_info "✅ Autenticación configurada:"
    echo "   • Clave SSH: acceso sin contraseña desde esta máquina"
    echo "   • Contraseña root: establecida para acceso por consola o en otras máquinas"
    echo ""
    echo "   Verificar acceso con clave:"
    echo "   ssh root@${ROUTER_IP}"
}

main "$@"
