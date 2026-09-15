#!/usr/bin/env bash
# ============================================================================
# setup-usb-tether.sh — Uplink via tethering USB (RNDIS/CDC-Ethernet)
#
# Usa el teléfono conectado por USB (con "Compartir internet"/tethering
# activado) como fuente de internet alternativa, igual que setup-wifi.sh
# hace con un cliente WiFi (interfaz wwan) pero para el dispositivo de red
# que aparece cuando el teléfono expone RNDIS o CDC-Ethernet por USB.
#
# Prerrequisito: activar tethering/"Compartir internet" en el teléfono.
# El kernel del router debe tener cargados kmod-usb-net-rndis o
# kmod-usb-net-cdc-ether (ver config/openwrt-packages.toml).
#
# Subcomandos:
#   enable   Detecta el dispositivo USB de red y lo configura como uplink
#   disable  Retira la interfaz usbwan (no toca el dispositivo USB en sí)
#   status   Muestra el dispositivo detectado y el estado de usbwan
#
# Uso:
#   setup-usb-tether.sh enable  [--ip <IP>] [--env <env>]
#   setup-usb-tether.sh disable [--ip <IP>] [--env <env>]
#   setup-usb-tether.sh status  [--ip <IP>] [--env <env>]
# ============================================================================
set -euo pipefail
ROUTER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROUTER_SCRIPT_DIR}/../commons/router-base.sh"

readonly UCI_IFACE="usbwan"

_SUBCMD=""
ROUTER_ENV="prod"
_ROUTER_IP_CLI=""

_show_help() {
    cat << 'HELP'
Uso: setup-usb-tether.sh <subcomando> [opciones]

Subcomandos:
  enable    Detecta el dispositivo USB de red (RNDIS/CDC-Ethernet) y lo
            configura como interfaz de uplink (usbwan, DHCP, zona wan)
  disable   Retira usbwan; no toca el dispositivo USB ni el teléfono
  status    Dispositivo USB detectado + estado de usbwan (IP, gateway)

Opciones:
  --ip <IP>    IP del router (default: de .env.public o 192.168.1.1)
  --env <env>  Entorno (default: prod)

Prerrequisito: activar "Compartir internet"/tethering USB en el teléfono
ANTES de correr 'enable' — si el teléfono está en modo carga/almacenamiento
no aparece ningún dispositivo de red para detectar.
HELP
}

if [[ $# -eq 0 ]]; then _show_help; exit 1; fi

case "$1" in
    enable|disable|status) _SUBCMD="$1"; shift ;;
    -h|--help) _show_help; exit 0 ;;
    *) log_error "Subcomando desconocido: $1"; echo "   Usa: $0 --help"; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)  _ROUTER_IP_CLI="${2:?--ip requiere argumento}"; shift 2 ;;
        --env) ROUTER_ENV="${2:?--env requiere argumento}"; shift 2 ;;
        -h|--help) _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
    esac
done

router_load_env "${ROUTER_ENV}"

