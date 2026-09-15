#!/usr/bin/env bash
# ============================================================================
# setup-captive-agent.sh — Llave SSH restringida para el router-agent HTTP
#
# Aprovisiona en el router una SEGUNDA llave SSH (independiente de la llave
# admin que usa setup-auth.sh), restringida vía forced-command de Dropbear a
# solo poder ejecutar allow/block/list/status sobre el set nftables
# "allowed_clients" del portal cautivo (ver scripts/router/setup-captive.sh).
#
# Esta llave es la que usa router-agent/{go,rust} para exponer una API HTTP
# angosta a un backend externo (p.ej. un portal cautivo con lógica de negocio
# propia) SIN darle nunca acceso root completo al router.
#
# Prerrequisito: el portal cautivo debe estar instalado
#   (just router-captive-setup) — este script no crea la tabla nftables,
#   solo añade una puerta de entrada adicional, más angosta, para operarla.
#
# Subcomandos:
#   install     Genera la llave, la instala en el router, la guarda en secrets
#   rotate-key  Genera una llave nueva, la instala junto a la vieja, prueba,
#               y solo entonces retira la vieja (evita bloquearse)
#   uninstall   Retira la llave y el dispatcher del router
#   status      Verifica el estado de la instalación
#
# Uso:
#   setup-captive-agent.sh install    [--ip <IP>] [--env <env>]
#   setup-captive-agent.sh rotate-key [--ip <IP>] [--env <env>]
#   setup-captive-agent.sh uninstall  [--ip <IP>] [--env <env>]
#   setup-captive-agent.sh status     [--ip <IP>] [--env <env>]
# ============================================================================
set -euo pipefail
ROUTER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROUTER_SCRIPT_DIR}/../commons/router-base.sh"
source "${ROUTER_SCRIPT_DIR}/../commons/secrets.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly CAPTIVE_DIR="/etc/captive"
readonly DISPATCH_REMOTE_PATH="${CAPTIVE_DIR}/agent-dispatch.sh"
readonly DISPATCH_LOCAL_SRC="${REPO_ROOT}/router-agent/shared/router-dispatch/agent-dispatch.sh"
readonly AUTHKEYS="/etc/dropbear/authorized_keys"
readonly SECRET_KEY_NAME="CAPTIVE_AGENT_SSH_PRIVATE_KEY"
readonly AGE_KEYFILE="${HOME}/.age/poc-openwrt-privkey.txt"

_SUBCMD=""
ROUTER_ENV="prod"
_ROUTER_IP_CLI=""

_show_help() {
    cat << 'HELP'
Uso: setup-captive-agent.sh <subcomando> [opciones]

Subcomandos:
  install       Genera y aprovisiona la llave SSH restringida del agente
  rotate-key    Rota la llave sin ventana de bloqueo
  uninstall     Retira la llave restringida y el dispatcher del router
  status        Verifica el estado de la instalación

Opciones:
  --ip <IP>     IP del router (default: de .env.public o 192.168.1.1)
  --env <env>   Entorno (default: prod)

Prerrequisito: portal cautivo instalado (just router-captive-setup).
HELP
}

if [[ $# -eq 0 ]]; then
    _show_help
    exit 1
fi

case "$1" in
    install|rotate-key|uninstall|status) _SUBCMD="$1"; shift ;;
    -h|--help) _show_help; exit 0 ;;
    *) log_error "Subcomando desconocido: $1"; echo "   Usa: $0 --help"; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)  _ROUTER_IP_CLI="${2:?--ip requiere argumento}"; shift 2 ;;
        --env) ROUTER_ENV="${2:?--env requiere argumento}"; shift 2 ;;
        -h|--help) _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
    esac
done

router_load_env "${ROUTER_ENV}"
[ -n "${_ROUTER_IP_CLI}" ] && ROUTER_IP="${_ROUTER_IP_CLI}"

SECRETS_FILE="${REPO_ROOT}/environments/${ROUTER_ENV}/secrets.enc.yaml"
PUBKEY_FILE="${REPO_ROOT}/environments/${ROUTER_ENV}/captive-agent-key.pub"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extrae "tipo base64" (sin comentario) de un archivo .pub — es lo único que
# necesitamos para identificar/deduplicar la línea en authorized_keys, y es
# seguro embeberlo en comandos remotos entre comillas simples: el alfabeto
# base64 (A-Za-z0-9+/=) nunca rompe un `'...'` de shell.
_pubkey_blob_from_file() {
    awk '{print $1" "$2}' "$1"
}

_json_string_from_file() {
    python3 -c "import json,sys; print(json.dumps(open(sys.argv[1]).read()))" "$1"
}

