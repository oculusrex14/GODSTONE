#!/usr/bin/env python3
"""Extract the Godstone repository from Godstone.xlsx.

The Excel workbook IS the source repository. Each tab is a project folder.
Column A of every tab is walked in tab order (00 -> 12). Rows between a

    >>> FILE: <relative/path/from/repo/root.ext>

marker and its matching

    <<< END FILE

marker are VERBATIM lines of that file, including leading indentation. Column B
is human commentary only and is never emitted. Rows outside a FILE block are
documentation and are skipped.

This reproduces the protocol documented in tab 00_README, Section 1, so the
workbook-to-repo step is deterministic and auditable: re-running this script on
the same .xlsx always yields a byte-identical working tree.

Usage:
    python3 scripts/extract_workbook.py [path/to/Godstone.xlsx] [repo_root]

Requires openpyxl:  python3 -m pip install openpyxl
"""
from __future__ import annotations

import os
import re
import sys

try:
    import openpyxl
except ModuleNotFoundError:
    sys.exit("openpyxl is required:  python3 -m pip install openpyxl")

_FILE_OPEN = re.compile(r"^>>> FILE: (.+?)\s*$")
_FILE_CLOSE = "<<< END FILE"


def extract(xlsx_path: str, repo_root: str) -> list[str]:
    wb = openpyxl.load_workbook(xlsx_path, data_only=True)
    written: list[str] = []
    errors: list[str] = []

    for ws in wb.worksheets:  # workbook tab order
        current = None
        fpath = None
        for (val,) in ws.iter_rows(min_col=1, max_col=1, values_only=True):
            if val is None:
                s = None
            elif isinstance(val, str):
                s = val
            else:
                # Text-formatted cells should already be strings; coerce just in case.
                s = str(val)

            if isinstance(s, str):
                m = _FILE_OPEN.match(s)
                if m:
                    fpath = m.group(1).strip()
                    full = os.path.join(repo_root, fpath)
                    os.makedirs(os.path.dirname(full), exist_ok=True)
                    current = open(full, "w", newline="\n")
                    continue
                if s.strip() == _FILE_CLOSE:
                    if current is not None:
                        current.close()
                        written.append(fpath)
                        current = None
                    else:
                        errors.append(f"{ws.title}: stray <<< END FILE")
                    continue

            if current is not None:
                current.write(("" if s is None else s) + "\n")

        if current is not None:
            errors.append(f"{ws.title}: unclosed file {fpath}")
            current.close()

    if errors:
        for e in errors:
            print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    return written


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(here)
    xlsx_path = os.path.join(repo_root, "Godstone.xlsx")

    if len(sys.argv) > 1:
        xlsx_path = sys.argv[1]
    if len(sys.argv) > 2:
        repo_root = sys.argv[2]

    if not os.path.exists(xlsx_path):
        sys.exit(f"workbook not found: {xlsx_path}")

    written = extract(xlsx_path, repo_root)
    print(f"extracted {len(written)} files into {repo_root}")
    for f in written:
        print(f"  {f}")


if __name__ == "__main__":
    main()