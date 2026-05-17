#!/usr/bin/env bash
# ============================================================================
# setup-wifi.sh — Gestión de WiFi en OpenWRT (AP y modo cliente)
#
# Subcomandos:
#   ap       Configura un radio como Access Point (SSID, contraseña, canal)
#   client   Configura un radio como cliente WiFi (conecta a otra red)
#   scan     Escanea redes WiFi disponibles
#   status   Muestra estado de todos los radios e interfaces
#   list     Lista la configuración UCI de wireless
#   enable   Habilita un radio o interfaz WiFi
#   disable  Deshabilita un radio o interfaz WiFi
#
# Uso:
#   setup-wifi.sh ap     --ssid <nombre> [--password <pass>] [--radio <r>] [--channel <ch>]
#   setup-wifi.sh client --ssid <nombre> [--password <pass>] [--radio <r>]
#   setup-wifi.sh scan   [--radio <r>]
#   setup-wifi.sh status|list
#   setup-wifi.sh enable|disable --radio <r>
#
# Opciones:
#   --radio <radio>      radio0|radio1|2g|5g  (default: radio0 para ap, radio1 para client)
#   --ssid <nombre>      Nombre de la red WiFi
#   --password <pass>    Contraseña WPA2 (mínimo 8 chars)
#   --open               Sin contraseña (--encryption none)
#   --channel <n>        Canal WiFi (auto si no se indica)
#   --encryption <tipo>  none|psk|psk2  (default: psk2)
#   --ip <IP>            IP del router
#   --env <env>          Entorno (default: prod)
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

# ---------------------------------------------------------------------------
# Parsear subcomando y opciones
# ---------------------------------------------------------------------------
_SUBCMD=""
_ENV="prod"
_CLI_IP=""
_RADIO=""
_SSID=""
_PASSWORD=""
_BSSID=""
_CHANNEL="auto"
_ENCRYPTION="psk2"
_OPEN=false

_show_help() {
    cat << 'HELP'
Uso: setup-wifi.sh <subcomando> [opciones]

Subcomandos:
  ap          Configura Access Point
  client      Conecta a una red WiFi externa (modo cliente/STA)
  disconnect  Desconecta el cliente WiFi y elimina la interfaz wwan
  scan        Escanea redes disponibles
  status      Estado de todos los radios e interfaces
  list        Configuración UCI actual de wireless
  enable      Habilita un radio
  disable     Deshabilita un radio

Opciones:
  --radio <r>          radio0|radio1|2g|5g
  --ssid <nombre>      Nombre de red
  --password <pass>    Contraseña WPA2 (≥8 chars)
  --open               Sin contraseña
  --channel <n>        Canal (auto por defecto)
  --encryption <tipo>  none|psk|psk2 (default: psk2)
  --ip <IP>            IP del router
  --env <env>          Entorno (default: prod)

Ejemplos:
  setup-wifi.sh ap --ssid "MiRed" --password "clave1234"
  setup-wifi.sh ap --ssid "MiRed5G" --radio 5g --channel 36
  setup-wifi.sh ap --ssid "Libre" --open
  setup-wifi.sh client --ssid "RedExterna" --password "supass"
  setup-wifi.sh client --ssid "RedExterna" --radio radio1 --password "supass"
  setup-wifi.sh scan
  setup-wifi.sh scan --radio 5g
  setup-wifi.sh disable --radio radio1
HELP
}

if [[ $# -eq 0 ]]; then _show_help; exit 1; fi

case "$1" in
    ap|client|disconnect|scan|status|list|enable|disable) _SUBCMD="$1"; shift ;;
    -h|--help) _show_help; exit 0 ;;
    *) log_error "Subcomando desconocido: $1"; exit 1 ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)         _CLI_IP="${2:?}"; shift 2 ;;
        --env)        _ENV="${2:?}"; shift 2 ;;
        --radio)      _RADIO="${2:?}"; shift 2 ;;
        --ssid)       _SSID="${2:?}"; shift 2 ;;
        --password)   _PASSWORD="${2:?}"; shift 2 ;;
        --channel)    _CHANNEL="${2:?}"; shift 2 ;;
        --encryption) _ENCRYPTION="${2:?}"; shift 2 ;;
        --bssid)      _BSSID="${2:?}"; shift 2 ;;
        --open)       _OPEN=true; _ENCRYPTION="none"; shift ;;
        -h|--help)    _show_help; exit 0 ;;
        *) log_error "Opción desconocida: $1"; exit 1 ;;
    esac
