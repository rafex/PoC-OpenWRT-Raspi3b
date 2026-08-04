#!/usr/bin/env bash
# ============================================================================
# backup.sh — Backup y restauración de configuración del router OpenWRT
#
# Subcomandos:
#   backup   Descarga /etc/config como .tar.gz a ./backups/ (o --dir)
#   restore  Sube un backup local y lo aplica en el router
#   list     Lista los backups locales disponibles
#
# Uso:
#   backup.sh backup  [--ip <IP>] [--env <env>] [--dir <dir>]
#   backup.sh restore --file <backup.tar.gz> [--ip <IP>] [--env <env>]
#   backup.sh list    [--dir <dir>]
# ============================================================================
set -euo pipefail
ROUTER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROUTER_SCRIPT_DIR}/../commons/router-base.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

_DEFAULT_BACKUP_DIR="${REPO_ROOT}/backups"

_SUBCMD=""
ROUTER_ENV="prod"
_ROUTER_IP_CLI=""
_FILE=""
_DIR=""

_show_help() {
    cat << 'HELP'
Uso: backup.sh <subcomando> [opciones]

Subcomandos:
  backup   Descarga backup de configuración del router a ./backups/
  restore  Aplica un backup local en el router y reinicia
  list     Lista los backups locales disponibles

Opciones:
  --ip <IP>      IP del router (default: env o 192.168.1.1)
  --env <env>    Entorno (default: prod)
  --dir <dir>    Directorio local de backups (default: ./backups/)
  --file <path>  Archivo de backup a restaurar (solo para restore)

Ejemplos:
  backup.sh backup
  backup.sh backup --dir /tmp/router-backups
  backup.sh restore --file backups/router-20260518-142300.tar.gz
  backup.sh list
HELP
}

if [[ $# -eq 0 ]]; then _show_help; exit 1; fi
case "$1" in
    backup|restore|list) _SUBCMD="$1"; shift ;;
    -h|--help) _show_help; exit 0 ;;
    *) log_error "Subcomando desconocido: $1"; _show_help; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)    _ROUTER_IP_CLI="${2:?}";  shift 2 ;;
        --env)   ROUTER_ENV="${2:?}";     shift 2 ;;
        --dir)   _DIR="${2:?}";     shift 2 ;;
        --file)  _FILE="${2:?}";    shift 2 ;;
        -h|--help) _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
    esac
done

router_load_env "${ROUTER_ENV}"
BACKUP_DIR="${_DIR:-${_DEFAULT_BACKUP_DIR}}"

_scp_get() {
    ssh -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" -o CheckHostIP=no \
        "root@${ROUTER_IP}" "cat '$1'" > "$2"
}

_scp_put() {
    ssh -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${KNOWN_HOSTS_FILE}" -o CheckHostIP=no \
        "root@${ROUTER_IP}" "cat > '$2'" < "$1"
}

# ---------------------------------------------------------------------------
_backup() {
    router_check_ssh
    mkdir -p "${BACKUP_DIR}"

    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local remote_file="/tmp/router-backup-${ts}.tar.gz"
    local local_file="${BACKUP_DIR}/router-${ROUTER_IP}-${ts}.tar.gz"

    log_step "Generando backup en el router..."
    router_ssh sysupgrade -b "${remote_file}"

    log_step "Descargando backup..."
    _scp_get "${remote_file}" "${local_file}"
    router_ssh rm -f "${remote_file}" 2>/dev/null || true

    echo ""
    log_info "✅ Backup guardado en: ${local_file}"
    ls -lh "${local_file}"
}

# ---------------------------------------------------------------------------
_restore() {
    if [ -z "${_FILE}" ]; then
        log_error "Especifica el archivo de backup con --file <path>"
        exit 1
    fi
    if [ ! -f "${_FILE}" ]; then
        log_error "Archivo no encontrado: ${_FILE}"
        exit 1
    fi

    router_check_ssh

    local remote_file="/tmp/router-restore.tar.gz"
    echo ""
    log_warn "Esto restaurará la configuración del router y lo reiniciará."
    read -r -p "¿Continuar? (s/N) " answer
    [[ "${answer,,}" != "s" ]] && { echo "Cancelado."; exit 0; }

    log_step "Subiendo backup al router..."
    _scp_put "${_FILE}" "${remote_file}"

    log_step "Aplicando configuración..."
    router_ssh sh - << EOF
tar xzf ${remote_file} -C /
rm -f ${remote_file}
echo "Configuración restaurada. Reiniciando..."
reboot
EOF

    echo ""
    log_info "✅ Configuración restaurada. El router se está reiniciando..."
    log_info "   Espera ~60 segundos antes de reconectar."
}

# ---------------------------------------------------------------------------
_list() {
    mkdir -p "${BACKUP_DIR}"
    echo ""
    echo "Backups en ${BACKUP_DIR}:"
    echo "────────────────────────────────────────────"
    if ls "${BACKUP_DIR}"/router-*.tar.gz 2>/dev/null | sort -r; then
        echo ""
        echo "Total: $(ls "${BACKUP_DIR}"/router-*.tar.gz 2>/dev/null | wc -l | tr -d ' ') backup(s)"
    else
        echo "  (ninguno)"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
case "${_SUBCMD}" in
    backup)  _backup ;;
    restore) _restore ;;
    list)    _list ;;
esac
