# router-agent (Rust)

A narrow HTTP-to-SSH bridge: an external captive-portal backend calls this
service's HTTP API to tell an OpenWRT router "authorize this client IP" /
"revoke it", without ever holding SSH credentials to the router itself. The
service holds a restricted SSH private key (mounted at runtime, never baked
into the image) and forwards validated commands to the forced-command
dispatcher already installed on the router
(`router-agent/shared/router-dispatch/agent-dispatch.sh`).

This is the Rust implementation, built to be interchangeable — from an HTTP
caller's point of view — with the sibling Go implementation at
`router-agent/go/`, for benchmarking. The HTTP contract, JSON shapes, and
error codes match exactly.

## SSH crate decision: `russh`, not a `ssh` shellout

The spec for this service asked for a real attempt at `russh` (pure Rust,
async/tokio-native, no OpenSSL dependency) before falling back to shelling
out to the system `ssh` binary with a `ControlMaster`. That attempt
succeeded — `russh` 0.63 is used directly, no fallback needed. Specifically:

- **Loading an ed25519 private key from a file**: `russh::keys::load_secret_key(path, None)`
  reads and parses an OpenSSH-format private key file directly. Used in
  `ssh_client.rs::SshClient::dial`.
- **Host key verification against a pinned `known_hosts` file**: `russh`
  ships this out of the box —
  `russh::keys::check_known_hosts_path(host, port, &server_public_key, known_hosts_path)`
  parses a standard OpenSSH `known_hosts` file (including hashed hostnames)
  and does the comparison for us. We call it from inside our
  `client::Handler::check_server_key` callback, which is `russh`'s hook for
  this exact purpose. We never accept an unverified host key.
- **Executing a command and reading back stdout/stderr/exit status**:
  `Channel::exec(want_reply, command)` opens the exec request, and
  `Channel::wait()` yields a stream of `ChannelMsg` values —
  `Data { data }` (stdout), `ExtendedData { data, ext: 1 }` (stderr per
  RFC 4254 §5.2), and `ExitStatus { exit_status }` — until the channel
  closes. This is clean and exactly what `dispatch.rs` needs.

No blocking friction was hit on any of the three points the spec asked to
verify, so there was no reason to reach for the shellout fallback.

### Crypto backend: `ring`, not `aws-lc-rs`

`russh`'s *default* features pull in `aws-lc-rs` (which builds `aws-lc-sys`,
a C/assembly library, via `cmake`) plus RSA support we don't need (the
dispatcher's SSH key and the router's host key are both ed25519). This
crate instead builds `russh` with `default-features = false, features =
["ring", "flate2"]`:

- `ring` is a much lighter, well-audited crypto backend that's long proven
  itself building cleanly against musl (it's what `rustls` commonly links
  on Alpine), without needing `cmake`/`clang`/`bindgen` in the build image.
- Dropping the `rsa` feature means the `rsa`/`pkcs1` crates and their
  bignum dependencies aren't compiled at all — smaller build, smaller
  attack surface, and one less place a future maintainer could accidentally
  widen the accepted host/client key algorithms beyond ed25519.

`ring` itself is not pure Rust — it has a C/assembly core — so it does need
a C toolchain (`gcc`) at *build* time inside the Alpine build stage (see
Containerfile). It still produces a fully static, dynamically-linked-nothing
binary suitable for a `FROM scratch` final image, which was the actual goal
(no OpenSSL `.so` dependency at runtime, no shell, no package manager in
the shipped container).

## SSH connection strategy

One persistent SSH connection is dialed at startup (lazily, on first use —
not before the HTTP listener is up, so `/healthz` can answer while the
router is still booting) and kept alive across requests. Each request opens
a fresh `exec` channel over that same connection rather than a new
TCP+SSH handshake. See `src/ssh_client.rs`:

- `SshClient` holds `tokio::sync::Mutex<Option<client::Handle<ClientHandler>>>`.
  Every `exec()` call takes that mutex for its whole duration — connect (if
  needed), channel-open, exec, and read-to-completion — which both
  serializes command execution (matching the dispatcher's one-command-per-
  invocation model) and guarantees no unbounded concurrent channels against
  a small embedded SSH server (dropbear on the router).
