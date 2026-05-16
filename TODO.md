# TODO

_Actualizado: 2026-05-15 | Agente: @build_

## Active

_No hay tareas activas._

## Context

Proyecto completo integrado en `main`:
- Scripts de compilación OpenWRT para TL-WDR3600
- Build system: Makefile (build) + Justfile (orquestador, 14 recipes)
- Secrets: sops + age con clave única por proyecto
- Scripts modulares: `scripts/{commons,deps,install,build,templates}/`
- `.gitignore` multinivel contra filtrado de secrets

**Todos los PRs mergeados, ramas locales limpias, worktrees eliminados.**

## History

| Date | Plan | Status |
|------|------|--------|
| 2026-05-15 | tasks/build-openwrt-tp-link/TASKS.md | completed (PR #1) |
| 2026-05-15 | Makefile + Justfile + sops/age | completed (PR #2) |
| 2026-05-15 | tasks/organize-scripts/TASKS.md | completed (PR #3) |
