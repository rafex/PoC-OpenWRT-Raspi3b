# Uso de Just — Task Manager

`justfile` es el **único punto de entrada** del proyecto. Orquesta todas las tareas: setup, secrets, build, validación, flasheo y configuración del router.

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
| `just update [ip=<IP>] [env=<env>]` | Actualizar firmware via sysupgrade **manteniendo** configuración |
| `just update-force [ip=<IP>] [env=<env>]` | Actualizar firmware **borrando** configuración del router |
| `just flash [env]` | Compilar y preparar imagen (no flashea automáticamente) |

La IP se infiere de `environments/<env>/.env.public` (`ROUTER_IP`). Por defecto `192.168.1.1`.

### Configuración inicial del router

| Recipe | Descripción |
|--------|-------------|
| `just setup-extroot [ip=] [device=] [env=]` | Configura USB como extroot (`/overlay`) para ampliar almacenamiento |
| `just setup-logs [ip=] [env=]` | Configura logs persistentes en el USB (requiere extroot activo) |
| `just setup-auth [ip=] [env=] [key=]` | Copia clave SSH pública al router y establece contraseña root |

### Post-instalación de paquetes

| Recipe | Descripción |
|--------|-------------|
| `just post-install [group=] [ip=] [env=]` | Instala paquetes adicionales via `opkg` (lee `openwrt-post-install-packages.toml`) |

Ejemplo:
```bash
just post-install                          # Instala todos los grupos
just post-install group=captive_portal     # Solo el grupo captive_portal (uhttpd)
scripts/build/post-install.sh --list       # Ver grupos disponibles
```

### Portal cautivo

Requiere: `just post-install group=captive_portal` (instala `uhttpd`).

| Recipe | Descripción |
|--------|-------------|
| `just setup-captive [ip=] [env=] [timeout=30] [portal-url=] [token=]` | Instala el portal cautivo (nftables + uhttpd) |
| `just remove-captive [ip=] [env=]` | Desinstala el portal cautivo |
| `just captive-allow client=<IP> [timeout=30] [ip=] [env=]` | Autoriza una IP manualmente (`timeout=0` = permanente) |
| `just captive-block client=<IP> [ip=] [env=]` | Revoca el acceso de una IP |
| `just captive-flush [ip=] [env=]` | Limpia todos los clientes autorizados |
| `just captive-list [ip=] [env=]` | Lista clientes autorizados y estado del portal |
| `just captive-status [ip=] [env=]` | Diagnóstico completo del portal |

Ejemplos:
```bash
just setup-captive                                      # Portal local (HTML en el router)
just setup-captive portal-url=https://portal.example.com token=abc123  # Portal externo
just captive-allow client=192.168.1.50                 # 30 min (default)
just captive-allow client=192.168.1.50 timeout=120     # 2 horas
just captive-allow client=192.168.1.50 timeout=0       # Sin límite
```

### WiFi

Todas las recipes pasan argumentos directamente al script (`--flag valor`).

| Recipe | Descripción |
|--------|-------------|
| `just wifi-ap` | AP interactivo: detecta radios libres → SSID → contraseña → canal |
| `just wifi-client` | Cliente interactivo: selecciona banda → escanea → SSID → contraseña |
| `just wifi-disconnect` | Desconecta todos los clientes STA y elimina interfaz `wwan` |
| `just wifi-scan` | Escanea 2.4 GHz y 5 GHz; con `--radio` solo esa banda |
| `just wifi-status` | Estado de radios e interfaces (banda, canal, SSID, clientes) |
| `just wifi-enable --radio <r>` | Habilita un radio |
| `just wifi-disable --radio <r>` | Deshabilita un radio |

Alias de radio válidos: `radio0`, `radio1`, `2g`, `5g`, `2.4ghz`, `5ghz`.

Ejemplos:
```bash
just wifi-ap                                       # AP completamente interactivo
just wifi-ap --ssid MiRed --radio 5g              # Pre-selecciona radio y SSID
just wifi-ap --ssid MiRed --channel 36 --open     # Sin contraseña, canal fijo

just wifi-client                                   # Interactivo: elige banda → escanea
just wifi-client --radio 2.4ghz                   # Fuerza 2.4 GHz, luego interactivo
just wifi-client --radio 5g --ssid RedExterna     # Fuerza radio y SSID

just wifi-disconnect                               # Desconecta todos los clientes
just wifi-disconnect --radio radio0               # Solo desconecta radio0

just wifi-scan                                     # Escanea 2.4 GHz y 5 GHz
just wifi-scan --radio 5g                         # Solo 5 GHz
just wifi-scan --radio radio0                     # Solo 2.4 GHz

just wifi-status
just wifi-disable --radio radio1
just wifi-enable --radio radio0
```

