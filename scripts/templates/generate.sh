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
PUBLIC_ENV_FILE="${REPO_ROOT}/environments/${ENV}/.env.public"
OVERLAY_DIR="${REPO_ROOT}/config/overlay/${ENV}"
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

    log_step "Generating config for environment: ${ENV}"

    mkdir -p "${OVERLAY_DIR}/etc/dropbear"
    mkdir -p "${OVERLAY_DIR}/etc/wireguard"
    mkdir -p "${OVERLAY_DIR}/etc/config"

    replace_template "${REPO_ROOT}/templates/etc/dropbear/dropbear_rsa_host_key.template" \
                     "${OVERLAY_DIR}/etc/dropbear/dropbear_rsa_host_key"

    replace_template "${REPO_ROOT}/templates/etc/wireguard/wg0.conf.template" \
                     "${OVERLAY_DIR}/etc/wireguard/wg0.conf"

    replace_template "${REPO_ROOT}/templates/etc/config/wireless.template" \
                     "${OVERLAY_DIR}/etc/config/wireless"

    echo ""
    _validate_output
    log_info "Config generated at: ${OVERLAY_DIR}"
    echo ""
    echo "To build with this overlay:"
    echo "  just build-${ENV}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
