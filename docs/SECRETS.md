# Gestión de Secrets — sops + age

Este proyecto usa **sops** (Secrets OPerationS) con **age** para encryptar secretos que deben ser committeados al repositorio de forma segura. **La clave privada NUNCA se sube al repo.**

## Arquitectura

```
~/.age/poc-openwrt-privkey.txt     ← Clave privada (SOLO en tu disco, permisos 600)
.age-pubkey.txt                    ← Clave pública (committeada, no es secreta)
.sops.yaml                         ← Config sops (mapea entornos → claves age)
environments/{dev,prod}/
├── .env.public                    ← Variables públicas (committeadas, sin secrets)
└── secrets.enc.yaml               ← Secrets encryptados (committeados, solo sops puede leerlos)
```

### Separación de datos públicos y privados

| Archivo | Contiene | ¿Se commitea? |
|---------|----------|---------------|
| `.env.public` | Versión OpenWRT, target, IP del router, **nombres de red WiFi** | ✅ Sí |
| `secrets.enc.yaml` | **Contraseñas WiFi**, clave WireGuard, hash root | ✅ Sí (encryptado) |
| `~/.age/poc-openwrt-privkey.txt` | Clave privada age | ❌ Nunca |

## Estructura de secrets

`secrets.enc.yaml` contiene **solo contraseñas y claves privadas**:

```yaml
WIFI_KEY_24: ""           # Contraseña red 2.4 GHz
WIFI_KEY_5: ""            # Contraseña red 5 GHz
WIREGUARD_PRIVATE_KEY: "" # Clave privada WireGuard
ROOT_PASSWORD_HASH: ""    # Hash SHA-512-crypt para /etc/shadow
```

Los **nombres de red** (SSID) van en `.env.public` — no son secretos:

```bash
WIFI_SSID_24=MiRed24
WIFI_SSID_5=MiRed5G
```

## Setup inicial (una sola vez)

```bash
# Instalar herramientas
# macOS:
brew install just sops age yq shellcheck

# Linux (just install-tools descarga binarios automáticamente):
just install-tools

# Setup completo (genera clave age + estructura de environments)
just setup
```

## Primer uso en una máquina nueva (clonar el repo)

Cuando clonas el repo, los `secrets.enc.yaml` están encriptados con la clave de otra máquina. Debes re-encriptarlos con tu clave local:

```bash
just setup                   # Genera tu clave age local

just reinit-secrets prod     # Actualiza .sops.yaml + recrea secrets.enc.yaml con tu clave
just reinit-secrets dev      # Igual para dev

just edit-secrets prod       # Llenar secrets (WiFi keys, WireGuard)
just create-password prod    # Generar hash de root
just build-prod
```

`reinit-secrets` actualiza `.age-pubkey.txt` y `.sops.yaml` con tu clave pública, elimina el archivo anterior y crea uno nuevo vacío encriptado con tu clave.

## Flujo diario

### Editar secrets

```bash
just edit-secrets prod       # Abre $EDITOR con sops (re-encripta al guardar)
just edit-secrets dev
```

### Generar hash de contraseña root

```bash
just create-password prod    # Pide contraseña en modo oculto, genera hash $6$ e inyecta en secrets
```

El hash se inyecta directamente en `secrets.enc.yaml` sin mostrarse en pantalla ni quedar en historial.

### Ver secrets (solo lectura)

```bash
just decrypt-secrets prod    # Desencripta a /tmp/secrets-prod.yaml
cat /tmp/secrets-prod.yaml
```

### Build con secrets

```bash
just build-prod              # Verifica secrets → genera config → compila
just build-dev
```

Si los secrets no se pueden desencriptar (clave incorrecta), el build falla con instrucciones claras.

## Trade-offs de clave única por proyecto

| Ventajas | Desventajas |
|----------|-------------|
| Simple — una sola clave | Si la clave se filtra, todos los secrets expuestos |
| Setup rápido (~30s) | Rotar clave = re-encryptar todo |
| Sin key server externo | Sin audit trail de quién desencriptó |

**Si el equipo crece a > 3 personas**, considerar migrar a claves por persona (agregar múltiples `age:` en `.sops.yaml`).

## Preguntas frecuentes

### ¿Cloné el repo y no puedo desencriptar?

Los secrets están encriptados con la clave de quien inicializó el repo. Ejecuta:

```bash
just reinit-secrets prod
just reinit-secrets dev
```

Esto regenera los archivos de secrets vacíos encriptados con tu clave local. Luego llénalos con `just edit-secrets` y `just create-password`.

### ¿Perdí la clave privada?

Si pierdes `~/.age/poc-openwrt-privkey.txt`, no podrás desencriptar los secrets. Deberás:

```bash
rm ~/.age/poc-openwrt-privkey.txt   # Eliminar la clave perdida
just generate-age-key               # Generar nueva clave
just reinit-secrets prod
just reinit-secrets dev
just edit-secrets prod              # Re-ingresar todos los secrets
just create-password prod
```

### ¿Alguien más necesita acceso?

Agrega su clave pública a `.sops.yaml`:

```yaml
creation_rules:
  - path_regex: environments/(dev|prod)/secrets\.enc\.yaml$
    key_groups:
      - age:
          - age150en7...  # Tu clave
          - age1abc123... # Clave del nuevo miembro
```

Luego re-encrypta para que ambos puedan acceder:

```bash
sops updatekeys environments/prod/secrets.enc.yaml
sops updatekeys environments/dev/secrets.enc.yaml
```

### ¿Qué hace `just generate-config`?

Toma los templates en `templates/etc/` y reemplaza los placeholders `{{VARIABLE}}` con los valores de `.env.public` y los secrets desencriptados. El resultado se guarda en `config/overlay/<env>/` (no committeado por `.gitignore`).
