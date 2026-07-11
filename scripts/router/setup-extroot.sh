#!/usr/bin/env bash
# ============================================================================
# setup-extroot.sh — Configura USB como extroot en el router OpenWRT
#
# Flujo:
#   1. Detecta el dispositivo USB en el router (o usa --device)
#   2. Verifica que esté formateado como ext4 (sin e2fsprogs en router,
#      formatear previamente con: sudo mkfs.ext4 /dev/sdX en otra máquina)
#   3. Monta el USB en /mnt
#   4. Copia /overlay actual del router al USB (preservando atributos)
#   5. Configura /etc/config/fstab por UUID para automontaje como /overlay
#   6. Desmonta y reinicia el router
#
# Uso:
#   scripts/build/setup-extroot.sh [--ip <IP>] [--device <dev>] [--env <env>] [--no-reboot]
#
# Opciones:
#   --ip <IP>        IP del router (default: ROUTER_IP de .env.public o 192.168.1.1)
#   --device <dev>   Dispositivo USB en el router, ej: /dev/sda1 (default: auto-detectar)
#   --env <env>      Entorno para leer .env.public (default: prod)
#   --no-reboot      No reiniciar el router al final (para verificar antes)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
_ENV="prod"
_CLI_IP=""
_DEVICE=""
_NO_REBOOT=false

# ---------------------------------------------------------------------------
# Parsear argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)
            _CLI_IP="${2:?--ip requiere un argumento}"
            shift 2
            ;;
        --device)
            _DEVICE="${2:?--device requiere un argumento}"
            shift 2
            ;;
        --env)
            _ENV="${2:?--env requiere un argumento}"
            shift 2
            ;;
        --no-reboot)
            _NO_REBOOT=true
            shift
            ;;
        -h|--help)
            echo "Uso: $0 [--ip <IP>] [--device <dev>] [--env <env>] [--no-reboot]"
            echo ""
            echo "  --ip <IP>       IP del router (default: ROUTER_IP de .env.public o 192.168.1.1)"
            echo "  --device <dev>  Dispositivo USB en el router, ej: /dev/sda1 (auto-detectar)"
            echo "  --env           Entorno para leer .env.public (default: prod)"
            echo "  --no-reboot     No reiniciar el router al final"
            echo ""
            echo "  Prerrequisito: el USB debe estar formateado como ext4 antes de conectarlo."
            echo "  En otra máquina Linux: sudo mkfs.ext4 /dev/sdX"
            exit 0
            ;;
        *)
            log_error "Argumento desconocido: $1"
            echo "   Uso: $0 [--ip <IP>] [--device <dev>] [--env <env>] [--no-reboot]"
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Cargar variables del entorno
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a
fi

ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"

