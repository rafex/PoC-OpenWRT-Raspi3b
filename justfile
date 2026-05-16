# justfile — Único punto de entrada (task manager)
# Orquesta todo: setup, secrets, build, flash.
# Las tareas de build están en Makefile; just las llama, nunca al revés.

# Variables de entorno definidas por recipes (ENV=dev por defecto)

# ─────────────────────────────────────────────────────
# Default: mostrar ayuda
# ─────────────────────────────────────────────────────
default:
    @just --list --unsorted

# ─────────────────────────────────────────────────────
# Setup inicial (ejecutar una sola vez)
# ─────────────────────────────────────────────────────

# setup: Instalar herramientas, generar clave age y crear environments
# force=true: reinstalar herramientas aunque ya existan
setup force="false":
    @echo "=== Setup inicial del proyecto ==="
    just install-tools force={{ force }}
    just generate-age-key
    just create-environments
    just setup-hooks

# install-tools: Verificar herramientas faltantes y ofrecer instalarlas
# force=true: reinstalar aunque la herramienta ya exista
install-tools force="false":
    #!/usr/bin/env bash
    set -euo pipefail
    FORCE="{{ force }}"
    echo "Verificando herramientas..."

    # Determinar qué instalar
    if [ "$FORCE" = "true" ]; then
        echo "(modo force: se reinstalarán todas las herramientas)"
        missing=(just make sops age)
    else
        missing=()
        for tool in just make sops age; do
            if ! command -v "$tool" &>/dev/null; then
                missing+=("$tool")
            fi
        done
        if [ ${#missing[@]} -eq 0 ]; then
            echo "✅ Todas las herramientas instaladas"
            echo "   Usa 'just install-tools force=true' para forzar reinstalación"
            exit 0
        fi
    fi

    echo "A instalar: ${missing[*]}"
    echo ""

    # Construir comandos según SO
    cmds=()
    path_hint=false
    case "$(uname -s)" in
        Darwin)
            cmds+=("brew install ${missing[*]}")
            ;;
        Linux)
            # Normalizar arquitectura: x86_64 → amd64, aarch64 → arm64
            ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
            for tool in "${missing[@]}"; do
                case "$tool" in
                    make)  cmds+=("sudo apt-get install -y make") ;;
                    just)  if [ "$FORCE" = "true" ]; then
                               cmds+=("rm -rf ~/.local/bin/just")
                           fi
                           cmds+=("curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin")
                           path_hint=true ;;
                    sops)  cmds+=("mkdir -p ~/.local/bin")
                           if [ "$FORCE" = "true" ]; then
                               cmds+=("rm -rf ~/.local/bin/sops")
                           fi
                           cmds+=("curl -Lo ~/.local/bin/sops https://github.com/getsops/sops/releases/latest/download/sops.linux.${ARCH}")
                           cmds+=("chmod +x ~/.local/bin/sops")
                           path_hint=true ;;
                     age)  cmds+=("mkdir -p ~/.local/bin")
                           if [ "$FORCE" = "true" ]; then
                               cmds+=("rm -rf ~/.local/bin/age ~/.local/bin/age-keygen")
                           fi
                           cmds+=("AGE_VER=\$(curl -s https://api.github.com/repos/FiloSottile/age/releases/latest | grep -o '\"tag_name\": *\"[^\"]*\"' | cut -d'\"' -f4 | sed 's/^v//')")
                           cmds+=("curl -Lo /tmp/age.tar.gz https://github.com/FiloSottile/age/releases/latest/download/age-v\${AGE_VER}-linux-${ARCH}.tar.gz")
                           cmds+=("tar -xzf /tmp/age.tar.gz --strip-components=1 -C ~/.local/bin")
                           cmds+=("chmod +x ~/.local/bin/age ~/.local/bin/age-keygen")
                           cmds+=("rm /tmp/age.tar.gz")
                           path_hint=true ;;
                esac
            done
            ;;
        *)
            echo "Sistema no reconocido. Instala manualmente:"
            echo "  just:  https://github.com/casey/just#installation"
            echo "  make:  gestor de paquetes de tu sistema"
            echo "  sops:  https://github.com/getsops/sops#download"
            echo "  age:   https://github.com/FiloSottile/age#installation"
            exit 1
            ;;
    esac

    # Mostrar comandos que se ejecutarán
    echo "Se ejecutarán los siguientes comandos:"
    echo "──────────────────────────────────────"
    for cmd in "${cmds[@]}"; do
        echo "  $ $cmd"
    done
    if [ "$path_hint" = true ]; then
        echo ""
        echo "  Nota: asegúrate de tener ~/.local/bin en tu PATH:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
    echo "──────────────────────────────────────"
    echo ""

    # Pedir confirmación
    read -r -p "¿Ejecutar estos comandos ahora? (s/N) " answer
    if [ "${answer,,}" != "s" ] && [ "${answer,,}" != "si" ]; then
        echo "Cancelado. Ejecuta los comandos manualmente y vuelve a intentar."
        exit 1
    fi

    echo ""
    echo "Ejecutando..."
    for cmd in "${cmds[@]}"; do
        echo "  $ $cmd"
        eval "$cmd" || { echo "❌ Falló: $cmd"; exit 1; }
    done

    echo ""
    if [ "$path_hint" = true ]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Re-verificar
    still_missing=()
    for tool in "${missing[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            still_missing+=("$tool")
        fi
    done
    if [ ${#still_missing[@]} -eq 0 ]; then
        echo "✅ Todas las herramientas instaladas correctamente"
        exit 0
    else
        echo "⚠️  Algunas herramientas no se detectan: ${still_missing[*]}"
        echo "   Verifica que ~/.local/bin esté en tu PATH y vuelve a intentar."
        exit 1
    fi

# generate-age-key: Generar clave age única del proyecto (si no existe)
generate-age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"
    if [ -f "$KEYFILE" ]; then
        echo "ℹ️  Clave age ya existe: $KEYFILE"
    else
        mkdir -p "$(dirname "$KEYFILE")"
        age-keygen -o "$KEYFILE"
        chmod 600 "$KEYFILE"
        echo "✅ Clave privada generada: $KEYFILE"
        echo "⚠️  GUARDA ESTE ARCHIVO EN UN LUGAR SEGURO (NO en el repo)"
        # Extraer clave pública para el repo
        grep "public key" "$KEYFILE" | awk '{print $3}' > .age-pubkey.txt
        chmod 644 .age-pubkey.txt
        echo "✅ Clave pública guardada en .age-pubkey.txt (committeable)"
    fi

# create-environments: Crear estructura environments/ y secrets vacíos
create-environments:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p environments/{dev,prod}
    # Crear .env.public con valores de ejemplo si no existen
    if [ ! -f environments/dev/.env.public ]; then
        cat > environments/dev/.env.public << 'ENVEOF'
# Variables públicas para entorno DEV
# Estos valores son seguros de commitear
ENV=dev
OPENWRT_VERSION=25.12.2
TARGET=ath79
SUBTARGET=generic
PROFILE=tplink_tl-wdr3600-v1
ROUTER_IP=192.168.1.1
SSH_PORT=22
ENVEOF
        echo "✅ environments/dev/.env.public creado"
    fi
    if [ ! -f environments/prod/.env.public ]; then
        cat > environments/prod/.env.public << 'ENVEOF'
# Variables públicas para entorno PROD
# Estos valores son seguros de commitear
ENV=prod
OPENWRT_VERSION=25.12.2
TARGET=ath79
SUBTARGET=generic
PROFILE=tplink_tl-wdr3600-v1
ROUTER_IP=192.168.1.1
SSH_PORT=22
ENVEOF
        echo "✅ environments/prod/.env.public creado"
    fi
    # Crear secrets.enc.yaml con estructura YAML válida si no existen
    PUBKEY=$(cat .age-pubkey.txt 2>/dev/null || echo "")
    if [ -z "$PUBKEY" ]; then
        echo "⚠️  No se encontró .age-pubkey.txt. Ejecuta: just generate-age-key"
        exit 1
    fi
    for env in dev prod; do
        SECRETS_FILE="environments/${env}/secrets.enc.yaml"
        if [ ! -f "$SECRETS_FILE" ]; then
            printf 'WIFI_KEY_24: ""\nWIFI_KEY_5: ""\nWIREGUARD_PRIVATE_KEY: ""\nROOT_PASSWORD_HASH: ""\n' > "$SECRETS_FILE"
            SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt" sops --encrypt --in-place "$SECRETS_FILE"
            echo "✅ environments/${env}/secrets.enc.yaml creado y encriptado"
        fi
    done

# ─────────────────────────────────────────────────────
# Secrets
# ─────────────────────────────────────────────────────

# decrypt-secrets: Desencriptar secrets para el entorno (ENV)
decrypt-secrets ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"
    SECRETS_FILE="environments/{{ ENV }}/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
        echo "Error: $SECRETS_FILE no existe. Ejecuta: just create-environments"
        exit 1
    fi
    sops -d "$SECRETS_FILE" > /tmp/secrets-{{ ENV }}.yaml
    echo "✅ Secrets desencriptados: /tmp/secrets-{{ ENV }}.yaml"

# edit-secrets: Editar secrets del entorno especificado
# Si el archivo no está encriptado, lo encripta automáticamente antes de abrir el editor.
# Al cerrar el editor, sops re-encripta automáticamente.
edit-secrets ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"
    SECRETS_FILE="environments/{{ ENV }}/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
        echo "Error: $SECRETS_FILE no existe. Ejecuta: just create-environments"
        exit 1
    fi
    # Si el archivo no tiene metadata sops, encriptarlo primero
    if ! grep -q 'sops:' "$SECRETS_FILE" && ! python3 -c "import json,sys; d=json.load(open('$SECRETS_FILE')); assert 'sops' in d" 2>/dev/null; then
        echo "⚠️  El archivo no está encriptado. Encriptando antes de editar..."
        sops --encrypt --in-place "$SECRETS_FILE"
        echo "✅ Archivo encriptado. Abriendo editor..."
    fi
    sops "$SECRETS_FILE"

# ─────────────────────────────────────────────────────
# Git hooks
# ─────────────────────────────────────────────────────

# setup-hooks: Configurar .githooks como directorio de hooks de git
setup-hooks:
    @bash scripts/git/setup-hooks.sh

# ─────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────

# build-dev: Compilar imagen para desarrollo (sin secrets reales)
build-dev:
    @echo "=== Build DEV (valores dummy) ==="
    ENV=dev make build

# build-prod: Compilar imagen para producción (con secrets reales)
build-prod:
    @echo "=== Build PROD ==="
    just decrypt-secrets prod
    just generate-config prod
    ENV=prod make build

# build: Compilar sin secrets (usa valores por defecto)
build:
    @echo "=== Build ==="
    make build

# generate-config: Generar archivos de configuración desde templates + secrets
generate-config ENV:
    ./scripts/templates/generate.sh {{ ENV }}

# ─────────────────────────────────────────────────────
# Paquetes
# ─────────────────────────────────────────────────────

# packages: Mostrar configuración de paquetes (TOML → display estructurado)
packages:
    @./scripts/build/show-packages.sh

# refresh-packages: Regenerar config/openwrt-packages.txt desde el TOML
refresh-packages:
    @echo "Regenerando config/openwrt-packages.txt desde config/openwrt-packages.toml..."
    ./scripts/build/convert-toml-packages.sh --output config/openwrt-packages.txt
    @echo "✅ Regenerado: config/openwrt-packages.txt"

# ─────────────────────────────────────────────────────
# Validación
# ─────────────────────────────────────────────────────

# validate: Ejecutar shellcheck en todos los scripts
validate:
    make validate

# ─────────────────────────────────────────────────────
# Flasheo
# ─────────────────────────────────────────────────────

# flash: Compilar y preparar para flashear (no ejecuta el flasheo automáticamente)
flash ENV="prod":
    @echo "=== Preparando flasheo para entorno {{ ENV }} ==="
    just build-prod
    ./scripts/build/verify.sh openwrt-builder/*/bin/targets/ath79/generic || true
    @echo ""
    @echo "✅ Imagen compilada. Para flashear el router:"
    @echo "   Ver docs/FLASH_INSTRUCTIONS.md"

# ─────────────────────────────────────────────────────
# Limpieza
# ─────────────────────────────────────────────────────

# clean: Limpiar artefactos de compilación
clean:
    make clean
    rm -f /tmp/secrets-*.yaml

# clean-all: Limpiar todo (incluyendo overlay)
clean-all:
    make clean
    make clean-overlay
    rm -f /tmp/secrets-*.yaml
