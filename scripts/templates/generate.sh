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
PUBLIC_ENV_FILE="${REPO_ROOT}/environments/${ENV}/.env.public"
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

        PLACEHOLDER="${placeholder}" VALUE="${value}" perl -0pi -e '
            my $placeholder = $ENV{"PLACEHOLDER"};
            my $value = $ENV{"VALUE"};
            s/\Q$placeholder\E/$value/g;
        ' "${output}"
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
main() {
    if [ ! -f "${SECRETS_FILE}" ]; then
        log_error "${SECRETS_FILE} not found"
        echo "  Run: just decrypt-secrets ${ENV}"
        exit 1
    fi

    if [ ! -f "${PUBLIC_ENV_FILE}" ]; then
        log_error "${PUBLIC_ENV_FILE} not found"
        echo "  Run: just create-environments"
        exit 1
    fi

    if ! command -v yq &>/dev/null; then
        log_error "yq is not installed. Run: brew install yq"
        exit 1
    fi

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
    log_info "Config generated at: ${OVERLAY_DIR}"
    echo ""
    echo "To build with this overlay:"
    echo "  just build-${ENV}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
