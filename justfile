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
        missing=(just make sops age yq)
    else
        missing=()
        for tool in just make sops age yq; do
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
                           cmds+=("SOPS_VER=\$(curl -s https://api.github.com/repos/getsops/sops/releases/latest | grep -o '\"tag_name\": *\"[^\"]*\"' | cut -d'\"' -f4 | sed 's/^v//')")
                           cmds+=("curl -Lo ~/.local/bin/sops https://github.com/getsops/sops/releases/download/v\${SOPS_VER}/sops-v\${SOPS_VER}.linux.\${ARCH}")
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
                      yq)  cmds+=("mkdir -p ~/.local/bin")
                           if [ "$FORCE" = "true" ]; then
                               cmds+=("rm -rf ~/.local/bin/yq")
                           fi
                           cmds+=("YQ_VER=\$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | grep -o '\"tag_name\": *\"[^\"]*\"' | cut -d'\"' -f4 | sed 's/^v//')")
                           cmds+=("curl -Lo ~/.local/bin/yq https://github.com/mikefarah/yq/releases/download/v\${YQ_VER}/yq_linux_\${ARCH}")
                           cmds+=("chmod +x ~/.local/bin/yq")
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

    # ── Post-download: verificar que binarios sean válidos ──────────
    if [ "$path_hint" = true ]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    for tool in "${missing[@]}"; do
        if command -v "$tool" &>/dev/null; then
            TPATH="$(command -v "$tool")"
            if file "${TPATH}" 2>/dev/null | grep -qi 'text'; then
                echo "❌ Error: '${tool}' en ${TPATH} no es un binario (parece texto/HTML)"
                echo "   La descarga desde GitHub probablemente falló (error 404)."
                echo "   Verifica la URL e inténtalo de nuevo."
                exit 1
            fi
        fi
    done
    echo ""

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

# validate-tools: Validar que todas las herramientas requeridas estén instaladas
validate-tools:
    @scripts/install/validate-tools.sh

# create-password: Generar hash SHA-512 de root e inyectarlo en secrets
# El hash se guarda directamente en secrets.enc.yaml sin mostrarse en pantalla.
create-password ENV:
    @scripts/install/generate-password-hash.sh {{ ENV }}

# generate-age-key: Generar clave age única del proyecto (si no existe)
generate-age-key:
    #!/usr/bin/env bash
    set -euo pipefail
    KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"
    if [ -f "$KEYFILE" ]; then
        echo "ℹ️  Clave age ya existe: $KEYFILE"
        exit 0
    fi

    # ── Pre-flight: verificar age-keygen ────────────────────────────
    if ! command -v age-keygen &>/dev/null; then
        echo "❌ Error: 'age-keygen' no encontrado en PATH"
        echo "   Buscando: age-keygen (necesario para generar clave age)"
        echo "   Solución: just install-tools"
        exit 1
    fi
    AGEPATH="$(command -v age-keygen)"
    if file "${AGEPATH}" 2>/dev/null | grep -qi 'text'; then
        echo "❌ Error: 'age-keygen' en ${AGEPATH} no es un binario válido"
        echo "   Detectado: archivo de texto/HTML (probable error 404 de GitHub)"
        echo "   Solución: just install-tools force=true"
        exit 1
    fi

    mkdir -p "$(dirname "$KEYFILE")"
    age-keygen -o "$KEYFILE"
    chmod 600 "$KEYFILE"
    echo "✅ Clave privada generada: $KEYFILE"
    echo "⚠️  GUARDA ESTE ARCHIVO EN UN LUGAR SEGURO (NO en el repo)"
    # Extraer clave pública para el repo
    grep -oE 'age1[a-z0-9]+' "$KEYFILE" | head -1 > .age-pubkey.txt
    chmod 644 .age-pubkey.txt
    echo "✅ Clave pública guardada en .age-pubkey.txt (committeable)"

