```toml
artifact_type = "task_file"
initiative    = "organize-scripts"
spec_id       = "SPEC-0003"
owner         = ""
state         = "todo"
```

# TASKS: Organizar scripts y modularizar build-openwrt.sh

> _Estado: 🔄 En construcción — @plan trabajando_
> _Iniciado: 2026-05-15_
> _Tipo: refactor_
> _Repo: MEDIANO (30+ archivos)_

_Este archivo se actualiza progresivamente mientras @plan recopila contexto y construye el plan._

## Plan: Reorganización del código y modularización

**Tipo:** refactor  
**Complejidad estimada:** media  
**Alcance:** Reorganización de scripts, limpieza de basura, mejora de modularidad

### Contexto

El proyecto actual tiene:
- **Directorios basura** en raíz (`-o`, `|`, `~`, `2>&1`, etc.)
- **Scripts dispersos**: `build-openwrt.sh` en raíz, otros en `scripts/` sin estructura
- **Falta de modularidad**: `build-openwrt.sh` es monolítico, no reutiliza funciones

### Archivos afectados

- **Eliminar** (basura):
  - `./-o/`
  - `./|/`
  - `./~/`
  - `./2>&1/`
  - `./public key/`
  - `./{print $3}/`
  - `./awk/`
  - `./cat/`
  - `./grep/`

- **Mover** (reorganizar):
  - `build-openwrt.sh` → `scripts/build/openwrt.sh`
  - `scripts/generate-config.sh` → `scripts/build/generate-config.sh`
  - `scripts/setup-build-env.sh` → `scripts/install/setup-env.sh`
  - `scripts/verify-image.sh` → `scripts/build/verify-image.sh`

- **Crear** (nuevos módulos):
  - `scripts/commons/logging.sh`
  - `scripts/commons/utils.sh`
  - `scripts/deps/check-tools.sh`
  - `scripts/install/setup-env.sh` (refactorizado)
  - `scripts/build/compile.sh`
  - `scripts/build/verify.sh`
  - `scripts/build/openwrt.sh` (refactorizado)
  - `scripts/templates/generate.sh` (refactorizado)

### Estructura propuesta

```
repo/
├── scripts/
│   ├── commons/
│   │   ├── logging.sh       # Funciones log_info, log_error, etc.
│   │   └── utils.sh         # Utilidades (find_builder, etc.)
│   ├── deps/
│   │   └── check-tools.sh   # Verificar herramientas (sops, age, just, make)
│   ├── install/
│   │   └── setup-env.sh     # Descarga y extracción de Image Builder
│   ├── build/
│   │   ├── openwrt.sh       # Orquestador principal (antes build-openwrt.sh)
│   │   ├── compile.sh       # Lógica de compilación
│   │   ├── verify.sh        # Verificación de imagen
│   │   └── generate-config.sh # Generar configs desde templates
│   └── templates/
│       └── generate.sh      # Generación de configs (mover desde build/)
├── justfile                 # Actualizar rutas
├── Makefile                 # Ya correcto
├── build-openwrt.sh         # Script wrapper (calls scripts/build/openwrt.sh)
└── ...
```

### Pasos de implementación

<ToDo>
- [ ] **W0-W2**: Setup worktree + analizar estado actual
- [ ] **W3**: Eliminar directorios basura
- [ ] **W4**: Crear estructura de directorios scripts/*
- [ ] **W5**: Mover scripts a ubicaciones correctas
- [ ] **W6**: Refactor build-openwrt.sh → scripts/build/openwrt.sh
- [ ] **W7**: Crear scripts/commons/logging.sh y utils.sh
- [ ] **W8**: Modularizar lógica en scripts/build/*.sh
- [ ] **W9**: Actualizar justfile con nuevas rutas
- [ ] **W10**: Validar shellcheck en todos los scripts
- [ ] **W11**: Testear flujo completo: just build-dev
- [ ] **W12-W14**: Commit, push, PR
</ToDo>

## Principios de diseño

1. **Responsabilidad única**: Cada script hace UNA cosa bien
2. **Reutilizable**: Funciones en `commons/` son importables
3. **Mantenible**: Estructura clara, nombres descriptivos
4. **Testable**: Scripts pequeños son más fáciles de validar

## Documentación a actualizar

- `README.md`: Actualizar rutas de scripts
- `docs/BUILD_INSTRUCTIONS.md`: Referenciar `scripts/build/` en lugar de raíz
- `AGENTS.md`: Documentar nueva estructura
- `docs/SCRIPTS.md` (nuevo): Descripción de cada script y su propósito

## Criterios de aceptación

- [ ] Sin directorios basura en raíz (`ls -la` solo muestra archivos válidos)
- [ ] Todos los scripts en `scripts/` con permisos 755
- [ ] `build-openwrt.sh` es un wrapper que llama a `scripts/build/openwrt.sh`
- [ ] `just build-dev` funciona completamente
- [ ] `shellcheck` pasa en todos los scripts
- [ ] No hay rutas hardcodeadas (usar variables `SCRIPT_DIR`, etc.)
