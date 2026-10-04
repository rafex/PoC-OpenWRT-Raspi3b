#!/usr/bin/env bash
# Diagnose, preserve readable files, and optionally repair an OpenWrt extroot USB.
set -euo pipefail

PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH:-/usr/local/bin:/usr/bin:/bin}"
export PATH

_DEVICE=""
_UUID=""
_BACKUP_DIR="${HOME}/openwrt-extroot-backups"
_LIST=false
_REPAIR=false
_MNT=""
_MOUNTED_BY_SCRIPT=false
_TMP_FILES=()
if [[ "${EUID}" -eq 0 ]]; then _SUDO=(); else _SUDO=(sudo); fi

_usage() {
    cat <<'HELP'
Uso:
  recover-extroot-usb.sh --list
  recover-extroot-usb.sh (--device /dev/sdX1 | --uuid <UUID>) [--backup-dir <dir>] [--repair]

Opciones:
  --list               Lista discos/particiones USB visibles
  --device <dev>       Partición USB ext4 conectada a esta máquina
  --uuid <uuid>        Resuelve la partición local por UUID (nombre dinámico)
  --backup-dir <dir>   Directorio local para informes y respaldos
  --repair             Tras respaldo legible y confirmación, ejecuta e2fsck -f -p

El diagnóstico no repara: ejecuta e2fsck -fn y monta con ro,noload. El respaldo
continúa si hay entradas ilegibles; un manifiesto identifica los errores. La
reparación -p aplica solo correcciones automáticas seguras y se detiene si
e2fsck requiere intervención. Nunca formatea.
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) _LIST=true; shift ;;
        --device) _DEVICE="${2:?--device requiere argumento}"; shift 2 ;;
        --uuid) _UUID="${2:?--uuid requiere argumento}"; shift 2 ;;
        --backup-dir) _BACKUP_DIR="${2:?--backup-dir requiere argumento}"; shift 2 ;;
        --repair) _REPAIR=true; shift ;;
        -h|--help) _usage; exit 0 ;;
        --yes)
            echo "[ERROR] --yes no está permitido; la reparación requiere confirmación." >&2
            exit 1 ;;
        *) echo "[ERROR] Argumento desconocido: $1" >&2; _usage; exit 1 ;;
    esac
done

_require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[ERROR] Falta dependencia local: $1" >&2
        exit 1
    }
}

_require lsblk
if "${_LIST}"; then
    lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,FSAVAIL,FSUSE%,MOUNTPOINTS,TRAN,MODEL
    exit 0
fi

for _tool in date findmnt gzip mount sudo tar umount; do
    if [[ "${EUID}" -eq 0 && "${_tool}" == sudo ]]; then continue; fi
    _require "${_tool}"
done
_require e2fsck

if [[ "$(uname -s)" != Linux ]]; then
    echo "[ERROR] Esta tarea debe ejecutarse en Linux, donde está conectada la USB." >&2
    exit 1
fi
if [[ -n "${_DEVICE}" && -n "${_UUID}" ]]; then
    echo "[ERROR] Usa --device o --uuid, no ambos." >&2
    exit 1
fi

if [[ -n "${_UUID}" ]]; then
    if [[ ! "${_UUID}" =~ ^[[:alnum:]-]+$ ]]; then
        echo "[ERROR] UUID inválido: ${_UUID}" >&2
        exit 1
    fi
    mapfile -t _MATCHES < <(lsblk -nrpo PATH,UUID | awk -v uuid="${_UUID}" '$2 == uuid {print $1}')
    if [[ "${#_MATCHES[@]}" -ne 1 ]]; then
        echo "[ERROR] El UUID ${_UUID} debe identificar exactamente una partición local; coincidencias: ${#_MATCHES[@]}." >&2
        lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL
        exit 1
    fi
    _DEVICE="${_MATCHES[0]}"
