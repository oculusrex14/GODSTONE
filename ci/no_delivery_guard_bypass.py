#!/usr/bin/env python3
"""C6.4.1-A gate: production SQL CAS must be UNCONDITIONAL.

A GATE: it fails (exit 1) iff a production (main-source) directory contains a
CAS guard-bypass token. Production ``SqliteDeliveryRepository`` (both platforms)
builds its state / mode / recipient WHERE predicate UNCONDITIONALLY; the
mutation controls that weaken those predicates live ONLY in the TEST-ONLY
``MutatedDeliveryRepository`` (test source). This gate makes that invariant
enforceable: if a guard-bypass token re-enters a main-source directory, the
build fails. (A control that has never fired is not a control -- run ``--selftest``.)

Forbidden needles (whole-word, case-sensitive):
    stateGuard  modeGuard  recipientGuard
    disableStateGuard  disableRecipientGuard

Scanned main-source trees:
    android/mesh/src/main   android/app/src/main   android/core/src/main
    ios/Godstone/Sources    ios/Packages/GodstoneFoundation/Sources

Test source (android/mesh/src/test, ios/Godstone/Tests,
ios/Packages/GodstoneFoundation/Tests) is NOT scanned -- the test-only
``MutatedDeliveryRepository`` legitimately uses the guard flags there.

This gate does NOT close A-03 / ADR-004 / ADR-005. It proves the production
binary contains no CAS guard-bypass API; it does not prove the guards hold on a
device. Those stay OPEN.

Usage:
    python3 ci/no_delivery_guard_bypass.py [--root DIR] [--selftest]
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

FORBIDDEN = re.compile(
    r"\b(stateGuard|modeGuard|recipientGuard|disableStateGuard|disableRecipientGuard)\b"
)
SOURCE_SUFFIXES = {".kt", ".java", ".swift"}
MAIN_DIRS = (
    Path("android/mesh/src/main"),
    Path("android/app/src/main"),
    Path("android/core/src/main"),
    Path("ios/Godstone/Sources"),
    Path("ios/Packages/GodstoneFoundation/Sources"),
)


def scan(root: Path) -> list[str]:
    """Return violation strings (empty list => gate passes)."""
    hits: list[str] = []
    for rel in MAIN_DIRS:
        base = root / rel
        if not base.is_dir():
            continue
        for p in sorted(base.rglob("*")):
            if not p.is_file() or p.suffix not in SOURCE_SUFFIXES:
                continue
            text = p.read_text(encoding="utf-8", errors="replace")
            for i, line in enumerate(text.splitlines(), 1):
                if FORBIDDEN.search(line):
                    hits.append(
                        f"{p.relative_to(root)}:{i}: forbidden CAS guard-bypass "
                        f"token in PRODUCTION source: {line.strip()}"
                    )
    return hits


def run_gate(root: Path) -> int:
    hits = scan(root)
    if hits:
        print("DELIVERY-GUARD-BYPASS GATE: FAIL -- a production (main-source) "
              "directory contains a CAS guard-bypass token:")
        for h in hits:
            print("  - " + h)
        print("Production SQL CAS must be unconditional; mutation controls belong "
              "ONLY in the test-only MutatedDeliveryRepository (test source).")
        print("(A-03 / ADR-004 / ADR-005 remain OPEN: this is source-structure "
              "evidence, not device evidence.)")
        return 1
    print("DELIVERY-GUARD-BYPASS GATE: PASS -- no CAS guard-bypass token in any "
          "production main-source directory.")
    return 0


def selftest() -> int:
    failures: list[str] = []

    # Positive + negative + test-source-exclusion in one tree.
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        m = root / "android/mesh/src/main/io/godstone/mesh/delivery"
        m.mkdir(parents=True)
        (m / "Repo.kt").write_text(
            "class Repo(val stateGuard: Boolean = true)\n", encoding="utf-8")
        if not scan(root):
            failures.append("planted `stateGuard` in android/mesh/src/main NOT detected")

        # Test source carries a guard token and must NOT be flagged.
        t = root / "android/mesh/src/test/io/godstone/mesh/delivery"
        t.mkdir(parents=True)
        (t / "Mutated.kt").write_text(
            "class Mutated(val modeGuard: Boolean = true)\n", encoding="utf-8")
        hits = scan(root)
        if len(hits) != 1:
            failures.append(
                f"expected exactly 1 hit (test-source token must be ignored), "
                f"got {len(hits)}: {hits}")

        # Clean production source -> no hits (test file still present, ignored).
        (m / "Repo.kt").write_text("class Repo\n", encoding="utf-8")
        if scan(root):
            failures.append("clean production source produced a false positive")

    # Positive: Swift token in ios/Godstone/Sources detected.
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        s = root / "ios/Godstone/Sources/GodstoneMesh"
        s.mkdir(parents=True)
        (s / "Repo.swift").write_text("let recipientGuard = true\n", encoding="utf-8")
        if not scan(root):
            failures.append("planted `recipientGuard` in ios/Godstone/Sources NOT detected")

    # Positive: disableStateGuard / disableRecipientGuard also caught.
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        m = root / "android/mesh/src/main/io/godstone/mesh/delivery"
        m.mkdir(parents=True)
        (m / "R.kt").write_text("fun disableStateGuard() {}\n", encoding="utf-8")
        if not scan(root):
            failures.append("planted `disableStateGuard` NOT detected")

    if failures:
        print("no_delivery_guard_bypass selftest FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("no_delivery_guard_bypass selftest PASSED: planted main-source tokens "
          "detected; test-source tokens ignored; clean source passes.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[1] if __doc__ else "")
    ap.add_argument("--root", type=Path, default=Path.cwd())
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return run_gate(args.root.resolve())


if __name__ == "__main__":
    raise SystemExit(main())