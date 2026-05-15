# PoC OpenWRT y Raspberry Pi 3B

El objetivo de esta prueba de concepto es demostrar la viabilidad de utilizar OpenWRT en un Raspberry Pi 3B para crear un router personalizado. A continuación se detallan los componentes utilizados y los pasos seguidos para llevar a cabo esta implementación.

Con los mini no breaks, se busca garantizar una fuente de alimentación estable para el Raspberry Pi, evitando interrupciones durante la configuración y uso del dispositivo como router.

## Hardware

- TP-Link (N600 Wireless Dual Band Gigabit Router) TL-WDR3600 v1.0
- Raspberry Pi 3B
- 2 Mini No Break de 8000 mAh

## Software

- OpenWRT 25.12.2 (https://downloads.openwrt.org/releases/25.12.2/targets/ath79/generic/openwrt-imagebuilder-25.12.2-ath79-generic.Linux-x86_64.tar.zst)
- DietPi RPi234 Trixie  (https://dietpi.com/downloads/images/DietPi_RPi234-ARMv8-Trixie.img.xz)

### Objetivo

Compilar una versión personalizada de OpenWRT para el TP-Link TL-WDR3600

#### Que debe considerar la compilación:

- Servidor de SSH
- Certificados para el servidor SSH
- Soporte TLS/HTTPS
- Firewall
- Soporte USB para almacenamiento externo (esto es muy importante ya que este router tiene poco espacio de almacenamiento interno)
- Soporte para VPN (OpenVPN o WireGuard)
- Soporte Wi-Fi (2.4 GHz y 5 GHz)
- Cliente Tor (para anonimizar el tráfico de red)

#### Que no debe considerar la compilación:

- LuCi (la interfaz web de OpenWRT, ya que se planea administrar el router a través de SSH)

### Pasos para la compilación

1. Descargar y preparar el entorno de compilación de OpenWRT.
2. Configurar la compilación para incluir los paquetes necesarios y excluir los no deseados.
3. Compilar la imagen personalizada de OpenWRT para el TP-Link TL-WDR3600.
4. Flashear la imagen compilada en el router TP-Link TL-WDR360

Ejemplo:

```bash
make image PROFILE=tplink_tl-wdr3600-v1 \
PACKAGES="\
dropbear dnsmasq firewall4 wpad-basic-mbedtls \
uclient-fetch libustream-mbedtls ca-bundle ca-certificates \
kmod-usb-core kmod-usb2 kmod-usb-ehci \
kmod-usb-storage kmod-usb-storage-uas \
kmod-scsi-core kmod-scsi-generic \
kmod-fs-ext4 block-mount e2fsprogs \
-luci -luci-base -luci-light -luci-theme-bootstrap \
-luci-app-firewall -luci-app-package-manager \
-luci-mod-admin-full -luci-mod-network -luci-mod-status -luci-mod-system \
-luci-proto-ipv6 -luci-proto-ppp \
-uhttpd -uhttpd-mod-ubus \
-rpcd -rpcd-mod-file -rpcd-mod-iwinfo -rpcd-mod-luci -rpcd-mod-rpcsys -rpcd-mod-rrdns -rpcd-mod-ucode"
```