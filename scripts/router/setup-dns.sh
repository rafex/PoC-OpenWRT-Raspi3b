#!/usr/bin/env bash
# ============================================================================
# setup-dns.sh — Gestión de servidores DNS en OpenWRT
#
# Subcomandos:
#   set    Configura los servidores DNS upstream de dnsmasq
#   show   Muestra la configuración DNS actual
#   reset  Restaura los valores por defecto (1.1.1.1 + 8.8.8.8)
#
# Uso:
#   setup-dns.sh set [--primary 1.1.1.1] [--secondary 8.8.8.8]
#   setup-dns.sh show
#   setup-dns.sh reset
#   setup-dns.sh set --primary 9.9.9.9 --secondary 149.112.112.112
#
# Opciones:
#   --primary <IP>    Servidor DNS primario   (default: 1.1.1.1)
#   --secondary <IP>  Servidor DNS secundario (default: 8.8.8.8)
#   --ip <IP>         IP del router
#   --env <env>       Entorno (default: prod)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

_DEFAULT_PRIMARY="1.1.1.1"
_DEFAULT_SECONDARY="8.8.8.8"

# ---------------------------------------------------------------------------
# Parsear subcomando y opciones
# ---------------------------------------------------------------------------
_SUBCMD=""
_ENV="prod"
_CLI_IP=""
_PRIMARY=""
_SECONDARY=""

_show_help() {
    cat << 'HELP'
Uso: setup-dns.sh <subcomando> [opciones]

Subcomandos:
  set    Configura servidores DNS upstream
  show   Muestra configuración DNS actual
  reset  Restaura DNS por defecto (1.1.1.1 + 8.8.8.8)

Opciones:
  --primary <IP>    Servidor primario   (default: 1.1.1.1 — Cloudflare)
  --secondary <IP>  Servidor secundario (default: 8.8.8.8 — Google)
  --ip <IP>         IP del router
  --env <env>       Entorno (default: prod)

Ejemplos:
  setup-dns.sh set                                          # Cloudflare + Google
  setup-dns.sh set --primary 9.9.9.9                       # Quad9 + Google
  setup-dns.sh set --primary 9.9.9.9 --secondary 149.112.112.112  # Quad9 solo
  setup-dns.sh set --primary 208.67.222.222 --secondary 208.67.220.220  # OpenDNS
  setup-dns.sh show
  setup-dns.sh reset
HELP
}

if [[ $# -eq 0 ]]; then _SUBCMD="show"; else
    case "$1" in
        set|show|reset) _SUBCMD="$1"; shift ;;
        -h|--help) _show_help; exit 0 ;;
        *) log_error "Subcomando desconocido: $1"; _show_help; exit 1 ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)        _CLI_IP="${2:?}";    shift 2 ;;
        --env)       _ENV="${2:?}";       shift 2 ;;
        --primary)   _PRIMARY="${2:?}";   shift 2 ;;
        --secondary) _SECONDARY="${2:?}"; shift 2 ;;
        -h|--help)   _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
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
    local retries=3 delay=4 i=1
    while [ "${i}" -le "${retries}" ]; do
        if ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
            return 0
        fi
        [ "${i}" -lt "${retries}" ] && { log_warn "SSH no disponible, reintentando en ${delay}s... (${i}/${retries})"; sleep "${delay}"; }
        i=$((i + 1))
    done
    log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
    exit 1
}

# ---------------------------------------------------------------------------
# Subcomando: set
# ---------------------------------------------------------------------------
_set() {
    local primary="${_PRIMARY:-${_DEFAULT_PRIMARY}}"
    local secondary="${_SECONDARY:-${_DEFAULT_SECONDARY}}"

    _check_ssh

    echo ""
    log_step "Configurando servidores DNS:"
    echo "   Primario:   ${primary}"
    echo "   Secundario: ${secondary}"
    echo ""

    _ssh sh - << EOF
set -eu
PRIMARY="${primary}"
SECONDARY="${secondary}"

# Limpiar lista existente y establecer nuevos servidores
uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null || true
uci add_list dhcp.@dnsmasq[0].server="\${PRIMARY}"
uci add_list dhcp.@dnsmasq[0].server="\${SECONDARY}"
uci commit dhcp

echo "Reiniciando dnsmasq..."
/etc/init.d/dnsmasq restart 2>/dev/null || true
sleep 1

echo ""
echo "✅ DNS configurado:"
echo "   Primario:   \${PRIMARY}"
echo "   Secundario: \${SECONDARY}"
echo ""
echo "Verificando resolución..."
if ping -c 1 -W 3 "\${PRIMARY}" >/dev/null 2>&1; then
    echo "  ✅ Conectividad con \${PRIMARY} OK"
else
    echo "  ⚠️  Sin respuesta de \${PRIMARY} (puede ser normal si bloquea ICMP)"
fi
nslookup cloudflare.com 2>/dev/null | grep -E "^Address" | tail -1 \
    && echo "  ✅ Resolución DNS OK" \
    || echo "  ❌ La resolución DNS falló"
EOF

    echo ""
    log_info "✅ DNS actualizado en ${ROUTER_IP}"
}

# ---------------------------------------------------------------------------
# Subcomando: show
# ---------------------------------------------------------------------------
_show() {
    _check_ssh

    echo ""
    echo "============================================="
    echo " DNS — Configuración actual"
    echo "============================================="

    _ssh sh - << 'REMOTE'
set -eu

echo ""
echo "--- Servidores upstream configurados (UCI dnsmasq) ---"
SERVERS=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
if [ -n "${SERVERS}" ]; then
    for S in ${SERVERS}; do echo "  ${S}"; done
else
    echo "  (ninguno — se usan los DNS recibidos por DHCP)"
fi

echo ""
echo "--- Interfaces con DNS sobreescritos (UCI network) ---"
for IFACE in wan wwan; do
    DNS=$(uci -q get network.${IFACE}.dns 2>/dev/null || true)
    PDNS=$(uci -q get network.${IFACE}.peerdns 2>/dev/null || echo "1")
    if [ -n "${DNS}" ]; then
        echo "  ${IFACE}: ${DNS}  (peerdns=${PDNS})"
    else
        echo "  ${IFACE}: sin override  (peerdns=${PDNS})"
    fi
done

echo ""
echo "--- resolv.conf ---"
cat /etc/resolv.conf

echo ""
echo "--- Prueba de resolución ---"
nslookup cloudflare.com 2>/dev/null | grep -E "^Address" | tail -1 \
    && echo "  → DNS funcionando" \
    || echo "  → DNS no responde"
REMOTE
}

# ---------------------------------------------------------------------------
# Subcomando: reset
# ---------------------------------------------------------------------------
_reset() {
    log_info "Restaurando DNS por defecto (${_DEFAULT_PRIMARY} + ${_DEFAULT_SECONDARY})..."
    _PRIMARY="${_DEFAULT_PRIMARY}"
    _SECONDARY="${_DEFAULT_SECONDARY}"
    _set
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    case "${_SUBCMD}" in
        set)   _set ;;
        show)  _show ;;
        reset) _reset ;;
    esac
}

main
