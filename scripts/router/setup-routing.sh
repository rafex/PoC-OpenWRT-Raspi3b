#!/usr/bin/env bash
# ============================================================================
# setup-routing.sh — Prioridad de rutas y enrutamiento en OpenWRT
#
# Gestiona qué interfaz (WAN físico o cliente WiFi "wwan") se usa como
# gateway por defecto, y permite fijar IPs LAN a una interfaz concreta
# mediante source-based routing (ip rule + ip route).
#
# Subcomandos:
#   status     Muestra rutas, gateways activos y métricas
#   priority   Define la interfaz preferida: wan | wifi | equal
#   pin        Fija tráfico de una IP LAN a una interfaz concreta
#   unpin      Elimina el pin de una IP LAN
#   pins       Lista pins activos en el router
#   reset      Elimina todos los pins y restaura prioridad a wan
#
# Uso:
#   setup-routing.sh status   [--ip <IP>] [--env <env>]
#   setup-routing.sh priority <wan|wifi|equal> [--ip <IP>] [--env <env>]
#   setup-routing.sh pin   --from <IP_LAN> --via <wan|wifi> [--ip <IP>] [--env <env>]
#   setup-routing.sh unpin --from <IP_LAN> [--ip <IP>] [--env <env>]
#   setup-routing.sh pins  [--ip <IP>] [--env <env>]
#   setup-routing.sh reset [--ip <IP>] [--env <env>]
#
# Notas:
#   - "wifi" en este script = interfaz wwan (cliente WiFi creada por setup-wifi.sh client)
#   - Los pins persisten en /etc/routing-pins.conf y se restauran en cada boot
#     mediante un hotplug script en /etc/hotplug.d/iface/50-routing-pins
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
_SUBCMD=""
_ENV="prod"
_CLI_IP=""
_PRIORITY=""
_FROM=""
_VIA=""

# Constantes del router (valores numéricos para evitar expansión en heredocs)
readonly _PINS_FILE="/etc/routing-pins.conf"
readonly _HOTPLUG_FILE="/etc/hotplug.d/iface/50-routing-pins"
# Tablas de routing: 100=wan, 200=wifi(wwan)

_show_help() {
    cat <<HELP
Uso: $(basename "$0") <subcomando> [opciones]

Subcomandos:
  status                     Muestra rutas, gateways y métricas actuales
  priority <wan|wifi|equal>  Define la interfaz de salida preferida
  pin --from <IP> --via <wan|wifi>  Fija tráfico de una IP LAN a una interfaz
  unpin --from <IP>          Elimina el pin de una IP LAN
  pins                       Lista todos los pins activos
  reset                      Elimina todos los pins y restaura prioridad wan

Opciones:
  --from <IP>   IP LAN origen del tráfico a fijar (para pin/unpin)
  --via <iface> Interfaz destino: wan | wifi  (para pin)
  --ip <IP>     IP del router (default: env o 192.168.1.1)
  --env <env>   Entorno (default: prod)

Ejemplos:
  $(basename "$0") status
  $(basename "$0") priority wifi           # prefiere WiFi cliente como salida
  $(basename "$0") priority wan            # prefiere WAN como salida
  $(basename "$0") priority equal          # ambas con misma prioridad
  $(basename "$0") pin --from 192.168.1.50 --via wifi   # laptop siempre por WiFi
  $(basename "$0") pin --from 192.168.1.51 --via wan    # servidor siempre por WAN
  $(basename "$0") unpin --from 192.168.1.50
  $(basename "$0") pins
  $(basename "$0") reset
HELP
}

# ---------------------------------------------------------------------------
# Parsear subcomando y opciones
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    _show_help; exit 0
fi

_SUBCMD="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)    _CLI_IP="${2:?--ip requiere argumento}"; shift 2 ;;
        --env)   _ENV="${2:?--env requiere argumento}"; shift 2 ;;
        --from)  _FROM="${2:?--from requiere argumento}"; shift 2 ;;
        --via)   _VIA="${2:?--via requiere argumento}"; shift 2 ;;
        wan|wifi|equal) _PRIORITY="$1"; shift ;;
        -h|--help) _show_help; exit 0 ;;
        *) log_error "Argumento desconocido: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Cargar entorno
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
if [ -f "${ENV_FILE}" ]; then
    set -a; source "${ENV_FILE}"; set +a
