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
| `just setup` | Setup inicial completo (tools + age key + environments) |
| `just install-tools` | Verificar herramientas faltantes, mostrar comandos y preguntar antes de instalar |
| `just generate-age-key` | Generar clave age del proyecto en `~/.age/poc-openwrt-privkey.txt` |
| `just create-environments` | Crear estructura `environments/{dev,prod}/` con secrets vacíos |

### Secrets

| Recipe | Descripción |
|--------|-------------|
| `just decrypt-secrets <env>` | Desencriptar `environments/<env>/secrets.enc.yaml` → `/tmp/secrets-<env>.yaml` |
| `just edit-secrets <env>` | Abrir secrets en `$EDITOR` para editar |

### Build

| Recipe | Descripción |
|--------|-------------|
| `just build` | Compilar sin secrets (valores por defecto) |
| `just build-dev` | Compilar para desarrollo (ENV=dev, sin secrets reales) |
| `just build-prod` | Compilar para producción (desencripta secrets + genera config) |
| `just generate-config <env>` | Generar archivos de configuración desde templates + secrets |

### Validación

| Recipe | Descripción |
|--------|-------------|
| `just validate` | Ejecutar `shellcheck` en todos los scripts |

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

### Primera vez

```bash
just setup                              # Instala tools, genera clave age, crea environments
just edit-secrets prod                  # Agrega secrets reales
```

### Compilar para producción

```bash
just build-prod
```

Internamente ejecuta:
1. `just decrypt-secrets prod` → desencripta secrets
2. `just generate-config prod` → genera configs desde templates
3. `make build` → compila la imagen

### Compilar para desarrollo

```bash
just build-dev
```

Usa valores dummy — no requiere secrets.

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
