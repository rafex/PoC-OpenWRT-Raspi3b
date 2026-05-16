# Build Instructions — OpenWRT 25.12.2 for TP-Link TL-WDR3600

Guía completa para compilar una imagen personalizada de OpenWRT 25.12.2 para el router TP-Link TL-WDR3600 v1.0 (N600 Wireless Dual Band Gigabit Router).

## Requisitos del sistema

### Sistema operativo recomendado

- **Linux:** Debian 12+ / Ubuntu 22.04+ / Fedora 40+
- **macOS:** Se requiere virtualización o contenedor Linux (el Image Builder solo produce binarios para Linux x86_64)
- **RAM:** 2 GB mínimo (4 GB recomendado)
- **Disco:** ~5 GB libres para el Image Builder y artefactos

### Dependencias

```bash
# Debian / Ubuntu
sudo apt-get install build-essential libncurses-dev zstd wget unzip

# macOS (Homebrew) — solo para inspección, no para compilar
brew install coreutils zstd wget

# Fedora
sudo dnf install make automake gcc gcc-c++ ncurses-devel zstd wget unzip
```

## Pasos de compilación

### 1. Clonar el repositorio

```bash
git clone https://github.com/rafex/PoC-OpenWRT-Raspi3b.git
cd PoC-OpenWRT-Raspi3b
```

### 2. Preparar el entorno

```bash
# Recomendado: con just
just setup           # Instala herramientas, genera clave age, crea environments

# O manualmente:
./scripts/install/setup-env.sh
```

Esto descargará `openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst` y lo extraerá en el directorio `openwrt-builder/`.

### 3. Revisar configuración de paquetes

La configuración de paquetes se define en **`config/openwrt-packages.toml`** (formato TOML, fuente de verdad).
El archivo `config/openwrt-packages.txt` se genera automáticamente desde el TOML — **no se edita manualmente**.

```bash
# Ver la config fuente (TOML)
cat config/openwrt-packages.toml

# Regenerar el .txt manualmente si es necesario
scripts/build/convert-toml-packages.sh --output config/openwrt-packages.txt
```

**Paquetes incluidos:**
- `dropbear` — Servidor SSH
- `dnsmasq`, `firewall4` — DNS/DHCP + Firewall
- `kmod-nft-core`, `kmod-nft-nat` — nftables backend
- `wpad-basic-mbedtls` — Wi-Fi WPA2/3
- `uclient-fetch`, `libustream-mbedtls`, `ca-bundle`, `ca-certificates` — TLS/HTTPS
- `kmod-usb-*`, `kmod-scsi-*`, `kmod-fs-ext4`, `kmod-nls-*`, `block-mount`, `e2fsprogs` — USB storage
- `wireguard-tools`, `kmod-wireguard` — VPN WireGuard
- `rpcd`, `rpcd-mod-file`, `rpcd-mod-iwinfo` — RPC daemon (requerido por ubus/netifd)
- `htop`, `usbutils`, `nano`, `logrotate` — Herramientas de sistema

**Paquetes excluidos:**
- `luci*` — Interfaz web (administración solo por SSH)
- `uhttpd*` — Servidor web
- `rpcd-mod-luci`, `rpcd-mod-rpcsys`, `rpcd-mod-rrdns`, `rpcd-mod-ucode` — Solo módulos LuCI de rpcd
- `tor` — Consume 50-80 MB RAM en dispositivo de 64 MB (riesgo OOM)

### 4. Compilar la imagen

```bash
# Recomendado: con just
just build-dev       # Desarrollo (valores dummy)
just build-prod      # Producción (con secrets reales)

# O con scripts modulares:
./scripts/build/openwrt.sh --builder openwrt-builder/*/

# O con el wrapper (compatible con versión anterior):
./build-openwrt.sh --builder openwrt-builder/*/
```

Opciones disponibles:

```bash
# Con just (recomendado):
just build --profile tplink_tl-wdr3600-v1

# Con scripts modulares:
./scripts/build/openwrt.sh --profile tplink_tl-wdr3600-v1 \
                   --packages config/openwrt-packages.txt \
                   --builder openwrt-builder/openwrt-imagebuilder-*/
```

**Tiempo estimado:** 5–15 minutos (dependiendo del hardware).

### 5. Verificar la imagen

```bash
# Recomendado: con just
just flash prod      # Compila + verifica + prepara para flashear

# O con script modular:
./scripts/build/verify.sh openwrt-builder/openwrt-imagebuilder-*/bin/targets/ath79/generic
```

El script verifica:
- Existencia de los archivos de imagen
- Tamaño (debe caber en los 8 MB de flash del TL-WDR3600)
- Checksums SHA256
- Presencia de paquetes requeridos (best-effort)

## Artefactos generados

Después de una compilación exitosa, encontrarás en `bin/targets/ath79/generic/`:

| Archivo | Descripción |
|---------|-------------|
| `*-factory.bin` | Imagen para flasheo inicial (desde firmware stock) |
| `*-sysupgrade.bin` | Imagen para actualización (desde OpenWRT existente) |
| `sha256sums` | Checksums de verificación |
| `*.manifest` | Lista de paquetes incluidos |

## Resolución de problemas

| Problema | Solución |
|----------|----------|
| `make: command not found` | Instalar `build-essential` |
| Error de espacio en disco | Liberar al menos 5 GB |
| Paquete no encontrado | Verificar nombre en [packages.openwrt.org](https://packages.openwrt.org) |
| `zstd` no encontrado | Instalar `zstd` con el gestor de paquetes |
| Descarga fallida | Verificar conectividad y URL en `scripts/setup-build-env.sh` |

## Referencias

- [OpenWRT Image Builder Guide](https://openwrt.org/docs/guide-user/additional-software/imagebuilder)
- [OpenWRT Downloads](https://downloads.openwrt.org/)
- [TP-Link TL-WDR3600 wiki](https://openwrt.org/toh/tp-link/tl-wdr3600)