# create-environments: Crear estructura environments/ y secrets vacíos
create-environments:
    #!/usr/bin/env bash
    set -euo pipefail
    O_VERSION="25.12.2"

    # ── Pre-flight: verificar sops ──────────────────────────────────
    if ! command -v sops &>/dev/null; then
        echo "❌ Error: 'sops' no encontrado en PATH"
        echo "   Buscando: sops (necesario para encriptar secrets)"
        echo "   Solución: just install-tools"
        exit 1
    fi
    SOPATH="$(command -v sops)"
    if file "${SOPATH}" 2>/dev/null | grep -qi 'text'; then
        echo "❌ Error: 'sops' en ${SOPATH} no es un binario válido"
        echo "   Detectado: archivo de texto/HTML (probable error 404 de GitHub)"
        echo "   Solución: just install-tools force=true"
        exit 1
    fi

    mkdir -p environments/{dev,prod}

    # Crear .env.public con valores de ejemplo si no existen
    # Contiene: parámetros de build + SSID de WiFi (no contraseñas)
    if [ ! -f environments/dev/.env.public ]; then
        printf '%s\n' \
            '# Variables públicas para entorno DEV' \
            '# Estos valores son seguros de commitear' \
            '' \
            'ENV=dev' \
            "OPENWRT_VERSION=${O_VERSION}" \
            'TARGET=ath79' \
            'SUBTARGET=generic' \
            'PROFILE=tplink_tl-wdr3600-v1' \
            'ROUTER_IP=192.168.1.1' \
            'SSH_PORT=22' \
            '' \
            '# Red WiFi (nombres de red — no contraseñas)' \
            'WIFI_SSID_24=TestWiFi24' \
            'WIFI_SSID_5=TestWiFi5G' \
            > environments/dev/.env.public
        echo "✅ environments/dev/.env.public creado"
    fi
    if [ ! -f environments/prod/.env.public ]; then
        printf '%s\n' \
            '# Variables públicas para entorno PROD' \
            '# Estos valores son seguros de commitear' \
            '' \
            'ENV=prod' \
            "OPENWRT_VERSION=${O_VERSION}" \
            'TARGET=ath79' \
            'SUBTARGET=generic' \
            'PROFILE=tplink_tl-wdr3600-v1' \
            'ROUTER_IP=192.168.1.1' \
            'SSH_PORT=22' \
            '' \
            '# Red WiFi (nombres de red — no contraseñas)' \
            'WIFI_SSID_24=' \
            'WIFI_SSID_5=' \
            > environments/prod/.env.public
        echo "✅ environments/prod/.env.public creado"
    fi

    # Crear secrets.enc.yaml vacíos (usuario los llena con just edit-secrets)
    # Contiene SOLO contraseñas: WiFi keys, WireGuard, root hash
    PUBKEY=$(cat .age-pubkey.txt 2>/dev/null || echo "")
    if [ -z "$PUBKEY" ]; then
        echo "⚠️  No se encontró .age-pubkey.txt. Ejecuta: just generate-age-key"
        exit 1
    fi
    for env in dev prod; do
        SECRETS_FILE="environments/${env}/secrets.enc.yaml"
        if [ ! -f "$SECRETS_FILE" ]; then
            printf 'WIFI_KEY_24: ""\nWIFI_KEY_5: ""\nWIREGUARD_PRIVATE_KEY: ""\nROOT_PASSWORD_HASH: ""\n' > "$SECRETS_FILE"
            SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt" sops --config .sops.yaml --encrypt --in-place "$SECRETS_FILE"
            echo "✅ environments/${env}/secrets.enc.yaml creado y encriptado"
            echo "   Llena tus datos con: just edit-secrets ${env}"
        fi
    done

# setup-env: Descargar y extraer el OpenWRT Image Builder
# Lee OPENWRT_VERSION, TARGET y SUBTARGET desde environments/<ENV>/.env.public
setup-env ENV="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ENV_FILE="environments/{{ ENV }}/.env.public"
    if [ ! -f "${ENV_FILE}" ]; then
        echo "❌ No se encontró: ${ENV_FILE}"
        echo "   Solución: just create-environments"
        exit 1
    fi
    # Cargar variables del entorno
    set -a; source "${ENV_FILE}"; set +a
    OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.2}"
    TARGET="${TARGET:-ath79}"
    SUBTARGET="${SUBTARGET:-generic}"
    export OPENWRT_VERSION TARGET SUBTARGET
    echo "=== Descargando Image Builder ==="
    echo "   Versión: ${OPENWRT_VERSION} — Target: ${TARGET}/${SUBTARGET}"
    echo ""
    scripts/install/setup-env.sh

