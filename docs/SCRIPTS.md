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
├── build/                      # Compilación y configuración del router
│   ├── openwrt.sh              # Orquestador principal de compilación
│   ├── compile.sh              # Lógica de `make image`
│   ├── update.sh               # Actualiza firmware via SSH + sysupgrade
│   ├── verify.sh               # Validación de imagen compilada
│   ├── convert-toml-packages.sh # Conversor TOML → TXT (standalone)
│   ├── post-install.sh         # Instala paquetes adicionales via opkg
│   ├── setup-extroot.sh        # Configura USB como extroot (/overlay)
│   ├── setup-logs.sh           # Logs persistentes en USB (extroot)
│   ├── setup-auth.sh           # Copia clave SSH pública + contraseña root
│   ├── setup-captive.sh        # Portal cautivo nftables + uhttpd
│   ├── setup-wifi.sh           # Gestión WiFi (AP, cliente, scan, enable/disable)
│   ├── setup-routing.sh        # Prioridad de rutas y source-based routing
│   └── setup-static-ip.sh      # IPs estáticas por MAC address (DHCP leases)
└── templates/                  # Generación de configuraciones
    └── generate.sh             # Reemplaza placeholders en templates con secrets
```

## Wrapper raíz

`build-openwrt.sh` en la raíz es un wrapper que redirige a `scripts/build/openwrt.sh`:

```bash
#!/usr/bin/env bash
exec "$(dirname "$0")/scripts/build/openwrt.sh" "$@"
```

---

## Scripts de compilación (build/)

### build/openwrt.sh

Orquestador principal. Detecta `config/openwrt-packages.toml` y auto-genera `.txt`:

```bash
./scripts/build/openwrt.sh --builder openwrt-builder/*/
./scripts/build/openwrt.sh --profile tplink_tl-wdr3600-v1 --packages config/openwrt-packages.txt
```

### build/update.sh

Actualiza el firmware del router via SSH y `sysupgrade`:

```bash
scripts/build/update.sh --env prod          # Mantiene configuración
scripts/build/update.sh --ip 192.168.0.1   # IP distinta
scripts/build/update.sh --force             # Borra configuración
```

Flujo: verifica SSH → transfiere `.bin` via SCP → ejecuta `sysupgrade -v`.

### build/compile.sh

Lógica de compilación aislada — solo ejecuta `make image`.

### build/convert-toml-packages.sh

Conversor standalone: lee `config/openwrt-packages.toml` y genera el `.txt` heredado.

```bash
./scripts/build/convert-toml-packages.sh                         # stdout
./scripts/build/convert-toml-packages.sh --output config/openwrt-packages.txt
```

### build/verify.sh

Valida la imagen compilada (tamaño, checksums):

```bash
./scripts/build/verify.sh openwrt-builder/*/bin/targets/ath79/generic
```

### build/post-install.sh

Instala paquetes adicionales en el router vía `opkg` post-flash. Lee `config/openwrt-post-install-packages.toml`, que agrupa los paquetes por funcionalidad.

```bash
scripts/build/post-install.sh                          # Instala todos los grupos
scripts/build/post-install.sh --group captive_portal   # Solo un grupo
scripts/build/post-install.sh --list                   # Lista grupos sin instalar
```

Opciones: `--group <nombre>`, `--ip <IP>`, `--env <env>`, `--list`.

---

## Scripts de configuración del router (build/)

Todos estos scripts se conectan al router via SSH. Leen `ROUTER_IP` y `SSH_PORT` de `environments/<env>/.env.public`.

### build/setup-extroot.sh

Configura un USB como extroot — monta `/dev/sda1` como `/overlay` para ampliar el espacio de almacenamiento del router. Copia el overlay actual, configura UCI fstab y reinicia.

```bash
scripts/build/setup-extroot.sh --env prod
scripts/build/setup-extroot.sh --ip 192.168.1.1 --device /dev/sdb1
```

Prerrequisito: formatear el USB como ext4 antes de conectarlo al router.

### build/setup-logs.sh

Configura logs persistentes en el USB (extroot). Crea `/overlay/var/log` con link simbólico desde `/var/log`.

```bash
scripts/build/setup-logs.sh --env prod
```

Prerrequisito: `setup-extroot.sh` debe haberse ejecutado y el router reiniciado con el USB activo.

### build/setup-auth.sh

Copia la clave SSH pública al router (`/etc/dropbear/authorized_keys`) y establece la contraseña de root de forma interactiva.

```bash
scripts/build/setup-auth.sh --env prod
scripts/build/setup-auth.sh --key ~/.ssh/id_ed25519.pub  # Clave explícita
```

Auto-detecta la clave pública local en orden: `id_ed25519.pub` > `id_ecdsa.pub` > `id_rsa.pub`. Previene duplicados con `grep -qF`.

### build/setup-captive.sh

Instala y gestiona un portal cautivo usando únicamente **nftables + uhttpd** (sin OpenNDS). Redirige peticiones HTTP de clientes no autorizados al portal, que presenta una página con botón de aceptar. Al aceptar, añade la IP del cliente al set `allowed_clients` de nftables con timeout configurable.

```bash
scripts/build/setup-captive.sh install                      # Instala el portal
scripts/build/setup-captive.sh install --portal-url <URL>   # Modo portal externo
scripts/build/setup-captive.sh uninstall                    # Desinstala
scripts/build/setup-captive.sh allow 192.168.1.50           # Autoriza IP manualmente
scripts/build/setup-captive.sh allow 192.168.1.50 --timeout 0    # Permanente
scripts/build/setup-captive.sh allow 192.168.1.50 --timeout 120  # 2 horas
scripts/build/setup-captive.sh block 192.168.1.50           # Revoca acceso
scripts/build/setup-captive.sh flush                        # Limpia todos los clientes
scripts/build/setup-captive.sh list                         # Lista clientes autorizados
scripts/build/setup-captive.sh status                       # Diagnóstico del portal
```

Características:
- 21 dominios de detección de portal (Android, iOS, Windows, Huawei, Samsung, Xiaomi, Firefox, Gnome)
- `filter_aaaa=1` en dnsmasq para bloquear bypass IPv6
- DHCP option 252 (RFC 8910) para notificación directa de URL del portal
- Modo portal externo: redirige al portal con `?return=<callback>`, el portal autentica y devuelve al router
- El CGI usa `REMOTE_ADDR` (IP TCP real), no parámetros URL

Prerrequisito: `just post-install group=captive_portal` (instala `uhttpd`).

### build/setup-wifi.sh

Gestión completa de la configuración WiFi del router via UCI.

```bash
# Access Points
scripts/build/setup-wifi.sh ap --ssid "MiRed" --password "clave1234"
scripts/build/setup-wifi.sh ap --ssid "MiRed5G" --radio 5g --channel 36

