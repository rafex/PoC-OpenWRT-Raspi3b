# justfile — Único punto de entrada (task manager)
# Orquesta todo: setup, secrets, build, flash.
# Las tareas de build están en Makefile; just las llama, nunca al revés.

# Garantiza que ~/.local/bin esté en PATH en todas las recetas.
# Necesario cuando sops/age/yq se acaban de instalar en esa ruta
# y la shell no ha recargado el perfil todavía.
export PATH := env_var('HOME') + '/.local/bin:' + env_var('PATH')

# Pinned tool versions (bump manually, update checksums in scripts/install/checksums.sha256)
SOPS_VERSION := "3.9.4"
AGE_VERSION := "1.2.1"
YQ_VERSION := "4.45.1"
JUST_VERSION := "1.39.0"

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
# Usa versiones pinnadas (var at top); elimina eval y curl|bash
install-tools force="false":
    #!/usr/bin/env bash
    set -euo pipefail
    FORCE="{{ force }}"
    SOPS_VERSION="{{ SOPS_VERSION }}"
    AGE_VERSION="{{ AGE_VERSION }}"
    YQ_VERSION="{{ YQ_VERSION }}"
    JUST_VERSION="{{ JUST_VERSION }}"
    echo "Verificando herramientas (versiones pinnadas: sops=${SOPS_VERSION} age=${AGE_VERSION} yq=${YQ_VERSION} just=${JUST_VERSION})..."

    if [ "$FORCE" = "true" ]; then
        echo "(modo force: se reinstalarán todas las herramientas)"
        missing=(just make gawk sops age yq)
    else
        missing=()
        for tool in just make gawk sops age yq; do
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

    ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
    REPO_ROOT="$(cd "$(dirname "${0%/*}")" && pwd)"
    CHECKSUMS_FILE="${REPO_ROOT}/scripts/install/checksums.sha256"
    path_hint=false

    case "$(uname -s)" in
        Darwin)
            echo "  $ brew install ${missing[*]}"
            read -r -p "¿Ejecutar? (s/N) " answer
            if [ "${answer,,}" != "s" ] && [ "${answer,,}" != "si" ]; then exit 1; fi
            # shellcheck disable=SC2086
            brew install ${missing[*]}
            ;;
        Linux)
            mkdir -p ~/.local/bin

            for tool in "${missing[@]}"; do
                case "$tool" in
                    make)  sudo apt-get install -y make ;;
                    gawk)  sudo apt-get install -y gawk ;;
                    just)
                        echo "  → Descargando just ${JUST_VERSION}..."
                        if [ "$FORCE" = "true" ]; then rm -f ~/.local/bin/just; fi
                        curl -sSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
                            -o /tmp/just.tar.gz
                        tar -xzf /tmp/just.tar.gz -C ~/.local/bin just
                        rm /tmp/just.tar.gz
                        chmod +x ~/.local/bin/just
                        path_hint=true
                        echo "  ✅ just ${JUST_VERSION}"
                        ;;
                    sops)
                        echo "  → Descargando sops v${SOPS_VERSION}..."
                        if [ "$FORCE" = "true" ]; then rm -f ~/.local/bin/sops; fi
                        curl -sSL "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.${ARCH}" \
                            -o ~/.local/bin/sops
                        chmod +x ~/.local/bin/sops
                        if [ -f "${CHECKSUMS_FILE}" ]; then
                            echo "  → Verificando checksum..."
                            EXPECTED_HASH=$(grep "sops-v${SOPS_VERSION}.linux.${ARCH}" "${CHECKSUMS_FILE}" 2>/dev/null | awk '{print $2}' || echo "")
                            if [ -n "${EXPECTED_HASH}" ] && [ "${EXPECTED_HASH}" != "<UNKNOWN" ]; then
                                ACTUAL_HASH=$(sha256sum ~/.local/bin/sops | awk '{print $1}')
                                if [ "${ACTUAL_HASH}" != "${EXPECTED_HASH}" ]; then
                                    echo "❌ Checksum mismatch para sops"
                                    echo "   Esperado: ${EXPECTED_HASH}"
                                    echo "   Obtenido: ${ACTUAL_HASH}"
                                    rm -f ~/.local/bin/sops
                                    exit 1
                                fi
                                echo "  ✅ Checksum verificado"
                            fi
                        fi
                        path_hint=true
                        echo "  ✅ sops v${SOPS_VERSION}"
                        ;;
                    age)
                        echo "  → Descargando age v${AGE_VERSION}..."
                        if [ "$FORCE" = "true" ]; then rm -f ~/.local/bin/age ~/.local/bin/age-keygen; fi
                        curl -sSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-${ARCH}.tar.gz" \
                            -o /tmp/age.tar.gz
                        if [ -f "${CHECKSUMS_FILE}" ]; then
                            echo "  → Verificando checksum..."
                            EXPECTED_HASH=$(grep "age-v${AGE_VERSION}-linux-${ARCH}" "${CHECKSUMS_FILE}" 2>/dev/null | awk '{print $2}' || echo "")
                            if [ -n "${EXPECTED_HASH}" ] && [ "${EXPECTED_HASH}" != "<UNKNOWN" ]; then
                                ACTUAL_HASH=$(sha256sum /tmp/age.tar.gz | awk '{print $1}')
                                if [ "${ACTUAL_HASH}" != "${EXPECTED_HASH}" ]; then
                                    echo "❌ Checksum mismatch para age"
                                    rm -f /tmp/age.tar.gz
                                    exit 1
                                fi
                                echo "  ✅ Checksum verificado"
                            fi
                        fi
                        tar -xzf /tmp/age.tar.gz --strip-components=1 -C ~/.local/bin
                        chmod +x ~/.local/bin/age ~/.local/bin/age-keygen
                        rm /tmp/age.tar.gz
                        path_hint=true
                        echo "  ✅ age v${AGE_VERSION}"
                        ;;
                    yq)
                        echo "  → Descargando yq v${YQ_VERSION}..."
                        if [ "$FORCE" = "true" ]; then rm -f ~/.local/bin/yq; fi
                        curl -sSL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ARCH}" \
                            -o ~/.local/bin/yq
                        chmod +x ~/.local/bin/yq
                        if [ -f "${CHECKSUMS_FILE}" ]; then
                            echo "  → Verificando checksum..."
                            EXPECTED_HASH=$(grep "yq_linux_${ARCH}" "${CHECKSUMS_FILE}" 2>/dev/null | awk '{print $2}' || echo "")
                            if [ -n "${EXPECTED_HASH}" ] && [ "${EXPECTED_HASH}" != "<UNKNOWN" ]; then
                                ACTUAL_HASH=$(sha256sum ~/.local/bin/yq | awk '{print $1}')
                                if [ "${ACTUAL_HASH}" != "${EXPECTED_HASH}" ]; then
                                    echo "❌ Checksum mismatch para yq"
                                    rm -f ~/.local/bin/yq
                                    exit 1
                                fi
                                echo "  ✅ Checksum verificado"
                            fi
                        fi
                        path_hint=true
                        echo "  ✅ yq v${YQ_VERSION}"
                        ;;
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

    # Post-download: verificar que los binarios sean válidos
    if [ "$path_hint" = true ]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi
    still_missing=()
    for tool in "${missing[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            still_missing+=("$tool")
        else
            TPATH="$(command -v "$tool")"
            if file "${TPATH}" 2>/dev/null | grep -qi 'text'; then
                echo "❌ Error: '${tool}' en ${TPATH} no es un binario (parece texto/HTML)"
                still_missing+=("$tool")
            fi
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
    @bash scripts/install/generate-age-key.sh

