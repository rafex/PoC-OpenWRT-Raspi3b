#!/usr/bin/env bash
# ============================================================================
# show-clients.sh — Lista dispositivos conectados al router OpenWRT
#
# Muestra los leases DHCP activos y la tabla ARP para identificar
# todos los dispositivos presentes en la red local.
#
# Uso:
#   show-clients.sh [--ip <IP>] [--env <env>]
#
# Opciones:
#   --ip <IP>    IP del router (default: env o 192.168.1.1)
#   --env <env>  Entorno (default: prod)
#
# Salida:
#   1. Leases DHCP activos: IP, MAC, hostname y tiempo restante de cada lease
#   2. Tabla ARP: dispositivos que han enviado tráfico recientemente (incluye IPs estáticas)
# ============================================================================
set -euo pipefail
ROUTER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROUTER_SCRIPT_DIR}/../commons/router-base.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ROUTER_ENV="prod"
_ROUTER_IP_CLI=""

_show_help() {
    cat << 'HELP'
Uso: show-clients.sh [opciones]

Muestra los dispositivos conectados al router:
  - Leases DHCP activos (IP, MAC, hostname, tiempo restante)
  - Tabla ARP (dispositivos que han enviado tráfico recientemente)

Opciones:
  --ip <IP>    IP del router (default: env o 192.168.1.1)
  --env <env>  Entorno (default: prod)
  -h, --help   Muestra esta ayuda

Ejemplos:
  show-clients.sh
  show-clients.sh --env dev
  show-clients.sh --ip 192.168.0.1
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)      _ROUTER_IP_CLI="${2:?--ip requiere argumento}"; shift 2 ;;
        --env)     ROUTER_ENV="${2:?--env requiere argumento}";   shift 2 ;;
        -h|--help) _show_help; exit 0 ;;
        *) log_error "Argumento desconocido: $1"; _show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Cargar entorno y SSH
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${ROUTER_ENV}/.env.public"
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
router_check_ssh
log_info "Consultando clientes en ${ROUTER_IP}..."

echo ""
echo "============================================="
echo " Clientes conectados — ${ROUTER_IP}"
echo "============================================="

router_ssh sh << 'REMOTE'
set -eu

NOW=$(date +%s)
SEP="  ─────────────────────────────────────────────────────────────────────────"

# ── Leases DHCP ──────────────────────────────────────────────────────────────
echo ""
echo "  LEASES DHCP  (/tmp/dhcp.leases)"
echo "${SEP}"

if [ ! -f /tmp/dhcp.leases ] || [ ! -s /tmp/dhcp.leases ]; then
    echo "  (sin leases activos)"
else
    ARP_DATA=$(cat /proc/net/arp 2>/dev/null || true)

    printf "  %-3s  %-16s  %-18s  %-20s  %s\n" \
        "#" "IP" "MAC" "Hostname" "Tiempo restante"
    echo "${SEP}"

    count=0
    while read -r exp mac ip host _rest; do
        count=$((count + 1))

        # Calcular tiempo restante del lease
        if [ "${exp}" = "0" ]; then
            time_str="permanente"
        else
            remaining=$((exp - NOW))
            if [ "${remaining}" -le 0 ]; then
                time_str="expirado"
            elif [ "${remaining}" -ge 86400 ]; then
                days=$((remaining / 86400))
                hrs=$(( (remaining % 86400) / 3600 ))
                time_str="${days}d ${hrs}h"
            elif [ "${remaining}" -ge 3600 ]; then
                hrs=$((remaining / 3600))
                mins=$(( (remaining % 3600) / 60 ))
                time_str="${hrs}h ${mins}m"
            else
                mins=$((remaining / 60))
                time_str="${mins}m"
            fi
        fi

        # ¿Está en la tabla ARP (activo en la red)?
        if echo "${ARP_DATA}" | grep -q "^${ip}[[:space:]]"; then
            status="[en red]"
        else
            status="[sin ARP]"
        fi

        [ "${host}" = "*" ] && host="(desconocido)"

        printf "  %-3s  %-16s  %-18s  %-20s  %-15s  %s\n" \
            "${count}" "${ip}" "${mac}" "${host}" "${time_str}" "${status}"

    done < /tmp/dhcp.leases

    echo ""
    echo "  Total: ${count} lease(s) activo(s)"
fi

# ── Tabla ARP ─────────────────────────────────────────────────────────────────
echo ""
echo "  TABLA ARP  (dispositivos con tráfico reciente)"
echo "${SEP}"

# Filtrar cabecera, entradas vacías y MACs nulas
ARP_ENTRIES=$(grep -Ev "^IP address|^$|00:00:00:00:00:00" /proc/net/arp 2>/dev/null || true)

if [ -z "${ARP_ENTRIES}" ]; then
    echo "  (tabla ARP vacía)"
else
    printf "  %-16s  %-18s  %-10s  %s\n" "IP" "MAC" "Interfaz" "Estado"
    echo "${SEP}"

    echo "${ARP_ENTRIES}" | while read -r ip _hwtype flags mac _mask iface; do
        # flags: 0x2 = entrada completa (reachable), 0x0 = incompleta
        case "${flags}" in
            0x2|0x6) reach="[completo]" ;;
            0x0)     reach="[incompleto]" ;;
            *)       reach="[flags=${flags}]" ;;
        esac
        printf "  %-16s  %-18s  %-10s  %s\n" "${ip}" "${mac}" "${iface}" "${reach}"
    done
fi

echo ""
REMOTE

echo ""
