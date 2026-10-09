#!/usr/bin/env bash
# Write the extroot filesystem image onto an existing USB partition.
set -euo pipefail

IMAGE=""
DEVICE=""
YES=false

usage() {
    cat <<'HELP'
Uso:
  write-extroot-usb.sh --image <archivo.ext4.img> --device /dev/sdX1 [--yes]

Escribe destructivamente la imagen ext4 extroot sobre una partición USB ya
creada. La partición destino debe tener al menos 512 MiB.
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --image) IMAGE="${2:?--image requiere argumento}"; shift 2 ;;
        --device) DEVICE="${2:?--device requiere argumento}"; shift 2 ;;
        --yes) YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Argumento desconocido: $1" >&2; usage; exit 1 ;;
    esac
done

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "[ERROR] Falta dependencia local: $1" >&2
        exit 1
    }
}

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "[ERROR] Esta tarea requiere Linux." >&2
    exit 1
fi

for tool in lsblk findmnt sudo blockdev tune2fs sha256sum dd sync stat sed; do require "$tool"; done

if [[ -z "${IMAGE}" || ! -f "${IMAGE}" ]]; then
    echo "[ERROR] Especifica una imagen extroot existente con --image." >&2
    exit 1
fi
if [[ -z "${DEVICE}" || ! -b "${DEVICE}" || ! "${DEVICE}" =~ ^/dev/sd[a-z][0-9]+$ ]]; then
    echo "[ERROR] Usa una partición USB tipo /dev/sdX1 con --device." >&2
    lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL
    exit 1
fi

PARENT_NAME="$(lsblk -no PKNAME "${DEVICE}" | head -1)"
if [[ -z "${PARENT_NAME}" ]]; then
    echo "[ERROR] No se pudo encontrar el disco padre de ${DEVICE}." >&2
    exit 1
fi
PARENT="/dev/${PARENT_NAME}"
TRANSPORT="$(lsblk -no TRAN "${PARENT}" | head -1)"
if [[ "${TRANSPORT}" != "usb" ]]; then
    echo "[ERROR] El disco padre ${PARENT} no se identifica como USB (TRAN=${TRANSPORT:-vacío})." >&2
    exit 1
fi
if findmnt -rn --source "${DEVICE}" >/dev/null 2>&1; then
    echo "[ERROR] Desmonta ${DEVICE} antes de sobrescribirla." >&2
    exit 1
fi

MANIFEST="$(dirname "${IMAGE}")/extroot-image.manifest"
if [[ ! -f "${MANIFEST}" ]]; then
    echo "[ERROR] Falta extroot-image.manifest junto a la imagen." >&2
    exit 1
fi
EXPECTED_UUID="$(sed -n 's/^uuid=//p' "${MANIFEST}" | head -1)"
MANIFEST_IMAGE="$(sed -n 's/^image=//p' "${MANIFEST}" | head -1)"
IMAGE_UUID="$(tune2fs -l "${IMAGE}" 2>/dev/null | sed -n 's/^Filesystem UUID:[[:space:]]*//p' | head -1)"
IMAGE_SIZE="$(stat -c '%s' "${IMAGE}")"
DEVICE_SIZE="$(sudo blockdev --getsize64 "${DEVICE}")"

if [[ "$(basename "${IMAGE}")" != "${MANIFEST_IMAGE}" || "${IMAGE_UUID}" != "${EXPECTED_UUID}" ]]; then
    echo "[ERROR] La imagen no coincide con el manifiesto de UUID ${EXPECTED_UUID:-ausente}." >&2
    exit 1
fi
if [[ "${IMAGE_SIZE}" -ne $((512 * 1024 * 1024)) || "${DEVICE_SIZE}" -lt "${IMAGE_SIZE}" ]]; then
    echo "[ERROR] La partición debe tener al menos 512 MiB y la imagen debe ser exactamente 512 MiB." >&2
    exit 1
fi

if [[ -f "$(dirname "${IMAGE}")/sha256sums" ]]; then
    (cd "$(dirname "${IMAGE}")" && sha256sum -c --quiet sha256sums) || {
        echo "[ERROR] Falló la verificación de checksum de los artefactos." >&2
        exit 1
    }
fi

echo "==============================================="
echo " Escribir imagen extroot en USB"
echo "==============================================="
echo "Imagen:      ${IMAGE}"
echo "UUID:        ${EXPECTED_UUID}"
echo "Dispositivo: ${DEVICE}"
echo "Disco padre: ${PARENT}"
lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,TRAN,MODEL "${PARENT}"
echo ""

if [[ "${YES}" != true ]]; then
    echo "Esto SOBRESCRIBE todo el contenido de ${DEVICE}."
    read -r -p "Escribe exactamente 'ESCRIBIR ${DEVICE}' para continuar: " confirm
    [[ "${confirm}" == "ESCRIBIR ${DEVICE}" ]] || { echo "Cancelado."; exit 0; }
fi

sudo dd if="${IMAGE}" of="${DEVICE}" bs=4M conv=fsync status=progress
sync

WRITTEN_UUID="$(sudo tune2fs -l "${DEVICE}" 2>/dev/null | sed -n 's/^Filesystem UUID:[[:space:]]*//p' | head -1)"
if [[ "${WRITTEN_UUID}" != "${EXPECTED_UUID}" ]]; then
    echo "[ERROR] UUID tras escritura (${WRITTEN_UUID:-ausente}) distinto al esperado." >&2
    exit 1
fi
echo "[OK] Imagen extroot escrita y UUID verificado: ${WRITTEN_UUID}"