# Genera un keypair ed25519 nuevo en un directorio temporal.
# Deja las rutas en las variables globales _NEW_PRIV / _NEW_PUB.
_generate_keypair() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    chmod 700 "${tmpdir}"
    ssh-keygen -q -t ed25519 -N "" \
        -C "captive-agent@${ROUTER_ENV}" \
        -f "${tmpdir}/captive-agent-key" > /dev/null
    _NEW_PRIV="${tmpdir}/captive-agent-key"
    _NEW_PUB="${tmpdir}/captive-agent-key.pub"
}

_cleanup_keypair_dir() {
    [ -n "${_NEW_PRIV:-}" ] && rm -rf "$(dirname "${_NEW_PRIV}")"
}

# Sube el dispatcher al router y lo hace ejecutable.
_upload_dispatch_script() {
    log_step "Subiendo dispatcher (${DISPATCH_REMOTE_PATH})..."
    router_ssh "mkdir -p ${CAPTIVE_DIR}"
    router_ssh "cat > ${DISPATCH_REMOTE_PATH} && chmod +x ${DISPATCH_REMOTE_PATH}" < "${DISPATCH_LOCAL_SRC}"
    log_info "   ✅ Dispatcher instalado"
}

# Añade (con dedup) una línea de authorized_keys con forced-command para el
# pubkey dado. No toca ninguna otra línea (en particular, no la llave admin).
_install_authorized_keys_line() {
    local pub_file="$1"
    local blob pub_content full_line
    blob="$(_pubkey_blob_from_file "${pub_file}")"
    pub_content="$(cat "${pub_file}")"
    full_line="command=\"${DISPATCH_REMOTE_PATH}\",no-pty,no-agent-forwarding,no-X11-forwarding,no-port-forwarding ${pub_content}"

    router_ssh "mkdir -p /etc/dropbear && chmod 700 /etc/dropbear && touch ${AUTHKEYS} && chmod 600 ${AUTHKEYS}"

    if router_ssh "grep -qF '${blob}' ${AUTHKEYS} 2>/dev/null"; then
        log_warn "   Llave ya presente en ${AUTHKEYS} — sin cambios"
    else
        printf '%s\n' "${full_line}" | router_ssh "cat >> ${AUTHKEYS} && sort -u -o ${AUTHKEYS} ${AUTHKEYS} && chmod 600 ${AUTHKEYS} && /etc/init.d/dropbear restart >/dev/null 2>&1 || true"
        log_info "   ✅ Línea forced-command añadida a ${AUTHKEYS}"
    fi
}

# Retira la línea de authorized_keys que contiene el pubkey dado.
_remove_authorized_keys_line() {
    local pub_file="$1"
    local blob
    blob="$(_pubkey_blob_from_file "${pub_file}")"
    router_ssh "grep -vF '${blob}' ${AUTHKEYS} > /tmp/authorized_keys.new 2>/dev/null; mv /tmp/authorized_keys.new ${AUTHKEYS}; chmod 600 ${AUTHKEYS}; /etc/init.d/dropbear restart >/dev/null 2>&1 || true"
}

