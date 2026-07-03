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

usb_devices=$(block info 2>/dev/null | awk -F: '/^\/dev\/sd[a-z][0-9]/{print $1}' | sort)
if [ -n "${usb_devices}" ]; then
    printf "  USB       : %s\n" "$(ok detectado)"
    printf "    %-12s %-8s %-36s %s\n" "Dispositivo" "FS" "UUID" "Montado"
    echo "${usb_devices}" | while read -r usb_dev; do
        [ -n "${usb_dev}" ] || continue
        usb_info=$(block info "${usb_dev}" 2>/dev/null || true)
        usb_type=$(echo "${usb_info}" | grep -o 'TYPE="[^"]*"' | cut -d'"' -f2)
        usb_uuid=$(echo "${usb_info}" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
        usb_mount=$(awk -v dev="${usb_dev}" '$1 == dev {print $2; exit}' /proc/mounts 2>/dev/null)
        printf "    %-12s %-8s %-36s %s\n" "${usb_dev}" "${usb_type:--}" "${usb_uuid:--}" "${usb_mount:--}"
    done
else
    printf "  USB       : %s\n" "$(warn no detectado)"
fi

overlay_src=$(awk '$2 == "/overlay" {print $1; exit}' /proc/mounts 2>/dev/null)
overlay_type=$(awk '$2 == "/overlay" {print $3; exit}' /proc/mounts 2>/dev/null)
if [ -n "${overlay_src}" ]; then
    case "${overlay_src}" in
        /dev/sd*) printf "  Extroot   : %s (%s)\n" "$(ok activo)" "${overlay_src}, ${overlay_type:-?}" ;;
        *)        printf "  Extroot   : %s (%s)\n" "$(warn no es USB)" "${overlay_src}, ${overlay_type:-?}" ;;
    esac
else
    printf "  Extroot   : %s\n" "$(warn no detectado)"
fi
if [ -f /etc/config/fstab ]; then
    extroot_enabled=$(uci -q get fstab.extroot.enabled 2>/dev/null || echo "0")
    extroot_target=$(uci -q get fstab.extroot.target 2>/dev/null || echo "-")
    extroot_uuid=$(uci -q get fstab.extroot.uuid 2>/dev/null || echo "-")
    extroot_device=$(uci -q get fstab.extroot.device 2>/dev/null || echo "-")
    printf "  fstab     : extroot enabled=%s target=%s uuid=%s device=%s\n" "${extroot_enabled}" "${extroot_target}" "${extroot_uuid}" "${extroot_device}"
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

# ── Dispositivos / DHCP ────────────────────────────────
sep
echo "DISPOSITIVOS / DHCP"
sep
tmp_static="/tmp/router-status-static.$$"
tmp_arp="/tmp/router-status-arp.$$"
tmp_leases="/tmp/router-status-leases.$$"
: > "${tmp_static}"
: > "${tmp_arp}"
: > "${tmp_leases}"

idx=0
while uci -q get "dhcp.@host[${idx}]" >/dev/null 2>&1; do
    static_mac=$(uci -q get "dhcp.@host[${idx}].mac" 2>/dev/null || true)
    static_ip=$(uci -q get "dhcp.@host[${idx}].ip" 2>/dev/null || true)
    static_name=$(uci -q get "dhcp.@host[${idx}].name" 2>/dev/null || true)
    if [ -n "${static_mac}" ] || [ -n "${static_ip}" ]; then
        printf "%s %s %s\n" "${static_ip:-?}" "$(echo "${static_mac:-?}" | tr 'A-F' 'a-f')" "${static_name:-?}" >> "${tmp_static}"
    fi
    idx=$((idx + 1))
done

if [ -f /proc/net/arp ]; then
    awk 'NR > 1 && $4 != "00:00:00:00:00:00" {print $1, tolower($4), $6, $3}' /proc/net/arp > "${tmp_arp}"
fi

if [ -f /tmp/dhcp.leases ] && [ -s /tmp/dhcp.leases ]; then
    cp /tmp/dhcp.leases "${tmp_leases}"
