#!/bin/sh
# ============================================================================
# agent-dispatch.sh — Forced-command dispatcher para la llave SSH restringida
# del router-agent (captive-agent).
#
# Se instala en el router como /etc/captive/agent-dispatch.sh y se referencia
# desde /etc/dropbear/authorized_keys con la opción `command=`:
#
#   command="/etc/captive/agent-dispatch.sh",no-pty,no-agent-forwarding,\
#   no-X11-forwarding,no-port-forwarding ssh-ed25519 AAAA... captive-agent@env
#
# Dropbear ignora lo que el cliente SSH pida ejecutar y SIEMPRE corre este
# script, pasando el comando original (si lo hubo) en $SSH_ORIGINAL_COMMAND.
# Este script NUNCA hace eval de esa variable — solo la parte con `set --`
# (word-splitting simple, sin expansión de glob ni comandos) y valida cada
# token contra una gramática cerrada antes de tocar nftables.
#
# Gramática soportada (cualquier otra entrada => exit 2):
#   allow <ip> [timeout_min]   (default 30; 0 = permanente)
#   block <ip>
#   list
#   status
#
# Replica exactamente las primitivas nftables de _allow/_block/_list/_status
# en scripts/router/setup-captive.sh (tabla "ip captive", set "allowed_clients").
# No reinventa el diseño del portal cautivo, solo añade una segunda puerta,
# más angosta, para dispararlo por SSH restringido en vez de la llave admin.
# ============================================================================
set -eu

NFT_TABLE="ip captive"
NFT_SET="allowed_clients"

# ---------------------------------------------------------------------------
# _validate_ip — copiado verbatim de _validate_ip() en setup-captive.sh
# para garantizar exactamente la misma validación en ambos lados.
# ---------------------------------------------------------------------------
_validate_ip() {
    ip="$1"
    case "${ip}" in *[!0-9.]*|'') return 1 ;; esac
    IFS='.'
    # shellcheck disable=SC2086
    set -- ${ip}
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        [ "${octet}" -ge 0 ] && [ "${octet}" -le 255 ] || return 1
    done
    return 0
}

_validate_timeout() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Parsear $SSH_ORIGINAL_COMMAND — solo word-splitting, nunca eval.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-}

CMD="${1:-}"
ARG1="${2:-}"
ARG2="${3:-}"

case "${CMD}" in
    allow)
        if [ -z "${ARG1}" ]; then
            echo "ERR missing ip" >&2
            exit 2
        fi
        if ! _validate_ip "${ARG1}"; then
            echo "ERR invalid ip" >&2
            exit 2
        fi
        TIMEOUT_MIN="${ARG2:-30}"
        if ! _validate_timeout "${TIMEOUT_MIN}"; then
            echo "ERR invalid timeout" >&2
            exit 2
        fi
        if [ "${TIMEOUT_MIN}" -eq 0 ]; then
            NFT_TIMEOUT="0"
        else
            NFT_TIMEOUT="${TIMEOUT_MIN}m"
        fi
        # Si ya está en el set, eliminarlo primero para actualizar el timeout
        # (mismo comportamiento que _allow() en setup-captive.sh)
        if nft list set "${NFT_TABLE}" "${NFT_SET}" 2>/dev/null | grep -qw "${ARG1}"; then
            nft delete element "${NFT_TABLE}" "${NFT_SET}" "{ ${ARG1} }" 2>/dev/null || true
        fi
        nft add element "${NFT_TABLE}" "${NFT_SET}" "{ ${ARG1} timeout ${NFT_TIMEOUT} }"
        echo "OK allow ${ARG1} ${NFT_TIMEOUT}"
        ;;
    block)
        if [ -z "${ARG1}" ]; then
            echo "ERR missing ip" >&2
            exit 2
        fi
        if ! _validate_ip "${ARG1}"; then
            echo "ERR invalid ip" >&2
            exit 2
        fi
        if ! nft list set "${NFT_TABLE}" "${NFT_SET}" 2>/dev/null | grep -qw "${ARG1}"; then
            echo "OK block ${ARG1} (not present)"
            exit 0
        fi
        nft delete element "${NFT_TABLE}" "${NFT_SET}" "{ ${ARG1} }"
        echo "OK block ${ARG1}"
        ;;
    list)
        # Salida JSON estable (nft -j) para que el agente HTTP la parsee.
        # El formato humano de _list() en setup-captive.sh es solo para uso interactivo.
        nft -j list set "${NFT_TABLE}" "${NFT_SET}" 2>/dev/null || echo '{"nftables":[]}'
        ;;
    status)
        if nft list table "${NFT_TABLE}" >/dev/null 2>&1; then
            echo "OK table=${NFT_TABLE} present"
        else
            echo "ERR table missing" >&2
            exit 1
        fi
        ;;
    *)
        echo "ERR unknown command" >&2
        exit 2
        ;;
esac
