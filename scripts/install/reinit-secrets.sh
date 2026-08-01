#!/usr/bin/env bash
# ============================================================================
# reinit-secrets.sh — Re-encriptar secrets con la clave age local
# ============================================================================
set -euo pipefail

ENV="${1:-prod}"
KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"

if [ ! -f "${KEYFILE}" ]; then
    echo "❌ No se encontró clave age: ${KEYFILE}"
    echo "   Solución: just generate-age-key"
    exit 1
fi

PUBKEY=$(grep -oE 'age1[a-z0-9]+' "${KEYFILE}" | head -1)
if [ -z "${PUBKEY}" ]; then
    echo "❌ No se pudo extraer la clave pública de: ${KEYFILE}"
    exit 1
fi

echo "🔑 Clave pública local: ${PUBKEY}"
echo ""
echo "Esto va a:"
echo "  1. Actualizar .age-pubkey.txt con tu clave"
echo "  2. Actualizar .sops.yaml con tu clave"
echo "  3. Eliminar environments/${ENV}/secrets.enc.yaml"
echo "  4. Crear nuevo secrets.enc.yaml vacío encriptado con tu clave"
echo ""
read -r -p "¿Continuar? (s/N) " answer
if [ "${answer,,}" != "s" ] && [ "${answer,,}" != "si" ]; then
    echo "Cancelado."
    exit 1
fi

echo "${PUBKEY}" > .age-pubkey.txt
echo "✅ .age-pubkey.txt actualizado"

printf 'creation_rules:\n  - path_regex: environments/(dev|prod)/secrets\\.enc\\.yaml$\n    key_groups:\n      - age:\n          - %s\n' "${PUBKEY}" > .sops.yaml
echo "✅ .sops.yaml actualizado"

export SOPS_AGE_KEY_FILE="${KEYFILE}"
SECRETS_FILE="environments/${ENV}/secrets.enc.yaml"
rm -f "${SECRETS_FILE}"
printf 'WIFI_KEY_24: ""\nWIFI_KEY_5: ""\nWIREGUARD_PRIVATE_KEY: ""\nDROPBEAR_RSA_HOST_KEY: ""\nROOT_PASSWORD_HASH: ""\n' > "${SECRETS_FILE}"
sops --config .sops.yaml --encrypt --in-place "${SECRETS_FILE}"
echo "✅ ${SECRETS_FILE} re-creado con tu clave"
echo ""
echo "Llena tus secrets con:"
echo "   just edit-secrets ${ENV}"
echo "   just create-password ${ENV}"
