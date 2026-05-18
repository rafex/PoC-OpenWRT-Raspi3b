#!/usr/bin/env bash
# ============================================================================
# reboot.sh — Reinicia el router OpenWRT via SSH
#
# Uso:
#   reboot.sh [--ip <IP>] [--env <env>] [--wait]
#
# Opciones:
#   --ip <IP>   IP del router (default: env o 192.168.1.1)
#   --env <env> Entorno (default: prod)
#   --wait      Espera a que el router vuelva a estar disponible (~60s)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

_ENV="prod"
_CLI_IP=""
_WAIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)    _CLI_IP="${2:?}"; shift 2 ;;
        --env)   _ENV="${2:?}";    shift 2 ;;
        --wait)  _WAIT=true;       shift ;;
        -h|--help)
            echo "Uso: reboot.sh [--ip <IP>] [--env <env>] [--wait]"
            echo "  --wait  Espera hasta que el router vuelva a responder SSH"
            exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
    esac
done

ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }
ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"

_ssh() {
    ssh -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

# Verificar conectividad
if ! ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
    log_error "No se puede conectar a root@${ROUTER_IP}:${SSH_PORT}"
    exit 1
fi

log_step "Reiniciando router ${ROUTER_IP}..."
_ssh reboot 2>/dev/null || true   # reboot corta la conexión, exit code != 0 es esperado

echo ""
log_info "Comando de reboot enviado."

if [ "${_WAIT}" = "true" ]; then
    echo ""
    log_step "Esperando a que el router vuelva a estar disponible..."
    sleep 20   # margen para que arranque el proceso de reboot

    local_timeout=90
    elapsed=0
    while [ "${elapsed}" -lt "${local_timeout}" ]; do
        if ssh -q -p "${SSH_PORT}" -o ConnectTimeout=3 -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
            echo ""
            log_info "✅ Router disponible en ${ROUTER_IP} (${elapsed}s)"
            exit 0
        fi
        printf "."
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo ""
    log_warn "El router no respondió en ${local_timeout}s — puede que tarde más en arrancar."
else
    log_info "Usa --wait para esperar a que vuelva a estar disponible."
fi
