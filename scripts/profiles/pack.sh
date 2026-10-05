#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "Uso: $0 <dev|prod> <profile.conf> <directorio-usb> [backend-ejecutable]" >&2
    exit 2
fi
ENV="$1"; PROFILE="$2"; OUT_DIR="$3"; BACKEND="${4:-}"
case "$ENV" in dev|prod) ;; *) echo "ENV debe ser dev o prod" >&2; exit 2 ;; esac
command -v usign >/dev/null || { echo "ERROR: falta usign en el host." >&2; exit 1; }
[ -f "$PROFILE" ] || { echo "ERROR: no existe $PROFILE" >&2; exit 1; }
[ -z "$BACKEND" ] || [ -x "$BACKEND" ] || { echo "ERROR: backend no ejecutable: $BACKEND" >&2; exit 1; }

KEY="${XDG_CONFIG_HOME:-$HOME/.config}/poc-openwrt/profile-signing-${ENV}.key"
[ -f "$KEY" ] || { echo "ERROR: falta la clave de firma $KEY; ejecuta just profile-keygen $ENV" >&2; exit 1; }
mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/router_profile"
cp "$PROFILE" "$WORK/router_profile/config"
chmod 600 "$WORK/router_profile/config"

# Accept only the UCI section and values consumed by the firmware supervisor.
awk '
  /^config router_profile '\''main'\''$/ { section++; next }
  /^[[:space:]]*option (uplink_mode|ap_ssid|ap_key|uplink_ssid|uplink_key) '\''[A-Za-z0-9_@%+=:,./-]+'\''$/ { next }
  /^[[:space:]]*option portal_enabled '\''[01]'\''$/ { next }
  /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
  { bad=1 }
  END { exit (bad || section != 1) }
' "$PROFILE" || { echo "ERROR: profile.conf no cumple el formato UCI documentado." >&2; exit 1; }
grep -q "option uplink_mode '" "$PROFILE" || { echo "ERROR: falta uplink_mode." >&2; exit 1; }
grep -q "option ap_ssid '" "$PROFILE" || { echo "ERROR: falta ap_ssid." >&2; exit 1; }
grep -q "option ap_key '" "$PROFILE" || { echo "ERROR: falta ap_key." >&2; exit 1; }
if [ -n "$BACKEND" ]; then
    cp "$BACKEND" "$WORK/router_profile/backend"
    chmod 755 "$WORK/router_profile/backend"
    source "$ROOT/scripts/install/ensure-secrets.sh"
    SECRETS_TMP="$(ensure_secrets "$ENV")"
    trap 'cleanup_secrets; rm -rf "$WORK"' EXIT
    agent_key="$(yq eval -r '.CAPTIVE_AGENT_SSH_PRIVATE_KEY // ""' "$SECRETS_TMP")"
    agent_token="$(yq eval -r '.CAPTIVE_AGENT_API_TOKEN // ""' "$SECRETS_TMP")"
    [ -n "$agent_key" ] && [ -n "$agent_token" ] || { echo "ERROR: faltan CAPTIVE_AGENT_SSH_PRIVATE_KEY o CAPTIVE_AGENT_API_TOKEN; ejecuta just router-agent-provision $ENV." >&2; exit 1; }
    known_hosts="$ROOT/environments/$ENV/.router-known-hosts"
    [ -s "$known_hosts" ] || { echo "ERROR: falta $known_hosts; registra/verifica la host key con just router-add-known-host $ENV." >&2; exit 1; }
    printf '%s\n' "$agent_key" > "$WORK/router_profile/agent_key"
    printf '%s\n' "$agent_token" > "$WORK/router_profile/agent_token"
    awk 'NF >= 3 && $1 !~ /^#/ {print "127.0.0.1", $2, $3}' "$known_hosts" > "$WORK/router_profile/agent_known_hosts"
    [ -s "$WORK/router_profile/agent_known_hosts" ] || { echo "ERROR: known_hosts no contiene host keys válidas." >&2; exit 1; }
    chmod 600 "$WORK/router_profile/agent_key" "$WORK/router_profile/agent_token" "$WORK/router_profile/agent_known_hosts"
fi

ARCHIVE="$OUT_DIR/profile.tar.gz"
SIGNATURE="$OUT_DIR/profile.tar.gz.sig"
tar -czf "$ARCHIVE" -C "$WORK" router_profile
usign -S -m "$ARCHIVE" -s "$KEY" -x "$SIGNATURE"
chmod 644 "$ARCHIVE" "$SIGNATURE"
echo "Perfil firmado: $ARCHIVE"
echo "Firma: $SIGNATURE"
echo "USB esperado: ext4 con etiqueta OPENWRT_PROFILE. Las credenciales viajan sin cifrar."