fi

lease_count=$(wc -l < "${tmp_leases}" 2>/dev/null || echo 0)
static_count=$(wc -l < "${tmp_static}" 2>/dev/null || echo 0)
arp_count=$(wc -l < "${tmp_arp}" 2>/dev/null || echo 0)
printf "  Leases activos : %s\n" "${lease_count}"
printf "  Reservas DHCP  : %s\n" "${static_count}"
printf "  Entradas ARP   : %s\n" "${arp_count}"
echo ""
printf "  %-16s  %-18s  %-22s  %-12s  %-12s  %s\n" "IP" "MAC" "Nombre" "Origen" "Estado" "Lease"
printf "  %-16s  %-18s  %-22s  %-12s  %-12s  %s\n" "----------------" "-----------------" "----------------------" "------------" "------------" "------------"

if [ -s "${tmp_leases}" ]; then
    while read -r exp mac ip host _rest; do
        mac_lc=$(echo "${mac}" | tr 'A-F' 'a-f')
        [ "${host}" = "*" ] && host="(desconocido)"

        if [ "${exp}" = "0" ]; then
            lease_left="permanente"
        else
            remaining=$((exp - $(date +%s)))
            if [ "${remaining}" -le 0 ]; then
                lease_left="expirado"
            elif [ "${remaining}" -ge 3600 ]; then
                lease_left="$((remaining / 3600))h $(((remaining % 3600) / 60))m"
            else
                lease_left="$((remaining / 60))m"
            fi
        fi

        status="sin ARP"
        grep -q "^${ip} " "${tmp_arp}" 2>/dev/null && status="en red"

        origin="dhcp"
        if grep -qiE "^${ip} ${mac_lc} " "${tmp_static}" 2>/dev/null || grep -qiE "^[^ ]+ ${mac_lc} " "${tmp_static}" 2>/dev/null; then
            origin="dhcp/reserva"
        fi

        printf "  %-16s  %-18s  %-22s  %-12s  %-12s  %s\n" "${ip}" "${mac_lc}" "${host}" "${origin}" "${status}" "${lease_left}"
    done < "${tmp_leases}"
fi

if [ -s "${tmp_static}" ]; then
    while read -r ip mac name; do
        if ! awk -v ip="${ip}" -v mac="${mac}" 'tolower($2) == mac || $3 == ip {found=1} END{exit found ? 0 : 1}' "${tmp_leases}" 2>/dev/null; then
            status="sin ARP"
            grep -q "^${ip} " "${tmp_arp}" 2>/dev/null && status="en red"
            printf "  %-16s  %-18s  %-22s  %-12s  %-12s  %s\n" "${ip}" "${mac}" "${name}" "reserva" "${status}" "-"
        fi
    done < "${tmp_static}"
fi

if [ -s "${tmp_arp}" ]; then
    while read -r ip mac iface flags; do
        if awk -v ip="${ip}" -v mac="${mac}" 'tolower($2) == mac || $3 == ip {found=1} END{exit found ? 0 : 1}' "${tmp_leases}" 2>/dev/null; then
            continue
        fi
        if awk -v ip="${ip}" -v mac="${mac}" '$1 == ip || $2 == mac {found=1} END{exit found ? 0 : 1}' "${tmp_static}" 2>/dev/null; then
            continue
        fi
        case "${flags}" in
            0x2|0x6) status="en red" ;;
            *) status="arp ${flags}" ;;
        esac
        printf "  %-16s  %-18s  %-22s  %-12s  %-12s  %s\n" "${ip}" "${mac}" "(desconocido)" "arp/${iface}" "${status}" "-"
    done < "${tmp_arp}"
fi

if [ ! -s "${tmp_leases}" ] && [ ! -s "${tmp_static}" ] && [ ! -s "${tmp_arp}" ]; then
    echo "  (sin leases DHCP, reservas ni entradas ARP)"
fi

rm -f "${tmp_static}" "${tmp_arp}" "${tmp_leases}"

