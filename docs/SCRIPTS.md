# Referencia de Scripts

Todos los scripts están organizados en `scripts/` por responsabilidad. Los módulos en `commons/` son reutilizables por otros scripts mediante `source`.

## Estructura

```
scripts/
├── commons/                    # Utilidades compartidas (sourceable)
│   ├── logging.sh              # log_info, log_warn, log_error, log_step
│   ├── utils.sh                # find_builder, parse_packages, get_repo_root
│   ├── toml-parser.sh          # parse_packages_toml, convert_toml_to_txt
│   └── toml_parser.py          # Parser TOML (invocado por toml-parser.sh)
├── deps/                       # Verificación de dependencias
│   └── check-tools.sh          # Verifica just, make, sops, age, yq, python3, etc.
├── git/                        # Hooks y verificaciones de git
│   ├── check-secrets-encrypted.sh  # Pre-commit: bloquea secrets sin encriptar
│   └── setup-hooks.sh          # Configura .githooks como directorio de hooks
├── install/                    # Preparación del entorno
│   ├── setup-env.sh            # Descarga y extrae el Image Builder
│   ├── validate-tools.sh       # Valida herramientas requeridas con versiones
│   ├── ensure-secrets.sh       # Verifica/desencripta secrets para el build
│   └── generate-password-hash.sh # Genera hash SHA-512 e inyecta en secrets
├── build/                      # Compilación y verificación
│   ├── openwrt.sh              # Orquestador principal de compilación
│   ├── compile.sh              # Lógica de `make image`
│   ├── update.sh               # Actualiza firmware via SSH + sysupgrade
│   ├── verify.sh               # Validación de imagen compilada
│   └── convert-toml-packages.sh # Conversor TOML → TXT (standalone)
└── templates/                  # Generación de configuraciones
    └── generate.sh             # Reemplaza placeholders en templates con secrets
```

## Wrapper raíz

`build-openwrt.sh` en la raíz es un wrapper que redirige a `scripts/build/openwrt.sh`:

```bash
#!/usr/bin/env bash
exec "$(dirname "$0")/scripts/build/openwrt.sh" "$@"
```

## Scripts en detalle

### commons/logging.sh

Funciones de logging reutilizables para todos los scripts:

```bash
source "${SCRIPT_DIR}/../commons/logging.sh"
log_info "Mensaje informativo"
log_warn "Advertencia"
log_error "Error"
log_step "Paso del proceso"
```

### commons/utils.sh

Utilidades compartidas entre scripts de build:

```bash
source "${SCRIPT_DIR}/../commons/utils.sh"
builder=$(find_builder "${BUILDER_DIR}")    # Encuentra Image Builder
packages=$(parse_packages "config/openwrt-packages.txt")  # Parsea paquetes
root=$(get_repo_root)                       # Raíz del repo
```

### commons/toml-parser.sh

Parser de configuración TOML de paquetes. Invoca `toml_parser.py` internamente:

```bash
source "${SCRIPT_DIR}/../commons/toml-parser.sh"

# Parsear TOML y obtener lista de paquetes
packages=$(parse_packages_toml "config/openwrt-packages.toml")

# Convertir TOML → formato .txt heredado
convert_toml_to_txt "config/openwrt-packages.toml" "config/openwrt-packages.txt"
```

### deps/check-tools.sh

Verifica herramientas requeridas. Útil para CI y setup:

```bash
./scripts/deps/check-tools.sh
# ✓ just ✓ make ✓ sops ✓ age ✓ shellcheck ✓ wget ✓ yq ✓ python3
```

### git/check-secrets-encrypted.sh

Hook pre-commit que bloquea el commit si hay `secrets.enc.yaml` sin encriptar (sin metadata sops). Configurado automáticamente por `just setup-hooks`.

### git/setup-hooks.sh

Configura `.githooks/` como directorio de hooks de git:

```bash
just setup-hooks    # Equivalente a git config core.hooksPath .githooks
```

