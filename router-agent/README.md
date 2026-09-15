# router-agent

Puente HTTP-a-SSH angosto: expone `allow`/`block`/`list`/`status` sobre el set
nftables `allowed_clients` del [portal cautivo](../scripts/router/setup-captive.sh)
a un backend externo (p. ej. un portal cautivo con lógica de negocio propia,
corriendo en otra máquina), **sin darle nunca la llave SSH admin del router**.

## Por qué existe

Un backend externo necesita poder decir "esta IP ya tiene acceso" según sus
propias reglas de negocio. Dos maneras de resolverlo — dar a ese backend la
llave SSH root que ya usan los scripts `just router-*`, o construir un
servicio intermedio que la guarde y exponga solo esa acción — no son en
realidad alternativas: la segunda es la única sensata. `router-agent` es ese
servicio, empaquetado como contenedor Podman para que la llave nunca toque el
proceso del backend externo.

## Arquitectura

```
backend externo (portal cautivo) --HTTP+token--> router-agent (contenedor)
                                                        |
                                                   SSH restringido
                                                  (forced-command)
                                                        v
                                              OpenWRT: agent-dispatch.sh
                                                        |
                                              nft add/delete element
                                              "ip captive" allowed_clients
```

- **Llave SSH restringida**: aprovisionada por [`scripts/router/setup-captive-agent.sh`](../scripts/router/setup-captive-agent.sh) (`just router-agent-provision`). Independiente de la llave admin de `setup-auth.sh`. Forzada por Dropbear (`command=` en `authorized_keys`) a solo poder ejecutar el dispatcher.
- **Dispatcher en el router**: [`shared/router-dispatch/agent-dispatch.sh`](shared/router-dispatch/agent-dispatch.sh) — gramática cerrada (`allow`/`block`/`list`/`status`), nunca `eval`, replica exactamente las primitivas `nft` que ya usa `setup-captive.sh`.
- **Contrato HTTP**: [`shared/openapi.yaml`](shared/openapi.yaml) — única fuente de verdad; las implementaciones Go y Rust deben cumplirlo de forma idéntica.
- **Dos implementaciones hermanas**: [`go/`](go/) y [`rust/`](rust/), benchmarcadas con [`bench/`](bench/) para decidir cuál se queda.

## Uso rápido

```bash
just router-captive-setup portal-url=https://portal.example.com   # prerrequisito
just router-agent-provision                                        # llave restringida
just router-agent-build-go                                         # o router-agent-build-rust
just router-agent-run-go                                           # levanta el contenedor
```

Ver el flujo completo en [docs/uses-case/examples/captive-agent-http-api.md](../docs/uses-case/examples/captive-agent-http-api.md).

## Nota operacional: permisos de la llave montada

Ambas imágenes corren como usuario no-root dentro del contenedor (UID/GID
`65532` — Go vía `distroless/static-debian12:nonroot`, Rust vía `USER
65532:65532` explícito en `FROM scratch`, mismo UID en ambas para paridad de
seguridad). La llave SSH privada que montás en `/secrets/captive-agent-key`
debe ser **legible por ese UID**, no solo por el dueño del archivo en el
host — `chmod 600` (solo dueño) falla dentro del contenedor con "permission
denied". Las recetas `just router-agent-run-go`/`-rust` y el harness de
benchmark ya aplican `chmod 644` al extraer la llave; si montás una llave
por otro medio, replicá ese permiso (o `chown` al UID 65532 si preferís no
ampliar legibilidad).

## Seguridad

| Si se filtra... | El atacante puede | El atacante NO puede |
|---|---|---|
| Llave SSH restringida | `allow`/`block`/`list`/`status` sobre `allowed_clients`, indefinidamente | Shell, leer archivos, cambiar WiFi/WAN/firewall fuera de ese set, reflashear — Dropbear fuerza el `command=` pase lo que pase |
| Token API | Lo mismo, pero gateado por el allowlist de IP del backend externo | Igual que arriba |
| Contenedor completo (RCE) | Acceso a la llave montada + canal SSH vivo (= llave filtrada) | La llave **admin** — nunca se monta en este contenedor, vive solo en `secrets.enc.yaml` / máquinas de operadores |

Riesgo residual (no eliminado, solo acotado): el token es un secreto estático
sin rotación automática (`just router-agent-rotate-key` es manual); una
llave/token filtrado sigue permitiendo autorizar o bloquear IPs arbitrarias —
es inherente a la funcionalidad pedida.

## Benchmark Go vs Rust

Ambas implementaciones usan la misma estrategia de conexión SSH (persistente,
canales `exec` multiplexados, sin reconectar por request) para que la
comparación mida HTTP+concurrencia y no "quién hace handshake SSH más
rápido". Ver [`bench/`](bench/) y `just router-agent-bench`. La decisión de
cuál implementación se conserva es manual, revisando `bench/results/REPORT.md`.
