# Diagnóstico del Proyecto

_Fecha: 2026-08-01 | Repositorio: PoC-OpenWRT-Raspi3b_

---

## 1. Exploración

### Estructura general

Proyecto para compilar una imagen personalizada de OpenWRT 25.12.5 para el router TP-Link TL-WDR3600 v1 (target `ath79/generic`, 64 MB RAM, 8 MB flash), con administración SSH, sin LuCI, e integración Tor vía Raspberry Pi 3B con DietPi.

```
repo/
├── justfile                       # Task manager (único punto de entrada, ~60 recipes, 1161 líneas)
├── Makefile                       # Solo tareas de build/validación (llamado por just)
├── Makefile.just                  # Wrappers de make incluidos por justfile
├── build-openwrt.sh               # Wrapper → scripts/build/openwrt.sh
├── .sops.yaml / .age-pubkey.txt   # Config cifrado sops + clave pública age
├── .githooks/pre-commit           # Dispatcher de hooks → scripts/git/*.sh
├── config/
│   ├── openwrt-packages.toml      # Fuente de verdad de paquetes (incluidos/excluidos)
│   ├── openwrt-packages.txt       # Generado desde TOML (ignorado por git)
│   └── openwrt-post-install-packages.toml
├── environments/{dev,prod}/       # .env.public (público) + secrets.enc.yaml (cifrado)
├── scripts/
│   ├── commons/    logging.sh, utils.sh, toml-parser.sh + toml_parser.py
│   ├── deps/       check-tools.sh
│   ├── git/        check-secrets-encrypted.sh, setup-hooks.sh
│   ├── install/    setup-env, ensure-secrets, generate-password-hash
│   ├── build/      openwrt, compile, verify, convert-toml-packages, show-packages
│   ├── router/     19 scripts de administración vía SSH
│   └── templates/  generate.sh (templates + secrets → overlay)
├── templates/etc/                 # config/wireless, dropbear host key, wireguard/wg0.conf
├── docs/                          # 6 guías + docs/uses-case/examples (9 casos con Mermaid)
└── TODO.md                        # Tablero de tareas persistente
```

### Lenguajes y tecnologías

- **Bash** — lenguaje dominante (~40 scripts con `set -euo pipefail`)
- **Python 3** — `toml_parser.py` (parseo de TOML sin librerías externas)
- **Make** — `Makefile` para build y validación
- **Just** — task runner/orquestador (`justfile`)
- **YAML / TOML** — configuraciones y secrets
- **Herramientas externas**: OpenWRT Image Builder, `sops`+`age` (cifrado), `yq`, `wget`, `tar --zstd`, `perl`

### Sistema de build / dependencias

Pipeline de compilación:
1. `just setup` → instala herramientas (brew en macOS; `~/.local/bin` en Linux) y genera clave age
2. `just setup-env prod` → descarga y extrae el OpenWRT Image Builder desde `downloads.openwrt.org`
3. `just build-prod` → desencripta secrets → genera overlay → `make build` → verificación

La compilación usa el **Image Builder oficial de OpenWRT** (`make image PROFILE=... PACKAGES=... FILES=overlay`). Regla arquitectónica: **Just llama a Make y scripts; los scripts nunca llaman a Just ni a Make.**

### Puntos de entrada

| Entrada | Rol |
|---|---|
| `justfile` → recipe `default` | Task manager (setup, secrets, build, flasheo, administración router) |
| `Makefile` → `build` | Compila la imagen |
| `scripts/build/openwrt.sh` | Orquestador real del build |
| `build-openwrt.sh` | Wrapper legacy hacia `openwrt.sh` |
| `scripts/router/*.sh` | Puntos de entrada post-flash (operan el router vía SSH/UCI) |
| `.githooks/pre-commit` | Dispatcher de validaciones pre-commit |

### Módulos y componentes clave

- `scripts/commons/` — utilidades compartidas consumidas por build/, install/, git/, router/ vía `source`
- `install/ensure-secrets.sh` — descifra secrets a `/tmp/secrets-<env>.yaml`
- `templates/generate.sh` — sustituye placeholders `{{VARIABLE}}` con secrets y escribe `config/overlay/<env>/`
- `build/openwrt.sh` — orquestador: localiza builder, convierte TOML → .txt, compila, reporta artefactos
- `build/verify.sh` — valida tamaño (límite 8 MB) y presencia de imágenes factory/sysupgrade
- `router/*.sh` — patrón subcomando con flags `--ip/--env`; gestionan UCI, nftables, dnsmasq, WireGuard, Tor/.onion, extroot, captive portal

### Archivos de configuración relevantes

- `.gitignore` — multinivel: bloquea `.key/.pem/.crt/.priv`, artefactos de build, `config/overlay/`, secrets temporales
- `.githooks/pre-commit` — dispatcher con `core.hooksPath = .githooks`
- `.sops.yaml` — regla de cifrado para secrets.enc.yaml con clave age
- `config/openwrt-packages.toml` — fuente de verdad de paquetes con categorías, exclusions, warnings
- `environments/{dev,prod}/.env.public` — versión, target, profile, IPs, SSIDs públicos
- **Sin CI/CD** (sin `.github/`, sin Dockerfile, sin pipelines)

