# Uso de Just — Task Manager

`justfile` es el **único punto de entrada** del proyecto. Orquesta todas las tareas: setup, secrets, build, validación, flasheo y configuración del router.

Antes de compilar con `just build-prod`, revisa [Configuración de Build](CONFIGURACION_BUILD.md) para saber qué archivos controlan versión, modelo, paquetes, secrets y overlay.

```bash
just --list                    # Ver todas las recipes disponibles
just <recipe>                  # Ejecutar una recipe
```

## Recipes

### Setup

| Recipe | Descripción |
|--------|-------------|
| `just setup [force=true]` | Setup inicial: tools + age key + environments |
| `just install-tools [force=true]` | Instalar herramientas faltantes (`just`, `make`, `sops`, `age`, `yq`) |
| `just validate-tools` | Verificar herramientas instaladas con sus versiones |
| `just generate-age-key` | Generar clave age en `~/.age/poc-openwrt-privkey.txt` |
| `just create-environments` | Crear `environments/{dev,prod}/` con `.env.public` y secrets vacíos encriptados |
| `just setup-hooks` | Configurar `.githooks/` como directorio de hooks de git |

### Secrets

| Recipe | Descripción |
|--------|-------------|
| `just reinit-secrets <env>` | Re-encriptar secrets con la clave age local (usar al clonar el repo) |
| `just decrypt-secrets <env>` | Desencriptar secrets → `/tmp/secrets-<env>.yaml` |
| `just edit-secrets <env>` | Abrir secrets en `$EDITOR` para editar (WiFi keys, WireGuard, etc.) |
| `just create-password <env>` | Pedir contraseña root, generar hash SHA-512 e inyectarlo en secrets |

### Paquetes

| Recipe | Descripción |
|--------|-------------|
| `just packages` | Mostrar paquetes de firmware agrupados (desde `config/openwrt-packages.toml`) |
| `just refresh-packages` | Regenerar `config/openwrt-packages.txt` desde el TOML |

### Build

| Recipe | Descripción |
|--------|-------------|
| `just setup-env [ENV=prod]` | Descarga y extrae el Image Builder de OpenWRT (ejecutar una vez por máquina) |
| `just build` | Compilar sin secrets (valores por defecto) |
| `just build-dev` | Compilar para desarrollo (verifica secrets dev, genera config, compila) |
| `just build-prod` | Compilar para producción (verifica secrets prod, genera config, compila) |
| `just generate-config <env>` | Generar archivos de configuración desde templates + secrets |

> **Nota**: `just setup-env` debe ejecutarse antes del primer `just build-*` en cada máquina nueva. Lee `OPENWRT_VERSION`, `TARGET` y `SUBTARGET` desde `environments/<env>/.env.public`.

### Validación

| Recipe | Descripción |
|--------|-------------|
| `just validate` | Ejecutar `shellcheck` en todos los scripts |
| `just validate-tools` | Verificar que todas las herramientas están instaladas |

### Update / Flasheo

| Recipe | Descripción |
|--------|-------------|
| `just router-update [ip=<IP>] [env=<env>]` | Actualizar firmware via sysupgrade **manteniendo** configuración |
| `just router-update-force [ip=<IP>] [env=<env>]` | Actualizar firmware **borrando** configuración del router |

La IP se infiere de `environments/<env>/.env.public` (`ROUTER_IP`). Por defecto `192.168.1.1`.

### Configuración inicial del router

| Recipe | Descripción |
|--------|-------------|
| `just router-copy-keys [--ip <IP>] [--env <env>] [--key <path>]` | Copia clave SSH pública a Dropbear sin cambiar contraseña root |
| `just router-setup-extroot [ip=] [device=] [env=]` | Configura USB como extroot (`/overlay`) para ampliar almacenamiento |
| `just router-setup-logs-ram [ip=] [env=]` | Buffer de logs en RAM (64 KB) — sin USB, no persisten entre reinicios |
| `just router-setup-logs-file [ip=] [env=]` | Logs persistentes en archivo (`/overlay/log/messages`) — requiere extroot activo |
| `just router-setup-auth [ip=] [env=] [key=]` | Copia clave SSH pública al router y establece contraseña root |

### Post-instalación de paquetes

