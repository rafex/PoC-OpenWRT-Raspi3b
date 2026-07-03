# PoC OpenWRT y Raspberry Pi 3B

El objetivo de esta prueba de concepto es demostrar la viabilidad de utilizar OpenWRT en un Raspberry Pi 3B para crear un router personalizado.

Con los mini no breaks, se busca garantizar una fuente de alimentación estable para el Raspberry Pi, evitando interrupciones durante la configuración y uso del dispositivo como router.

## Hardware

- TP-Link (N600 Wireless Dual Band Gigabit Router) TL-WDR3600 v1.0
- Raspberry Pi 3B
- 2 Mini No Break de 8000 mAh

## Software

- OpenWRT 25.12.5
- DietPi RPi234 Trixie (ARMv8)

## Objetivo

Compilar una versión personalizada de OpenWRT para el TP-Link TL-WDR3600 con:

- ✅ SSH con certificados
- ✅ TLS/HTTPS
- ✅ Firewall (nftables)
- ✅ USB Storage
- ✅ VPN WireGuard
- ✅ Wi-Fi Dual-Band (2.4/5 GHz)
- ✅ Integración Tor vía Raspberry Pi 3B (SOCKS/.onion transparent proxy)
- ❌ LuCi, uhttpd, módulos LuCI de rpcd (excluidos)
- ✅ `rpcd` base incluido solo para servicios del sistema (`ubus`/`netifd`)

## Arquitectura del proyecto

### Task manager: `just`

`justfile` es el **único punto de entrada**. Orquesta todas las tareas: setup, secretos, build, validación, flasheo.

```bash
just --list      # Ver todas las tareas
just setup       # Setup inicial
just build-prod  # Compilar con secrets reales
```

Ver [docs/JUST.md](docs/JUST.md) para la guía completa de recipes.

### Build: `make`

`Makefile` contiene solo tareas de compilación y validación. No orquesta — es llamado por `just`.

**Regla:** Just puede llamar a Make, pero Make NUNCA llama a Just. No hay tareas duplicadas entre ambos.

### Secrets: `sops + age`

Los secretos (Wi-Fi passwords, claves WireGuard, SSH host keys) se almacenan encryptados en `environments/<env>/secrets.enc.yaml`. La clave privada age (`~/.age/poc-openwrt-privkey.txt`) **nunca** se commitea.

Múltiples `.gitignore` aseguran que los secrets sin encryptar y archivos temporales no lleguen al repo.

### Scripts modulares

Los scripts están organizados en `scripts/` por responsabilidad:

| Directorio | Responsabilidad |
|-----------|-----------------|
| `commons/` | Utilidades compartidas: logging, utils, parsers TOML |
| `deps/` | Verificación de dependencias del sistema |
| `git/` | Hooks de git y verificaciones pre-commit |
| `install/` | Instalación, validación de herramientas, gestión de secrets |
| `build/` | Compilación de OpenWRT |
| `templates/` | Generación de configuraciones desde templates + secrets |

**Regla arquitectónica:** Just llama a scripts; Make llama a scripts; **Scripts NUNCA llaman a Just ni a Make**. No hay tareas duplicadas entre `justfile` y `Makefile`.

Ver [docs/SCRIPTS.md](docs/SCRIPTS.md).

## Estructura de archivos

```
repo/
├── justfile                       # Task manager (14 recipes)
├── Makefile                       # Build tasks
├── Makefile.just                  # Wrappers de make
├── .sops.yaml                     # Config sops
├── .age-pubkey.txt                # Clave pública (committeada)
├── .envrc.example                 # Ejemplo de variables
├── build-openwrt.sh               # Wrapper → scripts/build/openwrt.sh
├── config/
│   ├── openwrt-packages.toml      # Fuente de verdad de paquetes
│   ├── openwrt-packages.txt       # Generado desde TOML, no versionado
│   └── openwrt-post-install-packages.toml
├── environments/{dev,prod}/       # Secrets por entorno
├── scripts/
│   ├── commons/{logging,utils,toml-parser}.sh       # Utilidades compartidas
│   ├── deps/check-tools.sh                          # Verificación de dependencias
│   ├── git/{check-secrets-encrypted,setup-hooks}.sh # Hooks pre-commit
│   ├── install/{setup-env,validate-tools,           # Setup + validación
│   │           ensure-secrets,generate-password-hash}.sh
│   ├── build/{openwrt,compile,verify}.sh             # Compilación
│   └── templates/generate.sh                        # Generación de configs
├── templates/etc/                 # Templates de config
├── docs/                          # Documentación
└── .gitignore                     # NUNCA subir secrets/basura
```

## Documentación

- [Uso de Just](docs/JUST.md) — Todas las recipes
- [Referencia de Scripts](docs/SCRIPTS.md) — Scripts modulares
- [Compilación](docs/BUILD_INSTRUCTIONS.md) — Guía de compilación
- [Flasheo](docs/FLASH_INSTRUCTIONS.md) — Instalación en router
- [Secrets](docs/SECRETS.md) — Gestión con sops+age
