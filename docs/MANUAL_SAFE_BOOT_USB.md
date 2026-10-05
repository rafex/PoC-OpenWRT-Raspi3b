# Manual de instalación y uso: safe-boot con perfiles USB

Este manual describe cómo instalar la variante **safe-boot** en el TP-Link TL-WDR3600 v1 y cómo preparar una USB para que el router cargue su perfil después de arrancar.

El router siempre arranca desde la flash interna. La USB no es `/overlay` y no se necesita para entrar al router. Al conectar una unidad compatible, el supervisor espera unos segundos, valida el perfil firmado, lo monta en solo lectura y aplica la configuración en memoria. Si algo falla, vuelve al modo base. Al retirar la unidad también revierte al modo base.

> La variante anterior se construye con `just build-prod-legacy`. Este procedimiento instala la nueva variante `safe` con `just build-prod`.

## 1. Qué necesitas

- El repositorio clonado en una computadora Linux o macOS con las herramientas del proyecto.
- Acceso a los secretos de producción mediante SOPS y la clave age correspondiente.
- El Image Builder para OpenWrt 25.12.5, target `ath79/generic`.
- El TL-WDR3600 conectado a la computadora por Ethernet durante el flasheo.
- Una USB con una partición ext4. El supervisor la buscará por la etiqueta `OPENWRT_PROFILE`.
- El programa `usign` en la computadora para crear la clave y firmar el perfil.

La guía de [configuración de secrets](SECRETS.md) explica la preparación de age/SOPS. No copies la clave privada de firma ni la clave privada age a la USB.

## 2. Configura el acceso de recuperación

La imagen safe-boot mantiene un AP oculto en ambas bandas mientras no haya un perfil USB activo. Configura su nombre en `environments/prod/.env.public`:

```bash
WIFI_SAFE_SSID=OpenWRT-Recovery
```

En los secretos de producción define la clave Wi-Fi de recuperación y la contraseña root:

```bash
just edit-secrets prod
just create-password prod
```

En `just edit-secrets prod`, completa `WIFI_SAFE_KEY`. `just create-password prod` genera el hash de `ROOT_PASSWORD_HASH`; esa contraseña será la de root después del primer arranque de la nueva imagen. Guarda el SSID y ambas contraseñas fuera del router. El SSID de recuperación está oculto, así que puede ser necesario introducirlo manualmente en el cliente Wi-Fi.

Si el router ya usa otro entorno o una imagen previa, exporta o respalda la configuración que quieras conservar. La instalación recomendada más abajo usa `sysupgrade -n` y elimina la configuración persistente actual.

## 3. Crea o verifica la clave de firma

El firmware incluye la clave pública y la usa para comprobar la firma de cada perfil USB. La clave privada correspondiente debe permanecer en la computadora que prepara los perfiles.

Si todavía no existe el par de producción, créalo una sola vez:

```bash
just profile-keygen prod
```

El script no sobrescribe claves existentes. Si informa que la clave ya existe, no la regeneres: conserva la privada en `~/.config/poc-openwrt/profile-signing-prod.key` y usa el archivo público `environments/prod/profile-signing.pub` correspondiente. Si pierdes la privada, genera un par nuevo y reconstruye/flashea el firmware para incluir la nueva clave pública.

La clave pública tiene que existir **antes** de compilar. Si la acabas de crear, el build la incluirá automáticamente.

## 4. Descarga el Image Builder y compila safe-boot

Descarga el builder si esta máquina todavía no lo tiene:

```bash
just setup-env prod
```

Compila la variante safe:

```bash
just build-prod
```

La imagen y su checksum se guardan en:

```text
dist/openwrt/prod-safe/
```

Antes de seguir, comprueba que ahí haya un archivo `*-tplink_tl-wdr3600-v1-squashfs-sysupgrade.bin`. La guía [de compilación](BUILD_INSTRUCTIONS.md) cubre los errores del Image Builder.

### Si falla la compilación

- **Falta `WIFI_SAFE_KEY` o `ROOT_PASSWORD_HASH`:** vuelve a `just edit-secrets prod` y `just create-password prod`, y repite `just build-prod`.
- **Falta `WIFI_SAFE_SSID`:** revisa `environments/prod/.env.public`; usa entre 1 y 32 caracteres permitidos por la configuración del proyecto.
- **Falta la clave pública de perfil:** ejecuta `just profile-keygen prod` solo si el par aún no existe, y repite el build.
- **No se encuentra el Image Builder:** ejecuta `just setup-env prod` y confirma que el entorno tenga `OPENWRT_VERSION=25.12.5`, `TARGET=ath79` y `SUBTARGET=generic`.
- **El build legacy falla por credenciales Wi-Fi:** estás ejecutando la imagen anterior por error. Para el nuevo firmware USB usa `just build-prod`.

