# router-agent (Go)

A narrow HTTP-to-SSH bridge. An external captive-portal backend calls this
service's HTTP API to tell an OpenWRT router "authorize this client IP" /
"revoke it", without ever holding SSH credentials to the router itself. The
service holds a **restricted** SSH private key (mounted into its container
at runtime, never baked into the image) and forwards validated commands to
the forced-command dispatcher installed on the router at
`/etc/captive/agent-dispatch.sh` (see
`router-agent/shared/router-dispatch/agent-dispatch.sh` in this repo for the
exact command grammar and stdout/stderr/exit-code conventions this service
depends on).

A sibling Rust implementation targets the same HTTP contract for a
benchmark comparison; the two must be interchangeable from the caller's
point of view.

## Configuration

All configuration is via environment variables, validated at startup — the
process fails fast with every missing/invalid variable listed in a single
error if anything is wrong.

| Variable                            | Required | Default        | Notes                                                                 |
|--------------------------------------|----------|----------------|------------------------------------------------------------------------|
| `ROUTER_AGENT_LISTEN_ADDR`           | no       | `0.0.0.0:8443` | HTTP listen address                                                   |
| `ROUTER_AGENT_API_TOKEN`             | yes      | —              | Shared secret, compared in constant time via `X-Router-Agent-Token`   |
| `ROUTER_AGENT_ALLOWED_CIDRS`         | yes      | —              | Comma-separated CIDR allowlist for caller source IPs, e.g. `10.20.0.0/24,127.0.0.1/32` |
| `ROUTER_AGENT_SSH_HOST`              | yes      | —              | Router SSH host/IP                                                    |
| `ROUTER_AGENT_SSH_PORT`              | no       | `22`           | Router SSH port                                                       |
| `ROUTER_AGENT_SSH_USER`              | no       | `root`         | SSH user the restricted key authenticates as                          |
| `ROUTER_AGENT_SSH_KEY_PATH`          | yes      | —              | Path to the mounted restricted SSH private key                        |
| `ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH`  | yes      | —              | Path to a mounted `known_hosts` file used for host key verification (no `InsecureIgnoreHostKey`) |
| `ROUTER_AGENT_SSH_TIMEOUT_MS`        | no       | `5000`         | Applies to both SSH connect and each command exec                     |
| `ROUTER_AGENT_LOG_LEVEL`             | no       | `info`         | One of `debug`, `info`, `warn`, `error` (structured JSON on stdout via `log/slog`) |

## SSH connection strategy

One persistent SSH connection is established (lazily, on first use, so
startup doesn't fail just because the router is still booting) and kept
alive across requests; each request opens a new `exec` channel over that
same connection, serialized behind a mutex — this service never opens
unbounded concurrent SSH channels. On any transport-level error the
connection is marked dead and redialed with a few retries and exponential
backoff before a request fails with `router_unreachable`.

## Running

```sh
go build -o router-agent ./cmd/router-agent
ROUTER_AGENT_API_TOKEN=changeme \
ROUTER_AGENT_ALLOWED_CIDRS=10.20.0.0/24,127.0.0.1/32 \
ROUTER_AGENT_SSH_HOST=192.168.1.1 \
ROUTER_AGENT_SSH_KEY_PATH=/secrets/captive-agent-key \
ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH=/secrets/router-known-hosts \
./router-agent
```

Or build the container image (multi-stage, static binary on
`distroless/static-debian12:nonroot` — no shell in the final image):

```sh
podman build -f Containerfile -t router-agent .
podman run --rm -p 8443:8443 \
  -e ROUTER_AGENT_API_TOKEN=changeme \
  -e ROUTER_AGENT_ALLOWED_CIDRS=10.20.0.0/24,127.0.0.1/32 \
  -e ROUTER_AGENT_SSH_HOST=192.168.1.1 \
  -e ROUTER_AGENT_SSH_KEY_PATH=/secrets/captive-agent-key \
  -e ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH=/secrets/router-known-hosts \
  -v /path/to/captive-agent-key:/secrets/captive-agent-key:ro \
  -v /path/to/router-known-hosts:/secrets/router-known-hosts:ro \
  router-agent
```

## API

Every route except `/healthz` requires the `X-Router-Agent-Token` header
and a source IP within `ROUTER_AGENT_ALLOWED_CIDRS`. IP allowlist is
checked first (`403 forbidden_ip`), then the token (`401 unauthorized`).

Non-2xx responses all share the shape:

```json
{"error": "invalid_ip", "message": "human-readable detail"}
```

### `GET /healthz`

No auth, no SSH call — liveness only.

```sh
curl -s http://localhost:8443/healthz
# {"status":"ok"}
```

### `POST /v1/allow`

```sh
curl -s -X POST http://localhost:8443/v1/allow \
  -H "X-Router-Agent-Token: changeme" \
  -H "Content-Type: application/json" \
  -d '{"ip":"192.168.1.146","timeout_min":30}'
# {"ip":"192.168.1.146","status":"allowed","timeout_min":30}
```

`timeout_min` is optional (default `30`; `0` means permanent). Responses:
`200` success, `400 invalid_ip` / `400 invalid_timeout`, `502
router_unreachable` / `502 router_command_failed`, `504 router_timeout`.

### `POST /v1/block`

```sh
curl -s -X POST http://localhost:8443/v1/block \
  -H "X-Router-Agent-Token: changeme" \
  -H "Content-Type: application/json" \
  -d '{"ip":"192.168.1.146"}'
# {"ip":"192.168.1.146","status":"blocked"}
```

Blocking an IP that isn't currently allowed is idempotent success (`200`),
matching the dispatcher's own `OK block ... (not present)` response.

### `GET /v1/list`

```sh
curl -s http://localhost:8443/v1/list \
  -H "X-Router-Agent-Token: changeme"
# {"clients":[{"ip":"192.168.1.146","permanent":false,"expires_in_sec":1740},{"ip":"192.168.1.50","permanent":true,"expires_in_sec":null}]}
```

### `GET /v1/status`

```sh
curl -s http://localhost:8443/v1/status \
  -H "X-Router-Agent-Token: changeme"
# {"router_reachable":true,"nft_table_present":true,"ssh_latency_ms":42}
```

This endpoint never returns 5xx for router-side conditions: if the router
is unreachable, the response is still `200` with `router_reachable:false`
(other fields omitted); if the router answers but the `captive` nft table
is missing, the response is `200` with `nft_table_present:false`. `5xx` is
reserved for the agent's own internal errors.

## Development

```sh
go build ./...
go vet ./...
go test ./...
```

The `internal/nftjson` package's parser (turning `nft -j list set` output
into the `/v1/list` response shape) is the trickiest piece of logic here and
has the most thorough test coverage, using realistic sample payloads rather
than requiring a live router.