# create-environments: Crear estructura environments/ y secrets vacíos
create-environments:
    @bash scripts/install/create-environments.sh

# setup-env: Descargar y extraer el OpenWRT Image Builder
# Lee OPENWRT_VERSION, TARGET y SUBTARGET desde environments/<ENV>/.env.public
setup-env ENV="prod":
    @bash scripts/install/setup-env-wrapper.sh {{ ENV }}

# ─────────────────────────────────────────────────────
# Secrets
# ─────────────────────────────────────────────────────

# reinit-secrets: Re-encriptar secrets de un entorno con la clave age local
# Útil cuando el repo fue clonado y los secrets están encriptados con otra clave.
reinit-secrets ENV:
    @bash scripts/install/reinit-secrets.sh {{ ENV }}

# decrypt-secrets: Desencriptar secrets para el entorno (ENV)
# Usa la librería centralizada con mktemp + permisos 600
decrypt-secrets ENV:
    @bash scripts/install/ensure-secrets.sh {{ ENV }}

# edit-secrets: Editar secrets del entorno especificado
# Si el archivo no está encriptado, lo encripta automáticamente antes de abrir el editor.
# Al cerrar el editor, sops re-encripta automáticamente.
edit-secrets ENV:
    @bash scripts/install/edit-secrets.sh {{ ENV }}

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
    SECRETS_TMP=$(scripts/install/ensure-secrets.sh dev) || exit 1
    ./scripts/templates/generate.sh dev "${SECRETS_TMP}"
    rm -f "${SECRETS_TMP}"
    ENV=dev make build

