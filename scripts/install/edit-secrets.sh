#!/usr/bin/env bash
# ============================================================================
# edit-secrets.sh — Editar secrets del entorno especificado
# ============================================================================
set -euo pipefail

ENV="${1:-prod}"
export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"

if [ -z "${SOPS_EDITOR:-}" ]; then
    CURRENT_EDITOR="${EDITOR:-}"
    if [ -z "${CURRENT_EDITOR}" ] || { [ -z "${DISPLAY:-}" ] && [[ "${CURRENT_EDITOR}" =~ (^|/)(gedit|code|codium|subl|atom)( |$) ]]; }; then
        for editor in nano vim vi; do
            if command -v "${editor}" &>/dev/null; then
                export EDITOR="${editor}"
                break
            fi
        done
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"
source "${SCRIPT_DIR}/../commons/secrets.sh"

check_sops_binary || exit 1
check_age_key "${SOPS_AGE_KEY_FILE}" || exit 1

SECRETS_FILE="environments/${ENV}/secrets.enc.yaml"
if [ ! -f "$SECRETS_FILE" ]; then
    log_error "Archivo de secrets no existe: ${SECRETS_FILE}"
    echo "   Solución: just create-environments"
    exit 1
fi

if ! grep -q 'sops:' "$SECRETS_FILE" && ! python3 -c "import json,sys; d=json.load(open('$SECRETS_FILE')); assert 'sops' in d" 2>/dev/null; then
    echo "⚠️  El archivo no está encriptado. Encriptando antes de editar..."
    sops --encrypt --in-place "$SECRETS_FILE"
    echo "✅ Archivo encriptado. Abriendo editor..."
fi

set +e
sops "$SECRETS_FILE"
status=$?
set -e
if [ "${status}" -eq 200 ]; then
    echo "ℹ️  Secrets sin cambios."
    exit 0
fi
exit "${status}"