| Recipe | Descripción |
|--------|-------------|
| `just router-post-install [group=] [ip=] [env=]` | Instala paquetes adicionales via `apk`/`opkg` (lee `openwrt-post-install-packages.toml`) |

Ejemplo:
```bash
just router-post-install                          # Instala todos los grupos
just router-post-install group=captive_portal     # Solo el grupo captive_portal (uhttpd)
scripts/router/post-install.sh --list             # Ver grupos disponibles
```

### Portal cautivo

Requiere: `just router-post-install group=captive_portal` (instala `uhttpd`).

| Recipe | Descripción |
|--------|-------------|
| `just router-captive-setup [ip=] [env=] [timeout=30] [portal-url=] [token=]` | Instala el portal cautivo (nftables + uhttpd) |
| `just router-captive-remove [ip=] [env=]` | Desinstala el portal cautivo |
| `just router-captive-allow client=<IP> [timeout=30] [ip=] [env=]` | Autoriza una IP manualmente (`timeout=0` = permanente) |
| `just router-captive-block client=<IP> [ip=] [env=]` | Revoca el acceso de una IP |
| `just router-captive-flush [ip=] [env=]` | Limpia todos los clientes autorizados |
| `just router-captive-list [ip=] [env=]` | Lista clientes autorizados y estado del portal |
| `just router-captive-status [ip=] [env=]` | Diagnóstico completo del portal |

Ejemplos:
```bash
just router-captive-setup                                      # Portal local (HTML en el router)
just router-captive-setup portal-url=https://portal.example.com token=abc123  # Portal externo
just router-captive-allow client=192.168.1.50                 # 30 min (default)
just router-captive-allow client=192.168.1.50 timeout=120     # 2 horas
just router-captive-allow client=192.168.1.50 timeout=0       # Sin límite
```

### WiFi

Todas las recipes pasan argumentos directamente al script (`--flag valor`).

| Recipe | Descripción |
|--------|-------------|
| `just router-wifi-ap` | AP interactivo: detecta radios libres → SSID → contraseña → canal |
| `just router-wifi-client` | Cliente interactivo: selecciona banda → escanea → SSID → contraseña |
| `just router-wifi-disconnect` | Desconecta todos los clientes STA y elimina interfaz `wwan` |
| `just router-wifi-scan` | Escanea 2.4 GHz y 5 GHz; con `--radio` solo esa banda |
| `just router-wifi-status` | Estado de radios e interfaces (banda, canal, SSID, clientes) |
| `just router-wifi-enable --radio <r>` | Habilita un radio |
| `just router-wifi-disable --radio <r>` | Deshabilita un radio |

Alias de radio válidos: `radio0`, `radio1`, `2g`, `5g`, `2.4ghz`, `5ghz`.

Ejemplos:
```bash
just router-wifi-ap                                       # AP completamente interactivo
just router-wifi-ap --ssid MiRed --radio 5g              # Pre-selecciona radio y SSID
just router-wifi-ap --ssid MiRed --channel 36 --open     # Sin contraseña, canal fijo

just router-wifi-client                                   # Interactivo: elige banda → escanea
just router-wifi-client --radio 2.4ghz                   # Fuerza 2.4 GHz, luego interactivo
just router-wifi-client --radio 5g --ssid RedExterna     # Fuerza radio y SSID

just router-wifi-disconnect                               # Desconecta todos los clientes
just router-wifi-disconnect --radio radio0               # Solo desconecta radio0

just router-wifi-scan                                     # Escanea 2.4 GHz y 5 GHz
just router-wifi-scan --radio 5g                         # Solo 5 GHz
just router-wifi-scan --radio radio0                     # Solo 2.4 GHz

just router-wifi-status
just router-wifi-disable --radio radio1
just router-wifi-enable --radio radio0
```

### Routing

Gestiona qué interfaz usa el router como salida a internet y permite fijar IPs LAN a interfaces concretas.

| Recipe | Descripción |
|--------|-------------|
| `just router-routing-status` | Muestra rutas, gateways, métricas y pins activos |
| `just router-routing-priority <wan\|wifi\|equal>` | Define la interfaz de salida preferida |
| `just router-routing-pin --from <IP> --via <wan\|wifi>` | Fija tráfico de una IP LAN a una interfaz concreta |
| `just router-routing-unpin --from <IP>` | Elimina el pin de una IP LAN |
| `just router-routing-pins` | Lista todos los pins activos |
| `just router-routing-reset` | Elimina todos los pins y restaura prioridad a WAN |