# build-prod: Compilar imagen para producción y verificar resultado
# Carga variables públicas de prod + intenta descifrar secrets de prod.
# Los secrets vacíos se omiten (no configuran esa funcionalidad).
# Al terminar muestra la ruta de la imagen y el siguiente paso (flasheo).
build-prod:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "=== Build PROD ==="
    SECRETS_TMP=$(scripts/install/ensure-secrets.sh prod) || exit 1
    ./scripts/templates/generate.sh prod "${SECRETS_TMP}"
    rm -f "${SECRETS_TMP}"
    ENV=prod make build
    ENV=prod ./scripts/build/verify.sh || true
    echo ""
    echo "✅ Imagen lista. Siguiente paso: ver docs/FLASH_INSTRUCTIONS.md"

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

# test: Ejecutar todos los tests (TOML parser + integration)
test:
    python3 tests/test_toml_parser.py
    bash tests/test_generate_config.sh

# ─────────────────────────────────────────────────────
# Router — Gestión SSH y known_hosts
# ─────────────────────────────────────────────────────

# router-add-known-host: Registrar host key del router (verifica fingerprint manualmente)
# El fingerprint se guarda en environments/<ENV>/.router-known-hosts
# Las conexiones subsecuentes verifican contra esta key automáticamente.
router-add-known-host ENV="prod" ip="":
    #!/usr/bin/env bash
    set -euo pipefail
    ENV="{{ ENV }}"
    ROUTER_IP="{{ ip }}"
    KNOWN_HOSTS_FILE="environments/${ENV}/.router-known-hosts"
    if [ -z "${ROUTER_IP}" ]; then
        ENV_FILE="environments/${ENV}/.env.public"
        if [ -f "${ENV_FILE}" ]; then
            ROUTER_IP=$(grep 'ROUTER_IP=' "${ENV_FILE}" | cut -d= -f2 | tr -d '"' || echo "192.168.1.1")
        else
            ROUTER_IP="192.168.1.1"
        fi
    fi
    SSH_PORT=$(grep 'SSH_PORT=' "environments/${ENV}/.env.public" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "22")
    echo "Obteniendo host key de ${ROUTER_IP}:${SSH_PORT}..."
    if ! ssh-keyscan -p "${SSH_PORT}" "${ROUTER_IP}" > "${KNOWN_HOSTS_FILE}" 2>/dev/null; then
        if [ -f "${KNOWN_HOSTS_FILE}" ]; then rm -f "${KNOWN_HOSTS_FILE}"; fi
        echo "❌ No se pudo obtener la host key."
        echo "   Verifica que el router esté accesible en ${ROUTER_IP}:${SSH_PORT}"
        exit 1
    fi
    FINGERPRINT=$(ssh-keygen -l -f "${KNOWN_HOSTS_FILE}" 2>/dev/null | awk '{print $1, $2, $4}')
    echo "✅ Host key registrada en: ${KNOWN_HOSTS_FILE}"
    echo "   Fingerprint: ${FINGERPRINT}"
    echo ""
    echo "   Las conexiones SSH ahora verificarán esta key automáticamente."

