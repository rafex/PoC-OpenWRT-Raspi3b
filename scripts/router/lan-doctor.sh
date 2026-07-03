#!/usr/bin/env bash
# ============================================================================
# lan-doctor.sh — Valida comunicación interna LAN desde router y un origen
#
# Uso:
#   lan-doctor.sh [--ip <router>] [--env <env>] [--source local|user@host]
#                 [--target <IP>]...
#
# Si no se pasan targets, toma leases DHCP, reservas UCI y ARP LAN del router.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

_ENV="prod"
_CLI_IP=""
_SOURCE=""
_TARGETS=()

_show_help() {
    cat << 'HELP'
Uso: lan-doctor.sh [opciones]

Valida conectividad interna hacia dispositivos LAN:
  1. Router OpenWrt -> targets
  2. Origen opcional -> targets (--source local|user@host)

Opciones:
  --ip <IP>          IP del router OpenWrt (default: env o 192.168.1.1)
  --env <env>        Entorno para leer .env.public (default: prod)
  --source <origen>  local o user@host desde donde probar conectividad
  --target <IP>      IP a probar. Puede repetirse. Si se omite, autodetecta.
  -h, --help         Muestra esta ayuda

Ejemplos:
  lan-doctor.sh --ip 192.168.1.1
  lan-doctor.sh --ip 192.168.1.1 --source local
  lan-doctor.sh --ip 192.168.1.1 --source rafex@192.168.3.143
  lan-doctor.sh --source local --target 192.168.1.146 --target 192.168.1.167
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)      _CLI_IP="${2:?--ip requiere argumento}"; shift 2 ;;
        --env)     _ENV="${2:?--env requiere argumento}"; shift 2 ;;
        --source)  _SOURCE="${2:?--source requiere argumento}"; shift 2 ;;
        --target)  _TARGETS+=("${2:?--target requiere argumento}"); shift 2 ;;
        -h|--help) _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; _show_help; exit 1 ;;
    esac
done

ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a
fi

ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"

_ssh_router() {
    ssh -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

_check_router() {
    if ! ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
        log_error "No se puede conectar a root@${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
}

_discover_targets() {
    _ssh_router sh -s << 'REMOTE'
set -eu
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
LAN_PREFIX=$(echo "${LAN_IP}" | awk -F. '{print $1"."$2"."$3"."}')
TMP="/tmp/lan-doctor-targets.$$"
: > "${TMP}"

idx=0
while uci -q get "dhcp.@host[${idx}]" >/dev/null 2>&1; do
    ip=$(uci -q get "dhcp.@host[${idx}].ip" 2>/dev/null || true)
    mac=$(uci -q get "dhcp.@host[${idx}].mac" 2>/dev/null || true)
    name=$(uci -q get "dhcp.@host[${idx}].name" 2>/dev/null || true)
    case "${ip}" in
        "${LAN_PREFIX}"*) printf "%s\t%s\t%s\treserva\n" "${ip}" "${mac:-?}" "${name:-?}" >> "${TMP}" ;;
    esac
    idx=$((idx + 1))
done

if [ -f /tmp/dhcp.leases ]; then
    awk -v prefix="${LAN_PREFIX}" '$3 ~ "^"prefix {printf "%s\t%s\t%s\tdhcp\n", $3, tolower($2), ($4 == "*" ? "?" : $4)}' /tmp/dhcp.leases >> "${TMP}"
fi

if [ -f /proc/net/arp ]; then
    awk -v prefix="${LAN_PREFIX}" 'NR > 1 && $1 ~ "^"prefix && $4 != "00:00:00:00:00:00" {printf "%s\t%s\t?\tarp/%s\n", $1, tolower($4), $6}' /proc/net/arp >> "${TMP}"
fi

awk -F '\t' '!seen[$1]++ {print}' "${TMP}" | sort -V
rm -f "${TMP}"
REMOTE
}