# ---------------------------------------------------------------------------
# Helper: ejecutar comando en el router via SSH
# ---------------------------------------------------------------------------
_ssh() {
    ssh -q -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

# ---------------------------------------------------------------------------
# Verificar conectividad SSH
# ---------------------------------------------------------------------------
_check_ssh() {
    log_step "Verificando conectividad SSH con el router..."
    if ! _ssh "exit" 2>/dev/null; then
        log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
        echo ""
        echo "   Verifica:"
        echo "   • El router está encendido y conectado por cable Ethernet"
        echo "   • La IP es correcta (usa --ip <IP>)"
        echo "   • SSH está habilitado en el router"
        exit 1
    fi
    log_info "✅ Conectado a root@${ROUTER_IP}"
}

# ---------------------------------------------------------------------------
# Detectar o validar dispositivo USB
# ---------------------------------------------------------------------------
_find_device() {
    if [ -n "${_DEVICE}" ]; then
        # Validar que el dispositivo exista en el router
        if ! _ssh "test -b '${_DEVICE}'" 2>/dev/null; then
            log_error "Dispositivo no encontrado en el router: ${_DEVICE}"
            echo "   Lista de dispositivos disponibles:"
            _ssh "block info 2>/dev/null || ls /dev/sd* /dev/mmcblk* 2>/dev/null || echo '   (ninguno detectado)'"
            exit 1
        fi
        echo "${_DEVICE}"
        return 0
    fi

    # Auto-detectar primer dispositivo USB (sda1, sdb1, etc.)
    local dev
    dev=$(_ssh "block info 2>/dev/null | grep -o '^/dev/sd[a-z][0-9]' | head -1" 2>/dev/null || true)

    if [ -z "${dev}" ]; then
        log_error "No se detectó ningún dispositivo USB en el router."
        echo ""
        echo "   Verifica:"
        echo "   • El USB está conectado al router"
        echo "   • El USB está formateado como ext4"
        echo "   • Usa --device /dev/sda1 si el auto-detect falla"
        echo ""
        echo "   Dispositivos visibles:"
        _ssh "ls /dev/sd* 2>/dev/null || echo '   (ninguno)'" || true
        exit 1
    fi

    echo "${dev}"
}

# ---------------------------------------------------------------------------
# Verificar que el dispositivo sea ext4
# ---------------------------------------------------------------------------
_check_ext4() {
    local device="$1"
    local fstype
    fstype=$(_ssh "block info '${device}' 2>/dev/null | grep -o 'TYPE=\"[^\"]*\"' | cut -d'\"' -f2" 2>/dev/null || true)

    if [ "${fstype}" != "ext4" ]; then
        log_error "El dispositivo ${device} no está formateado como ext4."
        echo "   Tipo detectado: ${fstype:-desconocido}"
        echo ""
        echo "   Conecta el USB a una máquina Linux y formatea:"
        echo "   sudo mkfs.ext4 ${device}"
        echo ""
        echo "   Nota: e2fsprogs no está disponible en el router (excluido por espacio)."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Verificar archivos existentes en USB (llamada SSH separada, retorna localmente)
# ---------------------------------------------------------------------------
_check_usb_files() {
    local device="$1"
    # Monta, lista, desmonta — todo en el router; salida capturada localmente
    _ssh sh - <<REMOTE
set -eu
DEVICE="${device}"

# Detectar si el dispositivo ya está montado (evita "Resource busy")
EXISTING_MNT=\$(grep "^\${DEVICE} " /proc/mounts 2>/dev/null | awk '{print \$2}' | head -1)
if [ -n "\${EXISTING_MNT}" ]; then
    MNT="\${EXISTING_MNT}"
    KEEP_MOUNTED=true
else
    MNT="/mnt/usb-extroot"
    KEEP_MOUNTED=false
    mkdir -p "\${MNT}"
    mount "\${DEVICE}" "\${MNT}"
fi

COUNT=\$(find "\${MNT}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
if [ "\${COUNT}" -gt 0 ]; then
    TOTAL=\$(find "\${MNT}" -mindepth 1 2>/dev/null | wc -l)
    echo "NOTEMPTY \${TOTAL}"
    find "\${MNT}" -mindepth 1 -maxdepth 2 2>/dev/null | head -20 | sed "s|^\${MNT}|  |"
else
    echo "EMPTY"
fi

if [ "\${KEEP_MOUNTED}" = "false" ]; then umount "\${MNT}"; fi
REMOTE
}

# ---------------------------------------------------------------------------
# Configurar extroot via SSH (limpieza y copia controladas por flag local)
# ---------------------------------------------------------------------------
_setup_extroot_on_router() {
    local device="$1"
    local do_clean="$2"   # "yes" o "no"

    _ssh sh - <<REMOTE
set -eu

DEVICE="${device}"
DO_CLEAN="${do_clean}"
MNT="/mnt/usb-extroot"

echo ""
echo "=== Configurando extroot en el router ==="
echo "    Dispositivo: \${DEVICE}"
echo ""

# 1. Montar USB (o usar mount point existente si ya está montado)
echo "[1/5] Montando \${DEVICE}..."
EXISTING_MNT=\$(grep "^\${DEVICE} " /proc/mounts 2>/dev/null | awk '{print \$2}' | head -1)
if [ -n "\${EXISTING_MNT}" ]; then
    MNT="\${EXISTING_MNT}"
    echo "      ℹ️  Ya montado en \${MNT}"
else
    mkdir -p "\${MNT}"
    mount "\${DEVICE}" "\${MNT}"
    echo "      ✅ Montado en \${MNT}"
fi

# 2. Limpiar si se confirmó localmente
if [ "\${DO_CLEAN}" = "yes" ]; then
    echo "[2/5] Limpiando archivos anteriores del USB..."
    if ! find "\${MNT}" -mindepth 1 -maxdepth 1 -exec rm -rf '{}' ';'; then
        echo "      ❌ No se pudo limpiar el USB."
        echo "      El sistema de archivos puede estar corrupto; desmontando."
        sync
        umount "\${MNT}" 2>/dev/null || true
        echo ""
        echo "      Repara o reformatea el USB en una máquina Linux:"
        echo "        sudo e2fsck -f \${DEVICE}"
        echo "        # o, si vas a borrar todo:"
        echo "        sudo mkfs.ext4 -F \${DEVICE}"
        exit 1
    fi

    REMAINING=\$(find "\${MNT}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    if [ "\${REMAINING}" -ne 0 ]; then
        echo "      ❌ La limpieza terminó, pero todavía quedan \${REMAINING} entrada(s)."
        echo "      Esto normalmente indica corrupción en el filesystem ext4 del USB."
        sync
        umount "\${MNT}" 2>/dev/null || true
        echo ""
        echo "      Repara o reformatea el USB fuera del router antes de continuar."
        exit 1
    fi
    echo "      ✅ USB limpiado"
else
    echo "[2/5] USB vacío — sin limpieza necesaria"
fi

# 3. Copiar overlay actual al USB (preservando atributos y permisos)
echo "[3/5] Copiando /overlay al USB..."
tar -C /overlay -czf - . | tar -C "\${MNT}" -xzf -
echo "      ✅ Overlay copiado"

# 4. Obtener UUID y configurar fstab
echo "[4/5] Configurando fstab para extroot..."
UUID=\$(block info "\${DEVICE}" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
# Configurar sección global del fstab
uci -q set fstab.@global[0].auto_mount=1 2>/dev/null || true
uci -q set fstab.@global[0].delay_root=15 2>/dev/null || true
uci -q set fstab.@global[0].check_fs=0 2>/dev/null || true
# Configurar mount de extroot
uci -q delete fstab.extroot 2>/dev/null || true
uci set fstab.extroot=mount
uci set fstab.extroot.target=/overlay
uci set fstab.extroot.fstype=ext4
uci set fstab.extroot.options='rw,sync'
uci set fstab.extroot.enabled=1
uci set fstab.extroot.enabled_fsck=0
if [ -n "\${UUID}" ]; then
    uci set fstab.extroot.uuid="\${UUID}"
    echo "      UUID: \${UUID}"
else
    uci set fstab.extroot.device="\${DEVICE}"
    echo "      ⚠️  Sin UUID — usando ruta del dispositivo"
fi
uci commit fstab
echo "      ✅ fstab configurado"

# 5. Verificar y desmontar
echo "[5/5] Configuración guardada:"
uci show fstab.extroot
umount "\${MNT}"
echo ""
echo "✅ Extroot configurado correctamente"
REMOTE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "==============================================="
    echo " OpenWRT Extroot Setup"
    echo "==============================================="
    echo ""
    echo "   Prerrequisito: el USB debe estar formateado como ext4."
    echo "   Si no lo está: sudo mkfs.ext4 /dev/sdX  (en otra máquina)"
    echo ""

    _check_ssh

    echo ""
    log_step "Buscando dispositivo USB..."
    local device
    device=$(_find_device)
    log_info "Dispositivo: ${device}"

    echo ""
    log_step "Verificando sistema de archivos..."
    _check_ext4 "${device}"
    log_info "✅ Formato ext4 confirmado"

    # Verificar contenido existente en el USB (SSH → resultado local)
    echo ""
    log_step "Verificando contenido existente en el USB..."
    local usb_info do_clean="no"
    usb_info=$(_check_usb_files "${device}")

    if echo "${usb_info}" | grep -q "^NOTEMPTY"; then
        local total
        total=$(echo "${usb_info}" | head -1 | awk '{print $2}')
        echo ""
        log_warn "El USB contiene archivos de una instalación anterior (${total} archivos):"
        echo "${usb_info}" | tail -n +2 | head -20 | sed 's/^/   /'
        [ "${total}" -gt 20 ] && echo "   ... (${total} en total)"
        echo ""
        read -r -p "   ¿Borrar todos los archivos del USB y continuar? (s/N) " answer
        answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
        if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
            echo "Cancelado."
            exit 0
        fi
        do_clean="yes"
    else
        log_info "USB vacío — sin archivos previos"
    fi

    echo ""
    log_step "Resumen:"
    echo "   Router:      root@${ROUTER_IP}:${SSH_PORT}"
    echo "   Dispositivo: ${device}"
    echo "   Limpiar USB: ${do_clean}"
    echo "   Acción:      Copiar /overlay → USB, configurar fstab, $([ "${_NO_REBOOT}" = true ] && echo "sin reinicio" || echo "reiniciar")"
    echo ""
    read -r -p "¿Continuar? (s/N) " answer
    answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
    if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi

    echo ""
    _setup_extroot_on_router "${device}" "${do_clean}"

    echo ""
    if [ "${_NO_REBOOT}" = true ]; then
        log_info "✅ Extroot configurado. Reinicia manualmente para activar:"
        echo "   ssh root@${ROUTER_IP} reboot"
    else
        log_step "Reiniciando el router para activar extroot..."
        _ssh "reboot" || true
        echo ""
        log_info "✅ Router reiniciando. Espera ~2 minutos y verifica:"
        echo "   ssh root@${ROUTER_IP} 'df -h /overlay'"
        echo ""
        echo "   Si /overlay muestra el tamaño del USB, extroot está activo."
    fi
}

main "$@"
