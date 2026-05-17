# Uso de Just — Task Manager

`justfile` es el **único punto de entrada** del proyecto. Orquesta todas las tareas: setup, secrets, build, validación y flasheo.

```bash
just --list                    # Ver todas las recipes disponibles
just <recipe>                  # Ejecutar una recipe
```

## Recipes

### Setup

| Recipe | Descripción |
|--------|-------------|
| `just setup` | Setup inicial (tools + age key + environments). Usa `just setup force=true` para forzar reinstalación |
| `just install-tools` | Verificar e instalar herramientas faltantes (`just`, `make`, `sops`, `age`, `yq`). Usa `force=true` para reinstalar |
| `just validate-tools` | Validar que todas las herramientas requeridas están instaladas con sus versiones |
| `just generate-age-key` | Generar clave age del proyecto en `~/.age/poc-openwrt-privkey.txt` |
| `just create-environments` | Crear estructura `environments/{dev,prod}/` con `.env.public` y secrets vacíos encriptados |

### Secrets

| Recipe | Descripción |
|--------|-------------|
| `just reinit-secrets <env>` | Re-encriptar secrets con la clave age local. Usar al clonar el repo en una máquina nueva |
| `just decrypt-secrets <env>` | Desencriptar `environments/<env>/secrets.enc.yaml` → `/tmp/secrets-<env>.yaml` |
| `just edit-secrets <env>` | Abrir secrets en `$EDITOR` para editar (WiFi keys, WireGuard, etc.) |
| `just create-password <env>` | Pedir contraseña root en modo oculto, generar hash SHA-512 e inyectarlo en secrets |

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
| `just validate-tools` | Verificar que todas las herramientas requeridas están instaladas |

### Flasheo

| Recipe | Descripción |
|--------|-------------|
| `just flash <env>` | Compilar y preparar para flashear (default: prod) |

### Limpieza

| Recipe | Descripción |
|--------|-------------|
| `just clean` | Limpiar artefactos de compilación |
| `just clean-all` | Limpiar artefactos + overlay de configuración |

## Flujo de trabajo típico

### Primera vez (o máquina nueva)

```bash
just install-tools                      # Linux: descarga binarios. macOS: indicaciones brew
just setup                              # Genera clave age, crea environments

# Si el repo ya tiene secrets de otra máquina, re-encriptar con clave local:
just reinit-secrets prod
just reinit-secrets dev

just edit-secrets prod                  # Agrega WiFi keys, WireGuard, etc.
just create-password prod               # Genera y guarda hash de root
```

### Compilar para producción

```bash
just build-prod
```

Internamente ejecuta:
1. `scripts/install/ensure-secrets.sh prod` → verifica clave age y desencripta secrets
2. `just generate-config prod` → genera configs desde templates
3. `make build` → compila la imagen

Si los secrets no se pueden desencriptar, el build falla con instrucciones claras.

### Compilar para desarrollo

```bash
just build-dev
```

Mismo flujo que prod pero con `environments/dev/`. Los campos vacíos en secrets se omiten (esa funcionalidad no se configura).

### Validar scripts

```bash
just validate
```

Equivalente a `make validate` → `shellcheck scripts/**/*.sh build-openwrt.sh`.

### Flashear router

```bash
just flash prod
```

Equivalente a `just build-prod` + verificación de imagen.

## Relación Just ↔ Make

| Regla | Descripción |
|-------|-------------|
| Just → Make | ✅ Just puede llamar a Make |
| Make → Just | ❌ Make NUNCA llama a Just |
| Sin duplicados | No hay tareas duplicadas entre ambos |

- **`just`**: Orquesta (setup, secrets, flujo completo)
- **`make`**: Build y validación (compile, shellcheck, clean)