Modos de prioridad:
- `wan` — WAN físico como gateway preferido (métrica más baja)
- `wifi` — Cliente WiFi (`wwan`) como gateway preferido
- `equal` — Ambas interfaces con la misma métrica

Los pins de enrutamiento persisten entre reinicios vía `/etc/router-routing-pins.conf` y un hotplug script.

Ejemplos:
```bash
just router-routing-priority wifi                               # Preferir WiFi cliente
just router-routing-priority wan                                # Preferir WAN físico
just router-routing-pin --from 192.168.1.50 --via wifi         # Laptop siempre por WiFi
just router-routing-pin --from 192.168.1.51 --via wan          # Servidor siempre por WAN
just router-routing-unpin --from 192.168.1.50
just router-routing-reset
```

### IPs Estáticas

Gestiona DHCP static leases: asigna IPs fijas a dispositivos por MAC address.

| Recipe | Descripción |
|--------|-------------|
| `just router-static-ip-add --mac <MAC> --assign <IP> [--name <nombre>]` | Asigna IP estática a un dispositivo |
| `just router-static-ip-remove --mac <MAC>` o `--assign <IP>` | Elimina asignación por MAC o por IP |
| `just router-static-ip-list` | Muestra todas las asignaciones + leases activos |
| `just router-static-ip-clear` | Elimina todas las asignaciones |
| `just router-static-ip-import --file <csv>` | Importa desde CSV (formato: `MAC,IP,nombre`) |

Ejemplos:
```bash
just router-static-ip-add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 --name servidor
just router-static-ip-remove --mac AA:BB:CC:DD:EE:FF
just router-static-ip-remove --assign 192.168.1.100
just router-static-ip-list
just router-static-ip-import --file hosts.csv
```

### DNS

Configura los servidores DNS upstream que usa dnsmasq para resolver nombres.

| Recipe | Descripción |
|--------|-------------|
| `just router-dns-set` | Configura DNS (default: 1.1.1.1 Cloudflare + 8.8.8.8 Google) |
| `just router-dns-show` | Muestra la configuración DNS actual |
| `just router-dns-reset` | Restaura DNS por defecto (1.1.1.1 + 8.8.8.8) |

Ejemplos:
```bash
just router-dns-set                                              # Cloudflare + Google
just router-dns-set --primary 9.9.9.9                           # Quad9 + Google
just router-dns-set --primary 9.9.9.9 --secondary 149.112.112.112  # Quad9 solo
just router-dns-set --primary 208.67.222.222 --secondary 208.67.220.220  # OpenDNS
just router-dns-show
just router-dns-reset
```

### Transparent .onion proxy (Tor via Raspi3b)

Configura OpenWRT para enrutar dominios `.onion` a través de Tor en la Raspi3b de forma transparente. Los clientes WiFi/LAN acceden a `.onion` sin configurar ningún proxy.

| Recipe | Descripción |
|--------|-------------|
| `just router-onion-enable` | Activa el transparent proxy: dnsmasq `.onion` + nftables DNAT + MASQUERADE |
| `just router-onion-disable` | Desactiva el DNAT (conserva la entrada dnsmasq `.onion`) |
| `just router-onion-uninstall` | Limpieza total: elimina DNAT + entrada dnsmasq |
| `just router-onion-status` | Muestra estado del include UCI, archivo nftables y prueba DNS en vivo |
| `just router-onion-doctor` | Diagnóstico capa por capa: DHCP → dnsmasq → nftables → puertos Tor en la Raspi |

Ejemplos:
```bash
just router-onion-enable                                 # Auto-detecta IP raspi-tor desde DHCP
just router-onion-enable --raspi-ip 192.168.1.100        # IP explícita (puertos default: 5300 + 9040)
just router-onion-disable                                # Solo quita DNAT, conserva DNS
just router-onion-uninstall                              # Limpieza total
just router-onion-status                                 # Ver estado y prueba DNS en vivo
just router-onion-doctor                                 # Diagnostica todo el stack, sale con código 1 si hay errores
```