# ─────────────────────────────────────────────────────
# Secrets
# ─────────────────────────────────────────────────────

# reinit-secrets: Re-encriptar secrets de un entorno con la clave age local
# Útil cuando el repo fue clonado y los secrets están encriptados con otra clave.
reinit-secrets ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    KEYFILE="$HOME/.age/poc-openwrt-privkey.txt"

    if [ ! -f "${KEYFILE}" ]; then
        echo "❌ No se encontró clave age: ${KEYFILE}"
        echo "   Solución: just generate-age-key"
        exit 1
    fi

    PUBKEY=$(grep -oE 'age1[a-z0-9]+' "${KEYFILE}" | head -1)
    if [ -z "${PUBKEY}" ]; then
        echo "❌ No se pudo extraer la clave pública de: ${KEYFILE}"
        exit 1
    fi

    echo "🔑 Clave pública local: ${PUBKEY}"
    echo ""
    echo "Esto va a:"
    echo "  1. Actualizar .age-pubkey.txt con tu clave"
    echo "  2. Actualizar .sops.yaml con tu clave"
    echo "  3. Eliminar environments/{{ ENV }}/secrets.enc.yaml"
    echo "  4. Crear nuevo secrets.enc.yaml vacío encriptado con tu clave"
    echo ""
    read -r -p "¿Continuar? (s/N) " answer
    if [ "${answer,,}" != "s" ] && [ "${answer,,}" != "si" ]; then
        echo "Cancelado."
        exit 1
    fi

    echo "${PUBKEY}" > .age-pubkey.txt
    echo "✅ .age-pubkey.txt actualizado"

    printf 'creation_rules:\n  - path_regex: environments/(dev|prod)/secrets\\.enc\\.yaml$\n    key_groups:\n      - age:\n          - %s\n' "${PUBKEY}" > .sops.yaml
    echo "✅ .sops.yaml actualizado"

    SECRETS_FILE="environments/{{ ENV }}/secrets.enc.yaml"
    rm -f "${SECRETS_FILE}"
    printf 'WIFI_KEY_24: ""\nWIFI_KEY_5: ""\nWIREGUARD_PRIVATE_KEY: ""\nROOT_PASSWORD_HASH: ""\n' > "${SECRETS_FILE}"
    SOPS_AGE_KEY_FILE="${KEYFILE}" sops --config .sops.yaml --encrypt --in-place "${SECRETS_FILE}"
    echo "✅ ${SECRETS_FILE} re-creado con tu clave"
    echo ""
    echo "Llena tus secrets con:"
    echo "   just edit-secrets {{ ENV }}"
    echo "   just create-password {{ ENV }}"

# decrypt-secrets: Desencriptar secrets para el entorno (ENV)
decrypt-secrets ENV:
    #!/usr/bin/env bash
    set -euo pipefail
    export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"

    # ── Pre-flight: verificar sops ──────────────────────────────────
    if ! command -v sops &>/dev/null; then
        echo "❌ Error: 'sops' no encontrado en PATH"
        echo "   Buscando: sops (necesario para desencriptar secrets)"
        echo "   Solución: just install-tools"
        exit 1
    fi
    SOPATH="$(command -v sops)"
    if file "${SOPATH}" 2>/dev/null | grep -qi 'text'; then
        echo "❌ Error: 'sops' en ${SOPATH} no es un binario válido"
        echo "   Detectado: archivo de texto/HTML (probable error 404 de GitHub)"
        echo "   Solución: just install-tools force=true"
        exit 1
    fi

    # ── Pre-flight: verificar clave age ─────────────────────────────
    if [ ! -f "${SOPS_AGE_KEY_FILE}" ]; then
        echo "❌ Error: clave age no encontrada"
        echo "   Buscando: ${SOPS_AGE_KEY_FILE}"
        echo "   Solución: just generate-age-key"
        exit 1
    fi

    # ── Desencriptar ────────────────────────────────────────────────
    SECRETS_FILE="environments/{{ ENV }}/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
        echo "❌ Error: archivo de secrets no existe"
        echo "   Buscando: ${SECRETS_FILE}"
        echo "   Solución: just create-environments"
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

    # ── Pre-flight: verificar sops ──────────────────────────────────
    if ! command -v sops &>/dev/null; then
        echo "❌ Error: 'sops' no encontrado en PATH"
        echo "   Buscando: sops (necesario para editar secrets)"
        echo "   Solución: just install-tools"
        exit 1
    fi
    SOPATH="$(command -v sops)"
    if file "${SOPATH}" 2>/dev/null | grep -qi 'text'; then
        echo "❌ Error: 'sops' en ${SOPATH} no es un binario válido"
        echo "   Detectado: archivo de texto/HTML (probable error 404 de GitHub)"
        echo "   Solución: just install-tools force=true"
        exit 1
    fi

    # ── Pre-flight: verificar clave age ─────────────────────────────
    if [ ! -f "${SOPS_AGE_KEY_FILE}" ]; then
        echo "❌ Error: clave age no encontrada"
        echo "   Buscando: ${SOPS_AGE_KEY_FILE}"
        echo "   Solución: just generate-age-key"
        exit 1
    fi

    SECRETS_FILE="environments/{{ ENV }}/secrets.enc.yaml"
    if [ ! -f "$SECRETS_FILE" ]; then
        echo "❌ Error: archivo de secrets no existe"
        echo "   Buscando: ${SECRETS_FILE}"
        echo "   Solución: just create-environments"
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

