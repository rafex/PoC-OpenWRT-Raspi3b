# Configuración de Build

Esta guía concentra qué archivo editar antes de ejecutar `just build-prod`.

## Resumen Rápido

| Necesitas cambiar | Archivo | Campo |
|-------------------|---------|-------|
| Versión de OpenWRT | `environments/prod/.env.public` | `OPENWRT_VERSION` |
| Target/subtarget | `environments/prod/.env.public` | `TARGET`, `SUBTARGET` |
| Modelo/perfil del router | `environments/prod/.env.public` | `PROFILE` |
| IP/puerto SSH del router | `environments/prod/.env.public` | `ROUTER_IP`, `SSH_PORT` |
| SSID WiFi que irá en firmware | `environments/prod/.env.public` | `WIFI_SSID_24`, `WIFI_SSID_5` |
| Passwords y claves privadas | `environments/prod/secrets.enc.yaml` | editar con `just edit-secrets prod` |
| Paquetes incluidos en firmware | `config/openwrt-packages.toml` | secciones `categories.*` |
| Paquetes excluidos del firmware | `config/openwrt-packages.toml` | sección `exclusions` |
| Paquetes post-flash | `config/openwrt-post-install-packages.toml` | grupos TOML |
| Archivos inyectados al firmware | `templates/etc/` | templates con `{{VARIABLE}}` |

## Entornos

El proyecto usa dos entornos:

- `dev`: valores de prueba.
- `prod`: valores reales para el router.

Cada entorno vive en:

```text
environments/<env>/
├── .env.public
└── secrets.enc.yaml
```

Las recipes como `just build-prod` usan `prod`. Las recipes del router aceptan `env=prod` o `--env prod` para saber qué `.env.public` leer.

## Modelo, Versión y Router

Edita:

```bash
environments/prod/.env.public
```

Ejemplo para TP-Link TL-WDR3600 v1:

```bash
ENV=prod
OPENWRT_VERSION=25.12.5
TARGET=ath79
SUBTARGET=generic
PROFILE=tplink_tl-wdr3600-v1
ROUTER_IP=192.168.1.1
SSH_PORT=22
WIFI_SSID_24=
WIFI_SSID_5=
```

Campos importantes:

- `OPENWRT_VERSION`: versión que descargará `just setup-env prod`.
- `TARGET` y `SUBTARGET`: ruta del Image Builder en OpenWRT.
- `PROFILE`: perfil exacto del dispositivo para `make image`.
- `ROUTER_IP` y `SSH_PORT`: conexión SSH usada por scripts `router-*`.
- `WIFI_SSID_24` y `WIFI_SSID_5`: nombres de red si quieres inyectar APs WiFi al firmware.

Para este PoC el perfil esperado es:

```bash
PROFILE=tplink_tl-wdr3600-v1
```

## Secrets

Los secrets no se editan a mano. Usa:

```bash
just edit-secrets prod
just create-password prod
```

El archivo cifrado es:

```bash
environments/prod/secrets.enc.yaml
```

Campos esperados:

```yaml
WIFI_KEY_24: ""
WIFI_KEY_5: ""
WIREGUARD_PRIVATE_KEY: ""
DROPBEAR_RSA_HOST_KEY: ""
ROOT_PASSWORD_HASH: ""
```

Si un secret queda vacío, `just generate-config prod` omite el archivo de overlay que depende de ese valor para no generar configuración inválida.

## Paquetes del Firmware

La fuente de verdad es:

```bash
config/openwrt-packages.toml
```

Para ver la configuración:

```bash
just packages
```

Para regenerar el `.txt` usado por el Image Builder:

```bash
just refresh-packages
```

No edites manualmente ni lo agregues a git:

```bash
config/openwrt-packages.txt
```

Ese archivo se genera desde el TOML durante `just refresh-packages` y también durante el build. Está ignorado por `.gitignore`.

## Paquetes Post-Flash

Los paquetes que no van dentro del firmware, pero pueden instalarse después con `apk`, se definen en:

```bash
config/openwrt-post-install-packages.toml
```

Ejemplos:

```bash
just router-post-install
just router-post-install captive_portal
```

En OpenWRT 25.12+ el script usa `apk`. Si el router expone `opkg`, lo usa como compatibilidad.

## Overlay y Templates

Los templates fuente están en:

```text
templates/etc/
├── config/wireless.template
├── dropbear/dropbear_rsa_host_key.template
└── wireguard/wg0.conf.template
```

Los placeholders tienen forma:

```text
{{WIFI_SSID_24}}
{{WIFI_KEY_24}}
{{WIREGUARD_PRIVATE_KEY}}
```

`just generate-config prod` lee:

- `environments/prod/.env.public`
- `/tmp/secrets-prod.yaml`, generado por `scripts/install/ensure-secrets.sh prod`

y escribe:

```bash
config/overlay/prod/
```

`just build-prod` pasa ese overlay al Image Builder con `FILES=...`, por lo que esos archivos entran al firmware.

## Flujo Completo

Primera vez en una máquina:

```bash
just setup
just reinit-secrets prod
just edit-secrets prod
just create-password prod
just setup-env prod
just build-prod
```

En una máquina ya configurada:

```bash
just setup-env prod
just build-prod
```

Antes de actualizar un router existente:

```bash
just router-backup
just build-prod
just router-update
```

`just router-update` mantiene configuración. `just router-update-force` borra configuración y vuelve a defaults.

## Archivos que no se Committean

Estos son generados o locales:

```text
config/overlay/
openwrt-builder/
backups/
/tmp/secrets-*.yaml
~/.age/poc-openwrt-privkey.txt
```

La clave privada age nunca debe entrar al repo.

## Checklist Antes de Build

1. `environments/prod/.env.public` tiene `OPENWRT_VERSION`, `TARGET`, `SUBTARGET` y `PROFILE` correctos.
2. `just edit-secrets prod` puede abrir y guardar secrets.
3. `just packages` muestra los paquetes esperados.
4. `just setup-env prod` ya descargó el Image Builder.
5. `just build-prod` compila y ejecuta verificación.