fi

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
            -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" "exit" 2>/dev/null; then
        log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
    log_info "Conectado a ${ROUTER_IP}"
}

# ---------------------------------------------------------------------------
# Validar IP (POSIX)
# ---------------------------------------------------------------------------
_validate_ip() {
    local ip="$1"
    case "${ip}" in
        ""|*[!0-9.]*) return 1 ;;
    esac
    local IFS='.'
    # shellcheck disable=SC2086
    set -- ${ip}
    [ "$#" -eq 4 ] || return 1
    for octet in "$@"; do
        [ -n "${octet}" ] || return 1
        [ "${octet}" -ge 0 ] 2>/dev/null && [ "${octet}" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Genera el script hotplug que restaura los pins en cada arranque de interfaz
# (marcador quoted → sin expansión local; el script es POSIX sh puro)
# ---------------------------------------------------------------------------
_gen_hotplug() {
    cat << 'HOTPLUG'
#!/bin/sh
# Restaura source-based routing (pins) cuando sube wan o wwan
PINS="/etc/routing-pins.conf"
[ -f "${PINS}" ] || exit 0
[ "${ACTION}" = "ifup" ]   || exit 0
case "${INTERFACE}" in wan|wwan) : ;; *) exit 0 ;; esac

# Registrar tablas personalizadas si no existen
grep -q "^100 " /etc/iproute2/rt_tables 2>/dev/null || \
    echo "100 routing_wan"  >> /etc/iproute2/rt_tables
grep -q "^200 " /etc/iproute2/rt_tables 2>/dev/null || \
    echo "200 routing_wifi" >> /etc/iproute2/rt_tables

# Detectar gateways de cada interfaz
wan_gw=$(ip route show dev wan  2>/dev/null | awk '/^default/{print $3;exit}')
wifi_gw=$(ip route show dev wwan 2>/dev/null | awk '/^default/{print $3;exit}')

# Actualizar rutas en las tablas dedicadas
[ -n "${wan_gw}"  ] && ip route replace default via "${wan_gw}"  dev wan  table 100 2>/dev/null || true
[ -n "${wifi_gw}" ] && ip route replace default via "${wifi_gw}" dev wwan table 200 2>/dev/null || true

# Aplicar regla ip rule por cada pin
priority=100
while read -r from_ip via_iface; do
    case "${from_ip}" in '#'*|'') continue ;; esac
    case "${via_iface}" in
        wan)  table=100 ;;
        wifi) table=200 ;;
        *)    continue  ;;
    esac
    ip rule del from "${from_ip}" lookup "${table}" priority "${priority}" 2>/dev/null || true
    ip rule add from "${from_ip}" lookup "${table}" priority "${priority}"
    priority=$((priority + 1))
done < "${PINS}"
HOTPLUG
}

# ---------------------------------------------------------------------------
# _apply_pins_now — aplica inmediatamente las reglas del fichero de pins
# ---------------------------------------------------------------------------
_apply_pins_now() {
    _ssh sh - << 'REMOTE'
PINS="/etc/routing-pins.conf"
[ -f "${PINS}" ] || { echo "Sin pins que aplicar."; exit 0; }

grep -q "^100 " /etc/iproute2/rt_tables 2>/dev/null || \
    echo "100 routing_wan"  >> /etc/iproute2/rt_tables
grep -q "^200 " /etc/iproute2/rt_tables 2>/dev/null || \
    echo "200 routing_wifi" >> /etc/iproute2/rt_tables

wan_gw=$(ip route show dev wan  2>/dev/null | awk '/^default/{print $3;exit}')
wifi_gw=$(ip route show dev wwan 2>/dev/null | awk '/^default/{print $3;exit}')

[ -n "${wan_gw}"  ] && ip route replace default via "${wan_gw}"  dev wan  table 100 2>/dev/null || true
[ -n "${wifi_gw}" ] && ip route replace default via "${wifi_gw}" dev wwan table 200 2>/dev/null || true

priority=100
while read -r from_ip via_iface; do
    case "${from_ip}" in '#'*|'') continue ;; esac
    case "${via_iface}" in
        wan)  table=100 ;;
        wifi) table=200 ;;
        *)    continue  ;;
    esac
    ip rule del from "${from_ip}" lookup "${table}" 2>/dev/null || true
    ip rule add from "${from_ip}" lookup "${table}" priority "${priority}"
    priority=$((priority + 1))