### Estado del repositorio

- **Rama activa**: `main` (tracking `origin/main`, actualizada)
- **Otras ramas locales** (5): `feature/just-packages-display`, `feature/toml-packages-config`, `fix/detect-corrupt-binaries`, `fix/preflight-error-messages`, `claude/ecstatic-ramanujan-4db038`
- **Último commit**: `8386349` — "Document clean reinstall and extroot recovery" (solo docs)
- **Working tree**: limpio, sin archivos sin trackear
- **TODO.md**: sin tareas activas; 3 iniciativas históricas completadas

---

## 2. Revisión de calidad

### Problemas estructurales o de diseño

1. **justfile monolítico (1161 líneas).** Contiene lógica embebida (instalación de herramientas, generación de claves age, creación de entornos) que debería estar en `scripts/` para mantener la separación de responsabilidades que el propio proyecto predica.

2. **Duplicación de verificaciones de herramientas.** Recipes como `install-tools`, `generate-age-key`, `create-environments`, `setup-env`, `decrypt-secrets`, `edit-secrets` y `reinit-secrets` repiten bloques idénticos de comprobación de `sops`, `age`, `yq` (líneas 32-40, 202-215, 233-246, 313-319, 389-401, 442-455, 334-346).

3. **Patrones repetitivos en scripts router/.** ~19 scripts comparten la misma estructura: parseo de args, carga de entorno, función `_ssh` con `StrictHostKeyChecking=accept-new` y bloques heredoc extensos. Falta una biblioteca común o función base.

4. **Fragmentación del flujo de build.** La orquestación está dispersa entre justfile, Makefile y scripts, dificultando seguir el proceso completo sin saltar entre archivos.

### Deuda técnica identificada

- **Descifrado de secrets duplicado**: `decrypt-secrets`, `edit-secrets` y `ensure-secrets.sh` implementan su propio descifrado; debería centralizarse en `commons/`.
- **Uso de `eval` en justfile (línea 145)**: construye comandos dinámicos con `eval`, menos legible y potencialmente inseguro.
- **Dependencia de Perl en `templates/generate.sh`** (líneas 47-51): reemplazo de placeholders con Perl cuando podría usarse `sed` o bash puro.
- **Nombres de variables inconsistentes**: prefijos `_` mezclados con nombres genéricos como `idx`, `s`, `rd` sin contexto en scripts router/.
- **Redundancia en parsing TOML**: `toml-parser.sh`, `show-packages.py` y `convert-toml-packages.sh` — tres mecanismos para el mismo objetivo.

### Prácticas del lenguaje no seguidas

- **SSH sin verificación de host**: `StrictHostKeyChecking=accept-new` en todos los scripts router/ — riesgo MITM.
- **Instalación de binarios sin integridad**: `curl ... | bash` sin verificar firmas PGP o checksums (justfile líneas 79, 86, 94, 103).
- **`shellcheck disable=SC2086`** sin justificación clara en varios scripts, pudiendo ocultar problemas reales de word-splitting.
- **Manejo inseguro de temporales**: secrets descifrados en `/tmp` con permisos predeterminados (644); otros usuarios locales podrían leerlos.

### Riesgos de seguridad

1. **Clave SSH del usuario sin passphrase** asumida para acceso root al router.
2. **Binarios descargados sin verificación** — vulnerabilidad de cadena de suministro (compromiso de GitHub o MITM).
3. **Secrets expuestos en `/tmp`** durante ejecución de scripts.
4. **Acceso root sin restricción** (sin `ForceCommand` en `sshd_config` del router).
5. **Sin rotación automática de claves age** — el proceso de re-encriptado es manual.

### Cobertura de tests y documentación

- **Sin pruebas automatizadas.** Solo `verify.sh` valida tamaño de imagen. No hay tests unitarios ni de integración para scripts.
- **Documentación irregular en router/.** Muchos scripts carecen de docstrings detallados más allá del encabezado breve.
- **Información de uso dispersa** entre encabezados de scripts, archivos en `docs/` y comentarios en justfile.
- **Sin validación de config generada.** No se verifica que los templates resultantes sean sintácticamente válidos para UCI o nftables.

---

## 3. Síntesis ejecutiva

### Resumen del proyecto

Proyecto PoC para compilar una imagen personalizada de **OpenWRT 25.12.5** para el router **TP-Link TL-WDR3600 v1**. La imagen incluye SSH con certificados, nftables, WireGuard, soporte USB, Wi-Fi dual-band y proxy Tor transparente vía Raspberry Pi 3B con DietPi. Sin LuCI — administración exclusivamente por CLI.

| Aspecto | Detalle |
|---------|---------|
| **Lenguajes** | Bash (~40 scripts), Python 3 (parser TOML), Make, Just, YAML/TOML |
| **Build** | Image Builder oficial de OpenWRT (`make image`), paquetes definidos en TOML |
| **Secrets** | sops + age, cifrados en `environments/{dev,prod}/secrets.enc.yaml` |
| **Task manager** | `justfile` → `Makefile` → `scripts/` |
| **CI/CD** | Inexistente |

