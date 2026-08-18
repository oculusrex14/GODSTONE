#!/usr/bin/env python3
"""C6.4.1 / C6.6 / C7.4 / C7.4.1 / C7.4.2 gate: schema, persist, and atomic ACK-retirement controls MUST exist.

A GATE: it fails (exit 1) iff a C6.4.1/C6.6/C7.4/C7.4.1/C7.4.2 schema, persistence,
or atomic ACK-retirement fail-closed negative control is MISSING from the test sources
or if the structural AST/function-region invariants are violated.

Structural checks enforce:
  1. Android MeshNode.dispatchDirect transports canonicalFrame, never frame directly.
  2. iOS MeshNode.dispatchDirect transports canonicalFrame, never frame directly.
  3. DeliveryTracker on both platforms forbids state-only acknowledgeBound.
  4. Android SqliteDeliveryRepository.acknowledgeBoundAndRetire executes db.inTransaction,
     execDeliveryUpdate, and deleteHeld in strictly ordered succession inside the function region.
  5. iOS SqliteDeliveryRepository.acknowledgeBoundAndRetire routes through atomicAcknowledgeAndRetire.
  6. iOS SqliteMessageStore.atomicAcknowledgeAndRetireWithFault consumes guardedAckSql inside
     withTransaction and deletes StoreSchema.deleteHeldSql in strictly ordered succession.

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
    # --- Android: C7.4.1 atomic authenticated ACK commit, held-frame retirement, and mutation controls ---
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 production-shaped queued C6_6 to C7_4 success",
     "Android C7.4.1 production-shaped queued C6.6 to C7.4 success"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 production-shaped handed C6_6 to C7_4 success",
     "Android C7.4.1 production-shaped handed C6.6 to C7.4 success"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 rejected authentication held retained",
     "Android C7.4.1 rejected authentication held retained"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 not ack eligible NONE mode held retained",
     "Android C7.4.1 not ack eligible NONE mode held retained"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 missing-held active row rollback and Corrupt",
     "Android C7.4.1 missing held active row rollback and Corrupt"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 fault after ACK CAS both restored",
     "Android C7.4.1 fault after ACK CAS both restored"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 fault after held DELETE both restored",
     "Android C7.4.1 fault after held delete both restored"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 held delete SQL failure yields StorageFailure and rolls back",
     "Android C7.4.1 held delete SQL failure -> StorageFailure and rollback"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 sequential duplicate ACK short-circuits without re-auth",
     "Android C7.4.1 sequential duplicate ACK short-circuits without re-auth"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 duplicate authenticated race one Applied one Duplicate",
     "Android C7.4.1 duplicate authenticated race one Applied one Duplicate"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 production enqueueDirectOutbound after ACK returns RejectedTerminalState",
     "Android C7.4.1 direct enqueue after ACK returns RejectedTerminalState"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_4_1 capacity released on authenticated ACK is reusable by new frame",
     "Android C7.4.1 capacity released on ACK is reusable"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "skipping held retirement leaves split state",
     "Android cross-table mutation control - skipping held retirement leaves split state"),
    # --- iOS: C7.4.1 atomic authenticated ACK commit, held-frame retirement, and mutation controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741ProductionShapedQueuedC66ToC74Success",
     "iOS C7.4.1 production-shaped queued C6.6 to C7.4 success"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741ProductionShapedHandedC66ToC74Success",
     "iOS C7.4.1 production-shaped handed C6.6 to C7.4 success"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741RejectedAuthenticationHeldRetained",
     "iOS C7.4.1 rejected authentication held retained"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741NotAckEligibleNoneModeHeldRetained",
     "iOS C7.4.1 not ack eligible NONE mode held retained"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741MissingHeldActiveRowRollbackAndCorrupt",
     "iOS C7.4.1 missing held active row rollback and Corrupt"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741FaultAfterAckCasBothRestored",
     "iOS C7.4.1 fault after ACK CAS both restored"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741FaultAfterHeldDeleteBothRestored",
     "iOS C7.4.1 fault after held delete both restored"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741HeldDeleteSqlFailureYieldsStorageFailureAndRollsBack",
     "iOS C7.4.1 held delete SQL failure -> StorageFailure and rollback"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741SequentialDuplicateAckShortCircuitsWithoutReAuth",
     "iOS C7.4.1 sequential duplicate ACK short-circuits without re-auth"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741DuplicateAuthenticatedRaceOneAppliedOneDuplicate",
     "iOS C7.4.1 duplicate authenticated race one Applied one Duplicate"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741ProductionEnqueueDirectOutboundAfterAckReturnsRejectedTerminalState",
     "iOS C7.4.1 direct enqueue after ACK returns RejectedTerminalState"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC741CapacityReleasedOnAuthenticatedAckIsReusableByNewFrame",
     "iOS C7.4.1 capacity released on ACK is reusable"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testSkipHeldRetirementLeavesSplitStateProvingAtomicRetirementIsLoadBearing",
     "iOS cross-table mutation control - skipping held retirement leaves split state"),
]


def extract_braced_function(text: str, signature: str) -> str | None:
    """Extract the complete region of a function starting with `signature` up to its matching closing brace."""
    idx = text.find(signature)
    if idx == -1:
        return None
    brace_start = text.find("{", idx)
    if brace_start == -1:
        return None
    depth = 0
    in_line_comment = False
    in_block_comment = False
    in_string = False
    escape = False
    i = brace_start
    while i < len(text):
        c = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_line_comment:
            if c == "\n":
                in_line_comment = False
        elif in_block_comment:
            if c == "*" and nxt == "/":
                in_block_comment = False
                i += 1
        elif in_string:
            if escape:
                escape = False
            elif c == "\\":
                escape = True
            elif c == '"':
                in_string = False
        else:
            if c == "/" and nxt == "/":
                in_line_comment = True
                i += 1
            elif c == "/" and nxt == "*":
                in_block_comment = True
                i += 1
            elif c == '"':
                in_string = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return text[idx : i + 1]
        i += 1
    return None


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

    # 1. Structural check: Android MeshNode.dispatchDirect encodes canonicalFrame and never frame.encode()
    android_mesh_node = root / "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt"
    if not android_mesh_node.is_file():
        missing.append("android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt: file MISSING")
    else:
        text = android_mesh_node.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "fun dispatchDirect(")
        if fn_body is None:
            missing.append("android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt: dispatchDirect missing or unextractable")
        else:
            if "canonicalFrame.encode()" not in fn_body:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt: dispatchDirect must encode canonicalFrame")
            if "frame.encode()" in fn_body:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt: dispatchDirect must not call frame.encode()")

    # 2. Structural check: iOS MeshNode.dispatchDirect sends canonicalFrame and never send(frame,
    ios_mesh_node = root / "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift"
    if not ios_mesh_node.is_file():
        missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: file MISSING")
    else:
        text = ios_mesh_node.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "func dispatchDirect(")
        if fn_body is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: dispatchDirect missing or unextractable")
        else:
            if "send(canonicalFrame, peer)" not in fn_body:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: dispatchDirect must transport canonicalFrame")
            if "send(frame," in fn_body:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: dispatchDirect must not transport frame directly")

    # 3. Structural check: C7.4 DeliveryTracker must NOT expose state-only acknowledgeBound
    android_delivery_tracker = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt"
    if not android_delivery_tracker.is_file():
        missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt: file MISSING")
    else:
        text = android_delivery_tracker.read_text(encoding="utf-8", errors="replace")
        if "fun acknowledgeBound(" in text:
            missing.append("android DeliveryTracker must not expose state-only acknowledgeBound (must use acknowledgeBoundAndRetire)")

    ios_delivery_tracker = root / "ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift"
    if not ios_delivery_tracker.is_file():
        missing.append("ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift: file MISSING")
    else:
        text = ios_delivery_tracker.read_text(encoding="utf-8", errors="replace")
        if "func acknowledgeBound(" in text:
            missing.append("iOS DeliveryTracker must not expose state-only acknowledgeBound (must use acknowledgeBoundAndRetire)")

    # 4. Structural check: Android SqliteDeliveryRepository acknowledgeBoundAndRetire region
    android_sqlite_repo = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
    if not android_sqlite_repo.is_file():
        missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: file MISSING")
    else:
        text = android_sqlite_repo.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "override fun acknowledgeBoundAndRetire(")
        if fn_body is None:
            fn_body = extract_braced_function(text, "fun acknowledgeBoundAndRetire(")
        if fn_body is None:
            missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire missing or unextractable")
        else:
            pos_tx = fn_body.find("inTransaction")
            pos_upd = fn_body.find("execDeliveryUpdate")
            pos_del = fn_body.find("deleteHeld")

            if pos_tx == -1:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire must execute inside inTransaction")
            if pos_upd == -1:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire must call execDeliveryUpdate")
            if pos_del == -1:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire must call deleteHeld")

            if pos_tx != -1 and pos_upd != -1 and pos_del != -1:
                if not (pos_tx < pos_upd < pos_del):
                    missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire operations out of order (require inTransaction before execDeliveryUpdate before deleteHeld)")

    # 5. Structural check: iOS SqliteDeliveryRepository acknowledgeBoundAndRetire region routes to atomicAcknowledgeAndRetire
    ios_sqlite_repo = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
    if not ios_sqlite_repo.is_file():
        missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: file MISSING")
    else:
        text = ios_sqlite_repo.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "func acknowledgeBoundAndRetire(")
        fn_fault = extract_braced_function(text, "func acknowledgeBoundAndRetireWithFault(")
        if fn_body is None and fn_fault is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: acknowledgeBoundAndRetire missing or unextractable")
        else:
            routes_to_atomic = False
            if fn_body and "atomicAcknowledgeAndRetire" in fn_body:
                routes_to_atomic = True
            elif fn_body and "acknowledgeBoundAndRetireWithFault" in fn_body:
                if fn_fault and "atomicAcknowledgeAndRetire" in fn_fault:
                    routes_to_atomic = True
            elif fn_fault and "atomicAcknowledgeAndRetire" in fn_fault:
                routes_to_atomic = True

            if not routes_to_atomic:
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: acknowledgeBoundAndRetire must route through atomicAcknowledgeAndRetire")

    # 6. Structural check: iOS MessageStore atomicAcknowledgeAndRetireWithFault region
    ios_message_store = root / "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"
    if not ios_message_store.is_file():
        missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: file MISSING")
    else:
        text = ios_message_store.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "func atomicAcknowledgeAndRetireWithFault(")
        if fn_body is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault missing or unextractable")
        else:
            pos_tx = fn_body.find("withTransaction")
            pos_del = fn_body.find("StoreSchema.deleteHeldSql")
            if pos_del == -1:
                pos_del = fn_body.find("deleteHeldSql")

            if pos_tx == -1:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault must execute inside withTransaction")
            if pos_del == -1:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault must use StoreSchema.deleteHeldSql")

            if pos_tx != -1 and pos_del != -1:
                if not (pos_tx < pos_del):
                    missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault operations out of order (require withTransaction before deleteHeldSql)")

            # Require guardedAckSql is consumed inside the transaction body, not just named in the signature
            if pos_tx != -1:
                tx_body = fn_body[pos_tx:]
                if "guardedAckSql" not in tx_body:
                    missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: guardedAckSql must be consumed inside withTransaction region")
            else:
                if "guardedAckSql" not in fn_body:
                    missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: guardedAckSql missing from atomicAcknowledgeAndRetireWithFault")

    return missing


def run_gate(root: Path) -> int:
    missing = scan(root)
    if missing:
        print("STORE-SCHEMA-CONTROLS GATE: FAIL -- a C6.4.1/C6.6/C7.4/C7.4.1/C7.4.2 schema/persist/atomic-ACK "
              "fail-closed control is MISSING from the test sources:")
        for m in missing:
            print("  - " + m)
        print("A test or structural invariant that has been silently removed is a regression. "
              "Restore the named control or update ci/check_store_schema_controls.py "
              "deliberately (and record why).")
        print("(A-03 / A-04 / A-10 / ADR-003 / ADR-004 / ADR-005 remain OPEN: this is "
              "repo-owned evidence, not device evidence.)")
        return 1
    print(f"STORE-SCHEMA-CONTROLS GATE: PASS -- all {len(CONTROLS)} C6.4.1/C6.6/C7.4/C7.4.1/C7.4.2 "
          "schema/persistence/atomic ACK-retirement controls present in the test sources.")
    return 0


def _build_synthetic_positive_tree(root: Path) -> None:
    """Populate a minimal, fully-passing synthetic repository tree for selftests."""
    # Seed all marker files
    files: dict[str, str] = {}
    for rel, marker, _ in CONTROLS:
        files.setdefault(rel, "")
        files[rel] += f"    // marker: {marker}\n"
    for rel, body in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")

    # Android MeshNode
    android_mn = root / "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt"
    android_mn.parent.mkdir(parents=True, exist_ok=True)
    android_mn.write_text(
        "package io.godstone.mesh\n"
        "class MeshNode {\n"
        "    fun dispatchDirect(frame: FrameV2) {\n"
        "        val bytes = canonicalFrame.encode()\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
    )

    # iOS MeshNode
    ios_mn = root / "ios/Godstone/Sources/GodstoneMesh/MeshNode.swift"
    ios_mn.parent.mkdir(parents=True, exist_ok=True)
    ios_mn.write_text(
        "public class MeshNode {\n"
        "    func dispatchDirect(frame: FrameV2) {\n"
        "        send(canonicalFrame, peer)\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
    )

    # Android DeliveryTracker interface
    android_dt = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt"
    android_dt.parent.mkdir(parents=True, exist_ok=True)
    android_dt.write_text(
        "package io.godstone.mesh.delivery\n"
        "interface DeliveryTracker {\n"
        "    fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult\n"
        "}\n",
        encoding="utf-8",
    )

    # Android SqliteDeliveryRepository
    android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
    android_sdr.parent.mkdir(parents=True, exist_ok=True)
    android_sdr.write_text(
        "package io.godstone.mesh.delivery\n"
        "class SqliteDeliveryRepository {\n"
        "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
        "        return db.inTransaction { tx ->\n"
        "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
        "            val deleted = tx.deleteHeld(msgId)\n"
        "            AckRetireResult.APPLIED\n"
        "        }\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
    )

    # iOS DeliveryTracker interface
    ios_dt = root / "ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift"
    ios_dt.parent.mkdir(parents=True, exist_ok=True)
    ios_dt.write_text(
        "public protocol DeliveryTracker {\n"
        "    func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult\n"
        "}\n",
        encoding="utf-8",
    )

    # iOS SqliteDeliveryRepository
    ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
    ios_sdr.parent.mkdir(parents=True, exist_ok=True)
    ios_sdr.write_text(
        "public class SqliteDeliveryRepository {\n"
        "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
        "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
    )

    # iOS MessageStore
    ios_ms = root / "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"
    ios_ms.parent.mkdir(parents=True, exist_ok=True)
    ios_ms.write_text(
        "public class SqliteMessageStore {\n"
        "    internal func atomicAcknowledgeAndRetireWithFault(\n"
        "        guardedAckSql: String,\n"
        "        msgId: Data,\n"
        "        expectedRecipient: Data,\n"
        "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
        "    ) throws -> AckRetireMutationResult {\n"
        "        return try withTransaction { db in\n"
        "            sqlite3_prepare_v2(db, guardedAckSql, -1, &stmt, nil)\n"
        "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
        "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
        "            return .applied\n"
        "        }\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
    )


def selftest() -> int:
    failures: list[str] = []

    # 1. Clean positive synthetic tree -> PASS (0 missing)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        clean_res = scan(root)
        if clean_res:
            failures.append(f"clean positive synthetic tree produced false positives: {clean_res}")

        # Marker removal test (one marker removed fires exactly that marker)
        first_rel, first_marker, first_label = CONTROLS[0]
        p = root / first_rel
        text = p.read_text(encoding="utf-8")
        p.write_text(text.replace(f"// marker: {first_marker}\n", ""), encoding="utf-8")
        missing = scan(root)
        if len(missing) != 1 or first_label not in missing[0]:
            failures.append(
                f"removed marker {first_marker!r} but did not get exactly 1 "
                f"missing control naming {first_label!r}; got {missing}"
            )
        p.write_text(text, encoding="utf-8")

    # Mutation A: Android Transaction Removal with decoy elsewhere in file
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "        val deleted = tx.deleteHeld(msgId)\n"
            "        return AckResult.Applied\n"
            "    }\n"
            "    fun decoyElsewhere() {\n"
            "        db.inTransaction { }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must execute inside inTransaction" in m for m in res):
            failures.append(f"Mutation A (Android transaction removal with decoy) NOT detected; got {res}")
        else:
            print("  ok    [Mutation A] Android transaction removal with decoy detected")

    # Mutation B: Android Delete Removal with decoy elsewhere in file
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    fun decoyElsewhere() {\n"
            "        tx.deleteHeld(msgId)\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must call deleteHeld" in m for m in res):
            failures.append(f"Mutation B (Android deleteHeld removal with decoy) NOT detected; got {res}")
        else:
            print("  ok    [Mutation B] Android deleteHeld removal with decoy detected")

    # Mutation C: Android Guarded Update Removal with decoy elsewhere in file
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    fun decoyElsewhere() {\n"
            "        tx.execDeliveryUpdate(sql, bindArgs)\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must call execDeliveryUpdate" in m for m in res):
            failures.append(f"Mutation C (Android execDeliveryUpdate removal with decoy) NOT detected; got {res}")
        else:
            print("  ok    [Mutation C] Android execDeliveryUpdate removal with decoy detected")

    # Mutation D: iOS Repository Routing Removal with decoy elsewhere in file
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return .applied\n"
            "    }\n"
            "    func decoyElsewhere() {\n"
            "        store.atomicAcknowledgeAndRetire()\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must route through atomicAcknowledgeAndRetire" in m for m in res):
            failures.append(f"Mutation D (iOS repo routing removal with decoy) NOT detected; got {res}")
        else:
            print("  ok    [Mutation D] iOS repository routing removal with decoy detected")

    # Mutation E: iOS Transaction Removal with decoy elsewhere in file
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_ms = root / "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"
        ios_ms.write_text(
            "public class SqliteMessageStore {\n"
            "    internal func atomicAcknowledgeAndRetireWithFault(\n"
            "        guardedAckSql: String,\n"
            "        msgId: Data,\n"
            "        expectedRecipient: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> AckRetireMutationResult {\n"
            "        sqlite3_prepare_v2(db, guardedAckSql, -1, &stmt, nil)\n"
            "        let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "        sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "        return .applied\n"
            "    }\n"
            "    func decoyElsewhere() {\n"
            "        withTransaction { _ in }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicAcknowledgeAndRetireWithFault must execute inside withTransaction" in m for m in res):
            failures.append(f"Mutation E (iOS withTransaction removal with decoy) NOT detected; got {res}")
        else:
            print("  ok    [Mutation E] iOS withTransaction removal with decoy detected")

    # Mutation F: iOS Held Delete Removal with decoy elsewhere in file
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_ms = root / "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"
        ios_ms.write_text(
            "public class SqliteMessageStore {\n"
            "    internal func atomicAcknowledgeAndRetireWithFault(\n"
            "        guardedAckSql: String,\n"
            "        msgId: Data,\n"
            "        expectedRecipient: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> AckRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedAckSql, -1, &stmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "    func decoyElsewhere() {\n"
            "        let d = StoreSchema.deleteHeldSql\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicAcknowledgeAndRetireWithFault must use StoreSchema.deleteHeldSql" in m for m in res):
            failures.append(f"Mutation F (iOS deleteHeldSql removal with decoy) NOT detected; got {res}")
        else:
            print("  ok    [Mutation F] iOS deleteHeldSql removal with decoy detected")

    # Mutation G: State-only acknowledgeBound Reintroduction
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_dt = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt"
        android_dt.write_text(
            "package io.godstone.mesh.delivery\n"
            "interface DeliveryTracker {\n"
            "    fun acknowledgeBound(msgId: ByteArray): AckResult\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("android DeliveryTracker must not expose state-only acknowledgeBound" in m for m in res):
            failures.append(f"Mutation G (state-only acknowledgeBound on Android) NOT detected; got {res}")
        else:
            print("  ok    [Mutation G] state-only acknowledgeBound reintroduction detected")

    # Mutation Ordering Android: deleteHeld before execDeliveryUpdate
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire operations out of order" in m for m in res):
            failures.append(f"Mutation Ordering Android (deleteHeld before execDeliveryUpdate) NOT detected; got {res}")
        else:
            print("  ok    [Mutation Ordering Android] operations out of order detected")

    # Mutation Ordering iOS: StoreSchema.deleteHeldSql outside withTransaction
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_ms = root / "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"
        ios_ms.write_text(
            "public class SqliteMessageStore {\n"
            "    internal func atomicAcknowledgeAndRetireWithFault(\n"
            "        guardedAckSql: String,\n"
            "        msgId: Data,\n"
            "        expectedRecipient: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> AckRetireMutationResult {\n"
            "        let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedAckSql, -1, &stmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicAcknowledgeAndRetireWithFault operations out of order" in m for m in res):
            failures.append(f"Mutation Ordering iOS (deleteHeldSql outside withTransaction) NOT detected; got {res}")
        else:
            print("  ok    [Mutation Ordering iOS] operations out of order detected")

    # Missing file detection test
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        m = scan(root)
        if not m:
            failures.append("empty tree (no control files) did not report any missing control")
        if not any("file MISSING" in line for line in m):
            failures.append("missing files were not labelled 'file MISSING'")

    if failures:
        print("check_store_schema_controls selftest FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("check_store_schema_controls selftest PASSED:\n"
          "  - All markers present passed.\n"
          "  - Mutation A (Android no inTransaction) detected.\n"
          "  - Mutation B (Android no deleteHeld) detected.\n"
          "  - Mutation C (Android no execDeliveryUpdate) detected.\n"
          "  - Mutation D (iOS no atomic routing) detected.\n"
          "  - Mutation E (iOS no withTransaction) detected.\n"
          "  - Mutation F (iOS no deleteHeldSql) detected.\n"
          "  - Mutation G (state-only acknowledgeBound) detected.\n"
          "  - Mutation Ordering Android (deleteHeld before execDeliveryUpdate) detected.\n"
          "  - Mutation Ordering iOS (deleteHeldSql outside withTransaction) detected.\n"
          "  - Missing files reported.")
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