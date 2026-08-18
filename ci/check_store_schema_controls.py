#!/usr/bin/env python3
"""C6.4.1 / C6.6 / C7.4 / C7.4.1 / C7.4.2 / C7.4.3 / C7.5 / C7.5.1 gate: schema, persist, and atomic ACK/terminal-retirement controls MUST exist.

A GATE: it fails (exit 1) iff a C6.4.1/C6.6/C7.4/C7.4.1/C7.4.2/C7.4.3/C7.5/C7.5.1 schema, persistence,
or atomic ACK/terminal-retirement fail-closed negative control is MISSING from the test sources
or if the brace-balanced lexical function/closure-region structural invariants are violated.

Structural checks enforce:
  1. Android MeshNode.dispatchDirect transports canonicalFrame, never frame directly.
  2. iOS MeshNode.dispatchDirect transports canonicalFrame, never frame directly.
  3. DeliveryTracker on both platforms forbids state-only acknowledgeBound.
  4. Android SqliteDeliveryRepository.acknowledgeBoundAndRetire executes db.inTransaction,
     and inside that transaction closure executes execDeliveryUpdate and deleteHeld in
     strictly ordered succession.
  5. iOS SqliteDeliveryRepository.acknowledgeBoundAndRetire must exist and route to
     atomicAcknowledgeAndRetire (either directly or via explicit helper hop). Stale helper
     fallbacks and comment-only decoys are rejected.
  6. iOS SqliteMessageStore.atomicAcknowledgeAndRetireWithFault executes withTransaction,
     and inside that transaction closure consumes guardedAckSql via sqlite3_prepare_v2
     and executes StoreSchema.deleteHeldSql in strictly ordered succession.
  7. Android SqliteDeliveryRepository.executeRetiringTransition executes db.inTransaction,
     and inside that transaction closure executes execDeliveryUpdate and deleteHeld in
     strictly ordered succession; executeStateOnlyTransition must NOT call deleteHeld.
  8. iOS SqliteDeliveryRepository.transitionWithFault routes .retireAtomically to
     atomicTransitionAndRetire / atomicTransitionAndRetireWithFault.
  9. iOS SqliteMessageStore.atomicTransitionAndRetireWithFault executes withTransaction,
     and inside that transaction closure consumes guardedTransitionSql via sqlite3_prepare_v2
     and executes StoreSchema.deleteHeldSql in strictly ordered succession.

Usage:
    python3 ci/check_store_schema_controls.py [--root DIR] [--selftest]
"""
from __future__ import annotations