Prerrequisito en la Raspi3b (`/etc/tor/torrc`):
```
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 0.0.0.0:9040
DNSPort  0.0.0.0:5300   # evitar conflicto con mDNS (puerto 5353)
```

**Requisito de red en los clientes**: el proxy transparente solo funciona si el dispositivo usa el router OpenWRT como resolver DNS. Si el equipo tiene varias interfaces de red activas (p.ej. WiFi a otra red + ethernet al OpenWRT), las consultas `.onion` pueden salir por la interfaz incorrecta y no pasar por dnsmasq del router.

En equipos Linux con `systemd-resolved` verificar con `resolvectl status` que la interfaz ethernet al OpenWRT tiene prioridad. Regla práctica: si `cat /etc/resolv.conf` muestra `127.0.0.53`, el equipo usa systemd-resolved — asegurarse de que la ruta de DNS para `.onion` llega al router.

**Alternativa SOCKS5** (no depende de qué interfaz esté activa):
```bash
# Acceso puntual
curl --socks5-hostname 192.168.1.136:9050 http://dominio.onion

# Variables de entorno para la sesión
export http_proxy=socks5h://192.168.1.136:9050
export https_proxy=socks5h://192.168.1.136:9050
curl http://dominio.onion
```

### SOCKS Forward (Raspi3b / Tor)

Activa o desactiva el port forwarding del proxy SOCKS de la Raspberry Pi 3b para que dispositivos en la red upstream puedan usarlo.

| Recipe | Descripción |
|--------|-------------|
| `just router-socks-enable` | Activa el forwarding: pide IP de la Raspi, fija IP estática en DHCP y crea la regla DNAT |
| `just router-socks-disable` | Elimina la regla DNAT del firewall |
| `just router-socks-uninstall` | Elimina la regla DNAT **y** la IP estática de la Raspi en DHCP |
| `just router-socks-status` | Muestra el estado de la regla y la IP estática de la Raspi |

Diferencia entre `disable` y `uninstall`:
- `disable` — solo elimina la regla de port forwarding. La IP estática de la Raspi queda en DHCP.
- `uninstall` — limpieza completa: elimina la regla DNAT y la entrada DHCP `raspi-tor`. Deja el router como si nunca se hubiera configurado.

Ejemplos:
```bash
just router-socks-enable                                 # Interactivo: pide IP de la Raspi
just router-socks-enable --raspi-ip 192.168.1.100        # Con IP predefinida (puerto default 9050)
just router-socks-enable --raspi-ip 192.168.1.100 --port 9050
just router-socks-disable                                # Quita el forwarding, conserva IP estática
just router-socks-uninstall                              # Limpieza total
just router-socks-status
```

Flujo de `router-socks-enable`:
1. Pide la IP actual de la Raspi3b (si no se pasa con `--raspi-ip`)
2. Detecta la MAC de la Raspi en la tabla ARP del router
3. Llama a `setup-static-ip.sh add` para fijar la IP en DHCP como `raspi-tor`
4. Crea la regla DNAT `wan:<port> → raspi:<port>` en el firewall UCI
5. Muestra el comando `curl --socks5` para verificar desde el Mac

### Clientes DHCP

Lista los dispositivos conectados al router: leases DHCP activos y tabla ARP.

| Recipe | Descripción |
|--------|-------------|
| `just router-clients` | Lista dispositivos conectados (leases DHCP + tabla ARP) |

Ejemplos:
```bash
just router-clients                        # Red por defecto (prod)
just router-clients --env dev              # Entorno dev
just router-clients --ip 192.168.0.1      # IP del router explícita
```

### Backup y restauración

Guarda y restaura la configuración del router (`/etc/config`) usando `sysupgrade -b`.
Los backups se descargan localmente a `./backups/`.

| Recipe | Descripción |
|--------|-------------|
| `just router-backup` | Descarga backup de configuración a `./backups/` |
| `just router-restore --file <path>` | Aplica un backup en el router y reinicia |
| `just router-backup-list` | Lista los backups locales disponibles |

Ejemplos:
```bash
just router-backup                                          # Descarga backup con timestamp
just router-backup-list                                     # Ver backups disponibles
just router-restore --file backups/router-192.168.1.1-20260518-142300.tar.gz
```