### Routing

Gestiona qué interfaz usa el router como salida a internet y permite fijar IPs LAN a interfaces concretas.

| Recipe | Descripción |
|--------|-------------|
| `just routing-status` | Muestra rutas, gateways, métricas y pins activos |
| `just routing-priority <wan\|wifi\|equal>` | Define la interfaz de salida preferida |
| `just routing-pin --from <IP> --via <wan\|wifi>` | Fija tráfico de una IP LAN a una interfaz concreta |
| `just routing-unpin --from <IP>` | Elimina el pin de una IP LAN |
| `just routing-pins` | Lista todos los pins activos |
| `just routing-reset` | Elimina todos los pins y restaura prioridad a WAN |

Modos de prioridad:
- `wan` — WAN físico como gateway preferido (métrica más baja)
- `wifi` — Cliente WiFi (`wwan`) como gateway preferido
- `equal` — Ambas interfaces con la misma métrica

Los pins de enrutamiento persisten entre reinicios vía `/etc/routing-pins.conf` y un hotplug script.

Ejemplos:
```bash
just routing-priority wifi                               # Preferir WiFi cliente
just routing-priority wan                                # Preferir WAN físico
just routing-pin --from 192.168.1.50 --via wifi         # Laptop siempre por WiFi
just routing-pin --from 192.168.1.51 --via wan          # Servidor siempre por WAN
just routing-unpin --from 192.168.1.50
just routing-reset
```

### IPs Estáticas

Gestiona DHCP static leases: asigna IPs fijas a dispositivos por MAC address.

| Recipe | Descripción |
|--------|-------------|
| `just static-ip-add --mac <MAC> --assign <IP> [--name <nombre>]` | Asigna IP estática a un dispositivo |
| `just static-ip-remove --mac <MAC>` o `--assign <IP>` | Elimina asignación por MAC o por IP |
| `just static-ip-list` | Muestra todas las asignaciones + leases activos |
| `just static-ip-clear` | Elimina todas las asignaciones |
| `just static-ip-import --file <csv>` | Importa desde CSV (formato: `MAC,IP,nombre`) |

Ejemplos:
```bash
just static-ip-add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 --name servidor
just static-ip-remove --mac AA:BB:CC:DD:EE:FF
just static-ip-remove --assign 192.168.1.100
just static-ip-list
just static-ip-import --file hosts.csv
```

### DNS

Configura los servidores DNS upstream que usa dnsmasq para resolver nombres.

| Recipe | Descripción |
|--------|-------------|
| `just dns-set` | Configura DNS (default: 1.1.1.1 Cloudflare + 8.8.8.8 Google) |
| `just dns-show` | Muestra la configuración DNS actual |
| `just dns-reset` | Restaura DNS por defecto (1.1.1.1 + 8.8.8.8) |

Ejemplos:
```bash
just dns-set                                              # Cloudflare + Google
just dns-set --primary 9.9.9.9                           # Quad9 + Google
just dns-set --primary 9.9.9.9 --secondary 149.112.112.112  # Quad9 solo
just dns-set --primary 208.67.222.222 --secondary 208.67.220.220  # OpenDNS
just dns-show
just dns-reset
```

### Transparent .onion proxy (Tor via Raspi3b)

Configura OpenWRT para enrutar dominios `.onion` a través de Tor en la Raspi3b de forma transparente. Los clientes WiFi/LAN acceden a `.onion` sin configurar ningún proxy.

| Recipe | Descripción |
|--------|-------------|
| `just onion-enable` | Activa el transparent proxy: dnsmasq `.onion` + nftables DNAT + MASQUERADE |
| `just onion-disable` | Desactiva el DNAT (conserva la entrada dnsmasq `.onion`) |
| `just onion-uninstall` | Limpieza total: elimina DNAT + entrada dnsmasq |
| `just onion-status` | Muestra estado del include UCI, archivo nftables y prueba DNS en vivo |
| `just onion-doctor` | Diagnóstico capa por capa: DHCP → dnsmasq → nftables → puertos Tor en la Raspi |

