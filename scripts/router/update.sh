#!/usr/bin/env bash
# ============================================================================
# update.sh — Actualiza firmware del router via SSH + sysupgrade
#
# Uso:
#   scripts/build/update.sh [--ip <IP>] [--force] [--env <dev|prod>]
#
# Opciones:
#   --ip <IP>     IP del router (default: ROUTER_IP de .env.public o 192.168.1.1)
#   --env <env>   Entorno para leer .env.public (default: prod)
#   --force       Resetear configuración del router al actualizar
#                 Sin --force: mantiene la configuración actual (default)
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
_FORCE=false

# ---------------------------------------------------------------------------
# Parsear argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)
            if [ -z "${2:-}" ]; then
                log_error "--ip requiere un argumento: --ip <IP>"
                exit 1
            fi
            _CLI_IP="$2"
            shift 2
            ;;
        --force)
            _FORCE=true
            shift
            ;;
        --env)
            if [ -z "${2:-}" ]; then
                log_error "--env requiere un argumento: --env <dev|prod>"
                exit 1
            fi
            _ENV="$2"
            shift 2
            ;;
        -h|--help)
            echo "Uso: $0 [--ip <IP>] [--force] [--env <dev|prod>]"
            echo ""
            echo "  --ip <IP>   IP del router (default: ROUTER_IP de .env.public o 192.168.1.1)"
            echo "  --env       Entorno para leer .env.public (default: prod)"
            echo "  --force     Resetear configuración del router al actualizar"
            echo "              Sin --force: mantiene la configuración actual"
            exit 0
            ;;
        *)
            log_error "Argumento desconocido: $1"
            echo "   Uso: $0 [--ip <IP>] [--force] [--env <dev|prod>]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Cargar variables del entorno (.env.public) para ROUTER_IP y SSH_PORT
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a
fi

# CLI tiene precedencia sobre .env.public; .env.public tiene precedencia sobre default
ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"
OPENWRT_VERSION="${OPENWRT_VERSION:-}"
PROFILE="${PROFILE:-tplink_tl-wdr3600-v1}"

# ---------------------------------------------------------------------------
# Encontrar imagen sysupgrade
# ---------------------------------------------------------------------------
_find_sysupgrade() {
    local bin
    if [ -n "${OPENWRT_VERSION}" ]; then
        bin=$(find "${REPO_ROOT}/openwrt-builder" \
              -name "openwrt-${OPENWRT_VERSION}-*-${PROFILE}-squashfs-sysupgrade.bin" 2>/dev/null \
              | sort -r | head -1)
    else
        bin=""
    fi

    if [ -z "${bin}" ]; then
        bin=$(find "${REPO_ROOT}/openwrt-builder" -name "*-${PROFILE}-squashfs-sysupgrade.bin" 2>/dev/null \
              | sort -r | head -1)
    fi

    if [ -z "${bin}" ]; then
        log_error "No se encontró imagen sysupgrade para ${PROFILE}${OPENWRT_VERSION:+ en OpenWRT ${OPENWRT_VERSION}}"
        echo "   Solución: just build-prod"
        exit 1
    fi
    echo "${bin}"
}

# ---------------------------------------------------------------------------
# Verificar conectividad SSH con el router
# ---------------------------------------------------------------------------
_check_ssh() {
    if ! ssh -q -o ConnectTimeout=5 -o BatchMode=yes -p "${SSH_PORT}" \
         "root@${ROUTER_IP}" "exit" 2>/dev/null; then
        log_error "No se puede conectar al router: root@${ROUTER_IP}:${SSH_PORT}"
        echo ""
        echo "   Verifica:"
        echo "   • El router está encendido y conectado por cable Ethernet"
        echo "   • La IP es correcta (usa --ip <IP> para sobreescribir)"
        echo "   • SSH está habilitado en el router"
        echo "   • Tu clave SSH está autorizada en el router"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local sysupgrade_bin
    sysupgrade_bin=$(_find_sysupgrade)

    local bin_name
    bin_name=$(basename "${sysupgrade_bin}")

    local mode_label="manteniendo configuración"
    local sysupgrade_flags="-v"
    if [ "${_FORCE}" = true ]; then
        mode_label="BORRANDO configuración (--force)"
        sysupgrade_flags="-n -v"
    fi

    echo "==============================================="
    echo " OpenWRT Sysupgrade"
    echo "==============================================="
    echo ""
    log_step "Configuración:"
    echo "   Router:  root@${ROUTER_IP}:${SSH_PORT}"
    echo "   Imagen:  ${bin_name}"
    echo "   Modo:    ${mode_label}"
    echo ""

    if [ "${_FORCE}" = true ]; then
        echo "   ⚠️  ADVERTENCIA: Se borrará toda la configuración del router."
        echo "   El router quedará con configuración de fábrica de OpenWRT."
        echo ""
    fi

    read -r -p "¿Continuar? (s/N) " answer
    if [ "${answer,,}" != "s" ] && [ "${answer,,}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi

    echo ""
    log_step "Verificando conectividad SSH..."
    _check_ssh
    log_info "✅ Conectado a root@${ROUTER_IP}"

    echo ""
    log_step "Transfiriendo imagen al router..."
    # -O fuerza protocolo SCP legacy: dropbear no tiene servidor SFTP
    scp -O -P "${SSH_PORT}" "${sysupgrade_bin}" "root@${ROUTER_IP}:/tmp/${bin_name}"
    log_info "✅ Imagen transferida: /tmp/${bin_name}"

    echo ""
    log_step "Ejecutando sysupgrade (${mode_label})..."
    echo "   El router se reiniciará. La conexión SSH se cerrará — es normal."
    echo ""
    # shellcheck disable=SC2029
    ssh -p "${SSH_PORT}" "root@${ROUTER_IP}" "sysupgrade ${sysupgrade_flags} /tmp/${bin_name}" || true

    echo ""
    log_info "✅ Sysupgrade enviado. El router está reiniciando..."
    echo ""
    echo "   Espera ~2-3 minutos y luego conecta de nuevo:"
    echo "   ssh root@${ROUTER_IP}"
}

main "$@"
