#!/usr/bin/env bash
# ============================================================================
# setup-tor-onion.sh — Transparent proxy para dominios .onion en OpenWRT
#
# Configura OpenWRT para que los clientes LAN/WiFi accedan a dominios .onion
# de forma transparente sin configurar proxy en cada dispositivo.
#
# Prerrequisito en la Raspi3b (/etc/tor/torrc):
#   VirtualAddrNetworkIPv4 10.192.0.0/10
#   AutomapHostsOnResolve 1
#   TransPort 0.0.0.0:9040
#   DNSPort  0.0.0.0:5300   # evitar conflicto con mDNS (5353)
#
# Lo que hace en OpenWRT:
#   1. dnsmasq: reenvía consultas .onion → Raspi DNSPort
#               (Tor devuelve IP virtual del rango 10.192.0.0/10)
#   2. Firewall: DNAT TCP a 10.192.0.0/10 → Raspi TransPort
#               MASQUERADE para que el retorno fluya por el router (conntrack)
#
# Subcomandos:
#   enable    Activa el transparent proxy
#   disable   Desactiva el DNAT (conserva entrada DNS en dnsmasq)
#   uninstall Elimina el DNAT y la entrada DNS de dnsmasq
#   status    Muestra el estado actual
#   doctor    Diagnostica dependencias y configuración capa por capa
#
# Uso:
#   setup-tor-onion.sh enable    [--raspi-ip <IP>] [--dns-port 5300] [--trans-port 9040]
#   setup-tor-onion.sh disable   [--ip <router>] [--env <env>]
#   setup-tor-onion.sh uninstall [--ip <router>] [--env <env>]
#   setup-tor-onion.sh status    [--ip <router>] [--env <env>]
#   setup-tor-onion.sh doctor    [--ip <router>] [--dns-port 5300] [--trans-port 9040]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../commons/logging.sh disable=SC1091
source "${SCRIPT_DIR}/../commons/logging.sh"

_NFT_FILE="/etc/nftables.d/tor-onion.nft"
_UCI_INCLUDE="tor_onion_nft"
_VIRTUAL_RANGE="10.192.0.0/10"
_DEFAULT_DNS_PORT="5300"
_DEFAULT_TRANS_PORT="9040"

_SUBCMD=""
_ENV="prod"
_CLI_IP=""
_RASPI_IP=""
_DNS_PORT=""
_TRANS_PORT=""

# ---------------------------------------------------------------------------
# Ayuda
# ---------------------------------------------------------------------------
_show_help() {
    cat << HELP
Uso: $(basename "$0") <subcomando> [opciones]

Subcomandos:
  enable    Activa el transparent proxy .onion
  disable   Desactiva el DNAT (conserva la entrada DNS en dnsmasq)
  uninstall Elimina el DNAT y la entrada DNS de dnsmasq
  status    Muestra el estado actual
  doctor    Diagnostica el stack completo capa por capa

Opciones:
  --raspi-ip <IP>      IP de la Raspi3b (default: auto-detecta raspi-tor en DHCP)
  --dns-port <puerto>  Puerto DNSPort de Tor en la Raspi (default: ${_DEFAULT_DNS_PORT})
  --trans-port <p>     Puerto TransPort de Tor en la Raspi (default: ${_DEFAULT_TRANS_PORT})
  --ip <IP>            IP del router (default: env o 192.168.1.1)
  --env <env>          Entorno (default: prod)
  -h, --help           Muestra esta ayuda

Ejemplos:
  $(basename "$0") enable
  $(basename "$0") enable --raspi-ip 192.168.1.100
  $(basename "$0") enable --raspi-ip 192.168.1.100 --dns-port 5300 --trans-port 9040
  $(basename "$0") disable
  $(basename "$0") uninstall
  $(basename "$0") status
  $(basename "$0") doctor
HELP
}