_router_probe() {
    local target_file="$1"

    echo ""
    echo "──────────────────────────────────────────────────"
    echo "ROUTER -> LAN"
    echo "──────────────────────────────────────────────────"
    printf "  %-16s %-18s %-18s %-12s %s\n" "IP" "MAC" "Nombre" "Origen" "Ping"
    printf "  %-16s %-18s %-18s %-12s %s\n" "----------------" "-----------------" "------------------" "------------" "----"

    while IFS=$'\t' read -r ip mac name origin; do
        [ -n "${ip}" ] || continue
        if _ssh_router "ping -c 1 -W 1 '${ip}' >/dev/null 2>&1" </dev/null; then
            ping_state="OK"
        else
            ping_state="FALLA"
        fi
        printf "  %-16s %-18s %-18s %-12s %s\n" "${ip}" "${mac:-?}" "${name:-?}" "${origin:-?}" "${ping_state}"
    done < "${target_file}"
}

_source_probe_script='
set -eu
target_file="$1"

echo "Host: $(hostname 2>/dev/null || echo "?")"
echo ""
echo "Interfaces:"
ip -br addr 2>/dev/null || ifconfig 2>/dev/null || true
echo ""
echo "Rutas:"
ip route 2>/dev/null || netstat -rn 2>/dev/null || true
echo ""
printf "  %-16s %-18s %-18s %-12s %-22s %s\n" "IP" "MAC" "Nombre" "Origen" "Ruta" "Ping"
printf "  %-16s %-18s %-18s %-12s %-22s %s\n" "----------------" "-----------------" "------------------" "------------" "----------------------" "----"

while IFS="	" read -r ip mac name origin; do
    [ -n "${ip}" ] || continue
    route=$(ip route get "${ip}" 2>/dev/null | head -1 | sed "s/[[:space:]]\\+/ /g" || true)
    route_short=$(printf "%s\n" "${route}" | sed -n "s/.* dev \([^ ]*\).*/\1/p")
    [ -z "${route_short}" ] && route_short="-"
    if ping -c 1 -W 1 "${ip}" >/dev/null 2>&1; then
        ping_state="OK"
    else
        ping_state="FALLA"
    fi
    printf "  %-16s %-18s %-18s %-12s %-22s %s\n" "${ip}" "${mac:-?}" "${name:-?}" "${origin:-?}" "${route_short}" "${ping_state}"
done < "${target_file}"
'

_source_probe() {
    local target_file="$1"

    [ -n "${_SOURCE}" ] || return 0

    echo ""
    echo "──────────────────────────────────────────────────"
    echo "ORIGEN (${_SOURCE}) -> LAN"
    echo "──────────────────────────────────────────────────"

    if [ "${_SOURCE}" = "local" ]; then
        sh -c "${_source_probe_script}" sh "${target_file}"
    else
        local remote_tmp="/tmp/lan-doctor-targets.$$"
        scp -q "${target_file}" "${_SOURCE}:${remote_tmp}"
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${_SOURCE}" \
            "sh -s '${remote_tmp}'; rm -f '${remote_tmp}'" << EOF
${_source_probe_script}
EOF
    fi
}

main() {
    _check_router

    local target_file
    target_file=$(mktemp)
    trap "rm -f '${target_file}'" EXIT

    if [ "${#_TARGETS[@]}" -gt 0 ]; then
        for ip in "${_TARGETS[@]}"; do
            printf "%s\t?\tmanual\tmanual\n" "${ip}" >> "${target_file}"
        done
    else
        _discover_targets > "${target_file}"
    fi

    echo ""
    echo "============================================="
    echo " LAN Doctor — ${ROUTER_IP}"
    echo "============================================="
    echo ""

    if [ ! -s "${target_file}" ]; then
        log_warn "No se encontraron targets LAN. Usa --target <IP>."
        exit 0
    fi

    _router_probe "${target_file}"
    _source_probe "${target_file}"

    echo ""
    echo "Notas:"
    echo "  - Si Router->IP=OK pero Origen->IP=FALLA, revisa ruta, firewall o aislamiento entre clientes."
    echo "  - Si el origen no tiene interfaz/ruta hacia 192.168.1.0/24, necesita gateway/ruta por el router OpenWrt."
    echo "  - Si una MAC aparece con lease viejo, renueva DHCP en ese dispositivo."
}

main "$@"