done

# Normalizar alias de radio
_normalize_radio() {
    case "$1" in
        2g|2.4g|2ghz) echo "radio0" ;;
        5g|5ghz)       echo "radio1" ;;
        radio0|radio1) echo "$1" ;;
        "")            echo "" ;;
        *) log_error "Radio inválido: $1 (usa radio0, radio1, 2g o 5g)"; exit 1 ;;
    esac
}
_RADIO=$(_normalize_radio "${_RADIO}")

# ---------------------------------------------------------------------------
# Cargar entorno y SSH
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/environments/${_ENV}/.env.public"
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
    local retries=3 delay=4
    local i=1
    while [ "${i}" -le "${retries}" ]; do
        if ssh -q -p "${SSH_PORT}" -o ConnectTimeout=5 -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new "root@${ROUTER_IP}" exit 2>/dev/null; then
            return 0
        fi
        [ "${i}" -lt "${retries}" ] && { log_warn "SSH no disponible, reintentando en ${delay}s... (${i}/${retries})"; sleep "${delay}"; }
        i=$((i + 1))
    done
    log_error "No se puede conectar: root@${ROUTER_IP}:${SSH_PORT}"
    exit 1
}

# ---------------------------------------------------------------------------
# Subcomando: ap
# ---------------------------------------------------------------------------
_ap() {
    local radio="${_RADIO:-radio0}"

    [ -z "${_SSID}" ] && { log_error "--ssid requerido"; exit 1; }

    if [ "${_ENCRYPTION}" != "none" ] && [ -z "${_PASSWORD}" ]; then
        log_error "--password requerido (o usa --open para red sin contraseña)"
        exit 1
    fi

    if [ "${_ENCRYPTION}" != "none" ] && [ "${#_PASSWORD}" -lt 8 ]; then
        log_error "La contraseña debe tener al menos 8 caracteres"
        exit 1
    fi

    _check_ssh

    echo ""
    log_step "Configurando Access Point:"
    echo "   Radio:      ${radio}"
    echo "   SSID:       ${_SSID}"
    echo "   Cifrado:    ${_ENCRYPTION}"
    echo "   Canal:      ${_CHANNEL}"
    echo ""
    read -r -p "¿Continuar? (s/N) " ans
    [ "$(echo "${ans}" | tr '[:upper:]' '[:lower:]')" != "s" ] && { echo "Cancelado."; exit 0; }

    local ssid="${_SSID}"
    local password="${_PASSWORD}"
    local encryption="${_ENCRYPTION}"
    local channel="${_CHANNEL}"

    _ssh sh - << EOF
set -eu
RADIO="${radio}"
SSID="${ssid}"
PASSWORD="${password}"
ENCRYPTION="${encryption}"
CHANNEL="${channel}"

echo "Buscando interfaz AP en \${RADIO}..."

# Buscar interfaz AP existente en este radio
FOUND=""
I=0
while true; do
    DEV=\$(uci -q get wireless.@wifi-iface[\$I].device 2>/dev/null) || break
    MODE=\$(uci -q get wireless.@wifi-iface[\$I].mode 2>/dev/null || echo "ap")
    if [ "\$DEV" = "\$RADIO" ] && [ "\$MODE" = "ap" ]; then
        FOUND="\$I"
        break
    fi
    I=\$((I+1))
done

if [ -z "\$FOUND" ]; then
    echo "  Creando nueva interfaz AP en \${RADIO}..."
    uci add wireless wifi-iface
    FOUND=\$((I))
    uci set wireless.@wifi-iface[\$FOUND].device="\$RADIO"
    uci set wireless.@wifi-iface[\$FOUND].mode='ap'
    uci set wireless.@wifi-iface[\$FOUND].network='lan'
else
    echo "  Actualizando interfaz AP [\$FOUND] en \${RADIO}..."
fi

uci set wireless.@wifi-iface[\$FOUND].ssid="\$SSID"
uci set wireless.@wifi-iface[\$FOUND].disabled='0'

if [ "\$ENCRYPTION" = "none" ]; then
    uci set wireless.@wifi-iface[\$FOUND].encryption='none'
    uci -q delete wireless.@wifi-iface[\$FOUND].key 2>/dev/null || true
else
    uci set wireless.@wifi-iface[\$FOUND].encryption="\$ENCRYPTION"
    uci set wireless.@wifi-iface[\$FOUND].key="\$PASSWORD"
fi

# Canal
if [ "\$CHANNEL" != "auto" ] && [ "\$CHANNEL" != "" ]; then
    uci set wireless.\$RADIO.channel="\$CHANNEL"
else
    uci set wireless.\$RADIO.channel='auto'
fi

uci set wireless.\$RADIO.disabled='0'
uci commit wireless

echo "Aplicando configuración WiFi..."
wifi reload 2>/dev/null || wifi

echo ""
echo "✅ AP configurado:"
echo "   SSID:    \$SSID"
echo "   Cifrado: \$ENCRYPTION"
echo "   Radio:   \$RADIO"
EOF

    echo ""
    log_info "✅ Access Point listo. Busca '${_SSID}' en tus dispositivos."
}

