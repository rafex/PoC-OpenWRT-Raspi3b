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

### Setup inicial (solo una vez)

```bash
# 1. Clonar
git clone https://github.com/rafex/PoC-OpenWRT-Raspi3b.git
cd PoC-OpenWRT-Raspi3b

# 2. Instalar herramientas
brew install just sops age shellcheck

# 3. Setup automático (genera clave age, crea environments)
just setup

# 4. Configurar secrets para prod
just edit-secrets prod
# Agrega: WIFI_KEY_24, WIREGUARD_PRIVATE_KEY, etc.
```

### Build

```bash
# Desarrollo (valores dummy, sin secrets)
just build-dev

# Producción (con secrets reales)
just build-prod

# Validar scripts
just validate
```

### Flashear router

```bash
# Compilar y verificar
just flash prod

# Luego seguir docs/FLASH_INSTRUCTIONS.md
```

## Estructura del repositorio

```
PoC-OpenWRT-Raspi3b/
├── justfile                       # Task manager (único punto de entrada)
├── Makefile                       # Build tasks (compilación)
├── Makefile.just                  # Wrappers de make para just
├── .sops.yaml                     # Config sops (clave age del proyecto)
├── .age-pubkey.txt                # Clave pública age (committeada)
├── .envrc.example                 # Ejemplo de variables (copiar a .envrc)
├── AGENTS.md                      # Requisitos del proyecto
├── LICENSE                        # MIT
├── build-openwrt.sh               # Script principal de compilación
├── config/
│   └── openwrt-packages.txt       # Paquetes a incluir/excluir
├── environments/
│   ├── .gitignore                 # Bloquea secrets no encryptados
│   ├── dev/
│   │   ├── .env                   # Variables públicas dev
│   │   └── secrets.enc.yaml       # Secrets encryptados dev (dummy)
│   └── prod/
│       ├── .env                   # Variables públicas prod
│       └── secrets.enc.yaml       # Secrets encryptados prod (reales)
├── scripts/
│   ├── setup-build-env.sh         # Preparación del entorno
│   ├── verify-image.sh            # Verificación de imagen
│   └── generate-config.sh         # Genera configs desde templates + secrets
├── templates/
│   └── etc/
│       ├── dropbear/              # Template SSH host keys
│       ├── wireguard/             # Template WireGuard config
│       └── config/                # Template wireless config
├── docs/
│   ├── BUILD_INSTRUCTIONS.md
│   ├── FLASH_INSTRUCTIONS.md
│   └── SECRETS.md                 # Guía de gestión de secrets
└── README.md
```

## Documentación

- [Instrucciones de compilación](docs/BUILD_INSTRUCTIONS.md)
- [Instrucciones de instalación/flasheo](docs/FLASH_INSTRUCTIONS.md)
- [Gestión de secrets](docs/SECRETS.md)

## Licencia

MIT — Ver [LICENSE](LICENSE)