# ─────────────────────────────────────────────────────
# Update / Flasheo
# ─────────────────────────────────────────────────────

# router-update: Actualizar firmware del router via sysupgrade (mantiene configuración)
# Uso: just router-update [--ip <IP>] [--env <dev|prod>]
# La IP se infiere de environments/<env>/.env.public o usa 192.168.1.1 por defecto
router-update *args='':
    @scripts/router/update.sh {{args}}

# router-update-force: Actualizar firmware borrando la configuración del router
# Uso: just router-update-force [--ip <IP>] [--env <dev|prod>]
router-update-force *args='':
    @scripts/router/update.sh --force {{args}}

# router-setup-extroot: Configurar USB como extroot en el router via SSH
# Monta el USB, copia /overlay, configura fstab y reinicia.
# Prerrequisito: USB formateado como ext4 antes de conectar al router.
# Uso: just router-setup-extroot [--ip <IP>] [--device <dev>] [--env <env>] [--no-reboot]
router-setup-extroot *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-extroot.sh {{args}}

# host-format-extroot-usb: Borra/formatea un USB local como ext4 para extroot
# Ejecutar desde la máquina donde está conectado el USB, ej. ssh bastion-wifi
# Uso: just host-format-extroot-usb --list
# Uso: just host-format-extroot-usb --device /dev/sdX1 [--label openwrt-extroot] [--yes]
host-format-extroot-usb *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/install/format-extroot-usb.sh {{args}}

# host-recover-extroot-usb: Repara ext4 y respalda un USB extroot local
# Ejecutar desde la máquina donde está conectado el USB, ej. ssh bastion-wifi
# Uso: just host-recover-extroot-usb --list
# Uso: just host-recover-extroot-usb --device /dev/sdX1 [--backup-dir <dir>] [--yes]
host-recover-extroot-usb *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/install/recover-extroot-usb.sh {{args}}

# router-setup-logs-ram: Buffer de logs en RAM (64 KB, sin USB ni extroot)
# Los logs NO persisten entre reinicios.
# Uso: just router-setup-logs-ram [ip=<IP>] [env=<env>]
router-setup-logs-ram ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-logs-ram.sh ${ARGS}

# router-setup-logs-file: Logs persistentes en archivo (USB montado como extroot)
# ⚠️  Prerrequisito: just router-setup-extroot + reinicio del router.
# Uso: just router-setup-logs-file [ip=<IP>] [env=<env>]
router-setup-logs-file ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-logs-file.sh ${ARGS}

# router-setup-auth: Copia clave SSH pública al router y establece contraseña root
# Orden recomendado: primero copia la clave, luego pide contraseña (evita bloqueos)
# Uso: just router-setup-auth [ip=<IP>] [env=<env>] [key=<path>]
router-setup-auth ip="" env="prod" key="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ key }}" ]; then ARGS="${ARGS} --key {{ key }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-auth.sh ${ARGS}

# router-copy-keys: Copiar clave SSH pública a Dropbear sin cambiar contraseña root
# Uso: just router-copy-keys [--ip <IP>] [--env <env>] [--key <path>]
router-copy-keys *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-auth.sh --keys-only {{args}}

# router-post-install: Instala paquetes adicionales en el router via opkg (post-flash)
# Lee config/openwrt-router-post-install-packages.toml
# Uso: just router-post-install [group=<grupo>] [ip=<IP>] [env=<env>]
#      just router-post-install group=captive_portal
#      just router-post-install --list  → muestra grupos disponibles
router-post-install group="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="--env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ group }}" ]; then ARGS="${ARGS} --group {{ group }}"; fi
    # shellcheck disable=SC2086
    scripts/router/post-install.sh ${ARGS}

# ---------------------------------------------------------------------------
# Portal cautivo (nftables + uhttpd, sin OpenNDS)
# Flujo: just router-post-install group=captive_portal → just router-captive-setup
# ---------------------------------------------------------------------------

