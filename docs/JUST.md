# Uso de Just

`justfile` es el único punto de entrada operativo del proyecto. Orquesta setup, secrets, build, validación, actualización del router y configuración post-flash.

Antes de compilar con `just build-prod`, revisa [Configuración de Build](CONFIGURACION_BUILD.md) para saber qué archivos controlan versión, modelo, paquetes, secrets y overlay.

```bash
just --list
just <recipe>
```

## Convenciones

Hay dos estilos de argumentos en este `justfile`:

- Recipes con `*args`: aceptan flags como el script interno. Ejemplo: `just router-status --ip 192.168.1.1 --env prod`.
- Recipes con parámetros declarados en la firma, como `ip="" env="prod"`: pasan valores por posición. Ejemplo: `just router-wifi-status 192.168.1.1 prod`.

No uses `ip=192.168.1.1` después del nombre de la recipe en recetas posicionales; `just` lo pasa como texto literal. Si una recipe dice `router-wifi-status ip="" env="prod"`, el primer argumento es la IP y el segundo es el entorno.

Si dudas, corre:

```bash
just --list
```

La mayoría de comandos del router leen `ROUTER_IP` y `SSH_PORT` desde `environments/<env>/.env.public`. El entorno por defecto es `prod`.

## Setup

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `default` | `just` | Muestra `just --list --unsorted`. |
| `setup` | `just setup [true]` | Ejecuta setup inicial: instala herramientas, genera clave age, crea environments y hooks. `true` fuerza reinstalación de herramientas. |
| `install-tools` | `just install-tools [true]` | Instala/verifica `just`, `make`, `gawk`, `sops`, `age`, `yq`. `true` fuerza reinstalación. |
| `validate-tools` | `just validate-tools` | Valida herramientas requeridas y versiones. |
| `generate-age-key` | `just generate-age-key` | Crea `~/.age/poc-openwrt-privkey.txt` y actualiza `.age-pubkey.txt`. |
| `create-environments` | `just create-environments` | Crea `environments/{dev,prod}` con `.env.public` y `secrets.enc.yaml`. |
| `setup-hooks` | `just setup-hooks` | Configura `.githooks/` como hooks de git. |

Ejemplos:

```bash
just setup
just install-tools true
just validate-tools
```

## Secrets

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `reinit-secrets` | `just reinit-secrets prod` | Re-crea secrets vacíos encriptados con la clave age local. Útil al clonar en otra máquina. |
| `decrypt-secrets` | `just decrypt-secrets prod` | Desencripta a `/tmp/secrets-prod.yaml`. |
| `edit-secrets` | `just edit-secrets prod` | Abre `secrets.enc.yaml` con `sops`; en SSH usa editor de terminal si detecta editor gráfico. |
| `create-password` | `just create-password prod` | Pide contraseña root, genera hash SHA-512 y lo guarda en `ROOT_PASSWORD_HASH`. |

Campos esperados en `secrets.enc.yaml`:

```yaml
WIFI_KEY_24: ""
WIFI_KEY_5: ""
WIREGUARD_PRIVATE_KEY: ""
DROPBEAR_RSA_HOST_KEY: ""
ROOT_PASSWORD_HASH: ""
```

Para contraseña root, no escribas el hash a mano:

```bash
just create-password prod
just edit-secrets prod
```

## Build y Paquetes

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `setup-env` | `just setup-env [prod]` | Descarga y extrae el OpenWrt Image Builder definido en `.env.public`. |
| `packages` | `just packages` | Muestra la configuración de paquetes desde `config/openwrt-packages.toml`. |
| `refresh-packages` | `just refresh-packages` | Regenera `config/openwrt-packages.txt` desde el TOML. |
| `generate-config` | `just generate-config prod` | Genera `config/overlay/<env>/` desde templates y secrets. |
| `build` | `just build` | Compila sin secrets usando valores por defecto. |
| `build-dev` | `just build-dev` | Verifica secrets dev, genera overlay dev y compila. |
| `build-prod` | `just build-prod` | Verifica secrets prod, genera overlay prod, compila y verifica imagen. |
| `validate` | `just validate` | Ejecuta `shellcheck` vía `make validate`. |
| `clean` | `just clean` | Limpia artefactos de compilación y `/tmp/secrets-*.yaml`. |
| `clean-all` | `just clean-all` | Limpia artefactos, overlay generado y `/tmp/secrets-*.yaml`. |