fi
if [[ -z "${_DEVICE}" ]]; then
    echo "[ERROR] Especifica --device o --uuid." >&2
    _usage
    exit 1
fi
if [[ ! -b "${_DEVICE}" || ! "${_DEVICE}" =~ ^/dev/sd[a-z][0-9]+$ ]]; then
    echo "[ERROR] Se requiere una partición USB tipo /dev/sdX1: ${_DEVICE}" >&2
    exit 1
fi

_PKNAME="$(lsblk -no PKNAME "${_DEVICE}" | head -1)"
if [[ -z "${_PKNAME}" ]]; then
    echo "[ERROR] No se pudo determinar el disco padre de ${_DEVICE}." >&2
    exit 1
fi
_PARENT="/dev/${_PKNAME}"
_TRAN="$(lsblk -ndo TRAN "${_PARENT}" 2>/dev/null | head -1 || true)"
_FSTYPE="$(lsblk -no FSTYPE "${_DEVICE}" | head -1)"
_ACTUAL_UUID="$(lsblk -no UUID "${_DEVICE}" | head -1)"
if [[ "${_TRAN}" != usb || "${_FSTYPE}" != ext4 ]]; then
    echo "[ERROR] Se requiere una partición USB ext4; TRAN='${_TRAN:-?}', FSTYPE='${_FSTYPE:-?}'." >&2
    lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL "${_PARENT}"
    exit 1
fi
if [[ -n "${_UUID}" && "${_UUID}" != "${_ACTUAL_UUID}" ]]; then
    echo "[ERROR] El UUID resuelto no coincide con el dispositivo: ${_ACTUAL_UUID}" >&2
    exit 1
fi

_STAMP="$(date +%Y%m%d-%H%M%S)"
_HOST="$(hostname 2>/dev/null || echo host)"
_BASE="${_BACKUP_DIR}/extroot-${_HOST}-${_ACTUAL_UUID}-${_STAMP}"
_BACKUP_FILE="${_BASE}.tar.gz"
_LOGS_FILE="${_BASE}-logs.tar.gz"
_FSCK_LOG="${_BASE}-e2fsck-readonly.txt"
_TAR_LOG="${_BASE}-backup-warnings.txt"
_LOG_LIST="${_BASE}-log-files.null"
_STATUS_FILE="${_BASE}-backup-status.txt"
_MNT="/mnt/openwrt-extroot-recover-${_ACTUAL_UUID}-$$"
mkdir -p "${_BACKUP_DIR}"

_cleanup() {
    if "${_MOUNTED_BY_SCRIPT}"; then
        "${_SUDO[@]}" umount "${_MNT}" 2>/dev/null || true
        _MOUNTED_BY_SCRIPT=false
    fi
    if [[ -n "${_MNT}" ]]; then "${_SUDO[@]}" rmdir "${_MNT}" 2>/dev/null || true; fi
    for _tmp in "${_TMP_FILES[@]}"; do rm -f "${_tmp}"; done
}
trap _cleanup EXIT

echo "==============================================="
echo " Diagnóstico USB OpenWrt extroot"
echo "==============================================="
echo "Dispositivo: ${_DEVICE}"
echo "UUID:        ${_ACTUAL_UUID}"
echo "Disco padre: ${_PARENT}"
echo "Backup dir:  ${_BACKUP_DIR}"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,FSAVAIL,FSUSE%,MOUNTPOINTS,TRAN,MODEL "${_PARENT}"

mapfile -t _MOUNT_TARGETS < <(findmnt -rn --source "${_DEVICE}" -o TARGET || true)
for _target in "${_MOUNT_TARGETS[@]}"; do
    echo "[STEP] Desmontando ${_DEVICE} de ${_target}..."
    "${_SUDO[@]}" umount "${_target}"
done

