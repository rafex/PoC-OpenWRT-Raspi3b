#!/usr/bin/env bash
# ============================================================================
# setup-socks-forward.sh — Port forwarding del proxy SOCKS (Raspi3b/Tor)
#
# Activa o desactiva el reenvío de puertos en el firewall de OpenWRT para
# que dispositivos en la red upstream puedan usar el proxy SOCKS de la
# Raspberry Pi 3b conectada al LAN del router.
#
# Al activar:
#   1. Pide la IP actual de la Raspi3b
#   2. Detecta su MAC en la tabla ARP del router
#   3. Asigna IP estática en DHCP (via setup-static-ip.sh)
#   4. Crea regla DNAT en el firewall (wan:<port> → raspi:<port>)
#
# Subcomandos:
#   enable   Activa el port forwarding
#   disable  Desactiva el port forwarding y elimina la regla
#   status   Muestra el estado actual
#
# Uso:
#   setup-socks-forward.sh enable  [--raspi-ip <IP>] [--port 9050]
#   setup-socks-forward.sh disable [--ip <router>] [--env <env>]
#   setup-socks-forward.sh status  [--ip <router>] [--env <env>]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

# Nombre fijo de la regla UCI — usado para encontrarla y eliminarla
_RULE_NAME="tor_socks_fwd"
_DEFAULT_PORT="9050"

_SUBCMD=""
_ENV="prod"
_CLI_IP=""
_RASPI_IP=""
_PORT=""

# ---------------------------------------------------------------------------
# Ayuda
# ---------------------------------------------------------------------------
_show_help() {
    cat << HELP
Uso: $(basename "$0") <subcomando> [opciones]

Subcomandos:
  enable   Activa el port forwarding del proxy SOCKS
  disable  Desactiva el port forwarding
  status   Muestra el estado actual

Opciones:
  --raspi-ip <IP>  IP actual de la Raspi3b (solo en enable; se pedirá si no se indica)
  --port <puerto>  Puerto SOCKS (default: ${_DEFAULT_PORT})
  --ip <IP>        IP del router (default: env o 192.168.1.1)
  --env <env>      Entorno (default: prod)
  -h, --help       Muestra esta ayuda

Ejemplos:
  $(basename "$0") enable
  $(basename "$0") enable --raspi-ip 192.168.1.100 --port 9050
  $(basename "$0") disable
  $(basename "$0") status
HELP
}

# ---------------------------------------------------------------------------
# Parsear args
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    _show_help; exit 0
fi

_SUBCMD="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)       _CLI_IP="${2:?--ip requiere argumento}";       shift 2 ;;
        --env)      _ENV="${2:?--env requiere argumento}";         shift 2 ;;
        --raspi-ip) _RASPI_IP="${2:?--raspi-ip requiere argumento}"; shift 2 ;;
        --port)     _PORT="${2:?--port requiere argumento}";       shift 2 ;;
        -h|--help)  _show_help; exit 0 ;;
        *) log_error "Argumento desconocido: $1"; _show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Cargar entorno y SSH
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
# shellcheck disable=SC1090
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
        log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
    log_info "Conectado a ${ROUTER_IP}"
}