import argparse
import re
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
    # --- Android: C7.5 terminal transition and held retirement controls ---
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 production queued C6_6 to EXPIRE success",
     "Android C7.5 production queued to EXPIRE success"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 production handed C6_6 to EXPIRE success",
     "Android C7.5 production handed to EXPIRE success"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 production queued C6_6 to CANCEL success",
     "Android C7.5 production queued to CANCEL success"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 production handed C6_6 to CANCEL success",
     "Android C7.5 production handed to CANCEL success"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 MARK_HANDED retains held frame",
     "Android C7.5 MARK_HANDED retains held frame"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 missing-held active row rollback and Corrupt on EXPIRE",
     "Android C7.5 missing-held rollback on EXPIRE"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 missing-held active row rollback and Corrupt on CANCEL",
     "Android C7.5 missing-held rollback on CANCEL"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 fault after terminal CAS both restored",
     "Android C7.5 fault after terminal CAS restored"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 fault after held DELETE both restored",
     "Android C7.5 fault after held DELETE restored"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 held delete SQL failure",
     "Android C7.5 held delete SQL failure"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 ACK committed then CANCEL zero-row classification",
     "Android C7.5 ACK committed then CANCEL zero-row classification"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 ACK committed then EXPIRE zero-row classification",
     "Android C7.5 ACK committed then EXPIRE zero-row classification"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 ACK wins concurrent in-flight CANCEL",
     "Android C7.5 ACK wins concurrent in-flight CANCEL"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 ACK wins concurrent in-flight EXPIRE",
     "Android C7.5 ACK wins concurrent in-flight EXPIRE"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 CANCEL wins ACK loses",
     "Android C7.5 CANCEL wins ACK loses"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 EXPIRE wins ACK loses",
     "Android C7.5 EXPIRE wins ACK loses"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 CANCEL vs EXPIRE",
     "Android C7.5 CANCEL vs EXPIRE"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 anti-entropy excludes retired terminal frame",
     "Android C7.5 anti-entropy excludes retired terminal frame"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 capacity released on EXPIRE",
     "Android C7.5 capacity released on EXPIRE"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 capacity released on CANCEL",
     "Android C7.5 capacity released on CANCEL"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 AckMode NONE terminal retirement",
     "Android C7.5 AckMode NONE terminal retirement"),
    ("android/mesh/src/test/java/io/godstone/mesh/delivery/SqliteDeliveryRepositoryTest.kt",
     "C7_5 transition disposition policy",
     "Android C7.5 transition disposition policy"),
    # --- iOS: C7.5 terminal transition and held retirement controls ---
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_production_queued_C6_6_to_EXPIRE_success",
     "iOS C7.5 production queued to EXPIRE success"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_production_handed_C6_6_to_EXPIRE_success",
     "iOS C7.5 production handed to EXPIRE success"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_production_queued_C6_6_to_CANCEL_success",
     "iOS C7.5 production queued to CANCEL success"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_production_handed_C6_6_to_CANCEL_success",
     "iOS C7.5 production handed to CANCEL success"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_MARK_HANDED_retains_held_frame",
     "iOS C7.5 MARK_HANDED retains held frame"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_missing_held_active_row_rollback_and_Corrupt_on_EXPIRE",
     "iOS C7.5 missing-held rollback on EXPIRE"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_missing_held_active_row_rollback_and_Corrupt_on_CANCEL",
     "iOS C7.5 missing-held rollback on CANCEL"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_fault_after_terminal_CAS_both_restored",
     "iOS C7.5 fault after terminal CAS restored"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_fault_after_held_DELETE_both_restored",
     "iOS C7.5 fault after held DELETE restored"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_held_delete_SQL_failure",
     "iOS C7.5 held delete SQL failure"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_ACK_committed_then_CANCEL_zero_row_classification",
     "iOS C7.5 ACK committed then CANCEL zero-row classification"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_ACK_committed_then_EXPIRE_zero_row_classification",
     "iOS C7.5 ACK committed then EXPIRE zero-row classification"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_ACK_wins_concurrent_in_flight_CANCEL",
     "iOS C7.5 ACK wins concurrent in-flight CANCEL"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_ACK_wins_concurrent_in_flight_EXPIRE",
     "iOS C7.5 ACK wins concurrent in-flight EXPIRE"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_CANCEL_wins_ACK_loses",
     "iOS C7.5 CANCEL wins ACK loses"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_EXPIRE_wins_ACK_loses",
     "iOS C7.5 EXPIRE wins ACK loses"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_CANCEL_vs_EXPIRE",
     "iOS C7.5 CANCEL vs EXPIRE"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_anti_entropy_excludes_retired_terminal_frame",
     "iOS C7.5 anti-entropy excludes retired terminal frame"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_capacity_released_on_EXPIRE",
     "iOS C7.5 capacity released on EXPIRE"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_capacity_released_on_CANCEL",
     "iOS C7.5 capacity released on CANCEL"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_AckMode_NONE_terminal_retirement",
     "iOS C7.5 AckMode NONE terminal retirement"),
    ("ios/Godstone/Tests/GodstoneMeshTests/SqliteDeliveryRepositoryTests.swift",
     "testC7_5_transition_disposition_policy",
     "iOS C7.5 transition disposition policy"),
]


def strip_comments(text: str) -> str:
    """Strip line and block comments from text while preserving string literals and newlines."""
    out: list[str] = []
    i = 0
    in_line_comment = False
    in_block_comment = False
    in_string = False
    escape = False
    while i < len(text):
        c = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_line_comment:
            if c == "\n":
                in_line_comment = False
                out.append("\n")
        elif in_block_comment:
            if c == "*" and nxt == "/":
                in_block_comment = False
                i += 1
        elif in_string:
            out.append(c)
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
                out.append(c)
            else:
                out.append(c)
        i += 1
    return "".join(out)


def extract_braced_function(text: str, signature: str) -> str | None:
    """Extract the complete region of a function starting with `signature` up to its matching closing brace."""
    idx = text.find(signature)
    if idx == -1:
        return None
    brace_start = text.find("{", idx + len(signature))
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


