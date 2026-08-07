#!/usr/bin/env python3
from __future__ import annotations
import re
from pathlib import Path

ROOTS = [Path(".github/workflows"), Path("ci"), Path("scripts"), Path("release")]
TEXT_SUFFIXES = {".py", ".sh", ".yml", ".yaml", ".md", ".json", ".toml", ".kts"}
MUTABLE_ACTION = re.compile(r"^\s*-?\s*uses:\s*[^\s@]+@(v?\d+(?:\.\d+){0,2}|main|master)\s*$", re.MULTILINE)


def main() -> int:
    violations: list[str] = []
    for root in ROOTS:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in TEXT_SUFFIXES or path.name == Path(__file__).name:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            if "--allow-unpinned" in text:
                violations.append(f"{path}: unpinned-vector bypass")
            if MUTABLE_ACTION.search(text):
                violations.append(f"{path}: mutable GitHub Action reference")
    if violations:
        print("Release bypasses found:\n" + "\n".join(violations))
        return 1
    print("no executable release bypasses or mutable action tags")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