# build-dev: Compilar imagen para desarrollo
# Carga variables públicas de dev + intenta descifrar secrets de dev.
# Los secrets vacíos se omiten (no configuran esa funcionalidad).
build-dev:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Build DEV ==="
    scripts/install/ensure-secrets.sh dev || exit 1
    just generate-config dev
    ENV=dev make build

# build-prod: Compilar imagen para producción
# Carga variables públicas de prod + intenta descifrar secrets de prod.
# Los secrets vacíos se omiten (no configuran esa funcionalidad).
build-prod:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Build PROD ==="
    scripts/install/ensure-secrets.sh prod || exit 1
    just generate-config prod
    ENV=prod make build

# build: Compilar sin secrets (usa valores por defecto del entorno)
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
# Update / Flasheo
# ─────────────────────────────────────────────────────

# update: Actualizar firmware del router via sysupgrade (mantiene configuración)
# Uso: just update [ip=<IP>] [env=<dev|prod>]
# La IP se infiere de environments/<env>/.env.public o usa 192.168.1.1 por defecto
update ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then
        ARGS="${ARGS} --ip {{ ip }}"
    fi
    # shellcheck disable=SC2086
    scripts/build/update.sh ${ARGS}

# update-force: Actualizar firmware borrando la configuración del router
# Uso: just update-force [ip=<IP>] [env=<dev|prod>]
update-force ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }} --force"
    if [ -n "{{ ip }}" ]; then
        ARGS="${ARGS} --ip {{ ip }}"
    fi
    # shellcheck disable=SC2086
    scripts/build/update.sh ${ARGS}

# setup-extroot: Configurar USB como extroot en el router via SSH
# Monta el USB, copia /overlay, configura fstab y reinicia.
# Prerrequisito: USB formateado como ext4 antes de conectar al router.
# Uso: just setup-extroot [ip=<IP>] [device=<dev>] [env=<env>]
setup-extroot ip="" device="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ];     then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ device }}" ]; then ARGS="${ARGS} --device {{ device }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-extroot.sh ${ARGS}

# setup-logs: Configurar logs persistentes en USB (extroot) via SSH
# ⚠️  Prerrequisito: just setup-extroot debe haberse ejecutado y el router
#    debe haber reiniciado con el USB montado como /overlay.
# Uso: just setup-logs [ip=<IP>] [env=<env>]
setup-logs ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-logs.sh ${ARGS}

# setup-auth: Copia clave SSH pública al router y establece contraseña root
# Orden recomendado: primero copia la clave, luego pide contraseña (evita bloqueos)
# Uso: just setup-auth [ip=<IP>] [env=<env>] [key=<path>]
setup-auth ip="" env="prod" key="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ key }}" ]; then ARGS="${ARGS} --key {{ key }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-auth.sh ${ARGS}