# Cliente WiFi (conectar el router a otra red)
scripts/build/setup-wifi.sh client --ssid "RedExterna" --radio radio1 --password "supass"

# Escanear redes disponibles
scripts/build/setup-wifi.sh scan
scripts/build/setup-wifi.sh scan --radio 5g

# Estado y listado
scripts/build/setup-wifi.sh status
scripts/build/setup-wifi.sh list

# Habilitar / deshabilitar radio
scripts/build/setup-wifi.sh enable  --radio radio0
scripts/build/setup-wifi.sh disable --radio radio1
```

Subcomandos: `ap`, `client`, `scan`, `status`, `list`, `enable`, `disable`.

Opciones de radio: `radio0`, `radio1`, `2g`, `5g` (alias normalizados).

Modo cliente crea la interfaz `wwan` (protocolo DHCP) y la añade a la zona WAN del firewall. El escaneo parsea la salida de `iw dev scan` y presenta una tabla SSID/señal/canal/cifrado.

### build/setup-routing.sh

Gestiona la prioridad de salida a internet (WAN físico vs cliente WiFi `wwan`) y permite fijar IPs LAN a interfaces concretas mediante source-based routing (`ip rule` + tablas de routing dedicadas).

```bash
# Ver estado actual
scripts/build/setup-routing.sh status

# Definir interfaz preferida
scripts/build/setup-routing.sh priority wan    # WAN físico preferido (default)
scripts/build/setup-routing.sh priority wifi   # Cliente WiFi preferido
scripts/build/setup-routing.sh priority equal  # Misma métrica, kernel decide

