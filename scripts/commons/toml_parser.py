#!/usr/bin/env python3
"""
Parse config/openwrt-packages.toml and output space-separated package list.

Sections:
  [categories.*] — include packages (no prefix)
  [exclusions]   — exclude packages (prefixed with "-")

Output format mimics the legacy config/openwrt-packages.txt format:
  dropbear dnsmasq firewall4 ... -luci -luci-base ...
"""
import sys
import re
from pathlib import Path
from typing import Optional


def parse_toml_basic(toml_path: str) -> str:
    """Parse our restricted TOML subset:
      - Comments: # ...
      - Sections: [section] / [parent.child]
      - Arrays:   key = ["val1", "val2"]
      - Strings:  key = "value"
    """
    includes: list[str] = []
    exclusions: list[str] = []

    current_section: Optional[str] = None

    with open(toml_path, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()

            # Skip blank lines and comments
            if not stripped or stripped.startswith("#"):
                continue

            # Section header
            if m := re.match(r'^\[([a-zA-Z0-9_.-]+)\]', stripped):
                current_section = m.group(1)
                continue

            # Key = ["val1", "val2", ...] — multi-line array
            # Keys may be bare or quoted: "SSH Server" or ssh_server
            if m := re.match(r'^"([^"]+)"\s*=\s*\[', stripped) or re.match(r'^([a-zA-Z0-9_.-]+)\s*=\s*\[', stripped):
                key = m.group(1)
                # Collect array values (may span multiple lines)
                values: list[str] = []
                # Handle same-line values
                rest = stripped[stripped.index("[") + 1 :]
                while True:
                    vals, closing = _extract_array_segment(rest)
                    values.extend(vals)
                    if closing:
                        break
                    # Read next line
                    nxt = next(fh, None)
                    if nxt is None:
                        break
                    rest = nxt.strip()
                    if rest.startswith("#"):
                        continue

                # Categorize: exclusions are special
                dq = '"'  # double quote character
                if current_section == "exclusions" or current_section == "exclusion":
                    exclusions.extend(f"-{v.strip(dq)}" for v in values)
                else:
                    includes.extend(v.strip(dq) for v in values)
                continue

    result = includes + exclusions
    return " ".join(result)


def _extract_array_segment(text: str) -> tuple[list[str], bool]:
    """Extract values from an array segment. Returns (values, is_last_segment)."""
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


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: toml_parser.py <toml-file>", file=sys.stderr)
        return 1

    toml_path = sys.argv[1]
    if not Path(toml_path).exists():
        print(f"TOML file not found: {toml_path}", file=sys.stderr)
        return 1

    try:
        packages = parse_toml_basic(toml_path)
        print(packages)
        return 0
    except Exception as e:
        print(f"Error parsing TOML: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