Flujo típico:

```bash
just setup-env prod
just refresh-packages
just build-prod
```

## Firmware / Sysupgrade

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-update` | `just router-update [--ip <IP>] [--env <env>]` | Ejecuta `sysupgrade` manteniendo configuración. |
| `router-update-force` | `just router-update-force [--ip <IP>] [--env <env>]` | Ejecuta `sysupgrade -n`; borra configuración del router. |

Ejemplos:

```bash
just router-update --ip 192.168.1.1
just router-update-force --ip 192.168.1.1
```

Usa `router-update-force` solo cuando quieras que la configuración incluida en la imagen reemplace lo persistido en `/overlay`, por ejemplo para forzar `/etc/shadow` nuevo.

## Setup Inicial del Router

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-copy-keys` | `just router-copy-keys [--ip <IP>] [--env <env>] [--key <path>]` | Copia clave SSH pública a Dropbear sin cambiar contraseña root. |
| `router-setup-auth` | `just router-setup-auth [IP] [env] [key]` | Copia clave SSH y configura contraseña root. |
| `router-setup-extroot` | `just router-setup-extroot [IP] [device] [env]` | Configura USB como extroot. Requiere USB ext4. |
| `router-setup-logs-ram` | `just router-setup-logs-ram [IP] [env]` | Configura buffer de logs en RAM; no persiste reinicios. |
| `router-setup-logs-file` | `just router-setup-logs-file [IP] [env]` | Configura logs persistentes en `/overlay/log/messages`; requiere extroot. |
| `router-post-install` | `just router-post-install [grupo] [IP] [env]` | Instala paquetes post-flash definidos en `config/openwrt-post-install-packages.toml`. |

Ejemplos:

```bash
just router-copy-keys --ip 192.168.1.1
just router-setup-auth 192.168.1.1
just router-setup-extroot 192.168.1.1 /dev/sda1
just router-post-install captive_portal
```

Nota: `router-post-install --list` no funciona como flag directo porque esta recipe usa parámetros `just`; para listar grupos usa el script:

```bash
scripts/router/post-install.sh --list
```

## Estado, Clientes, Backup y Reinicio

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-status` | `just router-status [--ip <IP>] [--env <env>]` | Diagnóstico general: sistema, firmware, memoria, almacenamiento, red, WiFi, dispositivos, portal cautivo, servicios y salud. |
| `router-clients` | `just router-clients [--ip <IP>] [--env <env>]` | Lista leases DHCP y tabla ARP. |
| `router-backup` | `just router-backup [--ip <IP>] [--env <env>] [--dir <dir>]` | Descarga backup de configuración a `./backups/`. |
| `router-restore` | `just router-restore --file <backup.tar.gz> [--ip <IP>] [--env <env>]` | Restaura backup y reinicia router. |
| `router-backup-list` | `just router-backup-list [--dir <dir>]` | Lista backups locales disponibles. |
| `router-reboot` | `just router-reboot [--ip <IP>] [--env <env>] [--wait]` | Reinicia router; con `--wait` espera reconexión. |

Ejemplos:

```bash
just router-status --ip 192.168.1.1
just router-clients --ip 192.168.1.1
just router-backup --ip 192.168.1.1
just router-backup-list
just router-restore --file backups/router-192.168.1.1-20260703.tar.gz
just router-reboot --ip 192.168.1.1 --wait
```

## WiFi

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-wifi-setup` | `just router-wifi-setup <subcmd> [IP] [env] [ssid] [password] [radio] [channel] [open]` | Wrapper parametrizado para `setup-wifi.sh`. |
| `router-wifi-ap` | `just router-wifi-ap [--radio <r>] [--ssid <s>] [--channel <c>] [--open] [--env <env>]` | Configura AP; sin flags guía interactivamente. |
| `router-wifi-client` | `just router-wifi-client [--radio <r>] [--ssid <s>] [--env <env>]` | Conecta el router como cliente WiFi; puede escanear y pedir password. |
| `router-wifi-disconnect` | `just router-wifi-disconnect [radio] [IP] [env]` | Elimina interfaz STA/wwan; sin radio desconecta todos los clientes STA. |
| `router-wifi-scan` | `just router-wifi-scan [--radio <r>] [--ip <IP>] [--env <env>]` | Escanea redes WiFi disponibles. |
| `router-wifi-status` | `just router-wifi-status [IP] [env]` | Muestra radios, interfaces, SSID y estado WiFi. |
| `router-wifi-enable` | `just router-wifi-enable <radio> [IP] [env]` | Habilita un radio WiFi. |
| `router-wifi-disable` | `just router-wifi-disable <radio> [IP] [env]` | Deshabilita un radio WiFi. |