# post-install: Instala paquetes adicionales en el router via opkg (post-flash)
# Lee config/openwrt-post-install-packages.toml
# Uso: just post-install [group=<grupo>] [ip=<IP>] [env=<env>]
#      just post-install group=captive_portal
#      just post-install --list  → muestra grupos disponibles
post-install group="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ group }}" ]; then ARGS="${ARGS} --group {{ group }}"; fi
    # shellcheck disable=SC2086
    scripts/build/post-install.sh ${ARGS}

# ---------------------------------------------------------------------------
# Portal cautivo (nftables + uhttpd, sin OpenNDS)
# Flujo: just post-install group=captive_portal → just setup-captive
# ---------------------------------------------------------------------------

# setup-captive: Instala el portal cautivo en el router
# Uso: just setup-captive [ip=] [env=] [timeout=30] [portal-url=] [token=]
setup-captive ip="" env="prod" timeout="30" portal-url="" token="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="install --env {{ env }} --timeout {{ timeout }}"
    if [ -n "{{ ip }}" ];         then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ portal-url }}" ]; then ARGS="${ARGS} --portal-url {{ portal-url }}"; fi
    if [ -n "{{ token }}" ];      then ARGS="${ARGS} --token {{ token }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-captive.sh ${ARGS}

# remove-captive: Desinstala el portal cautivo del router
# Uso: just remove-captive [ip=] [env=]
remove-captive ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="uninstall --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-captive.sh ${ARGS}

# captive-allow: Autoriza una IP manualmente en el portal cautivo
# timeout en minutos (default: 30). 0 = sin límite (permanente).
# Uso: just captive-allow client=192.168.1.50 [timeout=30] [ip=] [env=]
#      just captive-allow client=192.168.1.50 timeout=0    # permanente
#      just captive-allow client=192.168.1.50 timeout=120  # 2 horas
captive-allow client="" ip="" env="prod" timeout="30":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ client }}" ]; then echo "ERROR: especifica client=<IP>"; exit 1; fi
    ARGS="allow {{ client }} --env {{ env }} --timeout {{ timeout }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-captive.sh ${ARGS}

# captive-block: Revoca autorización de una IP del portal cautivo
# Uso: just captive-block client=192.168.1.50 [ip=] [env=]
captive-block client="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ client }}" ]; then echo "ERROR: especifica client=<IP>"; exit 1; fi
    ARGS="block {{ client }} --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-captive.sh ${ARGS}

# captive-flush: Limpia todos los clientes autorizados del portal
# Uso: just captive-flush [ip=] [env=]
captive-flush ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="flush --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-captive.sh ${ARGS}

# captive-list: Muestra clientes autorizados y estado del portal
# Uso: just captive-list [ip=] [env=]
captive-list ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="list --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-captive.sh ${ARGS}

# captive-status: Diagnóstico del portal cautivo
# Uso: just captive-status [ip=] [env=]
captive-status ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="status --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-captive.sh ${ARGS}

# ---------------------------------------------------------------------------
# WiFi (APs y modo cliente)
# ---------------------------------------------------------------------------

# setup-wifi: Configura WiFi en el router (AP o cliente)
# Ver subcomandos con: just setup-wifi help
setup-wifi subcmd="" ip="" env="prod" ssid="" password="" radio="" channel="" open="false":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="{{ subcmd }} --env {{ env }}"
    if [ -n "{{ ip }}" ];       then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ ssid }}" ];     then ARGS="${ARGS} --ssid {{ ssid }}"; fi
    if [ -n "{{ password }}" ]; then ARGS="${ARGS} --password {{ password }}"; fi
    if [ -n "{{ radio }}" ];    then ARGS="${ARGS} --radio {{ radio }}"; fi
    if [ -n "{{ channel }}" ];  then ARGS="${ARGS} --channel {{ channel }}"; fi
    if [ "{{ open }}" = "true" ]; then ARGS="${ARGS} --open"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh ${ARGS}

# wifi-ap: Configura un Access Point (completamente interactivo)
# Sin args: pregunta radio disponible → SSID → contraseña → canal
# Uso: just wifi-ap [--radio 5g|radio1] [--ssid MiRed] [--channel 6] [--open] [--env dev]
wifi-ap *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh ap {{args}}

