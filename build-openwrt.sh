#!/usr/bin/env bash
# ============================================================================
# build-openwrt.sh — Wrapper for scripts/build/openwrt.sh
# ============================================================================
# This file exists for backwards compatibility. For new usage, prefer:
#   ./scripts/build/openwrt.sh [OPTIONS]
# ============================================================================
exec "$(dirname "$0")/scripts/build/openwrt.sh" "$@"