# Fijar IP LAN a una interfaz (persiste entre reinicios)
scripts/build/setup-routing.sh pin --from 192.168.1.50 --via wifi
scripts/build/setup-routing.sh pin --from 192.168.1.51 --via wan

# Gestionar pins
scripts/build/setup-routing.sh unpin --from 192.168.1.50
scripts/build/setup-routing.sh pins
scripts/build/setup-routing.sh reset
```

Los pins se almacenan en `/etc/routing-pins.conf` y se restauran en cada boot mediante un hotplug script en `/etc/hotplug.d/iface/50-routing-pins`. Las tablas de routing usadas son `100` (wan) y `200` (wifi/wwan).

### build/setup-static-ip.sh

Gestiona DHCP static leases: asigna IPs fijas a dispositivos por su MAC address usando entradas UCI `dhcp host`. dnsmasq sirve siempre la misma IP al mismo dispositivo.

```bash
# Asignar IP estática
scripts/build/setup-static-ip.sh add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 --name servidor
scripts/build/setup-static-ip.sh add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100

# Eliminar asignación
scripts/build/setup-static-ip.sh remove --mac AA:BB:CC:DD:EE:FF
scripts/build/setup-static-ip.sh remove --assign 192.168.1.100

# Listar, limpiar
scripts/build/setup-static-ip.sh list
scripts/build/setup-static-ip.sh clear

# Importar desde CSV local
scripts/build/setup-static-ip.sh import --file hosts.csv
```

Formato CSV para import:
```csv
MAC,IP,nombre
AA:BB:CC:DD:EE:FF,192.168.1.100,servidor
BB:CC:DD:EE:FF:00,192.168.1.101,laptop
```

---

## Scripts de soporte (commons/, deps/, install/, git/)

### commons/logging.sh

Funciones de logging reutilizables:

```bash
source "${SCRIPT_DIR}/../commons/logging.sh"
log_info "Mensaje informativo"
log_warn "Advertencia"
log_error "Error"
log_step "Paso del proceso"
```

### commons/utils.sh

```bash
source "${SCRIPT_DIR}/../commons/utils.sh"
builder=$(find_builder "${BUILDER_DIR}")
packages=$(parse_packages "config/openwrt-packages.txt")
root=$(get_repo_root)
```

### commons/toml-parser.sh

```bash
source "${SCRIPT_DIR}/../commons/toml-parser.sh"
packages=$(parse_packages_toml "config/openwrt-packages.toml")
convert_toml_to_txt "config/openwrt-packages.toml" "config/openwrt-packages.txt"
```

### install/validate-tools.sh

```bash
just validate-tools
# ✅ just 1.36.0
# ✅ sops 3.9.4
# ✅ age v1.2.1
# ❌ shellcheck (NO INSTALADA)
```

### install/ensure-secrets.sh

Verifica disponibilidad de secrets para el build. Si no existe clave age la crea; si no puede desencriptar indica `just reinit-secrets <ENV>`.

### install/generate-password-hash.sh

Pide contraseña root en modo oculto, genera hash SHA-512-crypt (`$6$...`) e inyecta directamente en `secrets.enc.yaml`. Detecta: `openssl passwd -6` o `python3 crypt`.

```bash
just create-password prod
```

### git/check-secrets-encrypted.sh

Hook pre-commit que bloquea el commit si hay `secrets.enc.yaml` sin encriptar.

### git/setup-hooks.sh

```bash
just setup-hooks    # git config core.hooksPath .githooks
```

### templates/generate.sh

```bash
just decrypt-secrets prod
./scripts/templates/generate.sh prod   # genera configs en config/overlay/prod/
```

---

## Convenciones

- **Shebang**: `#!/usr/bin/env bash`
- **Error handling**: `set -euo pipefail` (local) — scripts remotos usan `set -eu` (BusyBox sh)
- **SSH remoto**: heredocs con marcador sin comillas (`<< REMOTE`) para expansión local; con comillas (`<< 'REMOTE'`) para pasar el script verbatim
- **Source scripts**: cada script importa `logging.sh` con path relativo a su ubicación
- **Ejecución standalone**: todos los scripts pueden ejecutarse directamente

## Validación

```bash
just validate          # shellcheck en todos los scripts
make shellcheck        # Equivalente directo
```
