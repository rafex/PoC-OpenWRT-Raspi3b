#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV="${1:-prod}"
command -v usign >/dev/null || { echo "ERROR: falta usign en el host (instala el paquete usign)." >&2; exit 1; }
case "$ENV" in dev|prod) ;; *) echo "Uso: $0 [dev|prod]" >&2; exit 2 ;; esac

KEY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/poc-openwrt"
PRIVATE_KEY="${KEY_DIR}/profile-signing-${ENV}.key"
PUBLIC_KEY="${ROOT}/environments/${ENV}/profile-signing.pub"
if [ -e "$PRIVATE_KEY" ] || [ -e "$PUBLIC_KEY" ]; then
    echo "ERROR: ya existe la clave privada o pública para $ENV; no se sobrescribirá." >&2
    exit 1
fi
mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"
umask 077
usign -G -p "$PUBLIC_KEY" -s "$PRIVATE_KEY"
chmod 600 "$PRIVATE_KEY"
chmod 644 "$PUBLIC_KEY"
echo "Clave privada: $PRIVATE_KEY (no compartir ni commitear)"
echo "Clave pública: $PUBLIC_KEY (commitear y reconstruir firmware)"