def extract_braced_region_after(text: str, token: str) -> str | None:
    """Extract the balanced { ... } closure region immediately following `token` in `text`."""
    idx = text.find(token)
    if idx == -1:
        return None
    brace_start = text.find("{", idx + len(token))
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
                    return text[brace_start : i + 1]
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
            clean_fn = strip_comments(fn_body)
            if "canonicalFrame.encode()" not in clean_fn:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt: dispatchDirect must encode canonicalFrame")
            if "frame.encode()" in clean_fn:
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
            clean_fn = strip_comments(fn_body)
            if "send(canonicalFrame, peer)" not in clean_fn:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: dispatchDirect must transport canonicalFrame")
            if "send(frame," in clean_fn:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MeshNode.swift: dispatchDirect must not transport frame directly")

    # 3. Structural check: DeliveryTracker on both platforms must NOT expose state-only acknowledgeBound
    android_delivery_tracker = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt"
    if not android_delivery_tracker.is_file():
        missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/DeliveryTracker.kt: file MISSING")
    else:
        text = android_delivery_tracker.read_text(encoding="utf-8", errors="replace")
        clean_text = strip_comments(text)
        if "fun acknowledgeBound(" in clean_text:
            missing.append("android DeliveryTracker must not expose state-only acknowledgeBound (must use acknowledgeBoundAndRetire)")

    ios_delivery_tracker = root / "ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift"
    if not ios_delivery_tracker.is_file():
        missing.append("ios/Godstone/Sources/GodstoneMesh/DeliveryTracker.swift: file MISSING")
    else:
        text = ios_delivery_tracker.read_text(encoding="utf-8", errors="replace")
        clean_text = strip_comments(text)
        if "func acknowledgeBound(" in clean_text:
            missing.append("iOS DeliveryTracker must not expose state-only acknowledgeBound (must use acknowledgeBoundAndRetire)")

    # 4. Structural check: Android SqliteDeliveryRepository acknowledgeBoundAndRetire region + transaction closure containment
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
            tx_closure = extract_braced_region_after(fn_body, "inTransaction")
            if tx_closure is None:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire must execute inside inTransaction closure")
            else:
                clean_tx = strip_comments(tx_closure)
                pos_upd = clean_tx.find("execDeliveryUpdate")
                pos_del = clean_tx.find("deleteHeld")

                if pos_upd == -1:
                    missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire must call execDeliveryUpdate inside inTransaction closure")
                if pos_del == -1:
                    missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire must call deleteHeld inside inTransaction closure")

                if pos_upd != -1 and pos_del != -1:
                    if not (pos_upd < pos_del):
                        missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: acknowledgeBoundAndRetire operations out of order (require execDeliveryUpdate before deleteHeld inside inTransaction closure)")

    # 5. Structural check: iOS SqliteDeliveryRepository acknowledgeBoundAndRetire region routes to atomicAcknowledgeAndRetire
    ios_sqlite_repo = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
    if not ios_sqlite_repo.is_file():
        missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: file MISSING")
    else:
        text = ios_sqlite_repo.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "func acknowledgeBoundAndRetire(")
        if fn_body is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: acknowledgeBoundAndRetire missing or unextractable")
        else:
            clean_fn = strip_comments(fn_body)
            routes_to_atomic = False

            # Shape A: Direct route
            if ".atomicAcknowledgeAndRetire(" in clean_fn or "store.atomicAcknowledgeAndRetire(" in clean_fn:
                routes_to_atomic = True
            # Shape B: Explicit helper hop
            elif "acknowledgeBoundAndRetireWithFault(" in clean_fn:
                fn_fault = extract_braced_function(text, "func acknowledgeBoundAndRetireWithFault(")
                if fn_fault is not None:
                    clean_fault = strip_comments(fn_fault)
                    if (
                        ".atomicAcknowledgeAndRetire(" in clean_fault
                        or "store.atomicAcknowledgeAndRetire(" in clean_fault
                        or "sms.atomicAcknowledgeAndRetireWithFault(" in clean_fault
                        or "atomicAcknowledgeAndRetire(" in clean_fault
                    ):
                        routes_to_atomic = True

            if not routes_to_atomic:
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: acknowledgeBoundAndRetire must route through atomicAcknowledgeAndRetire")

    # 6. Structural check: iOS MessageStore atomicAcknowledgeAndRetireWithFault region + withTransaction closure containment
    ios_message_store = root / "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"
    if not ios_message_store.is_file():
        missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: file MISSING")
    else:
        text = ios_message_store.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "func atomicAcknowledgeAndRetireWithFault(")
        if fn_body is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault missing or unextractable")
        else:
            tx_closure = extract_braced_region_after(fn_body, "withTransaction")
            if tx_closure is None:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault must execute inside withTransaction closure")
            else:
                clean_tx = strip_comments(tx_closure)
                prep_match = re.search(r"sqlite3_prepare_v2\s*\(\s*db\s*,\s*guardedAckSql\b", clean_tx)
                pos_del = clean_tx.find("StoreSchema.deleteHeldSql")
                if pos_del == -1:
                    pos_del = clean_tx.find("deleteHeldSql")

                if not prep_match:
                    missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: guardedAckSql must be prepared via sqlite3_prepare_v2 inside withTransaction closure")
                if pos_del == -1:
                    missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault must use StoreSchema.deleteHeldSql inside withTransaction closure")

                if prep_match and pos_del != -1:
                    if not (prep_match.start() < pos_del):
                        missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicAcknowledgeAndRetireWithFault operations out of order (require guardedAckSql preparation before deleteHeldSql inside withTransaction closure)")

    # 7. Structural check: Android SqliteDeliveryRepository executeRetiringTransition + executeStateOnlyTransition
    if android_sqlite_repo.is_file():
        text = android_sqlite_repo.read_text(encoding="utf-8", errors="replace")
        fn_retire = extract_braced_function(text, "private fun executeRetiringTransition(")
        if fn_retire is None:
            fn_retire = extract_braced_function(text, "fun executeRetiringTransition(")
        if fn_retire is None:
            missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: executeRetiringTransition missing or unextractable")
        else:
            tx_closure = extract_braced_region_after(fn_retire, "inTransaction")
            if tx_closure is None:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: executeRetiringTransition must execute inside inTransaction closure")
            else:
                clean_tx = strip_comments(tx_closure)
                pos_upd = clean_tx.find("execDeliveryUpdate")
                pos_del = clean_tx.find("deleteHeld")
                if pos_upd == -1:
                    missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: executeRetiringTransition must call execDeliveryUpdate inside inTransaction closure")
                if pos_del == -1:
                    missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: executeRetiringTransition must call deleteHeld inside inTransaction closure")
                if pos_upd != -1 and pos_del != -1:
                    if not (pos_upd < pos_del):
                        missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: executeRetiringTransition operations out of order (require execDeliveryUpdate before deleteHeld inside inTransaction closure)")

        fn_state_only = extract_braced_function(text, "private fun executeStateOnlyTransition(")
        if fn_state_only is None:
            fn_state_only = extract_braced_function(text, "fun executeStateOnlyTransition(")
        if fn_state_only is None:
            missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: executeStateOnlyTransition missing or unextractable")
        else:
            clean_so = strip_comments(fn_state_only)
            if "deleteHeld" in clean_so:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: executeStateOnlyTransition must not call deleteHeld")

    # 8. Structural check: iOS SqliteDeliveryRepository transition routes .retireAtomically to atomicTransitionAndRetire and .retain to execDeliveryUpdate
    if ios_sqlite_repo.is_file():
        text = ios_sqlite_repo.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "func transitionWithFault(")
        if fn_body is None:
            fn_body = extract_braced_function(text, "public func transition(")
        if fn_body is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionWithFault missing or unextractable")
        else:
            clean_fn = strip_comments(fn_body)
            if "switch spec.heldDisposition" not in clean_fn and "switch disposition" not in clean_fn:
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionWithFault must switch on spec.heldDisposition")
            else:
                retain_matches = list(re.finditer(r"case\s+\.retain\s*:", clean_fn))
                retire_matches = list(re.finditer(r"case\s+\.retireAtomically\s*:", clean_fn))
                if len(retain_matches) != 1 or len(retire_matches) != 1:
                    missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionWithFault switch must contain exactly one 'case .retain:' and one 'case .retireAtomically:'")
                else:
                    retain_start = retain_matches[0].start()
                    retire_start = retire_matches[0].start()
                    if retain_start < retire_start:
                        retain_region = clean_fn[retain_start:retire_start]
                        retire_region = clean_fn[retire_start:]
                    else:
                        retire_region = clean_fn[retire_start:retain_start]
                        retain_region = clean_fn[retain_start:]

                    if "atomicTransitionAndRetire(" in retain_region or "atomicTransitionAndRetireWithFault(" in retain_region:
                        missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: retain region must not call atomicTransitionAndRetire")
                    if "execDeliveryUpdate" not in retain_region:
                        missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: retain region must call execDeliveryUpdate")
                    if not (
                        ".atomicTransitionAndRetire(" in retire_region
                        or "store.atomicTransitionAndRetire(" in retire_region
                        or "sms.atomicTransitionAndRetireWithFault(" in retire_region
                        or "atomicTransitionAndRetire(" in retire_region
                    ):
                        missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: retireAtomically region must route through atomicTransitionAndRetire")

    # 9. Structural check: iOS MessageStore atomicTransitionAndRetireWithFault region + withTransaction closure containment
    if ios_message_store.is_file():
        text = ios_message_store.read_text(encoding="utf-8", errors="replace")
        fn_body = extract_braced_function(text, "func atomicTransitionAndRetireWithFault(")
        if fn_body is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicTransitionAndRetireWithFault missing or unextractable")
        else:
            tx_closure = extract_braced_region_after(fn_body, "withTransaction")
            if tx_closure is None:
                missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicTransitionAndRetireWithFault must execute inside withTransaction closure")
            else:
                clean_tx = strip_comments(tx_closure)
                prep_match = re.search(r"sqlite3_prepare_v2\s*\(\s*db\s*,\s*guardedTransitionSql\b", clean_tx)
                pos_del = clean_tx.find("StoreSchema.deleteHeldSql")
                if pos_del == -1:
                    pos_del = clean_tx.find("deleteHeldSql")

                if not prep_match:
                    missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: guardedTransitionSql must be prepared via sqlite3_prepare_v2 inside withTransaction closure")
                if pos_del == -1:
                    missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicTransitionAndRetireWithFault must use StoreSchema.deleteHeldSql inside withTransaction closure")

                if prep_match and pos_del != -1:
                    if not (prep_match.start() < pos_del):
                        missing.append("ios/Godstone/Sources/GodstoneMesh/MessageStore.swift: atomicTransitionAndRetireWithFault operations out of order (require guardedTransitionSql preparation before deleteHeldSql inside withTransaction closure)")

    # 10. Structural check: Android transitionSpec explicit policy
    if android_sqlite_repo.is_file():
        text = android_sqlite_repo.read_text(encoding="utf-8", errors="replace")
        fn_ts = extract_braced_region_after(text, "fun transitionSpec(")
        if fn_ts is None:
            fn_ts = extract_braced_function(text, "fun transitionSpec(")
        if fn_ts is None:
            missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: transitionSpec missing or unextractable")
        else:
            clean_ts = strip_comments(fn_ts)
            if "when (transition)" not in text and "when(transition)" not in text:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: transitionSpec must use when (transition)")
            if "else ->" in clean_ts:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: transitionSpec must be exhaustive without else ->")
            if "DeliveryTransition.MARK_HANDED" not in clean_ts or "HeldDisposition.RETAIN" not in clean_ts:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: transitionSpec must map MARK_HANDED to RETAIN")
            if "DeliveryTransition.EXPIRE" not in clean_ts or "HeldDisposition.RETIRE_ATOMICALLY" not in clean_ts:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: transitionSpec must map EXPIRE to RETIRE_ATOMICALLY")
            if "DeliveryTransition.CANCEL" not in clean_ts or "HeldDisposition.RETIRE_ATOMICALLY" not in clean_ts:
                missing.append("android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt: transitionSpec must map CANCEL to RETIRE_ATOMICALLY")

    # 11. Structural check: iOS transitionSpec explicit policy
    if ios_sqlite_repo.is_file():
        text = ios_sqlite_repo.read_text(encoding="utf-8", errors="replace")
        fn_ts = extract_braced_function(text, "func transitionSpec(")
        if fn_ts is None:
            missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionSpec missing or unextractable")
        else:
            clean_ts = strip_comments(fn_ts)
            if "switch transition" not in clean_ts:
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionSpec must use switch transition")
            if "default:" in clean_ts:
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionSpec must be exhaustive without default:")
            m_mark = re.search(r"case\s+\.markHanded\s*:(.*?)(case|\})", clean_ts, re.DOTALL)
            m_exp = re.search(r"case\s+\.expire\s*:(.*?)(case|\})", clean_ts, re.DOTALL)
            m_can = re.search(r"case\s+\.cancel\s*:(.*?)(case|\})", clean_ts, re.DOTALL)
            if not m_mark or ".retain" not in m_mark.group(1):
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionSpec must map .markHanded to .retain")
            if not m_exp or ".retireAtomically" not in m_exp.group(1):
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionSpec must map .expire to .retireAtomically")
            if not m_can or ".retireAtomically" not in m_can.group(1):
                missing.append("ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift: transitionSpec must map .cancel to .retireAtomically")

    return missing