# ---------------------------------------------------------------------------
# Subcomando: client (STA mode)
# ---------------------------------------------------------------------------
_client() {
    local radio="${_RADIO:-}"   # vacío si el usuario no especificó --radio

    _check_ssh

    # Modo interactivo: si no se pasó --ssid, guiar paso a paso
    if [ -z "${_SSID}" ]; then

        # Paso 1: elegir banda si no se especificó --radio
        if [ -z "${radio}" ]; then
            echo ""
            echo "  ¿Qué banda usar para conectarte?"
            echo "    [1] 2.4 GHz (radio0) — mayor alcance"
            echo "    [2] 5 GHz  (radio1) — mayor velocidad (default)"
            printf "  Banda [1/2]: "
            read -r _band_choice
            case "${_band_choice}" in
                1) radio="radio0" ;;
                *) radio="radio1" ;;
            esac
        fi

        # Paso 2: escanear
        echo ""
        log_step "Escaneando redes en ${radio}..."
        _do_scan "${radio}"
        echo ""

        # Paso 3: elegir SSID
        printf "  SSID de la red a conectar (Enter para cancelar): "
        read -r _SSID
        [ -z "${_SSID}" ] && { echo "  Cancelado."; exit 0; }

        # Paso 4: contraseña
        if ! "${_OPEN}" && [ -z "${_PASSWORD}" ]; then
            printf "  Contraseña para '%s' (Enter si es red abierta): " "${_SSID}"
            read -r -s _PASSWORD
            echo ""
            [ -z "${_PASSWORD}" ] && _OPEN=true
        fi

        # Paso 5: BSSID
        if [ -z "${_BSSID}" ]; then
            printf "  BSSID concreto (Enter para conectar al AP más fuerte): "
            read -r _BSSID
        fi
    fi

    # Aplicar default de radio si llegamos aquí sin haberlo definido (--radio explícito)
    [ -z "${radio}" ] && radio="radio1"

    # Si llegamos aquí con ssid ya dado (no interactivo) y falta password, pedir ahora
    if ! "${_OPEN}" && [ -z "${_PASSWORD}" ]; then
        printf "\n  Contraseña para '%s' (Enter si la red es abierta): " "${_SSID}"
        read -r -s _PASSWORD
        echo ""
        [ -z "${_PASSWORD}" ] && _OPEN=true
    fi
    [ "${_OPEN}" = "true" ] && _ENCRYPTION="none"

    # BSSID: pedir solo si no vino del modo interactivo ni de --bssid
    if [ -z "${_BSSID}" ]; then
        printf "  BSSID concreto (Enter para conectar al AP más fuerte): "
        read -r _BSSID
    fi

    echo ""
    log_step "Configurando modo cliente WiFi:"
    echo "   Radio:   ${radio}"
    echo "   Red:     ${_SSID}"
    [ -n "${_BSSID}" ] && echo "   BSSID:   ${_BSSID}"
    echo "   Cifrado: ${_ENCRYPTION}"
    echo ""
    log_warn "El router obtendrá una IP de '${_SSID}' via DHCP y la usará como WAN secundario."
    echo ""
    read -r -p "¿Continuar? (s/N) " ans
    [ "$(echo "${ans}" | tr '[:upper:]' '[:lower:]')" != "s" ] && { echo "Cancelado."; exit 0; }

    local ssid="${_SSID}"
    local password="${_PASSWORD}"
    local encryption="${_ENCRYPTION}"
    local bssid="${_BSSID}"

    _ssh sh - << EOF