# ---------------------------------------------------------------------------
# _detect_usb_net_iface — busca por driver (rndis_host o cdc_ether), no por
# nombre fijo: "usb0" es lo que asignó el kernel esta vez, pero no hay
# garantía de que sea siempre así tras reconexiones/reinicios.
# Salida: nombre de interfaz en stdout, o nada + exit 1 si no encuentra.
# ---------------------------------------------------------------------------
_detect_usb_net_iface() {
    router_ssh sh - << 'REMOTE'
set -eu
for dev in /sys/class/net/*/; do
    d=$(basename "$dev")
    drv=$(cat "${dev}device/uevent" 2>/dev/null | grep '^DRIVER=' | cut -d= -f2)
    case "$drv" in
        rndis_host|cdc_ether) echo "$d"; exit 0 ;;
    esac
done
exit 1
REMOTE
}

# ---------------------------------------------------------------------------
# Subcomando: enable
# ---------------------------------------------------------------------------
_enable() {
    router_check_ssh

    log_step "Buscando dispositivo de red USB (rndis_host/cdc_ether)..."
    local iface
    if ! iface=$(_detect_usb_net_iface); then
        log_error "No se detectó ningún dispositivo de red USB."
        echo "   Activa 'Compartir internet' / USB tethering en el teléfono primero."
        echo "   Si ya lo activaste, revisa: scripts/router/setup-usb-tether.sh status"
        exit 1
    fi
    log_info "   ✅ Detectado: ${iface}"

    echo ""
    log_step "Configurando '${UCI_IFACE}' (DHCP) sobre ${iface}..."

    router_ssh sh - << EOF
set -eu
IFACE="${iface}"
UCI_IFACE="${UCI_IFACE}"

uci -q delete network.\${UCI_IFACE} 2>/dev/null || true
uci set network.\${UCI_IFACE}=interface
uci set network.\${UCI_IFACE}.proto='dhcp'
uci set network.\${UCI_IFACE}.device="\${IFACE}"
uci commit network

echo "Añadiendo '\${UCI_IFACE}' a zona firewall WAN..."
WAN_ZONE=""
I=0
while true; do
    NAME=\$(uci -q get firewall.@zone[\$I].name 2>/dev/null) || break
    if [ "\$NAME" = "wan" ]; then
        WAN_ZONE=\$I
        break
    fi
    I=\$((I+1))
done
if [ -n "\$WAN_ZONE" ]; then
    NETS=\$(uci -q get firewall.@zone[\$WAN_ZONE].network 2>/dev/null || echo "")
    echo "\$NETS" | grep -qw "\${UCI_IFACE}" || uci add_list firewall.@zone[\$WAN_ZONE].network="\${UCI_IFACE}"
    uci commit firewall
fi

echo "Aplicando configuración..."
/etc/init.d/network restart 2>/dev/null || true
/etc/init.d/firewall reload 2>/dev/null || true

echo ""
echo "✅ '\${UCI_IFACE}' configurado sobre \${IFACE} (DHCP, zona wan)"
EOF

    echo ""
    log_info "✅ Tethering USB configurado como uplink."
    echo "   Espera unos segundos y verifica con:"
    echo "   scripts/router/setup-usb-tether.sh status"
}

# ---------------------------------------------------------------------------
# Subcomando: disable
# ---------------------------------------------------------------------------
_disable() {
    router_check_ssh

    echo "============================================="
    echo " Tethering USB — Desactivar uplink"
    echo "============================================="

    router_ssh sh - << EOF
set -eu
UCI_IFACE="${UCI_IFACE}"

if ! uci -q get network.\${UCI_IFACE} >/dev/null 2>&1; then
    echo "  '\${UCI_IFACE}' no estaba configurado — nada que hacer."
    exit 0
fi

echo "  Eliminando interfaz de red '\${UCI_IFACE}'..."
uci delete network.\${UCI_IFACE}
uci commit network

Z=0
while true; do
    NAME=\$(uci -q get firewall.@zone[\$Z].name 2>/dev/null) || break
    if [ "\$NAME" = "wan" ]; then
        NETS=\$(uci -q get firewall.@zone[\$Z].network 2>/dev/null || echo "")
        if echo "\$NETS" | grep -qw "\${UCI_IFACE}"; then
            uci del_list firewall.@zone[\$Z].network="\${UCI_IFACE}" 2>/dev/null || true
            uci commit firewall
            echo "  Eliminado '\${UCI_IFACE}' de zona firewall wan"
        fi
        break
    fi
    Z=\$((Z+1))
done

/etc/init.d/network restart 2>/dev/null || true
/etc/init.d/firewall reload 2>/dev/null || true
echo "✅ '\${UCI_IFACE}' retirado. El dispositivo USB no fue tocado."
EOF
}

# ---------------------------------------------------------------------------
# Subcomando: status
# ---------------------------------------------------------------------------
_status() {
    router_check_ssh

    echo ""
    echo "============================================="
    echo " Tethering USB — Estado"
    echo "============================================="
    echo ""

    log_step "Dispositivo de red USB..."
    local iface
    if iface=$(_detect_usb_net_iface); then
        log_info "   ✅ Detectado: ${iface}"
    else
        log_warn "   ⚠️  Ningún dispositivo de red USB presente ahora mismo"
        echo "      (activa tethering en el teléfono, o revisa la conexión física)"
    fi

    echo ""
    echo "--- Configuración UCI ---"
    router_ssh "uci -q get network.${UCI_IFACE} >/dev/null 2>&1 && uci show network.${UCI_IFACE} || echo '  ${UCI_IFACE} no configurado'"

    # Estado en vivo — via ubus/ifstatus (netifd), NO "ip addr show ${UCI_IFACE}":
    # 'usbwan' es un nombre lógico UCI, no un dispositivo de kernel; el
    # dispositivo real (l3_device, ej. usb0) solo se conoce a través de
    # ifstatus. Mismo patrón que ya usa scripts/router/status.sh.
    echo ""
    echo "--- Estado en vivo (ifstatus ${UCI_IFACE}) ---"
    router_ssh sh - << EOF
set -eu
json_get() {
    awk -v key="\"\$1\"" '
        index(\$0, key) {
            sub(/^[^:]*: */, "")
            gsub(/[",]/, "")
            gsub(/^[ \t]+|[ \t]+\$/, "")
            print
            exit
        }
    '
}

if ! command -v ifstatus >/dev/null 2>&1; then
    echo "  (ifstatus no disponible)"
    exit 0
fi

RAW=\$(ifstatus "${UCI_IFACE}" 2>/dev/null) || { echo "  '${UCI_IFACE}' no existe como interfaz de red"; exit 0; }

UP=\$(echo "\${RAW}" | json_get up)
DEV=\$(echo "\${RAW}" | json_get l3_device)
ADDR=\$(echo "\${RAW}" | json_get address)
GW=\$(echo "\${RAW}" | json_get nexthop)

printf "  activa:      %s\n" "\${UP:-?}"
printf "  dispositivo: %s\n" "\${DEV:-?}"
printf "  IP:          %s\n" "\${ADDR:-(sin IP)}"
printf "  gateway:     %s\n" "\${GW:-(sin gateway anunciado por DHCP)}"
EOF
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    case "${_SUBCMD}" in
        enable)  _enable ;;
        disable) _disable ;;
        status)  _status ;;
        *)
            log_error "Subcomando vacío. Usa: enable | disable | status"
            exit 1
            ;;
    esac
}

main
