#!/usr/bin/env bash
# ============================================================================
# create-environments.sh — Crear estructura environments/ y secrets vacíos
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"
source "${SCRIPT_DIR}/../commons/secrets.sh"

O_VERSION="25.12.5"

check_sops_binary || exit 1

mkdir -p environments/{dev,prod}

if [ ! -f environments/dev/.env.public ]; then
    printf '%s\n' \
        '# Variables públicas para entorno DEV' \
        '# Estos valores son seguros de commitear' \
        '' \
        'ENV=dev' \
        "OPENWRT_VERSION=${O_VERSION}" \
        'TARGET=ath79' \
        'SUBTARGET=generic' \
        'PROFILE=tplink_tl-wdr3600-v1' \
        'ROUTER_IP=192.168.1.1' \
        'SSH_PORT=22' \
        '' \
        '# Red WiFi (nombres de red — no contraseñas)' \
        'WIFI_SSID_24=TestWiFi24' \
        'WIFI_SSID_5=TestWiFi5G' \
        > environments/dev/.env.public
    echo "✅ environments/dev/.env.public creado"
fi

if [ ! -f environments/prod/.env.public ]; then
    printf '%s\n' \
        '# Variables públicas para entorno PROD' \
        '# Estos valores son seguros de commitear' \
        '' \
        'ENV=prod' \
        "OPENWRT_VERSION=${O_VERSION}" \
        'TARGET=ath79' \
        'SUBTARGET=generic' \
        'PROFILE=tplink_tl-wdr3600-v1' \
        'ROUTER_IP=192.168.1.1' \
        'SSH_PORT=22' \
        '' \
        '# Red WiFi (nombres de red — no contraseñas)' \
        'WIFI_SSID_24=' \
        'WIFI_SSID_5=' \
        > environments/prod/.env.public
    echo "✅ environments/prod/.env.public creado"
fi

PUBKEY=$(cat .age-pubkey.txt 2>/dev/null || echo "")
if [ -z "$PUBKEY" ]; then
    echo "⚠️  No se encontró .age-pubkey.txt. Ejecuta: just generate-age-key"
    exit 1
fi

export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"
for env in dev prod; do
    SECRETS_FILE="environments/${env}/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
        printf 'WIFI_KEY_24: ""\nWIFI_KEY_5: ""\nWIREGUARD_PRIVATE_KEY: ""\nDROPBEAR_RSA_HOST_KEY: ""\nROOT_PASSWORD_HASH: ""\n' > "$SECRETS_FILE"
        sops --config .sops.yaml --encrypt --in-place "$SECRETS_FILE"
        echo "✅ environments/${env}/secrets.enc.yaml creado y encriptado"
        echo "   Llena tus datos con: just edit-secrets ${env}"
    fi
done
