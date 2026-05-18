#!/usr/bin/env bash
# ============================================================================
# status.sh — Estado general del router OpenWRT
#
# Muestra en una sola llamada SSH:
#   - Hostname, versión firmware, uptime, carga
#   - Uso de RAM y flash
#   - Interfaces de red: IPs WAN/LAN, estado
#   - Clientes DHCP conectados
#   - Estado de servicios clave (tor, wireguard, dnsmasq, firewall)
#
# Uso:
#   status.sh [--ip <IP>] [--env <env>]
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
            echo "Uso: status.sh [--ip <IP>] [--env <env>]"
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

_check_ssh() {
    if ! ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
        log_error "No se puede conectar a root@${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
}

_check_ssh

echo ""
echo "══════════════════════════════════════════════════"
echo "  Estado del router: ${ROUTER_IP}"
echo "══════════════════════════════════════════════════"

_ssh sh - << 'REMOTE'

sep() { echo "──────────────────────────────────────────────────"; }

# ── Sistema ────────────────────────────────────────────
sep
echo "SISTEMA"
sep
HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null || uci get system.@system[0].hostname 2>/dev/null || echo "?")
VERSION=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION | cut -d'"' -f2 || echo "?")
UPTIME=$(cat /proc/uptime | awk '{s=$1; d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); printf "%dd %dh %dm", d, h, m}')
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
printf "  Hostname : %s\n" "${HOSTNAME}"
printf "  Firmware : %s\n" "${VERSION}"
printf "  Uptime   : %s\n" "${UPTIME}"
printf "  Carga    : %s (1m 5m 15m)\n" "${LOAD}"

# ── Memoria ────────────────────────────────────────────
sep
echo "MEMORIA"
sep
awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{
    u=t-a
    printf "  RAM: %d MB usados / %d MB total (%.0f%% uso)\n", u/1024, t/1024, u*100/t
}' /proc/meminfo

# ── Flash / Almacenamiento ─────────────────────────────
sep
echo "ALMACENAMIENTO"
sep
df -h / /overlay /tmp 2>/dev/null | awk 'NR>1 {printf "  %-12s %6s / %-6s  %s\n", $6, $3, $2, $5}' || true

# ── Red ────────────────────────────────────────────────
sep
echo "RED"
sep
# WAN
WAN_IF=$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null || echo "eth0")
WAN_IP=$(ip -4 addr show "${WAN_IF}" 2>/dev/null | awk '/inet /{print $2}' | head -1)
WAN_GW=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1)
printf "  WAN  (%s): %s  gateway: %s\n" "${WAN_IF}" "${WAN_IP:-sin IP}" "${WAN_GW:--}"

# LAN
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | head -1)
printf "  LAN  (br-lan): %s\n" "${LAN_IP:-?}"

# WiFi cliente (wwan) si existe
WWAN_IP=$(ip -4 addr show wwan 2>/dev/null | awk '/inet /{print $2}' | head -1 || true)
[ -n "${WWAN_IP}" ] && printf "  WiFi cliente (wwan): %s\n" "${WWAN_IP}"

# WireGuard
WG_IP=$(ip -4 addr show wg0 2>/dev/null | awk '/inet /{print $2}' | head -1 || true)
[ -n "${WG_IP}" ] && printf "  WireGuard (wg0): %s\n" "${WG_IP}"

# ── WiFi ───────────────────────────────────────────────
sep
echo "WIFI"
sep
for radio in radio0 radio1; do
    if uci -q get wireless.${radio} >/dev/null 2>&1; then
        band=$(uci -q get wireless.${radio}.band 2>/dev/null || uci -q get wireless.${radio}.hwmode 2>/dev/null || echo "?")
        disabled=$(uci -q get wireless.${radio}.disabled 2>/dev/null || echo "0")
        channel=$(uci -q get wireless.${radio}.channel 2>/dev/null || echo "auto")
        state=$( [ "${disabled}" = "1" ] && echo "deshabilitado" || echo "activo" )
        printf "  %s: %s  canal %s  [%s]\n" "${radio}" "${band}" "${channel}" "${state}"
    fi
done

# ── Clientes DHCP ──────────────────────────────────────
sep
echo "CLIENTES DHCP"
sep
if [ -f /tmp/dhcp.leases ]; then
    count=$(wc -l < /tmp/dhcp.leases)
    printf "  Conectados: %d\n" "${count}"
    awk '{printf "  %-16s  %-20s  %s\n", $3, $4, $2}' /tmp/dhcp.leases
else
    echo "  (sin leases activos)"
fi

# ── Servicios ──────────────────────────────────────────
sep
echo "SERVICIOS"
sep
check_svc() {
    local name="$1" cmd="$2"
    if eval "${cmd}" >/dev/null 2>&1; then
        printf "  %-20s ✅ activo\n" "${name}"
    else
        printf "  %-20s ❌ inactivo\n" "${name}"
    fi
}
check_svc "dnsmasq"    "pgrep dnsmasq"
check_svc "nftables"   "nft list ruleset"
check_svc "dropbear"   "pgrep dropbear"
check_svc "tor"        "pgrep tor"
check_svc "wireguard"  "ip link show wg0"

sep
REMOTE

echo ""
