# PoC-OpenWRT-Raspi3b

Prueba de concepto para compilar una imagen personalizada de **OpenWRT 25.12.5** para el router **TP-Link TL-WDR3600 v1.0**, con administración vía SSH y sin interfaz web LuCi. La versión está fijada para reproducibilidad del PoC.

## Quick Start

```bash
git clone https://github.com/rafex/PoC-OpenWRT-Raspi3b.git
cd PoC-OpenWRT-Raspi3b

# macOS — instalar dependencias con brew
brew install just sops age yq shellcheck

# Linux — just install-tools descarga los binarios automáticamente a ~/.local/bin
just setup   # tools + age key + estructura de environments + git hooks

# Primera vez en esta máquina: re-encriptar secrets con tu clave local
just reinit-secrets prod
just reinit-secrets dev

# Descargar el Image Builder de OpenWRT (una vez por máquina)
just setup-env prod

# (Opcional) Llenar secrets antes de compilar
just edit-secrets prod    # WiFi keys, WireGuard, etc.
just create-password prod # Hash SHA-512 de root

# Compilar
just build-prod
```

## Documentación

| Guía | Descripción |
|------|-------------|
| [Uso de Just](docs/JUST.md) | Todas las recipes del task manager |
| [Scripts](docs/SCRIPTS.md) | Referencia de scripts modulares |
| [Compilación](docs/BUILD_INSTRUCTIONS.md) | Guía completa de compilación |
| [Flasheo](docs/FLASH_INSTRUCTIONS.md) | Instalación en el router |
| [Secrets](docs/SECRETS.md) | Gestión de secrets con sops+age |

## Características de la imagen

- ✅ SSH (`dropbear`) · TLS/HTTPS · Firewall (`nftables`)
- ✅ USB Storage (`ext4`, `block-mount`)
- ✅ VPN WireGuard · Wi-Fi Dual-Band (2.4/5 GHz)
- ✅ Integración Tor vía Raspberry Pi 3B (SOCKS y proxy transparente `.onion`)
- ❌ LuCi, uhttpd y módulos LuCI de `rpcd` excluidos
- ✅ `rpcd` base incluido para servicios del sistema (`ubus`/`netifd`)

## Gestión del router (vía SSH)

Las recetas con prefijo `router-` se ejecutan en el router OpenWRT vía SSH.
Las recetas sin prefijo corren localmente (build, secrets, herramientas).

| Receta | Descripción |
|--------|-------------|
| `just router-setup-auth` | Copia clave SSH pública + contraseña root |
| `just router-setup-extroot` | Configura USB como extroot (`/overlay`) |
| `just router-setup-logs` | Logs persistentes en USB |
| `just router-post-install` | Instala paquetes adicionales via `apk`/`opkg` |
| `just router-captive-setup` | Portal cautivo nftables + uhttpd (sin OpenNDS) |
| `just router-wifi-ap` | Configura AP interactivo (detecta radios libres) |
| `just router-wifi-client` | Conecta como cliente WiFi (selección de banda interactiva) |
| `just router-wifi-scan` / `just router-wifi-status` | Escanea ambos radios y muestra estado |
| `just router-routing-priority` / `just router-routing-pin` | Prioridad WAN vs WiFi + source-based routing |
| `just router-static-ip-add` / `just router-static-ip-list` | DHCP leases estáticos por MAC address |
| `just router-dns-set` / `just router-dns-show` / `just router-dns-reset` | Servidores DNS upstream de dnsmasq |
| `just router-clients` | Lista dispositivos conectados: leases DHCP activos + tabla ARP |
| `just router-status` | Vista general: sistema, RAM, red, WiFi, clientes DHCP y servicios |
| `just router-backup` / `just router-restore` / `just router-backup-list` | Backup y restauración de configuración (`/etc/config`) |
| `just router-reboot` / `just router-reboot --wait` | Reinicia el router; `--wait` bloquea hasta reconexión |
| `just router-update` / `just router-update-force` | Actualiza firmware via sysupgrade |
| `just router-wireguard-status` / `just router-wireguard-peer-list` | Estado del túnel WireGuard y peers activos |
| `just router-wireguard-peer-add` / `just router-wireguard-peer-remove` | Añade / elimina peers WireGuard via UCI |
| `just router-port-forward-list` / `just router-port-forward-add` / `just router-port-forward-remove` | Port forwarding DNAT desde WAN (TCP/UDP/ambos) |
| `just router-socks-enable` / `just router-socks-disable` / `just router-socks-status` | Port forwarding del proxy SOCKS de Raspi3b/Tor |
| `just router-onion-enable` / `just router-onion-disable` / `just router-onion-uninstall` | Transparent proxy `.onion` vía Tor (dnsmasq + nftables DNAT) |
| `just router-onion-doctor` | Diagnóstico capa por capa del stack `.onion` (DHCP → dnsmasq → nftables → puertos Tor) |

## Licencia

MIT — Ver [LICENSE](LICENSE)
