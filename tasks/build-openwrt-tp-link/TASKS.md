```toml
artifact_type = "task_file"
initiative    = "build-openwrt-tp-link"
spec_id       = "SPEC-0001"
owner         = ""
state         = "todo"
```

# TASKS: Compilación de OpenWRT para TP-Link TL-WDR3600

> _Estado: ✅ Listo_
> _Iniciado: 2026-05-15_
> _Tipo: feature_
> _Repo: PEQUEÑO (10 archivos, 852 líneas)_

## Plan: Compilación personalizada de OpenWRT 25.12.2 para TP-Link TL-WDR3600 v1.0

**Tipo:** feature  
**Complejidad estimada:** media  
**Hardware objetivo:** TP-Link TL-WDR3600 v1.0 (N600 Wireless Dual Band Gigabit Router)

### Contexto

El repositorio actual está vacío (solo contiene LICENSE, .gitignore y AGENTS.md con requisitos del proyecto). Es necesario crear desde cero los scripts y documentación para compilar una imagen OpenWRT 25.12.2 personalizada con las siguientes características:

- **Sí incluir:** SSH con certificados, TLS/HTTPS, firewall, soporte USB (almacenamiento externo), VPN (OpenVPN/WireGuard), Wi-Fi dual-band (2.4/5 GHz), cliente Tor
- **No incluir:** LuCi (interfaz web), uhttpd, rpcd

### Archivos a crear

1. `build-openwrt.sh` — Script principal de compilación
2. `config/openwrt-packages.txt` — Lista de paquetes a incluir/excluir
3. `docs/BUILD_INSTRUCTIONS.md` — Guía completa de compilación
4. `docs/FLASH_INSTRUCTIONS.md` — Guía de instalación en el router
5. `scripts/setup-build-env.sh` — Script de preparación del entorno
6. `scripts/verify-image.sh` — Script de verificación de la imagen compilada
7. `README.md` — Actualizar con información del proyecto

### Archivos a modificar

- `.gitignore` — Añadir reglas para artefactos de compilación (imágenes, descargas, caché)

### Pasos de implementación

1. **Crear script de preparación de entorno** (`scripts/setup-build-env.sh`)
   - Verificar dependencias (build-essential, libncurses-dev, unzip, wget, etc.)
   - Descargar OpenWRT Image Builder 25.12.2 para ath79/generic
   - Extraer y verificar integridad

2. **Definir configuración de paquetes** (`config/openwrt-packages.txt`)
   - Listar paquetes necesarios: dropbear, dnsmasq, firewall4, wpad-basic-mbedtls, uclient-fetch, libustream-mbedtls, ca-bundle, ca-certificates
   - Listar módulos USB: kmod-usb-core, kmod-usb2, kmod-usb-ehci, kmod-usb-storage, kmod-usb-storage-uas, kmod-scsi-core, kmod-scsi-generic, kmod-fs-ext4, block-mount, e2fsprogs
   - Listar paquetes VPN: openvpn-openssl o wireguard-tools
   - Listar paquetes Wi-Fi: kmod-ath9k (2.4GHz), kmod-ath9k-common
   - Listar cliente Tor: tor
   - Listar paquetes a excluir con prefijo `-`: luci*, uhttpd*, rpcd*

3. **Crear script principal de compilación** (`build-openwrt.sh`)
   - Cargar configuración de paquetes
   - Ejecutar `make image PROFILE=tplink_tl-wdr3600-v1 PACKAGES="..."`
   - Manejar errores y logging
   - Generar reporte de compilación

4. **Crear script de verificación** (`scripts/verify-image.sh`)
   - Verificar checksums de la imagen generada
   - Validar que los paquetes requeridos están incluidos
   - Comprobar tamaño de la imagen (debe caber en el flash del router)

5. **Crear documentación de compilación** (`docs/BUILD_INSTRUCTIONS.md`)
   - Requisitos del sistema (Ubuntu/Debian recomendado)
   - Pasos de instalación de dependencias
   - Instrucciones de uso de los scripts
   - Tiempo estimado de compilación (~15-30 minutos)
   - Localización de los artefactos generados

6. **Crear documentación de instalación** (`docs/FLASH_INSTRUCTIONS.md`)
   - Métodos de flasheo (TFTP, sysupgrade)
   - Precauciones y backups
   - Procedimiento de recuperación en caso de fallo
   - Configuración inicial vía SSH

7. **Actualizar README.md**
   - Descripción del proyecto
   - Hardware y software objetivo
   - Quick start con enlaces a documentación
   - Estructura del repositorio

8. **Actualizar .gitignore**
   - Añadir `*.img`, `*.bin`, `downloads/`, `build_dir/`, `tmp/`

### Tests a escribir

- **Test de integridad del script**: Verificar que `build-openwrt.sh` ejecuta sin errores de sintaxis
- **Test de configuración**: Validar que todos los paquetes listados existen en los repositorios de OpenWRT 25.12.2
- **Test de verificación**: Comprobar que `scripts/verify-image.sh` detecta correctamente una imagen válida/inválida

### Riesgos

- **Espacio en disco**: El entorno de compilación requiere ~5-10GB de espacio libre
- **Compatibilidad de paquetes**: Algunas combinaciones de paquetes pueden generar conflictos de dependencias
- **Tamaño de imagen**: Incluir demasiados paquetes puede exceder el flash disponible (8MB en TL-WDR3600)
- **Versión de OpenWRT**: La versión 25.12.2 debe ser verificada si existe (la última estable es 23.05)

### Criterio de aceptación

- [ ] Script de compilación ejecuta completamente sin errores
- [ ] Imagen generada tiene tamaño < 8MB (flash disponible)
- [ ] Todos los paquetes requeridos están incluidos (`dropbear`, `firewall4`, `wpad`, `kmod-usb-storage`, etc.)
- [ ] Todos los paquetes prohibidos están excluidos (`luci*`, `uhttpd*`, `rpcd*`)
- [ ] Documentación completa y verificable
- [ ] Scripts tienen permisos de ejecución y shebang correcto

### ToDo

<ToDo>
- [ ] Crear worktree: `git worktree add .opencode/worktrees/build-openwrt-tp-link -b feature/build-openwrt-tp-link`
- [ ] @build — Crear `scripts/setup-build-env.sh` con verificación de dependencias
- [ ] @build — Crear `config/openwrt-packages.txt` con lista completa de paquetes
- [ ] @build — Crear `build-openwrt.sh` script principal de compilación
- [ ] @build — Crear `scripts/verify-image.sh` para validación de artefactos
- [ ] @build — Crear `docs/BUILD_INSTRUCTIONS.md` con guía completa
- [ ] @build — Crear `docs/FLASH_INSTRUCTIONS.md` con procedimiento de instalación
- [ ] @build — Actualizar `README.md` con información del proyecto
- [ ] @build — Actualizar `.gitignore` para excluir artefactos de compilación
- [ ] Validar: Ejecutar `shellcheck` en scripts creados
- [ ] Review con @audit
- [ ] /merge — Integrar worktree a rama base
</ToDo>