### Estado y reinicio

| Recipe | Descripción |
|--------|-------------|
| `just router-status` | Diagnóstico general: versión, salud, RAM, almacenamiento, red, WiFi, DHCP y servicios |
| `just router-reboot` | Reinicia el router via SSH |
| `just router-reboot --wait` | Reinicia y espera hasta que el router vuelva a responder |

`router-status` muestra en una sola llamada SSH: modelo, firmware, kernel, uptime, carga, package manager, RAM/swap, almacenamiento, extroot, rutas, IPs WAN/LAN/WWAN/WireGuard, radios e interfaces WiFi, leases DHCP, servicios instalados/habilitados/activos y pruebas de salud de internet/DNS.

```bash
just router-status
just router-status --ip 192.168.1.1
just router-reboot --wait     # útil en scripts: bloquea hasta reconexión (~60s)
```

### WireGuard

Gestiona el túnel WireGuard (`wg0`) configurado vía UCI en el router. WireGuard ya está incluido en la imagen compilada.

| Recipe | Descripción |
|--------|-------------|
| `just router-wireguard-status` | Estado del túnel y peers activos (`wg show`) |
| `just router-wireguard-enable` | Activa la interfaz `wg0` |
| `just router-wireguard-disable` | Desactiva la interfaz `wg0` |
| `just router-wireguard-peer-list` | Lista los peers configurados en UCI |
| `just router-wireguard-peer-add --pubkey <k> --endpoint <IP:port> --allowed-ips <CIDR>` | Añade un peer |
| `just router-wireguard-peer-remove --pubkey <k>` | Elimina un peer por su clave pública |

Ejemplos:
```bash
just router-wireguard-status
just router-wireguard-peer-list
just router-wireguard-peer-add \
    --pubkey "abc123...==" \
    --endpoint "1.2.3.4:51820" \
    --allowed-ips "10.0.0.2/32" \
    --name "laptop"
just router-wireguard-peer-remove --pubkey "abc123...=="
just router-wireguard-disable
```

### Port forwarding

Gestiona reglas DNAT desde la WAN hacia hosts de la LAN vía UCI (`firewall redirect`).

| Recipe | Descripción |
|--------|-------------|
| `just router-port-forward-list` | Lista todas las reglas de port forwarding |
| `just router-port-forward-add --name <n> --port <ext> --dest-ip <IP>` | Añade una regla DNAT |
| `just router-port-forward-remove --name <n>` | Elimina una regla por nombre |
| `just router-port-forward-status` | Muestra reglas activas con contadores nftables en vivo |

Opciones de `add`:
- `--dest-port <p>` — puerto destino si difiere del externo (default: igual a `--port`)
- `--proto tcp|udp|both` — protocolo (default: `tcp`); `both` crea dos reglas

Ejemplos:
```bash
just router-port-forward-list
just router-port-forward-add --name "web" --port 8080 --dest-ip 192.168.1.50
just router-port-forward-add --name "nas-smb" --port 445 --dest-ip 192.168.1.30 --proto both
just router-port-forward-add --name "ssh-raspi" --port 2222 --dest-ip 192.168.1.136 --dest-port 22
just router-port-forward-remove --name "web"
just router-port-forward-status
```

### Limpieza

| Recipe | Descripción |
|--------|-------------|
| `just clean` | Limpiar artefactos de compilación |
| `just clean-all` | Limpiar artefactos + overlay de configuración |

---

## Flujos de trabajo típicos

### Primera vez (o máquina nueva)

```bash
# macOS
brew install just sops age yq shellcheck

# Linux: just setup descarga los binarios a ~/.local/bin automáticamente
just setup                      # tools + age key + environments + git hooks

# Re-encriptar secrets con la clave de esta máquina
just reinit-secrets prod
just reinit-secrets dev

# (Opcional) Llenar secrets
just edit-secrets prod          # WiFi keys, WireGuard, etc.
just create-password prod       # Hash SHA-512 de root

# Descargar el Image Builder (una vez por máquina, antes del primer build)
just setup-env prod
```

### Compilar y flashear

