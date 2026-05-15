#!/usr/bin/env bash
# ============================================================================
# generate.sh — Generate config files from templates + secrets
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

ENV="${1:-prod}"
SECRETS_FILE="/tmp/secrets-${ENV}.yaml"
OVERLAY_DIR="${REPO_ROOT}/config/overlay/${ENV}"

# ---------------------------------------------------------------------------
replace_template() {
    local template="$1"
    local output="$2"

    if [ ! -f "${template}" ]; then
        log_error "Template not found: ${template}"
        return 1
    fi

    cp "${template}" "${output}"

    while IFS='=' read -r key value; do
        if [ -n "${key}" ] && [ -n "${value}" ]; then
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
main() {
    if [ ! -f "${SECRETS_FILE}" ]; then
        log_error "${SECRETS_FILE} not found"
        echo "  Run: just decrypt-secrets ${ENV}"
        exit 1
    fi

    if ! command -v yq &>/dev/null; then
        log_error "yq is not installed. Run: brew install yq"
        exit 1
    fi

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
    log_info "Config generated at: ${OVERLAY_DIR}"
    echo ""
    echo "To build with this overlay:"
    echo "  just build-prod"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
