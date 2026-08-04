#!/usr/bin/env bash
# ============================================================================
# setup-env-wrapper.sh — Load env vars and dispatch to setup-env.sh
# ============================================================================
set -euo pipefail

ENV="${1:-prod}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENV_FILE="${REPO_ROOT}/environments/${ENV}/.env.public"
if [ ! -f "${ENV_FILE}" ]; then
    echo "❌ No se encontró: ${ENV_FILE}"
    echo "   Solución: just create-environments"
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

export OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
export TARGET="${TARGET:-ath79}"
export SUBTARGET="${SUBTARGET:-generic}"

echo "=== Descargando Image Builder ==="
echo "   Versión: ${OPENWRT_VERSION} — Target: ${TARGET}/${SUBTARGET}"
echo ""

exec "${SCRIPT_DIR}/setup-env.sh"
