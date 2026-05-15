# Makefile.just — Wrappers de Makefile incluidos por justfile
# Este archivo es llamado desde justfile para tareas de build.
# No usar directamente — usar `just <task>`.

.PHONY: validate clean

validate:
	make validate

clean:
	make clean