# router-captive-setup: Instala el portal cautivo en el router
# Uso: just router-captive-setup [ip=] [env=] [timeout=30] [portal-url=] [token=]
router-captive-setup ip="" env="prod" timeout="30" portal-url="" token="":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="install --env {{ env }} --timeout {{ timeout }}"
    if [ -n "{{ ip }}" ];         then ARGS="${ARGS} --ip {{ ip }}"; fi
    if [ -n "{{ portal-url }}" ]; then ARGS="${ARGS} --portal-url {{ portal-url }}"; fi
    if [ -n "{{ token }}" ];      then ARGS="${ARGS} --token {{ token }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-captive.sh ${ARGS}

# router-captive-remove: Desinstala el portal cautivo del router
# Uso: just router-captive-remove [ip=] [env=]
router-captive-remove ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="uninstall --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-captive.sh ${ARGS}

# router-captive-allow: Autoriza una IP manualmente en el portal cautivo
# timeout en minutos (default: 30). 0 = sin límite (permanente).
# Uso: just router-captive-allow client=192.168.1.50 [timeout=30] [ip=] [env=]
#      just router-captive-allow client=192.168.1.50 timeout=0    # permanente
#      just router-captive-allow client=192.168.1.50 timeout=120  # 2 horas
router-captive-allow client="" ip="" env="prod" timeout="30":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ client }}" ]; then echo "ERROR: especifica client=<IP>"; exit 1; fi
    ARGS="allow {{ client }} --env {{ env }} --timeout {{ timeout }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-captive.sh ${ARGS}

# router-captive-block: Revoca autorización de una IP del portal cautivo
# Uso: just router-captive-block client=192.168.1.50 [ip=] [env=]
router-captive-block client="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ client }}" ]; then echo "ERROR: especifica client=<IP>"; exit 1; fi
    ARGS="block {{ client }} --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-captive.sh ${ARGS}

# router-captive-flush: Limpia todos los clientes autorizados del portal
# Uso: just router-captive-flush [ip=] [env=]
router-captive-flush ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="flush --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-captive.sh ${ARGS}

# router-captive-list: Muestra clientes autorizados y estado del portal
# Uso: just router-captive-list [ip=] [env=]
router-captive-list ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="list --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-captive.sh ${ARGS}

# router-captive-status: Diagnóstico del portal cautivo
# Uso: just router-captive-status [ip=] [env=]
router-captive-status ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="status --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-captive.sh ${ARGS}

# ---------------------------------------------------------------------------
# WiFi (APs y modo cliente)
# ---------------------------------------------------------------------------

# router-wifi-setup: Configura WiFi en el router (AP o cliente)
# Ver subcomandos con: just router-wifi-setup help
router-wifi-setup subcmd="" ip="" env="prod" ssid="" password="" radio="" channel="" open="false":
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
    scripts/router/setup-wifi.sh ${ARGS}

# router-wifi-ap: Configura un Access Point (completamente interactivo)
# Sin args: pregunta radio disponible → SSID → contraseña → canal
# Uso: just router-wifi-ap [--radio 5g|radio1] [--ssid MiRed] [--channel 6] [--open] [--env dev]
router-wifi-ap *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wifi.sh ap {{args}}

# router-wifi-client: Conecta el router como cliente a otra red WiFi
# Sin argumentos: escanea redes y guía interactivamente (SSID, banda, contraseña, BSSID)
# Uso: just router-wifi-client [--radio 2g|5g|radio0|radio1] [--ssid OtraRed] [--env dev]
router-wifi-client *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wifi.sh client {{args}}

# router-wifi-disconnect: Desconecta el cliente WiFi (elimina STA y wwan)
# Uso: just router-wifi-disconnect [radio=radio1] [ip=] [env=]
#      Sin radio=: desconecta todos los clientes STA activos
router-wifi-disconnect radio="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="disconnect --env {{ env }}"
    if [ -n "{{ radio }}" ]; then ARGS="${ARGS} --radio {{ radio }}"; fi
    if [ -n "{{ ip }}" ];    then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-wifi.sh ${ARGS}

