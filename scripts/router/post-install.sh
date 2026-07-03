#!/usr/bin/env bash
# ============================================================================
# post-install.sh — Instala paquetes adicionales en el router
#
# Lee openwrt-post-install-packages.toml y ejecuta apk/opkg en el router.
# Estos paquetes NO van compilados en la imagen — se instalan post-flash.
#
# Uso:
#   scripts/build/post-install.sh [--group <grupo>] [--ip <IP>] [--env <env>]
#
# Opciones:
#   --group <grupo>  Instala solo un grupo (ej: captive_portal, diagnostico)
#                    Sin --group: instala todos los grupos
#   --ip <IP>        IP del router
#   --env <env>      Entorno (default: prod)
#   --list           Lista los grupos y paquetes disponibles sin instalar
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

readonly TOML_FILE="${REPO_ROOT}/config/openwrt-post-install-packages.toml"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
_ENV="prod"
_CLI_IP=""
_GROUP=""
_LIST_ONLY=false

# ---------------------------------------------------------------------------
# Parsear argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --group)  _GROUP="${2:?--group requiere argumento}"; shift 2 ;;
        --ip)     _CLI_IP="${2:?--ip requiere argumento}"; shift 2 ;;
        --env)    _ENV="${2:?--env requiere argumento}"; shift 2 ;;
        --list)   _LIST_ONLY=true; shift ;;
        -h|--help)
            echo "Uso: $0 [--group <grupo>] [--ip <IP>] [--env <env>] [--list]"
            echo ""
            echo "  --group <grupo>  Instala solo un grupo (ver --list)"
            echo "  --ip <IP>        IP del router"
            echo "  --env            Entorno (default: prod)"
            echo "  --list           Muestra grupos disponibles sin instalar"
            exit 0
            ;;
        *) log_error "Argumento desconocido: $1"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Verificar TOML
# ---------------------------------------------------------------------------
if [ ! -f "${TOML_FILE}" ]; then
    log_error "No se encontró: ${TOML_FILE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Parser minimalista para el TOML de post-install
# Extrae grupos ([nombre]) y sus listas packages = ["pkg1", "pkg2"]
# ---------------------------------------------------------------------------
_parse_groups() {
    python3 - "${TOML_FILE}" << 'PYEOF'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

current = None
groups = {}
descs = {}

for line in content.splitlines():
    line = line.strip()
    if line.startswith('#') or not line:
        continue
    m = re.match(r'^\[(\w+)\]$', line)
    if m:
        current = m.group(1)
        groups[current] = []
        continue
    if current:
        dm = re.match(r'^description\s*=\s*"(.+)"$', line)
        if dm:
            descs[current] = dm.group(1)
        pm = re.match(r'^packages\s*=\s*\[(.+)\]$', line)
        if pm:
            pkgs = re.findall(r'"([^"]+)"', pm.group(1))
            groups[current] = pkgs

for g, pkgs in groups.items():
    desc = descs.get(g, '')
    print(f"{g}|{desc}|{' '.join(pkgs)}")
PYEOF
}

# ---------------------------------------------------------------------------
# Listar grupos disponibles
# ---------------------------------------------------------------------------
_list_groups() {
    echo ""
    echo "Grupos disponibles en openwrt-post-install-packages.toml:"
    echo ""
    while IFS='|' read -r group desc packages; do
        printf "  [%-20s] %s\n" "${group}" "${desc}"
        for pkg in ${packages}; do
            printf "    • %s\n" "${pkg}"
        done
        echo ""
    done < <(_parse_groups)
}

if "${_LIST_ONLY}"; then
    _list_groups
    exit 0
fi

# ---------------------------------------------------------------------------
# Cargar entorno
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "============================================="
echo " Post-Install — Instalación de paquetes"
echo "============================================="
echo "   Router: root@${ROUTER_IP}:${SSH_PORT}"
[ -n "${_GROUP}" ] && echo "   Grupo:  ${_GROUP}" || echo "   Grupos: todos"
echo ""

# Verificar SSH
if ! ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" "exit" 2>/dev/null; then
    log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
    exit 1
fi
log_info "✅ Conectado"

# Recoger paquetes a instalar
all_packages=""
while IFS='|' read -r group desc packages; do
    if [ -n "${_GROUP}" ] && [ "${group}" != "${_GROUP}" ]; then
        continue
    fi
    if [ -n "${_GROUP}" ] && [ "${group}" != "${_GROUP}" ]; then
        continue
    fi
    echo "   Grupo [${group}]: ${desc}"
    for pkg in ${packages}; do
        echo "     • ${pkg}"
        all_packages="${all_packages} ${pkg}"
    done
done < <(_parse_groups)

if [ -z "${all_packages}" ]; then
    if [ -n "${_GROUP}" ]; then
        log_error "Grupo no encontrado: '${_GROUP}'"
        echo "   Grupos disponibles:"
        _parse_groups | cut -d'|' -f1 | sed 's/^/   • /'
    else
        log_warn "No hay paquetes para instalar."
    fi
    exit 1
fi

echo ""
read -r -p "¿Instalar los paquetes listados? (s/N) " answer
answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
    echo "Cancelado."
    exit 0
fi

echo ""
pkg_manager=$(_ssh "if command -v apk >/dev/null 2>&1; then echo apk; elif command -v opkg >/dev/null 2>&1; then echo opkg; fi")
if [ -z "${pkg_manager}" ]; then
    log_error "No se encontró apk ni opkg en el router."
    exit 1
fi

log_step "Instalando paquetes con ${pkg_manager}..."
if [ "${pkg_manager}" = "apk" ]; then
    # OpenWRT 25.12+ usa apk. -U actualiza índices antes de instalar.
    # shellcheck disable=SC2086
    _ssh "apk -U add ${all_packages}"
else
    _ssh "opkg update"
    # shellcheck disable=SC2086
    _ssh "opkg install ${all_packages}"
fi

echo ""
log_info "✅ Paquetes instalados: ${all_packages}"
