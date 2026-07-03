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
├── install/                    # Preparación del entorno local
│   ├── setup-env.sh            # Descarga y extrae el Image Builder
│   ├── validate-tools.sh       # Valida herramientas requeridas con versiones
│   ├── ensure-secrets.sh       # Verifica/desencripta secrets para el build
│   └── generate-password-hash.sh # Genera hash SHA-512 e inyecta en secrets
├── build/                      # Compilación local del firmware (no conectan al router)
│   ├── openwrt.sh              # Orquestador principal de compilación
│   ├── compile.sh              # Lógica de `make image`
│   ├── verify.sh               # Validación de imagen compilada
│   ├── convert-toml-packages.sh # Conversor TOML → TXT (standalone)
│   └── show-packages.sh        # Muestra paquetes configurados agrupados
├── router/                     # Administración del router via SSH
│   ├── update.sh               # Actualiza firmware via sysupgrade
│   ├── post-install.sh         # Instala paquetes adicionales via apk/opkg
│   ├── setup-auth.sh           # Copia clave SSH pública + contraseña root
│   ├── setup-extroot.sh        # Configura USB como extroot (/overlay)
│   ├── setup-logs-ram.sh       # Buffer de logs en RAM (64 KB, sin USB)
│   ├── setup-logs-file.sh      # Logs persistentes en archivo (USB/extroot)
│   ├── setup-captive.sh        # Portal cautivo nftables + uhttpd
│   ├── setup-wifi.sh           # Gestión WiFi (AP interactivo, cliente, scan, disconnect)
│   ├── setup-routing.sh        # Prioridad de rutas y source-based routing
│   ├── setup-static-ip.sh      # IPs estáticas por MAC address (DHCP leases)
│   ├── setup-dns.sh            # Servidores DNS upstream de dnsmasq
│   ├── show-clients.sh         # Lista dispositivos conectados (leases DHCP + ARP)
│   ├── setup-socks-forward.sh  # Port forwarding del proxy SOCKS de Raspi3b/Tor
│   ├── setup-tor-onion.sh      # Transparent proxy para dominios .onion
│   ├── backup.sh               # Backup y restauración de /etc/config (sysupgrade -b)
│   ├── reboot.sh               # Reinicio remoto con espera opcional de reconexión
│   ├── status.sh               # Vista general: sistema, red, WiFi, DHCP, servicios
│   ├── setup-wireguard.sh      # Gestión del túnel WireGuard (wg0) via UCI
│   └── setup-port-forward.sh   # Port forwarding DNAT desde WAN via UCI firewall
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

### router/update.sh

Actualiza el firmware del router via SSH y `sysupgrade`:

```bash
scripts/router/update.sh --env prod          # Mantiene configuración
scripts/router/update.sh --ip 192.168.0.1   # IP distinta
scripts/router/update.sh --force             # Borra configuración
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

### router/post-install.sh

Instala paquetes adicionales en el router post-flash. En OpenWRT 25.12+ usa `apk`; si el router expone `opkg`, cae a `opkg` para compatibilidad. Lee `config/openwrt-post-install-packages.toml`, que agrupa los paquetes por funcionalidad.

```bash
scripts/router/post-install.sh                          # Instala todos los grupos
scripts/router/post-install.sh --group captive_portal   # Solo un grupo
scripts/router/post-install.sh --list                   # Lista grupos sin instalar
```

Opciones: `--group <nombre>`, `--ip <IP>`, `--env <env>`, `--list`.

---

## Scripts de administración del router (router/)

Todos estos scripts se conectan al router via SSH. Leen `ROUTER_IP` y `SSH_PORT` de `environments/<env>/.env.public`.

### router/setup-extroot.sh

Configura un USB como extroot — monta `/dev/sda1` como `/overlay` para ampliar el espacio de almacenamiento del router. Copia el overlay actual, configura UCI fstab y reinicia.

```bash
scripts/router/setup-extroot.sh --env prod
scripts/router/setup-extroot.sh --ip 192.168.1.1 --device /dev/sdb1
```

Prerrequisito: formatear el USB como ext4 antes de conectarlo al router.

### router/setup-logs-ram.sh

Buffer circular de 64 KB en RAM. No requiere USB ni extroot. Los logs **no persisten** entre reinicios. Si existía una configuración previa con `log_file` (USB), la elimina limpiamente.

```bash
scripts/router/setup-logs-ram.sh --env prod
scripts/router/setup-logs-ram.sh --ip 192.168.1.1
```

Aplica `uci set system.@system[0].log_size='64'`, reinicia el servicio y muestra `logread | tail -10`.

```bash
ssh root@<router-ip> 'logread'       # ver buffer completo
ssh root@<router-ip> 'logread -f'    # seguir en tiempo real
```

### router/setup-logs-file.sh

Logs persistentes en archivo (`/overlay/log/messages`). Requiere extroot activo (USB montado como `/overlay`). Los logs sobreviven a reinicios mientras el USB esté conectado.

```bash
scripts/router/setup-logs-file.sh --env prod
scripts/router/setup-logs-file.sh --ip 192.168.1.1
```

Prerrequisito: `just router-setup-extroot` ejecutado y router reiniciado con el USB activo. El script verifica que `/overlay` esté montado desde un dispositivo externo antes de continuar.

Aplica `log_file=/overlay/log/messages` y `log_size=128`, reinicia el servicio y verifica la creación del archivo.

```bash
ssh root@<router-ip> 'tail -f /overlay/log/messages'   # seguir en tiempo real
ssh root@<router-ip> 'logread'                          # buffer RAM (funciona en ambos modos)
```

### router/setup-auth.sh

Copia la clave SSH pública al router (`/etc/dropbear/authorized_keys`) y establece la contraseña de root de forma interactiva.

```bash
scripts/router/setup-auth.sh --env prod
scripts/router/setup-auth.sh --key ~/.ssh/id_ed25519.pub  # Clave explícita
```

Auto-detecta la clave pública local en orden: `id_ed25519.pub` > `id_ecdsa.pub` > `id_rsa.pub`. Previene duplicados con `grep -qF`.

### router/setup-captive.sh

Instala y gestiona un portal cautivo usando únicamente **nftables + uhttpd** (sin OpenNDS). Redirige peticiones HTTP de clientes no autorizados al portal, que presenta una página con botón de aceptar. Al aceptar, añade la IP del cliente al set `allowed_clients` de nftables con timeout configurable.

```bash
scripts/router/setup-captive.sh install                      # Instala el portal
scripts/router/setup-captive.sh install --portal-url <URL>   # Modo portal externo
scripts/router/setup-captive.sh uninstall                    # Desinstala
scripts/router/setup-captive.sh allow 192.168.1.50           # Autoriza IP manualmente
scripts/router/setup-captive.sh allow 192.168.1.50 --timeout 0    # Permanente
scripts/router/setup-captive.sh allow 192.168.1.50 --timeout 120  # 2 horas
scripts/router/setup-captive.sh block 192.168.1.50           # Revoca acceso
scripts/router/setup-captive.sh flush                        # Limpia todos los clientes
scripts/router/setup-captive.sh list                         # Lista clientes autorizados
scripts/router/setup-captive.sh status                       # Diagnóstico del portal
```

Características:
- 21 dominios de detección de portal (Android, iOS, Windows, Huawei, Samsung, Xiaomi, Firefox, Gnome)
- `filter_aaaa=1` en dnsmasq para bloquear bypass IPv6
- DHCP option 252 (RFC 8910) para notificación directa de URL del portal
- Modo portal externo: redirige al portal con `?return=<callback>`, el portal autentica y devuelve al router
- El CGI usa `REMOTE_ADDR` (IP TCP real), no parámetros URL

Prerrequisito: `just router-post-install group=captive_portal` (instala `uhttpd`).

### router/setup-wifi.sh

Gestión completa de la configuración WiFi del router via UCI.

```bash
# Access Point — completamente interactivo
scripts/router/setup-wifi.sh ap                           # detecta radios libres → SSID → pass → canal
scripts/router/setup-wifi.sh ap --ssid MiRed --radio 5g  # pre-selecciona radio y SSID
scripts/router/setup-wifi.sh ap --ssid Libre --open       # sin contraseña

# Cliente WiFi — interactivo o con flags
scripts/router/setup-wifi.sh client                        # elige banda → escanea → SSID → pass
scripts/router/setup-wifi.sh client --radio 2.4ghz         # fuerza 2.4 GHz, luego interactivo
scripts/router/setup-wifi.sh client --ssid RedExterna      # SSID fijo, pide contraseña

# Desconectar cliente
scripts/router/setup-wifi.sh disconnect                    # elimina todas las interfaces STA
scripts/router/setup-wifi.sh disconnect --radio radio0     # solo esa radio