- If the connection is absent or `handle.is_closed()`, `ensure_connected`
  redials with a short backoff (0ms, 200ms, 800ms — 3 attempts) before
  giving up and surfacing `router_unreachable`.
- Any transport-level error during `exec` (channel open failure, etc.)
  drops the cached handle so the *next* request redials instead of reusing
  a connection presumed dead; the failing in-flight request itself still
  returns an error rather than blocking to retry.
- The whole `exec` (connect-if-needed + channel + read) is wrapped in
  `tokio::time::timeout(ssh_timeout, ...)`, so `ROUTER_AGENT_SSH_TIMEOUT_MS`
  bounds both connect and per-command exec, per the spec.

## Behavioral parity note: IPv4 validation

The literal spec text for this service named `std::net::Ipv4Addr::from_str`
for IP validation. In practice `Ipv4Addr::from_str` **rejects** octets with
a leading zero (e.g. `192.168.001.010` fails to parse), while
`agent-dispatch.sh`'s own `_validate_ip` (a POSIX shell string/arithmetic
check) **accepts** them — shell arithmetic treats `"010"` as decimal 10,
not octal. The Go sibling was built with this in mind and deliberately
avoids `net.ParseIP` for the same reason (see its `ValidateIPv4` doc
comment in `router-agent/go/internal/api/handlers.go`).

To keep the two HTTP implementations truly interchangeable — the explicit
goal of building both — this Rust implementation does the same thing:
`api::handlers::validate_ipv4` is a hand-rolled check (exactly four
dot-separated all-digit octets, each `0..=255`, leading zeros allowed) that
mirrors the shell dispatcher's grammar bit-for-bit, instead of using
`Ipv4Addr::from_str`. This is the one deliberate deviation from the literal
spec text in this codebase; everything else (JSON shapes, field names,
status codes, error codes) matches exactly.

## Config (environment variables)

| Variable | Required | Default | Notes |
|---|---|---|---|
| `ROUTER_AGENT_LISTEN_ADDR` | no | `0.0.0.0:8443` | |
| `ROUTER_AGENT_API_TOKEN` | yes | — | shared secret, min 8 chars |
| `ROUTER_AGENT_ALLOWED_CIDRS` | yes | — | comma-separated, e.g. `10.20.0.0/24,127.0.0.1/32` |
| `ROUTER_AGENT_SSH_HOST` | yes | — | |
| `ROUTER_AGENT_SSH_PORT` | no | `22` | |
| `ROUTER_AGENT_SSH_USER` | no | `root` | |
| `ROUTER_AGENT_SSH_KEY_PATH` | yes | — | must exist at startup |
| `ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH` | yes | — | must exist at startup |
| `ROUTER_AGENT_SSH_TIMEOUT_MS` | no | `5000` | applies to connect AND per-command exec |
| `ROUTER_AGENT_LOG_LEVEL` | no | `info` | passed to `tracing_subscriber::EnvFilter` |

Config is parsed and validated once at startup (`src/config.rs`); any
problem (missing var, unparseable CIDR/port/timeout, missing key/known_hosts
file) prints a clear error to stderr and exits non-zero before the HTTP
listener ever opens.

## API

Every route except `/healthz` requires the source IP to be in
`ROUTER_AGENT_ALLOWED_CIDRS` (checked against the raw TCP peer address —
this service sits behind no reverse proxy) *and* a valid
`X-Router-Agent-Token` header, compared in constant time. The IP check runs
first: a disallowed source IP gets `403` even with a correct token.

