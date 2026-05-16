#!/usr/bin/env bash
# ============================================================================
# setup-hooks.sh — Configurar .githooks como directorio de hooks de git
# ============================================================================
# Idempotente: puede ejecutarse múltiples veces sin efectos secundarios.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "${SCRIPT_DIR}/../commons/logging.sh"

HOOKS_DIR="${REPO_ROOT}/.githooks"

# ── Verificar que estamos en un repo git ──────────────────────────────────
if ! git -C "$REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    log_error "No se encontró un repositorio git en: $REPO_ROOT"
    exit 1
fi

# ── Crear .githooks/ si no existe ─────────────────────────────────────────
if [ ! -d "$HOOKS_DIR" ]; then
    mkdir -p "$HOOKS_DIR"
    log_info "Directorio creado: .githooks/"
fi

# ── Configurar git para usar .githooks/ ───────────────────────────────────
CURRENT_HOOKS_PATH=$(git -C "$REPO_ROOT" config --local core.hooksPath 2>/dev/null || echo "")

if [ "$CURRENT_HOOKS_PATH" = ".githooks" ]; then
    log_info "Git hooks ya configurados: core.hooksPath = .githooks"
else
    git -C "$REPO_ROOT" config --local core.hooksPath .githooks
    log_info "Git configurado: core.hooksPath = .githooks"
fi

# ── Dar permisos de ejecución a todos los hooks ───────────────────────────
HOOKS_UPDATED=0
for hook in "${HOOKS_DIR}"/*; do
    [ -f "$hook" ] || continue
    if [ ! -x "$hook" ]; then
        chmod +x "$hook"
        log_info "  chmod +x $(basename "$hook")"
        HOOKS_UPDATED=1
    fi
done

# ── Dar permisos de ejecución a scripts/git/*.sh ─────────────────────────
GIT_SCRIPTS_DIR="${REPO_ROOT}/scripts/git"
if [ -d "$GIT_SCRIPTS_DIR" ]; then
    for script in "${GIT_SCRIPTS_DIR}"/*.sh; do
        [ -f "$script" ] || continue
        if [ ! -x "$script" ]; then
            chmod +x "$script"
            log_info "  chmod +x scripts/git/$(basename "$script")"
            HOOKS_UPDATED=1
        fi
    done
fi

if [ "$HOOKS_UPDATED" -eq 0 ]; then
    log_info "Todos los hooks ya tienen permisos correctos."
fi

# ── Resumen ────────────────────────────────────────────────────────────────
echo ""
log_info "Git hooks activos en .githooks/:"
for hook in "${HOOKS_DIR}"/*; do
    [ -f "$hook" ] && echo "   - $(basename "$hook")"
done

echo ""
log_info "Scripts de pre-commit en scripts/git/:"
for script in "${GIT_SCRIPTS_DIR}"/*.sh; do
    [ -f "$script" ] && echo "   - $(basename "$script")"
done

echo ""
log_info "Setup de git hooks completado. ✅"