# ---------------------------------------------------------------------------
# Parsear args
# ---------------------------------------------------------------------------
if [[ $# -eq 0 ]]; then
    _show_help; exit 0
fi

_SUBCMD="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         _CLI_IP="${2:?--ip requiere argumento}";         shift 2 ;;
        --env)        _ENV="${2:?--env requiere argumento}";           shift 2 ;;
        --raspi-ip)   _RASPI_IP="${2:?--raspi-ip requiere argumento}"; shift 2 ;;
        --dns-port)   _DNS_PORT="${2:?--dns-port requiere argumento}"; shift 2 ;;
        --trans-port) _TRANS_PORT="${2:?--trans-port requiere argumento}"; shift 2 ;;
        -h|--help)    _show_help; exit 0 ;;
        *) log_error "Argumento desconocido: $1"; _show_help; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Entorno y SSH
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
# shellcheck disable=SC1090
[ -f "${ENV_FILE}" ] && { set -a; source "${ENV_FILE}"; set +a; }

ROUTER_IP="${_CLI_IP:-${ROUTER_IP:-192.168.1.1}}"
SSH_PORT="${SSH_PORT:-22}"

_ssh() {
    ssh -p "${SSH_PORT}" \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "root@${ROUTER_IP}" "$@"
}

_check_ssh() {
    if ! ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
        log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
    log_info "Conectado a ${ROUTER_IP}"
}

# Lee la IP asignada a raspi-tor en DHCP (si existe)
_get_raspi_tor_ip() {
    _ssh sh << 'REMOTE'
idx=0
while uci -q get "dhcp.@host[${idx}]" >/dev/null 2>&1; do
    hname=$(uci -q get "dhcp.@host[${idx}].name" 2>/dev/null || true)
    if [ "${hname}" = "raspi-tor" ]; then
        uci -q get "dhcp.@host[${idx}].ip" 2>/dev/null || true
        break
    fi
    idx=$((idx + 1))
done
REMOTE
}

