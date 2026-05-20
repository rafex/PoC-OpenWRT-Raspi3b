#!/usr/bin/env bash
# ============================================================================
# setup-logs-file.sh — Logs persistentes en archivo (USB/extroot)
#
# Configura syslog para escribir a /overlay/log/messages (USB montado como
# extroot). Los logs persisten entre reinicios mientras el USB esté conectado.
#
# ⚠️  PRERREQUISITO: just router-setup-extroot debe haberse ejecutado y el
#    router debe haber reiniciado con el USB montado como /overlay.
#
# Qué hace:
#   1. Verifica que /overlay esté montado desde un dispositivo externo (USB)
#   2. Crea /overlay/log/ si no existe
#   3. Establece log_file=/overlay/log/messages y log_size=128 KB
#   4. Reinicia el servicio de log
#   5. Verifica que el archivo de log se crea correctamente
#
# Uso:
#   scripts/router/setup-logs-file.sh [--ip <IP>] [--env <env>]
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
            echo "Uso: setup-logs-file.sh [--ip <IP>] [--env <env>]"
            echo ""
            echo "  Configura logs persistentes en /overlay/log/messages (USB extroot)."
            echo "  Prerrequisito: just router-setup-extroot + reinicio del router."
            echo ""
            echo "  Ver logs:       ssh root@<IP> 'tail -f /overlay/log/messages'"
            echo "  O en RAM:       ssh root@<IP> 'logread -f'"
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

# Verificar que extroot esté activo
log_step "Verificando extroot..."
overlay_device=$(_ssh "mount | grep ' /overlay ' | awk '{print \$1}'" 2>/dev/null || true)
if [ -z "${overlay_device}" ]; then
    echo ""
    log_error "/overlay no está montado desde un dispositivo externo (USB)."
    echo ""
    echo "  Pasos necesarios:"
    echo "    1. just router-setup-extroot"
    echo "    2. Esperar reinicio del router (~2 min)"
    echo "    3. Volver a ejecutar: just router-setup-logs-file"
    exit 1
fi
overlay_size=$(_ssh "df -h /overlay | tail -1 | awk '{print \$2}'" 2>/dev/null || echo "?")
log_info "Extroot activo: ${overlay_device} (${overlay_size})"

log_step "Configurando logs persistentes en /overlay/log/messages..."

_ssh sh - << 'REMOTE'
set -eu

LOG_FILE="/overlay/log/messages"

# Crear directorio si no existe
mkdir -p /overlay/log

# Limpiar opciones remotas previas (syslog UDP/TCP)
uci -q delete system.@system[0].log_proto 2>/dev/null || true
uci -q delete system.@system[0].log_ip    2>/dev/null || true
uci -q delete system.@system[0].log_port  2>/dev/null || true

# Configurar log a archivo
uci set system.@system[0].log_file="${LOG_FILE}"
uci set system.@system[0].log_size='128'
uci commit system

/etc/init.d/log restart 2>/dev/null || true
sleep 2

# Verificar que se crea el archivo
if [ ! -f "${LOG_FILE}" ]; then
    logger -t setup-logs "Logs configurados en USB extroot"
    sleep 1
fi

if [ -f "${LOG_FILE}" ]; then
    lines=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
    echo "✅ Modo: archivo  |  ${LOG_FILE}  (${lines} líneas)"
    echo ""
    echo "Últimas entradas:"
    echo "──────────────────────────────────────────────"
    tail -10 "${LOG_FILE}"
    echo "──────────────────────────────────────────────"
else
    echo "⚠️  El archivo aún no existe — se creará cuando syslog escriba la primera entrada."
fi

echo ""
echo "  tail -f /overlay/log/messages  → seguir en tiempo real"
echo "  logread                        → buffer en RAM (ambos modos)"
REMOTE
