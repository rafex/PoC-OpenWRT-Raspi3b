#!/usr/bin/env bash
# ============================================================================
# setup-captive.sh — Portal cautivo via nftables + uhttpd (sin OpenNDS)
#
# Instala un portal cautivo completo en el router OpenWRT usando:
#   • nftables: intercepción de tráfico HTTP no autorizado (DNAT :80 → :8080)
#   • uhttpd:   servidor web mínimo que sirve el portal HTML + CGI de aceptación
#   • dnsmasq:  redirige dominios de detección de portal (Android, Apple, etc.)
#
# Modos:
#   local    (default) HTML y CGI viven en el router. El usuario acepta ahí.
#   externo  uhttpd redirige al portal externo. El portal externo devuelve
#            al cliente al CGI del router para que autorice su IP.
#
# Subcomandos:
#   install    Instala el portal cautivo
#   uninstall  Desinstala completamente
#   allow <IP> Autoriza una IP manualmente (con timeout)
#   block <IP> Revoca autorización de una IP
#   flush      Limpia todos los clientes autorizados
#   list       Muestra clientes autorizados, leases y conexiones activas
#   status     Diagnóstico de salud del portal
#
# Uso:
#   setup-captive.sh install [--ip <IP>] [--env <env>] [--timeout <min>]
#                            [--portal-url <URL>] [--token <secret>]
#   setup-captive.sh allow <IP> [--ip <IP>] [--env <env>] [--timeout <min>]
#   setup-captive.sh block <IP> [--ip <IP>] [--env <env>]
#   setup-captive.sh flush|list|status|uninstall [--ip <IP>] [--env <env>]
#
# Opciones:
#   --ip <IP>          IP del router (default: ROUTER_IP de .env.public)
#   --env <env>        Entorno (default: prod)
#   --timeout <min>    Minutos de sesión por cliente (default: 30)
#   --portal-url <URL> Portal externo: URL a la que el router redirige
#   --token <secret>   Token compartido con portal externo (auto-generado)
#   --iface <iface>    Interfaz LAN del router (default: auto-detectar)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# ---------------------------------------------------------------------------
# Constantes (en el router)
# ---------------------------------------------------------------------------
readonly NFT_TABLE="ip captive"
readonly NFT_SET="allowed_clients"
readonly CAPTIVE_PORT="8080"
readonly CAPTIVE_DIR="/etc/captive"
readonly CAPTIVE_WWW="${CAPTIVE_DIR}/www"
readonly CAPTIVE_NFT="${CAPTIVE_DIR}/captive.nft"
readonly CAPTIVE_CFG="${CAPTIVE_DIR}/config"
readonly CAPTIVE_INIT="/etc/init.d/captive"

# Dominios de detección de portal cautivo por fabricante/SO
# Fuente: análisis de tráfico de Android, iOS, Windows, Huawei, Samsung, Xiaomi, Firefox
readonly PROBE_DOMAINS="connectivitycheck.gstatic.com
clients3.google.com
clients1.google.com
captive.apple.com
www.apple.com
www.appleiphonecell.com
www.itools.info
www.ibook.info
www.airport.us
connectivitycheck.hicloud.com
connectivitycheck.platform.hicloud.com
connectivitycheck.samsung.com
connect.rom.miui.com
detectportal.firefox.com
detectportal.prod.mozaws.net
nmcheck.gnome.org
networkcheck.kde.org
network-test.debian.org
connectivity.ubuntu.com
www.msftconnecttest.com
msftncsi.com"

# ---------------------------------------------------------------------------
# Parsear subcomando y opciones
# ---------------------------------------------------------------------------
_SUBCMD=""
_SUBCMD_ARG=""
_ENV="prod"
_CLI_IP=""
_TIMEOUT=30
_PORTAL_URL=""
_TOKEN=""
_IFACE=""