# router-wifi-scan: Escanea redes WiFi disponibles
# Sin args: escanea ambos radios (2.4 GHz y 5 GHz)
# Uso: just router-wifi-scan [--radio 2g|5g|radio0|radio1] [--env dev] [--ip 192.168.x.x]
router-wifi-scan *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wifi.sh scan {{args}}

# router-wifi-status: Muestra estado de todos los radios e interfaces WiFi
# Uso: just router-wifi-status [ip=] [env=]
router-wifi-status ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="status --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-wifi.sh ${ARGS}

# router-wifi-enable: Habilita un radio WiFi
# Uso: just router-wifi-enable radio=radio0|2g|radio1|5g [ip=] [env=]
router-wifi-enable radio="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ radio }}" ]; then echo "ERROR: especifica radio=<radio0|radio1|2g|5g>"; exit 1; fi
    ARGS="enable --radio {{ radio }} --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-wifi.sh ${ARGS}

# router-wifi-disable: Deshabilita un radio WiFi
# Uso: just router-wifi-disable radio=radio0|2g|radio1|5g [ip=] [env=]
router-wifi-disable radio="" ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{ radio }}" ]; then echo "ERROR: especifica radio=<radio0|radio1|2g|5g>"; exit 1; fi
    ARGS="disable --radio {{ radio }} --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-wifi.sh ${ARGS}

# ---------------------------------------------------------------------------
# Routing (prioridad WAN vs WiFi cliente y source-based routing)
# ---------------------------------------------------------------------------

# router-routing-status: Muestra rutas, gateways y métricas actuales
# Uso: just router-routing-status [ip=] [env=]
router-routing-status ip="" env="prod":
    #!/usr/bin/env bash
    set -euo pipefail
    ARGS="status --env {{ env }}"
    if [ -n "{{ ip }}" ]; then ARGS="${ARGS} --ip {{ ip }}"; fi
    # shellcheck disable=SC2086
    scripts/router/setup-routing.sh ${ARGS}

# router-routing-priority: Define qué interfaz es la salida preferida
# Uso: just router-routing-priority <wan|wifi|equal> [--env dev] [--ip 192.168.x.x]
router-routing-priority *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-routing.sh priority {{args}}

# router-routing-pin: Fija el tráfico de una IP LAN a una interfaz concreta
# Uso: just router-routing-pin --from 192.168.1.50 --via wifi [--env dev]
router-routing-pin *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-routing.sh pin {{args}}

# router-routing-unpin: Elimina el pin de enrutamiento para una IP LAN
# Uso: just router-routing-unpin --from 192.168.1.50 [--env dev]
router-routing-unpin *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-routing.sh unpin {{args}}

# router-routing-pins: Lista todos los pins de enrutamiento activos
# Uso: just router-routing-pins [--env dev] [--ip 192.168.x.x]
router-routing-pins *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-routing.sh pins {{args}}

# router-routing-reset: Elimina todos los pins y restaura prioridad a WAN
# Uso: just router-routing-reset [--env dev] [--ip 192.168.x.x]
router-routing-reset *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-routing.sh reset {{args}}

# ---------------------------------------------------------------------------
# IPs Estáticas (DHCP leases por MAC address)
# ---------------------------------------------------------------------------

# router-static-ip-add: Asigna IP estática a un MAC address
# Uso: just router-static-ip-add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 [--name servidor]
router-static-ip-add *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-static-ip.sh add {{args}}

# router-static-ip-remove: Elimina asignación de IP estática (por MAC o por IP)
# Uso: just router-static-ip-remove --mac AA:BB:CC:DD:EE:FF
#      just router-static-ip-remove --assign 192.168.1.100
router-static-ip-remove *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-static-ip.sh remove {{args}}

# router-static-ip-list: Muestra todas las asignaciones de IP estática
# Uso: just router-static-ip-list [--env dev] [--ip 192.168.x.x]
router-static-ip-list *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-static-ip.sh list {{args}}