# ---------------------------------------------------------------------------
# enable — activa el port forwarding
# ---------------------------------------------------------------------------
_enable() {
    _check_ssh

    # Paso 1: IP de la Raspi
    if [ -z "${_RASPI_IP}" ]; then
        echo ""
        read -r -p "  IP actual de la Raspi3b (proxy SOCKS/Tor): " _RASPI_IP
        [ -n "${_RASPI_IP}" ] || { log_error "IP de la Raspi requerida"; exit 1; }
    fi

    # Paso 2: Puerto SOCKS
    local port="${_PORT:-}"
    if [ -z "${port}" ]; then
        read -r -p "  Puerto SOCKS [${_DEFAULT_PORT}]: " port
        port="${port:-${_DEFAULT_PORT}}"
    fi

    # Paso 3: detectar MAC de la Raspi en la tabla ARP del router
    log_step "Buscando MAC de ${_RASPI_IP} en la tabla ARP del router..."
    local raspi_ip="${_RASPI_IP}"
    local raspi_mac
    raspi_mac=$(_ssh sh - << EOF
grep "^${raspi_ip}[[:space:]]" /proc/net/arp 2>/dev/null | awk '{print \$4}' | head -1 || true
EOF
)
    raspi_mac="${raspi_mac:-}"

    if [ -z "${raspi_mac}" ] || [ "${raspi_mac}" = "00:00:00:00:00:00" ]; then
        log_warn "No se encontró la MAC de ${_RASPI_IP} en el ARP del router."
        log_warn "Asegúrate de que la Raspi esté encendida y conectada al LAN del router."
        echo ""
        read -r -p "  MAC de la Raspi (AA:BB:CC:DD:EE:FF), o Enter para omitir IP estática: " raspi_mac
    fi

    # Paso 4: obtener IP wwan del router para mostrarla al final
    local wwan_ip
    wwan_ip=$(_ssh "uci -q get network.wwan.ipaddr 2>/dev/null || true" 2>/dev/null || true)

    # Resumen
    echo ""
    echo "============================================="
    echo " Configuración a aplicar"
    echo "============================================="
    echo "  Router:     ${ROUTER_IP} (wwan: ${wwan_ip:-desconocida})"
    echo "  Raspi IP:   ${_RASPI_IP}"
    echo "  Raspi MAC:  ${raspi_mac:-no detectada — se omite IP estática}"
    echo "  Puerto:     ${port}"
    echo "  Regla UCI:  ${_RULE_NAME}"
    echo ""
    echo "  Efecto: ${wwan_ip:-<wwan>}:${port} → ${_RASPI_IP}:${port} (TCP/DNAT)"
    echo ""
    read -r -p "  ¿Aplicar? (s/N) " confirm
    confirm=$(echo "${confirm}" | tr '[:upper:]' '[:lower:]')
    [ "${confirm}" = "s" ] || { echo "Cancelado."; exit 0; }
    echo ""

    # Paso 5: asignar IP estática en DHCP (solo si tenemos MAC)
    if [ -n "${raspi_mac}" ] && [ "${raspi_mac}" != "00:00:00:00:00:00" ]; then
        log_step "Asignando IP estática a la Raspi (raspi-tor)..."
        "${SCRIPT_DIR}/setup-static-ip.sh" add \
            --mac "${raspi_mac}" \
            --assign "${_RASPI_IP}" \
            --name "raspi-tor" \
            --ip "${ROUTER_IP}" \
            --env "${_ENV}"
    else
        log_warn "Omitiendo asignación de IP estática (MAC no disponible)."
    fi

    # Paso 6: crear regla de port forwarding en el firewall
    log_step "Creando regla de port forwarding (${_RULE_NAME})..."
    local rule_name="${_RULE_NAME}"
    _ssh sh - << EOF
set -eu
RULE_NAME="${rule_name}"
RASPI_IP="${_RASPI_IP}"
PORT="${port}"

# Eliminar regla anterior con el mismo nombre si existe
idx=0
while uci -q get "firewall.@redirect[\${idx}]" >/dev/null 2>&1; do
    name=\$(uci -q get "firewall.@redirect[\${idx}].name" 2>/dev/null || true)
    if [ "\${name}" = "\${RULE_NAME}" ]; then
        uci delete "firewall.@redirect[\${idx}]"
        uci commit firewall
        echo "  Regla anterior eliminada."
        break
    fi
    idx=\$((idx + 1))
done

# Crear nueva regla DNAT
uci add firewall redirect >/dev/null
uci set "firewall.@redirect[-1].name=\${RULE_NAME}"
uci set "firewall.@redirect[-1].src=wan"
uci set "firewall.@redirect[-1].dest=lan"
uci set "firewall.@redirect[-1].proto=tcp"
uci set "firewall.@redirect[-1].src_dport=\${PORT}"
uci set "firewall.@redirect[-1].dest_ip=\${RASPI_IP}"
uci set "firewall.@redirect[-1].dest_port=\${PORT}"
uci set "firewall.@redirect[-1].target=DNAT"
uci set "firewall.@redirect[-1].enabled=1"
uci commit firewall

echo "  ✅ Regla '\${RULE_NAME}' creada: wan:\${PORT} → \${RASPI_IP}:\${PORT} (TCP)"

echo "  Reiniciando firewall..."
/etc/init.d/firewall restart 2>/dev/null && echo "  ✅ Firewall reiniciado" || true
EOF

    echo ""
    log_info "✅ Port forwarding activado"
    echo ""
    echo "  Para usar el proxy SOCKS5 desde el Mac:"
    echo "  ┌─────────────────────────────────────────────────────────────────"
    echo "  │  curl --socks5 ${wwan_ip:-<wwan_ip>}:${port} https://check.torproject.org/api/ip"
    echo "  │"
    echo "  │  O configura en Sistema > Proxies > SOCKS:"
    echo "  │    Host: ${wwan_ip:-<wwan_ip>}    Puerto: ${port}"
    echo "  └─────────────────────────────────────────────────────────────────"
    echo ""
}

