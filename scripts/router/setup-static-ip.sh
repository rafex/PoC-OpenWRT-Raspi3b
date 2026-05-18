#!/usr/bin/env bash
# ============================================================================
# setup-static-ip.sh — IPs estáticas por MAC address en OpenWRT
#
# Asigna IPs fijas (DHCP static leases) a dispositivos por su MAC address.
# Usa UCI dhcp host entries → dnsmasq sirve la IP siempre al mismo dispositivo.
#
# Subcomandos:
#   add     Asigna IP estática a un MAC address
#   remove  Elimina asignación (por --mac o --assign)
#   list    Muestra todas las asignaciones configuradas
#   clear   Elimina todas las asignaciones
#   import  Importa asignaciones desde un CSV local
#
# Uso:
#   setup-static-ip.sh add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 [--name <nombre>]
#   setup-static-ip.sh remove --mac AA:BB:CC:DD:EE:FF
#   setup-static-ip.sh remove --assign 192.168.1.100
#   setup-static-ip.sh list   [--ip <router>] [--env <env>]
#   setup-static-ip.sh clear  [--ip <router>] [--env <env>]
#   setup-static-ip.sh import --file <csv> [--ip <router>] [--env <env>]
#
# Formato CSV (import):
#   MAC,IP,nombre
#   AA:BB:CC:DD:EE:FF,192.168.1.100,servidor
#   BB:CC:DD:EE:FF:00,192.168.1.101,laptop
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
_MAC=""
_ASSIGN=""
_NAME=""
_FILE=""

_show_help() {
    cat <<HELP
Uso: $(basename "$0") <subcomando> [opciones]

Subcomandos:
  add     Asigna IP estática a un MAC address
  remove  Elimina asignación (por --mac o --assign)
  list    Muestra todas las asignaciones
  clear   Elimina todas las asignaciones
  import  Importa desde CSV local

Opciones:
  --mac <MAC>      MAC address del dispositivo (AA:BB:CC:DD:EE:FF)
  --assign <IP>    IP estática a asignar (para add/remove)
  --name <nombre>  Hostname del dispositivo (opcional en add)
  --file <csv>     Archivo CSV para import
  --ip <IP>        IP del router (default: env o 192.168.1.1)
  --env <env>      Entorno (default: prod)

Ejemplos:
  $(basename "$0") add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 --name servidor
  $(basename "$0") add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100
  $(basename "$0") remove --mac AA:BB:CC:DD:EE:FF
  $(basename "$0") remove --assign 192.168.1.100
  $(basename "$0") list
  $(basename "$0") clear
  $(basename "$0") import --file hosts.csv

Formato CSV (import):
  MAC,IP,nombre
  AA:BB:CC:DD:EE:FF,192.168.1.100,servidor
  BB:CC:DD:EE:FF:00,192.168.1.101,laptop
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
        --ip)     _CLI_IP="${2:?--ip requiere argumento}"; shift 2 ;;
        --env)    _ENV="${2:?--env requiere argumento}"; shift 2 ;;
        --mac)    _MAC="${2:?--mac requiere argumento}"; shift 2 ;;
        --assign) _ASSIGN="${2:?--assign requiere argumento}"; shift 2 ;;
        --name)   _NAME="${2:?--name requiere argumento}"; shift 2 ;;
        --file)   _FILE="${2:?--file requiere argumento}"; shift 2 ;;
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
# Validaciones
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

_validate_mac() {
    local mac="$1"
    # Acepta AA:BB:CC:DD:EE:FF (mayúsculas o minúsculas)
    case "${mac}" in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f])
            return 0 ;;
        *) return 1 ;;
    esac
}

# Normaliza MAC a minúsculas (como espera OpenWRT)
_normalize_mac() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# ---------------------------------------------------------------------------
# _dnsmasq_restart — recarga dnsmasq en el router
# ---------------------------------------------------------------------------
_dnsmasq_restart() {
    _ssh "/etc/init.d/dnsmasq restart" 2>/dev/null \
        && log_info "dnsmasq reiniciado" \
        || log_warn "No se pudo reiniciar dnsmasq (continúa igual hasta próximo reinicio)"
}

# ---------------------------------------------------------------------------
# Subcomandos
# ---------------------------------------------------------------------------

