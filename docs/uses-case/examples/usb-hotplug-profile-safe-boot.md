# Arranque seguro y perfiles USB opcionales

El router siempre inicia desde la configuración guardada en la flash interna. La USB nunca es `/overlay` ni se necesita para entrar por SSH. Al detectar una USB compatible, el servicio `router-profile` monta la partición ext4 en solo lectura, valida una firma `usign` y aplica el perfil en memoria. Si la unidad falta, no monta, tiene una firma inválida o se retira, vuelve a los AP base sin reiniciar.

## Configuración de recuperación del firmware

El perfil `prod` exige:

- `WIFI_SAFE_SSID` en `environments/prod/.env.public`.
- `WIFI_SAFE_KEY` y `ROOT_PASSWORD_HASH` en `environments/prod/secrets.enc.yaml`.
- Una clave de firma por entorno, generada una sola vez.

La red base publica el mismo SSID oculto y clave en las dos bandas. Para editar los valores privados usa `just edit-secrets prod`; genera o actualiza la contraseña con `just create-password prod`. El hash root se aplica en el primer arranque del firmware nuevo. No se puede cambiar con el sistema ya instalado usando solo este mecanismo.

Genera el par de firma:

```sh
just profile-keygen prod
git add environments/prod/profile-signing.pub
```

El host que genera las firmas necesita el binario `usign` (paquete `usign` en Debian/OpenWrt SDK; instálalo con el gestor disponible en tu sistema).

La clave privada queda en `~/.config/poc-openwrt/profile-signing-prod.key`; nunca se copia a la USB ni se commitea. Reconstruye y flashea firmware con instalación limpia (`just router-update-force`) para quitar cualquier fstab de extroot heredado. No conectes la USB durante esta primera puesta en marcha; verifica primero que el modo base permite entrar por SSH.

## Preparar un perfil USB

Formatea la partición como ext4 y ponle la etiqueta `OPENWRT_PROFILE`. Crea `profile.conf` en una máquina host. Ejemplo de uplink Wi-Fi de 2.4 GHz con AP en 5 GHz:

```uci
config router_profile 'main'
    option uplink_mode 'wifi_uplink_2g_ap_5g'
    option uplink_ssid 'Red-uplink'
    option uplink_key 'clave-uplink'
    option ap_ssid 'Portal-Invitados'
    option ap_key 'clave-del-ap'
    option portal_enabled '1'
```

Para AP dual con tethering usa `uplink_mode 'usb_tether'` y conecta el teléfono al router después de que este haya arrancado. El perfil Wi-Fi inverso es `wifi_uplink_5g_ap_2g`. Las contraseñas van en claro dentro del archivo firmado; la firma da autenticidad e integridad, no confidencialidad.

Si el bundle debe incluir `router-agent`, primero configura el portal y aprovisiona la llave SSH restringida que el agente usa contra Dropbear:

```sh
just router-post-install --group captive_portal
just router-captive-setup
just router-add-known-host prod
just router-agent-provision env=prod
just router-agent-build-usb
```

El build intenta Rust para `mipsel-unknown-linux-musl` si el target y linker OpenWrt ya están instalados; si no están disponibles o falla ese build, compila la implementación Go con MIPS little-endian soft-float. Esto genera `router-agent/build/router-agent-mipsle`. Inclúyelo al firmar:

```sh
just profile-pack prod ./profile.conf /media/usb ./router-agent/build/router-agent-mipsle
```

Al incluir el backend, el empaquetador descifra temporalmente el token y llave restringida desde SOPS, los pone en el bundle firmado, y elimina el temporal local al terminar. En el router el API escucha solo en `127.0.0.1:8443`; el agente conecta por SSH a Dropbear local y solo puede ejecutar el dispatcher restringido. El portal actual no invoca automáticamente esta API: una aplicación local debe consumirla y aportar su propia lógica de acceso.

Empaqueta y firma directamente en la USB:

```sh
just profile-pack prod ./profile.conf /media/usb
sync
```

Esto crea `profile.tar.gz` y `profile.tar.gz.sig`. Para `portal_enabled '1'`, instala previamente el portal cautivo y `uhttpd` en el router (`just router-post-install --group captive_portal`, luego `just router-captive-setup`); el supervisor lo mantiene detenido en modo base y lo inicia solo mientras el perfil USB esté activo. La partición debe usar ext4 y la etiqueta indicada. Conecta la unidad a un router ya arrancado; el supervisor espera 15 segundos antes de procesarla. Consulta el resultado desde el host:

```sh
just profile-status
```

El supervisor acepta el ejecutable opcional producido arriba. El archivo firmado completo no puede exceder 16 MiB. `router-agent` sigue siendo un puente HTTP limitado a `allow/block/list/status`; no agrega autenticación de usuarios ni pagos.

## Modos y recuperación

| `uplink_mode` | Radio 2.4 GHz | Radio 5 GHz | Uplink |
|---|---|---|---|
| `usb_tether` | AP | AP | Interfaz de red USB detectada en sysfs |
| `wifi_uplink_2g_ap_5g` | cliente | AP | Wi-Fi 2.4 GHz |
| `wifi_uplink_5g_ap_2g` | AP | cliente | Wi-Fi 5 GHz |

El servicio mantiene los cambios con UCI sin `commit`. Al retirar la USB ejecuta `uci revert` y recarga red y Wi-Fi. En cualquier caso, reiniciar también carga la configuración base persistida en flash. Diagnóstico: `just profile-status` y en el router `logread -e router-profile`.

La USB debe prepararse/repararse en una computadora. El firmware no contiene `e2fsck`; el supervisor tampoco escribe en la partición. No agregues una sección extroot a `/etc/config/fstab`.
