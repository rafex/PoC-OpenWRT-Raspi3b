# Referencia de Scripts

Todos los scripts están organizados en `scripts/` por responsabilidad. Los módulos en `commons/` son reutilizables por otros scripts mediante `source`.

## Estructura

```
scripts/
├── commons/          # Utilidades compartidas (sourceable)
│   ├── logging.sh    # Funciones log_info, log_warn, log_error, log_step
│   ├── utils.sh      # find_builder, parse_packages, get_repo_root
│   ├── toml-parser.sh # parse_packages_toml, convert_toml_to_txt (wrapper Python)
│   └── toml_parser.py # Parser TOML real (invocado por toml-parser.sh)
├── deps/             # Verificación de dependencias
│   └── check-tools.sh # Verifica just, make, sops, age, python3, yq, etc.
├── install/          # Preparación del entorno
│   └── setup-env.sh  # Descarga y extrae el Image Builder
├── build/            # Compilación y verificación
│   ├── openwrt.sh    # Orquestador principal de compilación
│   ├── compile.sh    # Lógica de `make image`
│   ├── verify.sh     # Validación de imagen compilada
│   └── convert-toml-packages.sh # Conversor TOML → TXT (standalone)
└── templates/        # Generación de configuraciones
    └── generate.sh   # Reemplaza placeholders en templates con secrets
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