# router-static-ip-clear: Elimina TODAS las asignaciones de IP estática
# Uso: just router-static-ip-clear [--env dev] [--ip 192.168.x.x]
router-static-ip-clear *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-static-ip.sh clear {{args}}

# router-static-ip-import: Importa asignaciones desde CSV (MAC,IP,nombre)
# Uso: just router-static-ip-import --file hosts.csv [--env dev]
router-static-ip-import *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-static-ip.sh import {{args}}

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

# router-dns-set: Configura los servidores DNS upstream del router
# Sin args: usa Cloudflare (1.1.1.1) + Google (8.8.8.8)
# Uso: just router-dns-set [--primary 9.9.9.9] [--secondary 149.112.112.112] [--env dev]
router-dns-set *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-dns.sh set {{args}}

# router-dns-show: Muestra la configuración DNS actual del router
# Uso: just router-dns-show [--ip 192.168.x.x] [--env dev]
router-dns-show *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-dns.sh show {{args}}

# router-dns-reset: Restaura los DNS por defecto (1.1.1.1 + 8.8.8.8)
# Uso: just router-dns-reset [--ip 192.168.x.x] [--env dev]
router-dns-reset *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-dns.sh reset {{args}}

# ---------------------------------------------------------------------------
# Clientes DHCP
# ---------------------------------------------------------------------------

# router-clients: Lista los dispositivos conectados al router (leases DHCP + tabla ARP)
# Uso: just router-clients [--ip 192.168.x.x] [--env dev]
router-clients *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/show-clients.sh {{args}}

# router-lan-doctor: Valida comunicación interna LAN desde router y un origen opcional
# Uso: just router-lan-doctor [--ip 192.168.x.x] [--source local|user@host] [--target IP]
router-lan-doctor *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/lan-doctor.sh {{args}}

# ---------------------------------------------------------------------------
# SOCKS Forward (Raspi3b / Tor)
# ---------------------------------------------------------------------------

# router-socks-enable: Activa el port forwarding del proxy SOCKS de la Raspi3b (Tor)
# Pide la IP de la Raspi interactivamente, asigna IP estática en DHCP y crea la regla DNAT
# Uso: just router-socks-enable [--raspi-ip 192.168.1.x] [--port 9050]
router-socks-enable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-socks-forward.sh enable {{args}}

# router-socks-disable: Desactiva el port forwarding del proxy SOCKS (elimina la regla DNAT)
# Uso: just router-socks-disable [--ip 192.168.x.x] [--env dev]
router-socks-disable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-socks-forward.sh disable {{args}}

# router-socks-uninstall: Elimina la regla DNAT y la IP estática de la Raspi en DHCP
# Uso: just router-socks-uninstall [--ip 192.168.x.x] [--env dev]
router-socks-uninstall *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-socks-forward.sh uninstall {{args}}

# router-socks-status: Muestra el estado del port forwarding SOCKS y la IP estática de la Raspi
# Uso: just router-socks-status [--ip 192.168.x.x] [--env dev]
router-socks-status *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-socks-forward.sh status {{args}}

# ---------------------------------------------------------------------------
# Transparent .onion proxy (Tor via Raspi3b)
# ---------------------------------------------------------------------------

# router-onion-enable: Activa el transparent proxy .onion (dnsmasq + nftables DNAT)
# Pide IP de la Raspi si no se indica; auto-detecta desde raspi-tor en DHCP
# Uso: just router-onion-enable [--raspi-ip 192.168.1.x] [--dns-port 5300] [--trans-port 9040]
router-onion-enable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-tor-onion.sh enable {{args}}

# router-onion-disable: Desactiva el DNAT .onion (conserva la entrada dnsmasq)
# Uso: just router-onion-disable [--ip 192.168.x.x] [--env dev]
router-onion-disable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-tor-onion.sh disable {{args}}

# router-onion-uninstall: Elimina el DNAT y la entrada dnsmasq .onion (limpieza total)
# Uso: just router-onion-uninstall [--ip 192.168.x.x] [--env dev]
router-onion-uninstall *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-tor-onion.sh uninstall {{args}}

