#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${ROOT}/router-agent/build"
OUTPUT="${OUT_DIR}/router-agent-mipsle"
mkdir -p "$OUT_DIR"

# Prefer the selected Rust implementation when its target and OpenWrt linker
# are available; use the existing pure-Go implementation if cross linking is
# not configured on this host.
RUST_TARGET="mipsel-unknown-linux-musl"
RUST_LINKER="${CARGO_TARGET_MIPSEL_UNKNOWN_LINUX_MUSL_LINKER:-mipsel-openwrt-linux-musl-gcc}"
if command -v cargo >/dev/null 2>&1 && command -v "$RUST_LINKER" >/dev/null 2>&1 \
   && rustup target list --installed 2>/dev/null | grep -qx "$RUST_TARGET"; then
    echo "Compilando router-agent Rust para $RUST_TARGET..."
    if (cd "$ROOT/router-agent/rust" && \
        CARGO_TARGET_MIPSEL_UNKNOWN_LINUX_MUSL_LINKER="$RUST_LINKER" \
        cargo build --release --target "$RUST_TARGET"); then
        cp "$ROOT/router-agent/rust/target/$RUST_TARGET/release/router-agent" "$OUTPUT"
        chmod 755 "$OUTPUT"
        echo "Agente Rust listo: $OUTPUT"
        exit 0
    fi
    echo "Rust no pudo compilar para este target; usando el fallback Go." >&2
else
    echo "Target/linker Rust MIPS no disponible; usando el fallback Go." >&2
fi

command -v go >/dev/null 2>&1 || { echo "ERROR: instala Go para compilar el fallback MIPS." >&2; exit 1; }
(cd "$ROOT/router-agent/go" && \
    GOOS=linux GOARCH=mipsle GOMIPS=softfloat CGO_ENABLED=0 \
    go build -trimpath -ldflags='-s -w' -o "$OUTPUT" ./cmd/router-agent)
chmod 755 "$OUTPUT"
echo "Agente Go MIPS soft-float listo: $OUTPUT"
