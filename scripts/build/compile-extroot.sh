#!/usr/bin/env bash
# Build a small flash image paired with a pre-populated extroot filesystem.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

if [[ $# -ne 6 ]]; then
    echo "Usage: $0 <builder> <firmware-packages> <extroot-packages> <profile> <overlay> <artifact-dir>" >&2
    exit 2
fi

BUILDER="$1"
FIRMWARE_PACKAGES="$2"
EXTROOT_PACKAGES="$3"
PROFILE="$4"
OVERLAY="$5"
ARTIFACT_DIR="$6"
EXTROOT_UUID="${EXTROOT_UUID:-}"
EXTROOT_SIZE_MIB=512
EXTROOT_ROOT_DIR="${EXTROOT_ROOT_DIR:-${PROJECT_ROOT}/openwrt-builder/extroot-stage-root}"

if [[ ! "${EXTROOT_UUID}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    log_error "EXTROOT_UUID must be a valid UUID. Generate it with python3 -c 'import uuid; print(uuid.uuid4())'."
    exit 2
fi

for tool in mke2fs tune2fs e2fsck debugfs truncate cp mktemp sha256sum; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        log_error "Required host tool not found: ${tool}"
        exit 1
    fi
done
FAKEROOT="${BUILDER}/staging_dir/host/bin/fakeroot"
if [[ ! -x "${FAKEROOT}" ]]; then
    log_error "Image Builder fakeroot tool not found: ${FAKEROOT}"
    exit 1
fi

[[ -d "${BUILDER}" ]] || { log_error "Image Builder not found: ${BUILDER}"; exit 1; }
if [[ ! -d "${OVERLAY}" ]]; then
    log_error "Generated extroot overlay not found: ${OVERLAY}"
    exit 1
fi
if ! grep -Fq "option uuid '${EXTROOT_UUID}'" "${OVERLAY}/etc/config/fstab"; then
    log_error "Generated fstab does not reference EXTROOT_UUID ${EXTROOT_UUID}; regenerate the extroot config with that UUID."
    exit 1
fi
if [[ ! -d "${EXTROOT_ROOT_DIR}/upper" || ! -d "${EXTROOT_ROOT_DIR}/work" ]]; then
    log_error "Extroot package root has not been staged at ${EXTROOT_ROOT_DIR}; run the just build recipe."
    exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openwrt-extroot-build.XXXXXX")"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

ROOT_PAYLOAD="${WORK_DIR}/root-payload"
mkdir -p "${ROOT_PAYLOAD}"
cp -a "${EXTROOT_ROOT_DIR}/." "${ROOT_PAYLOAD}/"

log_step "Building the ${EXTROOT_SIZE_MIB} MiB ext4 extroot image..."
mkdir -p "${ARTIFACT_DIR}"
local_image="${ARTIFACT_DIR}/openwrt-${PROFILE}-extroot.ext4.img"

# Build the paired flash image after preserving the full extroot package tree.
"${SCRIPT_DIR}/compile.sh" "${BUILDER}" "${FIRMWARE_PACKAGES}" \
    "${PROFILE}" "${OVERLAY}" "${ARTIFACT_DIR}"

# compile.sh clears and repopulates the artifact directory; create the USB
# artifact afterward and checksum both firmware and extroot files together.
truncate -s "$((EXTROOT_SIZE_MIB * 1024 * 1024))" "${local_image}"
"${FAKEROOT}" sh -c '
    chown -hR 0:0 "$1"
    exec mke2fs -q -t ext4 -F -m 0 -U "$2" -d "$1" "$3" "$4"
' _ "${ROOT_PAYLOAD}" "${EXTROOT_UUID}" "${local_image}" "${EXTROOT_SIZE_MIB}M"
cat > "${ARTIFACT_DIR}/extroot-image.manifest" <<EOF
profile=${PROFILE}
uuid=${EXTROOT_UUID}
filesystem=ext4
size_mib=${EXTROOT_SIZE_MIB}
image=$(basename "${local_image}")
fstab_uuid=${EXTROOT_UUID}
firmware_packages=${FIRMWARE_PACKAGES}
extroot_packages=${EXTROOT_PACKAGES}
EOF
(cd "${ARTIFACT_DIR}" && sha256sum ./*.bin ./*.img > sha256sums)

log_info "Paired extroot artifacts written to ${ARTIFACT_DIR}"
log_info "USB image UUID: ${EXTROOT_UUID}"
