#!/usr/bin/env bash
# ============================================================================
# generate.sh — Generate config files from templates + secrets
#
# Uso:
#   generate.sh <ENV> [<secrets_file>]
#
# Si no se especifica secrets_file, llama a ensure-secrets.sh para obtener uno
# y limpia el temporal al salir.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"
source "${SCRIPT_DIR}/../commons/secrets.sh"

ENV="${1:-prod}"
SECRETS_FILE="${2:-}"
VARIANT="${3:-safe}"
PUBLIC_ENV_FILE="${REPO_ROOT}/environments/${ENV}/.env.public"
OVERLAY_DIR="${REPO_ROOT}/config/overlay/${ENV}/${VARIANT}"
_SECRETS_OWNED=false

# ---------------------------------------------------------------------------
replace_template() {
    local template="$1"
    local output="$2"

    if [ ! -f "${template}" ]; then
        log_error "Template not found: ${template}"
        return 1
    fi

    cp "${template}" "${output}"

    local placeholder key value skip_output=false
    while IFS= read -r placeholder; do
        key="${placeholder#\{\{}"
        key="${key%\}\}}"

        if [ -n "${!key+x}" ]; then
            value="${!key}"
        elif yq eval "has(\"${key}\")" "${SECRETS_FILE}" | grep -qx 'true'; then
            value=$(yq eval -r ".\"${key}\" // \"\"" "${SECRETS_FILE}")
        else
            log_error "Missing value for placeholder ${placeholder}"
            return 1
        fi

        if [ -z "${value}" ]; then
            log_warn "${placeholder} is empty; skipping ${output}"
            skip_output=true
        fi

        sed -i '' "s|${placeholder}|${value}|g" "${output}" 2>/dev/null || \
            sed -i "s|${placeholder}|${value}|g" "${output}"
        echo "  ✓ ${placeholder} → **** (${#value} chars)"
    done < <(grep -ho '{{[A-Z0-9_][A-Z0-9_]*}}' "${template}" | sort -u)

    if "${skip_output}"; then
        rm -f "${output}"
        return 0
    fi

    if grep -q '{{[A-Z0-9_][A-Z0-9_]*}}' "${output}"; then
        log_error "Unresolved placeholders remain in: ${output}"
        return 1
    fi

    echo "  → ${output}"
}

# ---------------------------------------------------------------------------
_validate_output() {
    local errors=0
    log_step "Validating generated config..."

    local f
    while IFS= read -r -d '' f; do
        if grep -q '{{[A-Z0-9_][A-Z0-9_]*}}' "${f}"; then
            log_error "Unresolved placeholder in: ${f}"
            grep -n '{{[A-Z0-9_][A-Z0-9_]*}}' "${f}" | while read -r line; do
                echo "  ${line}"
            done
            errors=1
        fi
    done < <(find "${OVERLAY_DIR}" -type f -print0 2>/dev/null || true)

    if [ -f "${OVERLAY_DIR}/etc/wireguard/wg0.conf" ]; then
        if ! grep -q '^\[Interface\]' "${OVERLAY_DIR}/etc/wireguard/wg0.conf"; then
            log_warn "wg0.conf missing [Interface] section"
        fi
    fi

    if [ -f "${OVERLAY_DIR}/etc/config/wireless" ]; then
        if ! grep -q 'wifi-iface' "${OVERLAY_DIR}/etc/config/wireless"; then
            log_warn "wireless config has no wifi-iface blocks (Wi-Fi may not be configured)"
        fi
    fi

    if [ "${errors}" -ne 0 ]; then
        log_error "Validation failed. Remove overlay and re-run with correct secrets."
        rm -rf "${OVERLAY_DIR}"
        exit 1
    fi
    log_info "✓ Config validation passed"
}