_show_help() {
    cat << 'HELP'
Uso: setup-captive.sh <subcomando> [opciones]

Subcomandos:
  install              Instala el portal cautivo
  uninstall            Desinstala completamente
  allow <IP>           Autoriza una IP manualmente
  block <IP>           Revoca autorización de una IP
  flush                Limpia todos los clientes autorizados
  list                 Muestra clientes y estado del portal
  status               Diagnóstico de salud

Opciones:
  --ip <IP>            IP del router (default: de .env.public o 192.168.1.1)
  --env <dev|prod>     Entorno (default: prod)
  --timeout <min>      Minutos de sesión (default: 30)
  --portal-url <URL>   Modo externo: URL del portal externo
  --token <secret>     Token compartido con portal externo
  --iface <iface>      Interfaz LAN (default: auto-detectar)

Ejemplos:
  setup-captive.sh install
  setup-captive.sh install --timeout 60
  setup-captive.sh install --portal-url https://portal.example.com
  setup-captive.sh allow 192.168.1.50
  setup-captive.sh allow 192.168.1.50 --timeout 120
  setup-captive.sh list
HELP
}

if [[ $# -eq 0 ]]; then
    _show_help
    exit 1
fi

case "$1" in
    install|uninstall|flush|list|status) _SUBCMD="$1"; shift ;;
    allow|block)
        _SUBCMD="$1"; shift
        if [[ $# -gt 0 ]] && [[ "$1" != --* ]]; then
            _SUBCMD_ARG="$1"; shift
        fi
        ;;
    -h|--help) _show_help; exit 0 ;;
    *) log_error "Subcomando desconocido: $1"; echo "   Usa: $0 --help"; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         _CLI_IP="${2:?--ip requiere argumento}"; shift 2 ;;
        --env)        _ENV="${2:?--env requiere argumento}"; shift 2 ;;
        --timeout)    _TIMEOUT="${2:?--timeout requiere argumento}"; shift 2 ;;
        --portal-url) _PORTAL_URL="${2:?--portal-url requiere argumento}"; shift 2 ;;
        --token)      _TOKEN="${2:?--token requiere argumento}"; shift 2 ;;
        --iface)      _IFACE="${2:?--iface requiere argumento}"; shift 2 ;;
        -h|--help)    _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
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
_MODE="local"
[ -n "${_PORTAL_URL}" ] && _MODE="external"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_ssh() {
    ssh -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

_check_ssh() {
    if ! ssh -q -p "${SSH_PORT}" \
            -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new \
            -o BatchMode=yes \
            "root@${ROUTER_IP}" "exit" 2>/dev/null; then
        log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
    log_info "✅ Conectado a root@${ROUTER_IP}"
}

# Validación IP POSIX (adaptado de poc-openwrt-dietpi-raspi3b-raspi4b/scripts/lib/common.sh)
_validate_ip() {
    local ip="$1"
    case "${ip}" in *[!0-9.]*|'') return 1 ;; esac
    local IFS='.'
    # shellcheck disable=SC2086
    set -- ${ip}
    [ $# -eq 4 ] || return 1
    for octet in "$@"; do
        [ "${octet}" -ge 0 ] && [ "${octet}" -le 255 ] || return 1
    done
    return 0
}

# Obtiene IP LAN e interfaz del router
_router_lan_info() {
    _ssh sh - << 'REMOTE'
set -eu
LAN_IP=$(uci -q get network.lan.ipaddr 2>/dev/null || \
         ip -4 addr show br-lan 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}' | head -1 || \
         echo "192.168.1.1")
LAN_IFACE=$(uci -q get network.lan.device 2>/dev/null || \
            uci -q get network.lan.ifname 2>/dev/null || \
            echo "br-lan")
echo "LAN_IP=${LAN_IP}"
echo "LAN_IFACE=${LAN_IFACE}"
REMOTE
}

# ---------------------------------------------------------------------------
# Generadores de contenido (ejecutados localmente, subidos al router)
# ---------------------------------------------------------------------------

_gen_nft() {
    local lan_ip="$1"
    local lan_iface="$2"
    local timeout="${_TIMEOUT}m"

    cat << EOF
# Portal cautivo — nftables — generado por setup-captive.sh
# Router: ${lan_ip}  Iface: ${lan_iface}  Timeout: ${timeout}

table ip captive {
    set ${NFT_SET} {
        type ipv4_addr
        flags timeout
        timeout ${timeout}
    }

    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        # Clientes ya autorizados: sin interceptar
        ip saddr @${NFT_SET} accept
        # DNS y DHCP: siempre permitidos (sin DNAT)
        udp dport { 53, 67, 68 } accept
        # HTTP no autorizado → servidor de portal
        tcp dport 80 dnat to ${lan_ip}:${CAPTIVE_PORT}
    }

    chain forward {
        type filter hook forward priority filter - 1; policy accept;
        # Clientes autorizados: forward libre a internet
        ip saddr @${NFT_SET} accept
        # DNS: siempre (clientes no autorizados también pueden resolver)
        ip protocol udp udp dport 53 accept
        # Bloquear todo lo demás desde LAN sin autorización
        iifname "${lan_iface}" drop
    }
}
EOF
}

