#!/usr/bin/env bash
# ============================================================================
# status.sh — Estado general del router OpenWRT
#
# Muestra en una sola llamada SSH:
#   - Modelo, versión firmware, kernel, uptime, carga
#   - Uso de RAM, flash, tmp y extroot
#   - Interfaces de red: LAN, WAN, WWAN, rutas
#   - Clientes DHCP conectados
#   - Estado de servicios clave y package manager
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
ok() { printf "✅ %s" "$1"; }
bad() { printf "❌ %s" "$1"; }
warn() { printf "⚠️  %s" "$1"; }

json_get() {
    awk -v key="\"$1\"" '
        index($0, key) {
            sub(/^[^:]*: */, "")
            gsub(/[",]/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    '
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

service_enabled() {
    local svc="$1"
    [ -x "/etc/init.d/${svc}" ] && "/etc/init.d/${svc}" enabled >/dev/null 2>&1
}

service_running() {
    local svc="$1"
    case "${svc}" in
        dnsmasq) pgrep -x dnsmasq >/dev/null 2>&1 ;;
        dropbear) pgrep -x dropbear >/dev/null 2>&1 ;;
        firewall|nftables) nft list ruleset >/dev/null 2>&1 ;;
        tor) pgrep -x tor >/dev/null 2>&1 ;;
        uhttpd) pgrep -x uhttpd >/dev/null 2>&1 ;;
        wireguard) ip link show wg0 >/dev/null 2>&1 ;;
        *) pgrep -x "${svc}" >/dev/null 2>&1 ;;
    esac
}

print_service() {
    local label="$1" svc="$2" installed="$3"
    local run_state enabled_state

    if eval "${installed}" >/dev/null 2>&1; then
        if service_running "${svc}"; then
            run_state="$(ok activo)"
        else
            run_state="$(bad inactivo)"
        fi

        if service_enabled "${svc}"; then
            enabled_state="habilitado"
        else
            enabled_state="no habilitado"
        fi
        printf "  %-14s %s  (%s)\n" "${label}:" "${run_state}" "${enabled_state}"
    else
        printf "  %-14s %s\n" "${label}:" "$(bad no instalado)"
    fi
}

iface_ip4() {
    ip -4 addr show "$1" 2>/dev/null | awk '/inet /{print $2}' | head -1
}

ifstatus_field() {
    local iface="$1" field="$2"
    ifstatus "${iface}" 2>/dev/null | json_get "${field}"
}

# ── Sistema ────────────────────────────────────────────
sep
echo "SISTEMA"
sep
HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null || uci get system.@system[0].hostname 2>/dev/null || echo "?")
VERSION=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_DESCRIPTION | cut -d'"' -f2 || echo "?")
RELEASE_VERSION=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_RELEASE | cut -d"'" -f2 || echo "?")
REVISION=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_REVISION | cut -d"'" -f2 || echo "?")
TARGET=$(cat /etc/openwrt_release 2>/dev/null | grep DISTRIB_TARGET | cut -d"'" -f2 || echo "?")
MODEL=$(ubus call system board 2>/dev/null | json_get model || echo "?")
KERNEL=$(uname -r 2>/dev/null || echo "?")
UPTIME=$(cat /proc/uptime | awk '{s=$1; d=int(s/86400); h=int((s%86400)/3600); m=int((s%3600)/60); printf "%dd %dh %dm", d, h, m}')
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
PKG_MANAGER="$(command -v apk >/dev/null 2>&1 && echo apk || { command -v opkg >/dev/null 2>&1 && echo opkg || echo "no detectado"; })"
printf "  Hostname : %s\n" "${HOSTNAME}"
printf "  Modelo   : %s\n" "${MODEL}"
printf "  Firmware : %s\n" "${VERSION}"
printf "  Release  : %s (%s)\n" "${RELEASE_VERSION}" "${REVISION}"
printf "  Target   : %s\n" "${TARGET}"
printf "  Kernel   : %s\n" "${KERNEL}"
printf "  Uptime   : %s\n" "${UPTIME}"
printf "  Carga    : %s (1m 5m 15m)\n" "${LOAD}"
printf "  Paquetes : %s\n" "${PKG_MANAGER}"

# ── Memoria ────────────────────────────────────────────
sep
echo "MEMORIA"
sep
awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{
    u=t-a
    p=u*100/t
    state=(p >= 90 ? "CRITICO" : (p >= 75 ? "ALTO" : "OK"))
    printf "  RAM       : %d MB usados / %d MB total (%.0f%% uso) [%s]\n", u/1024, t/1024, p, state
}' /proc/meminfo
awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{
    if (t > 0) {
        u=t-f
        printf "  Swap      : %d MB usados / %d MB total (%.0f%% uso)\n", u/1024, t/1024, u*100/t
    } else {
        printf "  Swap      : no configurada\n"
    }
}' /proc/meminfo