## 5. Flashea el router por Ethernet

### Si ya tiene OpenWrt y responde por SSH

1. Deja la USB desconectada.
2. Conecta la computadora a un puerto LAN del router por Ethernet.
3. Si necesitas conservar una copia de configuración, hazla antes. `sysupgrade -n` borra los ajustes persistentes, paquetes instalados y cualquier configuración extroot.
4. Instala la imagen safe con una actualización limpia:

   ```bash
   just router-update-force --ip <IP_ACTUAL_DEL_ROUTER>
   ```

   Si la IP coincide con `ROUTER_IP` en `environments/prod/.env.public`, puedes omitir `--ip`.

5. Revisa que el actualizador muestre la imagen correcta, la variante `safe` y el modo que borra configuración. Confirma con `s` cuando pregunte.
6. No desconectes alimentación ni Ethernet mientras comienza el flasheo. SSH se cortará y el router se reiniciará.
7. Espera al menos 3 minutos antes de intentar reconectar.

La imagen de sysupgrade se elige desde `dist/openwrt/prod-safe/`; el actualizador no tomará la imagen legacy como reemplazo.

### Si aún tiene firmware de fábrica

`router-update-force` requiere OpenWrt y SSH; no sirve desde el firmware de fábrica. Usa el archivo `factory.bin` de `dist/openwrt/prod-safe/` mediante TFTP Recovery o la interfaz stock, según [las instrucciones de flasheo](FLASH_INSTRUCTIONS.md). No uses un archivo `sysupgrade.bin` en la interfaz de fábrica.

## 6. Comprueba el primer arranque sin USB

Después del reinicio:

1. Mantén la USB desconectada.
2. Reconecta la computadora por Ethernet. En una instalación limpia, OpenWrt usa normalmente `192.168.1.1`; si la computadora no obtiene dirección, configura temporalmente una IPv4 en `192.168.1.0/24`, por ejemplo `192.168.1.2/24`.
3. Comprueba SSH:

   ```bash
   ssh root@192.168.1.1
   ```

4. Introduce la contraseña root que definiste antes del build.
5. Ya dentro del router, comprueba que el supervisor está instalado y que todavía no hay perfil USB activo:

   ```sh
   /usr/sbin/router-profile status
   logread -e router-profile
   ```

La respuesta esperada antes de conectar una unidad es similar a `fallback: no USB profile loaded` o `fallback: profile volume OPENWRT_PROFILE not detected`. Eso significa que sigue usando la configuración base.

La base ofrece el SSID oculto `WIFI_SAFE_SSID` en 2.4 y 5 GHz, protegido por `WIFI_SAFE_KEY`. Anota los valores configurados antes de salir de la sesión.

### Si no puedes volver a conectar

- Espera 3–5 minutos desde que se cortó SSH; el primer arranque tarda más que un reinicio normal.
- Confirma que el cable esté conectado a un puerto LAN y que la computadora esté en la red `192.168.1.0/24`.
- Prueba `ping 192.168.1.1` y después `ssh root@192.168.1.1`.
- Comprueba que estás usando la contraseña root configurada en los secretos al compilar. El hash se aplica durante el primer arranque de esta imagen.
- Si no responde por Ethernet, busca manualmente el SSID oculto configurado y prueba la clave de recuperación.
- Si sigue sin arrancar, deja la USB desconectada y usa TFTP Recovery descrito en [Flasheo](FLASH_INSTRUCTIONS.md) para reinstalar una imagen compatible.

## 7. Prepara la USB en la computadora

### 7.1 Comprueba la partición

Conecta la unidad a la computadora y localiza la partición correcta:

```bash
lsblk -f
```

Debe ser ext4 y llevar la etiqueta exacta `OPENWRT_PROFILE`. Identifica cuidadosamente el dispositivo, por ejemplo `/dev/sdX1`; el nombre varía entre computadoras. Si necesitas cambiar la etiqueta, desmonta la partición y hazlo desde la computadora:

```bash
sudo e2label /dev/sdX1 OPENWRT_PROFILE
```

No ejecutes el comando hasta verificar que `/dev/sdX1` sea la partición de la USB correcta. Si debes crear/formatear ext4, hazlo en la computadora y recuerda que `mkfs` destruye los datos de esa partición. El router no incluye `e2fsck` y no repara ni escribe el sistema de archivos: monta la USB en solo lectura.

### 7.2 Crea un perfil

Crea `profile.conf` en la computadora. El siguiente ejemplo usa la red Wi-Fi externa de 2.4 GHz como uplink y publica un AP en 5 GHz:

```uci
config router_profile 'main'
    option uplink_mode 'wifi_uplink_2g_ap_5g'
    option uplink_ssid 'Red-uplink'
    option uplink_key 'clave-uplink'
    option ap_ssid 'Portal-Invitados'
    option ap_key 'clave-del-ap'
    option portal_enabled '0'
```

Modos disponibles:

| `uplink_mode` | Uplink | Radio 2.4 GHz | Radio 5 GHz |
|---|---|---|---|
| `wifi_uplink_2g_ap_5g` | Wi-Fi de 2.4 GHz | Cliente | AP |
| `wifi_uplink_5g_ap_2g` | Wi-Fi de 5 GHz | AP | Cliente |
| `usb_tether` | Interfaz de tethering USB detectada | AP | AP |

En modo Wi-Fi incluye `uplink_ssid` y `uplink_key`. En todos los modos incluye `ap_ssid` y `ap_key`. Usa un SSID de 1–32 caracteres y claves Wi-Fi de 8–63 caracteres. El empaquetador acepta letras, números y `_@%+=:,./-`; evita espacios y comillas simples en esos campos.

En modo `usb_tether`, la conexión de tethering (por ejemplo, un teléfono con tethering USB habilitado) debe presentar una interfaz de red USB al router. La USB de almacenamiento que contiene el perfil solo proporciona la configuración; no es por sí misma el uplink.

Empieza con `portal_enabled '0'`. Si lo cambias a `1`, el router necesita tener instalado y configurado el servicio cautivo antes de conectar ese perfil. Consulta la sección opcional de portal más abajo.

Las claves del uplink y del AP se guardan en claro dentro del archivo firmado. La firma protege contra cambios no autorizados, pero no cifra las credenciales.

### 7.3 Firma y copia el perfil

Usa como destino el punto donde la computadora montó la partición ext4 etiquetada `OPENWRT_PROFILE`:

```bash
just profile-pack prod ./profile.conf <PUNTO_DE_MONTAJE_USB>
sync
```

El comando crea estos dos archivos en la raíz de la USB:

```text
profile.tar.gz
profile.tar.gz.sig
```

Desmonta/expulsa la USB de forma segura desde la computadora antes de conectarla al router. No renombres ni edites el archivo después de firmarlo. El bundle firmado no debe superar 16 MiB.

### Si falla la preparación o firma

- **No existe la clave privada:** ejecuta `just profile-keygen prod` solo si no existe ya un par. Si el firmware se construyó con otra clave pública, reconstruye e instala safe-boot con la pública que corresponde a la privada disponible.
- **`profile.conf no cumple el formato`:** conserva una sola sección `config router_profile 'main'`, usa las opciones del ejemplo y evita espacios/comillas adicionales en los valores.
- **No se crea el bundle:** confirma que `usign` está instalado en la computadora y que el directorio de destino es escribible.
- **Perfil activo pero no hay Internet:** revisa modo, SSID/clave del uplink y que el uplink tenga DHCP. Para `usb_tether`, habilita el tethering del teléfono y verifica que aparezca una interfaz de red USB.

## 8. Conecta la USB al router

Solo después de haber comprobado el arranque base:

1. Conecta la USB ext4 etiquetada `OPENWRT_PROFILE` al router ya encendido.
2. Espera unos 20 segundos. En el arranque el servicio escanea después de 12 segundos; el evento hotplug espera aproximadamente 15 segundos.
3. En la consola SSH del router consulta el estado:

   ```sh
   /usr/sbin/router-profile status
   logread -e router-profile
   ```

4. Si el estado indica `active: ...`, prueba la red AP del perfil y confirma que el uplink tenga conexión.
5. Conserva abierta la conexión Ethernet hasta completar las pruebas.

La unidad permanece montada en `/mnt/router-profile` en modo de solo lectura mientras el perfil está activo. Los cambios UCI se aplican en memoria, sin `uci commit`, y no alteran la configuración base almacenada en flash.

## 9. Errores frecuentes y recuperación

El mensaje exacto aparece con:

```sh
/usr/sbin/router-profile status
logread -e router-profile
```