# ---------------------------------------------------------------------------
main() {
    case "${VARIANT}" in safe|legacy) ;; *) log_error "Unknown image variant: ${VARIANT} (use safe or legacy)"; exit 2 ;; esac
    if [ ! -f "${PUBLIC_ENV_FILE}" ]; then
        log_error "${PUBLIC_ENV_FILE} not found"
        echo "  Run: just create-environments"
        exit 1
    fi

    if ! command -v yq &>/dev/null; then
        log_error "yq is not installed. Run: brew install yq"
        exit 1
    fi

    if [ -z "${SECRETS_FILE}" ]; then
        SECRETS_FILE=$(decrypt_secrets "${ENV}") || exit 1
        _SECRETS_OWNED=true
    fi
    trap '[[ "${_SECRETS_OWNED}" == "true" ]] && cleanup_secrets' EXIT

    set -a
    # shellcheck disable=SC1090
    source "${PUBLIC_ENV_FILE}"
    set +a
    WIFI_SAFE_SSID="${WIFI_SAFE_SSID:-}"
    export WIFI_SAFE_SSID

    log_step "Generating config for environment: ${ENV}"

    mkdir -p "${OVERLAY_DIR}/etc/dropbear"
    mkdir -p "${OVERLAY_DIR}/etc/wireguard"
    mkdir -p "${OVERLAY_DIR}/etc/config"
    mkdir -p "${OVERLAY_DIR}/etc/uci-defaults"
    mkdir -p "${OVERLAY_DIR}/etc/hotplug.d/block"
    mkdir -p "${OVERLAY_DIR}/etc/init.d"
    mkdir -p "${OVERLAY_DIR}/etc"
    mkdir -p "${OVERLAY_DIR}/usr/sbin"

    if [[ "${VARIANT}" == "safe" && "${ENV}" == "prod" ]]; then
        # Production fallback credentials are mandatory: the router must be
        # reachable and protected even when no USB profile is available.
        for required in WIFI_SAFE_SSID ROOT_PASSWORD_HASH WIFI_SAFE_KEY; do
            value="${!required:-}"
            if [[ "${required}" != WIFI_SAFE_SSID ]]; then
                value="$(yq eval -r ".${required} // \"\"" "${SECRETS_FILE}")"
            fi
            if [[ "${required}" == WIFI_SAFE_KEY ]]; then
                WIFI_SAFE_KEY="${value}"
            fi
            if [ -z "${value}" ]; then
                log_error "${required} is required for the production safe-boot configuration"
                exit 1
            fi
        done
        if [[ ! "${WIFI_SAFE_SSID}" =~ ^[A-Za-z0-9_@%+=:,./-]{1,32}$ ]]; then
            log_error "WIFI_SAFE_SSID must be 1-32 characters from A-Z, a-z, 0-9, _@%+=:,./-"
            exit 1
        fi
        if [[ ! "${WIFI_SAFE_KEY}" =~ ^[A-Za-z0-9_@%+=:,./-]{8,63}$ ]]; then
            log_error "WIFI_SAFE_KEY must be 8-63 characters from A-Z, a-z, 0-9, _@%+=:,./-"
            exit 1
        fi
        export WIFI_SAFE_KEY
    elif [[ "${VARIANT}" == "safe" ]]; then
        WIFI_SAFE_KEY="$(yq eval -r '.WIFI_SAFE_KEY // ""' "${SECRETS_FILE}")"
        ROOT_PASSWORD_HASH="$(yq eval -r '.ROOT_PASSWORD_HASH // ""' "${SECRETS_FILE}")"
        export WIFI_SAFE_KEY ROOT_PASSWORD_HASH
    elif [[ "${VARIANT}" == "legacy" && "${ENV}" == "prod" ]]; then
        # Refuse to silently produce a legacy image without its two APs.
        for required in WIFI_SSID_24 WIFI_SSID_5; do
            value="${!required:-}"
            if [[ ! "${value}" =~ ^[A-Za-z0-9_@%+=:,./-]{1,32}$ ]]; then
                log_error "${required} must be 1-32 characters from A-Z, a-z, 0-9, _@%+=:,./- for the production legacy image"
                exit 1
            fi
        done
        for required in WIFI_KEY_24 WIFI_KEY_5; do
            value="$(yq eval -r ".${required} // \"\"" "${SECRETS_FILE}")"
            if [[ ! "${value}" =~ ^[A-Za-z0-9_@%+=:,./-]{8,63}$ ]]; then
                log_error "${required} must be 8-63 characters from A-Z, a-z, 0-9, _@%+=:,./- for the production legacy image"
                exit 1
            fi
        done
    fi

    if [[ "${VARIANT}" == "safe" ]]; then
        # The verification key is public and checked into the environment folder.
        PROFILE_PUBKEY="${REPO_ROOT}/environments/${ENV}/profile-signing.pub"
        if [ -f "${PROFILE_PUBKEY}" ]; then
            cp "${PROFILE_PUBKEY}" "${OVERLAY_DIR}/etc/router-profile.pub"
        elif [[ "${ENV}" == "prod" ]]; then
            log_error "Missing ${PROFILE_PUBKEY}; create a signing key with: just profile-keygen prod"
            exit 1
        fi
    fi

    replace_template "${REPO_ROOT}/templates/etc/dropbear/dropbear_rsa_host_key.template" \
                     "${OVERLAY_DIR}/etc/dropbear/dropbear_rsa_host_key"

    replace_template "${REPO_ROOT}/templates/etc/wireguard/wg0.conf.template" \
                     "${OVERLAY_DIR}/etc/wireguard/wg0.conf"

    if [[ "${VARIANT}" == "legacy" ]]; then
        WIRELESS_TEMPLATE="${REPO_ROOT}/templates/variants/legacy/etc/config/wireless.template"
    else
        WIRELESS_TEMPLATE="${REPO_ROOT}/templates/etc/config/wireless.template"
    fi
    replace_template "${WIRELESS_TEMPLATE}" \
                     "${OVERLAY_DIR}/etc/config/wireless"

    if [[ "${VARIANT}" == "safe" ]]; then
        replace_template "${REPO_ROOT}/templates/etc/uci-defaults/10-root-password.template" \
                         "${OVERLAY_DIR}/etc/uci-defaults/10-root-password"
        cp "${REPO_ROOT}/templates/usr/sbin/router-profile" "${OVERLAY_DIR}/usr/sbin/router-profile"
        cp "${REPO_ROOT}/templates/etc/init.d/router-profile" "${OVERLAY_DIR}/etc/init.d/router-profile"
        cp "${REPO_ROOT}/templates/etc/init.d/router-agent-profile" "${OVERLAY_DIR}/etc/init.d/router-agent-profile"
        cp "${REPO_ROOT}/templates/etc/hotplug.d/block/90-router-profile" "${OVERLAY_DIR}/etc/hotplug.d/block/90-router-profile"
        chmod 755 "${OVERLAY_DIR}/usr/sbin/router-profile" "${OVERLAY_DIR}/etc/init.d/router-profile" \
                  "${OVERLAY_DIR}/etc/init.d/router-agent-profile" \
                  "${OVERLAY_DIR}/etc/hotplug.d/block/90-router-profile" "${OVERLAY_DIR}/etc/uci-defaults/10-root-password"
    fi

    echo ""
    _validate_output
    log_info "Config generated at: ${OVERLAY_DIR}"
    echo ""
    echo "To build with this overlay:"
    echo "  just build-${ENV} (safe variant)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
