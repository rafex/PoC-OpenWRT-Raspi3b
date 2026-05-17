# Uso de Just — Task Manager

`justfile` es el **único punto de entrada** del proyecto. Orquesta todas las tareas: setup, secrets, build, validación, flasheo y configuración del router.

```bash
just --list                    # Ver todas las recipes disponibles
just <recipe>                  # Ejecutar una recipe
```

## Recipes

### Setup

| Recipe | Descripción |
|--------|-------------|
| `just setup [force=true]` | Setup inicial: tools + age key + environments |
| `just install-tools [force=true]` | Instalar herramientas faltantes (`just`, `make`, `sops`, `age`, `yq`) |
| `just validate-tools` | Verificar herramientas instaladas con sus versiones |
| `just generate-age-key` | Generar clave age en `~/.age/poc-openwrt-privkey.txt` |
| `just create-environments` | Crear `environments/{dev,prod}/` con `.env.public` y secrets vacíos encriptados |
| `just setup-hooks` | Configurar `.githooks/` como directorio de hooks de git |

### Secrets

| Recipe | Descripción |
|--------|-------------|
| `just reinit-secrets <env>` | Re-encriptar secrets con la clave age local (usar al clonar el repo) |
| `just decrypt-secrets <env>` | Desencriptar secrets → `/tmp/secrets-<env>.yaml` |
| `just edit-secrets <env>` | Abrir secrets en `$EDITOR` para editar (WiFi keys, WireGuard, etc.) |
| `just create-password <env>` | Pedir contraseña root, generar hash SHA-512 e inyectarlo en secrets |

### Paquetes

| Recipe | Descripción |
|--------|-------------|
| `just packages` | Mostrar paquetes de firmware agrupados (desde `config/openwrt-packages.toml`) |
| `just refresh-packages` | Regenerar `config/openwrt-packages.txt` desde el TOML |

### Build

| Recipe | Descripción |
|--------|-------------|
| `just build` | Compilar sin secrets (valores por defecto) |
| `just build-dev` | Compilar para desarrollo (verifica secrets dev, genera config, compila) |
| `just build-prod` | Compilar para producción (verifica secrets prod, genera config, compila) |
| `just generate-config <env>` | Generar archivos de configuración desde templates + secrets |

### Validación

| Recipe | Descripción |
|--------|-------------|
| `just validate` | Ejecutar `shellcheck` en todos los scripts |
| `just validate-tools` | Verificar que todas las herramientas están instaladas |

### Update / Flasheo

| Recipe | Descripción |
|--------|-------------|
| `just update [ip=<IP>] [env=<env>]` | Actualizar firmware via sysupgrade **manteniendo** configuración |
| `just update-force [ip=<IP>] [env=<env>]` | Actualizar firmware **borrando** configuración del router |
| `just flash [env]` | Compilar y preparar imagen (no flashea automáticamente) |

La IP se infiere de `environments/<env>/.env.public` (`ROUTER_IP`). Por defecto `192.168.1.1`.

### Configuración inicial del router

| Recipe | Descripción |
|--------|-------------|
| `just setup-extroot [ip=] [device=] [env=]` | Configura USB como extroot (`/overlay`) para ampliar almacenamiento |
| `just setup-logs [ip=] [env=]` | Configura logs persistentes en el USB (requiere extroot activo) |
| `just setup-auth [ip=] [env=] [key=]` | Copia clave SSH pública al router y establece contraseña root |

### Post-instalación de paquetes

| Recipe | Descripción |
|--------|-------------|
| `just post-install [group=] [ip=] [env=]` | Instala paquetes adicionales via `opkg` (lee `openwrt-post-install-packages.toml`) |

Ejemplo:
```bash
just post-install                          # Instala todos los grupos
just post-install group=captive_portal     # Solo el grupo captive_portal (uhttpd)
scripts/build/post-install.sh --list       # Ver grupos disponibles
```

### Portal cautivo

Requiere: `just post-install group=captive_portal` (instala `uhttpd`).

