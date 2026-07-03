# Makefile — Solo tareas de compilación y validación
# Las tareas de orquestación están en justfile.
# No duplicar tareas entre make y just.

.PHONY: build validate clean shellcheck

## build: Compilar imagen OpenWRT para TP-Link TL-WDR3600
build:
	@echo "=== Compilando imagen OpenWRT ==="
	./build-openwrt.sh

## validate: Validar scripts con shellcheck
validate: shellcheck
	@echo "=== Validación OK ==="

## shellcheck: Ejecutar shellcheck en todos los scripts
shellcheck:
	@echo "=== shellcheck ==="
	shellcheck -x --severity=error scripts/**/*.sh build-openwrt.sh

## clean: Limpiar artefactos de compilación
clean:
	@echo "=== Limpiando artefactos ==="
	rm -rf openwrt-builder/ *.img *.bin downloads/ staging_dir/ build_dir/ tmp/ logs/

## clean-overlay: Limpiar overlay de configuración generado
clean-overlay:
	rm -rf config/overlay/