# Escanear redes
scripts/router/setup-wifi.sh scan                          # ambos radios (2.4 GHz + 5 GHz)
scripts/router/setup-wifi.sh scan --radio 5g               # solo 5 GHz

# Estado y listado
scripts/router/setup-wifi.sh status
scripts/router/setup-wifi.sh list

# Habilitar / deshabilitar radio
scripts/router/setup-wifi.sh enable  --radio radio0
scripts/router/setup-wifi.sh disable --radio radio1
```

Subcomandos: `ap`, `client`, `disconnect`, `scan`, `status`, `list`, `enable`, `disable`.

Alias de radio: `radio0`, `radio1`, `2g`, `5g`, `2.4ghz`, `5ghz`.

**Comportamiento interactivo:**
- `ap` sin `--ssid`: detecta qué radios están libres (no en uso como cliente STA) y muestra menú; si solo hay uno libre lo elige automáticamente.
- `client` sin `--radio`: pregunta banda (2.4 GHz / 5 GHz), escanea esa radio y muestra tabla de redes.
- Contraseña siempre se pide con `read -s` (nunca visible en terminal).
- BSSID: pregunta `¿Especificar BSSID? (s/N)` — solo pide el valor si responde `s`.

Modo cliente crea la interfaz `wwan` (protocolo DHCP), la añade a la zona WAN del firewall y acepta DNS del upstream (`peerdns=1`).

### router/setup-dns.sh

Configura los servidores DNS upstream que usa dnsmasq para resolver nombres externos. Por defecto usa Cloudflare (1.1.1.1) y Google (8.8.8.8).

```bash
# Configurar DNS
scripts/router/setup-dns.sh set                                         # 1.1.1.1 + 8.8.8.8
scripts/router/setup-dns.sh set --primary 9.9.9.9                       # Quad9 + Google
scripts/router/setup-dns.sh set --primary 9.9.9.9 --secondary 149.112.112.112
scripts/router/setup-dns.sh set --primary 208.67.222.222 --secondary 208.67.220.220  # OpenDNS

# Ver configuración actual
scripts/router/setup-dns.sh show

# Restaurar valores por defecto
scripts/router/setup-dns.sh reset
```

Subcomandos: `set`, `show`, `reset`. El `show` verifica también la resolución con `nslookup`.

### router/setup-routing.sh

Gestiona la prioridad de salida a internet (WAN físico vs cliente WiFi `wwan`) y permite fijar IPs LAN a interfaces concretas mediante source-based routing (`ip rule` + tablas de routing dedicadas).

```bash
# Ver estado actual
scripts/router/setup-routing.sh status

# Definir interfaz preferida
scripts/router/setup-routing.sh priority wan    # WAN físico preferido (default)
scripts/router/setup-routing.sh priority wifi   # Cliente WiFi preferido
scripts/router/setup-routing.sh priority equal  # Misma métrica, kernel decide

# Fijar IP LAN a una interfaz (persiste entre reinicios)
scripts/router/setup-routing.sh pin --from 192.168.1.50 --via wifi
scripts/router/setup-routing.sh pin --from 192.168.1.51 --via wan

# Gestionar pins
scripts/router/setup-routing.sh unpin --from 192.168.1.50
scripts/router/setup-routing.sh pins
scripts/router/setup-routing.sh reset
```

Los pins se almacenan en `/etc/routing-pins.conf` y se restauran en cada boot mediante un hotplug script en `/etc/hotplug.d/iface/50-routing-pins`. Las tablas de routing usadas son `100` (wan) y `200` (wifi/wwan).

### router/setup-static-ip.sh

Gestiona DHCP static leases: asigna IPs fijas a dispositivos por su MAC address usando entradas UCI `dhcp host`. dnsmasq sirve siempre la misma IP al mismo dispositivo.

```bash
# Asignar IP estática
scripts/router/setup-static-ip.sh add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100 --name servidor
scripts/router/setup-static-ip.sh add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.100

# Eliminar asignación
scripts/router/setup-static-ip.sh remove --mac AA:BB:CC:DD:EE:FF
scripts/router/setup-static-ip.sh remove --assign 192.168.1.100

# Listar, limpiar
scripts/router/setup-static-ip.sh list
scripts/router/setup-static-ip.sh clear