# ---------------------------------------------------------------------------
# enable
# ---------------------------------------------------------------------------
_enable() {
    _check_ssh

    # Raspi IP: auto-detectar desde DHCP o pedir
    if [ -z "${_RASPI_IP}" ]; then
        log_step "Buscando IP de raspi-tor en DHCP del router..."
        _RASPI_IP=$(_get_raspi_tor_ip 2>/dev/null || true)
        if [ -n "${_RASPI_IP}" ]; then
            log_info "raspi-tor encontrada: ${_RASPI_IP}"
        else
            echo ""
            read -r -p "  IP de la Raspi3b (Tor DNSPort + TransPort): " _RASPI_IP
            [ -n "${_RASPI_IP}" ] || { log_error "IP requerida"; exit 1; }
        fi
    fi

    local dns_port="${_DNS_PORT:-${_DEFAULT_DNS_PORT}}"
    local trans_port="${_TRANS_PORT:-${_DEFAULT_TRANS_PORT}}"
    local raspi_ip="${_RASPI_IP}"
    local nft_file="${_NFT_FILE}"
    local uci_include="${_UCI_INCLUDE}"
    local vrange="${_VIRTUAL_RANGE}"

    echo ""
    echo "============================================="
    echo " Transparent .onion proxy — configuración"
    echo "============================================="
    echo "  Raspi IP:       ${raspi_ip}"
    echo "  DNS port:       ${dns_port}  (Tor DNSPort)"
    echo "  Trans port:     ${trans_port}  (Tor TransPort)"
    echo "  Rango virtual:  ${vrange}"
    echo ""
    echo "  dnsmasq: .onion → ${raspi_ip}#${dns_port}"
    echo "  nftables DNAT:  TCP ${vrange} → ${raspi_ip}:${trans_port}"
    echo "  nftables MASQ:  retorno fluye por el router (conntrack)"
    echo ""
    read -r -p "  ¿Aplicar? (s/N) " confirm
    confirm=$(echo "${confirm}" | tr '[:upper:]' '[:lower:]')
    [ "${confirm}" = "s" ] || { echo "Cancelado."; exit 0; }
    echo ""

    # El outer heredoc (EOF sin comillas) expande variables locales.
    # El inner heredoc (NFTEOF con comillas) se envía literal al shell remoto,
    # que ve los valores ya sustituidos por el outer heredoc.
    _ssh sh - << EOF
set -eu
RASPI_IP="${raspi_ip}"
DNS_PORT="${dns_port}"
TRANS_PORT="${trans_port}"
NFT_FILE="${nft_file}"
UCI_INCLUDE="${uci_include}"
VRANGE="${vrange}"

# ── 1. Crear archivo nftables ─────────────────────────────
mkdir -p "\$(dirname \${NFT_FILE})"
cat > "\${NFT_FILE}" << 'NFTEOF'
# Transparent Tor proxy — .onion
# Generado por setup-tor-onion.sh — no editar manualmente
#
# Este archivo se incluye DENTRO del bloque table inet fw4 { } de fw4,
# por eso usa definiciones de cadenas con hooks (no 'add rule').
#
# DNAT: TCP al rango virtual .onion → Raspi TransPort
chain tor_onion_dnat {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr ${vrange} meta l4proto tcp dnat ip to ${raspi_ip}:${trans_port}
}
# MASQUERADE: el router actúa de origen para la Raspi → retorno correcto via conntrack
chain tor_onion_snat {
    type nat hook postrouting priority srcnat; policy accept;
    ip daddr ${raspi_ip} tcp dport ${trans_port} masquerade
}
NFTEOF
echo "  ✅ \${NFT_FILE} creado"

# ── 2. Registrar include UCI en el firewall ───────────────
uci -q delete "firewall.\${UCI_INCLUDE}" 2>/dev/null || true
uci set "firewall.\${UCI_INCLUDE}=include"
uci set "firewall.\${UCI_INCLUDE}.path=\${NFT_FILE}"
uci set "firewall.\${UCI_INCLUDE}.type=nftables"
uci commit firewall
echo "  ✅ Include UCI '\${UCI_INCLUDE}' registrado"

# ── 3. Agregar server .onion en dnsmasq ──────────────────
# Eliminar entrada /onion/ anterior si existe (evita duplicados)
servers=\$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
for s in \${servers}; do
    case "\${s}" in
        /onion/*) uci -q del_list dhcp.@dnsmasq[0].server="\${s}" 2>/dev/null || true ;;
    esac
done
uci add_list dhcp.@dnsmasq[0].server="/onion/\${RASPI_IP}#\${DNS_PORT}"
uci commit dhcp
echo "  ✅ dnsmasq: .onion → \${RASPI_IP}#\${DNS_PORT}"

# ── 3b. Exención DNS rebind protection para .onion ───────
# dnsmasq tiene --stop-dns-rebind que descarta respuestas con IPs privadas
# (10.x.x.x). Tor legítimamente devuelve IPs del rango 10.192.0.0/10 para
# .onion vía AutomapHostsOnResolve, así que necesitamos eximir el dominio.
rebind_domains=\$(uci -q get dhcp.@dnsmasq[0].rebind_domain 2>/dev/null || true)
already_exempt=0
for rd in \${rebind_domains}; do
    [ "\${rd}" = "/onion/" ] && already_exempt=1
done
if [ "\${already_exempt}" = "0" ]; then
    uci add_list dhcp.@dnsmasq[0].rebind_domain='/onion/'
    uci commit dhcp
    echo "  ✅ dnsmasq: rebind protection exenta para .onion"
else
    echo "  — dnsmasq: rebind exemption /onion/ ya configurada"
fi

# ── 4. Recargar servicios ─────────────────────────────────
echo ""
/etc/init.d/dnsmasq restart 2>/dev/null && echo "  ✅ dnsmasq reiniciado" || true

if /etc/init.d/firewall restart >/tmp/_tor_onion_fw.log 2>&1; then
    echo "  ✅ Firewall reiniciado"
else
    echo "  ❌ Error al reiniciar firewall:"
    sed 's/^/     /' /tmp/_tor_onion_fw.log
fi
rm -f /tmp/_tor_onion_fw.log

# ── 5. Verificar resolución DNS .onion ───────────────────
echo ""
echo "  Verificando resolución DNS .onion..."
sleep 2
dns_result=\$(nslookup duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion 127.0.0.1 2>/dev/null || true)
if echo "\${dns_result}" | grep -q "^Address:.*10\."; then
    vip=\$(echo "\${dns_result}" | grep "^Address:.*10\." | head -1 | awk '{print \$2}')
    echo "  ✅ DNS .onion resuelve a IP virtual: \${vip}"
else
    echo "  ⚠️  DNS sin respuesta — verifica que Tor esté corriendo en la Raspi"
    echo "     (torrc: DNSPort 0.0.0.0:${dns_port} y TransPort 0.0.0.0:${trans_port})"
fi
EOF

    echo ""
    log_info "✅ Transparent .onion proxy activado"
    echo ""
    echo "  ┌─ Cómo probar ──────────────────────────────────────────────────"
    echo "  │"
    echo "  │  DNS (desde el Mac o cualquier cliente del router):"
    echo "  │  nslookup duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion ${ROUTER_IP}"
    echo "  │  → debe devolver una IP del rango 10.192.0.0/10"
    echo "  │"
    echo "  │  Nota: curl bloquea .onion por RFC 7686 — usa wget o un navegador:"
    echo "  │  wget -qO- http://duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion"
    echo "  │"
    echo "  │  Firefox: about:config → network.dns.blockDotOnion → false"
    echo "  └────────────────────────────────────────────────────────────────"
    echo ""
}

# ---------------------------------------------------------------------------
# disable — elimina DNAT, conserva entrada dnsmasq
# ---------------------------------------------------------------------------
_disable() {
    _check_ssh
    log_step "Desactivando DNAT .onion (firewall include + archivo nftables)..."

    local nft_file="${_NFT_FILE}"
    local uci_include="${_UCI_INCLUDE}"

    _ssh sh - << EOF
set -eu
NFT_FILE="${nft_file}"
UCI_INCLUDE="${uci_include}"

# Eliminar include UCI
if uci -q get "firewall.\${UCI_INCLUDE}" >/dev/null 2>&1; then
    uci delete "firewall.\${UCI_INCLUDE}"
    uci commit firewall
    echo "  ✅ Include UCI '\${UCI_INCLUDE}' eliminado"
else
    echo "  — Include '\${UCI_INCLUDE}' no encontrado (ya estaba eliminado)"
fi

# Eliminar archivo nftables
if [ -f "\${NFT_FILE}" ]; then
    rm -f "\${NFT_FILE}"
    echo "  ✅ \${NFT_FILE} eliminado"
else
    echo "  — \${NFT_FILE} no encontrado"
fi

if /etc/init.d/firewall restart >/tmp/_tor_onion_fw.log 2>&1; then
    echo "  ✅ Firewall reiniciado"
else
    echo "  ❌ Error al reiniciar firewall:"
    sed 's/^/     /' /tmp/_tor_onion_fw.log
fi
rm -f /tmp/_tor_onion_fw.log
echo ""
echo "  Nota: la entrada dnsmasq .onion se conserva."
echo "  Usa 'uninstall' para eliminarla también."
EOF

    echo ""
    log_info "✅ DNAT .onion desactivado"
    echo ""
}

# ---------------------------------------------------------------------------
# uninstall — elimina DNAT + entrada dnsmasq
# ---------------------------------------------------------------------------
_uninstall() {
    _check_ssh

    echo ""
    echo "============================================="
    echo " Desinstalar transparent .onion proxy"
    echo "============================================="
    echo ""
    echo "  Se eliminarán:"
    echo "   • Include UCI '${_UCI_INCLUDE}' del firewall"
    echo "   • Archivo ${_NFT_FILE}"
    echo "   • Entrada dnsmasq server '/onion/...'"
    echo ""
    read -r -p "  ¿Continuar? (s/N) " confirm
    confirm=$(echo "${confirm}" | tr '[:upper:]' '[:lower:]')
    [ "${confirm}" = "s" ] || { echo "Cancelado."; exit 0; }
    echo ""

    local nft_file="${_NFT_FILE}"
    local uci_include="${_UCI_INCLUDE}"

    _ssh sh - << EOF
set -eu
NFT_FILE="${nft_file}"
UCI_INCLUDE="${uci_include}"

# ── Eliminar include UCI ──────────────────────────────────
if uci -q get "firewall.\${UCI_INCLUDE}" >/dev/null 2>&1; then
    uci delete "firewall.\${UCI_INCLUDE}"
    uci commit firewall
    echo "  ✅ Include UCI '\${UCI_INCLUDE}' eliminado"
else
    echo "  — Include '\${UCI_INCLUDE}' no encontrado"
fi

# ── Eliminar archivo nftables ─────────────────────────────
if [ -f "\${NFT_FILE}" ]; then
    rm -f "\${NFT_FILE}"
    echo "  ✅ \${NFT_FILE} eliminado"
else
    echo "  — \${NFT_FILE} no encontrado"
fi

# ── Eliminar entrada dnsmasq .onion ──────────────────────
dns_changed=0
servers=\$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
for s in \${servers}; do
    case "\${s}" in
        /onion/*)
            uci -q del_list dhcp.@dnsmasq[0].server="\${s}" 2>/dev/null || true
            echo "  ✅ Entrada dnsmasq '\${s}' eliminada"
            dns_changed=1 ;;
    esac
done
[ "\${dns_changed}" = "0" ] && echo "  — Entrada dnsmasq .onion no encontrada"
[ "\${dns_changed}" = "1" ] && uci commit dhcp || true

# Eliminar exención rebind protection para .onion
rebind_changed=0
rebind_domains=\$(uci -q get dhcp.@dnsmasq[0].rebind_domain 2>/dev/null || true)
for rd in \${rebind_domains}; do
    if [ "\${rd}" = "/onion/" ]; then
        uci -q del_list dhcp.@dnsmasq[0].rebind_domain='/onion/' 2>/dev/null || true
        rebind_changed=1
        echo "  ✅ dnsmasq: rebind exemption /onion/ eliminada"
        break
    fi
done
[ "\${rebind_changed}" = "1" ] && uci commit dhcp || true

# ── Recargar servicios ────────────────────────────────────
echo ""
if /etc/init.d/firewall restart >/tmp/_tor_onion_fw.log 2>&1; then
    echo "  ✅ Firewall reiniciado"
else
    echo "  ❌ Error al reiniciar firewall:"
    sed 's/^/     /' /tmp/_tor_onion_fw.log
fi
rm -f /tmp/_tor_onion_fw.log
[ "\${dns_changed}" = "1" ] && \
    { /etc/init.d/dnsmasq restart 2>/dev/null && echo "  ✅ dnsmasq reiniciado" || true; }
EOF

    echo ""
    log_info "✅ Desinstalación completada"
    echo ""
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------
_status() {
    _check_ssh

    echo ""
    echo "============================================="
    echo " Estado — Transparent .onion proxy"
    echo "============================================="

    local nft_file="${_NFT_FILE}"
    local uci_include="${_UCI_INCLUDE}"

    _ssh sh - << EOF
set -eu
NFT_FILE="${nft_file}"
UCI_INCLUDE="${uci_include}"

# ── Include UCI ───────────────────────────────────────────
echo ""
echo "  Include UCI firewall:"
if uci -q get "firewall.\${UCI_INCLUDE}" >/dev/null 2>&1; then
    path=\$(uci -q get "firewall.\${UCI_INCLUDE}.path" 2>/dev/null || true)
    echo "  ✅ ACTIVO — \${path}"
else
    echo "  ❌ INACTIVO ('\${UCI_INCLUDE}' no registrado)"
fi

# ── Archivo nftables ──────────────────────────────────────
echo ""
echo "  Archivo nftables (\${NFT_FILE}):"
if [ -f "\${NFT_FILE}" ]; then
    echo "  ✅ Existe:"
    grep -v '^#' "\${NFT_FILE}" | grep -v '^$' | sed 's/^/     /'
else
    echo "  ❌ No encontrado"
fi

# ── dnsmasq .onion ────────────────────────────────────────
echo ""
echo "  Entrada dnsmasq server .onion:"
servers=\$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
found_dns=0
for s in \${servers}; do
    case "\${s}" in
        /onion/*) echo "  ✅ \${s}"; found_dns=1 ;;
    esac
done
[ "\${found_dns}" = "0" ] && echo "  ❌ No configurada"

# ── Prueba DNS en vivo ────────────────────────────────────
echo ""
echo "  Prueba DNS .onion (via dnsmasq local):"
result=\$(nslookup duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion 127.0.0.1 2>/dev/null || true)
if echo "\${result}" | grep -q "10\."; then
    echo "  ✅ Resuelve a IP virtual 10.x.x.x — OK"
    echo "\${result}" | grep "Address:" | tail -1 | sed 's/^/     /'
else
    echo "  ⚠️  Sin respuesta (¿Tor corriendo en la Raspi?)"
fi

echo ""
EOF
}

# ---------------------------------------------------------------------------
# doctor — diagnostica el stack completo capa por capa
# ---------------------------------------------------------------------------
_doctor() {
    _check_ssh

    local nft_file="${_NFT_FILE}"
    local uci_include="${_UCI_INCLUDE}"
    local dns_port="${_DNS_PORT:-${_DEFAULT_DNS_PORT}}"
    local trans_port="${_TRANS_PORT:-${_DEFAULT_TRANS_PORT}}"

    echo ""
    echo "============================================="
    echo " Diagnóstico — Transparent .onion proxy"
    echo "============================================="

    local _rc=0
    _ssh sh - << EOF || _rc=$?
NFT_FILE="${nft_file}"
UCI_INCLUDE="${uci_include}"
DNS_PORT="${dns_port}"
TRANS_PORT="${trans_port}"

PASS=0
FAIL=0
WARN=0
RASPI_IP=""
RASPI_MAC=""

ok()   { echo "  ✅ \$*"; PASS=\$((PASS + 1)); }
fail() { echo "  ❌ \$*"; FAIL=\$((FAIL + 1)); }
warn() { echo "  ⚠️  \$*"; WARN=\$((WARN + 1)); }
hint() { echo "     → \$*"; }

# ── Capa 1: DHCP raspi-tor ───────────────────────────────
echo ""
echo "  ── Capa 1: IP estática raspi-tor (DHCP) ────────────"
idx=0
while uci -q get "dhcp.@host[\${idx}]" >/dev/null 2>&1; do
    hname=\$(uci -q get "dhcp.@host[\${idx}].name" 2>/dev/null || true)
    if [ "\${hname}" = "raspi-tor" ]; then
        RASPI_IP=\$(uci -q get "dhcp.@host[\${idx}].ip"  2>/dev/null || true)
        RASPI_MAC=\$(uci -q get "dhcp.@host[\${idx}].mac" 2>/dev/null || true)
        break
    fi
    idx=\$((idx + 1))
done

if [ -n "\${RASPI_IP}" ]; then
    ok "DHCP estático raspi-tor: \${RASPI_MAC} → \${RASPI_IP}"
else
    fail "Sin entrada DHCP 'raspi-tor' — IP de la Raspi desconocida"
    hint "Ejecuta: just socks-enable"
fi

# Fallback: extraer IP desde la entrada dnsmasq /onion/ si existe
if [ -z "\${RASPI_IP}" ]; then
    servers=\$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
    for s in \${servers}; do
        case "\${s}" in
            /onion/*)
                RASPI_IP=\$(echo "\${s}" | sed 's|/onion/||;s|#.*||')
                warn "Raspi IP obtenida desde dnsmasq (sin DHCP estático): \${RASPI_IP}"
                break ;;
        esac
    done
fi

# Ping a la Raspi
if [ -n "\${RASPI_IP}" ]; then
    if ping -c 1 -W 2 "\${RASPI_IP}" >/dev/null 2>&1; then
        ok "Raspi alcanzable en la red: \${RASPI_IP}"
    else
        fail "Raspi NO alcanzable: \${RASPI_IP}"
        hint "Verifica que la Raspi esté encendida y conectada al LAN del router"
    fi
fi

# ── Capa 2: dnsmasq .onion ───────────────────────────────
echo ""
echo "  ── Capa 2: dnsmasq .onion ──────────────────────────"
servers=\$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null || true)
onion_server=""
for s in \${servers}; do
    case "\${s}" in
        /onion/*) onion_server="\${s}"; break ;;
    esac
done

if [ -n "\${onion_server}" ]; then
    ok "dnsmasq server .onion: \${onion_server}"
else
    fail "Sin entrada dnsmasq server /onion/"
    hint "Ejecuta: just onion-enable"
fi

# Verificar exención rebind protection (sin esto dnsmasq descarta IPs 10.x.x.x)
rebind_ok=0
rebind_domains=\$(uci -q get dhcp.@dnsmasq[0].rebind_domain 2>/dev/null || true)
for rd in \${rebind_domains}; do
    [ "\${rd}" = "/onion/" ] && rebind_ok=1
done
if [ "\${rebind_ok}" = "1" ]; then
    ok "dnsmasq rebind protection exenta para .onion"
else
    fail "dnsmasq rebind_domain '/onion/' no configurado — bloqueará respuestas 10.x.x.x"
    hint "Ejecuta: just onion-enable  (lo configura automáticamente)"
fi

if ps 2>/dev/null | grep -q '[d]nsmasq'; then
    ok "dnsmasq corriendo"
else
    fail "dnsmasq NO está corriendo"
    hint "/etc/init.d/dnsmasq restart"
fi

dns_result=\$(nslookup duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion 127.0.0.1 2>/dev/null || true)
if echo "\${dns_result}" | grep -q "^Address:.*10\."; then
    vip=\$(echo "\${dns_result}" | grep "^Address:.*10\." | head -1 | awk '{print \$2}')
    ok "DNS .onion resuelve a IP virtual: \${vip}"
else
    fail "DNS .onion no resuelve a IP virtual 10.x.x.x"
    hint "Verifica en la Raspi: DNSPort 0.0.0.0:\${DNS_PORT} en /etc/tor/torrc"
    hint "sudo systemctl restart tor  (en la Raspi)"
fi

# ── Capa 3: nftables DNAT ────────────────────────────────
echo ""
echo "  ── Capa 3: nftables DNAT ───────────────────────────"

if uci -q get "firewall.\${UCI_INCLUDE}" >/dev/null 2>&1; then
    nft_path=\$(uci -q get "firewall.\${UCI_INCLUDE}.path" 2>/dev/null || true)
    ok "UCI include '\${UCI_INCLUDE}' registrado: \${nft_path}"
else
    fail "UCI include '\${UCI_INCLUDE}' no registrado en el firewall"
    hint "Ejecuta: just onion-enable"
fi

if [ -f "\${NFT_FILE}" ]; then
    ok "Archivo nft existe: \${NFT_FILE}"
else
    fail "Archivo nft NO existe: \${NFT_FILE}"
    hint "Ejecuta: just onion-enable"
fi

if command -v nft >/dev/null 2>&1; then
    if nft list chain inet fw4 tor_onion_dnat >/dev/null 2>&1; then
        ok "Cadena tor_onion_dnat cargada en el kernel"
    else
        fail "Cadena tor_onion_dnat NO cargada (fw4 no incluyó el archivo)"
        hint "Ejecuta: just onion-uninstall && just onion-enable"
    fi
    if nft list chain inet fw4 tor_onion_snat >/dev/null 2>&1; then
        ok "Cadena tor_onion_snat cargada en el kernel"
    else
        fail "Cadena tor_onion_snat NO cargada (fw4 no incluyó el archivo)"
        hint "Ejecuta: just onion-uninstall && just onion-enable"
    fi
else
    warn "nft no disponible en el router — no se pueden verificar cadenas"
fi

# ── Capa 4: puertos Tor en la Raspi ─────────────────────
echo ""
echo "  ── Capa 4: puertos Tor en la Raspi ─────────────────"
if [ -z "\${RASPI_IP}" ]; then
    warn "Raspi IP desconocida — se omite verificación de puertos"
else
    # DNSPort es UDP — BusyBox nslookup no soporta SERVER#PORT y nc sin -u
    # no puede probar UDP. La conectividad UDP se valida en Capa 2 de forma
    # completa (dnsmasq → Raspi:DNSPort). Aquí solo verificamos si el proceso
    # Tor llegó a abrir el puerto (visible en ss desde el propio router).
    # Si la Capa 2 pasó, el DNSPort está OK; si falló, revisar bootstrap de Tor.
    warn "DNSPort UDP (\${RASPI_IP}:\${DNS_PORT}): prueba directa no disponible desde OpenWRT"
    hint "La Capa 2 valida el DNSPort completo: si la nslookup via dnsmasq pasa, el puerto está OK"
    hint "Para verificar bootstrap: grep Bootstrapped /run/tor/notices.log (en la Raspi)"

    # TransPort: nc siempre falla porque Tor rechaza conexiones directas
    # (no DNAT'd — no tiene SO_ORIGINAL_DST → RST inmediato por diseño).
    # Verificar en su lugar que la regla DNAT apunta al destino correcto.
    if nft list chain inet fw4 tor_onion_dnat 2>/dev/null | grep -q "dnat ip to \${RASPI_IP}:\${TRANS_PORT}"; then
        ok "TransPort DNAT apunta a \${RASPI_IP}:\${TRANS_PORT} (activo)"
    else
        fail "DNAT no apunta a \${RASPI_IP}:\${TRANS_PORT} — regla incorrecta o ausente"
        hint "Ejecuta: just onion-uninstall && just onion-enable"
    fi
fi

# ── Resumen ──────────────────────────────────────────────
echo ""
echo "  ─────────────────────────────────────────────────────"
echo "  Resultado: \${PASS} OK  |  \${FAIL} ERROR  |  \${WARN} AVISO"
echo "  ─────────────────────────────────────────────────────"
echo ""

[ "\${FAIL}" -gt 0 ] && exit 1 || exit 0
EOF

    echo ""
    if [ "${_rc}" -eq 0 ]; then
        log_info "✅ Todos los checks pasaron — proxy .onion listo"
    else
        log_error "Hay errores — revisa los puntos marcados con ❌ arriba"
    fi
    echo ""
    return "${_rc}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${_SUBCMD}" in
    enable)    _enable ;;
    disable)   _disable ;;
    uninstall) _uninstall ;;
    status)    _status ;;
    doctor)    _doctor ;;
    -h|--help) _show_help ;;
    *) log_error "Subcomando desconocido: ${_SUBCMD}"; _show_help; exit 1 ;;
esac
