#!/usr/bin/env python3
"""
Display OpenWRT package configuration in a structured, readable terminal format.

Reads config/openwrt-packages.toml and outputs:
  - Header with metadata (profile, target, RAM)
  - Included packages grouped by category
  - Excluded packages grouped by category
  - Warnings and notes
  - Summary footer with counts

Usage:
  just packages          # via justfile
  ./scripts/build/show-packages.py [--toml <file>]
"""
import sys
import re
from pathlib import Path
from typing import Optional


# ── ANSI Colors ────────────────────────────────────────────────────────────
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
MAGENTA = "\033[35m"
WHITE = "\033[37m"
RESET = "\033[0m"

# ── Box drawing ─────────────────────────────────────────────────────────────
H = "─"  # horizontal
V = "│"  # vertical
TL = "╭"  # top-left
TR = "╮"  # top-right
BL = "╰"  # bottom-left
BR = "╯"  # bottom-right
LM = "├"  # left-middle
RM = "┤"  # right-middle
TM = "┬"  # top-middle
BM = "┴"  # bottom-middle
CR = "┼"  # cross

# ── Width ───────────────────────────────────────────────────────────────────
W = 70


def box_top(title: str = "") -> str:
    """Top border with optional title."""
    if title:
        return f"{TL}{title}{H * (W - len(title) - 2)}{TR}"
    return f"{TL}{H * (W - 2)}{TR}"


def box_line(text: str = "") -> str:
    """Single line inside box."""
    return f"{V} {text:<{W - 4}} {V}"


def box_mid(title: str = "") -> str:
    """Middle separator with optional title."""
    if title:
        return f"{LM} {BOLD}{title}{RESET} {H * (W - len(title) - 5)}{RM}"
    return f"{LM}{H * (W - 2)}{RM}"


def box_bot() -> str:
    """Bottom border."""
    return f"{BL}{H * (W - 2)}{BR}"


