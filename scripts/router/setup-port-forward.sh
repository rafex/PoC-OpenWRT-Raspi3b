#!/usr/bin/env bash
# ============================================================================
# setup-port-forward.sh — Gestión de port forwarding en OpenWRT
#
# Subcomandos:
#   list    Lista todas las reglas de port forwarding activas
#   add     Añade una nueva regla DNAT
#   remove  Elimina una regla por nombre
#   status  Muestra reglas activas con estadísticas nftables
#
# Uso:
#   setup-port-forward.sh list
#   setup-port-forward.sh add --name <nombre> --port <ext> --dest-ip <IP> \
#                             [--dest-port <int>] [--proto tcp|udp|both]
#   setup-port-forward.sh remove --name <nombre>
#   setup-port-forward.sh status
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

_SUBCMD=""
_ENV="prod"
_CLI_IP=""
_NAME=""
_PORT=""
_DEST_IP=""
_DEST_PORT=""
_PROTO="tcp"

_show_help() {
    cat << 'HELP'
Uso: setup-port-forward.sh <subcomando> [opciones]

Subcomandos:
  list     Lista todas las reglas de port forwarding
  add      Añade una regla de port forwarding (DNAT desde WAN)
  remove   Elimina una regla por nombre
  status   Muestra reglas con contadores nftables en vivo

Opciones:
  --name <nombre>      Nombre de la regla (requerido en add/remove)
  --port <puerto>      Puerto externo WAN (ej: 8080)
  --dest-ip <IP>       IP destino en la LAN (ej: 192.168.1.50)
  --dest-port <puerto> Puerto destino (default: igual que --port)
  --proto <proto>      tcp | udp | both  (default: tcp)
  --ip <IP>            IP del router
  --env <env>          Entorno (default: prod)

Ejemplos:
  setup-port-forward.sh list
  setup-port-forward.sh add --name "servidor-web" --port 8080 --dest-ip 192.168.1.50
  setup-port-forward.sh add --name "nas-smb" --port 445 --dest-ip 192.168.1.30 --proto both
  setup-port-forward.sh add --name "ssh-raspi" --port 2222 --dest-ip 192.168.1.136 --dest-port 22
  setup-port-forward.sh remove --name "servidor-web"
  setup-port-forward.sh status
HELP
}

if [[ $# -eq 0 ]]; then _show_help; exit 1; fi
case "$1" in
    list|add|remove|status) _SUBCMD="$1"; shift ;;
    -h|--help) _show_help; exit 0 ;;
    *) log_error "Subcomando desconocido: $1"; _show_help; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         _CLI_IP="${2:?}";    shift 2 ;;
        --env)        _ENV="${2:?}";       shift 2 ;;
        --name)       _NAME="${2:?}";      shift 2 ;;
        --port)       _PORT="${2:?}";      shift 2 ;;
        --dest-ip)    _DEST_IP="${2:?}";   shift 2 ;;
        --dest-port)  _DEST_PORT="${2:?}"; shift 2 ;;
        --proto)      _PROTO="${2:?}";     shift 2 ;;
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
_list() {
    _check_ssh
    echo ""
    echo "Port forwarding configurado en UCI:"
    echo "════════════════════════════════════════════════"
    _ssh sh - << 'REMOTE'
found=0
for section in $(uci show firewall | grep "=redirect" | cut -d= -f1); do
    name=$(uci -q get "${section}.name" 2>/dev/null || echo "(sin nombre)")
    target=$(uci -q get "${section}.target" 2>/dev/null || echo "?")
    [ "${target}" != "DNAT" ] && continue
    found=1
    src_dport=$(uci -q get "${section}.src_dport" 2>/dev/null || echo "?")
    dest_ip=$(uci -q get "${section}.dest_ip" 2>/dev/null || echo "?")
    dest_port=$(uci -q get "${section}.dest_port" 2>/dev/null || echo "${src_dport}")
    proto=$(uci -q get "${section}.proto" 2>/dev/null || echo "tcp")
    enabled=$(uci -q get "${section}.enabled" 2>/dev/null || echo "1")
    state=$( [ "${enabled}" = "0" ] && echo "DESACTIVADA" || echo "activa" )
    printf "  %-20s  WAN:%-6s → %s:%-6s  [%s]  %s\n" \
        "${name}" "${src_dport}" "${dest_ip}" "${dest_port}" "${proto}" "${state}"
done
[ "${found}" = "0" ] && echo "  (sin reglas de port forwarding)"
REMOTE
    echo ""
}