### Estado de salud

**🟡 Amarillo** — La estructura base es sólida (separación clara entre orquestación, build y scripts, gestión de secrets con sops+age, documentación presente). Sin embargo, el proyecto acumula deuda técnica significativa en seguridad (secrets en `/tmp`, SSH sin verificación de host, binarios sin checksums) y mantenibilidad (justfile monolítico, duplicación de lógica). Para una PoC funcional es aceptable; para producción o colaboración, requiere intervención.

### Top 3 fortalezas

1. **Arquitectura de capas bien definida.** La separación `justfile → Makefile → scripts/` con la regla "just llama a make, make llama a scripts, scripts nunca llaman a just" es un patrón maduro. Scripts organizados por responsabilidad (`commons/`, `deps/`, `build/`, `router/`, `templates/`).

2. **Gestión de secrets con sops+age.** Secrets cifrados en el repo, `.gitignore` multinivel que previene filtraciones, clave pública committeada y clave privada excluida. Patrón `secrets.enc.yaml` por entorno (`dev`/`prod`) correcto.

3. **Documentación operativa completa.** 6 guías (`JUST.md`, `SCRIPTS.md`, `BUILD_INSTRUCTIONS.md`, `FLASH_INSTRUCTIONS.md`, `SECRETS.md`, `CONFIGURACION_BUILD.md`) más `AGENTS.md` con contrato operativo para agentes. Inusual para una PoC, facilita la continuidad.

### Top 3 riesgos o deudas

1. **Riesgos de seguridad críticos.** SSH con `StrictHostKeyChecking=accept-new` (vulnerabilidad MITM), secrets descifrados en `/tmp` con permisos 644, binarios instalados con `curl | bash` sin verificación de checksums, clave SSH sin passphrase para acceso root. No son deuda técnica — son vulnerabilidades activas.

2. **justfile monolítico con lógica embebida.** 1161 líneas con bash inline, verificaciones de herramientas duplicadas en múltiples recipes, uso de `eval` (línea 145). Viola el propio principio arquitectónico del proyecto.

3. **Fragmentación y redundancia en parsing/gestión.** Tres mecanismos para parsear TOML, descifrado de secrets duplicado, patrones repetitivos en `scripts/router/` que deberían ser funciones compartidas en `commons/`.

### Próximos pasos recomendados

1. **Centralizar manejo de secrets** — Crear `scripts/commons/secrets.sh` con funciones `decrypt_secrets()`, `cleanup_secrets()` (trap + permisos 600), eliminar duplicación en router/ e install/. Impacto: seguridad + mantenibilidad.

2. **Eliminar `eval` y hardening del justfile** — Reemplazar `eval` (línea 145) por alternativa segura, mover bash inline a scripts, deduplicar verificaciones de herramientas. Impacto: seguridad + legibilidad.

3. **Hardening SSH y descargas** — Agregar verificación de host keys, validar checksums/firmas de binarios descargados, exigir passphrase en claves SSH. Impacto: seguridad (eliminación de vulnerabilidades MITM).

4. **Consolidar parsing TOML** — Unificar en un solo mecanismo (preferiblemente `toml-parser.sh` o el Python parser). Eliminar `convert-toml-packages.sh`. Impacto: reducción de complejidad.

5. **Agregar CI básico** — GitHub Actions con shellcheck en scripts, validación de templates generados, verificación de que `just build` completa sin errores. Impacto: prevención de regresiones.

---

## 4. Archivos relevantes

| Archivo | Tipo | Relevancia |
|---------|------|------------|
| `justfile` | entry | Task manager principal (~1161 líneas). Monolítico con lógica embebida y `eval` inseguro. Mayor fuente de deuda técnica. |
| `scripts/build/openwrt.sh` | module | Orquestador real del build. Punto central del flujo de compilación. |
| `scripts/build/verify.sh` | module | Única validación automática del proyecto (tamaño de imagen, checksums). |
| `scripts/install/ensure-secrets.sh` | module | Descifrado de secrets (duplicado con justfile). Riesgo: secrets en `/tmp` con permisos inseguros. |
| `scripts/templates/generate.sh` | module | Generación de config desde templates + secrets. Dependencia innecesaria de Perl. |
| `scripts/commons/toml-parser.sh` | module | Parser TOML (usa Python). Redundante con `show-packages.py` y `convert-toml-packages.sh`. |
| `scripts/router/tor.sh` | module | Representativo de ~19 scripts router/ con patrones SSH repetitivos y sin verificación de host. |
| `config/openwrt-packages.toml` | config | Fuente de verdad de paquetes. Bien estructurado, con categorías, exclusions y warnings. |
| `environments/prod/secrets.enc.yaml` | config | Secrets cifrados con sops+age. Patrón correcto pero descifrado en `/tmp` con permisos inseguros. |
| `.githooks/pre-commit` | config | Única verificación automática pre-commit (bloquea secrets en texto plano). Sin CI complementario. |
