#!/usr/bin/env python3
"""
Tests for unified TOML parser (toml_parser.py).

Run: python3 tests/test_toml_parser.py
"""
import sys
import tempfile
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "commons"))
from toml_parser import parse_toml_structured, format_packages_list

PASS = 0
FAIL = 0


def test(name: str, actual, expected):
    global PASS, FAIL
    if actual == expected:
        PASS += 1
        print(f"  ✓ {name}")
    else:
        FAIL += 1
        print(f"  ✗ {name}")
        print(f"    expected: {expected!r}")
        print(f"    got:      {actual!r}")


TOML_FIXTURE = """[metadata]
profile = "tplink_tl-wdr3600-v1"
target = "ath79/generic"
ram_mb = "64"

[categories.ssh]
"SSH Server" = ["dropbear"]

[categories.network]
"Core Networking" = ["dnsmasq", "firewall4"]

[categories.wifi]
"Wi-Fi Dual-Band" = ["wpad-basic-mbedtls"]

[exclusions.luci]
"LuCI" = ["luci", "luci-base"]
"""


def run_tests():
    global PASS, FAIL
    print("\n=== TOML Parser Tests ===\n")

    with tempfile.NamedTemporaryFile(mode="w", suffix=".toml", delete=False) as f:
        f.write(TOML_FIXTURE)
        f.flush()
        toml_path = f.name

    try:
        data = parse_toml_structured(toml_path)

        test("metadata.profile", data["metadata"].get("profile"), "tplink_tl-wdr3600-v1")
        test("metadata.target", data["metadata"].get("target"), "ath79/generic")
        test("metadata.ram_mb", data["metadata"].get("ram_mb"), "64")

        test("categories count", len(data["categories"]), 3)
        test("categories.Core Networking", data["categories"]["Core Networking"],
             ["dnsmasq", "firewall4"])
        test("categories.SSH Server", data["categories"]["SSH Server"], ["dropbear"])

        test("exclusions count", len(data["exclusions"]), 1)
        test("exclusions.LuCI", data["exclusions"]["LuCI"], ["luci", "luci-base"])

        packages = format_packages_list(data)
        test("includes in output", "dropbear" in packages, True)
        test("exclusions prefixed", "-luci" in packages, True)

        test("no errors", len(data["errors"]), 0)

    finally:
        os.unlink(toml_path)

    print(f"\n{'='*40}")
    print(f"Results: {PASS} passed, {FAIL} failed")
    if PASS + FAIL == 0:
        print("No tests ran!")
        FAIL = 1
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(run_tests())