# ---------------------------------------------------------------------------
# disable — desactiva el port forwarding
# ---------------------------------------------------------------------------
_disable() {
    _check_ssh
    log_step "Desactivando port forwarding '${_RULE_NAME}'..."

    local rule_name="${_RULE_NAME}"
    _ssh sh - << EOF
set -eu
RULE_NAME="${rule_name}"

idx=0
found=""
while uci -q get "firewall.@redirect[\${idx}]" >/dev/null 2>&1; do
    name=\$(uci -q get "firewall.@redirect[\${idx}].name" 2>/dev/null || true)
    if [ "\${name}" = "\${RULE_NAME}" ]; then
        found="\${idx}"
        break
    fi
    idx=\$((idx + 1))
done

if [ -n "\${found}" ]; then
    dest_ip=\$(uci -q get "firewall.@redirect[\${found}].dest_ip"   2>/dev/null || true)
    port=\$(uci    -q get "firewall.@redirect[\${found}].dest_port" 2>/dev/null || true)
    uci delete "firewall.@redirect[\${found}]"
    uci commit firewall
    echo "  ✅ Regla '\${RULE_NAME}' eliminada (era: → \${dest_ip}:\${port})"
    /etc/init.d/firewall restart 2>/dev/null && echo "  ✅ Firewall reiniciado" || true
else
    echo "  AVISO: No se encontró la regla '\${RULE_NAME}' — ya estaba desactivada."
fi
EOF
    echo ""
}

# ---------------------------------------------------------------------------
# status — muestra el estado del forwarding y la IP estática
# ---------------------------------------------------------------------------
_status() {
    _check_ssh
    echo ""
    echo "============================================="
    echo " Estado — SOCKS Forward (${_RULE_NAME})"
    echo "============================================="

    local rule_name="${_RULE_NAME}"
    _ssh sh - << EOF
set -eu
RULE_NAME="${rule_name}"

# ── Regla de firewall ─────────────────────────────────
echo ""
echo "  Regla de port forwarding:"

idx=0
found=""
while uci -q get "firewall.@redirect[\${idx}]" >/dev/null 2>&1; do
    name=\$(uci -q get "firewall.@redirect[\${idx}].name" 2>/dev/null || true)
    if [ "\${name}" = "\${RULE_NAME}" ]; then
        found="\${idx}"
        break
    fi
    idx=\$((idx + 1))
done

if [ -n "\${found}" ]; then
    dest_ip=\$(uci    -q get "firewall.@redirect[\${found}].dest_ip"    2>/dev/null || true)
    dest_port=\$(uci  -q get "firewall.@redirect[\${found}].dest_port"  2>/dev/null || true)
    src_dport=\$(uci  -q get "firewall.@redirect[\${found}].src_dport"  2>/dev/null || true)
    enabled=\$(uci    -q get "firewall.@redirect[\${found}].enabled"    2>/dev/null || echo "1")
    echo "  ✅ ACTIVO   wan:\${src_dport} → \${dest_ip}:\${dest_port} (TCP/DNAT, enabled=\${enabled})"
else
    echo "  ❌ INACTIVO (regla '\${RULE_NAME}' no encontrada)"
fi

# ── IP wwan del router ────────────────────────────────
echo ""
echo "  IP wwan del router:"
wwan_ip=\$(uci -q get network.wwan.ipaddr 2>/dev/null || true)
if [ -n "\${wwan_ip}" ]; then
    echo "    \${wwan_ip}"
else
    echo "    (wwan no disponible)"
fi

# ── IP estática de la Raspi ───────────────────────────
echo ""
echo "  IP estática DHCP (raspi-tor):"
idx2=0
found2=""
while uci -q get "dhcp.@host[\${idx2}]" >/dev/null 2>&1; do
    hname=\$(uci -q get "dhcp.@host[\${idx2}].name" 2>/dev/null || true)
    if [ "\${hname}" = "raspi-tor" ]; then
        found2="\${idx2}"
        break
    fi
    idx2=\$((idx2 + 1))
done

if [ -n "\${found2}" ]; then
    hmac=\$(uci -q get "dhcp.@host[\${found2}].mac" 2>/dev/null || true)
    hip=\$(uci  -q get "dhcp.@host[\${found2}].ip"  2>/dev/null || true)
    echo "  ✅ \${hmac} → \${hip}  (raspi-tor)"
else
    echo "  — (sin entrada estática para raspi-tor)"
fi

echo ""
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${_SUBCMD}" in
    enable)  _enable ;;
    disable) _disable ;;
    status)  _status ;;
    -h|--help) _show_help ;;
    *) log_error "Subcomando desconocido: ${_SUBCMD}"; _show_help; exit 1 ;;
esac
