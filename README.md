# PoC-OpenWRT-Raspi3b

Prueba de concepto para compilar una imagen personalizada de **OpenWRT 25.12.2** para el router **TP-Link TL-WDR3600 v1.0**, con administración vía SSH y sin interfaz web LuCi.

## Quick Start

```bash
git clone https://github.com/rafex/PoC-OpenWRT-Raspi3b.git
cd PoC-OpenWRT-Raspi3b

# macOS
brew install just sops age yq shellcheck

# Linux — just install-tools descarga los binarios automáticamente
just install-tools

# Setup inicial (genera clave age + estructura de environments)
just setup

# Primera vez en esta máquina: re-encriptar secrets con tu clave local
just reinit-secrets prod
just reinit-secrets dev

# Llenar secrets y compilar
just edit-secrets prod   # WiFi keys, WireGuard, etc.
just create-password prod  # Hash SHA-512 de root
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
- ✅ Cliente Tor
- ❌ LuCi, uhttpd, rpcd (excluidos — uhttpd disponible via post-install)

## Scripts de gestión del router

| Script | Descripción |
|--------|-------------|
| `just setup-auth` | Copia clave SSH pública + contraseña root |
| `just setup-extroot` | Configura USB como extroot (`/overlay`) |
| `just setup-logs` | Logs persistentes en USB |
| `just post-install` | Instala paquetes adicionales via `opkg` |
| `just setup-captive` | Portal cautivo nftables + uhttpd (sin OpenNDS) |
| `just wifi-ap` | Configura AP interactivo (detecta radios libres) |
| `just wifi-client` | Conecta como cliente WiFi (selección de banda interactiva) |
| `just wifi-scan` / `just wifi-status` | Escanea ambos radios y muestra estado |
| `just routing-priority` / `just routing-pin` | Prioridad WAN vs WiFi + source-based routing |
| `just static-ip-add` / `just static-ip-list` | DHCP leases estáticos por MAC address |
| `just dns-set` / `just dns-show` / `just dns-reset` | Servidores DNS upstream de dnsmasq |
| `just clients` | Lista dispositivos conectados: leases DHCP activos + tabla ARP |
| `just socks-enable` / `just socks-disable` / `just socks-status` | Port forwarding del proxy SOCKS de Raspi3b/Tor |
| `just onion-enable` / `just onion-disable` / `just onion-uninstall` | Transparent proxy `.onion` vía Tor (dnsmasq + nftables DNAT) |

## Licencia

MIT — Ver [LICENSE](LICENSE)