def run_gate(root: Path) -> int:
    missing = scan(root)
    if missing:
        print("STORE-SCHEMA-CONTROLS GATE: FAIL -- a C6.4.1/C6.6/C7.4/C7.4.1/C7.4.2/C7.4.3/C7.5/C7.5.1 schema/persist/atomic-ACK "
              "fail-closed control is MISSING from the test sources:")
        for m in missing:
            print("  - " + m)
        print("A test or structural invariant that has been silently removed is a regression. "
              "Restore the named control or update ci/check_store_schema_controls.py "
              "deliberately (and record why).")
        print("(A-03 / A-04 / A-10 / ADR-003 / ADR-004 / ADR-005 remain OPEN: this is "
              "repo-owned evidence, not device evidence.)")
        return 1
    print(f"STORE-SCHEMA-CONTROLS GATE: PASS -- all {len(CONTROLS)} C6.4.1/C6.6/C7.4/C7.4.1/C7.4.2/C7.4.3/C7.5/C7.5.1 "
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
        "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
        "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
        "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
        "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
        "}\n"
        "class SqliteDeliveryRepository {\n"
        "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
        "        return db.inTransaction { tx ->\n"
        "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
        "            val deleted = tx.deleteHeld(msgId)\n"
        "            AckRetireResult.APPLIED\n"
        "        }\n"
        "    }\n"
        "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
        "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
        "        return TransitionResult.Applied\n"
        "    }\n"
        "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
        "        return db.inTransaction { tx ->\n"
        "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
        "            val deleted = tx.deleteHeld(msgId)\n"
        "            CrossTableRetireResult.APPLIED\n"
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
        "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
        "        switch transition {\n"
        "        case .markHanded:\n"
        "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
        "        case .expire:\n"
        "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
        "        case .cancel:\n"
        "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
        "        }\n"
        "    }\n"
        "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
        "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
        "    }\n"
        "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
        "        switch spec.heldDisposition {\n"
        "        case .retain:\n"
        "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
        "            return .applied\n"
        "        case .retireAtomically:\n"
        "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
        "        }\n"
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
        "    internal func atomicTransitionAndRetireWithFault(\n"
        "        guardedTransitionSql: String,\n"
        "        msgId: Data,\n"
        "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
        "    ) throws -> TerminalRetireMutationResult {\n"
        "        return try withTransaction { db in\n"
        "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
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
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "        val deleted = tx.deleteHeld(msgId)\n"
            "        return AckResult.Applied\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    fun decoyElsewhere() {\n"
            "        db.inTransaction { }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must execute inside inTransaction closure" in m for m in res):
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
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    fun decoyElsewhere() {\n"
            "        tx.deleteHeld(msgId)\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must call deleteHeld inside inTransaction closure" in m for m in res):
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
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    fun decoyElsewhere() {\n"
            "        tx.execDeliveryUpdate(sql, bindArgs)\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must call execDeliveryUpdate inside inTransaction closure" in m for m in res):
            failures.append(f"Mutation C (Android execDeliveryUpdate removal with decoy) NOT detected; got {res}")
        else:
            print("  ok    [Mutation C] Android execDeliveryUpdate removal with decoy detected")

    # D1: Direct Route Positive
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if res:
            failures.append(f"D1 (Direct route positive) failed unexpectedly: {res}")
        else:
            print("  ok    [D1 Direct Positive] direct route recognized (PASS)")

    # D2: Helper Route Positive
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        acknowledgeBoundAndRetireWithFault(msgId, expectedRecipient: expectedRecipient, fault: nil)\n"
            "    }\n"
            "    internal func acknowledgeBoundAndRetireWithFault(_ msgId: Data, expectedRecipient: Data, fault: Any?) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if res:
            failures.append(f"D2 (Helper route positive) failed unexpectedly: {res}")
        else:
            print("  ok    [D2 Helper Positive] explicit helper hop recognized (PASS)")

    # D3: Stale Helper Bypass (production returns .applied directly, helper still calls atomic)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return .applied\n"
            "    }\n"
            "    internal func acknowledgeBoundAndRetireWithFault(_ msgId: Data, expectedRecipient: Data, fault: Any?) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must route through atomicAcknowledgeAndRetire" in m for m in res):
            failures.append(f"D3 (Stale helper bypass) NOT detected; got {res}")
        else:
            print("  ok    [D3 Stale Helper] stale helper bypass detected")

    # D4: Production Function Missing (only helper exists)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    internal func acknowledgeBoundAndRetireWithFault(_ msgId: Data, expectedRecipient: Data, fault: Any?) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire missing or unextractable" in m for m in res):
            failures.append(f"D4 (Production function missing) NOT detected; got {res}")
        else:
            print("  ok    [D4 Function Missing] missing production function detected")

    # D5: Comment-only Decoy in Main Function
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        // store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "        return .applied\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must route through atomicAcknowledgeAndRetire" in m for m in res):
            failures.append(f"D5 (Comment-only decoy route) NOT detected; got {res}")
        else:
            print("  ok    [D5 Comment Decoy] comment-only decoy route detected")

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
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "    func decoyElsewhere() {\n"
            "        withTransaction { _ in }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicAcknowledgeAndRetireWithFault must execute inside withTransaction closure" in m for m in res):
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
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
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
        if not any("atomicAcknowledgeAndRetireWithFault must use StoreSchema.deleteHeldSql inside withTransaction closure" in m for m in res):
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

    # Android Closure Mutation: Operations after transaction closure
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        db.inTransaction { tx ->\n"
            "            // empty transaction\n"
            "        }\n"
            "        db.execDeliveryUpdate(sql, bindArgs)\n"
            "        db.deleteHeld(msgId)\n"
            "        return AckResult.Applied\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire must call execDeliveryUpdate inside inTransaction closure" in m for m in res):
            failures.append(f"Android operations after transaction NOT detected; got {res}")
        else:
            print("  ok    [Android Closure] operations after transaction closure detected")

    # Android Ordering Mutation: deleteHeld before execDeliveryUpdate inside closure
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("acknowledgeBoundAndRetire operations out of order" in m for m in res):
            failures.append(f"Android ordering mutation NOT detected; got {res}")
        else:
            print("  ok    [Android Ordering] operations out of order inside closure detected")

    # iOS Closure Mutation: deleteHeldSql after withTransaction closure
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
            "        try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedAckSql, -1, &stmt, nil)\n"
            "        }\n"
            "        let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "        return .applied\n"
            "    }\n"
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicAcknowledgeAndRetireWithFault must use StoreSchema.deleteHeldSql inside withTransaction closure" in m for m in res):
            failures.append(f"iOS delete after transaction closure NOT detected; got {res}")
        else:
            print("  ok    [iOS Closure] deleteHeldSql after withTransaction closure detected")

    # iOS guardedAckSql Decoy / Comment-only
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
            "            // sqlite3_prepare_v2(db, guardedAckSql, -1, &stmt, nil)\n"
            "            let note = \"guardedAckSql\"\n"
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("guardedAckSql must be prepared via sqlite3_prepare_v2 inside withTransaction closure" in m for m in res):
            failures.append(f"iOS guardedAckSql decoy/comment NOT detected; got {res}")
        else:
            print("  ok    [iOS Guarded SQL Decoy] comment-only/string decoy for guardedAckSql detected")

    # iOS Ordering Mutation: deleteHeldSql before guardedAckSql preparation inside closure
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
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, guardedAckSql, -1, &stmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicAcknowledgeAndRetireWithFault operations out of order" in m for m in res):
            failures.append(f"iOS ordering mutation inside closure NOT detected; got {res}")
        else:
            print("  ok    [iOS Ordering] operations out of order inside closure detected")

    # --- C7.5.1 Mutations ---------------------------------------------
    # Mutation H1: Android Retiring Transition Transaction Removal
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        val deleted = tx.deleteHeld(msgId)\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("executeRetiringTransition must execute inside inTransaction closure" in m for m in res):
            failures.append(f"Mutation H1 (Android retiring transition without inTransaction) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H1] Android retiring transition without inTransaction detected")

    # Mutation H2: Android Retiring Transition Delete Removal
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("executeRetiringTransition must call deleteHeld inside inTransaction closure" in m for m in res):
            failures.append(f"Mutation H2 (Android retiring transition without deleteHeld) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H2] Android retiring transition without deleteHeld detected")

    # Mutation H3: Android State-Only Transition Leak
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETAIN)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        db.deleteHeld(msgId)\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("executeStateOnlyTransition must not call deleteHeld" in m for m in res):
            failures.append(f"Mutation H3 (Android state-only transition calling deleteHeld) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H3] Android state-only transition calling deleteHeld detected")

    # Mutation H4: iOS Transition Repository Route Bypass
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        return .applied\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("transitionWithFault must switch on spec.heldDisposition" in m for m in res):
            failures.append(f"Mutation H4 (iOS transition not routing to atomic) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H4] iOS transition not routing to atomic detected")

    # Mutation H5: iOS MessageStore atomicTransitionAndRetireWithFault Transaction Removal
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
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "        let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "        sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "        return .applied\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicTransitionAndRetireWithFault must execute inside withTransaction closure" in m for m in res):
            failures.append(f"Mutation H5 (iOS atomicTransition without withTransaction) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H5] iOS atomicTransition without withTransaction detected")

    # Mutation H6: iOS MessageStore atomicTransitionAndRetireWithFault Delete Removal
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
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicTransitionAndRetireWithFault must use StoreSchema.deleteHeldSql inside withTransaction closure" in m for m in res):
            failures.append(f"Mutation H6 (iOS atomicTransition without deleteHeldSql) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H6] iOS atomicTransition without deleteHeldSql detected")

    # Mutation H7: iOS MessageStore atomicTransitionAndRetireWithFault Ordering Violation
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
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, deleteHeldSql, -1, &delStmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "    internal func atomicTransitionAndRetireWithFault(\n"
            "        guardedTransitionSql: String,\n"
            "        msgId: Data,\n"
            "        fault: ((String, OpaquePointer) throws -> Void)? = nil\n"
            "    ) throws -> TerminalRetireMutationResult {\n"
            "        return try withTransaction { db in\n"
            "            let deleteHeldSql = StoreSchema.deleteHeldSql\n"
            "            sqlite3_prepare_v2(db, guardedTransitionSql, -1, &stmt, nil)\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("atomicTransitionAndRetireWithFault operations out of order" in m for m in res):
            failures.append(f"Mutation H7 (iOS atomicTransition ordering mutation) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H7] iOS atomicTransition ordering mutation inside closure detected")

    # Mutation H8: iOS RETAIN incorrectly routes atomic
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("retain region must not call atomicTransitionAndRetire" in m for m in res):
            failures.append(f"Mutation H8 (iOS retain calling atomic) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H8] iOS retain calling atomic detected")

    # Mutation H9: iOS atomic decoy outside case
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        let decoy = store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return .applied\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("retireAtomically region must route through atomicTransitionAndRetire" in m for m in res):
            failures.append(f"Mutation H9 (iOS atomic decoy outside case) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H9] iOS atomic decoy outside case detected")

    # Mutation H10: iOS retain loses guarded state-only update
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retain)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("retain region must call execDeliveryUpdate" in m for m in res):
            failures.append(f"Mutation H10 (iOS retain without execDeliveryUpdate) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H10] iOS retain without execDeliveryUpdate detected")

    # Mutation H11: Android transitionSpec MARK_HANDED mutated to RETIRE_ATOMICALLY
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        android_sdr = root / "android/mesh/src/main/java/io/godstone/mesh/delivery/SqliteDeliveryRepository.kt"
        android_sdr.write_text(
            "package io.godstone.mesh.delivery\n"
            "internal fun transitionSpec(transition: DeliveryTransition): TransitionSpec = when (transition) {\n"
            "    DeliveryTransition.MARK_HANDED -> TransitionSpec(target = DeliveryState.HANDED_TO_RELAY, validFroms = setOf(DeliveryState.QUEUED_DURABLY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.EXPIRE -> TransitionSpec(target = DeliveryState.EXPIRED, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "    DeliveryTransition.CANCEL -> TransitionSpec(target = DeliveryState.CANCELLED_LOCALLY, validFroms = setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), heldDisposition = HeldDisposition.RETIRE_ATOMICALLY)\n"
            "}\n"
            "class SqliteDeliveryRepository {\n"
            "    override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, bindArgs)\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            AckRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "    private fun executeStateOnlyTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "        return TransitionResult.Applied\n"
            "    }\n"
            "    private fun executeRetiringTransition(msgId: ByteArray, target: DeliveryState, validFroms: Set<DeliveryState>): TransitionResult {\n"
            "        return db.inTransaction { tx ->\n"
            "            val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))\n"
            "            val deleted = tx.deleteHeld(msgId)\n"
            "            CrossTableRetireResult.APPLIED\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("transitionSpec must map MARK_HANDED to RETAIN" in m for m in res):
            failures.append(f"Mutation H11 (Android transitionSpec MARK_HANDED mutation) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H11] Android transitionSpec MARK_HANDED mutation detected")

    # Mutation H12: iOS transitionSpec .markHanded mutated to .retireAtomically
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        _build_synthetic_positive_tree(root)
        ios_sdr = root / "ios/Godstone/Sources/GodstoneMesh/SqliteDeliveryRepository.swift"
        ios_sdr.write_text(
            "public class SqliteDeliveryRepository {\n"
            "    internal func transitionSpec(_ transition: DeliveryTransition) -> TransitionSpec {\n"
            "        switch transition {\n"
            "        case .markHanded:\n"
            "            return TransitionSpec(target: .handedToRelay, validFroms: [.queuedDurably], heldDisposition: .retireAtomically)\n"
            "        case .expire:\n"
            "            return TransitionSpec(target: .expired, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        case .cancel:\n"
            "            return TransitionSpec(target: .cancelledLocally, validFroms: [.queuedDurably, .handedToRelay], heldDisposition: .retireAtomically)\n"
            "        }\n"
            "    }\n"
            "    public func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {\n"
            "        return try store.atomicAcknowledgeAndRetire(guardedAckSql: sql, msgId: msgId, expectedRecipient: expectedRecipient)\n"
            "    }\n"
            "    internal func transitionWithFault(_ msgId: Data, _ transition: DeliveryTransition, fault: ((String, OpaquePointer) throws -> Void)? = nil) -> TransitionResult {\n"
            "        switch spec.heldDisposition {\n"
            "        case .retain:\n"
            "            let affected = try store.execDeliveryUpdate(sql, bytesArgs: [msgId])\n"
            "            return .applied\n"
            "        case .retireAtomically:\n"
            "            return try store.atomicTransitionAndRetire(guardedTransitionSql: sql, msgId: msgId)\n"
            "        }\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        res = scan(root)
        if not any("transitionSpec must map .markHanded to .retain" in m for m in res):
            failures.append(f"Mutation H12 (iOS transitionSpec .markHanded mutation) NOT detected; got {res}")
        else:
            print("  ok    [Mutation H12] iOS transitionSpec .markHanded mutation detected")

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
          "  - D1 Direct Positive recognized.\n"
          "  - D2 Helper Positive recognized.\n"
          "  - D3 Stale Helper Bypass detected.\n"
          "  - D4 Production Function Missing detected.\n"
          "  - D5 Comment-only Route Decoy detected.\n"
          "  - Mutation E (iOS no withTransaction) detected.\n"
          "  - Mutation F (iOS no deleteHeldSql) detected.\n"
          "  - Mutation G (state-only acknowledgeBound) detected.\n"
          "  - Android Operations After Transaction Closure detected.\n"
          "  - Android Ordering (deleteHeld before execDeliveryUpdate) detected.\n"
          "  - iOS Delete After Transaction Closure detected.\n"
          "  - iOS Guarded SQL Decoy / Comment-only detected.\n"
          "  - iOS Ordering (deleteHeldSql before guardedAckSql) detected.\n"
          "  - Mutation H1 (Android retiring transition without inTransaction) detected.\n"
          "  - Mutation H2 (Android retiring transition without deleteHeld) detected.\n"
          "  - Mutation H3 (Android state-only transition calling deleteHeld) detected.\n"
          "  - Mutation H4 (iOS transition not routing to atomic) detected.\n"
          "  - Mutation H5 (iOS atomicTransition without withTransaction) detected.\n"
          "  - Mutation H6 (iOS atomicTransition without deleteHeldSql) detected.\n"
          "  - Mutation H7 (iOS atomicTransition ordering mutation) detected.\n"
          "  - Mutation H8 (iOS retain calling atomic) detected.\n"
          "  - Mutation H9 (iOS atomic decoy outside case) detected.\n"
          "  - Mutation H10 (iOS retain without execDeliveryUpdate) detected.\n"
          "  - Mutation H11 (Android transitionSpec MARK_HANDED mutation) detected.\n"
          "  - Mutation H12 (iOS transitionSpec .markHanded mutation) detected.\n"
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