# router-onion-status: Muestra el estado del transparent proxy .onion
# Uso: just router-onion-status [--ip 192.168.x.x] [--env dev]
router-onion-status *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-tor-onion.sh status {{args}}

# router-onion-doctor: Diagnostica el stack .onion capa por capa (DHCP → dnsmasq → nftables → puertos Tor)
# Muestra ✅/❌/⚠️ por check y sugerencias de corrección; sale con código 1 si hay errores
# Uso: just router-onion-doctor [--ip 192.168.x.x] [--dns-port 5300] [--trans-port 9040]
router-onion-doctor *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-tor-onion.sh doctor {{args}}

# ---------------------------------------------------------------------------
# Backup y restauración
# ---------------------------------------------------------------------------

# router-backup: Descarga backup de /etc/config del router a ./backups/
# Uso: just router-backup [ip=] [env=] [dir=]
router-backup *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/backup.sh backup {{args}}

# router-restore: Aplica un backup local en el router y reinicia
# Uso: just router-restore --file backups/router-YYYYMMDD.tar.gz [ip=] [env=]
router-restore *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/backup.sh restore {{args}}

# router-backup-list: Lista los backups locales disponibles en ./backups/
router-backup-list *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/backup.sh list {{args}}

# ---------------------------------------------------------------------------
# Estado y reinicio
# ---------------------------------------------------------------------------

# router-status: Muestra estado general del router (sistema, red, WiFi, clientes, servicios)
# Uso: just router-status [ip=] [env=]
router-status *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/status.sh {{args}}

# router-reboot: Reinicia el router via SSH
# Uso: just router-reboot [ip=] [env=] [--wait]
router-reboot *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/reboot.sh {{args}}

# ---------------------------------------------------------------------------
# WireGuard
# ---------------------------------------------------------------------------

# router-wireguard-status: Muestra estado del túnel WireGuard y peers activos
# Uso: just router-wireguard-status [ip=] [env=]
router-wireguard-status *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wireguard.sh status {{args}}

# router-wireguard-enable / disable: Activa o desactiva la interfaz wg0
# Uso: just router-wireguard-enable [ip=] [env=]
router-wireguard-enable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wireguard.sh enable {{args}}

router-wireguard-disable *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wireguard.sh disable {{args}}

# router-wireguard-peer-list: Lista los peers WireGuard configurados en UCI
# Uso: just router-wireguard-peer-list [ip=] [env=]
router-wireguard-peer-list *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wireguard.sh peer-list {{args}}

# router-wireguard-peer-add: Añade un peer al túnel WireGuard
# Uso: just router-wireguard-peer-add --pubkey <key> --endpoint <IP:port> --allowed-ips <CIDR> [--name <n>]
router-wireguard-peer-add *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wireguard.sh peer-add {{args}}

# router-wireguard-peer-remove: Elimina un peer WireGuard por su clave pública
# Uso: just router-wireguard-peer-remove --pubkey <key> [ip=] [env=]
router-wireguard-peer-remove *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-wireguard.sh peer-remove {{args}}

# ---------------------------------------------------------------------------
# Port forwarding
# ---------------------------------------------------------------------------

# router-port-forward-list: Lista todas las reglas de port forwarding
# Uso: just router-port-forward-list [ip=] [env=]
router-port-forward-list *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-port-forward.sh list {{args}}

# router-port-forward-add: Añade una regla de port forwarding (DNAT desde WAN)
# Uso: just router-port-forward-add --name <n> --port <ext> --dest-ip <IP> [--dest-port <p>] [--proto tcp|udp|both]
router-port-forward-add *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-port-forward.sh add {{args}}

# router-port-forward-remove: Elimina una regla de port forwarding por nombre
# Uso: just router-port-forward-remove --name <nombre> [ip=] [env=]
router-port-forward-remove *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-port-forward.sh remove {{args}}

# router-port-forward-status: Muestra reglas activas con contadores nftables
# Uso: just router-port-forward-status [ip=] [env=]
router-port-forward-status *args='':
    #!/usr/bin/env bash
    # shellcheck disable=SC2086
    scripts/router/setup-port-forward.sh status {{args}}

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