echo "[STEP] Comprobación ext4 de solo lectura (e2fsck -fn)..."
set +e
"${_SUDO[@]}" e2fsck -f -n "${_DEVICE}" >"${_FSCK_LOG}" 2>&1
_FSCK_STATUS=$?
set -e
cat "${_FSCK_LOG}"
echo "[INFO] e2fsck -fn terminó con código ${_FSCK_STATUS}; el informe está en ${_FSCK_LOG}."

"${_SUDO[@]}" mkdir -p "${_MNT}"
echo "[STEP] Montando en solo lectura sin replay del journal..."
if ! "${_SUDO[@]}" mount -t ext4 -o ro,noload "${_DEVICE}" "${_MNT}"; then
    echo "[ERROR] No se pudo montar en solo lectura. No se intentará reparar sin respaldo legible." >&2
    exit 1
fi
_MOUNTED_BY_SCRIPT=true

if [[ -d "${_MNT}/upper" && -d "${_MNT}/work" ]]; then
    echo "[INFO] Marcadores extroot encontrados: upper/ y work/."
else
    echo "[WARN] Faltan los marcadores extroot upper/ y/o work/."
fi

echo "[STEP] Creando respaldo de todos los archivos legibles..."
set +e
"${_SUDO[@]}" tar --ignore-failed-read --xattrs --acls --numeric-owner \
    -C "${_MNT}" -cpf - . 2>"${_TAR_LOG}" | gzip -c >"${_BACKUP_FILE}"
_PIPE_STATUS=("${PIPESTATUS[@]}")
set -e
if [[ "${_PIPE_STATUS[1]:-1}" -ne 0 ]] || ! gzip -t "${_BACKUP_FILE}"; then
    echo "[ERROR] El archivo de respaldo no es verificable; no se reparará ext4." >&2
    cat "${_TAR_LOG}" >&2 || true
    exit 1
fi

if [[ "${_PIPE_STATUS[0]:-0}" -ne 0 || -s "${_TAR_LOG}" ]]; then
    _ARCHIVE_STATUS="PARTIAL"
    echo "[WARN] Respaldo PARCIAL: tar reportó rutas ilegibles. Ver ${_TAR_LOG}."
else
    _ARCHIVE_STATUS="COMPLETE"
    echo "[INFO] Respaldo completo."
fi

echo "[STEP] Buscando logs persistentes..."
_TMP_FILES+=("${_LOG_LIST}")
"${_SUDO[@]}" find "${_MNT}" -xdev -type f \
    \( -iname messages -o -iname syslog -o -iname dmesg -o -iname kern.log -o -iname daemon.log \) \
    -printf '%P\0' >"${_LOG_LIST}" 2>"${_BASE}-find-warnings.txt" || true
_LOG_COUNT="$(tr -cd '\000' <"${_LOG_LIST}" | wc -c | tr -d ' ')"
if [[ "${_LOG_COUNT}" -gt 0 ]]; then
    if "${_SUDO[@]}" tar --ignore-failed-read --xattrs --acls --numeric-owner \
        -C "${_MNT}" --null -T "${_LOG_LIST}" -czf "${_LOGS_FILE}" 2>>"${_TAR_LOG}"; then
        gzip -t "${_LOGS_FILE}"
        echo "[INFO] Logs encontrados (${_LOG_COUNT} archivos) en ${_LOGS_FILE}"
        tr '\000' '\n' <"${_LOG_LIST}"
    else
        echo "[WARN] Se encontraron logs, pero no todos pudieron respaldarse; revisar ${_TAR_LOG}."
    fi
else
    echo "[WARN] No se encontraron archivos de log persistentes reconocidos."
fi
printf 'uuid=%s\ndevice=%s\nfsck_readonly_status=%s\narchive=%s\narchive_status=%s\nlogs=%s\n' \
    "${_ACTUAL_UUID}" "${_DEVICE}" "${_FSCK_STATUS}" "${_BACKUP_FILE}" \
    "${_ARCHIVE_STATUS}" "${_LOG_COUNT}" >"${_STATUS_FILE}"