set -eu
RADIO="${radio}"
SSID="${ssid}"
PASSWORD="${password}"
ENCRYPTION="${encryption}"
BSSID="${bssid}"

echo "Configurando interfaz de red 'wwan'..."
uci -q delete network.wwan 2>/dev/null || true
uci set network.wwan=interface
uci set network.wwan.proto='dhcp'
uci set network.wwan.peerdns='0'
uci commit network

echo "Añadiendo 'wwan' a zona firewall WAN..."
WAN_ZONE=""
I=0
while true; do
    NAME=\$(uci -q get firewall.@zone[\$I].name 2>/dev/null) || break
    if [ "\$NAME" = "wan" ]; then
        WAN_ZONE=\$I
        break
    fi
    I=\$((I+1))
done
if [ -n "\$WAN_ZONE" ]; then
    # Añadir wwan solo si no está ya
    NETS=\$(uci -q get firewall.@zone[\$WAN_ZONE].network 2>/dev/null || echo "")
    echo "\$NETS" | grep -qw "wwan" || uci add_list firewall.@zone[\$WAN_ZONE].network='wwan'
    uci commit firewall
fi

echo "Buscando interfaz STA existente en \$RADIO..."
FOUND=""
I=0
while true; do
    DEV=\$(uci -q get wireless.@wifi-iface[\$I].device 2>/dev/null) || break
    MODE=\$(uci -q get wireless.@wifi-iface[\$I].mode 2>/dev/null || echo "ap")
    if [ "\$DEV" = "\$RADIO" ] && [ "\$MODE" = "sta" ]; then
        FOUND="\$I"
        break
    fi
    I=\$((I+1))
done

if [ -z "\$FOUND" ]; then
    echo "  Creando nueva interfaz STA en \$RADIO..."
    uci add wireless wifi-iface
    FOUND=\$I
    uci set wireless.@wifi-iface[\$FOUND].device="\$RADIO"
    uci set wireless.@wifi-iface[\$FOUND].mode='sta'
else
    echo "  Actualizando interfaz STA [\$FOUND] en \$RADIO..."
fi

uci set wireless.@wifi-iface[\$FOUND].network='wwan'
uci set wireless.@wifi-iface[\$FOUND].ssid="\$SSID"
uci set wireless.@wifi-iface[\$FOUND].disabled='0'

if [ -n "\$BSSID" ]; then
    uci set wireless.@wifi-iface[\$FOUND].bssid="\$BSSID"
else
    uci -q delete wireless.@wifi-iface[\$FOUND].bssid 2>/dev/null || true
fi

if [ "\$ENCRYPTION" = "none" ]; then
    uci set wireless.@wifi-iface[\$FOUND].encryption='none'
    uci -q delete wireless.@wifi-iface[\$FOUND].key 2>/dev/null || true
else
    uci set wireless.@wifi-iface[\$FOUND].encryption="\$ENCRYPTION"
    uci set wireless.@wifi-iface[\$FOUND].key="\$PASSWORD"
fi

uci set wireless.\$RADIO.disabled='0'
uci commit wireless

echo "Aplicando configuración..."
wifi reload 2>/dev/null || wifi
/etc/init.d/firewall reload 2>/dev/null || true
/etc/init.d/network restart 2>/dev/null || true

echo ""
echo "✅ Modo cliente configurado:"
echo "   Red:         \$SSID"
echo "   Interfaz:    wwan (DHCP)"
echo "   Zona fw:     wan"
EOF

    echo ""
    log_info "✅ El router intentará conectarse a '${_SSID}'."
    echo "   Espera ~15 segundos y verifica:"
    echo "   ssh root@${ROUTER_IP} 'ip addr show wwan; ip route'"
}

