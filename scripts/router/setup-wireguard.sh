#!/usr/bin/env bash
# ============================================================================
# setup-wireguard.sh — Gestión de WireGuard en OpenWRT
#
# Subcomandos:
#   status      Muestra estado del túnel y peers conectados
#   enable      Activa la interfaz wg0
#   disable     Desactiva la interfaz wg0
#   peer-list   Lista los peers configurados en UCI
#   peer-add    Añade un peer (public key + endpoint + allowed IPs)
#   peer-remove Elimina un peer por su clave pública
#
# Uso:
#   setup-wireguard.sh status
#   setup-wireguard.sh enable|disable
#   setup-wireguard.sh peer-list
#   setup-wireguard.sh peer-add --pubkey <key> --endpoint <IP:port> \
#                                --allowed-ips <CIDR> [--name <nombre>]
#   setup-wireguard.sh peer-remove --pubkey <key>
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

_SUBCMD=""
_ENV="prod"
_CLI_IP=""
_PUBKEY=""
_ENDPOINT=""
_ALLOWED_IPS=""
_PEER_NAME=""

_show_help() {
    cat << 'HELP'
Uso: setup-wireguard.sh <subcomando> [opciones]

Subcomandos:
  status       Muestra estado del túnel wg0 y peers activos
  enable       Activa la interfaz WireGuard (wg0)
  disable      Desactiva la interfaz WireGuard (wg0)
  peer-list    Lista peers configurados en UCI
  peer-add     Añade un peer al túnel
  peer-remove  Elimina un peer por su clave pública

Opciones:
  --pubkey <key>        Clave pública del peer (base64)
  --endpoint <IP:port>  Endpoint del peer (ej: 1.2.3.4:51820)
  --allowed-ips <CIDR>  IPs enrutadas por el túnel (ej: 10.0.0.2/32)
  --name <nombre>       Nombre descriptivo del peer (opcional)
  --ip <IP>             IP del router
  --env <env>           Entorno (default: prod)

Ejemplos:
  setup-wireguard.sh status
  setup-wireguard.sh peer-list
  setup-wireguard.sh peer-add \
    --pubkey "abc123...==" \
    --endpoint "1.2.3.4:51820" \
    --allowed-ips "10.0.0.2/32" \
    --name "laptop"
  setup-wireguard.sh peer-remove --pubkey "abc123...=="
  setup-wireguard.sh disable
HELP
}

if [[ $# -eq 0 ]]; then _show_help; exit 1; fi
case "$1" in
    status|enable|disable|peer-list|peer-add|peer-remove) _SUBCMD="$1"; shift ;;
    -h|--help) _show_help; exit 0 ;;
    *) log_error "Subcomando desconocido: $1"; _show_help; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)           _CLI_IP="${2:?}";       shift 2 ;;
        --env)          _ENV="${2:?}";           shift 2 ;;
        --pubkey)       _PUBKEY="${2:?}";        shift 2 ;;
        --endpoint)     _ENDPOINT="${2:?}";      shift 2 ;;
        --allowed-ips)  _ALLOWED_IPS="${2:?}";   shift 2 ;;
        --name)         _PEER_NAME="${2:?}";     shift 2 ;;
        -h|--help) _show_help; exit 0 ;;
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
    local retries=3 delay=4 i=1
    while [ "${i}" -le "${retries}" ]; do
        if ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
            return 0
        fi
        [ "${i}" -lt "${retries}" ] && {
            log_warn "SSH no disponible, reintentando en ${delay}s... (${i}/${retries})"
            sleep "${delay}"
        }
        i=$((i + 1))
    done
    log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
    exit 1
}

# ---------------------------------------------------------------------------
_status() {
    _check_ssh
    echo ""
    _ssh sh - << 'REMOTE'
echo "══════════════════════════════════════════════"
echo "  WireGuard — Estado"
echo "══════════════════════════════════════════════"

# Interfaz
if ip link show wg0 >/dev/null 2>&1; then
    WG_IP=$(ip -4 addr show wg0 | awk '/inet /{print $2}')
    WG_STATE=$(ip link show wg0 | grep -o 'UP\|DOWN' | head -1)
    printf "  Interfaz wg0: %s  IP: %s\n" "${WG_STATE}" "${WG_IP:-sin IP}"
else
    echo "  Interfaz wg0: no existe (WireGuard inactivo)"
fi

echo ""

# Estadísticas en vivo (si wg está disponible)
if command -v wg >/dev/null 2>&1; then
    echo "──────────────────────────────────────────────"
    echo "  Peers activos:"
    echo "──────────────────────────────────────────────"
    wg show wg0 2>/dev/null || echo "  (no hay peers o wg0 no está activo)"
else
    echo "  (comando 'wg' no disponible)"
fi

echo ""
echo "──────────────────────────────────────────────"
echo "  Configuración UCI:"
echo "──────────────────────────────────────────────"
uci show network | grep -E "wireguard|wg0" 2>/dev/null || echo "  (sin configuración WireGuard en UCI)"
REMOTE
}