```bash
TOKEN=supersecrettoken
HOST=http://127.0.0.1:8443

# Liveness — no auth, no SSH call.
curl -s $HOST/healthz

# Authorize a client IP for 30 minutes (default).
curl -s -X POST $HOST/v1/allow \
  -H "X-Router-Agent-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"ip":"192.168.1.146"}'

# Authorize permanently (timeout_min: 0).
curl -s -X POST $HOST/v1/allow \
  -H "X-Router-Agent-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"ip":"192.168.1.146","timeout_min":0}'

# Revoke (idempotent — 200 even if the IP wasn't allowed).
curl -s -X POST $HOST/v1/block \
  -H "X-Router-Agent-Token: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"ip":"192.168.1.146"}'

# List currently allowed clients.
curl -s $HOST/v1/list -H "X-Router-Agent-Token: $TOKEN"

# Router/agent health (never 5xxs for router-side conditions).
curl -s $HOST/v1/status -H "X-Router-Agent-Token: $TOKEN"
```

## Code layout

```
src/
├── main.rs           tokio runtime, config → AppState → axum router, graceful shutdown
├── config.rs          env var parsing/validation
├── ssh_client.rs       persistent conn, mutex-serialized exec(), reconnect-with-backoff
├── dispatch.rs         command-string builders + exit-code/stdout/stderr → typed results
├── nft_json.rs          `nft -j list set` parser (unit-tested against literal sample JSON)
└── api/
    ├── mod.rs           router wiring
    ├── handlers.rs       one handler per route + IPv4/timeout validation
    ├── middleware.rs      CIDR allowlist + constant-time token check
    └── types.rs           request/response/error JSON shapes
```

## Verification performed

- `cargo build` / `cargo build --release`: pass (native `aarch64-apple-darwin`).
- `cargo test`: 37 unit tests pass — `nft_json` parser (mixed permanent/
  timed elements, both integer and duration-string `expires`, malformed/
  empty/unrecognized shapes), `dispatch` command builders and response
  interpretation, IPv4/timeout validation, CIDR matching, constant-time
  token comparison.
- `cargo clippy --all-targets`: zero warnings.
- `cargo fmt --check`: clean.
- **musl cross-build**: attempted `cargo build --release --target
  x86_64-unknown-linux-musl` directly on this macOS dev machine; it failed
  because `ring`'s build script needs a musl C cross-toolchain
  (`x86_64-linux-musl-gcc`) that isn't installed here. That's expected and
  fine — the Containerfile deliberately does **not** pin a target triple
  (see below), so this cross-build attempt was never actually necessary.
- **Containerfile build — verified and fixed by the orchestrating session**:
  the original version of this Containerfile hardcoded
  `--target x86_64-unknown-linux-musl`. That broke on an arm64 build host
  (Apple Silicon via a `podman machine` VM): `rust:1-alpine` is multi-arch,
  so on an arm64 host its *native* triple is `aarch64-unknown-linux-musl`,
  and pinning `x86_64` forced an actual cross-compile needing a target/
  toolchain the image doesn't install (`error[E0463]: can't find crate for
  core` for the `x86_64-unknown-linux-musl` target). Fixed by dropping
  `--target` entirely and building/copying from `target/release/` instead —
  `cargo build --release` always uses the image's native host target, which
  is musl either way (x86_64 or aarch64 depending on build host), so the
  binary stays static without needing to know the host arch in advance.
  With that fix, `podman build -f router-agent/rust/Containerfile
  -t router-agent-rust:dev router-agent/rust` succeeds end-to-end on an
  arm64 host, and the resulting `FROM scratch` image runs and fails fast
  on missing config exactly as expected (final image size: ~4.7 MB, vs.
  ~9.3 MB for the sibling Go image on `distroless/static-debian12`).

## Containerfile

`FROM scratch` final stage: no shell, no package manager, nothing but the
statically-linked binary. Build stage installs `musl-dev gcc perl make` on
top of `rust:1-alpine` — `gcc`/`musl-dev` for `ring`'s C core, `perl`/`make`
included defensively since some versions of `ring`'s build script probe for
them (harmless if unused). If a future dependency change moves this crate
back onto `aws-lc-rs` or another crate with a heavier native build, this
stage's package list and possibly the base image will need to grow with it
— that tradeoff was avoided here specifically by picking `ring` over the
default `aws-lc-rs` feature (see above).
