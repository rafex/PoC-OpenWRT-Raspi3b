#!/usr/bin/env bash
# ============================================================================
# setup-logs.sh — Configura el buffer de logs en RAM en OpenWRT
#
# Configura syslog para usar un buffer circular de 64 KB en RAM.
# No requiere USB ni extroot.
#
# Qué hace:
#   1. Elimina cualquier log_file previo (USB/extroot) que pudiera existir
#   2. Establece log_size=64 (KB) en /etc/config/system
#   3. Reinicia el servicio de log
#   4. Muestra las últimas entradas con logread
#
# Uso:
#   scripts/router/setup-logs.sh [--ip <IP>] [--env <env>]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

_ENV="prod"
_CLI_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)  _CLI_IP="${2:?}"; shift 2 ;;
        --env) _ENV="${2:?}";    shift 2 ;;
        -h|--help)
            echo "Uso: setup-logs.sh [--ip <IP>] [--env <env>]"
            echo ""
            echo "  Configura un buffer circular de 64 KB en RAM para syslog."
            echo "  No requiere USB ni extroot."
            exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
    esac
done

ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }
ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"

_ssh() {
    ssh -q -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

if ! _ssh exit 2>/dev/null; then
    log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
    exit 1
fi

log_step "Configurando buffer de logs en RAM (64 KB)..."

_ssh sh - << 'REMOTE'
set -eu

# Eliminar log_file si existía de una configuración USB previa
uci -q delete system.@system[0].log_file  2>/dev/null || true
uci -q delete system.@system[0].log_proto 2>/dev/null || true
uci -q delete system.@system[0].log_ip    2>/dev/null || true
uci -q delete system.@system[0].log_port  2>/dev/null || true

# Buffer circular de 64 KB en RAM
uci set system.@system[0].log_size='64'
uci commit system

/etc/init.d/log restart 2>/dev/null || true
sleep 1

echo "✅ log_size = 64 KB (buffer en RAM)"
echo ""
echo "Últimas entradas (logread):"
echo "──────────────────────────────────────────────"
logread | tail -10 || echo "  (sin entradas aún)"
echo "──────────────────────────────────────────────"
echo ""
echo "Comando útil: logread -f   (seguir en tiempo real)"
REMOTE
