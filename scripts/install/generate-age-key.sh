#!/usr/bin/env bash
# ============================================================================
# generate-age-key.sh — Generar clave age única del proyecto (si no existe)
# ============================================================================
set -euo pipefail

KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"

if [ -f "$KEYFILE" ]; then
    echo "ℹ️  Clave age ya existe: $KEYFILE"
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

if ! command -v age-keygen &>/dev/null; then
    echo "❌ Error: 'age-keygen' no encontrado en PATH"
    echo "   Buscando: age-keygen (necesario para generar clave age)"
    echo "   Solución: just install-tools"
    exit 1
fi

AGEPATH="$(command -v age-keygen)"
if file "${AGEPATH}" 2>/dev/null | grep -qi 'text'; then
    echo "❌ Error: 'age-keygen' en ${AGEPATH} no es un binario válido"
    echo "   Detectado: archivo de texto/HTML (probable error 404 de GitHub)"
    echo "   Solución: just install-tools force=true"
    exit 1
fi

mkdir -p "$(dirname "$KEYFILE")"
age-keygen -o "$KEYFILE"
chmod 600 "$KEYFILE"
echo "✅ Clave privada generada: $KEYFILE"
echo "⚠️  GUARDA ESTE ARCHIVO EN UN LUGAR SEGURO (NO en el repo)"

grep -oE 'age1[a-z0-9]+' "$KEYFILE" | head -1 > .age-pubkey.txt
chmod 644 .age-pubkey.txt
echo "✅ Clave pública guardada en .age-pubkey.txt (committeable)"