| Estado o síntoma | Causa probable | Cómo resolverlo |
|---|---|---|
| `fallback: profile volume OPENWRT_PROFILE not detected` | Etiqueta distinta, partición sin ext4, unidad/partición no detectada o mala conexión | En la computadora revisa `lsblk -f`; confirma ext4 y etiqueta exacta. Reconecta la unidad después de verificarla. |
| `fallback: signed profile bundle is missing` | Faltan los archivos o no están en la raíz de la partición | Vuelve a ejecutar `just profile-pack prod ./profile.conf <PUNTO_DE_MONTAJE_USB>` y confirma que `profile.tar.gz` y `.sig` aparezcan en la raíz. |
| `fallback: signature verification failed` | Firma no corresponde al firmware o el bundle se modificó después de firmarlo | Comprueba que usaste la clave privada emparejada con la clave pública incluida en la imagen. Firma de nuevo el perfil y reinstala el bundle sin editarlo. |
| `fallback: firmware has no profile verification key` | La imagen no incluye `profile-signing.pub` | Confirma que el archivo público exista en `environments/prod/`, ejecuta `just build-prod` y reinstala desde `dist/openwrt/prod-safe/`. |
| `fallback: invalid AP credentials` o `AP key must be 8-63 characters` | SSID/clave vacíos, demasiado largos o con caracteres no aceptados | Corrige `ap_ssid`/`ap_key`, firma de nuevo y vuelve a conectar. |
| `fallback: invalid Wi-Fi uplink credentials` | Faltan `uplink_ssid`/`uplink_key` o usan caracteres no aceptados | Corrige ambos campos y firma de nuevo. Confirma también que la contraseña tenga 8–63 caracteres. |
| `fallback: no USB network interface detected` | El perfil usa `usb_tether`, pero no hay tethering de red presente | Habilita tethering USB en el teléfono/dispositivo, vuelve a conectarlo y reconecta la unidad de perfil. Alternativamente usa uno de los modos de uplink Wi-Fi. |
| `fallback: captive service is not installed` | `portal_enabled` vale `1`, pero el servicio cautivo no existe en el router | Cambia a `portal_enabled '0'` y vuelve a firmar; o instala/configura primero el portal como se describe abajo. |
| Se activa el perfil pero no aparece el AP | Cliente conectado al SSID oculto anterior, clave equivocada o radio aún recargando | Busca el nuevo `ap_ssid`, verifica `ap_key` y consulta `logread -e router-profile`. Mantén Ethernet para volver a administrar. |
| El router se reinicia al conectar la unidad | Problema de alimentación, USB/partición defectuosa o un problema ajeno al perfil | Retira la USB y deja arrancar el router sin ella. No repitas ciclos de encendido con la unidad conectada. Recoge logs desde el router y examina/repara ext4 en la computadora con la partición desmontada. |

Para volver inmediatamente al modo base, retira la USB. El hotplug ejecutará la reversión; confirma `fallback: USB profile removed`. También puedes reiniciar el router sin la unidad: siempre vuelve a la configuración persistida en flash.

Si la unidad parece dañada, no la formatees antes de respaldarla. Inspección y reparación del sistema de archivos se hacen en una computadora, nunca en el router. Conserva los logs que puedas leer antes de reparar.

## 10. Portal cautivo y backend opcionales

El perfil solo inicia el portal si `portal_enabled '1'`; no instala sus paquetes. Como instalar paquetes requiere que el router tenga Internet, primero conecta un perfil con uplink y `portal_enabled '0'`. Cuando el router tenga conectividad, instala el grupo cautivo y configura el servicio:

```bash
just router-post-install group=captive_portal ip=192.168.1.1 env=prod
just router-captive-setup ip=192.168.1.1 env=prod
```

Después confirma que `/etc/init.d/captive` exista y que el servicio funcione. Edita `profile.conf` para poner `portal_enabled '1'`, vuelve a firmarlo con `just profile-pack`, expulsa la USB y vuelve a conectarla al router. Mantén acceso Ethernet para recuperación. Si el router aún no tiene uplink, instala primero el portal dentro de una imagen personalizada o configura temporalmente un uplink; sin Internet los paquetes no se podrán descargar.

El backend `router-agent` es opcional y se empaqueta aparte. Su API local no implementa por sí sola la autenticación de usuarios ni la lógica comercial del portal. Sigue el apartado de `router-agent` en [la guía de perfiles USB](uses-case/examples/usb-hotplug-profile-safe-boot.md) para aprovisionar credenciales, compilarlo y firmarlo dentro del bundle.

## Comandos de referencia

```bash
# Preparar entorno y build safe-boot
just setup-env prod
just profile-keygen prod     # Solo cuando aún no exista el par
just build-prod

# Flashear desde OpenWrt existente; borra la configuración persistente
just router-update-force --ip <IP_ACTUAL_DEL_ROUTER>

# Firmar la configuración USB
just profile-pack prod ./profile.conf <PUNTO_DE_MONTAJE_USB>

# En el router, inspeccionar carga y errores
/usr/sbin/router-profile status
logread -e router-profile
```

Para el detalle de comandos generales, consulta [Uso de Just](JUST.md), [Flasheo](FLASH_INSTRUCTIONS.md) y [Secrets](SECRETS.md).
