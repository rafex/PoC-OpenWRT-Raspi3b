# PoC OpenWRT y Raspberry Pi 3B

El objetivo de esta prueba de concepto es demostrar la viabilidad de utilizar OpenWRT en un Raspberry Pi 3B para crear un router personalizado.

Con los mini no breaks, se busca garantizar una fuente de alimentación estable para el Raspberry Pi, evitando interrupciones durante la configuración y uso del dispositivo como router.

## Hardware

- TP-Link (N600 Wireless Dual Band Gigabit Router) TL-WDR3600 v1.0
- Raspberry Pi 3B
- 2 Mini No Break de 8000 mAh

## Software

- OpenWRT 25.12.2
- DietPi RPi234 Trixie (ARMv8)

## Objetivo

Compilar una versión personalizada de OpenWRT para el TP-Link TL-WDR3600 con:

- ✅ SSH con certificados
- ✅ TLS/HTTPS
- ✅ Firewall (nftables)
- ✅ USB Storage
- ✅ VPN WireGuard
- ✅ Wi-Fi Dual-Band (2.4/5 GHz)
- ✅ Cliente Tor
- ❌ LuCi, uhttpd, rpcd (excluidos)

## Arquitectura del proyecto

### Task manager: `just`

`justfile` es el **único punto de entrada**. Orquesta todas las tareas: setup, secretos, build, validación, flasheo.

```bash
just --list      # Ver todas las tareas
just setup       # Setup inicial
just build-prod  # Compilar con secrets reales
```

### Build: `make`

`Makefile` contiene solo tareas de compilación y validación. No orquesta — es llamado por `just`.

**Regla:** Just puede llamar a Make, pero Make NUNCA llama a Just. No hay tareas duplicadas entre ambos.

### Secrets: `sops + age`

Los secretos (Wi-Fi passwords, claves WireGuard, SSH host keys) se almacenan encryptados en `environments/<env>/secrets.enc.yaml`. La clave privada age (`~/.age/poc-openwrt-privkey.txt`) **nunca** se commitea.

Múltiples `.gitignore` aseguran que los secrets sin encryptar y archivos temporales no lleguen al repo.

## Estructura de archivos

```
repo/
├── justfile                       # Task manager
├── Makefile                       # Build tasks
├── Makefile.just                  # Wrappers de make
├── .sops.yaml                     # Config sops
├── .age-pubkey.txt                # Clave pública (committeada)
├── .envrc.example                 # Ejemplo de variables
├── build-openwrt.sh               # Script principal
├── config/openwrt-packages.txt    # Paquetes
├── environments/{dev,prod}/       # Secrets por entorno
├── scripts/                       # Scripts auxiliares
├── templates/etc/                 # Templates de config
├── docs/                          # Documentación
└── .gitignore                     # NUNCA subir secrets/basura
```