Ejemplos:
```bash
just onion-enable                                 # Auto-detecta IP raspi-tor desde DHCP
just onion-enable --raspi-ip 192.168.1.100        # IP explícita (puertos default: 5300 + 9040)
just onion-disable                                # Solo quita DNAT, conserva DNS
just onion-uninstall                              # Limpieza total
just onion-status                                 # Ver estado y prueba DNS en vivo
just onion-doctor                                 # Diagnostica todo el stack, sale con código 1 si hay errores
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
| `just socks-enable` | Activa el forwarding: pide IP de la Raspi, fija IP estática en DHCP y crea la regla DNAT |
| `just socks-disable` | Elimina la regla DNAT del firewall |
| `just socks-uninstall` | Elimina la regla DNAT **y** la IP estática de la Raspi en DHCP |
| `just socks-status` | Muestra el estado de la regla y la IP estática de la Raspi |

Diferencia entre `disable` y `uninstall`:
- `disable` — solo elimina la regla de port forwarding. La IP estática de la Raspi queda en DHCP.
- `uninstall` — limpieza completa: elimina la regla DNAT y la entrada DHCP `raspi-tor`. Deja el router como si nunca se hubiera configurado.

Ejemplos:
```bash
just socks-enable                                 # Interactivo: pide IP de la Raspi
just socks-enable --raspi-ip 192.168.1.100        # Con IP predefinida (puerto default 9050)
just socks-enable --raspi-ip 192.168.1.100 --port 9050
just socks-disable                                # Quita el forwarding, conserva IP estática
just socks-uninstall                              # Limpieza total
just socks-status
```

Flujo de `socks-enable`:
1. Pide la IP actual de la Raspi3b (si no se pasa con `--raspi-ip`)
2. Detecta la MAC de la Raspi en la tabla ARP del router
3. Llama a `setup-static-ip.sh add` para fijar la IP en DHCP como `raspi-tor`
4. Crea la regla DNAT `wan:<port> → raspi:<port>` en el firewall UCI
5. Muestra el comando `curl --socks5` para verificar desde el Mac

### Clientes DHCP

Lista los dispositivos conectados al router: leases DHCP activos y tabla ARP.

| Recipe | Descripción |
|--------|-------------|
| `just clients` | Lista dispositivos conectados (leases DHCP + tabla ARP) |

Ejemplos:
```bash
just clients                        # Red por defecto (prod)
just clients --env dev              # Entorno dev
just clients --ip 192.168.0.1      # IP del router explícita
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
just setup-auth                 # Clave SSH + contraseña root
just setup-extroot              # USB como extroot (si hay USB conectado)
just setup-logs                 # Logs persistentes (tras reinicio con extroot)
```

### Configurar WiFi

```bash
just wifi-status                                         # Ver estado actual

just wifi-ap                                             # AP interactivo (detecta radios libres)
just wifi-ap --ssid MiRed --radio 5g                    # Pre-selecciona radio

just wifi-client                                         # Interactivo: banda → escanea → SSID
just wifi-client --radio 2.4ghz                         # Fuerza 2.4 GHz, resto interactivo

just wifi-scan                                           # Escanea 2.4 GHz y 5 GHz
just wifi-scan --radio 5g                               # Solo 5 GHz

just dns-set                                             # DNS Cloudflare + Google
just dns-set --primary 9.9.9.9                          # Cambiar DNS primario
```

### Instalar portal cautivo

```bash
just post-install group=captive_portal  # Instala uhttpd en el router
just setup-captive                      # Instala el portal (30 min por defecto)
just captive-status                     # Verificar que funciona
just captive-allow client=192.168.1.50  # Autorizar dispositivo manualmente
```

### Gestionar routing

```bash
# Router con WAN físico + cliente WiFi (wifi-client):
just routing-status                                               # Ver configuración actual
just routing-priority wifi                                        # Preferir WiFi como salida
just routing-pin --from 192.168.1.100 --via wan                  # NAS siempre por WAN
just routing-pin --from 192.168.1.50  --via wifi                 # Laptop siempre por WiFi
just routing-unpin --from 192.168.1.50
just routing-reset
```

### Asignar IPs fijas

```bash
just static-ip-add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.10 --name nas
just static-ip-add --mac BB:CC:DD:EE:FF:00 --assign 192.168.1.11 --name impresora
just static-ip-list
just static-ip-remove --mac AA:BB:CC:DD:EE:FF
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
