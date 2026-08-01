#!/usr/bin/env python3
"""
Parse config/openwrt-packages.toml — unified TOML parser + display.

Modes:
  default (no --mode)  → space-separated package list for build
  --mode=display       → structured terminal display with box drawing
  --mode=json          → structured JSON output (for scripting)

Usage:
  python3 toml_parser.py <toml-file>                    # build mode
  python3 toml_parser.py <toml-file> --mode=display      # display
  python3 toml_parser.py <toml-file> --mode=json         # json
"""
import sys
import re
import json
from pathlib import Path
from typing import Optional


# ── ANSI Colors ────────────────────────────────────────────────────────────
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
RESET = "\033[0m"

H = "─"
V = "│"
TL = "╭"; TR = "╮"; BL = "╰"; BR = "╯"; LM = "├"; RM = "┤"
W = 70


def parse_toml_structured(toml_path: str) -> dict:
    """Parse TOML into structured dict. Single pass, single source of truth."""
    result = {"metadata": {}, "categories": {}, "exclusions": {},
              "warnings": {}, "notes": {}, "errors": [], "all_includes": [],
              "all_exclusions": []}
    current_section: Optional[str] = None

    with open(toml_path, "r", encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue

            if m := re.match(r'^\[([a-zA-Z0-9_.-]+)\]', s):
                current_section = m.group(1)
                continue

            if m := re.match(r'^([a-zA-Z0-9_]+)\s*=\s*(\S.*)', s):
                key, val = m.group(1), m.group(2).strip('"').strip("'")
                if current_section == "metadata":
                    result["metadata"][key] = val
                elif current_section == "warnings":
                    result["warnings"][key] = val
                elif current_section == "notes":
                    result["notes"][key] = val
                continue

            if m := re.match(r'^"([^"]+)"\s*=\s*\[', s) or re.match(r'^([a-zA-Z0-9_.-]+)\s*=\s*\[', s):
                key = m.group(1)
                values: list[str] = []
                rest = s[s.index("[") + 1:]
                while True:
                    vals, closing = _extract_array_segment(rest)
                    values.extend(vals)
                    if closing:
                        break
                    nxt = next(fh, None)
                    if nxt is None:
                        break
                    rest = nxt.strip()
                    while rest.startswith("#"):
                        nxt = next(fh, None)
                        if nxt is None:
                            break
                        rest = nxt.strip()

                if current_section and current_section.startswith("exclusion"):
                    result["exclusions"][key] = values
                    result["all_exclusions"].extend(f"-{v}" for v in values)
                else:
                    result["categories"][key] = values
                    result["all_includes"].extend(values)
                continue

    if not result["metadata"]:
        result["errors"].append("Missing [metadata] section")
    if not result["categories"]:
        result["errors"].append("No [categories.*] sections found")
    return result


def _extract_array_segment(text: str) -> tuple[list[str], bool]:
    values: list[str] = []
    closing = False
    for part in text.split(","):
        part = part.strip()
        if part.endswith("]"):
            closing = True
            part = part[:-1].strip()
        if part:
            values.append(part.strip('"').strip("'"))
        if closing:
            break
    return values, closing


def format_packages_list(data: dict) -> str:
    """Build space-separated list (build mode)."""
    result = data["all_includes"] + data["all_exclusions"]
    return " ".join(result)


def format_display(data: dict) -> str:
    """Build structured terminal display."""
    lines = []
    m = data["metadata"]
    profile = m.get("profile", "unknown")
    target = m.get("target", "unknown")
    ram = m.get("ram_mb", "?")

    def box_top(title=""):
        return f"{TL}{title}{H * (W - len(title) - 2)}{TR}" if title else f"{TL}{H * (W - 2)}{TR}"
    def box_line(text=""):
        return f"{V} {text:<{W - 4}} {V}"
    def box_mid(title=""):
        return f"{LM} {BOLD}{title}{RESET} {H * (W - len(title) - 5)}{RM}" if title else f"{LM}{H * (W - 2)}{RM}"
    def box_bot():
        return f"{BL}{H * (W - 2)}{BR}"

    lines.append(box_top(f"{BOLD}OpenWRT Package Configuration{RESET}"))
    lines.append(box_line(f"Profile: {CYAN}{profile}{RESET}  |  Target: {CYAN}{target}{RESET}  |  RAM: {YELLOW}{ram} MB{RESET}"))
    lines.append(box_mid())

    total_inc = 0
    for cat_label, pkgs in data["categories"].items():
        if not pkgs:
            continue
        lines.append(box_line(f"{BOLD}{GREEN}▸ {cat_label}{RESET}  ({len(pkgs)} packages)"))
        for p in sorted(pkgs):
            lines.append(box_line(f"     {p}"))
        total_inc += len(pkgs)

    if data["exclusions"]:
        lines.append(box_mid("EXCLUDED PACKAGES"))
        total_exc = 0
        for cat_label, pkgs in data["exclusions"].items():
            if not pkgs:
                continue
            lines.append(box_line(f"{BOLD}{RED}▸ {cat_label}{RESET}  ({len(pkgs)} packages)"))
            for p in sorted(pkgs):
                lines.append(box_line(f"     {RED}-{p}{RESET}"))
            total_exc += len(pkgs)
    else:
        total_exc = 0

    if data["warnings"] or data["notes"] or data["errors"]:
        lines.append(box_mid("INFO"))
    for key, msg in data["warnings"].items():
        lines.append(box_line(f"{YELLOW}⚠  {key}:{RESET} {msg}"))
    for key, msg in data["notes"].items():
        lines.append(box_line(f"{DIM}ℹ  {key}:{RESET} {DIM}{msg}{RESET}"))
    for err in data["errors"]:
        lines.append(box_line(f"{RED}✗ VALIDATION ERROR: {err}{RESET}"))

    lines.append(box_mid())
    lines.append(box_line(
        f"{BOLD}Total:{RESET} {GREEN}{total_inc} included{RESET} + "
        f"{RED}{total_exc} excluded{RESET} = "
        f"{BOLD}{total_inc + total_exc} packages{RESET}"
    ))
    lines.append(box_bot())
    return "\n".join(lines)


def main() -> int:
    mode = "build"
    toml_path = None
    for arg in sys.argv[1:]:
        if arg.startswith("--mode="):
            mode = arg.split("=", 1)[1]
        elif arg in ("--display",):
            mode = "display"
        elif arg in ("--json",):
            mode = "json"
        elif arg == "--toml":
            pass
        elif arg.startswith("--toml="):
            toml_path = arg.split("=", 1)[1]
        elif not arg.startswith("--"):
            toml_path = arg

    if not toml_path:
        print("Usage: toml_parser.py <toml-file> [--mode=display|json]", file=sys.stderr)
        return 1
    if not Path(toml_path).exists():
        print(f"TOML file not found: {toml_path}", file=sys.stderr)
        return 1

    try:
        data = parse_toml_structured(toml_path)
    except Exception as e:
        print(f"Error parsing TOML: {e}", file=sys.stderr)
        return 1

    if mode == "display":
        print(format_display(data))
    elif mode == "json":
        out = {k: v for k, v in data.items() if k not in ("all_includes", "all_excludes")}
        out["total_includes"] = len(data["all_includes"])
        out["total_exclusions"] = len(data["all_exclusions"])
        print(json.dumps(out, indent=2, default=str))
    else:
        print(format_packages_list(data))

    return 1 if data["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