```bash
just build-prod
# Sigue docs/FLASH_INSTRUCTIONS.md para el flasheo físico

# Post-flash: configuración inicial del router
just router-setup-auth                 # Clave SSH + contraseña root
just router-setup-extroot              # USB como extroot (si hay USB conectado)
just router-setup-logs-ram             # Buffer de logs en RAM (64 KB, sin USB)
# o si hay USB con extroot activo:
just router-setup-logs-file            # Logs persistentes en /overlay/log/messages
```

### Configurar WiFi

```bash
just router-wifi-status                                         # Ver estado actual

just router-wifi-ap                                             # AP interactivo (detecta radios libres)
just router-wifi-ap --ssid MiRed --radio 5g                    # Pre-selecciona radio

just router-wifi-client                                         # Interactivo: banda → escanea → SSID
just router-wifi-client --radio 2.4ghz                         # Fuerza 2.4 GHz, resto interactivo

just router-wifi-scan                                           # Escanea 2.4 GHz y 5 GHz
just router-wifi-scan --radio 5g                               # Solo 5 GHz

just router-dns-set                                             # DNS Cloudflare + Google
just router-dns-set --primary 9.9.9.9                          # Cambiar DNS primario
```

### Instalar portal cautivo

```bash
just router-post-install group=captive_portal  # Instala uhttpd en el router
just router-captive-setup                      # Instala el portal (30 min por defecto)
just router-captive-status                     # Verificar que funciona
just router-captive-allow client=192.168.1.50  # Autorizar dispositivo manualmente
```

### Verificar estado y hacer backup antes de actualizar

```bash
just router-status                                      # Vista general: sistema, red, servicios
just router-backup                                      # Descarga backup a ./backups/ con timestamp
just router-backup-list                                 # Ver backups disponibles

just router-update                                      # Actualizar firmware (mantiene config)

# Si algo sale mal: restaurar desde backup
just router-restore --file backups/router-192.168.1.1-20260518-142300.tar.gz
```

### Reiniciar el router

```bash
just router-reboot                                      # Reboot inmediato (retorna al instante)
just router-reboot --wait                               # Reboot + espera hasta reconexión (~60s)
```

### Gestionar WireGuard

```bash
just router-wireguard-status                            # Estado del túnel y peers activos
just router-wireguard-peer-list                         # Peers configurados en UCI

just router-wireguard-peer-add \
    --pubkey "abc123...==" \
    --endpoint "1.2.3.4:51820" \
    --allowed-ips "10.0.0.2/32" \
    --name "laptop"

just router-wireguard-peer-remove --pubkey "abc123...=="
just router-wireguard-disable                           # Apagar el túnel temporalmente
```

### Gestionar port forwarding

```bash
just router-port-forward-list                                                      # Ver reglas activas
just router-port-forward-add --name "web" --port 8080 --dest-ip 192.168.1.50      # HTTP
just router-port-forward-add --name "nas-smb" --port 445 --dest-ip 192.168.1.30 --proto both
just router-port-forward-add --name "ssh-raspi" --port 2222 --dest-ip 192.168.1.136 --dest-port 22
just router-port-forward-status                                                    # Contadores nftables en vivo
just router-port-forward-remove --name "web"
```

### Gestionar routing

```bash
# Router con WAN físico + cliente WiFi (router-wifi-client):
just router-routing-status                                               # Ver configuración actual
just router-routing-priority wifi                                        # Preferir WiFi como salida
just router-routing-pin --from 192.168.1.100 --via wan                  # NAS siempre por WAN
just router-routing-pin --from 192.168.1.50  --via wifi                 # Laptop siempre por WiFi
just router-routing-unpin --from 192.168.1.50
just router-routing-reset
```

### Asignar IPs fijas

```bash
just router-static-ip-add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.10 --name nas
just router-static-ip-add --mac BB:CC:DD:EE:FF:00 --assign 192.168.1.11 --name impresora
just router-static-ip-list
just router-static-ip-remove --mac AA:BB:CC:DD:EE:FF
```

---

## Relación Just ↔ Make

| Regla | Descripción |
|-------|-------------|
| Just → Make | ✅ Just puede llamar a Make |
| Make → Just | ❌ Make NUNCA llama a Just |
| Sin duplicados | No hay tareas duplicadas entre ambos |

- **`just`**: Orquesta (setup, secrets, router, flujo completo)
- **`make`**: Build y validación (compile, shellcheck, clean)