# ── Flash / Almacenamiento ─────────────────────────────
sep
echo "ALMACENAMIENTO"
sep
df -h /rom / /overlay /tmp 2>/dev/null | awk 'NR>1 {printf "  %-12s %6s / %-6s  %s\n", $6, $3, $2, $5}' || true
if mount | grep -q ' on /overlay '; then
    overlay_src=$(mount | awk '$3 == "/overlay" {print $1; exit}')
    overlay_type=$(mount | awk '$3 == "/overlay" {print $5; exit}')
    printf "  Extroot   : %s (%s)\n" "$(ok activo)" "${overlay_src:-?}, ${overlay_type:-?}"
else
    printf "  Extroot   : %s\n" "$(warn no detectado)"
fi
if [ -f /etc/config/fstab ]; then
    extroot_enabled=$(uci -q get fstab.extroot.enabled 2>/dev/null || echo "0")
    printf "  fstab     : extroot enabled=%s\n" "${extroot_enabled}"
fi

# ── Red ────────────────────────────────────────────────
sep
echo "RED"
sep
WAN_IF=$(uci -q get network.wan.device 2>/dev/null || uci -q get network.wan.ifname 2>/dev/null || echo "eth0")
WAN_IP=$(iface_ip4 "${WAN_IF}")
WAN_UP=$(ifstatus_field wan up)
WAN_GW=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1)
printf "  WAN   (%s): %s  estado=%s\n" "${WAN_IF}" "${WAN_IP:-sin IP}" "${WAN_UP:-?}"

LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | head -1)
LAN_DEV=$(uci -q get network.lan.device 2>/dev/null || echo "br-lan")
printf "  LAN   (%s): %s\n" "${LAN_DEV}" "${LAN_IP:-?}"

WWAN_DEV=$(ifstatus_field wwan l3_device)
WWAN_IP=""
[ -n "${WWAN_DEV}" ] && WWAN_IP=$(iface_ip4 "${WWAN_DEV}" || true)
[ -n "${WWAN_IP}" ] && printf "  WWAN  (%s): %s\n" "${WWAN_DEV}" "${WWAN_IP}"

WG_IP=$(iface_ip4 wg0 || true)
[ -n "${WG_IP}" ] && printf "  WireGuard (wg0): %s\n" "${WG_IP}"

printf "  Gateway: %s\n" "${WAN_GW:--}"
echo "  Rutas:"
ip -4 route show 2>/dev/null | sed 's/^/    /' || true

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
echo "  Interfaces:"
uci show wireless 2>/dev/null | awk -F'[.=]' '
    /wifi-iface$/ {section=$2}
    /mode=/ {mode[section]=$0}
    /ssid=/ {ssid[section]=$0}
    /network=/ {net[section]=$0}
    /device=/ {dev[section]=$0}
    /disabled=/ {disabled[section]=$0}
    END {
        for (s in mode) {
            m=mode[s]; sub(/^.*mode=/, "", m); gsub(/\047/, "", m)
            id=ssid[s]; sub(/^.*ssid=/, "", id); gsub(/\047/, "", id)
            n=net[s]; sub(/^.*network=/, "", n); gsub(/\047/, "", n)
            d=dev[s]; sub(/^.*device=/, "", d); gsub(/\047/, "", d)
            dis=disabled[s]; sub(/^.*disabled=/, "", dis); gsub(/\047/, "", dis)
            state=(dis == "1" ? "deshabilitada" : "activa")
            printf "    %-10s mode=%-5s ssid=%-24s net=%-8s %s\n", d, m, id, n, state
        }
    }
' | sort

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
print_service "dnsmasq" "dnsmasq" "command_exists dnsmasq"
print_service "firewall" "firewall" "command_exists fw4"
print_service "dropbear" "dropbear" "command_exists dropbear"
print_service "wireguard" "wireguard" "command_exists wg"
print_service "tor" "tor" "command_exists tor"
print_service "uhttpd" "uhttpd" "command_exists uhttpd"

# ── Salud ──────────────────────────────────────────────
sep
echo "SALUD"
sep
if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    printf "  Internet IPv4 : %s\n" "$(ok disponible)"
else
    printf "  Internet IPv4 : %s\n" "$(bad sin respuesta)"
fi

if nslookup openwrt.org 127.0.0.1 >/dev/null 2>&1; then
    printf "  DNS local     : %s\n" "$(ok resuelve)"
else
    printf "  DNS local     : %s\n" "$(bad falla)"
fi

log_warns=$(logread 2>/dev/null | tail -80 | grep -Ei 'error|failed|warn|oom|no default route' | tail -5 || true)
if [ -n "${log_warns}" ]; then
    echo "  Logs recientes:"
    echo "${log_warns}" | sed 's/^/    /'
else
    printf "  Logs recientes: %s\n" "$(ok sin errores relevantes)"
fi

sep
REMOTE

echo ""