Radios válidos: `radio0`, `radio1`, `2g`, `5g`, `2.4ghz`, `5ghz`.

Ejemplos:

```bash
just router-wifi-status
just router-wifi-status 192.168.1.1
just router-wifi-scan --radio 2g
just router-wifi-client --radio 2g --ssid netup
just router-wifi-ap --radio 5g --ssid OpenWrtLab --channel 36
just router-wifi-disable radio1
just router-wifi-enable radio0
```

### Activar AP en 5 GHz

Si el router ya usa `radio0`/2.4 GHz como cliente WiFi hacia una red externa, puedes levantar el AP en la otra banda usando `radio1`/5 GHz. Esto mantiene el cliente WiFi de 2.4 GHz y crea/activa una interfaz AP en `lan`.

1. Verifica el estado actual:

```bash
just router-wifi-status 192.168.1.1
```

Debes ver algo similar:

```text
radio0 ... mode=sta ssid=netup net=wwan activa
radio1 ... mode=ap  ...       net=lan  deshabilitada
```

2. Configura el AP en 5 GHz:

```bash
just router-wifi-ap --ip 192.168.1.1 --radio 5g --ssid OpenWrt-5G --channel 36
```

El comando pedirá la contraseña WPA2 si no pasas `--password`. La contraseña debe tener al menos 8 caracteres.

También puedes pasarla en el comando:

```bash
just router-wifi-ap --ip 192.168.1.1 --radio 5g --ssid OpenWrt-5G --password 'clave-segura-123' --channel 36
```

Para un AP abierto, sin contraseña:

```bash
just router-wifi-ap --ip 192.168.1.1 --radio 5g --ssid OpenWrt-5G --open --channel 36
```

3. Confirma con `s` cuando muestre el resumen:

```text
Radio:   radio1
SSID:    OpenWrt-5G
Cifrado: psk2
Canal:   36
```

4. Verifica que quedó activo:

```bash
just router-wifi-status 192.168.1.1
just router-status --ip 192.168.1.1
```

5 GHz usa `radio1`. Los canales comunes son `36`, `40`, `44` y `48`; `36` es una opción conservadora para evitar DFS.

## Portal Cautivo

Requiere instalar el grupo post-flash `captive_portal` para tener `uhttpd`:

```bash
just router-post-install captive_portal
```

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-captive-setup` | `just router-captive-setup [IP] [env] [timeout] [portal-url] [token]` | Instala portal cautivo local o externo con nftables + uhttpd. |
| `router-captive-remove` | `just router-captive-remove [IP] [env]` | Desinstala portal, reglas nftables, dnsmasq probes y archivos. |
| `router-captive-allow` | `just router-captive-allow <cliente-IP> [router-IP] [env] [timeout]` | Autoriza una IP; `timeout=0` es permanente. |
| `router-captive-block` | `just router-captive-block <cliente-IP> [router-IP] [env]` | Revoca autorización de una IP. |
| `router-captive-flush` | `just router-captive-flush [IP] [env]` | Vacía todos los clientes autorizados. |
| `router-captive-list` | `just router-captive-list [IP] [env]` | Lista tabla nftables, clientes autorizados, leases y conexiones HTTP. |
| `router-captive-status` | `just router-captive-status [IP] [env]` | Diagnóstico de portal, uhttpd, nftables y configuración. |

Ejemplos:

```bash
just router-captive-setup 192.168.1.1 prod 60
just router-captive-setup 192.168.1.1 prod 30 https://portal.example.com abc123
just router-captive-allow 192.168.1.50 192.168.1.1 prod 120
just router-captive-block 192.168.1.50
just router-captive-list
just router-captive-status
just router-captive-remove
```

## Routing

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-routing-status` | `just router-routing-status [IP] [env]` | Muestra rutas, gateways, métricas y pins. |
| `router-routing-priority` | `just router-routing-priority <wan|wifi|equal> [--ip <IP>] [--env <env>]` | Cambia prioridad de salida WAN/WiFi. |
| `router-routing-pin` | `just router-routing-pin --from <IP> --via <wan|wifi> [--ip <IP>] [--env <env>]` | Enruta una IP LAN por una salida específica. |
| `router-routing-unpin` | `just router-routing-unpin --from <IP> [--ip <IP>] [--env <env>]` | Elimina pin de una IP LAN. |
| `router-routing-pins` | `just router-routing-pins [--ip <IP>] [--env <env>]` | Lista pins activos. |
| `router-routing-reset` | `just router-routing-reset [--ip <IP>] [--env <env>]` | Elimina pins y restaura prioridad WAN. |

