# Gestión de Secrets — sops + age

Este proyecto usa **sops** (Secrets OPerationS) con **age** para encryptar secretos que deben ser committeados al repositorio de forma segura. **La clave privada NUNCA se sube al repo.**

## Arquitectura

```
~/.age/poc-openwrt-privkey.txt     ← Clave privada (SOLO en tu disco, permisos 600)
.age-pubkey.txt                    ← Clave pública (committeada, no es secreta)
.sops.yaml                         ← Config sops (mapea entornos → claves age)
environments/{dev,prod}/
├── .env                            ← Variables públicas (committeadas)
└── secrets.enc.yaml                ← Secrets encryptados (committeados, solo sops puede leerlos)
```

## Setup inicial (una sola vez)

```bash
# 1. Instalar herramientas
brew install sops age just

# 2. Generar clave age del proyecto
mkdir -p ~/.age
age-keygen -o ~/.age/poc-openwrt-privkey.txt
chmod 600 ~/.age/poc-openwrt-privkey.txt

# 3. Extraer clave pública al repo
grep "public key" ~/.age/poc-openwrt-privkey.txt | awk '{print $3}' > .age-pubkey.txt

# O si ya ejecutaste el setup automático:
just setup
```

## Flujo diario

### Ver secrets

```bash
# Ver secrets de prod (solo lectura)
sops environments/prod/secrets.enc.yaml

# Alternativa con just
just decrypt-secrets prod
cat /tmp/secrets-prod.yaml
```

### Editar secrets

```bash
# Editar secrets de prod
just edit-secrets prod

# O directamente
sops environments/prod/secrets.enc.yaml
```

Los secrets de **prod** se estructuran así:

```yaml
# Secrets para el router de producción
WIFI_SSID_24: MyWiFi24
WIFI_KEY_24: super-secret-password
WIFI_SSID_5: MyWiFi5G
WIFI_KEY_5: super-secret-password-5g
WIREGUARD_PRIVATE_KEY: AKE-SECRET-KEY-...
ROOT_PASSWORD_HASH: $5$...
DROPBEAR_RSA_HOST_KEY: -----BEGIN <RSA PRIVATE KEY HEADER>-----
TOR_CONTROL_PASSWORD: tor-password
```

### Commitear secrets

Los archivos `*.enc.yaml` son seguros de commitear porque están encryptados con age. El `.gitignore` multinivel asegura que:

- `environments/.gitignore`: bloquea cualquier `.yaml` que NO termine en `.enc.yaml`
- Root `.gitignore`: bloquea `**/*.key`, `**/*.pem`, `.envrc`

### Build con secrets

```bash
# Build para producción (usa secrets reales)
just build-prod

# Build para desarrollo (valores dummy)
just build-dev
```

## Trade-offs de clave única por proyecto

| Ventajas | Desventajas |
|----------|-------------|
| Simple — una sola clave | Si la clave se filtra, todos los secrets expuestos |
| Setup rápido (~30s) | Rotar clave = re-encryptar todo |
| Sin key server externo | Sin audit trail de quién desencriptó |

**Si el equipo crece a > 3 personas**, considerar migrar a claves por persona (agregar múltiples `age:`
en `.sops.yaml`).

## Preguntas frecuentes

### ¿Perdí la clave privada?

Si pierdes `~/.age/poc-openwrt-privkey.txt`, no podrás desencriptar los secrets. Deberás:
1. Generar nueva clave (`age-keygen`)
2. Actualizar `.age-pubkey.txt`
3. Re-crear `secrets.enc.yaml` con la nueva clave
4. Re-ingresar todos los secretos manualmente

### ¿Alguien más necesita acceso?

Agrega su clave pública a `.sops.yaml`:
```yaml
creation_rules:
  - path_regex: environments/prod/secrets\.enc\.yaml$
    key_groups:
      - age:
          - age150en7...  # Clave del proyecto (tú)
          - age1abc123... # Clave del nuevo miembro
```
Luego re-encrypta:
```bash
sops updatekeys environments/prod/secrets.enc.yaml
```

### ¿Qué hace `just generate-config`?

Toma los templates en `templates/etc/` y reemplaza los placeholders `{{VARIABLE}}` con los valores de los secrets desencriptados. El resultado se guarda en `config/overlay/<env>/` (no committeado por `.gitignore`).