# ---------------------------------------------------------------------------
# _do_scan — escanea redes y muestra tabla (sin _check_ssh, sin encabezado)
# Uso: _do_scan <radio>
# ---------------------------------------------------------------------------
_do_scan() {
    local radio="$1"

    _ssh sh - << EOF
set -eu
RADIO="${radio}"

# Derivar número de radio (radio0→0, radio1→1)
RNUM=\$(echo "\$RADIO" | sed 's/radio//')
PHY="phy\${RNUM}"

# Verificar que la phy existe
if [ ! -d "/sys/class/ieee80211/\${PHY}" ]; then
    echo "  ERROR: no se encontró \${PHY} para \${RADIO}"
    exit 1
fi

# Buscar interfaz existente en esta phy
# iw dev muestra: phy#0\n\tInterface wlan0\n ...
IFNAME=\$(iw dev 2>/dev/null | awk -v rn="\${RNUM}" '
    /^phy#/ { cur = substr(\$0, 5) }
    cur == rn && /Interface/ { print \$2; exit }
')

# Si no hay interfaz, crear una temporal para escanear
TEMP_IF=""
if [ -z "\${IFNAME}" ]; then
    TEMP_IF="scan_tmp\${RNUM}"
    iw phy "\${PHY}" interface add "\${TEMP_IF}" type managed 2>/dev/null || {
        echo "  ERROR: no se pudo crear interfaz temporal en \${PHY}"
        exit 1
    }
    ip link set "\${TEMP_IF}" up 2>/dev/null || true
    sleep 1
    IFNAME="\${TEMP_IF}"
    echo "  (interfaz temporal creada: \${IFNAME})"
fi

echo ""
echo "  Interfaz: \${IFNAME}  (radio: \${RADIO} / \${PHY})"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-30s %-5s %-10s %-6s %-19s %s\n" "SSID" "Banda" "Señal" "Canal" "BSSID" "Cifrado"
echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Función awk común para derivar banda desde canal
AWK_BAND='function band_of(c) { return (c+0 > 14) ? "5G" : "2.4G" }'

# Escanear: iwinfo si disponible, si no iw dev scan
if command -v iwinfo >/dev/null 2>&1; then
    iwinfo "\${IFNAME}" scan 2>/dev/null | awk '
    function band_of(c) { return (c+0 > 14) ? "5G" : "2.4G" }
    /Cell [0-9]+ - Address:/ {
        if (ssid != "")
            printf "  %-30s %-5s %-10s %-6s %-19s %s\n", ssid, band_of(ch), sig, ch, bssid, enc
        bssid=\$NF; ssid=""; sig="?"; ch="?"; enc="abierta"
    }
    /ESSID:/ { ssid=\$2; gsub(/"/, "", ssid) }
    /Channel:/ {
        for (i=1; i<=NF; i++) if (\$i=="Channel:") { ch=\$(i+1); gsub(/[^0-9]/,"",ch) }
    }
    /Signal:/ { sig=\$2" "\$3 }
    /Encryption:/ {
        rest=\$0; sub(/.*Encryption: */,"",rest); gsub(/[ \t]*\$/,"",rest)
        if (rest~/none/ || rest=="") enc="abierta"
        else if (rest~/WPA2/) enc="WPA2"
        else if (rest~/WPA/)  enc="WPA"
        else enc=rest
    }
    END { if (ssid!="") printf "  %-30s %-5s %-10s %-6s %-19s %s\n", ssid, band_of(ch), sig, ch, bssid, enc }
    ' 2>/dev/null
else
    iw dev "\${IFNAME}" scan 2>/dev/null | awk '
    function band_of(c) { return (c+0 > 14) ? "5G" : "2.4G" }
    function flush_bss() {
        if (bssid=="" || ssid=="") return
        ch=""
        if (freq+0>=2412 && freq+0<=2484) ch=int((freq+0-2407)/5)
        else if (freq+0>=5000) ch=int((freq+0-5000)/5)
        printf "  %-30s %-5s %-10s %-6s %-19s %s\n", ssid, band_of(ch), sig, ch, bssid, enc
    }
    BEGIN { bssid=""; ssid=""; sig="?"; ch="?"; enc="abierta"; freq="" }
    /^BSS /   { flush_bss(); bssid=substr(\$2,1,17); ssid=""; sig="?"; enc="abierta"; freq="" }
    /freq:/   { freq=\$2 }
    /signal:/ { sig=\$2" "\$3 }
    /SSID:/   { ssid=substr(\$0,index(\$0,\$2)); gsub(/^ +| +\$/,"",ssid) }
    /RSN:|WPA Vendor/ { enc="WPA2" }
    /capability:.*Privacy/ { if (enc=="abierta") enc="WEP" }
    END { flush_bss() }
    ' 2>/dev/null
fi

echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Limpiar interfaz temporal
if [ -n "\${TEMP_IF}" ]; then
    iw dev "\${TEMP_IF}" del 2>/dev/null || true
fi
EOF
}

# ---------------------------------------------------------------------------
# Subcomando: scan
# ---------------------------------------------------------------------------
_scan() {
    _check_ssh
    log_step "Escaneando redes WiFi..."
    _do_scan "${_RADIO:-radio0}"
    echo ""
}

# ---------------------------------------------------------------------------
# Subcomando: status
# ---------------------------------------------------------------------------
_status() {
    _check_ssh

    echo ""
    echo "============================================="
    echo " WiFi — Estado de radios e interfaces"
    echo "============================================="

    _ssh sh - << 'REMOTE'
set -eu

echo ""
echo "--- Radios ---"
I=0
while true; do
    RADIO="radio${I}"
    RAW=$(uci -q get wireless.${RADIO}.band 2>/dev/null || \
          uci -q get wireless.${RADIO}.hwmode 2>/dev/null || echo "?")
    case "${RAW}" in
        2g|11g|11b|11bg|11n) BAND="2.4 GHz" ;;
        5g|11a|11ac|11n-5)   BAND="5 GHz"   ;;
        *) BAND="${RAW}" ;;
    esac
    DISABLED=$(uci -q get wireless.${RADIO}.disabled 2>/dev/null || echo "0")
    CHANNEL=$(uci -q get wireless.${RADIO}.channel 2>/dev/null || echo "auto")
    STATE="habilitado"
    [ "$DISABLED" = "1" ] && STATE="DESHABILITADO"
    echo "  ${RADIO}  banda=${BAND}  canal=${CHANNEL}  estado=${STATE}"
    I=$((I+1))
    uci -q get wireless.radio${I}.band >/dev/null 2>&1 || break
done

echo ""
echo "--- Interfaces WiFi (UCI) ---"
I=0
while true; do
    DEV=$(uci -q get wireless.@wifi-iface[$I].device 2>/dev/null) || break
    MODE=$(uci -q get wireless.@wifi-iface[$I].mode 2>/dev/null || echo "ap")
    SSID=$(uci -q get wireless.@wifi-iface[$I].ssid 2>/dev/null || echo "(sin SSID)")
    ENC=$(uci -q get wireless.@wifi-iface[$I].encryption 2>/dev/null || echo "none")
    DIS=$(uci -q get wireless.@wifi-iface[$I].disabled 2>/dev/null || echo "0")
    NET=$(uci -q get wireless.@wifi-iface[$I].network 2>/dev/null || echo "")
    STATE="activa"
    [ "$DIS" = "1" ] && STATE="deshabilitada"
    printf "  [%d] dev=%-8s mode=%-6s ssid=%-25s enc=%-8s net=%-8s %s\n" \
           "$I" "$DEV" "$MODE" "$SSID" "$ENC" "$NET" "$STATE"
    I=$((I+1))
done

echo ""
echo "--- Estado del sistema (iw dev) ---"
iw dev 2>/dev/null || echo "  (iw no disponible)"

echo ""
echo "--- Clientes conectados ---"
for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
    COUNT=$(iw dev $iface station dump 2>/dev/null | grep -c "Station" || echo 0)
    [ "$COUNT" -gt 0 ] && echo "  ${iface}: ${COUNT} cliente(s)" || echo "  ${iface}: sin clientes"
done
REMOTE
}