done < "${PINS}"
echo "✅ Reglas de enrutamiento aplicadas"
REMOTE
}

# ---------------------------------------------------------------------------
# Subcomandos
# ---------------------------------------------------------------------------

_status() {
    echo "============================================="
    echo " Routing Status — ${ROUTER_IP}"
    echo "============================================="
    _ssh sh << 'REMOTE'
echo ""
echo "=== Rutas por defecto ==="
ip route show default

echo ""
echo "=== Tabla de rutas completa ==="
ip route show

echo ""
echo "=== Interfaces de red ==="
ip -brief addr show

echo ""
echo "=== Métricas UCI ==="
wan_m=$(uci -q get network.wan.metric  2>/dev/null || echo "no configurado")
wwan_m=$(uci -q get network.wwan.metric 2>/dev/null || echo "interfaz wwan no existe")
printf "  wan  metric: %s\n"  "${wan_m}"
printf "  wwan metric: %s\n" "${wwan_m}"

echo ""
echo "=== Reglas ip rule (activas) ==="
ip rule show | grep -v "^0:" | grep -v "^32766:" | grep -v "^32767:" \
    || echo "  (ninguna regla adicional)"

echo ""
echo "=== Pins guardados ==="
PINS="/etc/routing-pins.conf"
if [ -f "${PINS}" ] && [ -s "${PINS}" ]; then
    printf "  %-20s %s\n" "IP LAN origen" "Vía"
    echo "  ─────────────────────────────"
    while read -r from_ip via_iface; do
        case "${from_ip}" in '#'*|'') continue ;; esac
        printf "  %-20s %s\n" "${from_ip}" "${via_iface}"
    done < "${PINS}"
else
    echo "  (sin pins configurados)"
fi

echo ""
echo "=== mwan3 ==="
if command -v mwan3 >/dev/null 2>&1; then
    mwan3 status 2>/dev/null || echo "  mwan3 instalado pero sin configurar"
else
    echo "  mwan3 no instalado"
    echo "  Para balanceo avanzado: apk -U add mwan3"
fi
REMOTE
}

_priority() {
    if [ -z "${_PRIORITY}" ]; then
        log_error "Especifica el modo: wan | wifi | equal"
        echo "Uso: $(basename "$0") priority <wan|wifi|equal>"
        exit 1
    fi

    local wan_metric wwan_metric
    case "${_PRIORITY}" in
        wan)   wan_metric=0;  wwan_metric=10 ;;
        wifi)  wan_metric=10; wwan_metric=0  ;;
        equal) wan_metric=0;  wwan_metric=0  ;;
        *) log_error "Modo inválido: ${_PRIORITY}. Usa: wan|wifi|equal"; exit 1 ;;
    esac

    echo "============================================="
    echo " Prioridad de routing — ${_PRIORITY}"
    echo "============================================="
    echo "   wan  metric: ${wan_metric}"
    echo "   wwan metric: ${wwan_metric}"
    echo ""

    _ssh sh - << REMOTE
set -eu
if ! uci -q get network.wwan >/dev/null 2>&1; then
    echo "AVISO: interfaz wwan no configurada."
    echo "       Usa 'just wifi-client' para conectar como cliente WiFi."
fi
uci set network.wan.metric=${wan_metric}
if uci -q get network.wwan >/dev/null 2>&1; then
    uci set network.wwan.metric=${wwan_metric}
fi
uci commit network
/etc/init.d/network restart
echo "✅ Prioridad configurada: ${_PRIORITY}"
REMOTE
}

_pin() {
    [ -n "${_FROM}" ] || { log_error "Especifica --from <IP_LAN>"; exit 1; }
    [ -n "${_VIA}"  ] || { log_error "Especifica --via <wan|wifi>"; exit 1; }
    _validate_ip "${_FROM}" || { log_error "IP inválida: ${_FROM}"; exit 1; }
    case "${_VIA}" in wan|wifi) : ;; *) log_error "--via debe ser wan o wifi"; exit 1 ;; esac

    echo "============================================="
    echo " Pin: ${_FROM} → ${_VIA}"
    echo "============================================="

    # Instalar hotplug si no existe
    if ! _ssh "[ -f '${_HOTPLUG_FILE}' ]" 2>/dev/null; then
        log_step "Instalando script hotplug de persistencia..."
        _gen_hotplug | _ssh "mkdir -p /etc/hotplug.d/iface && cat > '${_HOTPLUG_FILE}' && chmod +x '${_HOTPLUG_FILE}'"
    fi

    # Guardar pin en el fichero del router
    _ssh sh - << REMOTE
