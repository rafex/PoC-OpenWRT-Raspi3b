#!/usr/bin/env bash
# ============================================================================
# generate-config.sh — Genera archivos de configuración desde templates + secrets
# ============================================================================
# Uso: ./scripts/generate-config.sh <env>
# Ej:   ./scripts/generate-config.sh prod
#
# Requisitos:
#   - secrets desencriptados en /tmp/secrets-<env>.yaml
#     (ejecutar: just decrypt-secrets <env>)
#   - yq instalado (brew install yq)
#
set -euo pipefail

ENV="${1:-prod}"
SECRETS_FILE="/tmp/secrets-${ENV}.yaml"
OVERLAY_DIR="config/overlay/${ENV}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Verificar requisitos
# ---------------------------------------------------------------------------
if [ ! -f "${SECRETS_FILE}" ]; then
    echo -e "${RED}[ERROR]${NC} ${SECRETS_FILE} no existe"
    echo "  Ejecuta primero: just decrypt-secrets ${ENV}"
    exit 1
fi

if ! command -v yq &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} yq no está instalado"
    echo "  Instalar: brew install yq"
    exit 1
fi

# ---------------------------------------------------------------------------
# Crear directorio overlay
# ---------------------------------------------------------------------------
mkdir -p "${OVERLAY_DIR}/etc/dropbear"
mkdir -p "${OVERLAY_DIR}/etc/wireguard"
mkdir -p "${OVERLAY_DIR}/etc/config"

# ---------------------------------------------------------------------------
# Función: reemplazar placeholders {{VARIABLE}} en template
# ---------------------------------------------------------------------------
replace_template() {
    local template="$1"
    local output="$2"

    if [ ! -f "${template}" ]; then
        echo -e "${RED}[ERROR]${NC} Template no encontrado: ${template}"
        return 1
    fi

    cp "${template}" "${output}"

    # Leer cada clave del archivo YAML y reemplazar {{KEY}} en el output
    while IFS='=' read -r key value; do
        if [ -n "${key}" ] && [ -n "${value}" ]; then
            # Escapar caracteres especiales para sed
            local escaped_value
            escaped_value=$(printf '%s\n' "${value}" | sed 's/[&/\]/\\&/g')
            sed -i.bak "s|{{${key}}}|${escaped_value}|g" "${output}"
            rm -f "${output}.bak"
            echo "  ✓ {{${key}}} → **** (${#value} chars)"
        fi
    done < <(yq eval 'to_entries | .[] | .key + "=" + .value' "${SECRETS_FILE}")

    echo "  → ${output}"
}

# ---------------------------------------------------------------------------
# Generar configuraciones
# ---------------------------------------------------------------------------
echo -e "${GREEN}=== Generando configuración para entorno: ${ENV} ===${NC}"
echo ""

replace_template "templates/etc/dropbear/dropbear_rsa_host_key.template" \
                 "${OVERLAY_DIR}/etc/dropbear/dropbear_rsa_host_key"

replace_template "templates/etc/wireguard/wg0.conf.template" \
                 "${OVERLAY_DIR}/etc/wireguard/wg0.conf"

replace_template "templates/etc/config/wireless.template" \
                 "${OVERLAY_DIR}/etc/config/wireless"

echo ""
echo -e "${GREEN}✅ Configuración generada en: ${OVERLAY_DIR}${NC}"
echo ""
echo "Para compilar con este overlay:"
echo "  just build-prod"
