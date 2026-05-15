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
setup:
    @echo "=== Setup inicial del proyecto ==="
    just install-tools
    just generate-age-key
    just create-environments

# install-tools: Verificar e instalar herramientas necesarias
install-tools:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Verificando herramientas..."
    missing=()
    for tool in just make sops age; do
        if ! command -v $tool &>/dev/null; then
            missing+=("$tool")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Faltan: ${missing[*]}"
        echo ""
        echo "Instalar con:"
        echo "  macOS:  brew install ${missing[*]}"
        echo "  Debian: sudo apt-get install ${missing[*]}"
        echo "  Fedora: sudo dnf install ${missing[*]}"
        exit 1
    fi
    echo "✅ Todas las herramientas instaladas"

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
    touch environments/dev/.env
    touch environments/prod/.env
    # Crear secrets.enc.yaml vacíos con clave pública
    PUBKEY=$(cat .age-pubkey.txt 2>/dev/null || echo "")
    if [ -z "$PUBKEY" ]; then
        echo "⚠️  No se encontró .age-pubkey.txt. Ejecuta: just generate-age-key"
        exit 1
    fi
    if [ ! -f environments/prod/secrets.enc.yaml ]; then
        echo "# secrets.enc.yaml — Secrets para entorno prod" | sops --encrypt --age "$PUBKEY" /dev/stdin > environments/prod/secrets.enc.yaml
        echo "✅ environments/prod/secrets.enc.yaml creado"
    fi
    if [ ! -f environments/dev/secrets.enc.yaml ]; then
        echo "# secrets.enc.yaml — Secrets dummy para entorno dev" | sops --encrypt --age "$PUBKEY" /dev/stdin > environments/dev/secrets.enc.yaml
        echo "✅ environments/dev/secrets.enc.yaml creado"
    fi

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
edit-secrets ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"
    SECRETS_FILE="environments/{{ ENV }}/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
        echo "Error: $SECRETS_FILE no existe. Ejecuta: just create-environments"
        exit 1
    fi
    sops "$SECRETS_FILE"

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
