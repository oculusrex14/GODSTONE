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
    # --- Android: C6.6 atomic outbound DIRECT enqueue fail-closed controls ---
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "enqueueDirectOutbound fault after held insert rolls back both held and delivery rows",
     "Android direct enqueue fault after held insert -> ROLLBACK"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "enqueueDirectOutbound under tight capacity rejects and leaves zero delivery and zero held rows",
     "Android direct enqueue capacity rejection -> 0 delivery rows"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "enqueueDirectOutbound conflicting recipient fails closed with ConflictRecipient",
     "Android direct enqueue conflicting recipient -> fail closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "enqueueDirectOutbound held-only inconsistency fails closed with InconsistentState",
     "Android direct enqueue held-only inconsistency -> fail closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "enqueueDirectOutbound delivery-only inconsistency fails closed with InconsistentState",
     "Android direct enqueue delivery-only inconsistency -> fail closed"),
    # --- iOS: C6.6 atomic outbound DIRECT enqueue fail-closed controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC66EnqueueDirectOutboundFaultAfterHeldInsertRollsBackBothHeldAndDeliveryRows",
     "iOS direct enqueue fault after held insert -> ROLLBACK"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC66EnqueueDirectOutboundUnderTightCapacityRejectsAndLeavesZeroDeliveryAndZeroHeldRows",
     "iOS direct enqueue capacity rejection -> 0 delivery rows"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC66EnqueueDirectOutboundConflictingRecipientFailsClosedWithConflictRecipient",
     "iOS direct enqueue conflicting recipient -> fail closed"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC66EnqueueDirectOutboundHeldOnlyInconsistencyFailsClosedWithInconsistentState",
     "iOS direct enqueue held-only inconsistency -> fail closed"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC66EnqueueDirectOutboundDeliveryOnlyInconsistencyFailsClosedWithInconsistentState",
     "iOS direct enqueue delivery-only inconsistency -> fail closed"),
    # --- Android: C6.6.1 canonical frame binding and local provenance controls ---
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "same msgId different payload fails closed with CanonicalFrameMismatch",
     "Android direct enqueue payload mismatch -> fail closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "same msgId different routingTag fails closed with CanonicalFrameMismatch",
     "Android direct enqueue routingTag mismatch -> fail closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "local origin provenance is localOriginNodeId not msgId",
     "Android direct enqueue local origin provenance -> local node ID"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "wrong preexisting provenance fails closed with InconsistentState",
     "Android direct enqueue wrong provenance -> fail closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/MeshNodeDeliveryIntegrationTest.kt",
     "dispatchDirect transmits store-returned canonical frame and not caller modified frame",
     "Android dispatchDirect transports canonical store frame"),
    # --- iOS: C6.6.1 canonical frame binding and local provenance controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC661EnqueueDirectOutboundSameMsgIdDifferentPayloadFailsClosedWithCanonicalFrameMismatch",
     "iOS direct enqueue payload mismatch -> fail closed"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC661EnqueueDirectOutboundSameMsgIdDifferentRoutingTagFailsClosedWithCanonicalFrameMismatch",
     "iOS direct enqueue routingTag mismatch -> fail closed"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC661EnqueueDirectOutboundLocalOriginProvenanceIsLocalOriginNodeIdNotMsgId",
     "iOS direct enqueue local origin provenance -> local node ID"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC661EnqueueDirectOutboundWrongPreexistingProvenanceFailsClosedWithInconsistentState",
     "iOS direct enqueue wrong provenance -> fail closed"),
    ("ios/Godstone/Tests/GodstoneMeshTests/MeshNodeDeliveryIntegrationTests.swift",
     "testC661DispatchDirectTransmitsStoreReturnedCanonicalFrameAndNotCallerModifiedFrame",
     "iOS dispatchDirect transports canonical store frame"),
    # --- Android: C6.6.2 & C6.6.3 capacity safety, strict decoding, and policy controls ---
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "capacity eviction protects QUEUED_DURABLY active direct frame from new direct pressure",
     "Android capacity eviction protects active QUEUED_DURABLY frame"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "inbound persist cannot orphan local active direct delivery row",
     "Android inbound persist cannot orphan active delivery row"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "terminal delivery row without held frame returns RejectedTerminalState",
     "Android terminal delivery without held frame -> RejectedTerminalState"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "raw SQL corrupted type integer does not alias TypeV2 and fails closed",
     "Android raw SQL corrupted type integer does not alias -> fail closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "C6_6_3 raw SQL corrupted type negative 16 does not alias SOS and fails closed",
     "Android raw SQL type=-16 does not alias SOS -> fail closed"),
    ("android/mesh/src/test/java/io/godstone/mesh/store/SqliteMessageStoreTest.kt",
     "C6_6 enqueueDirectOutbound policy rejection on non-direct or unsealed or invalid msg_id",
     "Android direct enqueue policy rejection matrix -> InvalidArgument"),
    # --- iOS: C6.6.2 & C6.6.3 capacity safety, strict decoding, and error handling controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC662CapacityEvictionProtectsQueuedDurablyActiveDirectFrameFromNewDirectPressure",
     "iOS capacity eviction protects active QUEUED_DURABLY frame"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC662InboundPersistCannotOrphanLocalActiveDirectDeliveryRow",
     "iOS inbound persist cannot orphan active delivery row"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC662TerminalDeliveryRowWithoutHeldFrameReturnsRejectedTerminalState",
     "iOS terminal delivery without held frame -> RejectedTerminalState"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC662RawSqlCorruptedTypeIntegerFailsClosedWithoutTrapping",
     "iOS raw SQL corrupted type integer fails closed without trapping"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC662ReadHeldNoLockStrictStepErrorYieldsStorageFailureAndRollsBack",
     "iOS readHeld sqlite step error -> StorageFailure and rollback"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteMessageStoreTests.swift",
     "testC663ContainsNoLockStrictStepErrorYieldsFailedStorageAndRollsBack",
     "iOS containsNoLockStrict step error -> failedStorage and rollback"),
    # --- Android: C7.4 atomic authenticated ACK commit and held-frame retirement controls ---
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4 queued ACK state ACK and held deleted",
     "Android C7.4 queued ACK state ACK and held deleted"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4 handed ACK state ACK and held deleted",
     "Android C7.4 handed ACK state ACK and held deleted"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4 missing-held active row rollback and Corrupt",
     "Android C7.4 missing held active row rollback and Corrupt"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4 fault after ACK CAS both restored",
     "Android C7.4 fault after ACK CAS both restored"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4 fault after held DELETE both restored",
     "Android C7.4 fault after held delete both restored"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4 held delete SQL failure yields StorageFailure and rolls back",
     "Android C7.4 held delete SQL failure -> StorageFailure and rollback"),
    # --- iOS: C7.4 atomic authenticated ACK commit and held-frame retirement controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC74QueuedAckStateAckAndHeldDeleted",
     "iOS C7.4 queued ACK state ACK and held deleted"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC74HandedAckStateAckAndHeldDeleted",
     "iOS C7.4 handed ACK state ACK and held deleted"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC74MissingHeldActiveRowRollbackAndCorrupt",
     "iOS C7.4 missing held active row rollback and Corrupt"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC74FaultAfterAckCasBothRestored",
     "iOS C7.4 fault after ACK CAS both restored"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC74FaultAfterHeldDeleteBothRestored",
     "iOS C7.4 fault after held delete both restored"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC74HeldDeleteSqlFailureYieldsStorageFailureAndRollsBack",
     "iOS C7.4 held delete SQL failure -> StorageFailure and rollback"),
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

    # Structural check: Android MeshNode.dispatchDirect encodes canonicalFrame and never frame.encode()
    android_mesh_node = root / "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt"
    if android_mesh_node.is_file():
        text = android_mesh_node.read_text(encoding="utf-8", errors="replace")
        if "fun dispatchDirect(" in text:
            idx = text.find("fun dispatchDirect(")
            end_idx = text.find("fun ingestInbound(", idx)
            if end_idx == -1:
                end_idx = len(text)
            fn_body = text[idx:end_idx]
            if "val bytes = canonicalFrame.encode()" not in fn_body:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt: dispatchDirect must encode canonicalFrame")
            if "frame.encode()" in fn_body:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt: dispatchDirect must not call frame.encode()")

    # Structural check: iOS MeshNode.dispatchDirect sends canonicalFrame and never send(frame,
    ios_mesh_node = root / "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift"
    if ios_mesh_node.is_file():
        text = ios_mesh_node.read_text(encoding="utf-8", errors="replace")
        if "func dispatchDirect(" in text:
            idx = text.find("func dispatchDirect(")
            end_idx = text.find("func ingestInbound(", idx)
            if end_idx == -1:
                end_idx = len(text)
            fn_body = text[idx:end_idx]
            if "send(canonicalFrame, peer)" not in fn_body:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: dispatchDirect must transport canonicalFrame")
            if "send(frame," in fn_body:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: dispatchDirect must not transport frame directly")

    # Structural check: C7.4 DeliveryRepository must NOT expose state-only acknowledgeBound
    android_delivery_repo = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt"
    if android_delivery_repo.is_file():
        text = android_delivery_repo.read_text(encoding="utf-8", errors="replace")
        if "fun acknowledgeBound(" in text:
            missing.append("android DeliveryRepository must not expose state-only acknowledgeBound (must use acknowledgeBoundAndRetire)")

    ios_delivery_repo = root / "ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift"
    if ios_delivery_repo.is_file():
        text = ios_delivery_repo.read_text(encoding="utf-8", errors="replace")
        if "func acknowledgeBound(" in text:
            missing.append("iOS DeliveryRepository must not expose state-only acknowledgeBound (must use acknowledgeBoundAndRetire)")

    return missing


def run_gate(root: Path) -> int:
    missing = scan(root)
    if missing:
        print("STORE-SCHEMA-CONTROLS GATE: FAIL -- a C6.4.1/C6.6 schema/persist "
              "fail-closed negative control is MISSING from the test sources:")
        for m in missing:
            print("  - " + m)
        print("A test that has been silently deleted is no longer a control. "
              "Restore the named control or update ci/check_store_schema_controls.py "
              "deliberately (and record why).")
        print("(A-03 / A-04 / A-10 / ADR-004 / ADR-005 remain OPEN: this is "
              "test-presence evidence, not device evidence.)")
        return 1
    print(f"STORE-SCHEMA-CONTROLS GATE: PASS -- all {len(CONTROLS)} C6.4.1/C6.6 schema/persist/enqueue "
          "fail-closed negative controls present in the test sources.")
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