# Importar desde CSV local
scripts/router/setup-static-ip.sh import --file hosts.csv
```

Formato CSV para import:
```csv
MAC,IP,nombre
AA:BB:CC:DD:EE:FF,192.168.1.100,servidor
BB:CC:DD:EE:FF:00,192.168.1.101,laptop
```

### router/setup-socks-forward.sh

Activa o desactiva el reenvío de puertos del proxy SOCKS de la Raspberry Pi 3b al exterior del router. Al activar, detecta automáticamente la MAC de la Raspi en el ARP, llama a `setup-static-ip.sh` para fijar la IP, y crea la regla DNAT en el firewall UCI.

```bash
# Activar (interactivo: pide IP de la Raspi si no se indica)
scripts/router/setup-socks-forward.sh enable
scripts/router/setup-socks-forward.sh enable --raspi-ip 192.168.1.100 --port 9050

# Desactivar (elimina solo la regla DNAT; la IP estática en DHCP se conserva)
scripts/router/setup-socks-forward.sh disable

# Desinstalar completamente (regla DNAT + IP estática raspi-tor)
scripts/router/setup-socks-forward.sh uninstall

# Estado
scripts/router/setup-socks-forward.sh status
```

La regla UCI se llama `tor_socks_fwd` (nombre fijo), lo que permite encontrarla y eliminarla con precisión sin afectar otras reglas. La IP estática en DHCP se guarda con el nombre `raspi-tor`.

`uninstall` elimina ambas cosas y recarga firewall + dnsmasq. Deja el router en el estado previo a `enable`.

### router/setup-tor-onion.sh

Configura OpenWRT para que los clientes LAN/WiFi accedan a dominios `.onion` sin configurar ningún proxy en sus dispositivos (transparent proxy).

Prerrequisito: la Raspi3b debe tener Tor configurado con `TransPort 0.0.0.0:9040`, `DNSPort 0.0.0.0:5300` (evitar conflicto con mDNS en 5353), `VirtualAddrNetworkIPv4 10.192.0.0/10` y `AutomapHostsOnResolve 1`.

Lo que configura en OpenWRT:
1. **dnsmasq**: reenvía consultas `.onion` al puerto DNS de Tor en la Raspi → Tor devuelve una IP virtual del rango `10.192.0.0/10`
2. **nftables DNAT**: redirige TCP al rango `10.192.0.0/10` → `raspi:9040` (TransPort)
3. **nftables MASQUERADE**: el router actúa de intermediario para que el tráfico de retorno fluya correctamente via conntrack

```bash
# Activar (auto-detecta IP de raspi-tor desde DHCP)
scripts/router/setup-tor-onion.sh enable
scripts/router/setup-tor-onion.sh enable --raspi-ip 192.168.1.100
scripts/router/setup-tor-onion.sh enable --raspi-ip 192.168.1.100 --dns-port 5300 --trans-port 9040

# Desactivar (solo quita el DNAT; la entrada dnsmasq se conserva)
scripts/router/setup-tor-onion.sh disable

# Desinstalar (DNAT + entrada dnsmasq)
scripts/router/setup-tor-onion.sh uninstall

# Estado
scripts/router/setup-tor-onion.sh status

# Diagnóstico capa por capa
scripts/router/setup-tor-onion.sh doctor
```

El include UCI se registra con el nombre fijo `tor_onion_nft` y el archivo nftables en `/etc/nftables.d/tor-onion.nft`.

Diferencia `disable` vs `uninstall`:
- `disable`: elimina el DNAT (las IPs virtuales dejan de redirigirse), pero `.onion` sigue resolviéndose via dnsmasq
- `uninstall`: limpieza total — elimina el DNAT y la entrada dnsmasq

El subcomando `doctor` verifica el stack completo en 4 capas y muestra ✅/❌/⚠️ por check:
1. **DHCP**: entrada `raspi-tor` y alcanzabilidad de la Raspi
2. **dnsmasq**: server `/onion/`, proceso corriendo, rebind_domain `/onion/` exento y resolución DNS real
3. **nftables**: include UCI, archivo `.nft` y cadenas `tor_onion_dnat`/`tor_onion_snat` cargadas en el kernel
4. **Puertos Tor**: TransPort verificado vía regla DNAT en nftables; DNSPort reportado como ⚠️ (UDP — no testable con TCP desde OpenWRT; si la Capa 2 pasa, el puerto está OK)

Sale con código de salida 1 si algún check falla, útil para scripts.

**Requisito de red en los clientes**: el proxy transparente solo funciona si el dispositivo cliente usa el router OpenWRT como resolver DNS. Si el equipo tiene varias interfaces de red activas (p.ej. WiFi a otra red + ethernet al OpenWRT), las consultas `.onion` pueden salir por la interfaz incorrecta y no pasar por dnsmasq.

En equipos Linux con `systemd-resolved` conectados a múltiples redes: verificar con `resolvectl status` que la interfaz ethernet al OpenWRT tiene prioridad para `.onion`.

**Alternativa SOCKS5** (funciona independientemente de la interfaz de red):
```bash
# Acceso puntual
curl --socks5-hostname 192.168.1.136:9050 http://dominio.onion

