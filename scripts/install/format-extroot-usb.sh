#!/usr/bin/env bash
# ============================================================================
# format-extroot-usb.sh — Formatea un USB ext4 para OpenWrt extroot
#
# Este script corre en la máquina local donde se ejecuta `just` (por ejemplo,
# bastion-wifi). No corre dentro del router.
#
# Uso:
#   format-extroot-usb.sh --list
#   format-extroot-usb.sh --device /dev/sdX1 [--label openwrt-extroot] [--yes]
# ============================================================================
set -euo pipefail

_DEVICE=""
_LABEL="openwrt-extroot"
_YES=false
_LIST=false

_usage() {
    cat <<'HELP'
Uso:
  format-extroot-usb.sh --list
  format-extroot-usb.sh --device /dev/sdX1 [--label openwrt-extroot] [--yes]

Opciones:
  --list          Lista discos/particiones visibles en este host
  --device <dev> Partición a borrar/formatear, ej. /dev/sdb1
  --label <name> Etiqueta ext4 a asignar (default: openwrt-extroot)
  --yes           No pedir confirmación interactiva

ADVERTENCIA:
  Borra completamente la partición indicada. Ejecuta esto desde la máquina
  donde está conectado físicamente el USB, no desde el router.
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list) _LIST=true; shift ;;
        --device) _DEVICE="${2:?--device requiere argumento}"; shift 2 ;;
        --label) _LABEL="${2:?--label requiere argumento}"; shift 2 ;;
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

_require findmnt
_require sudo
_require wipefs
_require mkfs.ext4

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

if [[ "${_DEVICE}" =~ ^/dev/(nvme|mmcblk|loop|md|dm-) ]]; then
    echo "[ERROR] Por seguridad no se acepta este tipo de dispositivo: ${_DEVICE}" >&2
    echo "Usa una partición USB tipo /dev/sdX1." >&2
    exit 1
fi

if [[ ! "${_DEVICE}" =~ ^/dev/sd[a-z][0-9]+$ ]]; then
    echo "[ERROR] Usa una partición USB tipo /dev/sdX1, no un disco completo ni otro tipo de bloque." >&2
    echo "Valor recibido: ${_DEVICE}" >&2
    exit 1
fi

if lsblk -no PKNAME "${_DEVICE}" >/dev/null 2>&1; then
    _PARENT="/dev/$(lsblk -no PKNAME "${_DEVICE}" | head -1)"
else
    echo "[ERROR] No se pudo detectar disco padre para ${_DEVICE}" >&2
    exit 1
fi

echo "==============================================="
echo " Formatear USB para OpenWrt extroot"
echo "==============================================="
echo ""
echo "Host:        $(hostname 2>/dev/null || echo '?')"
echo "Dispositivo: ${_DEVICE}"
echo "Disco padre: ${_PARENT}"
echo "Etiqueta:    ${_LABEL}"
echo ""
echo "Vista del disco:"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL "${_PARENT}"
echo ""

if findmnt -rn --source "${_DEVICE}" >/dev/null 2>&1; then
    echo "[INFO] ${_DEVICE} aparece montado; se desmontará antes de formatear."
fi

if ! "${_YES}"; then
    echo "Esto BORRA por completo ${_DEVICE}."
    read -r -p "Escribe exactamente 'BORRAR ${_DEVICE}' para continuar: " confirm
    if [[ "${confirm}" != "BORRAR ${_DEVICE}" ]]; then
        echo "Cancelado."
        exit 0
    fi
fi

echo ""
echo "[STEP] Desmontando ${_DEVICE} si estaba montado..."
sudo umount "${_DEVICE}" 2>/dev/null || true

echo "[STEP] Borrando firmas previas..."
sudo wipefs -a "${_DEVICE}"

echo "[STEP] Creando ext4..."
sudo mkfs.ext4 -F -L "${_LABEL}" "${_DEVICE}"

echo "[STEP] Sincronizando..."
sync

echo ""
echo "[INFO] USB listo para OpenWrt extroot:"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL "${_PARENT}"
echo ""
echo "Siguiente paso, conecta el USB al router y ejecuta:"
echo "  just router-setup-extroot --ip 192.168.1.1 --device /dev/sda1"