Ejemplos:

```bash
just router-routing-status
just router-routing-priority wifi
just router-routing-pin --from 192.168.1.50 --via wifi
just router-routing-unpin --from 192.168.1.50
just router-routing-reset
```

## IPs Estáticas DHCP

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-static-ip-add` | `just router-static-ip-add --mac <MAC> --assign <IP> [--name <nombre>]` | Crea o actualiza una reserva DHCP. |
| `router-static-ip-remove` | `just router-static-ip-remove --mac <MAC>` o `--assign <IP>` | Elimina reserva por MAC o IP. |
| `router-static-ip-list` | `just router-static-ip-list [--ip <IP>] [--env <env>]` | Lista reservas y leases activos. |
| `router-static-ip-clear` | `just router-static-ip-clear [--ip <IP>] [--env <env>]` | Elimina todas las reservas DHCP. |
| `router-static-ip-import` | `just router-static-ip-import --file hosts.csv [--ip <IP>] [--env <env>]` | Importa reservas desde CSV `MAC,IP,nombre`. |

Ejemplos:

```bash
just router-static-ip-add --mac AA:BB:CC:DD:EE:FF --assign 192.168.1.10 --name nas
just router-static-ip-remove --assign 192.168.1.10
just router-static-ip-list
just router-static-ip-import --file hosts.csv
```

## DNS

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-dns-set` | `just router-dns-set [--primary <IP>] [--secondary <IP>] [--ip <IP>] [--env <env>]` | Configura DNS upstream de dnsmasq. Defaults: Cloudflare + Google. |
| `router-dns-show` | `just router-dns-show [--ip <IP>] [--env <env>]` | Muestra DNS actual. |
| `router-dns-reset` | `just router-dns-reset [--ip <IP>] [--env <env>]` | Restaura `1.1.1.1` y `8.8.8.8`. |

Ejemplos:

```bash
just router-dns-set
just router-dns-set --primary 9.9.9.9 --secondary 149.112.112.112
just router-dns-show
just router-dns-reset
```

## SOCKS Forward

Expone el proxy SOCKS de una Raspi/Tor desde el router mediante port forwarding.

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-socks-enable` | `just router-socks-enable [--raspi-ip <IP>] [--port 9050] [--ip <IP>] [--env <env>]` | Crea DNAT hacia Raspi y puede fijar IP estática. |
| `router-socks-disable` | `just router-socks-disable [--ip <IP>] [--env <env>]` | Elimina DNAT; conserva reserva DHCP. |
| `router-socks-uninstall` | `just router-socks-uninstall [--ip <IP>] [--env <env>]` | Elimina DNAT y reserva DHCP `raspi-tor`. |
| `router-socks-status` | `just router-socks-status [--ip <IP>] [--env <env>]` | Muestra regla firewall y reserva DHCP. |

Ejemplos:

```bash
just router-socks-enable --raspi-ip 192.168.1.100 --port 9050
just router-socks-status
just router-socks-disable
just router-socks-uninstall
```

## Transparent .onion Proxy

Configura resolución `.onion` en dnsmasq y DNAT/SNAT nftables hacia Tor en una Raspi.

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-onion-enable` | `just router-onion-enable [--raspi-ip <IP>] [--dns-port 5300] [--trans-port 9040] [--ip <IP>] [--env <env>]` | Activa proxy transparente `.onion`. |
| `router-onion-disable` | `just router-onion-disable [--ip <IP>] [--env <env>]` | Desactiva DNAT, conserva entrada dnsmasq. |
| `router-onion-uninstall` | `just router-onion-uninstall [--ip <IP>] [--env <env>]` | Elimina DNAT y configuración dnsmasq `.onion`. |
| `router-onion-status` | `just router-onion-status [--ip <IP>] [--env <env>]` | Muestra estado de include UCI, nftables y prueba DNS. |
| `router-onion-doctor` | `just router-onion-doctor [--dns-port 5300] [--trans-port 9040] [--ip <IP>] [--env <env>]` | Diagnóstico capa por capa. |

