#!/usr/bin/env python3
"""C6.4.1-L gate: the fail-closed store schema + persist negative controls MUST exist.

A GATE: it fails (exit 1) iff a C6.4.1 schema/persist fail-closed negative
control is MISSING from the test sources. The BCDEFG sub-part made the store
fail-closed on schema version + migration + DDL fingerprint + msg_id NOT NULL;
the H sub-part made the iOS persist path transactional (strict throw -> ROLLBACK
-> failedStorage). A test that has been silently deleted is no longer a control
-- this gate makes the PRESENCE of those named controls enforceable, mirroring
no_delivery_guard_bypass.py (run ``--selftest`` to prove the gate fires).

Required markers (stable test function-name strings, one per control):
  Android (android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt):
    - "a future user_version is rejected fail-closed and left untouched"
    - "a malformed current-version schema is rejected fail-closed"
    - "msg_id NULL and length boundaries are rejected by both tables at the raw SQL level"
  iOS (ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift):
    - testFutureUserVersionIsRejectedFailClosedAndUntouched
    - testMalformedCurrentVersionSchemaIsRejectedFailClosed
    - testMsgIdNullAndLengthBoundaryRejectedByBothTablesRawSql
  iOS persist (ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift):
    - testHeldBytesStrictSqlFailureRollsBackAndReopensValid
    - testEvictStrictSqlFailureRollsBackAndEvictedRowsRestored
    - testContainsStrictSqlFailureRollsBackAndReopensValid

This gate does NOT prove the tests PASS (the Android :mesh:testDebugUnitTest and
iOS swift-test + xcodebuild GodstoneMeshTests jobs do that) -- it proves they
EXIST, so a future commit cannot silently drop a fail-closed control. It does
NOT close A-03 / A-04 / A-10 / ADR-004 / ADR-005 (no device evidence). Those stay
OPEN. Verdict unchanged: PARTIALLY REMEDIATED -- NOT READY.

Usage:
    python3 ci/check_store_schema_controls.py [--root DIR] [--selftest]
"""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

# (relative path, marker substring, human label)
CONTROLS: list[tuple[str, str, str]] = [
    # --- Android: C6.4.1-BCDEFG schema fail-closed controls ---
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "a future user_version is rejected fail-closed and left untouched",
     "Android future-user_version rejected fail-closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "a malformed current-version schema is rejected fail-closed",
     "Android malformed-current-schema rejected fail-closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "msg_id NULL and length boundaries are rejected by both tables at the raw SQL level",
     "Android msg_id NULL+length raw-SQL boundary (both tables)"),
    # --- iOS: C6.4.1-BCDEFG schema fail-closed controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testFutureUserVersionIsRejectedFailClosedAndUntouched",
     "iOS future-user_version rejected fail-closed"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testMalformedCurrentVersionSchemaIsRejectedFailClosed",
     "iOS malformed-current-schema rejected fail-closed"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testMsgIdNullAndLengthBoundaryRejectedByBothTablesRawSql",
     "iOS msg_id NULL+length raw-SQL boundary (both tables)"),
    # --- iOS: C6.4.1-H persist transactional fail-closed controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testHeldBytesStrictSqlFailureRollsBackAndReopensValid",
     "iOS persist heldBytes strict-SQL failure -> ROLLBACK"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testEvictStrictSqlFailureRollsBackAndEvictedRowsRestored",
     "iOS persist evict strict-SQL failure -> ROLLBACK"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testContainsStrictSqlFailureRollsBackAndReopensValid",
     "iOS persist contains strict-SQL failure -> ROLLBACK"),
]


def scan(root: Path) -> list[str]:
    """Return missing-control strings (empty list => gate passes)."""
    missing: list[str] = []
    for rel, marker, label in CONTROLS:
        p = root / rel
        if not p.is_file():
            missing.append(f"{rel}: file MISSING -- cannot confirm control: {label}")
            continue
        text = p.read_text(encoding="utf-8", errors="replace")
        if marker not in text:
            missing.append(
                f"{rel}: marker MISSING -- control removed: {label} "
                f"(looked for: {marker!r})"
            )
    return missing


def run_gate(root: Path) -> int:
    missing = scan(root)
    if missing:
        print("STORE-SCHEMA-CONTROLS GATE: FAIL -- a C6.4.1 schema/persist "
              "fail-closed negative control is MISSING from the test sources:")
        for m in missing:
            print("  - " + m)
        print("A test that has been silently deleted is no longer a control. "
              "Restore the named control or update ci/check_store_schema_controls.py "
              "deliberately (and record why).")
        print("(A-03 / A-04 / A-10 / ADR-004 / ADR-005 remain OPEN: this is "
              "test-presence evidence, not device evidence.)")
        return 1
    print("STORE-SCHEMA-CONTROLS GATE: PASS -- all 9 C6.4.1 schema/persist "
          "fail-closed negative controls present in the test sources "
          "(3 Android schema + 3 iOS schema + 3 iOS persist).")
    return 0


def selftest() -> int:
    failures: list[str] = []

    # 1. A clean tree containing ALL markers -> PASS (no missing).
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        # Seed every control's file with its marker (plus extra noise).
        files: dict[str, str] = {}
        for rel, marker, _ in CONTROLS:
            files.setdefault(rel, "")
            files[rel] += f"    // marker: {marker}\n"
        for rel, body in files.items():
            p = root / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(body, encoding="utf-8")
        if scan(root):
            failures.append(f"clean tree (all markers present) produced false "
                            f"positive: {scan(root)}")

        # 2. Remove ONE marker -> the gate MUST fire with exactly that control.
        first_rel, first_marker, first_label = CONTROLS[0]
        p = root / first_rel
        text = p.read_text(encoding="utf-8")
        p.write_text(text.replace(f"// marker: {first_marker}\n", ""), encoding="utf-8")
        missing = scan(root)
        if len(missing) != 1 or first_label not in missing[0]:
            failures.append(
                f"removed marker {first_marker!r} but did not get exactly 1 "
                f"missing control naming {first_label!r}; got {missing}")
        # Restore -> clean again.
        p.write_text(text, encoding="utf-8")
        if scan(root):
            failures.append("restoring the removed marker still left a missing control")

    # 3. A missing FILE is reported as a missing file (not a crash).
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        m = scan(root)
        if not m:
            failures.append("empty tree (no control files) did not report any "
                            "missing control")
        if not all("file MISSING" in line for line in m):
            failures.append("missing files were not labelled 'file MISSING'")

    if failures:
        print("check_store_schema_controls selftest FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("check_store_schema_controls selftest PASSED: all-markers-present "
          "passes; one-removed fires exactly one missing control; missing files "
          "reported as missing.")
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