# ---------------------------------------------------------------------------
# Subcomando: list
# ---------------------------------------------------------------------------
_list() {
    _check_ssh
    echo ""
    _ssh "uci show wireless"
}

# ---------------------------------------------------------------------------
# Subcomando: disconnect
# ---------------------------------------------------------------------------
_disconnect() {
    local radio="${_RADIO:-}"

    _check_ssh

    echo "============================================="
    echo " Desconectar cliente WiFi"
    echo "============================================="

    _ssh sh - << EOF
set -eu
TARGET_RADIO="${radio}"

# Buscar todas las interfaces STA (cliente)
found=0
I=0
while true; do
    DEV=\$(uci -q get wireless.@wifi-iface[\$I].device 2>/dev/null) || break
    MODE=\$(uci -q get wireless.@wifi-iface[\$I].mode 2>/dev/null || echo "ap")
    if [ "\$MODE" = "sta" ]; then
        # Si se especificó radio, filtrar por él; si no, eliminar todos los STA
        if [ -z "\$TARGET_RADIO" ] || [ "\$DEV" = "\$TARGET_RADIO" ]; then
            SSID=\$(uci -q get wireless.@wifi-iface[\$I].ssid 2>/dev/null || echo "?")
            echo "  Eliminando STA [\$I]: \$DEV → '\$SSID'"
            uci delete wireless.@wifi-iface[\$I]
            found=\$((found+1))
            # No incrementar I: tras borrar, los índices se recorren
            continue
        fi
    fi
    I=\$((I+1))
done
uci commit wireless

# Eliminar interfaz de red wwan
if uci -q get network.wwan >/dev/null 2>&1; then
    echo "  Eliminando interfaz de red wwan..."
    uci delete network.wwan
    uci commit network
fi

# Quitar wwan de la zona WAN del firewall
Z=0
while true; do
    NAME=\$(uci -q get firewall.@zone[\$Z].name 2>/dev/null) || break
    if [ "\$NAME" = "wan" ]; then
        NETS=\$(uci -q get firewall.@zone[\$Z].network 2>/dev/null || echo "")
        if echo "\$NETS" | grep -qw "wwan"; then
            uci del_list firewall.@zone[\$Z].network='wwan' 2>/dev/null || true
            uci commit firewall
            echo "  Eliminado wwan de zona firewall wan"
        fi
        break
    fi
    Z=\$((Z+1))
done

if [ "\$found" -eq 0 ]; then
    echo "  Sin interfaces cliente WiFi activas."
else
    echo ""
    wifi reload 2>/dev/null || true
    /etc/init.d/network restart 2>/dev/null || true
    echo "✅ Desconectado: \$found interfaz(ces) STA eliminada(s)"
fi
EOF
}

