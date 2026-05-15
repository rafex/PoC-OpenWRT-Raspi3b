# PoC-OpenWRT-Raspi3b

Prueba de concepto para compilar una imagen personalizada de **OpenWRT 25.12.2** para el router **TP-Link TL-WDR3600 v1.0**, con administración vía SSH y sin interfaz web LuCi.

## Hardware

| Dispositivo | Modelo |
|-------------|--------|
| Router | TP-Link TL-WDR3600 v1.0 (N600 Dual Band) |
| SBC | Raspberry Pi 3B |
| UPS | 2× Mini No Break 8000 mAh |

## Software

| Componente | Versión |
|------------|---------|
| OpenWRT | 25.12.2 (ath79/generic) |
| DietPi | RPi234 Trixie (ARMv8) |

## Características de la imagen

- ✅ SSH con certificados (`dropbear`)
- ✅ TLS / HTTPS (`ca-bundle`, `ca-certificates`, `libustream-mbedtls`)
- ✅ Firewall (`firewall4` — nftables)
- ✅ USB Storage (`kmod-usb-storage`, `block-mount`, ext4)
- ✅ VPN WireGuard (`wireguard-tools`, `kmod-wireguard`)
- ✅ Wi-Fi Dual-Band 2.4/5 GHz (`wpad-basic-mbedtls`)
- ✅ Cliente Tor (`tor`)
- ❌ LuCi (interfaz web) — excluido
- ❌ uhttpd / rpcd — excluidos

## Quick Start

```bash
# 1. Preparar entorno
chmod +x scripts/setup-build-env.sh
./scripts/setup-build-env.sh

# 2. Compilar imagen
chmod +x build-openwrt.sh
./build-openwrt.sh

# 3. Verificar artefactos
chmod +x scripts/verify-image.sh
./scripts/verify-image.sh openwrt-builder/*/bin/targets/ath79/generic

# 4. Flashear router
# Ver docs/FLASH_INSTRUCTIONS.md
```

## Estructura del repositorio

```
PoC-OpenWRT-Raspi3b/
├── build-openwrt.sh              # Script principal de compilación
├── config/
│   └── openwrt-packages.txt      # Paquetes a incluir/excluir
├── scripts/
│   ├── setup-build-env.sh        # Preparación del entorno
│   └── verify-image.sh           # Verificación de imagen
├── docs/
│   ├── BUILD_INSTRUCTIONS.md     # Guía de compilación
│   └── FLASH_INSTRUCTIONS.md     # Guía de instalación
├── AGENTS.md                     # Requisitos del proyecto
├── LICENSE                       # MIT
└── README.md                     # Este archivo
```

## Documentación

- [Instrucciones de compilación](docs/BUILD_INSTRUCTIONS.md)
- [Instrucciones de instalación/flasheo](docs/FLASH_INSTRUCTIONS.md)

## Licencia

MIT — Ver [LICENSE](LICENSE)