def parse_toml_structured(toml_path: str) -> dict:
    """Parse TOML into a structured dict for display.

    Returns:
        {
            "metadata": {"profile": "...", "target": "...", "ram_mb": 64},
            "categories": {"SSH Server": ["dropbear"], ...},
            "exclusions": {"LuCI Web Interface": ["luci", ...], ...},
            "warnings": {"tor": "message"},
            "notes": {"extroot": "message"},
            "errors": ["validation error messages"]
        }
    """
    result = {
        "metadata": {},
        "categories": {},
        "exclusions": {},
        "warnings": {},
        "notes": {},
        "errors": [],
    }

    current_section: Optional[str] = None

    with open(toml_path, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue

            # Section: [section]
            if m := re.match(r'^\[([a-zA-Z0-9_.-]+)\]', stripped):
                current_section = m.group(1)
                continue

            # Simple key = value (metadata, warnings, notes)
            if m := re.match(r'^([a-zA-Z0-9_]+)\s*=\s*(\S.*)', stripped):
                key = m.group(1)
                val = m.group(2).strip('"').strip("'")
                if current_section == "metadata":
                    result["metadata"][key] = val
                elif current_section == "warnings":
                    result["warnings"][key] = val
                elif current_section == "notes":
                    result["notes"][key] = val
                continue

            # Quoted key = [array...]
            m_quoted = re.match(r'^"([^"]+)"\s*=\s*\[', stripped)
            m_bare = re.match(r'^([a-zA-Z0-9_.-]+)\s*=\s*\[', stripped)
            if m_quoted or m_bare:
                label = m_quoted.group(1) if m_quoted else m_bare.group(1)  # type: ignore[union-attr]
                values = []
                rest = stripped[stripped.index("[") + 1:]
                while True:
                    vals, closing = _extract_array_segment(rest)
                    values.extend(vals)
                    if closing:
                        break
                    nxt = next(fh, None)
                    if nxt is None:
                        break
                    rest = nxt.strip()
                    if rest.startswith("#"):
                        continue

                if current_section == "exclusions" or current_section == "exclusion":
                    result["exclusions"][label] = values
                else:
                    result["categories"][label] = values

    # ── Validate ──────────────────────────────────────────────────────────
    if not result["metadata"]:
        result["errors"].append("Missing [metadata] section")
    if not result["categories"]:
        result["errors"].append("No [categories.*] sections found")

    return result


def _extract_array_segment(text: str) -> tuple[list[str], bool]:
    """Extract values from array segment. Returns (values, is_last_segment)."""
    values = []
    closing = False
    for part in text.split(","):
        part = part.strip()
        if part.endswith("]"):
            closing = True
            part = part[:-1].strip()
        part = part.strip('"').strip("'")
        if part:
            values.append(part)
        if closing:
            break
    return values, closing


def format_package_list(pkgs: list[str], columns: int = 4, prefix: str = "") -> str:
    """Format packages in columns."""
    if not pkgs:
        return f"{DIM}(empty){RESET}"
    lines = []
    row = []
    for p in pkgs:
        row.append(f"{prefix}{p}")
        if len(row) >= columns:
            lines.append("  ".join(f"{x:<20}" for x in row))
            row = []
    if row:
        lines.append("  ".join(f"{x:<20}" for x in row))
    return "\n".join(f"     {l}" for l in lines)


def display(result: dict) -> str:
    """Build the structured display output."""
    lines = []
    meta = result["metadata"]

    profile = meta.get("profile", "unknown")
    target = meta.get("target", "unknown")
    ram = meta.get("ram_mb", "?")

    # ── Header ───────────────────────────────────────────────────────────
    lines.append(box_top())
    lines.append(box_line(f"{BOLD}OpenWRT 25.12.2 — Package Configuration{RESET}"))
    lines.append(box_line(f"Profile: {CYAN}{profile}{RESET}  |  Target: {CYAN}{target}{RESET}  |  RAM: {YELLOW}{ram} MB{RESET}"))
    lines.append(box_mid())

    # ── Included packages by category ────────────────────────────────────
    total_inc = 0
    for cat_label, pkgs in result["categories"].items():
        if not pkgs:
            continue
        lines.append(box_line(f"{BOLD}{GREEN}▸ {cat_label}{RESET}  ({len(pkgs)} packages)"))
        for p in sorted(pkgs):
            lines.append(box_line(f"     {p}"))
        total_inc += len(pkgs)

    # ── Exclusions ───────────────────────────────────────────────────────
    if result["exclusions"]:
        lines.append(box_mid("EXCLUDED PACKAGES"))
        total_exc = 0
        for cat_label, pkgs in result["exclusions"].items():
            if not pkgs:
                continue
            lines.append(box_line(f"{BOLD}{RED}▸ {cat_label}{RESET}  ({len(pkgs)} packages)"))
            for p in sorted(pkgs):
                lines.append(box_line(f"     {RED}-{p}{RESET}"))
            total_exc += len(pkgs)
    else:
        total_exc = 0

    # ── Warnings & Notes ─────────────────────────────────────────────────
    if result["warnings"] or result["notes"] or result["errors"]:
        lines.append(box_mid("INFO"))

    for key, msg in result["warnings"].items():
        lines.append(box_line(f"{YELLOW}⚠  {key}:{RESET} {msg}"))

    for key, msg in result["notes"].items():
        lines.append(box_line(f"{DIM}ℹ  {key}:{RESET} {DIM}{msg}{RESET}"))

    for err in result["errors"]:
        lines.append(box_line(f"{RED}✗ VALIDATION ERROR: {err}{RESET}"))

    # ── Footer ───────────────────────────────────────────────────────────
    lines.append(box_mid())
    lines.append(box_line(
        f"{BOLD}Total:{RESET} {GREEN}{total_inc} included{RESET} + "
        f"{RED}{total_exc} excluded{RESET} = "
        f"{BOLD}{total_inc + total_exc} packages{RESET}"
    ))
    lines.append(box_bot())

    return "\n".join(lines)


def main() -> int:
    toml_path = "config/openwrt-packages.toml"

    for arg in sys.argv[1:]:
        if arg.startswith("--toml="):
            toml_path = arg.split("=", 1)[1]
        elif arg == "--toml" and len(sys.argv) > sys.argv.index(arg) + 1:
            idx = sys.argv.index(arg)
            toml_path = sys.argv[idx + 1]

    if not Path(toml_path).exists():
        print(f"{RED}✗ TOML file not found: {toml_path}{RESET}", file=sys.stderr)
        return 1

    try:
        result = parse_toml_structured(toml_path)
    except Exception as e:
        print(f"{RED}✗ Error parsing TOML: {e}{RESET}", file=sys.stderr)
        return 1

    print(display(result))

    if result["errors"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