set -eu
PINS="${_PINS_FILE}"
FROM="${_FROM}"
VIA="${_VIA}"

[ -f "\${PINS}" ] || touch "\${PINS}"

if grep -q "^\${FROM} " "\${PINS}" 2>/dev/null; then
    tmp=\$(mktemp)
    grep -v "^\${FROM} " "\${PINS}" > "\${tmp}" || true
    mv "\${tmp}" "\${PINS}"
    echo "  (actualizando pin existente)"
fi

printf '%s %s\n' "\${FROM}" "\${VIA}" >> "\${PINS}"
echo "✅ Pin guardado: \${FROM} → \${VIA}"
REMOTE

    _apply_pins_now
}

_unpin() {
    [ -n "${_FROM}" ] || { log_error "Especifica --from <IP_LAN>"; exit 1; }
    _validate_ip "${_FROM}" || { log_error "IP inválida: ${_FROM}"; exit 1; }

    log_step "Eliminando pin para ${_FROM}"

    _ssh sh - << REMOTE
set -eu
PINS="${_PINS_FILE}"
FROM="${_FROM}"

if [ ! -f "\${PINS}" ]; then
    echo "Sin pins configurados."
    exit 0
fi

# Eliminar reglas ip rule para esta IP (en ambas tablas)
ip rule del from "\${FROM}" lookup 100 2>/dev/null || true
ip rule del from "\${FROM}" lookup 200 2>/dev/null || true

if grep -q "^\${FROM} " "\${PINS}" 2>/dev/null; then
    tmp=\$(mktemp)
    grep -v "^\${FROM} " "\${PINS}" > "\${tmp}" || true
    mv "\${tmp}" "\${PINS}"
    echo "✅ Pin eliminado: \${FROM}"
else
    echo "AVISO: no existía pin para \${FROM}"
fi
REMOTE
}

_list_pins() {
    _ssh sh << 'REMOTE'
PINS="/etc/routing-pins.conf"
echo ""
if [ ! -f "${PINS}" ] || [ ! -s "${PINS}" ]; then
    echo "Sin pins configurados."
else
    echo "  Pins de enrutamiento:"
    printf "  %-20s %s\n" "IP LAN origen" "Vía"
    echo "  ─────────────────────────────"
    while read -r from_ip via_iface; do
        case "${from_ip}" in '#'*|'') continue ;; esac
        printf "  %-20s %s\n" "${from_ip}" "${via_iface}"
    done < "${PINS}"
fi
echo ""
echo "  Reglas ip rule activas (priority 100-299):"
ip rule show | awk -F: '$1+0 >= 100 && $1+0 < 300 {print "  " $0}' \
    || echo "  (ninguna)"
REMOTE
}

_reset() {
    echo "============================================="
    echo " Reset — Eliminar pins y restaurar WAN"
    echo "============================================="

    _ssh sh - << 'REMOTE'
set -eu
# Eliminar reglas ip rule de pins (priority 100-299)
i=100
while [ "${i}" -lt 300 ]; do
    ip rule del priority "${i}" 2>/dev/null || true
    i=$((i + 1))
done

# Limpiar tablas de routing personalizadas
ip route flush table 100 2>/dev/null || true
ip route flush table 200 2>/dev/null || true

# Eliminar archivos de configuración
rm -f /etc/routing-pins.conf
rm -f /etc/hotplug.d/iface/50-routing-pins

# Restaurar métrica UCI: wan preferido
uci -q set network.wan.metric=0
if uci -q get network.wwan >/dev/null 2>&1; then
    uci -q set network.wwan.metric=10
fi
uci commit network

echo "✅ Enrutamiento reseteado: WAN prioritario, sin pins"
echo "   Si los cambios no son inmediatos: /etc/init.d/network restart"
REMOTE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${_SUBCMD}" in
    status)   _check_ssh; _status ;;
    priority) _check_ssh; _priority ;;
    pin)      _check_ssh; _pin ;;
    unpin)    _check_ssh; _unpin ;;
    pins)     _check_ssh; _list_pins ;;
    reset)    _check_ssh; _reset ;;
    -h|--help) _show_help ;;
    *) log_error "Subcomando desconocido: ${_SUBCMD}"; _show_help; exit 1 ;;
esac