# ── Portal cautivo ─────────────────────────────────────
sep
echo "PORTAL CAUTIVO"
sep
CAPTIVE_CFG="/etc/captive/config"
CAPTIVE_NFT="/etc/captive/captive.nft"
CAPTIVE_TABLE="ip captive"
CAPTIVE_SET="allowed_clients"

if [ -x /etc/init.d/captive ] || [ -f "${CAPTIVE_CFG}" ] || [ -f "${CAPTIVE_NFT}" ] || nft list table ${CAPTIVE_TABLE} >/dev/null 2>&1; then
    printf "  Instalado       : %s\n" "$(ok si)"
else
    printf "  Instalado       : %s\n" "$(bad "no detectado")"
fi

if [ -x /etc/init.d/captive ]; then
    if /etc/init.d/captive enabled >/dev/null 2>&1; then captive_enabled="habilitado"; else captive_enabled="no habilitado"; fi
    if /etc/init.d/captive running >/dev/null 2>&1; then captive_running="$(ok activo)"; else captive_running="$(bad inactivo)"; fi
    printf "  Servicio        : %s (%s)\n" "${captive_running}" "${captive_enabled}"
else
    printf "  Servicio        : %s\n" "$(bad "no registrado")"
fi

if nft list table ${CAPTIVE_TABLE} >/dev/null 2>&1; then
    printf "  nftables        : %s tabla '%s'\n" "$(ok activa)" "${CAPTIVE_TABLE}"
else
    printf "  nftables        : %s tabla '%s'\n" "$(bad no activa)" "${CAPTIVE_TABLE}"
fi

if [ -f "${CAPTIVE_CFG}" ]; then
    mode=$(grep -E '^MODE=' "${CAPTIVE_CFG}" 2>/dev/null | cut -d= -f2- || true)
    timeout=$(grep -E '^TIMEOUT=' "${CAPTIVE_CFG}" 2>/dev/null | cut -d= -f2- || true)
    portal_url=$(grep -E '^PORTAL_URL=' "${CAPTIVE_CFG}" 2>/dev/null | cut -d= -f2- || true)
    [ -n "${mode}" ] && printf "  Modo            : %s\n" "${mode}"
    [ -n "${timeout}" ] && printf "  Timeout         : %s\n" "${timeout}"
    [ -n "${portal_url}" ] && printf "  Portal externo  : %s\n" "${portal_url}"
else
    printf "  Config          : %s\n" "$(warn "/etc/captive/config no encontrado")"
fi

authorized=$(nft list set ${CAPTIVE_TABLE} ${CAPTIVE_SET} 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[^,}]*' || true)
if [ -n "${authorized}" ]; then
    echo "  Autorizados:"
    echo "${authorized}" | while IFS= read -r entry; do
        client_ip=$(echo "${entry}" | grep -Eo '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        expires=$(echo "${entry}" | grep -o 'expires .*' || true)
        lease_name=$(awk -v ip="${client_ip}" '$3 == ip {print $4; exit}' /tmp/dhcp.leases 2>/dev/null || true)
        lease_mac=$(awk -v ip="${client_ip}" '$3 == ip {print tolower($2); exit}' /tmp/dhcp.leases 2>/dev/null || true)
        printf "    %-16s %-18s %-20s %s\n" "${client_ip}" "${lease_mac:--}" "${lease_name:--}" "${expires}"
    done
else
    echo "  Autorizados     : ninguno"
fi

dhcp_opt_252=$(uci -q get dhcp.@dnsmasq[0].dhcp_option 2>/dev/null | tr ' ' '\n' | grep '^252,' || true)
probe_count=$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null | tr ' ' '\n' | grep -cE '/(connectivity|captive|msft|detectportal|network)/' || true)
filter_aaaa=$(uci -q get dhcp.@dnsmasq[0].filter_aaaa 2>/dev/null || echo "?")
printf "  DHCP opt 252    : %s\n" "${dhcp_opt_252:-no configurada}"
printf "  Probe domains   : %s entrada(s) dnsmasq\n" "${probe_count}"
printf "  filter_aaaa     : %s\n" "${filter_aaaa}"

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
