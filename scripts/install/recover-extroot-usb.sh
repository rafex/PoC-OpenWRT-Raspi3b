#!/usr/bin/env bash
# ============================================================================
# recover-extroot-usb.sh — Intenta reparar y respaldar un USB extroot
#
# Este script corre en la máquina local donde se ejecuta `just` (por ejemplo,
# bastion-wifi). No corre dentro del router.
#
# Uso:
#   recover-extroot-usb.sh --list
#   recover-extroot-usb.sh --device /dev/sdX1 [--backup-dir <dir>] [--yes]
# ============================================================================
set -euo pipefail

# Non-root SSH sessions on some Debian installations omit administrative
# binary directories from PATH, although the tools are installed there.
PATH="/usr/local/sbin:/usr/sbin:/sbin:${PATH:-/usr/local/bin:/usr/bin:/bin}"
export PATH

_DEVICE=""
_BACKUP_DIR="${HOME}/openwrt-extroot-backups"
_YES=false
_LIST=false

_usage() {
    cat <<'HELP'
Uso:
  recover-extroot-usb.sh --list
  recover-extroot-usb.sh --device /dev/sdX1 [--backup-dir <dir>] [--yes]

Opciones:
  --list             Lista discos/particiones visibles en este host
  --device <dev>    Partición USB extroot a reparar/respaldar, ej. /dev/sdb1
  --backup-dir <dir> Directorio local para guardar el .tar.gz
  --yes              No pedir confirmación interactiva para e2fsck

Qué hace:
  1. Verifica que el dispositivo sea una partición USB tipo /dev/sdX1
  2. Desmonta la partición si estaba montada
  3. Ejecuta e2fsck -f -y para reparar ext4
  4. Monta read-only y revisa marcadores de extroot
  5. Crea un backup .tar.gz preservando dueños numéricos, ACLs y xattrs

No formatea ni borra el USB.
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) _LIST=true; shift ;;
        --device) _DEVICE="${2:?--device requiere argumento}"; shift 2 ;;
        --backup-dir) _BACKUP_DIR="${2:?--backup-dir requiere argumento}"; shift 2 ;;
        --yes) _YES=true; shift ;;
        -h|--help) _usage; exit 0 ;;
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
    lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL
    exit 0
fi

_require e2fsck
_require findmnt
_require gzip
_require sudo
_require tar

if [[ -z "${_DEVICE}" ]]; then
    echo "[ERROR] Especifica --device /dev/sdX1" >&2
    echo ""
    _usage
    exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[ERROR] Esta tarea debe ejecutarse en Linux, por ejemplo dentro de ssh bastion-wifi." >&2
    exit 1
fi

if [[ ! -b "${_DEVICE}" ]]; then
    echo "[ERROR] No existe como dispositivo de bloque: ${_DEVICE}" >&2
    echo ""
    echo "Dispositivos disponibles:"
    lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL
    exit 1
fi

if [[ ! "${_DEVICE}" =~ ^/dev/sd[a-z][0-9]+$ ]]; then
    echo "[ERROR] Usa una partición USB tipo /dev/sdX1." >&2
    echo "Valor recibido: ${_DEVICE}" >&2
    exit 1
fi

_PARENT="/dev/$(lsblk -no PKNAME "${_DEVICE}" | head -1)"
_TRAN="$(lsblk -ndo TRAN "${_PARENT}" 2>/dev/null | head -1 || true)"
_FSTYPE="$(lsblk -no FSTYPE "${_DEVICE}" 2>/dev/null | head -1 || true)"
_DEV_BASENAME="$(basename "${_DEVICE}")"
_HOST="$(hostname 2>/dev/null || echo host)"
_STAMP="$(date +%Y%m%d-%H%M%S)"
_MNT="/mnt/openwrt-extroot-recover-${_DEV_BASENAME}"
_BACKUP_FILE="${_BACKUP_DIR}/extroot-${_HOST}-${_DEV_BASENAME}-${_STAMP}.tar.gz"

if [[ "${_TRAN}" != "usb" ]]; then
    echo "[ERROR] El disco padre no parece USB: ${_PARENT} TRAN='${_TRAN:-?}'" >&2
    echo "Vista del disco:"
    lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL "${_PARENT}"
    exit 1
fi

if [[ "${_FSTYPE}" != "ext4" ]]; then
    echo "[ERROR] La partición no aparece como ext4: ${_DEVICE} FSTYPE='${_FSTYPE:-?}'" >&2
    exit 1
fi

echo "==============================================="
echo " Recuperar USB OpenWrt extroot"
echo "==============================================="
echo ""
echo "Host:        ${_HOST}"
echo "Dispositivo: ${_DEVICE}"
echo "Disco padre: ${_PARENT}"
echo "Backup dir:  ${_BACKUP_DIR}"
echo "Backup file: ${_BACKUP_FILE}"
echo ""
echo "Vista del disco:"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL "${_PARENT}"
echo ""

if ! "${_YES}"; then
    echo "Se ejecutará e2fsck -f -y sobre ${_DEVICE}."
    echo "Esto intenta reparar el filesystem ext4; no formatea ni borra deliberadamente."
    read -r -p "Escribe exactamente 'REPARAR ${_DEVICE}' para continuar: " confirm
    if [[ "${confirm}" != "REPARAR ${_DEVICE}" ]]; then
        echo "Cancelado."
        exit 0
    fi
fi

echo ""
echo "[STEP] Desmontando ${_DEVICE} si estaba montado..."
sudo umount "${_DEVICE}" 2>/dev/null || true

echo "[STEP] Reparando ext4 con e2fsck..."
sudo e2fsck -f -y "${_DEVICE}"

echo "[STEP] Montando read-only..."
sudo mkdir -p "${_MNT}"
sudo mount -o ro "${_DEVICE}" "${_MNT}"

cleanup() {
    sudo umount "${_MNT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[STEP] Revisando contenido..."
sudo find "${_MNT}" -mindepth 1 -maxdepth 2 2>/dev/null | head -80 || true
echo ""

if [[ -d "${_MNT}/upper" && -d "${_MNT}/work" ]]; then
    echo "[INFO] Marcadores extroot encontrados: upper/ y work/"
else
    echo "[WARN] No se encontraron marcadores completos de extroot en la raíz."
    echo "       Se intentará respaldar de todos modos."
fi

echo "[STEP] Generando backup tar.gz..."
mkdir -p "${_BACKUP_DIR}"
sudo tar --xattrs --acls --numeric-owner -C "${_MNT}" -cpf - . | gzip -c > "${_BACKUP_FILE}"

echo "[STEP] Verificando backup..."
gzip -t "${_BACKUP_FILE}"
ls -lh "${_BACKUP_FILE}"

echo ""
echo "[INFO] Recuperación terminada."
echo "Backup creado: ${_BACKUP_FILE}"
echo ""
echo "Si decides borrar/recrear el USB después del backup:"
echo "  just host-format-extroot-usb --device ${_DEVICE}"