| Recipe | Descripción |
|--------|-------------|
| `just setup-captive [ip=] [env=] [timeout=30] [portal-url=] [token=]` | Instala el portal cautivo (nftables + uhttpd) |
| `just remove-captive [ip=] [env=]` | Desinstala el portal cautivo |
| `just captive-allow client=<IP> [timeout=30] [ip=] [env=]` | Autoriza una IP manualmente (`timeout=0` = permanente) |
| `just captive-block client=<IP> [ip=] [env=]` | Revoca el acceso de una IP |
| `just captive-flush [ip=] [env=]` | Limpia todos los clientes autorizados |
| `just captive-list [ip=] [env=]` | Lista clientes autorizados y estado del portal |
| `just captive-status [ip=] [env=]` | Diagnóstico completo del portal |

Ejemplos:
```bash
just setup-captive                                      # Portal local (HTML en el router)
just setup-captive portal-url=https://portal.example.com token=abc123  # Portal externo
just captive-allow client=192.168.1.50                 # 30 min (default)
just captive-allow client=192.168.1.50 timeout=120     # 2 horas
just captive-allow client=192.168.1.50 timeout=0       # Sin límite
```

### WiFi

| Recipe | Descripción |
|--------|-------------|
| `just wifi-ap ssid=<nombre> [password=] [radio=radio0] [channel=auto] [ip=] [env=]` | Configura un Access Point |
| `just wifi-client ssid=<nombre> [password=] [radio=radio1] [ip=] [env=]` | Conecta el router como cliente WiFi (crea interfaz `wwan`) |
| `just wifi-scan [radio=] [ip=] [env=]` | Escanea redes WiFi disponibles |
| `just wifi-status [ip=] [env=]` | Muestra estado de radios e interfaces (banda, canal, SSID, clientes) |
| `just wifi-enable radio=<r> [ip=] [env=]` | Habilita un radio |
| `just wifi-disable radio=<r> [ip=] [env=]` | Deshabilita un radio |

Valores válidos de radio: `radio0`, `radio1`, `2g`, `5g`.

Ejemplos:
```bash
just wifi-ap ssid="MiRed" password="clave1234"          # AP en 2.4 GHz
just wifi-ap ssid="MiRed5G" radio=5g channel=36         # AP en 5 GHz sin contraseña
just wifi-client ssid="RedExterna" password="supass"    # Cliente en 5 GHz (radio1)
just wifi-scan radio=5g
just wifi-status
just wifi-disable radio=radio1
```

### Routing

Gestiona qué interfaz usa el router como salida a internet y permite fijar IPs LAN a interfaces concretas.

| Recipe | Descripción |
|--------|-------------|
| `just routing-status [ip=] [env=]` | Muestra rutas, gateways, métricas y pins activos |
| `just routing-priority mode=<wan\|wifi\|equal> [ip=] [env=]` | Define la interfaz de salida preferida |
| `just routing-pin from=<IP> via=<wan\|wifi> [ip=] [env=]` | Fija tráfico de una IP LAN a una interfaz concreta |
| `just routing-unpin from=<IP> [ip=] [env=]` | Elimina el pin de una IP LAN |
| `just routing-pins [ip=] [env=]` | Lista todos los pins activos |
| `just routing-reset [ip=] [env=]` | Elimina todos los pins y restaura prioridad a WAN |

Modos de prioridad:
- `wan` — WAN físico como gateway preferido (métrica más baja)
- `wifi` — Cliente WiFi (`wwan`) como gateway preferido
- `equal` — Ambas interfaces con la misma métrica

Los pins de enrutamiento persisten entre reinicios vía `/etc/routing-pins.conf` y un hotplug script.

Ejemplos:
```bash
just routing-priority mode=wifi                          # Preferir WiFi cliente
just routing-pin from=192.168.1.50 via=wifi             # Laptop siempre por WiFi
just routing-pin from=192.168.1.51 via=wan              # Servidor siempre por WAN
just routing-unpin from=192.168.1.50
just routing-reset
```

