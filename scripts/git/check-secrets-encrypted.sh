#!/usr/bin/env bash
# ============================================================================
# check-secrets-encrypted.sh — Pre-commit: detectar secrets sin cifrar
# ============================================================================
# Verifica que todos los archivos secrets.enc.yaml en el índice de git
# estén encriptados con sops (contienen metadata sops) antes de commitear.
# Falla con exit 1 si encuentra algún archivo en texto plano.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../commons/logging.sh"

FAILED=0

# Archivos secrets.enc.yaml que están en el staged area
STAGED_SECRETS=$(git diff --cached --name-only --diff-filter=ACM | grep 'secrets\.enc\.yaml$' || true)

if [ -z "$STAGED_SECRETS" ]; then
    exit 0
fi

log_step "Verificando que los secrets estén encriptados..."

for file in $STAGED_SECRETS; do
    if [ ! -f "$file" ]; then
        continue
    fi

    # Detectar si el archivo tiene metadata sops (JSON o YAML)
    is_encrypted=false

    # Formato JSON: clave "sops" en el objeto raíz
    if python3 -c "import json,sys; d=json.load(open('$file')); assert 'sops' in d" 2>/dev/null; then
        is_encrypted=true
    fi

    # Formato YAML: línea con "sops:" en el archivo
    if grep -q '^sops:' "$file" 2>/dev/null; then
        is_encrypted=true
    fi

    if [ "$is_encrypted" = "true" ]; then
        log_info "  ✅ $file — encriptado"
    else
        log_error "  ❌ $file — NO encriptado (texto plano detectado)"
        log_error "     Ejecuta: SOPS_AGE_KEY_FILE=\"\$HOME/.age/poc-openwrt-privkey.txt\" sops --encrypt --in-place $file"
        log_error "     O usa:   just edit-secrets <env>"
        FAILED=1
    fi
done

if [ "$FAILED" -eq 1 ]; then
    echo ""
    log_error "Commit bloqueado: hay secrets sin cifrar."
    log_error "Encrípta los archivos marcados antes de commitear."
    exit 1
fi

log_info "Todos los secrets están encriptados. ✅"
exit 0