# Self-test: prueba que Dropbear REALMENTE fuerza el comando (no confía en
# que la opción `command=` esté soportada — lo verifica en runtime contra
# este firmware concreto).
#
#   1) Un comando no permitido ("id") NO debe devolver salida de shell real
#      (nunca debe contener "uid=") y debe fallar con exit 2 y "ERR unknown command".
#   2) El subcomando "status" (permitido) debe responder con la salida
#      estructurada del dispatcher, sea que el portal esté instalado o no.
_self_test() {
    local priv_key="$1"
    local opts=()
    # shellcheck disable=SC2046
    read -r -a opts <<< "$(_router_ssh_opts)"

    local disallowed_out disallowed_rc
    disallowed_out=$(ssh -i "${priv_key}" -o IdentitiesOnly=yes -o BatchMode=yes "${opts[@]}" "root@${ROUTER_IP}" "id" 2>&1) && disallowed_rc=0 || disallowed_rc=$?

    if echo "${disallowed_out}" | grep -q "uid="; then
        log_error "   ❌ Self-test FALLÓ: 'id' devolvió salida de shell real — el forced-command NO está aplicándose."
        return 1
    fi
    if [ "${disallowed_rc}" -ne 2 ] || ! echo "${disallowed_out}" | grep -q "ERR unknown command"; then
        log_error "   ❌ Self-test FALLÓ: respuesta inesperada a comando no permitido: '${disallowed_out}' (rc=${disallowed_rc})"
        return 1
    fi
    log_info "   ✅ Comando no permitido correctamente bloqueado (forced-command activo)"

    local status_out status_rc
    status_out=$(ssh -i "${priv_key}" -o IdentitiesOnly=yes -o BatchMode=yes "${opts[@]}" "root@${ROUTER_IP}" "status" 2>&1) && status_rc=0 || status_rc=$?

    if echo "${status_out}" | grep -q "OK table="; then
        log_info "   ✅ Dispatcher operativo — tabla nftables del portal presente"
    elif echo "${status_out}" | grep -q "ERR table missing"; then
        log_warn "   ⚠️  Dispatcher operativo, pero la tabla nftables del portal no existe aún"
        log_warn "      Instala el portal cautivo con: just router-captive-setup"
    else
        log_error "   ❌ Self-test FALLÓ: respuesta inesperada a 'status': '${status_out}' (rc=${status_rc})"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Subcomando: install
# ---------------------------------------------------------------------------
_install() {
    echo ""
    echo "============================================="
    echo " Router Agent — Llave SSH restringida"
    echo "============================================="
    echo "   Router: root@${ROUTER_IP}:${SSH_PORT}"
    echo "   Env:    ${ROUTER_ENV}"
    echo ""

    if [ -f "${PUBKEY_FILE}" ]; then
        log_error "Ya existe ${PUBKEY_FILE}"
        echo "   Usa 'rotate-key' para reemplazarla o 'uninstall' antes de reinstalar."
        exit 1
    fi

    check_sops_binary || exit 1
    if [ ! -f "${AGE_KEYFILE}" ]; then
        log_error "Clave age no encontrada: ${AGE_KEYFILE}"
        echo "   Solución: just generate-age-key"
        exit 1
    fi
    if [ ! -f "${SECRETS_FILE}" ]; then
        log_error "Archivo de secrets no encontrado: ${SECRETS_FILE}"
        echo "   Solución: just create-environments"
        exit 1
    fi
    export SOPS_AGE_KEY_FILE="${AGE_KEYFILE}"

    router_check_ssh

    log_step "[1/5] Generando keypair ed25519 local..."
    _generate_keypair
    trap _cleanup_keypair_dir EXIT
    log_info "   ✅ Keypair generado (temporal)"

    _upload_dispatch_script

    log_step "[3/5] Instalando llave restringida en authorized_keys..."
    _install_authorized_keys_line "${_NEW_PUB}"

    log_step "[4/5] Verificando que Dropbear aplica el forced-command..."
    if ! _self_test "${_NEW_PRIV}"; then
        log_error "Self-test falló — revirtiendo instalación de la llave."
        _remove_authorized_keys_line "${_NEW_PUB}"
        exit 1
    fi

    log_step "[5/5] Guardando llave privada en secrets (sops) y llave pública en el repo..."
    sops set "${SECRETS_FILE}" "[\"${SECRET_KEY_NAME}\"]" "$(_json_string_from_file "${_NEW_PRIV}")"
    cp "${_NEW_PUB}" "${PUBKEY_FILE}"
    log_info "   ✅ ${SECRET_KEY_NAME} guardada en ${SECRETS_FILE}"
    log_info "   ✅ Llave pública commiteable en ${PUBKEY_FILE}"

    echo ""
    log_info "✅ router-agent aprovisionado."
    echo ""
    echo "   Próximos pasos:"
    echo "   just router-agent-build-go     # o -rust"
    echo "   just router-agent-run-go       # levanta el contenedor localmente"
    echo ""
}

# ---------------------------------------------------------------------------
# Subcomando: rotate-key
# ---------------------------------------------------------------------------
_rotate_key() {
    echo ""
    echo "============================================="
    echo " Router Agent — Rotación de llave"
    echo "============================================="
    echo ""

    if [ ! -f "${PUBKEY_FILE}" ]; then
        log_error "No hay llave instalada (${PUBKEY_FILE} no existe)."
        echo "   Usa 'install' primero."
        exit 1
    fi

    check_sops_binary || exit 1
    export SOPS_AGE_KEY_FILE="${AGE_KEYFILE}"

    router_check_ssh

    local old_pub_file
    old_pub_file="$(mktemp)"
    cp "${PUBKEY_FILE}" "${old_pub_file}"

    log_step "[1/4] Generando keypair nuevo..."
    _generate_keypair
    trap '_cleanup_keypair_dir; rm -f "${old_pub_file}"' EXIT

    _upload_dispatch_script

    log_step "[2/4] Instalando llave nueva (junto a la anterior)..."
    _install_authorized_keys_line "${_NEW_PUB}"

    log_step "[3/4] Verificando llave nueva antes de retirar la anterior..."
    if ! _self_test "${_NEW_PRIV}"; then
        log_error "Self-test de la llave nueva falló — la llave anterior sigue activa, sin cambios."
        _remove_authorized_keys_line "${_NEW_PUB}"
        exit 1
    fi

    log_step "[4/4] Retirando llave anterior y actualizando secrets..."
    _remove_authorized_keys_line "${old_pub_file}"
    sops set "${SECRETS_FILE}" "[\"${SECRET_KEY_NAME}\"]" "$(_json_string_from_file "${_NEW_PRIV}")"
    cp "${_NEW_PUB}" "${PUBKEY_FILE}"

    echo ""
    log_info "✅ Llave rotada. Reconstruye/reinicia el contenedor del agente con la nueva llave."
    echo ""
}

# ---------------------------------------------------------------------------
# Subcomando: uninstall
# ---------------------------------------------------------------------------
_uninstall() {
    echo ""
    echo "============================================="
    echo " Router Agent — Desinstalación"
    echo "============================================="
    echo ""

    if [ ! -f "${PUBKEY_FILE}" ]; then
        log_warn "No hay llave instalada (${PUBKEY_FILE} no existe). Nada que hacer."
        exit 0
    fi

    router_check_ssh

    log_step "[1/3] Retirando llave de authorized_keys..."
    _remove_authorized_keys_line "${PUBKEY_FILE}"
    log_info "   ✅ Línea retirada"

    log_step "[2/3] Eliminando dispatcher del router..."
    router_ssh "rm -f ${DISPATCH_REMOTE_PATH}"
    log_info "   ✅ ${DISPATCH_REMOTE_PATH} eliminado"

    log_step "[3/3] Limpiando llave local y secret..."
    rm -f "${PUBKEY_FILE}"
    if [ -f "${SECRETS_FILE}" ] && [ -f "${AGE_KEYFILE}" ]; then
        export SOPS_AGE_KEY_FILE="${AGE_KEYFILE}"
        sops set "${SECRETS_FILE}" "[\"${SECRET_KEY_NAME}\"]" '""' 2>/dev/null || \
            log_warn "   No se pudo limpiar ${SECRET_KEY_NAME} en secrets (hazlo manualmente con: just edit-secrets ${ROUTER_ENV})"
    fi
    log_info "   ✅ ${PUBKEY_FILE} eliminado"

    echo ""
    log_info "✅ router-agent desinstalado. La tabla nftables del portal cautivo NO fue modificada."
    echo ""
}

# ---------------------------------------------------------------------------
# Subcomando: status
# ---------------------------------------------------------------------------
_status() {
    router_check_ssh

    echo ""
    echo "============================================="
    echo " Router Agent — Estado"
    echo "============================================="
    echo ""

    if [ ! -f "${PUBKEY_FILE}" ]; then
        log_warn "No hay llave instalada (${PUBKEY_FILE} no existe)."
        exit 0
    fi

    local blob
    blob="$(_pubkey_blob_from_file "${PUBKEY_FILE}")"

    if router_ssh "grep -qF '${blob}' ${AUTHKEYS} 2>/dev/null"; then
        log_info "✅ Llave presente en ${AUTHKEYS}"
    else
        log_warn "⚠️  Llave pública local existe pero NO está en ${AUTHKEYS} del router"
    fi

    if router_ssh "[ -x ${DISPATCH_REMOTE_PATH} ]"; then
        log_info "✅ Dispatcher presente y ejecutable (${DISPATCH_REMOTE_PATH})"
    else
        log_warn "⚠️  Dispatcher ausente o no ejecutable"
    fi

    if router_ssh "nft list table ip captive >/dev/null 2>&1"; then
        log_info "✅ Tabla nftables 'ip captive' presente"
    else
        log_warn "⚠️  Tabla nftables 'ip captive' ausente — instala el portal: just router-captive-setup"
    fi

    if [ -f "${SECRETS_FILE}" ] && [ -f "${AGE_KEYFILE}" ]; then
        export SOPS_AGE_KEY_FILE="${AGE_KEYFILE}"
        local secrets_tmp priv_content
        if secrets_tmp=$(decrypt_secrets "${ROUTER_ENV}" "${AGE_KEYFILE}" 2>/dev/null); then
            priv_content=$(get_secret_value "${SECRET_KEY_NAME}" "${secrets_tmp}")
            cleanup_secrets
            if [ -n "${priv_content}" ]; then
                local priv_tmp
                priv_tmp="$(mktemp)"
                printf '%s' "${priv_content}" > "${priv_tmp}"
                chmod 600 "${priv_tmp}"
                echo ""
                log_step "Probando extremo a extremo con la llave restringida..."
                if _self_test "${priv_tmp}"; then
                    log_info "✅ Llave restringida funcional de punta a punta"
                fi
                rm -f "${priv_tmp}"
            else
                log_warn "⚠️  ${SECRET_KEY_NAME} vacía en secrets — corre 'install' de nuevo"
            fi
        fi
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    case "${_SUBCMD}" in
        install)    _install ;;
        rotate-key) _rotate_key ;;
        uninstall)  _uninstall ;;
        status)     _status ;;
        *)
            log_error "Subcomando vacío. Usa: install | rotate-key | uninstall | status"
            exit 1
            ;;
    esac
}

main