# Variables de entorno (sesión completa)
export http_proxy=socks5h://192.168.1.136:9050
export https_proxy=socks5h://192.168.1.136:9050
curl http://dominio.onion
```

---

### router/show-clients.sh

Lista todos los dispositivos conectados al router. Lee `/tmp/dhcp.leases` para los leases DHCP activos y `/proc/net/arp` para la tabla ARP. Muestra el tiempo restante de cada lease y si el dispositivo responde en la red.

```bash
scripts/router/show-clients.sh                  # Usa entorno prod
scripts/router/show-clients.sh --env dev        # Otro entorno
scripts/router/show-clients.sh --ip 192.168.0.1  # IP del router explícita
```

Salida:
- **LEASES DHCP**: IP, MAC, hostname, tiempo restante (`23h 45m`, `permanente`, `expirado`) y si aparece en ARP (`[en red]` / `[sin ARP]`).
- **TABLA ARP**: todos los dispositivos con tráfico reciente, incluyendo los que tienen IP estática (no gestionada por DHCP).

### router/backup.sh

Backup y restauración de la configuración del router (`/etc/config`) usando `sysupgrade -b`. Los backups se descargan a `./backups/` con nombre `router-<IP>-<timestamp>.tar.gz`.

```bash
# Descargar backup de configuración
scripts/router/backup.sh backup
scripts/router/backup.sh backup --dir /tmp/router-backups   # directorio alternativo

# Restaurar desde backup (confirmación interactiva, reinicia el router)
scripts/router/backup.sh restore --file backups/router-192.168.1.1-20260518-142300.tar.gz

# Listar backups locales disponibles
scripts/router/backup.sh list
```

Subcomandos: `backup`, `restore`, `list`. Opciones: `--ip`, `--env`, `--dir` (backup/list), `--file` (restore).

Flujo de `backup`: genera `/tmp/router-backup-<ts>.tar.gz` en el router via `sysupgrade -b`, lo descarga con SCP y lo elimina del `/tmp` del router.

Flujo de `restore`: sube el archivo al router (`/tmp/router-restore.tar.gz`), aplica `tar xzf -C /` y ejecuta `reboot`. Pide confirmación antes de proceder.

---

### router/reboot.sh

Reinicia el router via SSH. Sin `--wait` envía el comando y retorna inmediatamente (útil en shell interactivo). Con `--wait` bloquea hasta que el router vuelve a estar disponible.

```bash
# Reboot inmediato (no espera)
scripts/router/reboot.sh
scripts/router/reboot.sh --ip 192.168.1.1

# Reboot + esperar reconexión (~60s)
scripts/router/reboot.sh --wait
scripts/router/reboot.sh --ip 192.168.1.1 --env prod --wait
```

Con `--wait`: espera 20 segundos iniciales (tiempo de apagado), luego sondea SSH cada 3 segundos hasta un máximo de 90 segundos, imprimiendo `.` en cada intento. Si el router no responde en 90s, imprime un aviso pero no sale con error.

---

### router/status.sh

Vista general del router en una sola llamada SSH. Muestra todo el estado sin modificar ninguna configuración.

```bash
scripts/router/status.sh
scripts/router/status.sh --ip 192.168.0.1
scripts/router/status.sh --env dev
```

Secciones mostradas:

| Sección | Contenido |
|---------|-----------|
| **Sistema** | Hostname, versión firmware (OpenWRT), uptime, carga (1m 5m 15m) |
| **Memoria** | MB usados / total / porcentaje de uso |
| **Almacenamiento** | `/`, `/overlay`, `/tmp` — uso y espacio disponible |
| **Red** | IP WAN, LAN (br-lan), WiFi cliente (wwan), WireGuard (wg0) si existen |
| **WiFi** | Radios con banda, canal y estado (activo/deshabilitado) |
| **Clientes DHCP** | IP, MAC y hostname de cada dispositivo conectado |
| **Servicios** | dnsmasq, nftables, dropbear, tor, wireguard — ✅ activo / ❌ inactivo |

Implementado como un único heredoc `<< 'REMOTE'` para minimizar el número de conexiones SSH.

---

### router/setup-wireguard.sh

Gestiona el túnel WireGuard (`wg0`) en OpenWRT via UCI. Asume que WireGuard está incluido en la imagen compilada (`kmod-wireguard`, `wireguard-tools`).

```bash
# Estado del túnel y peers activos
scripts/router/setup-wireguard.sh status

