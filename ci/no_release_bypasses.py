#!/usr/bin/env python3
"""Fail-closed scan for executable release bypasses.

No executable CI/release command under ``.github/workflows``, ``ci``,
``scripts`` or ``release`` may carry the ``--allow-unpinned`` vector-lock
bypass or a mutable GitHub Action reference (``@vN`` / ``@main`` / ``@master``).

This file is the *detection guard*, so it legitimately contains the literal
``--allow-unpinned`` string -- but only to match it. ``--selftest`` proves the
detection has teeth: it synthesises files carrying each bypass and requires the
scanner to flag them. A control that has never been observed firing is not a
control.
"""
from __future__ import annotations
import argparse
import re
import tempfile
from pathlib import Path

ROOTS = [Path(".github/workflows"), Path("ci"), Path("scripts"), Path("release")]
TEXT_SUFFIXES = {".py", ".sh", ".yml", ".yaml", ".md", ".json", ".toml", ".kts"}
MUTABLE_ACTION = re.compile(r"^\s*-?\s*uses:\s*[^\s@]+@(v?\d+(?:\.\d+){0,2}|main|master)\s*$", re.MULTILINE)


def scan(roots: list[Path], exclude_self: str | None) -> list[str]:
    violations: list[str] = []
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.suffix not in TEXT_SUFFIXES:
                continue
            if exclude_self is not None and path.name == exclude_self:
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            if "--allow-unpinned" in text:
                violations.append(f"{path}: unpinned-vector bypass")
            if MUTABLE_ACTION.search(text):
                violations.append(f"{path}: mutable GitHub Action reference")
    return violations


def selftest() -> int:
    """Prove the scanner detects each bypass class against synthetic inputs."""
    fired: list[str] = []
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        # unpinned-vector bypass
        (root / "bad.yml").write_text("run: python ci/check_parity.py --allow-unpinned\n")
        # mutable action reference
        (root / "bad2.yml").write_text("    uses: actions/checkout@v4\n")
        v = scan([root], exclude_self=None)
        if any("unpinned-vector bypass" in s for s in v):
            fired.append("unpinned-vector bypass")
        if any("mutable GitHub Action reference" in s for s in v):
            fired.append("mutable action reference")
        # negative: a clean file must NOT be flagged
        (root / "clean.yml").write_text("run: python ci/check_parity.py\n")
        v2 = scan([root / "clean.yml"], exclude_self=None)
        if not v2:
            fired.append("clean-file not flagged")
    expected = {"unpinned-vector bypass", "mutable action reference", "clean-file not flagged"}
    missing = expected - set(fired)
    print("selftest fired:")
    for f in fired:
        print(f"  - {f}")
    if missing:
        print(f"selftest: branches did NOT fire: {sorted(missing)}")
        return 1
    print("selftest: all detection branches fire correctly")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    ap.add_argument("--selftest", action="store_true",
                    help="prove the scanner detects each bypass against synthetic inputs")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    violations = scan(ROOTS, exclude_self=Path(__file__).name)
    if violations:
        print("Release bypasses found:\n" + "\n".join(violations))
        return 1
    print("no executable release bypasses or mutable action tags")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