### IPs Estáticas

Gestiona DHCP static leases: asigna IPs fijas a dispositivos por MAC address.

| Recipe | Descripción |
|--------|-------------|
| `just static-ip-add mac=<MAC> assign=<IP> [name=] [ip=] [env=]` | Asigna IP estática a un dispositivo |
| `just static-ip-remove mac=<MAC> \| assign=<IP> [ip=] [env=]` | Elimina asignación por MAC o por IP |
| `just static-ip-list [ip=] [env=]` | Muestra todas las asignaciones + leases activos |
| `just static-ip-clear [ip=] [env=]` | Elimina todas las asignaciones |
| `just static-ip-import file=<csv> [ip=] [env=]` | Importa desde CSV (formato: `MAC,IP,nombre`) |

Ejemplos:
```bash
just static-ip-add mac=AA:BB:CC:DD:EE:FF assign=192.168.1.100 name=servidor
just static-ip-remove mac=AA:BB:CC:DD:EE:FF
just static-ip-remove assign=192.168.1.100
just static-ip-list
just static-ip-import file=hosts.csv
```

### Limpieza

| Recipe | Descripción |
|--------|-------------|
| `just clean` | Limpiar artefactos de compilación |
| `just clean-all` | Limpiar artefactos + overlay de configuración |

---

## Flujos de trabajo típicos

### Primera vez (o máquina nueva)

```bash
just install-tools              # Linux: descarga binarios. macOS: indicaciones brew
just setup                      # Genera clave age, crea environments

# Si el repo ya tiene secrets de otra máquina:
just reinit-secrets prod
just reinit-secrets dev

just edit-secrets prod          # Agrega WiFi keys, WireGuard, etc.
just create-password prod       # Genera hash de root
```

### Compilar y flashear

```bash
just build-prod
# Sigue docs/FLASH_INSTRUCTIONS.md para el flasheo físico

# Post-flash: configuración inicial del router
just setup-auth                 # Clave SSH + contraseña root
just setup-extroot              # USB como extroot (si hay USB conectado)
just setup-logs                 # Logs persistentes (tras reinicio con extroot)
```

### Configurar WiFi

```bash
just wifi-status                                         # Ver estado actual
just wifi-ap ssid="MiRed" password="clave1234"           # Configurar AP 2.4 GHz
just wifi-ap ssid="MiRed5G" radio=5g password="clave5g" # Configurar AP 5 GHz
just wifi-client ssid="RedExterna" password="supass"     # Conectar como cliente WiFi
```

### Instalar portal cautivo

```bash
just post-install group=captive_portal  # Instala uhttpd en el router
just setup-captive                      # Instala el portal (30 min por defecto)
just captive-status                     # Verificar que funciona
just captive-allow client=192.168.1.50  # Autorizar dispositivo manualmente
```

### Gestionar routing

```bash
# Router con WAN físico + cliente WiFi (setup-wifi.sh client):
just routing-status                                      # Ver configuración actual
just routing-priority mode=wifi                          # Preferir WiFi como salida
just routing-pin from=192.168.1.100 via=wan             # Servidor NAS siempre por WAN
just routing-pin from=192.168.1.50  via=wifi            # Laptop siempre por WiFi
```

### Asignar IPs fijas

```bash
just static-ip-add mac=AA:BB:CC:DD:EE:FF assign=192.168.1.10 name=nas
just static-ip-add mac=BB:CC:DD:EE:FF:00 assign=192.168.1.11 name=impresora
just static-ip-list
```

---

## Relación Just ↔ Make

| Regla | Descripción |
|-------|-------------|
| Just → Make | ✅ Just puede llamar a Make |
| Make → Just | ❌ Make NUNCA llama a Just |
| Sin duplicados | No hay tareas duplicadas entre ambos |

- **`just`**: Orquesta (setup, secrets, router, flujo completo)
- **`make`**: Build y validación (compile, shellcheck, clean)