_gen_portal_html() {
    cat << EOF
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Portal de Acceso</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:#f0f4f8;min-height:100vh;
     display:flex;align-items:center;justify-content:center;padding:1rem}
.card{background:#fff;border-radius:16px;padding:2rem;max-width:400px;
      width:100%;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center}
h1{color:#1a202c;font-size:1.5rem;margin-bottom:.3rem}
.sub{color:#718096;font-size:.875rem;margin-bottom:1.5rem}
.mins{font-size:3.5rem;font-weight:700;color:#2b6cb0;line-height:1}
.mins-label{color:#a0aec0;font-size:.8rem;margin:.4rem 0 1.5rem}
.terms{font-size:.8rem;color:#718096;background:#f7fafc;border-radius:8px;
       padding:.75rem 1rem;text-align:left;margin-bottom:1.5rem;line-height:1.6}
button{background:#2b6cb0;color:#fff;border:none;padding:.9rem 2rem;
       border-radius:10px;font-size:1rem;font-weight:600;cursor:pointer;
       width:100%;transition:background .15s}
button:active{background:#2c5282}
.note{color:#cbd5e0;font-size:.75rem;margin-top:1.25rem}
</style>
</head>
<body>
<div class="card">
  <h1>Acceso a Internet</h1>
  <p class="sub">Red WiFi — Portal de acceso</p>
  <div class="mins">${_TIMEOUT}</div>
  <p class="mins-label">minutos de navegación</p>
  <div class="terms">
    Al pulsar <strong>Aceptar</strong> confirmas que usarás esta red de
    forma responsable. La sesión se cierra automáticamente al terminar
    el tiempo o al desconectarte.
  </div>
  <form action="/cgi-bin/accept" method="POST">
    <button type="submit">Aceptar y Navegar</button>
  </form>
  <p class="note">Sesión de ${_TIMEOUT} min · Reconecta para renovar</p>
</div>
</body>
</html>
EOF
}

_gen_redirect_html() {
    # Modo externo: redirige al portal externo pasando la URL de retorno
    local lan_ip="$1"
    local return_url="http://${lan_ip}:${CAPTIVE_PORT}/cgi-bin/accept"
    [ -n "${_TOKEN}" ] && return_url="${return_url}?token=${_TOKEN}"
    local portal_target="${_PORTAL_URL}?return=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${return_url}" 2>/dev/null || printf '%s' "${return_url}")"

    cat << EOF
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="0;url=${portal_target}">
<title>Redirigiendo...</title>
</head>
<body>
<script>window.location.replace("${portal_target}")</script>
<p>Redirigiendo al portal... <a href="${portal_target}">haz clic aquí</a></p>
</body>
</html>
EOF
}

_gen_connected_html() {
    cat << EOF
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Conectado</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,sans-serif;background:#f0fff4;min-height:100vh;
     display:flex;align-items:center;justify-content:center;padding:1rem}
.card{background:#fff;border-radius:16px;padding:2rem;max-width:360px;
      width:100%;box-shadow:0 4px 24px rgba(0,0,0,.08);text-align:center}
.icon{font-size:3rem;margin-bottom:1rem}
h1{color:#276749;font-size:1.5rem;margin-bottom:.5rem}
p{color:#718096;line-height:1.6}
.hi{color:#2b6cb0;font-weight:700}
.note{color:#a0aec0;font-size:.8rem;margin-top:1.25rem}
</style>
</head>
<body>
<div class="card">
  <div class="icon">&#10003;</div>
  <h1>¡Conectado!</h1>
  <p>Tu sesión está activa.<br>
     Tienes <span class="hi">${_TIMEOUT} minutos</span> de navegación.</p>
  <p class="note">Puedes cerrar esta ventana y navegar libremente.</p>
</div>
</body>
</html>
EOF
}

# CGI: autoriza la IP del cliente que hace la petición
_gen_cgi_accept() {
    # Usamos 'EOF' (comillas simples) para que bash NO expanda nada aquí —
    # el CGI corre en el router y usa sus propias variables de entorno CGI
    cat << 'EOF'
#!/bin/sh
# CGI: autoriza la IP del cliente en nftables
# Variables CGI: REMOTE_ADDR, QUERY_STRING, REQUEST_METHOD

. /etc/captive/config 2>/dev/null

CLIENT_IP="${REMOTE_ADDR:-}"
NFT_TABLE="ip captive"
NFT_SET="allowed_clients"
TIMEOUT="${CAPTIVE_TIMEOUT:-30m}"
TOKEN="${CAPTIVE_TOKEN:-}"
MODE="${CAPTIVE_MODE:-local}"

# Validar IP
case "${CLIENT_IP}" in
    ""|*[!0-9.]*)
        printf "Status: 400 Bad Request\r\nContent-Type: text/plain\r\n\r\nIP invalida\n"
        exit 0
        ;;
esac

# En modo externo: validar token
if [ "${MODE}" = "external" ] && [ -n "${TOKEN}" ]; then
    PARAM_TOKEN=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | grep '^token=' | cut -d= -f2 | head -1)
    if [ "${PARAM_TOKEN}" != "${TOKEN}" ]; then
        printf "Status: 403 Forbidden\r\nContent-Type: text/plain\r\n\r\nToken invalido\n"
        exit 0
    fi
fi

# Añadir IP al set de clientes autorizados (con timeout)
nft add element "${NFT_TABLE}" "${NFT_SET}" "{ ${CLIENT_IP} timeout ${TIMEOUT} }" 2>/dev/null || \
nft add element "${NFT_TABLE}" "${NFT_SET}" "{ ${CLIENT_IP} }" 2>/dev/null || true

# Redirigir a página de éxito
printf "Status: 302 Found\r\nLocation: /connected.html\r\nContent-Type: text/html\r\n\r\n"
EOF
}

# init.d: restaura nftables y arranca uhttpd en cada boot
_gen_initd() {
    cat << 'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

start_service() {
    # Restaurar tabla nftables del portal cautivo
    if [ -f /etc/captive/captive.nft ]; then
        nft -f /etc/captive/captive.nft 2>/dev/null || true
    fi

    # Arrancar uhttpd en puerto 8080 (document root: /etc/captive/www)
    procd_open_instance captive
    procd_set_param command /usr/sbin/uhttpd \
        -f \
        -h /etc/captive/www \
        -p 0.0.0.0:8080 \
        -x /cgi-bin \
        -t 30 \
        -T 30
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    nft delete table ip captive 2>/dev/null || true
}
EOF
}

# ---------------------------------------------------------------------------
# Subcomando: install
# ---------------------------------------------------------------------------
_install() {
    echo ""
    echo "============================================="
    echo " Portal Cautivo — Instalación"
    echo "============================================="
    echo "   Router:   root@${ROUTER_IP}:${SSH_PORT}"
    echo "   Timeout:  ${_TIMEOUT} minutos"
    echo "   Modo:     ${_MODE}"
    [ "${_MODE}" = "external" ] && echo "   Portal:   ${_PORTAL_URL}"
    echo ""

    _check_ssh

    # Detectar IP y interfaz LAN del router
    log_step "Detectando configuración LAN del router..."
    local router_info
    router_info=$(_router_lan_info)
    local LAN_IP LAN_IFACE
    eval "${router_info}"
    log_info "   LAN IP:    ${LAN_IP}"
    log_info "   Interfaz:  ${LAN_IFACE}"

    # Sobrescribir interfaz si se pasó --iface
    [ -n "${_IFACE}" ] && LAN_IFACE="${_IFACE}"

    # Verificar uhttpd
    log_step "Verificando uhttpd..."
    if ! _ssh "command -v uhttpd >/dev/null 2>&1"; then
        log_warn "uhttpd no encontrado — instalando via opkg..."
        _ssh "opkg update && opkg install uhttpd" || {
            log_error "No se pudo instalar uhttpd."
            echo "   Opciones:"
            echo "   1. Añadir 'uhttpd' al firmware: just build-prod y just update"
            echo "   2. Verificar conectividad a internet del router"
            exit 1
        }
    fi
    log_info "✅ uhttpd disponible"

    # Generar token si modo externo y no se proporcionó
    if [ "${_MODE}" = "external" ] && [ -z "${_TOKEN}" ]; then
        _TOKEN=$(head -c 16 /dev/urandom | od -A n -t x4 | tr -d ' \n')
        log_info "   Token generado: ${_TOKEN}"
        log_warn "   Configura este token en tu portal externo."
    fi

    echo ""
    read -r -p "¿Continuar instalación? (s/N) " answer
    answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
    if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi
    echo ""

    # Crear estructura de directorios en el router
    log_step "[1/6] Creando estructura en el router..."
    _ssh "mkdir -p ${CAPTIVE_WWW}/cgi-bin"
    log_info "      ✅ ${CAPTIVE_WWW}/cgi-bin"

    # Subir archivo de configuración
    log_step "[2/6] Subiendo configuración..."
    cat << EOF | _ssh "cat > ${CAPTIVE_CFG}"
CAPTIVE_TIMEOUT="${_TIMEOUT}m"
CAPTIVE_MODE="${_MODE}"
CAPTIVE_TOKEN="${_TOKEN}"
CAPTIVE_PORTAL_URL="${_PORTAL_URL}"
CAPTIVE_LAN_IP="${LAN_IP}"
CAPTIVE_PORT="${CAPTIVE_PORT}"
EOF
    log_info "      ✅ ${CAPTIVE_CFG}"

    # Subir reglas nftables
    log_step "[3/6] Subiendo reglas nftables..."
    _gen_nft "${LAN_IP}" "${LAN_IFACE}" | _ssh "cat > ${CAPTIVE_NFT}"
    _ssh "nft -f ${CAPTIVE_NFT}"
    log_info "      ✅ Tabla '${NFT_TABLE}' activa"

    # Subir archivos web
    log_step "[4/6] Subiendo portal web..."

    if [ "${_MODE}" = "local" ]; then
        _gen_portal_html | _ssh "cat > ${CAPTIVE_WWW}/index.html"
        log_info "      ✅ index.html (portal local)"
    else
        _gen_redirect_html "${LAN_IP}" | _ssh "cat > ${CAPTIVE_WWW}/index.html"
        log_info "      ✅ index.html (redirect → portal externo)"
    fi

    _gen_connected_html | _ssh "cat > ${CAPTIVE_WWW}/connected.html"
    log_info "      ✅ connected.html"

    _gen_cgi_accept | _ssh "cat > ${CAPTIVE_WWW}/cgi-bin/accept && chmod +x ${CAPTIVE_WWW}/cgi-bin/accept"
    log_info "      ✅ cgi-bin/accept (autorización de clientes)"

    # Subir y habilitar init.d
    log_step "[5/6] Configurando servicio de inicio..."
    _gen_initd | _ssh "cat > ${CAPTIVE_INIT} && chmod +x ${CAPTIVE_INIT}"
    _ssh "/etc/init.d/captive enable && /etc/init.d/captive start"
    log_info "      ✅ Servicio captive habilitado y arrancado"

    # Configurar dnsmasq: dominios de probe → IP del router
    log_step "[6/6] Configurando dnsmasq (dominios de detección)..."
    _configure_dnsmasq "${LAN_IP}"

    # Verificación rápida
    echo ""
    log_step "Verificando instalación..."
    _verify "${LAN_IP}"

    echo ""
    log_info "✅ Portal cautivo instalado."
    echo ""
    echo "   Prueba de funcionamiento:"
    echo "   • Conecta un dispositivo al WiFi"
    echo "   • Intenta abrir http://example.com"
    echo "   • Debe aparecer el portal en el navegador"
    echo ""
    echo "   Comandos útiles:"
    echo "   just captive-list    # ver clientes autorizados"
    echo "   just captive-status  # diagnóstico"
    if [ "${_MODE}" = "external" ] && [ -n "${_TOKEN}" ]; then
        echo ""
        echo "   Token para portal externo: ${_TOKEN}"
        echo "   URL de aceptación: http://${LAN_IP}:${CAPTIVE_PORT}/cgi-bin/accept?token=${_TOKEN}"
    fi
}

# Configura dnsmasq con los dominios de detección de portal cautivo
_configure_dnsmasq() {
    local lan_ip="$1"

    # Construir script UCI con todos los comandos en una sola sesión SSH
    local uci_script
    uci_script="set -eu

# Eliminar entradas anteriores del captive portal (que apunten a nuestra IP)
addresses=\$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
for e in \$addresses; do
    case \"\$e\" in */${lan_ip}) uci -q del_list dhcp.@dnsmasq[0].address=\"\$e\" 2>/dev/null || true ;; esac
done
# Eliminar option 252 anterior si existía
uci -q del_list dhcp.@dnsmasq[0].dhcp_option='252,http://${lan_ip}:${CAPTIVE_PORT}/' 2>/dev/null || true
"

    # Añadir un add_list por cada dominio
    while IFS= read -r domain; do
        [ -z "${domain}" ] && continue
        uci_script="${uci_script}
uci add_list dhcp.@dnsmasq[0].address='/${domain}/${lan_ip}'"
    done <<< "${PROBE_DOMAINS}"

    uci_script="${uci_script}
# RFC 8910: notifica la URL del portal directamente via DHCP option 252
uci add_list dhcp.@dnsmasq[0].dhcp_option='252,http://${lan_ip}:${CAPTIVE_PORT}/'
# Bloquear bypass via IPv6 (los SO usarían IPv6 para evadir el portal)
uci set dhcp.@dnsmasq[0].filter_aaaa=1
uci commit dhcp
/etc/init.d/dnsmasq reload
echo 'dnsmasq OK'"

    printf '%s\n' "${uci_script}" | _ssh sh -

    local domain_count
    domain_count=$(printf '%s\n' "${PROBE_DOMAINS}" | grep -c '[a-z]')
    log_info "      ✅ ${domain_count} dominios de detección + DHCP option 252"
}

# Verificación post-instalación
_verify() {
    local lan_ip="$1"
    local ok=true

    # Tabla nftables activa
    if _ssh "nft list table ${NFT_TABLE} >/dev/null 2>&1"; then
        log_info "   ✅ nftables: tabla '${NFT_TABLE}' activa"
    else
        log_warn "   ⚠️  nftables: tabla no encontrada"
        ok=false
    fi

    # uhttpd escuchando en CAPTIVE_PORT
    if _ssh "netstat -tlnp 2>/dev/null | grep -q ':${CAPTIVE_PORT}' || ss -tlnp 2>/dev/null | grep -q ':${CAPTIVE_PORT}'"; then
        log_info "   ✅ uhttpd: escuchando en :${CAPTIVE_PORT}"
    else
        log_warn "   ⚠️  uhttpd: no escucha en :${CAPTIVE_PORT}"
        ok=false
    fi

    # Respuesta HTTP del portal
    local http_code
    http_code=$(_ssh "curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://${lan_ip}:${CAPTIVE_PORT}/ 2>/dev/null || echo '000'")
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "302" ]; then
        log_info "   ✅ HTTP portal: responde (${http_code})"
    else
        log_warn "   ⚠️  HTTP portal: no responde (código ${http_code})"
        ok=false
    fi

    # Al menos un dominio de probe resuelve a nuestra IP
    local first_domain
    first_domain=$(printf '%s\n' "${PROBE_DOMAINS}" | head -1)
    local resolved
    resolved=$(_ssh "nslookup ${first_domain} 127.0.0.1 2>/dev/null | grep 'Address' | tail -1 | awk '{print \$2}'" 2>/dev/null || true)
    if [ "${resolved}" = "${lan_ip}" ]; then
        log_info "   ✅ DNS: ${first_domain} → ${lan_ip}"
    else
        log_warn "   ⚠️  DNS: ${first_domain} → '${resolved}' (esperado: ${lan_ip})"
        ok=false
    fi

    "${ok}" || log_warn "   Algunos componentes pueden necesitar unos segundos para iniciar."
}

# ---------------------------------------------------------------------------
# Subcomando: uninstall
# ---------------------------------------------------------------------------
_uninstall() {
    echo ""
    echo "============================================="
    echo " Portal Cautivo — Desinstalación"
    echo "============================================="
    echo ""

    _check_ssh

    log_step "Detectando IP LAN del router..."
    local router_info
    router_info=$(_router_lan_info)
    local LAN_IP LAN_IFACE
    eval "${router_info}"

    echo "   Router:  root@${ROUTER_IP}:${SSH_PORT}"
    echo "   LAN IP:  ${LAN_IP}"
    echo ""
    log_warn "Se eliminarán: nftables table, uhttpd captive, dnsmasq probe domains, /etc/captive/"
    echo ""
    read -r -p "¿Continuar? (s/N) " answer
    answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
    if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi
    echo ""

    # Detener y deshabilitar servicio
    log_step "[1/4] Deteniendo servicio captive..."
    _ssh "/etc/init.d/captive stop 2>/dev/null; /etc/init.d/captive disable 2>/dev/null; rm -f ${CAPTIVE_INIT}" || true
    log_info "      ✅ Servicio detenido"

    # Eliminar tabla nftables
    log_step "[2/4] Eliminando reglas nftables..."
    _ssh "nft delete table ${NFT_TABLE} 2>/dev/null || true"
    log_info "      ✅ Tabla eliminada"

    # Eliminar entradas dnsmasq
    log_step "[3/4] Limpiando dnsmasq..."
    local uci_clean
    uci_clean="set -eu
addresses=\$(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null || true)
for e in \$addresses; do
    case \"\$e\" in */${LAN_IP}) uci -q del_list dhcp.@dnsmasq[0].address=\"\$e\" 2>/dev/null || true ;; esac
done
uci -q del_list dhcp.@dnsmasq[0].dhcp_option='252,http://${LAN_IP}:${CAPTIVE_PORT}/' 2>/dev/null || true
uci -q set dhcp.@dnsmasq[0].filter_aaaa=0 2>/dev/null || true
uci commit dhcp
/etc/init.d/dnsmasq reload"
    printf '%s\n' "${uci_clean}" | _ssh sh -
    log_info "      ✅ Dominios de probe eliminados"

    # Eliminar archivos
    log_step "[4/4] Eliminando archivos del portal..."
    _ssh "rm -rf ${CAPTIVE_DIR}"
    log_info "      ✅ ${CAPTIVE_DIR} eliminado"

    echo ""
    log_info "✅ Portal cautivo desinstalado. Todos los dispositivos pueden navegar libremente."
}

# ---------------------------------------------------------------------------
# Subcomando: allow
# ---------------------------------------------------------------------------
_allow() {
    local target_ip="${_SUBCMD_ARG}"

    if [ -z "${target_ip}" ]; then
        log_error "Falta la IP a autorizar."
        echo "   Uso: $0 allow <IP> [--timeout <min>]"
        exit 1
    fi

    if ! _validate_ip "${target_ip}"; then
        log_error "IP inválida: ${target_ip}"
        exit 1
    fi

    _check_ssh

    local timeout="${_TIMEOUT}m"

    # Verificar si ya está autorizada
    if _ssh "nft list set ${NFT_TABLE} ${NFT_SET} 2>/dev/null | grep -qw '${target_ip}'"; then
        log_warn "${target_ip} ya está en el set — actualizando timeout a ${timeout}..."
        _ssh "nft delete element ${NFT_TABLE} ${NFT_SET} '{ ${target_ip} }' 2>/dev/null || true"
    fi

    _ssh "nft add element ${NFT_TABLE} ${NFT_SET} '{ ${target_ip} timeout ${timeout} }'"
    log_info "✅ ${target_ip} autorizado (${timeout})"
}

# ---------------------------------------------------------------------------
# Subcomando: block
# ---------------------------------------------------------------------------
_block() {
    local target_ip="${_SUBCMD_ARG}"

    if [ -z "${target_ip}" ]; then
        log_error "Falta la IP a bloquear."
        echo "   Uso: $0 block <IP>"
        exit 1
    fi

    if ! _validate_ip "${target_ip}"; then
        log_error "IP inválida: ${target_ip}"
        exit 1
    fi

    _check_ssh

    if ! _ssh "nft list set ${NFT_TABLE} ${NFT_SET} 2>/dev/null | grep -qw '${target_ip}'"; then
        log_warn "${target_ip} no estaba en el set (nada que hacer)"
        exit 0
    fi

    _ssh "nft delete element ${NFT_TABLE} ${NFT_SET} '{ ${target_ip} }'"
    log_info "✅ ${target_ip} bloqueado (vuelve al portal en su próxima petición HTTP)"
}

# ---------------------------------------------------------------------------
# Subcomando: flush
# ---------------------------------------------------------------------------
_flush() {
    _check_ssh

    local count
    count=$(_ssh "nft list set ${NFT_TABLE} ${NFT_SET} 2>/dev/null | grep -c 'elements' || echo 0" || echo 0)

    echo ""
    log_warn "Se vaciarán TODOS los clientes autorizados del portal."
    echo "   Set actual: ${count} entrada(s)"
    echo ""
    read -r -p "¿Continuar? (s/N) " answer
    answer=$(echo "${answer}" | tr '[:upper:]' '[:lower:]')
    if [ "${answer}" != "s" ] && [ "${answer}" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi

    _ssh "nft flush set ${NFT_TABLE} ${NFT_SET} 2>/dev/null || true"
    log_info "✅ Set vaciado — todos los dispositivos volverán al portal"
}

# ---------------------------------------------------------------------------
# Subcomando: list
# ---------------------------------------------------------------------------
_list() {
    _check_ssh

    echo ""
    echo "============================================="
    echo " Portal Cautivo — Estado"
    echo "============================================="

    # Tabla nftables
    echo ""
    echo "--- Tabla nftables ---"
    _ssh "nft list table ${NFT_TABLE} 2>/dev/null || echo '  (tabla no encontrada — portal no activo)'"

    # Set de clientes autorizados con timeouts
    echo ""
    echo "--- Clientes autorizados (${NFT_SET}) ---"
    local set_output
    set_output=$(_ssh "nft list set ${NFT_TABLE} ${NFT_SET} 2>/dev/null | grep 'elements' -A 99 | grep -v '^}' || true")
    if [ -z "${set_output}" ] || echo "${set_output}" | grep -q "elements { }"; then
        echo "  (sin clientes autorizados)"
    else
        echo "${set_output}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[^,}]*' | while IFS= read -r entry; do
            local ip timeout_info
            ip=$(echo "${entry}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
            timeout_info=$(echo "${entry}" | grep -o 'expires.*' | sed 's/expires /expira en /')
            printf "  %-18s %s\n" "${ip}" "${timeout_info:-}"
        done
    fi

    # Leases DHCP activos
    echo ""
    echo "--- Leases DHCP (/tmp/dhcp.leases) ---"
    _ssh "[ -f /tmp/dhcp.leases ] && awk '{printf \"  %-18s %-17s %s\\n\", \$3, \$2, \$4}' /tmp/dhcp.leases | head -30 || echo '  (sin leases)'"

    # Conexiones TCP activas port 80
    echo ""
    echo "--- Conexiones port 80 interceptadas ---"
    _ssh "netstat -tn 2>/dev/null | grep ':80 ' | awk '{printf \"  %-22s → %s\\n\", \$4, \$5}' | head -10 || echo '  (sin conexiones activas o netstat no disponible)'"
    echo ""
}

# ---------------------------------------------------------------------------
# Subcomando: status
# ---------------------------------------------------------------------------
_status() {
    _check_ssh

    echo ""
    echo "============================================="
    echo " Portal Cautivo — Diagnóstico"
    echo "============================================="
    echo ""

    log_step "Detectando IP LAN..."
    local router_info
    router_info=$(_router_lan_info)
    local LAN_IP LAN_IFACE
    eval "${router_info}"

    _verify "${LAN_IP}"

    echo ""
    echo "--- Configuración guardada ---"
    _ssh "cat ${CAPTIVE_CFG} 2>/dev/null || echo '  (${CAPTIVE_CFG} no encontrado)'"

    echo ""
    echo "--- Servicio captive ---"
    _ssh "/etc/init.d/captive status 2>/dev/null || echo '  (servicio no registrado)'"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    case "${_SUBCMD}" in
        install)   _install ;;
        uninstall) _uninstall ;;
        allow)     _allow ;;
        block)     _block ;;
        flush)     _flush ;;
        list)      _list ;;
        status)    _status ;;
        *)
            log_error "Subcomando vacío. Usa: install | uninstall | allow | block | flush | list | status"
            exit 1
            ;;
    esac
}

main