# wifi-client: Conecta el router como cliente a otra red WiFi
# Sin argumentos: escanea redes y guía interactivamente (SSID, banda, contraseña, BSSID)
# Uso: just wifi-client [--radio 2g|5g|radio0|radio1] [--ssid OtraRed] [--env dev]
wifi-client *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh client {{args}}

# wifi-disconnect: Desconecta el cliente WiFi (elimina STA y wwan)
# Uso: just wifi-disconnect [radio=radio1] [ip=] [env=]
#      Sin radio=: desconecta todos los clientes STA activos
wifi-disconnect radio="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="disconnect --env {{ env }}"
    if [ -n "{{ radio }}" ]; then ARGS="${ARGS} --radio {{ radio }}"; fi
    if [ -n "{{ ip }}" ];    then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh ${ARGS}

# wifi-scan: Escanea redes WiFi disponibles
# Sin args: escanea ambos radios (2.4 GHz y 5 GHz)
# Uso: just wifi-scan [--radio 2g|5g|radio0|radio1] [--env dev] [--ip 192.168.x.x]
wifi-scan *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh scan {{args}}

# wifi-status: Muestra estado de todos los radios e interfaces WiFi
# Uso: just wifi-status [ip=] [env=]
wifi-status ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="status --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh ${ARGS}

# wifi-enable: Habilita un radio WiFi
# Uso: just wifi-enable radio=radio0|2g|radio1|5g [ip=] [env=]
wifi-enable radio="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ radio }}" ]; then echo "ERROR: especifica radio=<radio0|radio1|2g|5g>"; exit 1; fi
    ARGS="enable --radio {{ radio }} --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh ${ARGS}

# wifi-disable: Deshabilita un radio WiFi
# Uso: just wifi-disable radio=radio0|2g|radio1|5g [ip=] [env=]
wifi-disable radio="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ radio }}" ]; then echo "ERROR: especifica radio=<radio0|radio1|2g|5g>"; exit 1; fi
    ARGS="disable --radio {{ radio }} --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-wifi.sh ${ARGS}

# ---------------------------------------------------------------------------
# Routing (prioridad WAN vs WiFi cliente y source-based routing)
# ---------------------------------------------------------------------------

# routing-status: Muestra rutas, gateways y métricas actuales
# Uso: just routing-status [ip=] [env=]
routing-status ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="status --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/build/setup-routing.sh ${ARGS}

# routing-priority: Define qué interfaz es la salida preferida
# Uso: just routing-priority <wan|wifi|equal> [--env dev] [--ip 192.168.x.x]
routing-priority *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-routing.sh priority {{args}}

# routing-pin: Fija el tráfico de una IP LAN a una interfaz concreta
# Uso: just routing-pin --from 192.168.1.50 --via wifi [--env dev]
routing-pin *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-routing.sh pin {{args}}

# routing-unpin: Elimina el pin de enrutamiento para una IP LAN
# Uso: just routing-unpin --from 192.168.1.50 [--env dev]
routing-unpin *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-routing.sh unpin {{args}}

# routing-pins: Lista todos los pins de enrutamiento activos
# Uso: just routing-pins [--env dev] [--ip 192.168.x.x]
routing-pins *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-routing.sh pins {{args}}

# routing-reset: Elimina todos los pins y restaura prioridad a WAN
# Uso: just routing-reset [--env dev] [--ip 192.168.x.x]
routing-reset *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-routing.sh reset {{args}}

# ---------------------------------------------------------------------------
# IPs Estáticas (DHCP leases por MAC address)
# ---------------------------------------------------------------------------

# static-ip-add: Asigna IP estática a un MAC address
# Uso: just static-ip-add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 [--name servidor]
static-ip-add *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-static-ip.sh add {{args}}

# static-ip-remove: Elimina asignación de IP estática (por MAC o por IP)
# Uso: just static-ip-remove --mac AA:BB:CC:DD:EE:FF
#      just static-ip-remove --assign 192.168.1.100
static-ip-remove *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-static-ip.sh remove {{args}}

# static-ip-list: Muestra todas las asignaciones de IP estática
# Uso: just static-ip-list [--env dev] [--ip 192.168.x.x]
static-ip-list *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-static-ip.sh list {{args}}