_add() {
    [ -n "${_MAC}" ]    || { log_error "Especifica --mac <MAC>"; exit 1; }
    [ -n "${_ASSIGN}" ] || { log_error "Especifica --assign <IP>"; exit 1; }
    _validate_mac "${_MAC}" \
        || { log_error "MAC inválida: ${_MAC} (formato esperado: AA:BB:CC:DD:EE:FF)"; exit 1; }
    _validate_ip "${_ASSIGN}" \
        || { log_error "IP inválida: ${_ASSIGN}"; exit 1; }

    local mac
    mac=$(_normalize_mac "${_MAC}")
    local name="${_NAME:-}"

    echo "============================================="
    echo " Asignar IP estática"
    echo "============================================="
    echo "   MAC:    ${mac}"
    echo "   IP:     ${_ASSIGN}"
    [ -n "${name}" ] && echo "   Nombre: ${name}"
    echo ""

    _ssh sh - << REMOTE
set -eu
MAC="${mac}"
ASSIGN="${_ASSIGN}"
NAME="${name}"

# Verificar si ya existe una entrada para este MAC
idx=0
found_idx=""
while uci -q get "dhcp.@host[\${idx}]" >/dev/null 2>&1; do
    existing_mac=\$(uci -q get "dhcp.@host[\${idx}].mac" 2>/dev/null || echo "")
    if [ "\${existing_mac}" = "\${MAC}" ]; then
        found_idx="\${idx}"
        break
    fi
    idx=\$((idx + 1))
done

if [ -n "\${found_idx}" ]; then
    # Actualizar entrada existente
    echo "  Actualizando entrada existente (índice \${found_idx})..."
    uci set "dhcp.@host[\${found_idx}].mac=\${MAC}"
    uci set "dhcp.@host[\${found_idx}].ip=\${ASSIGN}"
    [ -n "\${NAME}" ] && uci set "dhcp.@host[\${found_idx}].name=\${NAME}" || true
else
    # Crear nueva entrada
    uci add dhcp host >/dev/null
    uci set "dhcp.@host[-1].mac=\${MAC}"
    uci set "dhcp.@host[-1].ip=\${ASSIGN}"
    [ -n "\${NAME}" ] && uci set "dhcp.@host[-1].name=\${NAME}" || true
fi

uci commit dhcp
echo "✅ Asignado: \${MAC} → \${ASSIGN}"
REMOTE

    _dnsmasq_restart
}

_remove() {
    if [ -z "${_MAC}" ] && [ -z "${_ASSIGN}" ]; then
        log_error "Especifica --mac <MAC> o --assign <IP>"
        exit 1
    fi

    local mac=""
    [ -n "${_MAC}" ] && mac=$(_normalize_mac "${_MAC}")

    echo "============================================="
    echo " Eliminar asignación estática"
    echo "============================================="
    [ -n "${mac}" ]     && echo "   MAC: ${mac}"
    [ -n "${_ASSIGN}" ] && echo "   IP:  ${_ASSIGN}"
    echo ""

    _ssh sh - << REMOTE
set -eu
TARGET_MAC="${mac}"
TARGET_IP="${_ASSIGN}"

# Buscar la entrada a eliminar
idx=0
found_idx=""
while uci -q get "dhcp.@host[\${idx}]" >/dev/null 2>&1; do
    e_mac=\$(uci -q get "dhcp.@host[\${idx}].mac" 2>/dev/null || echo "")
    e_ip=\$(uci  -q get "dhcp.@host[\${idx}].ip"  2>/dev/null || echo "")
    if [ -n "\${TARGET_MAC}" ] && [ "\${e_mac}" = "\${TARGET_MAC}" ]; then
        found_idx="\${idx}"; break
    fi
    if [ -n "\${TARGET_IP}" ]  && [ "\${e_ip}"  = "\${TARGET_IP}" ]; then
        found_idx="\${idx}"; break
    fi
    idx=\$((idx + 1))
done

if [ -n "\${found_idx}" ]; then
    e_mac=\$(uci -q get "dhcp.@host[\${found_idx}].mac" 2>/dev/null || echo "?")
    e_ip=\$(uci  -q get "dhcp.@host[\${found_idx}].ip"  2>/dev/null || echo "?")
    uci delete "dhcp.@host[\${found_idx}]"
    uci commit dhcp
    echo "✅ Eliminado: \${e_mac} → \${e_ip}"
else
    echo "AVISO: no se encontró ninguna asignación con esos datos."
fi
REMOTE

    _dnsmasq_restart
}

_list() {
    echo "============================================="
    echo " IPs Estáticas — ${ROUTER_IP}"
    echo "============================================="
    _ssh sh << 'REMOTE'
echo ""
idx=0
count=0
printf "  %-20s %-16s %s\n" "MAC" "IP" "Nombre"
echo "  ─────────────────────────────────────────────"
while uci -q get "dhcp.@host[${idx}]" >/dev/null 2>&1; do
    mac=$(uci  -q get "dhcp.@host[${idx}].mac"  2>/dev/null || echo "")
    ip=$(uci   -q get "dhcp.@host[${idx}].ip"   2>/dev/null || echo "")
    name=$(uci -q get "dhcp.@host[${idx}].name" 2>/dev/null || echo "")
    [ -n "${mac}" ] || { idx=$((idx + 1)); continue; }
    printf "  %-20s %-16s %s\n" "${mac}" "${ip}" "${name}"
    count=$((count + 1))
    idx=$((idx + 1))
done
echo ""
echo "  Total: ${count} asignación(es)"

echo ""
echo "=== Leases DHCP activos ==="
if [ -f /tmp/dhcp.leases ]; then
    printf "  %-12s %-20s %-16s %s\n" "Expiración" "MAC" "IP" "Hostname"
    echo "  ─────────────────────────────────────────────"
    while read -r exp mac ip host _rest; do
        printf "  %-12s %-20s %-16s %s\n" "${exp}" "${mac}" "${ip}" "${host}"
    done < /tmp/dhcp.leases
else
    echo "  (sin leases activos)"
fi
REMOTE
}

