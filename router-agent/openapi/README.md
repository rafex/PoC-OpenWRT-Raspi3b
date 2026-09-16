# OpenAPI — router-agent

[`openapi.yaml`](openapi.yaml): spec OpenAPI 3.0 completo de la API HTTP de `router-agent` — los 5 endpoints, con ejemplos de request/response reales (incluye los casos de error 400/401/403/502/504). Go y Rust cumplen este contrato de forma idéntica; los 4 `servers` del spec apuntan a ambas instancias (local y las validadas en vivo en la thinkpad).

## Importar y generar los requests

**Postman**
1. `Import` → `File` → seleccionar `openapi.yaml`.
2. Postman genera automáticamente una colección con los 5 endpoints y los ejemplos como body por defecto.
3. En la colección, definí una variable `token` y seteala en el header `X-Router-Agent-Token` (o edita cada request), con el valor de:
   ```bash
   export SOPS_AGE_KEY_FILE="$HOME/.age/poc-openwrt-privkey.txt"
   sops -d environments/prod/secrets.enc.yaml | yq -r '.CAPTIVE_AGENT_API_TOKEN'
   ```

**Insomnia**
1. `Create` → `Import From` → `File` → `openapi.yaml`.
2. Insomnia arma un workspace con una carpeta por tag (`control`, `observabilidad`, `liveness`).
3. Mismo paso de token que arriba, como variable de entorno del workspace.

**Bruno**
1. `Import Collection` → `OpenAPI Spec` → `openapi.yaml`.

## Elegir servidor

El spec lista 4 servers (Go/Rust × local/thinkpad) — en el cliente que uses, seleccioná el que corresponda antes de mandar el request. Ver [docs/uses-case/examples/router-agent-manual-testing.md](../../docs/uses-case/examples/router-agent-manual-testing.md) para el flujo completo por `curl` si preferís no usar un cliente gráfico.
