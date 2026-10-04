#!/usr/bin/env bash
# Capture live router diagnostics before moving USB to host, then fix extroot UUID.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/router-base.sh"

_MODE="${1:-}"
if [[ -n "${_MODE}" ]]; then shift; fi
_UUID=""
_ROUTER_ENV="prod"
_usage() {
    cat <<'HELP'
Uso:
  recover-extroot.sh prepare [--ip <IP>] [--env <env>] [--uuid <UUID>]
  recover-extroot.sh finish --uuid <UUID> [--ip <IP>] [--env <env>]
HELP
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip) _ROUTER_IP_CLI="${2:?--ip requiere argumento}"; shift 2 ;;
        --env) _ROUTER_ENV="${2:?--env requiere argumento}"; shift 2 ;;
        --uuid) _UUID="${2:?--uuid requiere argumento}"; shift 2 ;;
        -h|--help) _usage; exit 0 ;;
        *) echo "[ERROR] Argumento desconocido: $1" >&2; _usage; exit 1 ;;
    esac
done
if [[ "${_MODE}" != prepare && "${_MODE}" != finish ]]; then
    echo "[ERROR] Especifica prepare o finish." >&2; _usage; exit 1
fi
if [[ -n "${_UUID}" && ! "${_UUID}" =~ ^[[:alnum:]-]+$ ]]; then
    echo "[ERROR] UUID inválido: ${_UUID}" >&2; exit 1
fi
if [[ "${_MODE}" == finish && -z "${_UUID}" ]]; then
    echo "[ERROR] finish requiere --uuid <UUID>." >&2; exit 1
fi
router_load_env "${_ROUTER_ENV}"
router_check_ssh

if [[ "${_MODE}" == prepare ]]; then
    _OUT_DIR="${HOME}/openwrt-extroot-backups"
    mkdir -p "${_OUT_DIR}"
    _STAMP="$(date +%Y%m%d-%H%M%S)"
    _REPORT="${_OUT_DIR}/router-prepare-${ROUTER_IP}-${_STAMP}.txt"
    echo "[INFO] Capturando estado/logs del router en ${_REPORT}"
    router_ssh "sh -c 'UUID_FILTER=${_UUID}; export UUID_FILTER; exec sh'" <<'REMOTE' | tee "${_REPORT}"
set -u
echo '=== OpenWrt extroot recovery prepare ==='
date -u 2>/dev/null || date
echo '=== block info ==='
INFO="$(block info 2>&1 || true)"
echo "$INFO"
echo '=== fstab ==='
uci show fstab 2>&1 || true
echo '=== mounts ==='
cat /proc/mounts
echo '=== /overlay filesystem ==='
df -h /overlay 2>&1 || true
echo '=== dmesg tail ==='
dmesg 2>&1 | tail -200 || true
echo '=== logread tail ==='
logread 2>&1 | tail -500 || true