### install/validate-tools.sh

Valida todas las herramientas requeridas e imprime sus versiones:

```bash
just validate-tools
# ✅ just 1.36.0
# ✅ sops — sops 3.9.4
# ✅ age — age v1.2.1
# ✅ yq — yq (https://github.com/mikefarah/yq/) version v4.44.3
# ❌ shellcheck (NO INSTALADA)
```

### install/ensure-secrets.sh

Verifica disponibilidad de secrets para el build. Llamado por `build-dev` y `build-prod`:

- Si no existe clave age → la crea y guía al usuario
- Si existe pero no puede desencriptar → indica `just reinit-secrets <ENV>`
- Si desencripta exitosamente → reporta campos vacíos y exporta variables

```bash
source scripts/install/ensure-secrets.sh prod   # Sourced o ejecutado
```

### install/generate-password-hash.sh

Pide contraseña root en modo oculto, genera hash SHA-512-crypt (`$6$...`) e inyecta directamente en `secrets.enc.yaml` sin mostrar el hash en pantalla:

```bash
just create-password prod   # Llamado por la recipe
```

Detecta automáticamente el método disponible: `openssl passwd -6` (macOS con Homebrew OpenSSL, Linux) o `python3 crypt`.

### install/setup-env.sh

Descarga y extrae el Image Builder de OpenWRT:

```bash
./scripts/install/setup-env.sh
# Descarga openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst
# Extrae en openwrt-builder/
```

### build/openwrt.sh

Orquestador principal. Detecta `config/openwrt-packages.toml` y auto-genera `.txt`. Reemplaza al antiguo `build-openwrt.sh` monolítico:

```bash
./scripts/build/openwrt.sh --builder openwrt-builder/*/
./scripts/build/openwrt.sh --profile tplink_tl-wdr3600-v1 --packages config/openwrt-packages.txt
```

### build/update.sh

Actualiza el firmware del router via SSH y `sysupgrade`. Llamado por `just update` y `just update-force`:

```bash
# Actualizar manteniendo configuración (IP desde .env.public)
scripts/build/update.sh --env prod

# Actualizar con IP distinta
scripts/build/update.sh --ip 192.168.0.1

# Borrar configuración del router al actualizar
scripts/build/update.sh --force

# Ver todas las opciones
scripts/build/update.sh --help
```

Flujo interno: verifica SSH → transfiere `.bin` via SCP → ejecuta `sysupgrade -v` (o `-n -v` con `--force`).

### build/compile.sh

Lógica de compilación aislada — solo ejecuta `make image`:

```bash
source "${SCRIPT_DIR}/../commons/logging.sh"
compile_image "/path/to/builder" "dropbear dnsmasq ..." "tplink_tl-wdr3600-v1"
```

### build/convert-toml-packages.sh

Conversor standalone: lee `config/openwrt-packages.toml` y genera el `.txt` heredado.

```bash
# Output a stdout (lista separada por espacios)
./scripts/build/convert-toml-packages.sh

# Generar archivo .txt
./scripts/build/convert-toml-packages.sh --output config/openwrt-packages.txt
```

### build/verify.sh

Valida la imagen compilada (tamaño, checksums):

```bash
./scripts/build/verify.sh openwrt-builder/*/bin/targets/ath79/generic
```

### templates/generate.sh

Genera archivos de configuración desde templates + secrets:

```bash
just decrypt-secrets prod       # Primero: desencriptar secrets
./scripts/templates/generate.sh prod  # Luego: generar configs en config/overlay/prod/
```

## Convenciones

- **Shebang**: `#!/usr/bin/env bash`
- **Error handling**: `set -euo pipefail`
- **Source scripts**: Cada script importa `logging.sh` con path relativo a su ubicación
- **Ejecución standalone**: Todos los scripts pueden ejecutarse directamente o ser sourceados

## Validación

```bash
just validate          # shellcheck en todos los scripts
make shellcheck        # Equivalente directo
```