# ---------------------------------------------------------------------------
_enable() {
    _check_ssh
    log_step "Activando WireGuard (wg0)..."
    _ssh sh - << 'REMOTE'
uci set network.wg0.disabled='0'
uci commit network
ifup wg0 2>/dev/null || ip link set wg0 up 2>/dev/null || true
echo "✅ WireGuard activado"
REMOTE
}

# ---------------------------------------------------------------------------
_disable() {
    _check_ssh
    log_step "Desactivando WireGuard (wg0)..."
    _ssh sh - << 'REMOTE'
uci set network.wg0.disabled='1'
uci commit network
ifdown wg0 2>/dev/null || ip link set wg0 down 2>/dev/null || true
echo "✅ WireGuard desactivado"
REMOTE
}

# ---------------------------------------------------------------------------
_peer_list() {
    _check_ssh
    echo ""
    echo "Peers WireGuard configurados en UCI:"
    echo "──────────────────────────────────────────────"
    _ssh sh - << 'REMOTE'
found=0
for peer in $(uci show network | grep "=wireguard_wg0" | cut -d= -f1); do
    found=1
    name=$(uci -q get "${peer}.description" 2>/dev/null || echo "(sin nombre)")
    pubkey=$(uci -q get "${peer}.public_key" 2>/dev/null || echo "?")
    endpoint=$(uci -q get "${peer}.endpoint_host" 2>/dev/null || echo "")
    port=$(uci -q get "${peer}.endpoint_port" 2>/dev/null || echo "")
    allowed=$(uci -q get "${peer}.allowed_ips" 2>/dev/null || echo "?")
    printf "  Nombre:       %s\n" "${name}"
    printf "  Public key:   %s\n" "${pubkey}"
    [ -n "${endpoint}" ] && printf "  Endpoint:     %s:%s\n" "${endpoint}" "${port}"
    printf "  Allowed IPs:  %s\n" "${allowed}"
    echo "  ────────────────────────────────────────────"
done
[ "${found}" = "0" ] && echo "  (sin peers configurados)"
REMOTE
}

# ---------------------------------------------------------------------------
_peer_add() {
    [ -z "${_PUBKEY}" ]       && { log_error "Falta --pubkey"; exit 1; }
    [ -z "${_ALLOWED_IPS}" ]  && { log_error "Falta --allowed-ips"; exit 1; }

    _check_ssh

    local pubkey="${_PUBKEY}"
    local endpoint_host="" endpoint_port=""
    if [ -n "${_ENDPOINT}" ]; then
        endpoint_host="${_ENDPOINT%:*}"
        endpoint_port="${_ENDPOINT##*:}"
    fi
    local allowed_ips="${_ALLOWED_IPS}"
    local peer_name="${_PEER_NAME:-peer-$(echo "${pubkey}" | head -c 8)}"

    log_step "Añadiendo peer '${peer_name}'..."

    _ssh sh - << EOF
uci add network wireguard_wg0
uci set network.@wireguard_wg0[-1].public_key='${pubkey}'
uci set network.@wireguard_wg0[-1].description='${peer_name}'
uci set network.@wireguard_wg0[-1].allowed_ips='${allowed_ips}'
uci set network.@wireguard_wg0[-1].persistent_keepalive='25'
$([ -n "${endpoint_host}" ] && echo "uci set network.@wireguard_wg0[-1].endpoint_host='${endpoint_host}'")
$([ -n "${endpoint_port}" ] && echo "uci set network.@wireguard_wg0[-1].endpoint_port='${endpoint_port}'")
uci set network.@wireguard_wg0[-1].route_allowed_ips='1'
uci commit network
echo "✅ Peer '${peer_name}' añadido"
echo "   Reinicia WireGuard: ifdown wg0 && ifup wg0"
EOF
}

# ---------------------------------------------------------------------------
_peer_remove() {
    [ -z "${_PUBKEY}" ] && { log_error "Falta --pubkey"; exit 1; }

    _check_ssh

    local pubkey="${_PUBKEY}"
    log_step "Eliminando peer con pubkey: ${pubkey:0:16}..."

    _ssh sh - << EOF
found=0
for idx in \$(uci show network | grep "=wireguard_wg0" | grep -n "" | tac | cut -d: -f1); do
    peer_section=\$(uci show network | grep "=wireguard_wg0" | sed -n "\${idx}p" | cut -d= -f1)
    pk=\$(uci -q get "\${peer_section}.public_key" 2>/dev/null || true)
    if [ "\${pk}" = '${pubkey}' ]; then
        uci delete "\${peer_section}"
        found=1
        echo "✅ Peer eliminado"
        break
    fi
done
[ "\${found}" = "0" ] && echo "❌ No se encontró ningún peer con esa clave pública"
uci commit network
EOF
}

# ---------------------------------------------------------------------------
case "${_SUBCMD}" in
    status)       _status ;;
    enable)       _enable ;;
    disable)      _disable ;;
    peer-list)    _peer_list ;;
    peer-add)     _peer_add ;;
    peer-remove)  _peer_remove ;;
esac