Ejemplos:

```bash
just router-onion-enable --raspi-ip 192.168.1.100
just router-onion-status
just router-onion-doctor
just router-onion-disable
just router-onion-uninstall
```

## WireGuard

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-wireguard-status` | `just router-wireguard-status [--ip <IP>] [--env <env>]` | Estado de `wg0` y `wg show`. |
| `router-wireguard-enable` | `just router-wireguard-enable [--ip <IP>] [--env <env>]` | Activa `wg0`. |
| `router-wireguard-disable` | `just router-wireguard-disable [--ip <IP>] [--env <env>]` | Desactiva `wg0`. |
| `router-wireguard-peer-list` | `just router-wireguard-peer-list [--ip <IP>] [--env <env>]` | Lista peers UCI. |
| `router-wireguard-peer-add` | `just router-wireguard-peer-add --pubkey <key> --endpoint <IP:port> --allowed-ips <CIDR> [--name <n>]` | Añade peer. |
| `router-wireguard-peer-remove` | `just router-wireguard-peer-remove --pubkey <key> [--ip <IP>] [--env <env>]` | Elimina peer por clave pública. |

Ejemplo:

```bash
just router-wireguard-peer-add \
  --pubkey "abc123...==" \
  --endpoint "1.2.3.4:51820" \
  --allowed-ips "10.0.0.2/32" \
  --name laptop
```

## Port Forwarding

| Recipe | Uso | Descripción |
|--------|-----|-------------|
| `router-port-forward-list` | `just router-port-forward-list [--ip <IP>] [--env <env>]` | Lista redirects UCI. |
| `router-port-forward-add` | `just router-port-forward-add --name <n> --port <ext> --dest-ip <IP> [--dest-port <p>] [--proto tcp|udp|both]` | Añade DNAT desde WAN. |
| `router-port-forward-remove` | `just router-port-forward-remove --name <nombre> [--ip <IP>] [--env <env>]` | Elimina regla por nombre. |
| `router-port-forward-status` | `just router-port-forward-status [--ip <IP>] [--env <env>]` | Muestra contadores nftables de reglas activas. |

Ejemplos:

```bash
just router-port-forward-list
just router-port-forward-add --name web --port 8080 --dest-ip 192.168.1.50
just router-port-forward-add --name ssh-raspi --port 2222 --dest-ip 192.168.1.136 --dest-port 22
just router-port-forward-status
just router-port-forward-remove --name web
```

## Flujos Típicos

Primera vez:

```bash
just setup
just reinit-secrets prod
just edit-secrets prod
just create-password prod
just setup-env prod
```

Compilar y actualizar:

```bash
just build-prod
just router-backup --ip 192.168.1.1
just router-update --ip 192.168.1.1
just router-status --ip 192.168.1.1
```

Post-flash básico:

```bash
just router-copy-keys --ip 192.168.1.1
just router-status --ip 192.168.1.1
just router-wifi-status 192.168.1.1
```

## Relación Just y Make

| Regla | Estado |
|-------|--------|
| Just puede llamar a Make | Sí |
| Make puede llamar a Just | No |
| Tareas duplicadas entre ambos | No |

- `just`: orquestación, secrets, router y flujos completos.
- `make`: compilación, validación y limpieza base.