# ---------------------------------------------------------------------------
_add() {
    [ -z "${_NAME}" ]    && { log_error "Falta --name";    exit 1; }
    [ -z "${_PORT}" ]    && { log_error "Falta --port";    exit 1; }
    [ -z "${_DEST_IP}" ] && { log_error "Falta --dest-ip"; exit 1; }

    local dest_port="${_DEST_PORT:-${_PORT}}"
    local name="${_NAME}"
    local src_port="${_PORT}"
    local dest_ip="${_DEST_IP}"
    local proto="${_PROTO}"

    _check_ssh

    log_step "Añadiendo regla '${name}': WAN:${src_port} → ${dest_ip}:${dest_port} [${proto}]"

    _ssh sh - << EOF
# Verificar que no exista ya una regla con ese nombre
existing=\$(uci show firewall | grep "\.name='${name}'" | cut -d= -f1 | head -1)
if [ -n "\${existing}" ]; then
    echo "❌ Ya existe una regla con el nombre '${name}'"
    echo "   Elimínala primero con: just router-port-forward-remove --name ${name}"
    exit 1
fi

# Añadir la regla
if [ "${proto}" = "both" ]; then
    # Dos reglas: una TCP, una UDP
    for p in tcp udp; do
        uci add firewall redirect
        uci set firewall.@redirect[-1].name='${name}-\${p}'
        uci set firewall.@redirect[-1].target='DNAT'
        uci set firewall.@redirect[-1].src='wan'
        uci set firewall.@redirect[-1].proto="\${p}"
        uci set firewall.@redirect[-1].src_dport='${src_port}'
        uci set firewall.@redirect[-1].dest_ip='${dest_ip}'
        uci set firewall.@redirect[-1].dest_port='${dest_port}'
        uci set firewall.@redirect[-1].enabled='1'
    done
else
    uci add firewall redirect
    uci set firewall.@redirect[-1].name='${name}'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].src='wan'
    uci set firewall.@redirect[-1].proto='${proto}'
    uci set firewall.@redirect[-1].src_dport='${src_port}'
    uci set firewall.@redirect[-1].dest_ip='${dest_ip}'
    uci set firewall.@redirect[-1].dest_port='${dest_port}'
    uci set firewall.@redirect[-1].enabled='1'
fi

uci commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1 || true
echo "✅ Regla añadida: WAN:${src_port} → ${dest_ip}:${dest_port} [${proto}]"
EOF
}

# ---------------------------------------------------------------------------
_remove() {
    [ -z "${_NAME}" ] && { log_error "Falta --name"; exit 1; }

    local name="${_NAME}"
    _check_ssh
    log_step "Eliminando regla(s) '${name}'..."

    _ssh sh - << EOF
found=0
# Iterar en orden inverso para no romper índices al borrar
sections=\$(uci show firewall | grep "=redirect" | cut -d= -f1)
for section in \$(echo "\${sections}" | tac); do
    rule_name=\$(uci -q get "\${section}.name" 2>/dev/null || true)
    if [ "\${rule_name}" = "${name}" ] || \
       [ "\${rule_name}" = "${name}-tcp" ] || \
       [ "\${rule_name}" = "${name}-udp" ]; then
        uci delete "\${section}"
        found=\$((found + 1))
        echo "  Eliminada: \${rule_name}"
    fi
done
if [ "\${found}" -gt 0 ]; then
    uci commit firewall
    /etc/init.d/firewall reload >/dev/null 2>&1 || true
    echo "✅ \${found} regla(s) eliminada(s)"
else
    echo "❌ No se encontró ninguna regla con el nombre '${name}'"
fi
EOF
}

# ---------------------------------------------------------------------------
_status() {
    _check_ssh
    echo ""
    echo "Port forwarding — estado en vivo (nftables):"
    echo "════════════════════════════════════════════════"
    _ssh sh - << 'REMOTE'
# Listar reglas DNAT en la chain de prerouting
nft list table inet fw4 2>/dev/null | grep -A2 "dnat\|redirect" | grep -v "^--$" || \
    echo "  (sin reglas DNAT activas en nftables)"
echo ""
echo "Configuración UCI completa:"
echo "──────────────────────────────────────────────"
uci show firewall | grep -E "redirect|DNAT" | head -40 || echo "  (sin redirects UCI)"
REMOTE
    echo ""
}

# ---------------------------------------------------------------------------
case "${_SUBCMD}" in
    list)   _list ;;
    add)    _add ;;
    remove) _remove ;;
    status) _status ;;
esac
