import XCTest
import SQLite3
@testable import GodstoneMesh
import GodstoneCore

/// iOS durable message store -- bounded capacity + real-SQL invariants
/// (ADR-004 §1,3,4,5,6; Stage 3 Phase G).
///
/// These tests drive the REAL `SqliteMessageStore` against a REAL on-disk
/// sqlite3 engine -- the SAME engine production uses (sqlite3 is auto-linked on
/// Apple platforms; there is no SQLCipher/sqlite-jdbc seam as on Android). The
/// SQL the store runs -- schema, INSERT OR IGNORE, the window-function
/// eviction, SUM(LENGTH(payload)) byte accounting, priority ORDER BY -- is
/// byte-identical to the Android `StoreSchema`, so the invariants proven here
/// are the invariants production enforces. (At-rest encryption is a device
/// concern -- `FileProtectionType.complete` is accepted but not enforced on the
/// macOS host; the production default is pinned structurally in
/// `testFileProtectionDefaultIsComplete`.)
///
/// Every assertion is deterministic. `receivedAt` is injected through
/// `persistAt` so eviction oldest-first and priority tie-breaks do not race the
/// wall clock. Mirrors `SqliteMessageStoreTest` on Android one-for-one.
final class SqliteMessageStoreTests: XCTestCase {

    private var tmpURL: URL!
    private var store: SqliteMessageStore!

