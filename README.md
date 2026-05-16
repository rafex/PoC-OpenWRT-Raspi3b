# PoC-OpenWRT-Raspi3b

Prueba de concepto para compilar una imagen personalizada de **OpenWRT 25.12.2** para el router **TP-Link TL-WDR3600 v1.0**, con administración vía SSH y sin interfaz web LuCi.

## Quick Start

```bash
git clone https://github.com/rafex/PoC-OpenWRT-Raspi3b.git
cd PoC-OpenWRT-Raspi3b
brew install just sops age shellcheck
just setup
just edit-secrets prod   # Agrega WIFI_KEY_24, WIREGUARD_PRIVATE_KEY, etc.
just build-prod          # Compilar con secrets reales
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
- ❌ LuCi, uhttpd, rpcd (excluidos)

## Licencia

MIT — Ver [LICENSE](LICENSE)
