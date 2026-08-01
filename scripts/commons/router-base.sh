#!/usr/bin/env bash
# ============================================================================
# router-base.sh — Shared library for router SSH scripts
#
# Uso en cada script de router/:
#   source "${SCRIPT_DIR}/../commons/router-base.sh"
#
# Después de sourcear, las funciones disponibles son:
#   router_init              — configura SCRIPT_DIR, REPO_ROOT, sourcea logging
#   router_load_env <env>    — carga .env.public, establece ROUTER_IP/SSH_PORT
#   router_parse_args "$@"   — parsea --ip, --env, -h/--help
#   router_ssh [args...]     — SSH con known_hosts persistente
#   router_check_ssh         — verifica conectividad SSH con reintentos
#   router_known_hosts_file  — devuelve la ruta al archivo known_hosts
#
# Diseño de seguridad:
#   - StrictHostKeyChecking=accept-new con UserKnownHostsFile persistente
#   - La primera conexión acepta la key automáticamente y la guarda
#   - Conexiones subsecuentes verifican contra la key guardada
#   - Usa: just router-add-known-host <env> para verificar manualmente
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/logging.sh"

export ROUTER_IP=""
export SSH_PORT="22"
export ROUTER_ENV="prod"
export KNOWN_HOSTS_FILE=""

# ---------------------------------------------------------------------------
# router_known_hosts_file — ruta al archivo known_hosts por entorno
# ---------------------------------------------------------------------------
router_known_hosts_file() {
    local env="${1:-${ROUTER_ENV}}"
    echo "${REPO_ROOT}/environments/${env}/.router-known-hosts"
}

# ---------------------------------------------------------------------------
# router_load_env — carga variables de entorno y prepara conexión
# ---------------------------------------------------------------------------
router_load_env() {
    local env="${1:-prod}"
    ROUTER_ENV="${env}"
    KNOWN_HOSTS_FILE=$(router_known_hosts_file "${env}")

    local env_file="${REPO_ROOT}/environments/${env}/.env.public"
    if [ -f "${env_file}" ]; then
        set -a
        # shellcheck disable=SC1090
        source "${env_file}"
        set +a
    fi

    ROUTER_IP="${ROUTER_IP:-192.168.1.1}"
    SSH_PORT="${SSH_PORT:-22}"

    if [ ! -f "${KNOWN_HOSTS_FILE}" ]; then
        log_warn "Sin known_hosts para ${env}. La primera conexión aceptará la key automáticamente."
        echo "   Verifica manualmente con: just router-add-known-host ${env}"
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# router_parse_args — parsea --ip, --env, -h/--help de $@
# Debe llamarse DESPUÉS de haberle quitado el subcomando a $@.
# Establece las variables ROUTER_IP_CLI, ROUTER_ENV.
# ---------------------------------------------------------------------------
_ROUTER_IP_CLI=""

router_parse_args() {
    local show_help_fn="${1:-}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)  _ROUTER_IP_CLI="${2:?--ip requiere argumento}"; shift 2 ;;
            --env) ROUTER_ENV="${2:?--env requiere argumento}";  shift 2 ;;
            -h|--help)
                if [ -n "${show_help_fn}" ] && command -v "${show_help_fn}" &>/dev/null; then
                    "${show_help_fn}"
                fi
                exit 0
                ;;
            *) shift ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# _router_resolve_ip — resuelve IP final combinando CLI + entorno + default
# ---------------------------------------------------------------------------
_router_resolve_ip() {
    ROUTER_IP="${_ROUTER_IP_CLI:-${ROUTER_IP:-192.168.1.1}}"
}

# ---------------------------------------------------------------------------
# _router_ssh_opts — opciones SSH comunes
# ---------------------------------------------------------------------------
_router_ssh_opts() {
    echo -n "-p ${SSH_PORT} -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
    echo -n " -o UserKnownHostsFile=${KNOWN_HOSTS_FILE}"
    echo -n " -o CheckHostIP=no"
}

# ---------------------------------------------------------------------------
# router_ssh — SSH wrapper con known_hosts persistente
# ---------------------------------------------------------------------------
router_ssh() {
    _router_resolve_ip

    local before_md5 after_md5
    before_md5=""
    if [ -f "${KNOWN_HOSTS_FILE}" ]; then
        before_md5=$(md5sum "${KNOWN_HOSTS_FILE}" 2>/dev/null || md5 -q "${KNOWN_HOSTS_FILE}" 2>/dev/null || echo "")
    fi

    # shellcheck disable=SC2086
    ssh $(_router_ssh_opts) "root@${ROUTER_IP}" "$@"
    local ssh_rc=$?

    if [ -f "${KNOWN_HOSTS_FILE}" ]; then
        after_md5=$(md5sum "${KNOWN_HOSTS_FILE}" 2>/dev/null || md5 -q "${KNOWN_HOSTS_FILE}" 2>/dev/null || echo "")
        if [ -n "${before_md5}" ] && [ "${before_md5}" != "${after_md5}" ]; then
            log_warn "NUEVA host key añadida para ${ROUTER_IP} en ${known_hosts}"
            echo "   Verifica el fingerprint manualmente:"
            echo "     just router-add-known-host ${ROUTER_ENV}"
        fi
    fi

    return ${ssh_rc}
}

# ---------------------------------------------------------------------------
# router_check_ssh — verifica conectividad SSH con reintentos
# ---------------------------------------------------------------------------
router_check_ssh() {
    _router_resolve_ip

    local retries=3 delay=4 i=1
    while [ "${i}" -le "${retries}" ]; do
        # shellcheck disable=SC2086
        if ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new \
                -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" \
                "root@${ROUTER_IP}" exit 2>/dev/null; then
            return 0
        fi
        [ "${i}" -lt "${retries}" ] && {
            log_warn "SSH no disponible, reintentando en ${delay}s... (${i}/${retries})"
            sleep "${delay}"
        }
        i=$((i + 1))
    done
    log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
    return 1
}