FOUND_DEVICE=''
FOUND_UUID=''
COUNT=0
for CANDIDATE in $(echo "$INFO" | sed -n '/^\/dev\/sd[a-z][0-9]*:/s/:.*//p'); do
    LINE=$(echo "$INFO" | grep "^$CANDIDATE:" | head -1)
    TYPE=$(echo "$LINE" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
    UUID=$(echo "$LINE" | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
    [ "$TYPE" = ext4 ] || continue
    [ -z "$UUID_FILTER" ] || [ "$UUID" = "$UUID_FILTER" ] || continue
    COUNT=$((COUNT + 1))
    FOUND_DEVICE="$CANDIDATE"
    FOUND_UUID="$UUID"
done
if [ "$COUNT" -ne 1 ]; then
    echo "[ERROR] Se requiere una sola USB ext4 seleccionada; coincidencias=$COUNT. Usa --uuid entre los candidatos de block info."
    exit 2
fi
echo "RECOVERY_DEVICE=$FOUND_DEVICE"
echo "RECOVERY_UUID=$FOUND_UUID"
OVERLAY_SOURCE=$(awk '$2 == "/overlay" {print $1; exit}' /proc/mounts)
if [ "$OVERLAY_SOURCE" = "$FOUND_DEVICE" ]; then
    echo '[ERROR] La USB está montada como /overlay. No la retires ni la pases al host.'
    exit 3
fi
USB_MOUNT=$(awk -v dev="$FOUND_DEVICE" '$1 == dev {print $2; exit}' /proc/mounts)
if [ -n "$USB_MOUNT" ]; then
    echo "[STEP] Desmontando $FOUND_DEVICE de $USB_MOUNT para poder retirarla..."
    if ! umount "$USB_MOUNT"; then
        echo "[ERROR] No se pudo desmontar $FOUND_DEVICE. No retires la USB."
        exit 4
    fi
else
    echo '[INFO] La USB no está montada en OpenWrt.'
fi
echo '[OK] Puedes retirar la USB y conectarla a esta máquina para reparar ext4.'
echo "[NEXT] just host-recover-extroot-usb --uuid $FOUND_UUID --repair"
REMOTE
    echo "[INFO] Diagnóstico remoto guardado: ${_REPORT}"
    exit 0
fi

echo "[INFO] Verificando y corrigiendo fstab en ${ROUTER_IP} para UUID ${_UUID}..."
router_ssh "sh -c 'UUID_EXPECTED=${_UUID}; export UUID_EXPECTED; exec sh'" <<'REMOTE'
set -eu
INFO=$(block info 2>/dev/null || true)
FOUND_DEVICE=''
FOUND_TYPE=''
for CANDIDATE in $(echo "$INFO" | sed -n '/^\/dev\/sd[a-z][0-9]*:/s/:.*//p'); do
    LINE=$(echo "$INFO" | grep "^$CANDIDATE:" | head -1)
    UUID=$(echo "$LINE" | sed -n 's/.*UUID="\([^"]*\)".*/\1/p')
    if [ "$UUID" = "$UUID_EXPECTED" ]; then
        FOUND_DEVICE="$CANDIDATE"
        FOUND_TYPE=$(echo "$LINE" | sed -n 's/.*TYPE="\([^"]*\)".*/\1/p')
        break
    fi
done
if [ -z "$FOUND_DEVICE" ] || [ "$FOUND_TYPE" != ext4 ]; then
    echo "[ERROR] No se encontró UUID ext4 $UUID_EXPECTED en block info."
    echo "$INFO"
    exit 2
fi
OVERLAY_SOURCE=$(awk '$2 == "/overlay" {print $1; exit}' /proc/mounts)
if [ "$OVERLAY_SOURCE" = "$FOUND_DEVICE" ]; then
    echo '[ERROR] El dispositivo ya está activo como /overlay; no se modificará fstab durante esta recuperación.'
    exit 3
fi
MOUNTED_AT=$(awk -v dev="$FOUND_DEVICE" '$1 == dev {print $2; exit}' /proc/mounts)
if [ -n "$MOUNTED_AT" ]; then
    echo "[ERROR] La USB sigue montada en $MOUNTED_AT. Desmóntala antes de corregir fstab."
    exit 4
fi
MNT=/tmp/extroot-recover-verify
mkdir -p "$MNT"
if ! mount -t ext4 -o ro,noload "$FOUND_DEVICE" "$MNT"; then
    rmdir "$MNT" 2>/dev/null || true
    echo '[ERROR] No se pudo montar la USB reparada en solo lectura.'
    exit 5
fi
if [ ! -d "$MNT/upper" ] || [ ! -d "$MNT/work" ]; then
    umount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
    echo '[ERROR] Faltan upper/ o work/; no se modificó fstab.'
    exit 6
fi
umount "$MNT"
rmdir "$MNT"

uci -q set fstab.@global[0].auto_mount=1 || true
uci -q set fstab.@global[0].delay_root=15 || true
uci set fstab.extroot=mount
uci set fstab.extroot.target=/overlay
uci set fstab.extroot.fstype=ext4
uci set fstab.extroot.enabled=1
uci set fstab.extroot.enabled_fsck=0
uci -q delete fstab.extroot.device 2>/dev/null || true
uci set fstab.extroot.uuid="$UUID_EXPECTED"
uci commit fstab
echo '=== fstab.extroot actualizado ==='
uci show fstab.extroot
echo '[OK] No se copiaron ni borraron archivos y no se reinició el router.'
echo '[NEXT] Revisa la configuración y reinicia manualmente cuando estés listo.'
REMOTE
