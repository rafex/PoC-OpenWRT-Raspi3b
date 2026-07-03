# Flash Instructions — OpenWRT on TP-Link TL-WDR3600

Procedimiento para instalar la imagen personalizada de OpenWRT 25.12.5 en el router TP-Link TL-WDR3600 v1.0.

> Pre-compila con: `just build-prod`.

## ⚠️ Advertencias

- **Haz backup** de la configuración del router antes de flashear.
- **No interrumpas** el proceso de flasheo (puede brickear el dispositivo).
- **Conecta el router por cable Ethernet** — nunca flashees por Wi-Fi.
- La imagen es específica para hardware **TL-WDR3600 v1.0**. No usar en otros modelos.

## Métodos de instalación

### Método 1: TFTP Recovery (recomendado para primera instalación)

El TL-WDR3600 tiene un servidor TFTP integrado en el bootloader para recuperación.

#### Preparación

1. **Configurar IP estática** en tu computadora:
   ```
   IP: 192.168.0.66
   Máscara: 255.255.255.0
   Gateway: 192.168.0.1
   ```

2. **Instalar servidor TFTP** (si no lo tienes):
   ```bash
   # Debian/Ubuntu
   sudo apt-get install tftpd-hpa
   
   # macOS
   brew install tftp-hpa  # o usar el tftp integrado
   ```

3. **Copiar la imagen factory al directorio TFTP**:
   ```bash
   cp bin/targets/ath79/generic/*-tplink_tl-wdr3600-v1-squashfs-factory.bin /srv/tftp/
   
   # Renombrar (algunos bootloaders requieren nombres específicos)
   cd /srv/tftp/
   mv *-tplink_tl-wdr3600-v1-squashfs-factory.bin wdr3600v1_tp_recovery.bin
   ```

#### Proceso de flasheo

1. **Apagar el router**
2. **Conectar puerto LAN** del router a la computadora (con IP fija 192.168.0.66)
3. **Mantener presionado el botón WPS/Reset**
4. **Encender el router** sin soltar el botón
5. **Esperar ~5 segundos** hasta que el LED de poder parpadee
6. **Soltar el botón** — el router entrará en modo TFTP recovery
7. El router descargará la imagen automáticamente y comenzará el flasheo
8. **Esperar ~3-5 minutos** — NO apagar durante este tiempo
9. El router reiniciará automáticamente con OpenWRT instalado

### Método 2: Web Interface (desde firmware stock)

1. Conectar al router vía Ethernet (puerto LAN)
2. Acceder a `http://192.168.0.1` (o la IP actual del router)
3. Navegar a **System Tools → Firmware Upgrade**
4. Seleccionar el archivo `*-factory.bin`
5. Hacer clic en **Upgrade**
6. Esperar ~3 minutos
7. El router reiniciará con OpenWRT

### Método 3: Sysupgrade (desde OpenWRT existente)

Si ya tienes OpenWRT instalado y solo actualizas, usa las recipes `router-update`:

```bash
# Actualizar manteniendo configuración (IP desde environments/prod/.env.public)
just router-update

# Actualizar con IP distinta
just router-update --ip 192.168.0.1

# Actualizar borrando configuración del router (vuelve a defaults de OpenWRT)
just router-update-force
```

O manualmente:

```bash
# Copiar la imagen al router
scp openwrt-*-sysupgrade.bin root@192.168.1.1:/tmp/

# Conectarse por SSH y flashear (mantiene configuración)
ssh root@192.168.1.1 "sysupgrade -v /tmp/openwrt-*-sysupgrade.bin"

# O borrar configuración
ssh root@192.168.1.1 "sysupgrade -n -v /tmp/openwrt-*-sysupgrade.bin"
```

## Configuración inicial post-flasheo

### 1. Conexión inicial

Después del flasheo, OpenWRT arranca con:
- **IP:** 192.168.1.1
- **SSH:** puerto 22 (sin contraseña en primer arranque — configurar inmediatamente)

```bash
ssh root@192.168.1.1
```

### 2. Establecer contraseña

```bash
passwd
```

### 3. Configurar red básica

```bash
# Editar configuración de red
vi /etc/config/network

# Reiniciar red
/etc/init.d/network restart
```

### 4. Configurar Wi-Fi

```bash
# Editar configuración wireless
vi /etc/config/wireless

# Activar Wi-Fi
wifi up
```

### 5. Configurar VPN (WireGuard)

```bash
# Crear clave privada
wg genkey | tee /etc/wireguard/private.key
chmod 600 /etc/wireguard/private.key

# Configurar interfaz
vi /etc/config/network
# Agregar sección wireguard_iface...
```

### 6. Integración Tor vía Raspberry Pi 3B

```bash
just router-socks-enable
just router-onion-enable
```

## Recuperación en caso de fallo

Si el router no arranca después del flasheo (brick):

1. **TFTP Recovery** (descrito arriba) — casi siempre funciona
2. **Serial console** — requiere abrir el router y conectar UART (3.3V TTL)
3. **Failsafe mode** — si OpenWRT arranca pero la config es incorrecta:
   - Mantener presionado el botón WPS/Reset durante el arranque
   - Esperar a que el LED parpadee rápido (~5 segundos)
   - Acceder por telnet a 192.168.1.1 (sin contraseña)

## Referencias

- [OpenWRT TFTP Recovery](https://openwrt.org/docs/guide-user/installation/tftp-recovery)
- [OpenWRT Failsafe Mode](https://openwrt.org/docs/guide-user/troubleshooting/failsafe_and_factory_reset)
- [TP-Link TL-WDR3600 Hardware](https://openwrt.org/toh/tp-link/tl-wdr3600)