# ---------------------------------------------------------------------------
# Subcomando: enable / disable
# ---------------------------------------------------------------------------
_toggle() {
    local action="$1"
    local radio="${_RADIO}"

    if [ -z "${radio}" ]; then
        log_error "--radio requerido para ${action} (ej: --radio radio0)"
        exit 1
    fi

    _check_ssh

    local val="0"
    [ "${action}" = "disable" ] && val="1"

    _ssh sh - << EOF
set -eu
RADIO="${radio}"
VAL="${val}"
ACTION="${action}"

uci -q get wireless.\$RADIO.disabled >/dev/null 2>&1 || {
    echo "Radio no encontrado: \$RADIO"
    exit 1
}
uci set wireless.\$RADIO.disabled="\$VAL"
uci commit wireless
wifi reload 2>/dev/null || wifi
echo "✅ Radio \$RADIO \${ACTION}d"
EOF

    local msg="✅ ${radio} habilitado"
    [ "${action}" = "disable" ] && msg="✅ ${radio} deshabilitado"
    log_info "${msg}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    case "${_SUBCMD}" in
        ap)         _ap ;;
        client)     _client ;;
        disconnect) _disconnect ;;
        scan)       _scan ;;
        status)     _status ;;
        list)       _list ;;
        enable)     _toggle "enable" ;;
        disable)    _toggle "disable" ;;
    esac
}

main
