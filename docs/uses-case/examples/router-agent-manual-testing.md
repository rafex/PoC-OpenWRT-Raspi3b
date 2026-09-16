# Probar router-agent manualmente por REST (antes de construir el backend)

## Objetivo

Levantar `router-agent` (Go y Rust en paralelo) en una máquina con acceso directo a la LAN del router, y probar los endpoints por `curl` — sin necesidad de tener todavía el backend del portal cautivo real. Útil para validar que el aprovisionamiento SSH, el token, y las mutaciones de nftables funcionan de punta a punta antes de integrar nada.

Validado en vivo: Go en `:8443`, Rust en `:8444`, ambos contra el mismo router real, mismas mutaciones visibles desde ambos (`allow` por uno, `list` por el otro).

> Si preferís un cliente gráfico (Postman/Insomnia/Bruno) en vez de `curl`, importá [`router-agent/openapi/openapi.yaml`](../../../router-agent/openapi/openapi.yaml) — genera las 5 requests solo, con los ejemplos de este documento ya cargados. Ver [`router-agent/openapi/README.md`](../../../router-agent/openapi/README.md).

## Prerrequisitos

1. La máquina donde corre `router-agent` necesita **acceso directo a la LAN del router** (no basta con acceso a internet) — no funciona detrás de un bridge SSH como se usó en otras partes de este proyecto.
2. Portal cautivo instalado: `just router-captive-setup <IP-router>`.
3. Llave SSH restringida + token de API aprovisionados: `just router-agent-provision <IP-router>` (genera y guarda `CAPTIVE_AGENT_SSH_PRIVATE_KEY` y `CAPTIVE_AGENT_API_TOKEN` en secrets).
4. Herramientas: `podman`, `just`, `sops`, `age`, **`yq` de [mikefarah/yq](https://github.com/mikefarah/yq)** (Go) — no el `python-yq` que trae `apt install yq` en Debian/Ubuntu por defecto; tienen sintaxis CLI incompatible. Si `just install-tools` detecta un `yq` de sistema ya instalado (aunque sea el equivocado), no lo reemplaza — verificá con `yq --version` que diga `mikefarah/yq`, y si no, bajalo a mano:
   ```bash
   curl -sSL "https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_amd64" -o ~/.local/bin/yq
   chmod +x ~/.local/bin/yq
   ```

## Levantar ambos agentes

```bash
just router-agent-build-go
just router-agent-build-rust
just router-agent-run-go                                          # puerto 8443
just router-agent-run-rust                                        # puerto 8444
```

Por defecto el allowlist de IPs permitidas es `192.168.3.0/24,127.0.0.1/32` — ajustalo a tu red pasando los argumentos **por posición** (`env port cidrs tag`, sin `nombre=`, ver [docs/JUST.md](../../JUST.md)):
```bash
just router-agent-run-go prod 8443 "10.0.0.0/24,127.0.0.1/32"
```

Verificar que arrancaron:
```bash
podman ps
curl -4 http://127.0.0.1:8443/healthz   # {"status":"ok"}
curl -4 http://127.0.0.1:8444/healthz
```

> ⚠️ Usá `127.0.0.1` o la IP explícita, no `localhost` — en hosts con IPv6 habilitado, `localhost` puede resolver primero a `::1`, y Podman solo publica los puertos en IPv4 por defecto. Con `curl -4` te asegurás de ir por IPv4 sin depender del orden de resolución.

## Obtener el token para las pruebas

```bash
export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"
TOKEN=$(sops -d environments/prod/secrets.enc.yaml | yq -r '.CAPTIVE_AGENT_API_TOKEN')
```

## Probar los endpoints

Reemplazá `<HOST>` por `127.0.0.1` (si corrés `curl` en la misma máquina) o la IP de esa máquina en tu LAN (si probás desde otra, como en el flujo validado: agente en la thinkpad, `curl` desde otra máquina en `192.168.3.0/24`).

```bash
# Salud (sin auth)
curl -4 http://<HOST>:8443/healthz

# Autorizar una IP (Go)
curl -4 -X POST http://<HOST>:8443/v1/allow \
  -H "X-Router-Agent-Token: ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"ip":"192.168.1.146","timeout_min":30}'
# {"ip":"192.168.1.146","status":"allowed","timeout_min":30}

# Lo mismo contra Rust (puerto 8444) — misma respuesta, mismo efecto
curl -4 -X POST http://<HOST>:8444/v1/allow \
  -H "X-Router-Agent-Token: ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"ip":"192.168.1.147","timeout_min":30}'

# Listar clientes autorizados
curl -4 -H "X-Router-Agent-Token: ${TOKEN}" http://<HOST>:8443/v1/list

# Estado del router (nunca 5xx por condiciones del lado del router)
curl -4 -H "X-Router-Agent-Token: ${TOKEN}" http://<HOST>:8443/v1/status
# {"router_reachable":true,"nft_table_present":true,"ssh_latency_ms":426}

# Revocar (idempotente — 200 aunque la IP no estuviera autorizada)
curl -4 -X POST http://<HOST>:8443/v1/block \
  -H "X-Router-Agent-Token: ${TOKEN}" -H "Content-Type: application/json" \
  -d '{"ip":"192.168.1.146"}'
```

## Verificar el efecto real (camino admin, independiente del agente)

```bash
just router-captive-list <IP-router>
```

Debe mostrar la misma IP con el mismo timeout que reportó el agente — confirma que `allow`/`block` por HTTP mutan exactamente el mismo set nftables que ya usan las recetas `just router-captive-allow`/`router-captive-block`.

## Casos de error esperados

```bash
# Sin token o token incorrecto → 401
curl -4 -X POST http://<HOST>:8443/v1/allow -H "X-Router-Agent-Token: token-malo" \
  -H "Content-Type: application/json" -d '{"ip":"192.168.1.146"}'
# {"error":"unauthorized","message":"missing or invalid X-Router-Agent-Token"}

# IP fuera del allowlist configurado → 403 (probar desde una IP fuera del CIDR de --cidrs)

# IP inválida → 400
curl -4 -X POST http://<HOST>:8443/v1/allow -H "X-Router-Agent-Token: ${TOKEN}" \
  -H "Content-Type: application/json" -d '{"ip":"no-es-una-ip"}'
```

## Parar los agentes

```bash
just router-agent-stop-go
just router-agent-stop-rust
```

## Troubleshooting

**`{"error":"router_unreachable","message":"...knownhosts: key mismatch"}`** — el archivo `environments/<env>/.router-known-hosts` no tiene el tipo de clave que Dropbear está negociando con el cliente Go/Rust (a diferencia del cliente `ssh` de OpenSSH, que puede preferir otro tipo). Si el router tiene tanto host key RSA como ed25519 (`DROPBEAR_RSA_HOST_KEY` en secrets — ver [docs/SECRETS.md](../../SECRETS.md)), asegurate de tener **ambas** en el archivo, no solo una:
```bash
ssh-keyscan -p 22 <IP-router> 2>/dev/null | grep '^<IP-router>' > environments/<env>/.router-known-hosts
```
Después reiniciá los contenedores (`just router-agent-stop-go && just router-agent-run-go`) — el `HostKeyCallback` se arma una sola vez al arrancar, no relee el archivo en caliente.

**El contenedor no arranca / "CAPTIVE_AGENT_API_TOKEN vacío"** — corré `just router-agent-provision <IP-router>` primero; genera y guarda tanto la llave SSH como el token.

**`yq: error: argument files: can't open ...`** — tenés el `yq` equivocado en el PATH (ver Prerrequisitos arriba).

**No se puede alcanzar el puerto desde otra máquina, pero sí desde localhost** — revisá el firewall del host donde corre el agente (`ufw`/`iptables`), no el del router; Podman publica el puerto en todas las interfaces por defecto, pero un firewall del sistema operativo puede seguir bloqueándolo.
