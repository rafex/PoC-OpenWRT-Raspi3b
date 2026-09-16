#!/usr/bin/env bash
# ============================================================================
# setup-dhcp-lease.sh — Política de duración del lease DHCP en OpenWRT
#
# Controla cuánto tiempo dnsmasq deja a un dispositivo "reservado" en una IP
# dinámica antes de que el lease expire (option leasetime, UCI dhcp).
#
# Subcomandos:
#   set    Configura la duración del lease
#   show   Muestra la duración configurada y los leases activos
#   reset  Restaura el default de OpenWRT (12h)
#
# Uso:
#   setup-dhcp-lease.sh set --leasetime 24h
#   setup-dhcp-lease.sh set --leasetime 8h --interface lan
#   setup-dhcp-lease.sh show
#   setup-dhcp-lease.sh reset
#
# Opciones:
#   --leasetime <valor>  Duración del lease: <n>h, <n>m, <n>s, o "infinite"
#   --interface <nombre> Interfaz DHCP a modificar (default: lan)
#   --ip <IP>            IP del router
#   --env <env>          Entorno (default: prod)
#
# Nota: cambiar el leasetime NO afecta leases ya otorgados — solo aplica a
# leases nuevos o renovados desde el cambio en adelante. Un dispositivo ya
# conectado conserva su lease anterior hasta que expire o renueve.
# ============================================================================
set -euo pipefail
ROUTER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROUTER_SCRIPT_DIR}/../commons/router-base.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

_DEFAULT_LEASETIME="12h"
_DEFAULT_INTERFACE="lan"

# ---------------------------------------------------------------------------
# Parsear subcomando y opciones
# ---------------------------------------------------------------------------
_SUBCMD=""
ROUTER_ENV="prod"
_ROUTER_IP_CLI=""
_LEASETIME=""
_INTERFACE=""

_show_help() {
    cat << 'HELP'
Uso: setup-dhcp-lease.sh <subcomando> [opciones]

Subcomandos:
  set    Configura la duración del lease DHCP
  show   Muestra la duración actual y los leases activos
  reset  Restaura el default de OpenWRT (12h)

Opciones:
  --leasetime <valor>   Duración: <n>h, <n>m, <n>s, o "infinite"
  --interface <nombre>  Interfaz DHCP (default: lan)
  --ip <IP>             IP del router
  --env <env>           Entorno (default: prod)

Ejemplos:
  setup-dhcp-lease.sh set --leasetime 24h
  setup-dhcp-lease.sh set --leasetime 8h
  setup-dhcp-lease.sh show
  setup-dhcp-lease.sh reset

Nota: cambiar el leasetime no afecta leases ya otorgados, solo los nuevos
o renovados a partir del cambio.
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
        --ip)         _ROUTER_IP_CLI="${2:?--ip requiere argumento}";    shift 2 ;;
        --env)        ROUTER_ENV="${2:?--env requiere argumento}";       shift 2 ;;
        --leasetime)  _LEASETIME="${2:?--leasetime requiere argumento}"; shift 2 ;;
        --interface)  _INTERFACE="${2:?--interface requiere argumento}"; shift 2 ;;
        -h|--help)    _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Cargar entorno
# ---------------------------------------------------------------------------
router_load_env "${ROUTER_ENV}"

# ---------------------------------------------------------------------------
# Validaciones
# ---------------------------------------------------------------------------
_validate_leasetime() {
    local value="$1"
    case "${value}" in
        infinite) return 0 ;;
        [0-9]*[hms])
            local number="${value%[hms]}"
            case "${number}" in ''|*[!0-9]*) return 1 ;; esac
            [ "${number}" -gt 0 ] 2>/dev/null || return 1
            return 0
            ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Subcomando: set
# ---------------------------------------------------------------------------
_set() {
    local leasetime="${_LEASETIME:?Especifica --leasetime <valor>}"
    local iface="${_INTERFACE:-${_DEFAULT_INTERFACE}}"

    _validate_leasetime "${leasetime}" \
        || { log_error "Leasetime inválido: ${leasetime} (esperado: <n>h, <n>m, <n>s, o \"infinite\")"; exit 1; }

    router_check_ssh

    echo ""
    log_step "Configurando duración de lease DHCP:"
    echo "   Interfaz:   ${iface}"
    echo "   Leasetime:  ${leasetime}"
    echo ""
    log_warn "No afecta leases ya otorgados — solo los nuevos o renovados desde ahora."
    echo ""

    router_ssh sh - << EOF
set -eu
IFACE="${iface}"
LEASETIME="${leasetime}"

uci set "dhcp.\${IFACE}.leasetime=\${LEASETIME}"
uci commit dhcp

echo "Reiniciando dnsmasq..."
/etc/init.d/dnsmasq restart 2>/dev/null || true
sleep 1

echo ""
echo "✅ Leasetime de \${IFACE} configurado en \${LEASETIME}"
EOF

    echo ""
    log_info "✅ Lease DHCP actualizado en ${ROUTER_IP}"
}

# ---------------------------------------------------------------------------
# Subcomando: show
# ---------------------------------------------------------------------------
_show() {
    local iface="${_INTERFACE:-${_DEFAULT_INTERFACE}}"

    router_check_ssh

    echo ""
    echo "============================================="
    echo " Lease DHCP — Configuración actual"
    echo "============================================="

    router_ssh sh - << EOF
set -eu
IFACE="${iface}"

echo ""
echo "--- Duración de lease (UCI dhcp.\${IFACE}.leasetime) ---"
LEASETIME=\$(uci -q get "dhcp.\${IFACE}.leasetime" 2>/dev/null || true)
if [ -n "\${LEASETIME}" ]; then
    echo "  \${LEASETIME}"
else
    echo "  (sin configurar — dnsmasq usa su default, típicamente 12h)"
fi

echo ""
echo "--- Leases DHCP activos ---"
if [ -f /tmp/dhcp.leases ]; then
    printf "  %-12s %-20s %-16s %s\n" "Expiración" "MAC" "IP" "Hostname"
    echo "  ─────────────────────────────────────────────"
    while read -r exp mac ip host _rest; do
        printf "  %-12s %-20s %-16s %s\n" "\${exp}" "\${mac}" "\${ip}" "\${host}"
    done < /tmp/dhcp.leases
else
    echo "  (sin leases activos)"
fi
EOF
}

# ---------------------------------------------------------------------------
# Subcomando: reset
# ---------------------------------------------------------------------------
_reset() {
    log_info "Restaurando leasetime por defecto (${_DEFAULT_LEASETIME})..."
    _LEASETIME="${_DEFAULT_LEASETIME}"
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