_clear() {
    echo "============================================="
    echo " Eliminar TODAS las asignaciones estáticas"
    echo "============================================="
    echo ""
    read -r -p "¿Eliminar todas las asignaciones de IP estática? (s/N) " answer
    answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
    if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi

    _ssh sh << 'REMOTE'
set -eu
deleted=0
while uci -q get "dhcp.@host[0]" >/dev/null 2>&1; do
    mac=$(uci -q get "dhcp.@host[0].mac" 2>/dev/null || echo "?")
    ip=$(uci  -q get "dhcp.@host[0].ip"  2>/dev/null || echo "?")
    uci delete "dhcp.@host[0]"
    echo "  Eliminado: ${mac} → ${ip}"
    deleted=$((deleted + 1))
done
uci commit dhcp
echo ""
echo "✅ Total eliminadas: ${deleted}"
REMOTE

    _dnsmasq_restart
}

_import() {
    [ -n "${_FILE}" ] || { log_error "Especifica --file <csv>"; exit 1; }
    [ -f "${_FILE}" ] || { log_error "Archivo no encontrado: ${_FILE}"; exit 1; }

    echo "============================================="
    echo " Importar desde CSV: ${_FILE}"
    echo "============================================="
    echo ""

    local count=0
    local errors=0
    local line_num=0

    while IFS=',' read -r raw_mac raw_ip raw_name; do
        line_num=$((line_num + 1))
        # Ignorar líneas vacías y cabecera (MAC,IP,*)
        [ -z "${raw_mac}" ] && continue
        case "${raw_mac}" in '#'*|'MAC'|'mac') continue ;; esac

        # Limpiar espacios
        local csv_mac csv_ip csv_name
        csv_mac=$(echo "${raw_mac}" | tr -d ' \r')
        csv_ip=$(echo "${raw_ip}" | tr -d ' \r')
        csv_name=$(echo "${raw_name:-}" | tr -d ' \r')

        if ! _validate_mac "${csv_mac}"; then
            log_warn "Línea ${line_num}: MAC inválida '${csv_mac}' — omitida"
            errors=$((errors + 1))
            continue
        fi
        if ! _validate_ip "${csv_ip}"; then
            log_warn "Línea ${line_num}: IP inválida '${csv_ip}' — omitida"
            errors=$((errors + 1))
            continue
        fi

        csv_mac=$(_normalize_mac "${csv_mac}")
        echo "  ${csv_mac} → ${csv_ip}${csv_name:+ (${csv_name})}"

        local normalized_mac="${csv_mac}"
        local normalized_ip="${csv_ip}"
        local normalized_name="${csv_name}"

        _ssh sh - << REMOTE
set -eu
MAC="${normalized_mac}"
ASSIGN="${normalized_ip}"
NAME="${normalized_name}"

idx=0; found_idx=""
while uci -q get "dhcp.@host[\${idx}]" >/dev/null 2>&1; do
    if [ "\$(uci -q get "dhcp.@host[\${idx}].mac" 2>/dev/null)" = "\${MAC}" ]; then
        found_idx="\${idx}"; break
    fi
    idx=\$((idx + 1))
done

if [ -n "\${found_idx}" ]; then
    uci set "dhcp.@host[\${found_idx}].ip=\${ASSIGN}"
    [ -n "\${NAME}" ] && uci set "dhcp.@host[\${found_idx}].name=\${NAME}" || true
else
    uci add dhcp host >/dev/null
    uci set "dhcp.@host[-1].mac=\${MAC}"
    uci set "dhcp.@host[-1].ip=\${ASSIGN}"
    [ -n "\${NAME}" ] && uci set "dhcp.@host[-1].name=\${NAME}" || true
fi
uci commit dhcp
REMOTE

        count=$((count + 1))

    done < "${_FILE}"

    echo ""
    echo "✅ Importadas: ${count}  |  Errores: ${errors}"

    if [ "${count}" -gt 0 ]; then
        _dnsmasq_restart
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${_SUBCMD}" in
    add)    _check_ssh; _add ;;
    remove) _check_ssh; _remove ;;
    list)   _check_ssh; _list ;;
    clear)  _check_ssh; _clear ;;
    import) _check_ssh; _import ;;
    -h|--help) _show_help ;;
    *) log_error "Subcomando desconocido: ${_SUBCMD}"; _show_help; exit 1 ;;
esac