"${_SUDO[@]}" umount "${_MNT}"
_MOUNTED_BY_SCRIPT=false
ls -lh "${_BACKUP_FILE}" "${_FSCK_LOG}" "${_TAR_LOG}" "${_STATUS_FILE}"

if "${_REPAIR}"; then
    echo ""
    echo "El respaldo (completo o parcial) ya se guardó antes de reparar."
    echo "e2fsck -p intentará solo correcciones automáticas seguras."
    read -r -p "Escribe exactamente 'REPARAR ${_ACTUAL_UUID}' para continuar: " _CONFIRM
    if [[ "${_CONFIRM}" != "REPARAR ${_ACTUAL_UUID}" ]]; then
        echo "Reparación cancelada; se conservaron los informes y el respaldo."
        exit 0
    fi

    echo "[STEP] Reparación segura e2fsck -f -p..."
    set +e
    "${_SUDO[@]}" e2fsck -f -p "${_DEVICE}"
    _REPAIR_STATUS=$?
    set -e
    case "${_REPAIR_STATUS}" in
        0) echo "[INFO] e2fsck no encontró correcciones pendientes." ;;
        1|2|3) echo "[INFO] e2fsck aplicó correcciones seguras (código ${_REPAIR_STATUS})." ;;
        *)
            echo "[ERROR] e2fsck -p dejó errores que requieren intervención (código ${_REPAIR_STATUS})." >&2
            echo "        USB conservada sin montar; revisar ${_FSCK_LOG} y ejecutar diagnóstico manual." >&2
            exit "${_REPAIR_STATUS}"
            ;;
    esac

    echo "[STEP] Verificación posterior de solo lectura..."
    set +e
    "${_SUDO[@]}" e2fsck -f -n "${_DEVICE}" >"${_BASE}-e2fsck-post-repair.txt" 2>&1
    _POST_STATUS=$?
    set -e
    cat "${_BASE}-e2fsck-post-repair.txt"
    if [[ "${_POST_STATUS}" -ne 0 ]]; then
        echo "[ERROR] La verificación posterior sigue reportando errores (código ${_POST_STATUS}); no reconectes como extroot todavía." >&2
        exit 1
    fi

    echo "[STEP] Respaldo posterior a la reparación..."
    "${_SUDO[@]}" mount -t ext4 -o ro,noload "${_DEVICE}" "${_MNT}"
    _MOUNTED_BY_SCRIPT=true
    _POST_FILE="${_BASE}-post-repair.tar.gz"
    set +e
    "${_SUDO[@]}" tar --ignore-failed-read --xattrs --acls --numeric-owner \
        -C "${_MNT}" -cpf - . 2>"${_BASE}-post-repair-warnings.txt" | gzip -c >"${_POST_FILE}"
    _POST_PIPE_STATUS=("${PIPESTATUS[@]}")
    set -e
    if [[ "${_POST_PIPE_STATUS[1]:-1}" -ne 0 ]] || ! gzip -t "${_POST_FILE}"; then
        echo "[ERROR] Falló el respaldo posterior; se conserva el respaldo previo." >&2
        exit 1
    fi
    "${_SUDO[@]}" umount "${_MNT}"
    _MOUNTED_BY_SCRIPT=false
    echo "[INFO] Respaldo posterior: ${_POST_FILE}"
fi

echo ""
if "${_REPAIR}"; then
    echo "[INFO] Recuperación host terminada y verificada para UUID ${_ACTUAL_UUID}."
    echo "Vuelve a conectar la USB al router y ejecuta:"
    echo "  just router-extroot-recover finish --uuid ${_ACTUAL_UUID}"
else
    echo "[INFO] Diagnóstico host terminado para UUID ${_ACTUAL_UUID}."
    echo "Revisa ${_STATUS_FILE}; para intentar la reparación segura, vuelve a ejecutar:"
    echo "  just host-recover-extroot-usb --uuid ${_ACTUAL_UUID} --repair"
fi