    /// Open a fresh real-sqlite3 store against a temp file with a `maxBytes` cap.
    private func open(maxBytes: Int64) -> SqliteMessageStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-store-\(UUID().uuidString).db")
        tmpURL = url
        let s = SqliteMessageStore(url: url, maxBytes: maxBytes)
        store = s
        return s
    }

    override func tearDown() {
        store = nil
        if let url = tmpURL { SqliteMessageStore.panicWipe(at: url) }
        tmpURL = nil
        super.tearDown()
    }

    private func msgId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
    }
    private let routingTag = Data([0, 1, 2, 3])

    /// A frame with `priority` (encoded into flags bits 8..10) and a
    /// `payloadSize`-byte payload.
    private func frame(_ seed: UInt8, _ priority: Priority, _ payloadSize: Int,
                       type: TypeV2 = .message) -> FrameV2 {
        FrameV2(type: type,
                msgId: msgId(seed),
                routingTag: routingTag,
                ttl: 12,
                hopCount: 0,
                flags: Priority.toFlags(priority),
                payload: Data(repeating: seed, count: payloadSize))
    }

    private func heldIds() -> [Data] { store.allHeldMsgIds() }
    private func held() -> [FrameV2] { store.allHeldOrderedByPriority() }
    private func bytes() -> Int64 { store.heldBytes }
    private func heldPriorities() -> [Priority] { held().map { Priority.fromFlags($0.flags) } }
    private func containsId(_ ids: [Data], _ id: Data) -> Bool { ids.contains(id) }

    // --- ADR-004 §1: persist + read-back preserves a frame and its fields ---

    func testPersistThenReadBackPreservesAllFields() {
        _ = open(maxBytes: Int64.max)
        let f = frame(7, .direct, 64, type: .sos)
        store.persist(f, receivedFrom: Data([0, 1, 2, 3, 4, 5]))
        let out = store.allHeldOrderedByPriority()
        XCTAssertEqual(out.count, 1)
        let r = out[0]
        XCTAssertEqual(f.type, r.type)
        XCTAssertEqual(f.msgId, r.msgId)
        XCTAssertEqual(f.routingTag, r.routingTag)
        XCTAssertEqual(f.ttl, r.ttl)
        XCTAssertEqual(f.hopCount, r.hopCount)
        XCTAssertEqual(f.flags, r.flags)
        XCTAssertEqual(f.payload, r.payload)
    }

    // --- dedup: duplicate msg_id is ignored (INSERT OR IGNORE) ---

    func testDuplicateMsgIdIsIgnored() {
        _ = open(maxBytes: Int64.max)
        let f = frame(1, .group, 32)
        store.persist(f, receivedFrom: Data())
        store.persist(f, receivedFrom: Data())
        XCTAssertEqual(heldIds().count, 1)
    }

    // --- ordering: SOS first, then priority asc, recency desc on ties ---

    func testPriorityOrderIsSosFirstThenAscendingWithRecencyTieBreak() {
        _ = open(maxBytes: Int64.max)
        // received_at injected so ties are deterministic: GROUP@t=300, GROUP@t=100
        // (newer-received first within a priority), DIRECT@t=200, SOS@t=50.
        store.persistAt(frame(1, .group, 8), receivedFrom: Data(), receivedAt: 300)
        store.persistAt(frame(2, .group, 8), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(3, .direct, 8), receivedFrom: Data(), receivedAt: 200)
        store.persistAt(frame(4, .sos, 8), receivedFrom: Data(), receivedAt: 50)
        // Expected: SOS(4), DIRECT(3), GROUP newer-first -> frame(1)@300 then frame(2)@100
        XCTAssertEqual(
            [.sos, .direct, .group, .group],
            heldPriorities())
        // The ordered frame list's msg_ids confirm the recency tie-break within
        // GROUP (newer-received frame(1)@300 before frame(2)@100).
        XCTAssertEqual(
            [msgId(4), msgId(3), msgId(1), msgId(2)],
            held().map { $0.msgId })
    }

    // --- ADR-004 §4 / A-14: eviction only when over budget ---

    func testEvictionDoesNotRunWhileUnderBudget() {
        // Cap generous enough that three small frames stay well under it.
        _ = open(maxBytes: 4096)
        store.persistAt(frame(1, .group, 64), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .group, 64), receivedFrom: Data(), receivedAt: 200)
        store.persistAt(frame(3, .group, 64), receivedFrom: Data(), receivedAt: 300)
        XCTAssertEqual(heldIds().count, 3)
        XCTAssertLessThanOrEqual(bytes(), 4096)
    }

    // --- ADR-004 §4: bounded capacity evicts oldest non-SOS first (precise) ---

    func testBoundedCapacityEvictsOldestNonSosFirstAndReturnsUnderCap() {
        // Each frame: 400-byte payload + 64-byte overhead = 464 bytes. Cap = 1024.
        // Two frames (928) fit; the third (1392) overshoots by 368, so the oldest
        // non-SOS frame (frame(1), 464 >= 368) is deleted -> 928 bytes, under cap.
        _ = open(maxBytes: 1024)
        store.persistAt(frame(1, .group, 400), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .group, 400), receivedFrom: Data(), receivedAt: 200)
        XCTAssertLessThanOrEqual(bytes(), 1024)
        store.persistAt(frame(3, .group, 400), receivedFrom: Data(), receivedAt: 300)
        // Precise byte accounting: the store is at or under the cap after eviction.
        XCTAssertLessThanOrEqual(bytes(), 1024, "over cap after eviction: \(bytes())")
        let ids = heldIds()
        XCTAssertFalse(containsId(ids, msgId(1)), "oldest non-SOS should be evicted")
        XCTAssertTrue(containsId(ids, msgId(2)))
        XCTAssertTrue(containsId(ids, msgId(3)))
        XCTAssertEqual(ids.count, 2)
    }

    func testPreciseEvictionDeletesSmallestPrefixThatMeetsOvershoot() {
        // Cap = 1024. Insert one large non-SOS frame (payload 800 -> 864) then a
        // small one (payload 100 -> 164): total 1028, overshoot = 4 bytes. The
        // oldest non-SOS prefix whose cumulative cost >= 4 is just frame(1)
        // (864 >= 4), so ONLY the large old frame is deleted -- not both. The
        // approximate row-count form could over-delete; the precise form does not.
        _ = open(maxBytes: 1024)
        store.persistAt(frame(1, .group, 800), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .broadcast, 100), receivedFrom: Data(), receivedAt: 200)
        XCTAssertLessThanOrEqual(bytes(), 1024, "over cap: \(bytes())")
        let ids = heldIds()
        XCTAssertFalse(containsId(ids, msgId(1)))
        XCTAssertTrue(containsId(ids, msgId(2)))
        XCTAssertEqual(ids.count, 1)
    }

    // --- ADR-004 §4: SOS retained under budget pressure (never evicted) ---

    func testSosFramesRetainedEvenWhenOldestRows() {
        // Cap = 1024. SOS@t=50 (464), non-SOS X@t=100 (464), non-SOS Y@t=200 (464)
        // -> 1392, overshoot 368. Oldest non-SOS is X (464 >= 368) -> deleted.
        // SOS, though oldest overall, is never considered -> retained.
        _ = open(maxBytes: 1024)
        store.persistAt(frame(1, .sos, 400), receivedFrom: Data(), receivedAt: 50)
        store.persistAt(frame(2, .group, 400), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(3, .group, 400), receivedFrom: Data(), receivedAt: 200)
        let ids = heldIds()
        XCTAssertTrue(containsId(ids, msgId(1)), "SOS must be retained")
        XCTAssertFalse(containsId(ids, msgId(2)), "oldest non-SOS evicted")
        XCTAssertTrue(containsId(ids, msgId(3)))
    }

    func testAllSosFloodingStaysInsideHardCapNewestRetained() {
        // ADR-004 criterion 4: "All-SOS flooding remains inside the configured
        // hard cap." Cap = 512; each SOS frame is 464 bytes.
        //  - after 2nd SOS: 928 > 512, overshoot 416 -> evict oldest SOS (frame1)
        //    -> 464 (frame2), under cap.
        //  - after 3rd SOS: 928 > 512, overshoot 416 -> evict oldest SOS (frame2)
        //    -> 464 (frame3), under cap.
        // SOS is evicted LAST (only because there is no non-SOS to evict), and
        // the bounded FIFO keeps the NEWEST SOS -- it never lets the backlog
        // grow past the cap.
        _ = open(maxBytes: 512)
        store.persistAt(frame(1, .sos, 400), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .sos, 400), receivedFrom: Data(), receivedAt: 200)
        store.persistAt(frame(3, .sos, 400), receivedFrom: Data(), receivedAt: 300)
        XCTAssertLessThanOrEqual(bytes(), 512, "all-SOS flooding must stay inside the cap: \(bytes())")
        let ids = heldIds()
        XCTAssertEqual(ids.count, 1, "only the newest SOS is retained under all-SOS pressure")
        XCTAssertTrue(containsId(ids, msgId(3)), "newest SOS retained")
        XCTAssertFalse(containsId(ids, msgId(1)), "oldest SOS evicted")
        XCTAssertTrue(heldPriorities().allSatisfy { $0 == .sos })
    }

    // --- A-13: streaming stops as soon as visit returns false ---

    func testForEachHeldOrderedByPriorityStopsWhenVisitReturnsFalse() {
        _ = open(maxBytes: Int64.max)
        store.persistAt(frame(1, .sos, 8), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .direct, 8), receivedFrom: Data(), receivedAt: 200)
        store.persistAt(frame(3, .group, 8), receivedFrom: Data(), receivedAt: 300)
        var seen = 0
        store.forEachHeldOrderedByPriority { _ in
            seen += 1
            return false   // stop after the first (SOS, highest priority)
        }
        XCTAssertEqual(seen, 1)
    }

    func testForEachHeldMsgIdStreamsAllIdsWhileVisitReturnsTrue() {
        _ = open(maxBytes: Int64.max)
        store.persistAt(frame(1, .group, 8), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .group, 8), receivedFrom: Data(), receivedAt: 200)
        var seen: [Data] = []
        store.forEachHeldMsgId { seen.append($0); return true }
        XCTAssertEqual(seen.count, 2)
    }

    // --- forward-compat: rows with an unknown type code are skipped, not crashed ---

    func testRowsWithUnknownTypeCodeAreSkippedNotThrown() {
        // Pre-seed the file with a row whose type code (0x77) is not a known
        // TypeV2 via a direct sqlite3 connection, then open the store over it.
        // The store must skip the row when listing frames (toFrame() -> nil) but
        // still report its msg_id (allHeldMsgIds does not type-check).
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-store-seed-\(UUID().uuidString).db")
        tmpURL = url
        seedUnknownTypeRow(at: url, msgId: msgId(9))
        // Reopen the seeded file (IF NOT EXISTS is a no-op on the existing table).
        let seeded = SqliteMessageStore(url: url, maxBytes: Int64.max)
        store = seeded
        XCTAssertEqual(seeded.allHeldOrderedByPriority().count, 0, "unknown-type row skipped")
        XCTAssertEqual(seeded.allHeldMsgIds().count, 1, "msg_id still reported")
    }

    // --- at-rest encryption intent pinned structurally (device enforces it) ---

    func testFileProtectionDefaultIsComplete() {
        // The production default for the DB file is complete data protection
        // (encrypted at rest with a device-passcode-derived key). A regression
        // to a weaker class is a test failure, not a silent weakening. The
        // macOS host accepts but does not enforce the attribute, so this pins
        // INTENT; the device verifies enforcement.
        _ = open(maxBytes: Int64.max)
        XCTAssertEqual(store.fileProtection, FileProtectionType.complete)
    }

    // MARK: - Stage 4B.1 / B2: persist means HELD AFTER cap enforcement

    func testOrdinaryFrameEvictedUnderAllSosPressureReportsRejectedCapacityAndIsAbsent() {
        // Fill the store to the cap with SOS frames. An incoming ORDINARY frame is
        // the first eviction candidate (non-SOS evicted before SOS), so it is
        // inserted then immediately evicted: persist MUST report `.rejectedCapacity`
        // (NOT `.heldNew`), the row MUST be absent, and the cap MUST remain
        // satisfied. The truthful result is what lets the router refuse to relay
        // without poisoning retry (B1).
        _ = open(maxBytes: 512)
        store.persistAt(frame(1, .sos, 400), receivedFrom: Data(), receivedAt: 100)
        XCTAssertLessThanOrEqual(bytes(), 512)
        let result = store.persistAt(frame(2, .group, 400), receivedFrom: Data(), receivedAt: 200)
        XCTAssertEqual(result, .rejectedCapacity)
        let ids = heldIds()
        XCTAssertFalse(containsId(ids, msgId(2)), "evicted ordinary frame must be absent")
        XCTAssertTrue(containsId(ids, msgId(1)), "SOS retained under pressure")
        XCTAssertLessThanOrEqual(bytes(), 512, "cap still satisfied after rejected persist")
    }

    func testNewSosUnderAllSosPressureKeepsCapSatisfiedAndNewestRetainedWithTruthfulResult() {
        // B2: "new SOS under all-SOS pressure, hard cap remains satisfied, newest
        // SOS retention deterministic, persist result exactly matches final row
        // presence." Each new SOS overshoots and evicts the oldest SOS, so the
        // NEWEST is always retained and the cap holds. The result MUST match
        // `contains`: `.heldNew` when present & new, `.heldDuplicate` when present
        // & already held, `.rejectedCapacity` when absent.
        _ = open(maxBytes: 512)
        XCTAssertEqual(.heldNew, store.persistAt(frame(1, .sos, 400), receivedFrom: Data(), receivedAt: 100))
        XCTAssertEqual(.heldNew, store.persistAt(frame(2, .sos, 400), receivedFrom: Data(), receivedAt: 200))
        XCTAssertEqual(.heldNew, store.persistAt(frame(3, .sos, 400), receivedFrom: Data(), receivedAt: 300))
        XCTAssertLessThanOrEqual(bytes(), 512, "all-SOS pressure stays inside the cap: \(bytes())")
        let ids = heldIds()
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(containsId(ids, msgId(3)), "newest SOS retained deterministically")
        XCTAssertFalse(containsId(ids, msgId(2)))
        // (a) re-offer the HELD frame3 -> row exists -> .heldDuplicate, present.
        XCTAssertEqual(.heldDuplicate, store.persistAt(frame(3, .sos, 400), receivedFrom: Data(), receivedAt: 400))
        XCTAssertTrue(containsId(heldIds(), msgId(3)))
        // (b) re-offer the evicted frame2 as the OLDEST (t=50) -> re-inserted then
        //     evicted (oldest SOS under all-SOS pressure) -> .rejectedCapacity, absent.
        XCTAssertEqual(.rejectedCapacity, store.persistAt(frame(2, .sos, 400), receivedFrom: Data(), receivedAt: 50))
        XCTAssertFalse(containsId(heldIds(), msgId(2)), "evicted frame absent -- result matches presence")
        XCTAssertTrue(containsId(heldIds(), msgId(3)), "newest SOS still retained")
    }

    func testCapacityRejectedFrameMayBeRetriedLaterAfterRoomFreed() {
        // B1+B2: a `.rejectedCapacity` persist must NOT permanently mark the id
        // seen/deduped. After room is freed (simulating delivery deleting a held
        // SOS), the SAME ordinary msg_id MUST be accepted as `.heldNew`. This is
        // the store-boundary half of "the same frame may be retried later".
        _ = open(maxBytes: 512)
        store.persistAt(frame(1, .sos, 400), receivedFrom: Data(), receivedAt: 100)
        let ordinary = frame(2, .group, 400)
        XCTAssertEqual(.rejectedCapacity, store.persistAt(ordinary, receivedFrom: Data(), receivedAt: 200))
        XCTAssertFalse(containsId(heldIds(), msgId(2)))
        // Free room: delete the SOS directly (simulates authenticated-ACK delivery).
        deleteHeldRow(msgId: msgId(1))
        XCTAssertLessThanOrEqual(bytes(), 512)
        // Retry the SAME ordinary msg_id: now there is room -> .heldNew, present.
        XCTAssertEqual(.heldNew, store.persistAt(ordinary, receivedFrom: Data(), receivedAt: 300))
        XCTAssertTrue(containsId(heldIds(), msgId(2)), "retried frame accepted after room freed")
    }

    // MARK: - Stage 4B.1 / B3: insert + eviction + final-held check is atomic

    private enum Fault: Error { case injected }

    func testFaultAfterInsertRollsBackAndReopensValidBounded() {
        // B3: a fault between insert and eviction ROLLs BACK the transaction
        // (the inserted row is NOT committed), persist reports `.failedStorage`,
        // and the store reopens valid + bounded.
        _ = open(maxBytes: 1024)
        store.persistAt(frame(1, .group, 100), receivedFrom: Data(), receivedAt: 100)
        let bytesBefore = bytes()
        let rowsBefore = heldIds().count
        let fault = { (phase: String, db: OpaquePointer?) in if phase == "after_insert" { throw Fault.injected } }
        let result = store.persistAtWithFault(frame(2, .group, 100), receivedFrom: Data(), receivedAt: 200, fault: fault)
        XCTAssertEqual(result, .failedStorage)
        XCTAssertEqual(bytes(), bytesBefore, "faulted insert rolled back -- byte total unchanged")
        XCTAssertEqual(heldIds().count, rowsBefore, "row count unchanged")
        XCTAssertFalse(containsId(heldIds(), msgId(2)))
        // Reopen over the same file: valid + bounded.
        store = nil
        _ = reopen(maxBytes: 1024)
        XCTAssertEqual(heldIds().count, rowsBefore, "store reopens valid after fault")
        XCTAssertLessThanOrEqual(bytes(), 1024, "store reopens bounded after fault")
        XCTAssertTrue(containsId(heldIds(), msgId(1)), "pre-fault row survives reopen")
    }

    func testFaultAfterEvictRollsBackAndEvictedRowsRestored() {
        // B3: a fault AFTER eviction (before the final-contains check / commit)
        // rolls back the ENTIRE transaction -- the rows the eviction deleted are
        // RESTORED and the inserted row is gone. A mid-transaction fault never
        // leaves the store in a half-evicted state.
        _ = open(maxBytes: 1024)
        store.persistAt(frame(1, .group, 400), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .group, 400), receivedFrom: Data(), receivedAt: 200)
        let bytesBefore = bytes()
        let rowsBefore = heldIds().count
        let fault = { (phase: String, db: OpaquePointer?) in if phase == "after_evict" { throw Fault.injected } }
        // A third 400-byte frame overshoots (928 -> 1392 > 1024) and triggers
        // eviction; the fault fires after eviction, before commit -> ROLLBACK.
        let result = store.persistAtWithFault(frame(3, .group, 400), receivedFrom: Data(), receivedAt: 300, fault: fault)
        XCTAssertEqual(result, .failedStorage)
        XCTAssertEqual(bytes(), bytesBefore, "evicted rows restored after rollback")
        XCTAssertEqual(heldIds().count, rowsBefore, "row count restored after rollback")
        XCTAssertTrue(containsId(heldIds(), msgId(1)))
        XCTAssertTrue(containsId(heldIds(), msgId(2)))
        XCTAssertFalse(containsId(heldIds(), msgId(3)))
    }

    func testFaultBeforeContainsRollsBackAndReopensValid() {
        // B3: the final-contains check is the last phase; faulting just before it
        // still rolls back the whole transaction (insert + any eviction).
        _ = open(maxBytes: 2048)
        store.persistAt(frame(1, .group, 100), receivedFrom: Data(), receivedAt: 100)
        let bytesBefore = bytes()
        let fault = { (phase: String, db: OpaquePointer?) in if phase == "before_contains" { throw Fault.injected } }
        let result = store.persistAtWithFault(frame(2, .group, 100), receivedFrom: Data(), receivedAt: 200, fault: fault)
        XCTAssertEqual(result, .failedStorage)
        XCTAssertEqual(bytes(), bytesBefore, "rolled back to pre-fault byte total")
        XCTAssertFalse(containsId(heldIds(), msgId(2)))
        store = nil
        _ = reopen(maxBytes: 2048)
        XCTAssertTrue(containsId(heldIds(), msgId(1)))
        XCTAssertEqual(heldIds().count, 1)
    }

    // MARK: - C6.4.1-H: strict persist helpers -- a real SQL failure rolls back

    /// C6.4.1-H: pre-H, `heldBytesNoLock` returned 0 on a SQL failure, so a
    /// storage fault in the capacity read was masked as "0 bytes stored" --
    /// eviction was skipped and an over-cap store was silently COMMITTED. The
    /// strict `heldBytesNoLockStrict` now THROWS; the throw unwinds to
    /// `withTransaction` -> ROLLBACK -> `.failedStorage`. This test injects a
    /// REAL SQL failure (drops `held_frames` at `after_insert`, before the
    /// capacity read) so `heldBytesNoLockStrict`'s prepare fails on a missing
    /// table, and proves the transaction rolls back + reopens valid (the DDL
    /// drop is rolled back too -- DDL is transactional in SQLite).
    func testHeldBytesStrictSqlFailureRollsBackAndReopensValid() {
        _ = open(maxBytes: 1024)
        store.persistAt(frame(1, .group, 100), receivedFrom: Data(), receivedAt: 100)
        let bytesBefore = bytes()
        let rowsBefore = heldIds().count
        let fault = { (phase: String, db: OpaquePointer?) in
            guard phase == "after_insert", let db = db else { return }
            sqlite3_exec(db, "DROP TABLE IF EXISTS \(StoreSchema.table)", nil, nil, nil)
        }
        let result = store.persistAtWithFault(frame(2, .group, 100), receivedFrom: Data(), receivedAt: 200, fault: fault)
        XCTAssertEqual(result, .failedStorage, "heldBytes strict SQL failure -> failedStorage, not silent over-cap commit")
        XCTAssertEqual(bytes(), bytesBefore, "rolled back to pre-fault byte total")
        XCTAssertEqual(heldIds().count, rowsBefore, "row count unchanged")
        XCTAssertFalse(containsId(heldIds(), msgId(2)))
        // Reopen over the same file: the DDL drop was rolled back, so the store
        // reopens valid + bounded (the table is restored by ROLLBACK).
        store = nil
        _ = reopen(maxBytes: 1024)
        XCTAssertEqual(heldIds().count, rowsBefore, "store reopens valid after heldBytes SQL failure")
        XCTAssertLessThanOrEqual(bytes(), 1024, "store reopens bounded")
        XCTAssertTrue(containsId(heldIds(), msgId(1)), "pre-fault row survives reopen")
    }

    /// C6.4.1-H: a real SQL failure in `evictOldestPrefixNoLockStrict` rolls the
    /// whole transaction back. Pre-H, `evictOldestPrefixNoLock` swallowed a
    /// prepare/step failure as a no-op, so a failed eviction left the store
    /// over-cap AND committed the new row. The strict variant throws. This
    /// test overshoots the cap (so eviction runs), drops `held_frames` at
    /// `after_heldbytes` (after the capacity read succeeded, before eviction)
    /// so `evictOldestPrefixNoLockStrict`'s prepare fails, and proves the
    /// evicted rows are RESTORED and the inserted row is gone.
    func testEvictStrictSqlFailureRollsBackAndEvictedRowsRestored() {
        _ = open(maxBytes: 512)
        store.persistAt(frame(1, .group, 100), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .group, 100), receivedFrom: Data(), receivedAt: 200)
        let bytesBefore = bytes()
        let rowsBefore = heldIds().count
        // A third 100-byte frame overshoots the 512 cap -> eviction runs. The
        // fault drops the table after the heldBytes read, so the evict prepare
        // fails on a missing table -> throw -> ROLLBACK.
        let fault = { (phase: String, db: OpaquePointer?) in
            guard phase == "after_heldbytes", let db = db else { return }
            sqlite3_exec(db, "DROP TABLE IF EXISTS \(StoreSchema.table)", nil, nil, nil)
        }
        let result = store.persistAtWithFault(frame(3, .group, 100), receivedFrom: Data(), receivedAt: 300, fault: fault)
        XCTAssertEqual(result, .failedStorage, "evict strict SQL failure -> failedStorage, not silent over-cap commit")
        XCTAssertEqual(bytes(), bytesBefore, "evicted rows restored after rollback")
        XCTAssertEqual(heldIds().count, rowsBefore, "row count restored after rollback")
        XCTAssertTrue(containsId(heldIds(), msgId(1)))
        XCTAssertTrue(containsId(heldIds(), msgId(2)))
        XCTAssertFalse(containsId(heldIds(), msgId(3)))
    }

    /// C6.4.1-H: a real SQL failure in `containsNoLockStrict` rolls back. Pre-H,
    /// `containsNoLock` returned false on a prepare failure, so a storage fault
    /// in the final-presence check was masked as `.rejectedCapacity` for a row
    /// that WAS durably inserted (the router would refuse to forward a frame
    /// that is in fact held, AND the over-cap / commit state was inconsistent).
    /// The strict variant throws -> ROLLBACK -> `.failedStorage`.
    func testContainsStrictSqlFailureRollsBackAndReopensValid() {
        _ = open(maxBytes: 2048)
        store.persistAt(frame(1, .group, 100), receivedFrom: Data(), receivedAt: 100)
        let bytesBefore = bytes()
        let fault = { (phase: String, db: OpaquePointer?) in
            guard phase == "before_contains", let db = db else { return }
            sqlite3_exec(db, "DROP TABLE IF EXISTS \(StoreSchema.table)", nil, nil, nil)
        }
        let result = store.persistAtWithFault(frame(2, .group, 100), receivedFrom: Data(), receivedAt: 200, fault: fault)
        XCTAssertEqual(result, .failedStorage, "contains strict SQL failure -> failedStorage, not masked rejectedCapacity")
        XCTAssertEqual(bytes(), bytesBefore, "rolled back to pre-fault byte total")
        XCTAssertFalse(containsId(heldIds(), msgId(2)))
        store = nil
        _ = reopen(maxBytes: 2048)
        XCTAssertTrue(containsId(heldIds(), msgId(1)))
        XCTAssertEqual(heldIds().count, 1)
    }

    // MARK: - C6.6: Atomic outbound DIRECT enqueue real-SQL tests

    private func recipient(_ seed: UInt8 = 0x55) -> Data {
        Data((0..<16).map { UInt8(($0 + Int(seed)) & 0xFF) })
    }

    private func localNode(_ seed: UInt8 = 0x10) -> Data {
        Data((0..<16).map { UInt8(($0 + Int(seed)) & 0xFF) })
    }

    private func directFrame(
        _ seed: UInt8,
        payloadSize: Int = 64,
        type: TypeV2 = .message,
        priority: Priority = .direct,
        sealed: Bool = true,
        hasPow: Bool = false,
        msgIdOverride: Data? = nil
    ) -> FrameV2 {
        var flags = UInt16(priority.rawValue << 8)
        if sealed { flags |= UInt16(FrameV2.Flags.sealed) }
        if hasPow { flags |= UInt16(FrameV2.Flags.has_pow) }
        return FrameV2(
            type: type,
            msgId: msgIdOverride ?? msgId(seed),
            routingTag: routingTag,
            ttl: 12,
            hopCount: 0,
            flags: flags,
            payload: Data(repeating: seed, count: payloadSize)
        )
    }

    private func readDeliveryRow(_ mid: Data) -> DeliveryRow? {
        try? store.readDelivery(mid)
    }

    func testC66EnqueueDirectOutboundHappyPathAtomicallyCreatesHeldAndDeliveryRows() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let result = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(result, .created(f))

        XCTAssertTrue(containsId(heldIds(), f.msgId))
        guard let d = readDeliveryRow(f.msgId) else {
            XCTFail("delivery row missing")
            return
        }
        XCTAssertEqual(d.state, DeliveryState.queuedDurably.code)
        XCTAssertEqual(d.ackMode, AckMode.singleRecipient.rawValue)
        XCTAssertEqual(d.expectedRecipient, rec)
    }

    private struct InjectedFault: Error {}

    func testC66EnqueueDirectOutboundFaultAfterHeldInsertRollsBackBothHeldAndDeliveryRows() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let fault = { (phase: String, db: OpaquePointer?) throws -> Void in
            if phase == "after_held_insert" {
                throw InjectedFault()
            }
        }
        let result = store.enqueueDirectOutboundAtWithFault(f, expectedRecipient: rec, localOriginNodeId: origin, receivedAt: 100, fault: fault)
        XCTAssertEqual(result, OutboundEnqueueResult.storageFailure)

        XCTAssertFalse(containsId(heldIds(), f.msgId))
        XCTAssertNil(readDeliveryRow(f.msgId))
        XCTAssertEqual(heldIds().count, 0)
    }

    func testC66EnqueueDirectOutboundFaultAfterEvictRollsBackAndRestoresEvictedRows() {
        _ = open(maxBytes: 1024)
        store.persistAt(frame(1, .group, 400), receivedFrom: Data(), receivedAt: 100)
        store.persistAt(frame(2, .group, 400), receivedFrom: Data(), receivedAt: 200)
        let bytesBefore = bytes()

        let f = directFrame(3, payloadSize: 400)
        let rec = recipient(3)
        let origin = localNode(1)

        let fault = { (phase: String, db: OpaquePointer?) throws -> Void in
            if phase == "after_evict" {
                throw InjectedFault()
            }
        }
        let result = store.enqueueDirectOutboundAtWithFault(f, expectedRecipient: rec, localOriginNodeId: origin, receivedAt: 300, fault: fault)
        XCTAssertEqual(result, OutboundEnqueueResult.storageFailure)

        XCTAssertEqual(bytes(), bytesBefore)
        XCTAssertEqual(heldIds().count, 2)
        XCTAssertTrue(containsId(heldIds(), msgId(1)))
        XCTAssertTrue(containsId(heldIds(), msgId(2)))
        XCTAssertFalse(containsId(heldIds(), f.msgId))
        XCTAssertNil(readDeliveryRow(f.msgId))
    }

    func testC66EnqueueDirectOutboundFaultBeforeDeliveryInsertRollsBackHeldInsert() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let fault = { (phase: String, db: OpaquePointer?) throws -> Void in
            if phase == "before_delivery_insert" {
                throw InjectedFault()
            }
        }
        let result = store.enqueueDirectOutboundAtWithFault(f, expectedRecipient: rec, localOriginNodeId: origin, receivedAt: 100, fault: fault)
        XCTAssertEqual(result, OutboundEnqueueResult.storageFailure)

        XCTAssertFalse(containsId(heldIds(), f.msgId))
        XCTAssertNil(readDeliveryRow(f.msgId))
    }

    func testC66EnqueueDirectOutboundFaultAfterDeliveryInsertRollsBackWholeTransaction() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let fault = { (phase: String, db: OpaquePointer?) throws -> Void in
            if phase == "after_delivery_insert" {
                throw InjectedFault()
            }
        }
        let result = store.enqueueDirectOutboundAtWithFault(f, expectedRecipient: rec, localOriginNodeId: origin, receivedAt: 100, fault: fault)
        XCTAssertEqual(result, OutboundEnqueueResult.storageFailure)

        XCTAssertFalse(containsId(heldIds(), f.msgId))
        XCTAssertNil(readDeliveryRow(f.msgId))
    }

    func testC66EnqueueDirectOutboundUnderTightCapacityRejectsAndLeavesZeroDeliveryAndZeroHeldRows() {
        _ = open(maxBytes: 200)
        let f = directFrame(1, payloadSize: 250)
        let rec = recipient(1)
        let origin = localNode(1)

        let result = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(result, .rejectedCapacity)

        XCTAssertFalse(containsId(heldIds(), f.msgId))
        XCTAssertNil(readDeliveryRow(f.msgId))
        XCTAssertEqual(heldIds().count, 0)
    }

    func testC66EnqueueDirectOutboundSameExactRetryIsIdempotentAndReturnsAlreadyQueuedSameBinding() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        let f2 = FrameV2(
            type: f.type,
            msgId: f.msgId,
            routingTag: f.routingTag,
            ttl: f.ttl,
            hopCount: f.hopCount,
            flags: f.flags,
            payload: f.payload
        )
        let r2 = store.enqueueDirectOutbound(f2, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r2, .alreadyQueuedSameBinding(f))

        XCTAssertEqual(heldIds().count, 1)
        guard let d = readDeliveryRow(f.msgId) else {
            XCTFail("missing row")
            return
        }
        XCTAssertEqual(d.state, DeliveryState.queuedDurably.code)
        XCTAssertEqual(d.expectedRecipient, rec)
    }

    func testC661EnqueueDirectOutboundSameMsgIdDifferentPayloadFailsClosedWithCanonicalFrameMismatch() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        let fDiffPayload = FrameV2(
            type: f.type,
            msgId: f.msgId,
            routingTag: f.routingTag,
            ttl: f.ttl,
            hopCount: f.hopCount,
            flags: f.flags,
            payload: Data(repeating: 0x55, count: 120)
        )
        let r2 = store.enqueueDirectOutbound(fDiffPayload, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r2, .canonicalFrameMismatch)
    }

    func testC661EnqueueDirectOutboundSameMsgIdDifferentRoutingTagFailsClosedWithCanonicalFrameMismatch() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        let fDiffTag = FrameV2(
            type: f.type,
            msgId: f.msgId,
            routingTag: Data([0x77, 0x88, 0x99, 0xAA]),
            ttl: f.ttl,
            hopCount: f.hopCount,
            flags: f.flags,
            payload: f.payload
        )
        let r2 = store.enqueueDirectOutbound(fDiffTag, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r2, .canonicalFrameMismatch)
    }

    func testC661EnqueueDirectOutboundSameMsgIdDifferentValidFlagsFailsClosedWithCanonicalFrameMismatch() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        let validModifiedFlags = f.flags | UInt16(FrameV2.Flags.relay_ok)
        let fDiffFlags = FrameV2(
            type: f.type,
            msgId: f.msgId,
            routingTag: f.routingTag,
            ttl: f.ttl,
            hopCount: f.hopCount,
            flags: validModifiedFlags,
            payload: f.payload
        )
        let r2 = store.enqueueDirectOutbound(fDiffFlags, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r2, .canonicalFrameMismatch)
    }

    func testC661EnqueueDirectOutboundSameMsgIdDifferentTtlFailsClosedWithCanonicalFrameMismatch() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        let fDiffTtl = FrameV2(
            type: f.type,
            msgId: f.msgId,
            routingTag: f.routingTag,
            ttl: 10,
            hopCount: f.hopCount,
            flags: f.flags,
            payload: f.payload
        )
        let r2 = store.enqueueDirectOutbound(fDiffTtl, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r2, .canonicalFrameMismatch)
    }

    func testC661EnqueueDirectOutboundSameMsgIdDifferentHopCountFailsClosedWithCanonicalFrameMismatch() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        let fDiffHop = FrameV2(
            type: f.type,
            msgId: f.msgId,
            routingTag: f.routingTag,
            ttl: f.ttl,
            hopCount: 1,
            flags: f.flags,
            payload: f.payload
        )
        let r2 = store.enqueueDirectOutbound(fDiffHop, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r2, .canonicalFrameMismatch)
    }

    func testC661EnqueueDirectOutboundLocalOriginProvenanceIsLocalOriginNodeIdNotMsgId() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(2)

        XCTAssertNotEqual(origin, f.msgId, "origin node ID must be distinct from msgId")

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        // C6.6.2 / Section 15: Read actual persisted received_from column via raw SQL
        let storedProvenance = readHeldReceivedFrom(msgId: f.msgId)
        XCTAssertEqual(storedProvenance, origin)
        XCTAssertNotEqual(storedProvenance, f.msgId)
    }

    func testC661EnqueueDirectOutboundWrongPreexistingProvenanceFailsClosedWithInconsistentState() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let originA = localNode(1)
        let foreignNode = localNode(9)

        // Seed held frame with foreignNode provenance
        XCTAssertEqual(store.persist(f, receivedFrom: foreignNode), .heldNew)
        try? store.insertDelivery(f.msgId, stateOrdinal: DeliveryState.queuedDurably.code, ackModeOrdinal: AckMode.singleRecipient.rawValue, expectedRecipient: rec)

        // Retry from local node A
        let r = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: originA)
        XCTAssertEqual(r, .inconsistentState)
    }

    func testC66EnqueueDirectOutboundConflictingRecipientFailsClosedWithConflictRecipient() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec1 = recipient(1)
        let rec2 = recipient(2)
        let origin = localNode(1)

        let r1 = store.enqueueDirectOutbound(f, expectedRecipient: rec1, localOriginNodeId: origin)
        XCTAssertEqual(r1, .created(f))

        let r2 = store.enqueueDirectOutbound(f, expectedRecipient: rec2, localOriginNodeId: origin)
        XCTAssertEqual(r2, .conflictRecipient)

        guard let d = readDeliveryRow(f.msgId) else {
            XCTFail("missing row")
            return
        }
        XCTAssertEqual(d.expectedRecipient, rec1)
    }

    func testC66EnqueueDirectOutboundTerminalDeliveryStateFailsClosedWithRejectedTerminalState() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        XCTAssertEqual(store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin), .created(f))

        let updateSql = "UPDATE delivery_state SET state = \(DeliveryState.acknowledgedByRecipient.code) WHERE msg_id = ?"
        _ = store.execRawUpdate(updateSql, [f.msgId])

        let r2 = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(r2, .rejectedTerminalState)
    }

    func testC66EnqueueDirectOutboundHeldOnlyInconsistencyFailsClosedWithInconsistentState() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        XCTAssertEqual(store.persist(f, receivedFrom: origin), .heldNew)
        XCTAssertNil(readDeliveryRow(f.msgId))

        let result = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(result, .inconsistentState)
    }

    func testC66EnqueueDirectOutboundDeliveryOnlyInconsistencyFailsClosedWithInconsistentState() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        try? store.insertDelivery(f.msgId, stateOrdinal: DeliveryState.queuedDurably.code, ackModeOrdinal: AckMode.singleRecipient.rawValue, expectedRecipient: rec)
        XCTAssertFalse(containsId(heldIds(), f.msgId))

        let result = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(result, .inconsistentState)
    }

    func testC66EnqueueDirectOutboundStoreReopenPreservesBothHeldFramesAndDeliveryRowsOnDisk() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        XCTAssertEqual(store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin), .created(f))

        store = nil
        _ = reopen(maxBytes: 4096)

        XCTAssertTrue(containsId(heldIds(), f.msgId))
        guard let d = readDeliveryRow(f.msgId) else {
            XCTFail("missing row")
            return
        }
        XCTAssertEqual(d.state, DeliveryState.queuedDurably.code)
        XCTAssertEqual(d.ackMode, AckMode.singleRecipient.rawValue)
        XCTAssertEqual(d.expectedRecipient, rec)
    }

    func testC66EnqueueDirectOutboundPolicyRejectionOnNonDirectOrUnsealedOrInvalidMsgId() {
        _ = open(maxBytes: 4096)
        let rec = recipient(1)
        let origin = localNode(1)

        let groupFrame = directFrame(1, priority: .group)
        XCTAssertEqual(store.enqueueDirectOutbound(groupFrame, expectedRecipient: rec, localOriginNodeId: origin), .invalidArgument)

        let unsealedFrame = directFrame(2, sealed: false)
        XCTAssertEqual(store.enqueueDirectOutbound(unsealedFrame, expectedRecipient: rec, localOriginNodeId: origin), .invalidArgument)

        let powFrame = directFrame(3, hasPow: true)
        XCTAssertEqual(store.enqueueDirectOutbound(powFrame, expectedRecipient: rec, localOriginNodeId: origin), .invalidArgument)

        let validFrame = directFrame(4)
        XCTAssertEqual(store.enqueueDirectOutbound(validFrame, expectedRecipient: Data(repeating: 2, count: 15), localOriginNodeId: origin), .invalidArgument)

        // Invalid localOriginNodeId length
        XCTAssertEqual(store.enqueueDirectOutbound(validFrame, expectedRecipient: rec, localOriginNodeId: Data(repeating: 2, count: 15)), .invalidArgument)
    }

    // ==================================================================
    // Stage 4 Phase C6.6.2 -- Capacity-safe delivery binding + strict row decoding
    // ==================================================================

    private func assertNoOrphanActiveDeliveries() {
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("failed to open db")
            return
        }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT d.msg_id, d.state FROM \(StoreSchema.deliveryTable) d " +
            "WHERE d.state IN (1, 2) " +
            "AND NOT EXISTS (SELECT 1 FROM \(StoreSchema.table) h WHERE h.msg_id = d.msg_id)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("failed to prepare query")
            return
        }
        defer { sqlite3_finalize(stmt) }
        var orphans: [Int32] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            orphans.append(sqlite3_column_int(stmt, 1))
        }
        XCTAssertTrue(orphans.isEmpty, "Found orphan active delivery rows without held frames: \(orphans)")
    }

    private func readHeldReceivedFrom(msgId: Data) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT \(StoreSchema.colReceivedFrom) FROM \(StoreSchema.table) WHERE \(StoreSchema.colMsgId) = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        msgId.withUnsafeBytes { r in
            sqlite3_bind_blob(stmt, 1, r.baseAddress, Int32(msgId.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: ptr, count: count)
    }

    func testC662CapacityEvictionProtectsQueuedDurablyActiveDirectFrameFromNewDirectPressure() {
        // Frame A is 100 bytes payload + 64 overhead = 164 bytes.
        // Cap is 200 bytes, so A fits alone, but A + B (328 bytes) exceeds cap.
        _ = open(maxBytes: 200)
        let fa = directFrame(1, payloadSize: 100)
        let fb = directFrame(2, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let ra = store.enqueueDirectOutbound(fa, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(ra, .created(fa))
        assertNoOrphanActiveDeliveries()

        // Enqueue B: A is protected (QUEUED_DURABLY). B cannot fit without evicting A, so B is evicted and rejected.
        let rb = store.enqueueDirectOutbound(fb, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(rb, .rejectedCapacity)

        // Frame A held + delivery row remain intact; Frame B is absent.
        XCTAssertTrue(containsId(heldIds(), fa.msgId))
        let da = readDeliveryRow(fa.msgId)
        XCTAssertNotNil(da)
        XCTAssertEqual(da?.state, DeliveryState.queuedDurably.code)

        XCTAssertFalse(containsId(heldIds(), fb.msgId))
        XCTAssertNil(readDeliveryRow(fb.msgId))
        XCTAssertLessThanOrEqual(bytes(), 200)
        assertNoOrphanActiveDeliveries()
    }

    func testC662CapacityEvictionProtectsHandedToRelayActiveDirectFrameUnderPressure() {
        _ = open(maxBytes: 200)
        let fa = directFrame(1, payloadSize: 100)
        let fb = directFrame(2, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let ra = store.enqueueDirectOutbound(fa, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(ra, .created(fa))

        // Advance A to HANDED_TO_RELAY (state = 2) via production SqliteDeliveryRepository
        let repo = SqliteDeliveryRepository(store)
        let tr = repo.transition(fa.msgId, .markHanded)
        XCTAssertEqual(tr, TransitionResult.applied)

        // Enqueue B under capacity pressure
        let rb = store.enqueueDirectOutbound(fb, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(rb, .rejectedCapacity)

        // A is still held and in HANDED_TO_RELAY
        XCTAssertTrue(containsId(heldIds(), fa.msgId))
        let da = readDeliveryRow(fa.msgId)
        XCTAssertNotNil(da)
        XCTAssertEqual(da?.state, DeliveryState.handedToRelay.code)
        XCTAssertLessThanOrEqual(bytes(), 200)
        assertNoOrphanActiveDeliveries()
    }

    func testC662InboundPersistCannotOrphanLocalActiveDirectDeliveryRow() {
        _ = open(maxBytes: 200)
        let fa = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let ra = store.enqueueDirectOutbound(fa, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(ra, .created(fa))

        // Inbound/unbound relay frame arrives
        let inboundB = frame(2, .group, 100)
        let persistResult = store.persist(inboundB, receivedFrom: localNode(2))
        XCTAssertEqual(persistResult, .rejectedCapacity)

        // A is still held and delivery is still QUEUED_DURABLY
        XCTAssertTrue(containsId(heldIds(), fa.msgId))
        let da = readDeliveryRow(fa.msgId)
        XCTAssertNotNil(da)
        XCTAssertEqual(da?.state, DeliveryState.queuedDurably.code)
        XCTAssertLessThanOrEqual(bytes(), 200)
        assertNoOrphanActiveDeliveries()
    }

    func testC662UnboundRelayFramesEvictBeforeActiveDeliveryBoundFrames() {
        // Cap is 350 bytes.
        // Relay R (50 bytes payload + 64 = 114 bytes)
        // Direct A (50 bytes payload + 64 = 114 bytes)
        // Total = 228 <= 350.
        _ = open(maxBytes: 350)
        let relayR = frame(10, .group, 50)
        let persistR = store.persistAt(relayR, receivedFrom: localNode(9), receivedAt: 100)
        XCTAssertEqual(persistR, .heldNew)

        let directA = directFrame(1, payloadSize: 50)
        let recA = recipient(1)
        let origin = localNode(1)
        let enqueueA = store.enqueueDirectOutboundAtWithFault(directA, expectedRecipient: recA, localOriginNodeId: origin, receivedAt: 200)
        XCTAssertEqual(enqueueA, .created(directA))

        // Now add Direct B (100 bytes payload + 64 = 164 bytes).
        // Total would be 114 + 114 + 164 = 392 > 350 (overshoot = 42 bytes).
        // R is evictable (unbound); A is protected (active delivery). R should be evicted.
        let directB = directFrame(2, payloadSize: 100)
        let enqueueB = store.enqueueDirectOutboundAtWithFault(directB, expectedRecipient: recipient(2), localOriginNodeId: origin, receivedAt: 300)
        XCTAssertEqual(enqueueB, .created(directB))

        // R was evicted
        XCTAssertFalse(containsId(heldIds(), relayR.msgId))
        // A is still held and active
        XCTAssertTrue(containsId(heldIds(), directA.msgId))
        let da = readDeliveryRow(directA.msgId)
        XCTAssertNotNil(da)
        XCTAssertEqual(da?.state, DeliveryState.queuedDurably.code)
        // B is held and active
        XCTAssertTrue(containsId(heldIds(), directB.msgId))
        let db = readDeliveryRow(directB.msgId)
        XCTAssertNotNil(db)
        XCTAssertEqual(db?.state, DeliveryState.queuedDurably.code)

        XCTAssertLessThanOrEqual(bytes(), 350)
        assertNoOrphanActiveDeliveries()
    }

    func testC662TerminalDeliveryRowWithoutHeldFrameReturnsRejectedTerminalState() {
        _ = open(maxBytes: 4096)
        let rec = recipient(1)
        let origin = localNode(1)

        let terminalStates: [DeliveryState] = [
            .acknowledgedByRecipient,
            .expired,
            .cancelledLocally
        ]

        for (idx, termState) in terminalStates.enumerated() {
            let f = directFrame(UInt8(idx + 10), payloadSize: 100)
            // Plant delivery row directly with terminal state and NO held frame
            try? store.insertDelivery(
                f.msgId,
                stateOrdinal: termState.code,
                ackModeOrdinal: AckMode.singleRecipient.rawValue,
                expectedRecipient: rec
            )
            XCTAssertFalse(containsId(heldIds(), f.msgId))

            // Retry same message
            let result = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
            XCTAssertEqual(result, .rejectedTerminalState)
            // Zero writes to held_frames
            XCTAssertFalse(containsId(heldIds(), f.msgId))
        }
    }

    func testC662RawSqlCorruptedTypeIntegerFailsClosedWithoutTrapping() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let created = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(created, .created(f))

        // Corrupt type in held_frames to 257 (or -1) via raw SQL
        let updateSql = "UPDATE \(StoreSchema.table) SET \(StoreSchema.colType) = 257 WHERE \(StoreSchema.colMsgId) = ?"
        let n = store.execRawUpdate(updateSql, [f.msgId])
        XCTAssertEqual(n, 1)

        // Retry must fail closed as .inconsistentState without trapping
        let retry = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(retry, .inconsistentState)
    }

    func testC662RawSqlCorruptedTtlOrFlagsFailsClosedWithoutTrapping() {
        _ = open(maxBytes: 4096)
        let f = directFrame(1, payloadSize: 100)
        let rec = recipient(1)
        let origin = localNode(1)

        let created = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(created, .created(f))

        // Corrupt ttl to -1 via raw SQL
        let updateSql = "UPDATE \(StoreSchema.table) SET \(StoreSchema.colTtl) = -1 WHERE \(StoreSchema.colMsgId) = ?"
        let n = store.execRawUpdate(updateSql, [f.msgId])
        XCTAssertEqual(n, 1)

        // Retry must fail closed as .inconsistentState without trapping
        let retry = store.enqueueDirectOutbound(f, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(retry, .inconsistentState)
    }

    func testC662ReadHeldNoLockStrictStepErrorYieldsStorageFailureAndRollsBack() {
        _ = open(maxBytes: 4096)
        let priorFrame = directFrame(99, payloadSize: 50)
        let rec = recipient(1)
        let origin = localNode(1)

        // Preseed a prior frame
        let priorEnqueue = store.enqueueDirectOutbound(priorFrame, expectedRecipient: recipient(99), localOriginNodeId: origin)
        XCTAssertEqual(priorEnqueue, .created(priorFrame))

        let f = directFrame(1, payloadSize: 100)
        let oneShot = OneShotProgressInterrupt()

        // Use fault hook after capacity eviction to install a ONE-SHOT progress handler that interrupts readHeld
        let result = store.enqueueDirectOutboundAtWithFault(
            f,
            expectedRecipient: rec,
            localOriginNodeId: origin,
            receivedAt: 100
        ) { hook, db in
            if hook == "after_evict" {
                oneShot.arm(db: db)
            }
        }

        XCTAssertEqual(result, .storageFailure)
        XCTAssertNotEqual(result, .rejectedCapacity)
        XCTAssertNotEqual(result, .inconsistentState)

        // Close and reopen store to independently verify rollback
        _ = reopen(maxBytes: 4096)
        XCTAssertFalse(containsId(heldIds(), f.msgId))
        XCTAssertNil(readDeliveryRow(f.msgId))

        // Preseeded frame remains intact and active
        XCTAssertTrue(containsId(heldIds(), priorFrame.msgId))
        let priorDelivery = readDeliveryRow(priorFrame.msgId)
        XCTAssertNotNil(priorDelivery)
        XCTAssertEqual(priorDelivery?.state, DeliveryState.queuedDurably.code)

        // Database remains usable for subsequent enqueue
        let validF = directFrame(2, payloadSize: 50)
        let validResult = store.enqueueDirectOutbound(validF, expectedRecipient: rec, localOriginNodeId: origin)
        XCTAssertEqual(validResult, .created(validF))
        XCTAssertTrue(containsId(heldIds(), validF.msgId))
    }

    func testC663ContainsNoLockStrictStepErrorYieldsFailedStorageAndRollsBack() {
        _ = open(maxBytes: 4096)
        let f = frame(1, .group, 50)
        let origin = localNode(1)

        let oneShot = OneShotProgressInterrupt()
        let result = store.persistAtWithFault(f, receivedFrom: origin, receivedAt: 100) { hook, db in
            if hook == "before_contains" {
                oneShot.arm(db: db)
            }
        }

        // Must fail with failedStorage (thrown stepFailed unwound transaction to ROLLBACK)
        XCTAssertEqual(result, .failedStorage)
        XCTAssertNotEqual(result, .rejectedCapacity)
        XCTAssertNotEqual(result, .heldNew)
        XCTAssertNotEqual(result, .heldDuplicate)

        // Close and reopen store over the same database to independently verify rollback
        _ = reopen(maxBytes: 4096)
        XCTAssertFalse(containsId(heldIds(), f.msgId))

        // Database remains fully usable after the failure
        let f2 = frame(2, .group, 50)
        let res2 = store.persist(f2, receivedFrom: origin)
        XCTAssertEqual(res2, .heldNew)
        XCTAssertTrue(containsId(heldIds(), f2.msgId))
    }

    private final class OneShotProgressInterrupt {
        private let rawPtr: UnsafeMutablePointer<Int32>

        init() {
            rawPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
            rawPtr.pointee = 0
        }

        deinit {
            rawPtr.deallocate()
        }

        func arm(db: OpaquePointer?) {
            guard let db = db else { return }
            rawPtr.pointee = 0
            sqlite3_progress_handler(db, 1, { ptr in
                guard let p = ptr?.assumingMemoryBound(to: Int32.self) else { return 0 }
                if p.pointee == 0 {
                    p.pointee = 1
                    return 1 // interrupt first operation
                }
                return 0 // allow subsequent operations (ROLLBACK, verification, etc.)
            }, rawPtr)
        }

        func disarm(db: OpaquePointer?) {
            guard let db = db else { return }
            sqlite3_progress_handler(db, 0, nil, nil)
        }
    }

    // MARK: - helpers

    /// Reopen the store over the existing [tmpURL] (B3 reopen-after-fault tests).
    @discardableResult
    private func reopen(maxBytes: Int64) -> SqliteMessageStore {
        let s = SqliteMessageStore(url: tmpURL, maxBytes: maxBytes)
        store = s
        return s
    }

    /// Delete a held row directly via a side sqlite3 connection (B2 retry test:
    /// simulates authenticated-ACK delivery deleting a held frame to make room).
    private func deleteHeldRow(msgId id: Data) {
        store = nil   // close the store handle so the side connection has the file
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmpURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db); return
        }
        var stmt: OpaquePointer?
        let sql = "DELETE FROM \(StoreSchema.table) WHERE \(StoreSchema.colMsgId) = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); sqlite3_close_v2(db); return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        id.withUnsafeBytes { r in
            sqlite3_bind_blob(stmt, 1, r.baseAddress, Int32(id.count), transient)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        sqlite3_close_v2(db)
        _ = reopen(maxBytes: 512)
    }

    /// Insert a row with an unknown type code (0x77) directly via sqlite3.
    private func seedUnknownTypeRow(at url: URL, msgId: Data) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                              nil) == SQLITE_OK else {
            sqlite3_close_v2(db); return
        }
        sqlite3_exec(db, StoreSchema.createSqlIfNotExists, nil, nil, nil)
        // C6.4.1-E: the store now DDL-fingerprint-validates BOTH tables on a
        // current-version reopen, so the seed must create delivery_state too
        // (otherwise validateSchema rejects the file as malformed fail-closed).
        sqlite3_exec(db, StoreSchema.createDeliverySqlIfNotExists, nil, nil, nil)
        let sql = "INSERT INTO \(StoreSchema.table) (" +
            "\(StoreSchema.colMsgId), \(StoreSchema.colType), \(StoreSchema.colTtl), " +
            "\(StoreSchema.colHopCount), \(StoreSchema.colFlags), \(StoreSchema.colPriority), " +
            "\(StoreSchema.colRoutingTag), \(StoreSchema.colPayload), " +
            "\(StoreSchema.colReceivedFrom), \(StoreSchema.colReceivedAt)) VALUES (?,?,?,?,?,?,?,?,?,?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); sqlite3_close_v2(db); return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        msgId.withUnsafeBytes { r in
            sqlite3_bind_blob(stmt, 1, r.baseAddress, Int32(msgId.count), transient)
        }
        sqlite3_bind_int(stmt, 2, 0x77)   // not a TypeV2
        sqlite3_bind_int(stmt, 3, 12)
        sqlite3_bind_int(stmt, 4, 0)
        sqlite3_bind_int(stmt, 5, Int32(Priority.toFlags(.group)))
        sqlite3_bind_int(stmt, 6, Int32(Priority.group.rawValue))
        routingTag.withUnsafeBytes { r in
            sqlite3_bind_blob(stmt, 7, r.baseAddress, Int32(routingTag.count), transient)
        }
        let payload = Data(repeating: 0, count: 8)
        payload.withUnsafeBytes { r in
            sqlite3_bind_blob(stmt, 8, r.baseAddress, Int32(payload.count), transient)
        }
        sqlite3_bind_zeroblob(stmt, 9, 0)
        sqlite3_bind_int64(stmt, 10, 100)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        // C6.4-E: stamp PRAGMA user_version = dbVersion so the store, on reopen,
        // sees a CURRENT-version file and takes the idempotent `IF NOT EXISTS`
        // path (no drop+recreate). Without this, runMigrations reads user_version=0
        // (fresh) and destructively recreates both tables -- destroying the seeded
        // forward-type row. The seed models a current-schema file that already
        // contains a future-type row (forward-compat: skip, do not crash).
        sqlite3_exec(db, "PRAGMA user_version = \(StoreSchema.dbVersion)", nil, nil, nil)
        sqlite3_close_v2(db)
    }
}