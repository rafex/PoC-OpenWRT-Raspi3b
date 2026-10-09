# Makefile — Solo tareas de compilación y validación
# Las tareas de orquestación están en justfile.
# No duplicar tareas entre make y just.

.PHONY: build extroot-stage validate clean shellcheck

BUILDER_DIR ?= $(shell find openwrt-builder -mindepth 1 -maxdepth 1 -type d -name 'openwrt-imagebuilder-*.Linux-x86_64' 2>/dev/null | sort -V | tail -1)
EXTROOT_PROFILE ?= tplink_tl-wdr3600-v1
EXTROOT_OVERLAY_DIR ?= $(CURDIR)/config/overlay/prod/extroot
EXTROOT_ROOT_DIR ?= openwrt-builder/extroot-stage-root
EXTROOT_PACKAGES ?=

## build: Compilar imagen OpenWRT para TP-Link TL-WDR3600
build:
	@echo "=== Compilando imagen OpenWRT ==="
	./build-openwrt.sh

## extroot-stage: Resolver paquetes y preparar el árbol extroot con Image Builder
extroot-stage:
	@test -n "$(BUILDER_DIR)" || { echo "Image Builder no encontrado; ejecuta just setup-env prod" >&2; exit 1; }
	@test -n "$(EXTROOT_PACKAGES)" || { echo "EXTROOT_PACKAGES es obligatorio" >&2; exit 1; }
	@test -d "$(EXTROOT_OVERLAY_DIR)" || { echo "Overlay extroot no encontrado: $(EXTROOT_OVERLAY_DIR)" >&2; exit 1; }
	@test -n "$(EXTROOT_UUID)" && grep -Fq "option uuid '$(EXTROOT_UUID)'" "$(EXTROOT_OVERLAY_DIR)/etc/config/fstab" || { echo "El fstab generado no coincide con EXTROOT_UUID" >&2; exit 1; }
	@rm -rf "$(EXTROOT_ROOT_DIR)" "$(BUILDER_DIR)/build_dir/target-mips_24kc_musl/root-ath79" "$(BUILDER_DIR)/build_dir/target-mips_24kc_musl/root.orig-ath79"
	@mkdir -p "$(EXTROOT_ROOT_DIR)/upper" "$(EXTROOT_ROOT_DIR)/work" "$(BUILDER_DIR)/build_dir/target-mips_24kc_musl/root-ath79"
	$(MAKE) -C "$(BUILDER_DIR)" package_reload package_install prepare_rootfs PROFILE="$(EXTROOT_PROFILE)" USER_PROFILE="DEVICE_$(EXTROOT_PROFILE)" USER_PACKAGES="$(EXTROOT_PACKAGES)" USER_FILES="$(EXTROOT_OVERLAY_DIR)"
	@cp -a "$(BUILDER_DIR)/build_dir/target-mips_24kc_musl/root-ath79/." "$(EXTROOT_ROOT_DIR)/upper/"
	@echo "Extroot package root staged at $(EXTROOT_ROOT_DIR)"

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
