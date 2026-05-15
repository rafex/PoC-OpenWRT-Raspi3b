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

Descarga y extrae el Image Builder de OpenWRT:

```bash
chmod +x scripts/setup-build-env.sh
./scripts/setup-build-env.sh
```

Esto descargará `openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst` y lo extraerá en el directorio `openwrt-builder/`.

### 3. Revisar configuración de paquetes

El archivo `config/openwrt-packages.txt` contiene la lista de paquetes a incluir y excluir:

```bash
cat config/openwrt-packages.txt
```

**Paquetes incluidos:**
- `dropbear` — Servidor SSH
- `dnsmasq` — DNS/DHCP
- `firewall4` — Firewall nftables
- `wpad-basic-mbedtls` — Wi-Fi WPA2/3
- `uclient-fetch`, `libustream-mbedtls`, `ca-bundle`, `ca-certificates` — TLS/HTTPS
- `kmod-usb-*`, `kmod-scsi-*`, `block-mount`, `e2fsprogs` — USB storage
- `wireguard-tools`, `kmod-wireguard` — VPN WireGuard
- `tor` — Cliente Tor

**Paquetes excluidos:**
- `luci*` — Interfaz web
- `uhttpd*` — Servidor web
- `rpcd*` — RPC daemon

### 4. Compilar la imagen

```bash
chmod +x build-openwrt.sh
./build-openwrt.sh
```

Opciones disponibles:

```bash
./build-openwrt.sh --profile tplink_tl-wdr3600-v1 \
                   --packages config/openwrt-packages.txt \
                   --builder openwrt-builder/openwrt-imagebuilder-*/
```

**Tiempo estimado:** 5–15 minutos (dependiendo del hardware).

### 5. Verificar la imagen

```bash
chmod +x scripts/verify-image.sh
./scripts/verify-image.sh openwrt-builder/openwrt-imagebuilder-*/bin/targets/ath79/generic
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