# Activar / desactivar la interfaz
scripts/router/setup-wireguard.sh enable
scripts/router/setup-wireguard.sh disable

# Listar peers configurados en UCI
scripts/router/setup-wireguard.sh peer-list

# Añadir peer
scripts/router/setup-wireguard.sh peer-add \
    --pubkey "abc123...==" \
    --endpoint "1.2.3.4:51820" \
    --allowed-ips "10.0.0.2/32" \
    --name "laptop"

# Peer solo receptor (sin endpoint, sin keepalive de salida)
scripts/router/setup-wireguard.sh peer-add \
    --pubkey "xyz789...==" \
    --allowed-ips "10.0.0.3/32"

# Eliminar peer por clave pública
scripts/router/setup-wireguard.sh peer-remove --pubkey "abc123...=="
```

Subcomandos: `status`, `enable`, `disable`, `peer-list`, `peer-add`, `peer-remove`.

`peer-add` crea entradas UCI `network.@wireguard_wg0[-1]` con `persistent_keepalive=25` y `route_allowed_ips=1`. `--endpoint` acepta formato `IP:puerto`. `--name` se almacena como `description` (opcional).

`peer-remove` itera en orden inverso por índice (`tac`) para no romper los índices UCI al eliminar.

`status` muestra el estado de la interfaz `wg0` (UP/DOWN, IP asignada), la salida de `wg show wg0` con estadísticas de peers activos y la configuración UCI completa.

---

### router/setup-port-forward.sh

Gestiona reglas de port forwarding DNAT desde la WAN hacia hosts de la LAN. Usa UCI `firewall redirect` con `target=DNAT` y `src=wan`.

```bash
# Listar reglas activas
scripts/router/setup-port-forward.sh list

# Añadir regla TCP simple (puerto externo = puerto interno)
scripts/router/setup-port-forward.sh add \
    --name "web" --port 8080 --dest-ip 192.168.1.50

# Puerto externo distinto del interno
scripts/router/setup-port-forward.sh add \
    --name "ssh-raspi" --port 2222 --dest-ip 192.168.1.136 --dest-port 22

# Protocolo both: crea nombre-tcp y nombre-udp
scripts/router/setup-port-forward.sh add \
    --name "nas-smb" --port 445 --dest-ip 192.168.1.30 --proto both

# Eliminar regla (o par tcp/udp) por nombre
scripts/router/setup-port-forward.sh remove --name "web"
scripts/router/setup-port-forward.sh remove --name "nas-smb"   # elimina nas-smb-tcp y nas-smb-udp

# Estado en vivo con contadores nftables
scripts/router/setup-port-forward.sh status
```

Subcomandos: `list`, `add`, `remove`, `status`.

Opciones de `add`:
- `--name <nombre>` — nombre de la regla UCI (requerido)
- `--port <puerto>` — puerto externo WAN (requerido)
- `--dest-ip <IP>` — IP destino en la LAN (requerido)
- `--dest-port <p>` — puerto interno si difiere del externo (default: igual a `--port`)
- `--proto tcp|udp|both` — protocolo (default: `tcp`); `both` crea dos reglas

`remove` busca por nombre exacto y también por `nombre-tcp` / `nombre-udp`, por lo que funciona tanto para reglas simples como para las creadas con `--proto both`. Itera en orden inverso para no romper los índices UCI.

`status` muestra los contadores de paquetes/bytes desde `nft list table inet fw4` y la configuración UCI completa (redirects).

Tras cada `add` o `remove` se ejecuta `uci commit firewall` y `/etc/init.d/firewall reload`.

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