# static-ip-clear: Elimina TODAS las asignaciones de IP estática
# Uso: just static-ip-clear [--env dev] [--ip 192.168.x.x]
static-ip-clear *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-static-ip.sh clear {{args}}

# static-ip-import: Importa asignaciones desde CSV (MAC,IP,nombre)
# Uso: just static-ip-import --file hosts.csv [--env dev]
static-ip-import *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-static-ip.sh import {{args}}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

# dns-set: Configura los servidores DNS upstream del router
# Sin args: usa Cloudflare (1.1.1.1) + Google (8.8.8.8)
# Uso: just dns-set [--primary 9.9.9.9] [--secondary 149.112.112.112] [--env dev]
dns-set *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-dns.sh set {{args}}

# dns-show: Muestra la configuración DNS actual del router
# Uso: just dns-show [--ip 192.168.x.x] [--env dev]
dns-show *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-dns.sh show {{args}}

# dns-reset: Restaura los DNS por defecto (1.1.1.1 + 8.8.8.8)
# Uso: just dns-reset [--ip 192.168.x.x] [--env dev]
dns-reset *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-dns.sh reset {{args}}

# ---------------------------------------------------------------------------
# Clientes DHCP
# ---------------------------------------------------------------------------

# clients: Lista los dispositivos conectados al router (leases DHCP + tabla ARP)
# Uso: just clients [--ip 192.168.x.x] [--env dev]
clients *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/show-clients.sh {{args}}

# ---------------------------------------------------------------------------
# SOCKS Forward (Raspi3b / Tor)
# ---------------------------------------------------------------------------

# socks-enable: Activa el port forwarding del proxy SOCKS de la Raspi3b (Tor)
# Pide la IP de la Raspi interactivamente, asigna IP estática en DHCP y crea la regla DNAT
# Uso: just socks-enable [--raspi-ip 192.168.1.x] [--port 9050]
socks-enable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-socks-forward.sh enable {{args}}

# socks-disable: Desactiva el port forwarding del proxy SOCKS (elimina la regla DNAT)
# Uso: just socks-disable [--ip 192.168.x.x] [--env dev]
socks-disable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-socks-forward.sh disable {{args}}

# socks-uninstall: Elimina la regla DNAT y la IP estática de la Raspi en DHCP
# Uso: just socks-uninstall [--ip 192.168.x.x] [--env dev]
socks-uninstall *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-socks-forward.sh uninstall {{args}}

# socks-status: Muestra el estado del port forwarding SOCKS y la IP estática de la Raspi
# Uso: just socks-status [--ip 192.168.x.x] [--env dev]
socks-status *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-socks-forward.sh status {{args}}

# ---------------------------------------------------------------------------
# Transparent .onion proxy (Tor via Raspi3b)
# ---------------------------------------------------------------------------

# onion-enable: Activa el transparent proxy .onion (dnsmasq + nftables DNAT)
# Pide IP de la Raspi si no se indica; auto-detecta desde raspi-tor en DHCP
# Uso: just onion-enable [--raspi-ip 192.168.1.x] [--dns-port 5300] [--trans-port 9040]
onion-enable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-tor-onion.sh enable {{args}}

# onion-disable: Desactiva el DNAT .onion (conserva la entrada dnsmasq)
# Uso: just onion-disable [--ip 192.168.x.x] [--env dev]
onion-disable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-tor-onion.sh disable {{args}}

# onion-uninstall: Elimina el DNAT y la entrada dnsmasq .onion (limpieza total)
# Uso: just onion-uninstall [--ip 192.168.x.x] [--env dev]
onion-uninstall *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-tor-onion.sh uninstall {{args}}

# onion-status: Muestra el estado del transparent proxy .onion
# Uso: just onion-status [--ip 192.168.x.x] [--env dev]
onion-status *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-tor-onion.sh status {{args}}

# onion-doctor: Diagnostica el stack .onion capa por capa (DHCP → dnsmasq → nftables → puertos Tor)
# Muestra ✅/❌/⚠️ por check y sugerencias de corrección; sale con código 1 si hay errores
# Uso: just onion-doctor [--ip 192.168.x.x] [--dns-port 5300] [--trans-port 9040]
onion-doctor *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/build/setup-tor-onion.sh doctor {{args}}

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
