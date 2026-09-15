#!/bin/sh
# ============================================================================
# mock-dispatch.sh — Simula la latencia y la gramática de
# router-agent/shared/router-dispatch/agent-dispatch.sh, pero contra un
# estado en archivo local en vez de nftables real.
#
# Existe SOLO para el harness de benchmark (router-agent/bench/run.sh), para
# poder correr concurrencia alta sin martillar el router físico. No es un
# sustituto de pruebas de integración contra el router real.
# ============================================================================
set -eu

LATENCY_MS="${MOCK_LATENCY_MS:-150}"
STATE_FILE="/tmp/mock-allowed-clients"
touch "${STATE_FILE}"

# Simula el round-trip nft real (medido una vez a mano contra el router).
_sleep_ms() {
    ms="$1"
    awk -v ms="${ms}" 'BEGIN { printf "%.3f", ms/1000 }' | xargs sleep
}
_sleep_ms "${LATENCY_MS}"

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
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    return 0
}

# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-}
CMD="${1:-}"
ARG1="${2:-}"
ARG2="${3:-}"

case "${CMD}" in
    allow)
        [ -n "${ARG1}" ] || { echo "ERR missing ip" >&2; exit 2; }
        _validate_ip "${ARG1}" || { echo "ERR invalid ip" >&2; exit 2; }
        TIMEOUT_MIN="${ARG2:-30}"
        _validate_timeout "${TIMEOUT_MIN}" || { echo "ERR invalid timeout" >&2; exit 2; }
        grep -v "^${ARG1} " "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null || true
        echo "${ARG1} ${TIMEOUT_MIN}" >> "${STATE_FILE}.tmp"
        mv "${STATE_FILE}.tmp" "${STATE_FILE}"
        if [ "${TIMEOUT_MIN}" -eq 0 ]; then
            echo "OK allow ${ARG1} 0"
        else
            echo "OK allow ${ARG1} ${TIMEOUT_MIN}m"
        fi
        ;;
    block)
        [ -n "${ARG1}" ] || { echo "ERR missing ip" >&2; exit 2; }
        _validate_ip "${ARG1}" || { echo "ERR invalid ip" >&2; exit 2; }
        if ! grep -q "^${ARG1} " "${STATE_FILE}" 2>/dev/null; then
            echo "OK block ${ARG1} (not present)"
            exit 0
        fi
        grep -v "^${ARG1} " "${STATE_FILE}" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "${STATE_FILE}"
        echo "OK block ${ARG1}"
        ;;
    list)
        # JSON con la misma forma que "nft -j list set" para timeout sets.
        printf '{"nftables":[{"set":{"family":"ip","name":"allowed_clients","table":"captive","elem":['
        first=1
        while read -r ip timeout_min; do
            [ -z "${ip}" ] && continue
            [ "${first}" -eq 1 ] || printf ','
            first=0
            if [ "${timeout_min}" = "0" ]; then
                printf '"%s"' "${ip}"
            else
                printf '{"elem":{"val":"%s","expires":%s}}' "${ip}" "$((timeout_min * 60))"
            fi
        done < "${STATE_FILE}"
        printf ']}}]}\n'
        ;;
    status)
        echo "OK table=ip captive present"
        ;;
    *)
        echo "ERR unknown command" >&2
        exit 2
        ;;
esac
