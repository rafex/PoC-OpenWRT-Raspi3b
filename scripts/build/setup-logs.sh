#!/usr/bin/env bash
# ============================================================================
# setup-logs.sh — Configura logs persistentes en USB (extroot) via SSH
#
# ⚠️  PRERREQUISITO: just setup-extroot debe haberse ejecutado y el router
#    debe haber reiniciado con el USB montado como /overlay.
#    Este script verifica que extroot esté activo antes de continuar.
#
# Qué hace:
#   1. Verifica que /overlay esté montado desde un dispositivo USB
#   2. Crea estructura de directorios en el USB: /overlay/{log,data,backup}
#   3. Configura /etc/config/system:
#        option log_file  '/overlay/log/messages'   ← logs al USB
#        option log_size  '128'                      ← máximo 128 KB en RAM buffer
#        (log_proto NO se configura: solo acepta tcp/udp, no file)
#   4. Reinicia el servicio de log
#   5. Verifica que los logs se escriben en el USB
#
# Uso:
#   scripts/build/setup-logs.sh [--ip <IP>] [--env <env>]
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
        -h|--help)
            echo "Uso: $0 [--ip <IP>] [--env <dev|prod>]"
            echo ""
            echo "  --ip <IP>   IP del router (default: ROUTER_IP de .env.public o 192.168.1.1)"
            echo "  --env       Entorno para leer .env.public (default: prod)"
            echo ""
            echo "  ⚠️  Prerrequisito: ejecutar 'just setup-extroot' primero."
            echo "     El router debe haber reiniciado con el USB montado como /overlay."
            exit 0
            ;;
        *)
            log_error "Argumento desconocido: $1"
            echo "   Uso: $0 [--ip <IP>] [--env <env>]"
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
# Helper SSH
# ---------------------------------------------------------------------------
_ssh() {
    ssh -q -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

# ---------------------------------------------------------------------------
# Verificar conectividad
# ---------------------------------------------------------------------------
_check_ssh() {
    if ! _ssh "exit" 2>/dev/null; then
        log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
    log_info "✅ Conectado a root@${ROUTER_IP}"
}

# ---------------------------------------------------------------------------
# Verificar que extroot esté activo (USB montado como /overlay)
# ---------------------------------------------------------------------------
_check_extroot() {
    log_step "Verificando que extroot esté activo..."

    local overlay_device
    overlay_device=$(_ssh "mount | grep ' /overlay ' | awk '{print \$1}'" 2>/dev/null || true)

    if [ -z "${overlay_device}" ]; then
        echo ""
        log_error "Extroot NO está activo — /overlay no está montado desde un dispositivo externo."
        echo ""
        echo "   Pasos necesarios antes de ejecutar este script:"
        echo ""
        echo "   1. Configurar extroot:"
        echo "      just setup-extroot"
        echo ""
        echo "   2. Esperar a que el router reinicie completamente (~2 minutos)"
        echo ""
        echo "   3. Verificar que extroot está activo:"
        echo "      ssh root@${ROUTER_IP} 'df -h /overlay'"
        echo "      (debe mostrar el tamaño del USB, no unos pocos MB)"
        echo ""
        echo "   4. Volver a ejecutar este script:"
        echo "      just setup-logs"
        exit 1
    fi

    local overlay_size
    overlay_size=$(_ssh "df -h /overlay | tail -1 | awk '{print \$2}'" 2>/dev/null || echo "?")

    log_info "✅ Extroot activo — /overlay montado desde: ${overlay_device} (${overlay_size})"
}

# ---------------------------------------------------------------------------
# Configurar logs en el router via SSH
# ---------------------------------------------------------------------------
_setup_logs_on_router() {
    _ssh bash <<'REMOTE'
set -euo pipefail

LOG_DIR="/overlay/log"
LOG_FILE="${LOG_DIR}/messages"

echo ""
echo "=== Configurando logs persistentes en USB ==="
echo ""

# 1. Crear estructura de directorios en el USB
echo "[1/4] Creando estructura de directorios en /overlay..."
mkdir -p /overlay/log
mkdir -p /overlay/data
mkdir -p /overlay/backup
echo "      ✅ /overlay/{log,data,backup} creados"

# 2. Configurar /etc/config/system
echo "[2/4] Configurando /etc/config/system..."

# Eliminar opciones de log existentes para evitar duplicados
uci -q delete system.@system[0].log_file  2>/dev/null || true
uci -q delete system.@system[0].log_size  2>/dev/null || true
uci -q delete system.@system[0].log_proto 2>/dev/null || true
uci -q delete system.@system[0].log_ip    2>/dev/null || true
uci -q delete system.@system[0].log_port  2>/dev/null || true

# Configurar log a archivo en USB
# Nota: log_proto solo acepta 'tcp'/'udp' (log remoto), NO 'file'
#       Para log a archivo solo se necesita log_file y log_size
uci set system.@system[0].log_file="${LOG_FILE}"
uci set system.@system[0].log_size='128'
uci commit system

echo "      ✅ log_file  = ${LOG_FILE}"
echo "      ✅ log_size  = 128 KB (buffer en RAM)"
echo "      ℹ️  log_proto no configurado (solo válido para tcp/udp remoto)"

# 3. Reiniciar servicio de log
echo "[3/4] Reiniciando servicio de log..."
/etc/init.d/log restart
sleep 2
echo "      ✅ Servicio reiniciado"

# 4. Verificar que se están escribiendo logs
echo "[4/4] Verificando escritura de logs..."
if [ -f "${LOG_FILE}" ]; then
    SIZE=$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)
    LINES=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
    echo "      ✅ ${LOG_FILE} existe (${LINES} líneas, ${SIZE} bytes)"
    echo ""
    echo "      Últimas entradas:"
    tail -5 "${LOG_FILE}" 2>/dev/null | sed 's/^/      /'
else
    echo "      ⚠️  El archivo aún no existe — se creará cuando syslog escriba la primera entrada"
    echo "      Forzando entrada de prueba..."
    logger -t setup-logs "Logs configurados en USB extroot"
    sleep 1
    if [ -f "${LOG_FILE}" ]; then
        echo "      ✅ ${LOG_FILE} creado correctamente"
        tail -3 "${LOG_FILE}" | sed 's/^/      /'
    fi
fi

echo ""
echo "✅ Logs configurados correctamente"
echo ""
echo "   Flujo de logs:"
echo "   Sistema → /overlay/log/messages (USB)"
echo ""
echo "   Comandos útiles:"
echo "   tail -f /overlay/log/messages    # seguir logs en tiempo real"
echo "   logread                          # ver logs del buffer de RAM"
echo "   ls -lh /overlay/log/             # ver archivos de log"
REMOTE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "==============================================="
    echo " OpenWRT — Logs Persistentes en USB"
    echo "==============================================="
    echo ""
    echo "   ⚠️  Este script requiere que 'just setup-extroot' se haya"
    echo "      ejecutado y el router haya reiniciado con el USB activo."
    echo ""

    _check_ssh
    echo ""
    _check_extroot

    echo ""
    log_step "Resumen:"
    echo "   Router:   root@${ROUTER_IP}:${SSH_PORT}"
    echo "   Log file: /overlay/log/messages"
    echo "   Dirs:     /overlay/{log,data,backup}"
    echo ""
    read -r -p "¿Continuar? (s/N) " answer
    if [ "${answer,,}" != "s" ] && [ "${answer,,}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi

    echo ""
    _setup_logs_on_router

    echo ""
    log_info "Para seguir los logs en tiempo real:"
    echo "   ssh root@${ROUTER_IP} 'tail -f /overlay/log/messages'"
}

main "$@"
