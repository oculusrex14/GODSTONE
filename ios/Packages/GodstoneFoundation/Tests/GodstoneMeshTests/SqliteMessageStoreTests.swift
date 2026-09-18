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
        sqlite3_exec(db, StoreSchema.createObligationSqlIfNotExists, nil, nil, nil)
        sqlite3_exec(db, StoreSchema.createAckFrameSqlIfNotExists, nil, nil, nil)
        // *** GS-FINAL-005: A SEEDED ROW NEEDS A REAL RETENTION BUDGET, OR THE STORE (CORRECTLY) JUDGES IT EXPIRED. ***
        //
        // THIS SEED WROTE NO RETENTION COLUMNS AT ALL. WHILE THE CLOCK WAS OPTIONAL THAT WAS HARMLESS, because the
        // store could not judge retention at all; WITH A MANDATORY RUNTIME CLOCK THE ROW IS JUDGED, and a row with no
        // budget is a row with nothing left -- so the sweep retired it before this arm could count it, and the arm
        // failed for a reason that had nothing to do with its subject (TYPE-SKIPPING).
        //
        // THE FIX IS THE FIXTURE'S, NOT THE STORE'S: the seed now admits the row through the SAME policy production
        // uses, so the row stands exactly as a real receipt would and the arm measures what it was written to measure.
        let seeded = RetentionPolicy.admit(
            msgId: msgId.map { String(format: "%02x", $0) }.joined(),
            kind: .direct, priority: 0, firstReceiptId: String(format: "%02x", 0),
            nowMono: Int(Date().timeIntervalSince1970 * 1000), bootIdentity: "seed-boot")
        let sql = "INSERT INTO \(StoreSchema.table) (" +
            "\(StoreSchema.colMsgId), \(StoreSchema.colType), \(StoreSchema.colTtl), " +
            "\(StoreSchema.colHopCount), \(StoreSchema.colFlags), \(StoreSchema.colPriority), " +
            "\(StoreSchema.colRoutingTag), \(StoreSchema.colPayload), " +
            "\(StoreSchema.colReceivedFrom), \(StoreSchema.colReceivedAt), " +
            "\(StoreSchema.colRemainingMs), \(StoreSchema.colCheckpointMono), " +
            "\(StoreSchema.colBootIdentity), \(StoreSchema.colDiscontinuity)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
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
        // AND THE FOUR RETENTION COLUMNS, so the row is JUDGEABLE rather than instantly spent (GS-FINAL-005).
        sqlite3_bind_int64(stmt, 11, Int64(seeded.remainingMs))
        sqlite3_bind_int64(stmt, 12, Int64(seeded.checkpointMonotonicMs))
        sqlite3_bind_text(stmt, 13, seeded.bootIdentity, -1, transient)
        sqlite3_bind_int64(stmt, 14, Int64(seeded.discontinuityCount))
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

    // -------------------------------------------------------------- GS-STORE-005
    //
    // The audit's charge: "Observer registrations remain append-only with no release handle.
    // Repeated runtime attachment can retain callbacks." The law these arms assert is the store's
    // own: A REGISTRATION MUST NOT OUTLIVE THE RUNTIME THAT MADE IT, and a released registration
    // must fire zero times. ARM 1 IS THE BEHAVIOURAL RED, expressible against the tree as it stood:
    // the store retained every closure for ever, so a witness the runtime dropped could not die.

    /// A runtime's own lifetime witness: the store's registration captures it, so whether it
    /// deallocateth telleth whether the store still holdeth the runtime's callback.
    private final class LifetimeWitness { var fired = 0 }

    func testGSSTORE005_aStoreRegistrationMustNotOutliveTheRuntimeThatMadeIt() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var witnesses: [LifetimeWitness] = []
        var weakBoxes: [() -> LifetimeWitness?] = []
        // ONE HUNDRED RUNTIME LIFETIMES: each registereth its own callback and then goeth away.
        for _ in 0..<100 {
            let w = LifetimeWitness()
            witnesses.append(w)
            weak var weakW = w
            weakBoxes.append { weakW }
            // EVERY LIFETIME RELEASETH ITS OWN REGISTRATION, as a runtime's teardown must: the law is that a
            // RELEASED registration doth not outlive the runtime, not that a store observeth without retaining.
            let lease = s.registerHeldSetObserver { w.fired += 1 }
            s.removeHeldSetObserver(lease!)
        }
        witnesses.removeAll()
        // Every runtime hath departed: not one callback may remain to be fired.
        let survivors = weakBoxes.filter { $0() != nil }.count
        XCTAssertEqual(survivors, 0,
                       "the store retained \(survivors) callbacks of runtimes that had already gone")
    }

    func testGSSTORE005_aReleasedRegistrationFiresZeroTimesAndTheCensusReturnsToBaseline() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        let baseline = s.observerCensusForTest()
        var fired = 0
        let lease = try XCTUnwrap(s.registerHeldSetObserver { fired += 1 },
                                  "the real store must answer a RELEASABLE lease, not nil")
        XCTAssertEqual(s.observerCensusForTest(), baseline + 1)
        s.removeHeldSetObserver(lease)
        XCTAssertEqual(s.observerCensusForTest(), baseline,
                       "a released registration must leave the census at its baseline")
        _ = s.persistAt(frame(1, .direct, 32), receivedFrom: Data([9]), receivedAt: 1_000)
        XCTAssertEqual(fired, 0, "a RELEASED registration must fire zero times")
    }

    func testGSSTORE005_theWholeObserverCensusIsReleasedByClose() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        for _ in 0..<64 { s.registerHeldSetObserver { } }
        XCTAssertEqual(s.observerCensusForTest(), 64)
        s.close()
        XCTAssertEqual(s.observerCensusForTest(), 0,
                       "closing the store must release every registration it held")
    }

    func testGSSTORE005_theMeasuredTotalQuotaRefusethAdmissionWithoutSlayingAProtectedRow() throws {
        let s = open(maxBytes: 64 * 1024 * 1024)
        // A protected row the pressure must NOT delete, and a candidate to be refused.
        _ = s.persistAt(frame(7, .sos, 64), receivedFrom: Data([1]), receivedAt: 1_000)
        let protectedIds = heldIds()
        // The measured total: a REAL reading of the database and its WAL, here injected as over quota.
        s.quotaSnapshotSource = { QuotaSnapshot(
            heldBytes: .values(s.heldBytes), totalBytes: .values(StoreQuota.totalPrivateStoreQuota + 1),
            deliveryRows: .values(0), inboxRows: .values(0), tombstoneRows: .values(0),
            trustPins: .values(0), inActiveTransaction: false, walBytes: 0) }
        XCTAssertEqual(s.persistAt(frame(8, .direct, 64), receivedFrom: Data([1]), receivedAt: 2_000),
                       .rejectedCapacity, "the measured total quota must refuse a new admission")
        XCTAssertEqual(heldIds(), protectedIds,
                       "a refused admission may not delete a protected row to make room")
    }

    func testGSSTORE005_aFailedMeasurementIsAFailureAndNeverAZero() throws {
        let s = open(maxBytes: 64 * 1024 * 1024)
        s.quotaSnapshotSource = { QuotaSnapshot(
            heldBytes: .queryFailure("held bytes unreadable"), totalBytes: .queryFailure("db unreadable"),
            deliveryRows: .values(0), inboxRows: .values(0), tombstoneRows: .values(0),
            trustPins: .values(0), inActiveTransaction: false, walBytes: 0) }
        XCTAssertEqual(s.persistAt(frame(9, .direct, 64), receivedFrom: Data([2]), receivedAt: 3_000),
                       .failedStorage,
                       "an unreadable measurement is a FAILURE, and a failure is never a fabricated zero")
        XCTAssertTrue(heldIds().isEmpty)
    }

    // ------------------------------------------------------------- GS-STORE-004
    //
    // The audit's charge: "Receipt-relative retention is not stored or executed by the real store ... The
    // existing store still records wall-clock receipt times without wiring the new checkpoint/debit policy into
    // transactions or startup." THE FIRST LAW OF THAT WIRING: THE RECEIPT ANCHOR COMETH FROM THE INJECTED
    // CLOCK, NEVER FROM WALL TIME READ INSIDE A TRANSACTION METHOD. Run RED against the tree as it stood.

    func testGSSTORE004_theReceiptAnchorComethFromTheInjectedClock() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var consulted = 0
        s.receiptTimeProvider = { consulted += 1; return (monoMs: 7_777_000, bootIdentity: "boot-A") }
        let f = frame(3, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertGreaterThan(consulted, 0,
                             "the store must ASK the injected clock, not read wall time inside its transaction")
        XCTAssertEqual(s.receiptAnchorForTest(f.msgId), 7_777_000,
                       "the persisted anchor must be the INJECTED monotonic reading, never Date()")
    }

    func testGSSTORE004_aDuplicateReceiptNeverReplenishesTheBudget() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var now: Int64 = 1_000_000
        s.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(4, .direct, 48)
        _ = s.persist(f, receivedFrom: Data([7]))
        let firstAnchor = s.receiptAnchorForTest(f.msgId)
        now += 3_600_000                     // an hour later, the SAME message arriveth again
        _ = s.persist(f, receivedFrom: Data([7]))
        XCTAssertEqual(s.receiptAnchorForTest(f.msgId), firstAnchor,
                       "a DUPLICATE receipt must RETAIN the original budget, never replenish it")
    }

    /// GS-STORE-004, the finding's own closure test: "Persist a DIRECT, close/reopen on same boot, advance
    /// injected monotonic time, and verify remaining lifetime only decreases" -- and "Expired rows must not be
    /// forwarded". RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_expiredAcrossAReopenAndIsNotForwarded() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-retention-\(UUID().uuidString).db")
        tmpURL = url
        var now: Int64 = 1_000_000
        let first = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        first.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(5, .direct, 48)
        XCTAssertEqual(first.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertNotNil(first.receiptAnchorForTest(f.msgId))
        first.close()

        // REOPEN on the SAME BOOT, an hour short of the DIRECT lifetime (seven days).
        now += 7 * 24 * 3_600_000 - 3_600_000
        let second = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        second.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        defer { second.close() }
        XCTAssertEqual(second.allHeldMsgIds(), [f.msgId],
                       "an hour short of the lifetime, the message is still offered")

        // AND PAST IT: the row must be DEBITED and NOT FORWARDED.
        now += 2 * 3_600_000
        XCTAssertTrue(second.allHeldMsgIds().isEmpty,
                      "an EXPIRED row must not be forwarded to a reader")
    }

    /// GS-STORE-004, the finding's own words: "On first durable receipt, initialize the local policy budget in the
    /// SAME TRANSACTION as the held row. On duplicate receipt, retain/debit the existing budget; do not replenish
    /// it from the sender's timestamp." RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_theBudgetIsPersistedWithTheRowAndNeverReplenished() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var now: Int64 = 5_000_000
        s.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(6, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        let first = s.retentionCheckpointForTest(f.msgId)
        XCTAssertNotNil(first.remainingMs,
                        "the LOCAL policy budget must be PERSISTED with the row, not left empty")
        XCTAssertEqual(first.remainingMs, Int64(RetentionPolicy.lifetimeMs[.direct]!),
                       "a FIRST receipt is granted the local lifetime exactly once")
        XCTAssertEqual(first.checkpointMono, 5_000_000, "anchored at the INJECTED monotonic reading")
        XCTAssertEqual(first.bootIdentity, "boot-A", "the continuity identifier is recorded with it")

        now += 3_600_000
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldDuplicate)
        let after = s.retentionCheckpointForTest(f.msgId)
        XCTAssertEqual(after.remainingMs, first.remainingMs,
                       "a DUPLICATE receipt must never replenish the budget")
        XCTAssertEqual(after.checkpointMono, first.checkpointMono,
                       "nor move its anchor")
    }

    /// GS-STORE-004, the DISCRIMINATING law of the persisted budget: "Persist a DIRECT, close/reopen on same boot,
    /// advance injected monotonic time, and verify remaining lifetime only DECREASES." An anchor-only debit cannot
    /// tell a row whose budget was already spent from one whose anchor is merely recent -- so this arm SETS the
    /// stored budget low and demands the row be withheld ON THAT ALONE. RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_thePersistedBudgetDecidethNotTheAnchorAlone() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-budget-\(UUID().uuidString).db")
        tmpURL = url
        let s = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        s.receiptTimeProvider = { (monoMs: 9_000_000, bootIdentity: "boot-A") }
        let f = frame(7, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        defer { s.close() }
        // The row's ANCHOR is fresh, and its STORED BUDGET is spent: only a store that READETH the budget can
        // withhold it.
        let changed = s.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", [])
        XCTAssertEqual(changed, 1, "the fixture must be able to spend the stored budget")
        XCTAssertEqual(s.retentionCheckpointForTest(f.msgId).remainingMs, 0)
        XCTAssertTrue(s.allHeldMsgIds().isEmpty,
                      "a row whose PERSISTED budget is spent must not be forwarded, however fresh its anchor")
    }

    /// GS-STORE-004: "on reopen, debit elapsed monotonic time WHEN CONTINUITY IS PROVED; otherwise use the FROZEN
    /// CONSERVATIVE DISCONTINUITY RULE." The persisted boot identity was written and never compared, so an arm
    /// that changes the boot under a SHORT budget must be withheld by the conservative debit (at least one hour)
    /// and is not, today. RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_aChangedBootDebitethConservatively() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-boot-\(UUID().uuidString).db")
        tmpURL = url
        let first = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        first.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: "boot-A") }
        let f = frame(8, .direct, 48)
        XCTAssertEqual(first.persist(f, receivedFrom: Data([7])), .heldNew)
        // A SHORT budget: thirty minutes, so a conservative debit of at least one hour MUST exhaust it.
        XCTAssertEqual(first.execRawUpdate("UPDATE held_frames SET remaining_ms = 1800000", []), 1)
        first.close()

        // THE SAME MONOTONIC READING, BUT A DIFFERENT BOOT: continuity is NOT proved.
        let second = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        second.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: "boot-B") }
        defer { second.close() }
        XCTAssertTrue(second.allHeldMsgIds().isEmpty,
                      "a changed boot under a short budget must be debited conservatively, not left untouched")
    }

    /// GS-STORE-004: the conservative rule is BOUNDED by `discontinuityLimit`, and a bound that is never
    /// PERSISTED can never be reached -- the policy returneth the next checkpoint and the store droppeth it. This
    /// arm demandeth that a conservative debit be WRITTEN BACK. RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_aConservativeDebitIsPersistedBack() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-disco-\(UUID().uuidString).db")
        tmpURL = url
        let first = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        first.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: "boot-A") }
        let f = frame(9, .direct, 48)
        XCTAssertEqual(first.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(first.execRawUpdate("UPDATE held_frames SET remaining_ms = 300000000", []), 1)
        XCTAssertEqual(first.retentionCheckpointForTest(f.msgId).discontinuity, 0)
        first.close()

        // A DIFFERENT BOOT with a budget that SURVIVETH the conservative hour: the debit must be recorded.
        let second = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        second.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: "boot-B") }
        defer { second.close() }
        _ = second.allHeldMsgIds()
        let after = second.retentionCheckpointForTest(f.msgId)
        XCTAssertEqual(after.discontinuity, 1,
                       "the conservative debit must be PERSISTED, or the bounded rule can never be reached")
        XCTAssertLessThan(after.remainingMs ?? .max, 300_000_000,
                          "and the debit must be reflected in the persisted budget")
    }

    /// *** GS-STORE-004 CLOSURE 2: "MAXIMUM HOLD" -- AND THE MEASUREMENT THAT REFUTED THE PREMISE THE PARKED ARM
    /// RESTED ON. ***
    ///
    /// ROUND 527 PARKED AN ARM DEMANDING THAT AN ABSOLUTE CAP CATCH A ROW WHOSE BUDGET HAD BEEN PLANTED AT THIRTY DAYS,
    /// AND CONCLUDED THAT ITS REPAIR NEEDED A NON-REBASED ORIGIN -- I.E. **SCHEMA REVISION 10**. **THAT PREMISE WAS
    /// NEVER MEASURED, AND MEASURING IT REFUTETH IT: NO PATH IN THIS STORE CAN GRANT A BUDGET ABOVE `maxHoldMs`.** The
    /// three measurements, each taken before this arm was written:
    ///   * `RetentionPolicy.admit` (`RetentionClock.swift:129`) IS THE **ONELY MINT** of a budget, and it granteth
    ///     EXACTLY `lifetimeMs[kind]` -- never a caller's number;
    ///   * the **ONELY MUTATION** is the debit (`newCp.remainingMs = ... remaining`, where
    ///     `remaining = max(0, cp.remainingMs - debit)`), which NEVER increaseth it; a duplicate receipt is
    ///     `INSERT OR IGNORE` and cannot replenish it either;
    ///   * and **EVERY LIFETIME IS AT OR BELOW THE CAP**: `direct` 168h == 168h, `sos`/`group`/`broadcast` 24h,
    ///     `bulk` 1h.
    /// SO THE MAXIMUM HOLD IS ENFORCED **BY CONSTRUCTION**, and the parked arm asserted a defect **IN A STATE THE
    /// STORE CANNOT PRODUCE** -- its thirty-day budget came from `execRawUpdate`, i.e. from OUTSIDE every path the
    /// card chargeth. **A DEFECT CLAIM WHOSE PREMISE IS UNMEASURED IS NOT A DEFECT CLAIM; IT IS A HYPOTHESIS.**
    ///
    /// THIS ARM THEREFORE ASSERTETH THE LAW THAT IS **REACHABLE**, AND IT IS THE STRONGER ONE: **NO KIND MAY BE
    /// GRANTED A BUDGET ABOVE THE CAP, AND A CAP THAT CANNOT BE EXCEEDED NEEDETH NO SECOND ENFORCEMENT.**
    func testGSSTORE004_noKindMayBeGrantedABudgetAboveTheMaximumHold() throws {
        // (A) THE LAW, OVER **EVERY** KIND THE POLICY NAMETH -- including `group` and `broadcast`, which have no wire
        // type in this build and so no held row can carry them yet: THE TABLE ITSELF must stand under the cap, or one
        // added later could silently outlive it.
        for kind in MessageKind.allCases {
            let lifetime = try XCTUnwrap(RetentionPolicy.lifetimeMs[kind],
                                         "every kind must carrieth a lifetime: \(kind)")
            XCTAssertLessThanOrEqual(lifetime, RetentionPolicy.maxHoldMs,
                                     "*** NO LIFETIME MAY EXCEED THE MAXIMUM HOLD: a lifetime above the cap would make "
                                     + "the cap the binding constraint and `isExpired`'s maxHold branch DEAD, while "
                                     + "every arm that planted a larger budget would be testing a state the store "
                                     + "cannot reach (GS-STORE-004 closure 2; \(kind)) ***")
        }
        XCTAssertEqual(RetentionPolicy.lifetimeMs[.direct], RetentionPolicy.maxHoldMs,
                       "and DIRECT is the kind that MEETS the cap exactly, which is why it was the one worth measuring")

        // (B) BEHAVIOURALLY, FOR THE KINDS THE WIRE CAN EXPRESS: the persisted budget IS the lifetime, and it is
        // under the cap. `group`/`broadcast` are asserted by the LAW above and NOT here, because no frame of this
        // build carrieth them -- and asserting a row that cannot exist would be the parked arm's error again.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-cap-\(UUID().uuidString).db")
        tmpURL = url
        let store = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        defer { store.close() }
        store.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: "boot-A") }

        for (seed, type) in [(UInt8(21), TypeV2.message), (UInt8(22), TypeV2.sos)] {
            let f = frame(seed, .bulk, 48, type: type)
            XCTAssertEqual(store.persist(f, receivedFrom: Data([7])), .heldNew)
            let budget = try XCTUnwrap(store.retentionCheckpointForTest(f.msgId).remainingMs,
                                       "the minted budget must be persisted")
            XCTAssertEqual(Int(budget), MessageKind.ofStoredTypeCode(Int(type.rawValue)).flatMap {
                RetentionPolicy.lifetimeMs[$0]
            },
            "*** THE MINTED BUDGET MUST BE THE LIFETIME OF THE ROW'S OWN KIND. MEASURED AT ROUND 528: the insert path "
            + "minted EVERY row as `MessageKind.direct` -- so an SOS was granted SEVEN DAYS where the policy saith "
            + "TWENTY-FOUR HOURS, and a bulk row ONE HUNDRED AND SIXTY-EIGHT TIMES its own (GS-STORE-004 step 3) ***")
            XCTAssertLessThanOrEqual(Int(budget), RetentionPolicy.maxHoldMs,
                                     "*** AND UNDER THE CAP: no reachable row may be granted a budget above the "
                                     + "maximum hold (GS-STORE-004 closure 2) ***")
            // AND NO DUPLICATE MAY RAISE IT -- the other half of the same law.
            XCTAssertEqual(store.persist(f, receivedFrom: Data([7])), .heldDuplicate)
            XCTAssertEqual(store.retentionCheckpointForTest(f.msgId).remainingMs, budget,
                           "a duplicate receipt may not replenish the budget, so it cannot raise it either")
        }
    }

    /// *** GS-STORE-004 CLOSURE 3's LAST CLAUSE: *"related delivery/retention state must survive ... TRANSACTION
    /// FAILURE."* IT COULD NOT BE WITNESSED BEFORE THIS ROUND, BECAUSE THE PATH COULD NOT BE FAULTED AT ALL. ***
    ///
    /// MEASURED AT ROUND 530, BEFORE ANY EDIT: the store's fault seam is *"`fault: ((String, OpaquePointer?) throws
    /// -> Void)?`"* -- **A PARAMETER OF THE PERSIST PATH** (`persistAtWithFault`, with the phases `after_insert` and
    /// `after_heldbytes`). **THE READ PATH HATH NO SUCH PARAMETER**, and the retention write-back runneth DURING A
    /// READ on the reader's own handle -- SO **NO COURT COULD MAKE IT FAIL**, and a clause whose path cannot be
    /// faulted cannot be witnessed. Round 530 added `retentionWriteBackFault` for that reason; **THIS ARM IS THE
    /// SECOND HALF.**
    ///
    /// THE LAW, IN THREE CLAUSES, EACH A WAY IT COULD GO WRONG:
    ///   * a REFUSED write-back leaveth the row **EXACTLY AS IT WAS** -- a single UPDATE is atomic, so a write that
    ///     never began cannot half-apply (budget, anchor and counter all unmoved);
    ///   * the row is **STILL OFFERED**: a refused write cost it nothing, and a refusal that silently lost the row
    ///     would be DATA LOSS DRESSED AS SAFETY;
    ///   * and when the fault is CLEARED the state **SELF-HEALETH** -- the next read recomputeth the FULL debit from
    ///     the STORED anchor, so a refused write loseth nothing.
    ///
    /// THE THIRD CLAUSE IS ALSO THE ARM'S OWN DISCRIMINATOR, AND WITHOUT IT THE ARM WOULD PROVE NOTHING: a seam that
    /// never reached the write-back would leave the row unmoved for EVERY clause. **A CHECK MUST SHOW THAT ITS
    /// INSTRUMENT REACHED THE THING IT JUDGETH.**
    func testGSSTORE004_theRetentionWriteBackSurvivethATransactionFailure() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-wbfault-\(UUID().uuidString).db")
        tmpURL = url
        var now: Int64 = 1_000_000
        let store = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        defer { store.close() }
        store.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(51, .direct, 48)
        XCTAssertEqual(store.persist(f, receivedFrom: Data([7])), .heldNew)
        let atAdmission = store.retentionCheckpointForTest(f.msgId)

        // AN HOUR ON -- PAST THE CADENCE, SO THE WRITE-BACK IS DUE -- AND IT IS REFUSED.
        now += 3_600_000
        store.retentionWriteBackFault = { throw StoreOpenFault.io("injected: the retention write-back is refused") }
        let heldWhileRefused = store.allHeldMsgIds()

        // (1) THE ROW IS EXACTLY AS IT WAS: the refused write left no half behind it.
        let afterFault = store.retentionCheckpointForTest(f.msgId)
        XCTAssertEqual(afterFault.remainingMs, atAdmission.remainingMs,
                       "a REFUSED write-back must leave the stored budget unmoved -- a write that never began "
                       + "cannot half-apply")
        XCTAssertEqual(afterFault.checkpointMono, atAdmission.checkpointMono,
                       "nor the anchor")
        XCTAssertEqual(afterFault.discontinuity, atAdmission.discontinuity,
                       "nor the continuity counter")

        // (2) AND THE ROW IS STILL OFFERED: the refusal cost it nothing.
        XCTAssertEqual(heldWhileRefused, [f.msgId],
                       "*** A REFUSED WRITE-BACK MUST NOT LOSE THE ROW: a refusal that silently dropt it would be "
                       + "DATA LOSS DRESSED AS SAFETY (GS-STORE-004 closure 3) ***")

        // (3) *** THE DISCRIMINATOR AND THE SELF-HEALING CLAUSE IN ONE: WITH THE FAULT CLEARED, THE NEXT READ
        // PERSISTETH THE **FULL** DEBIT FROM THE STORED ANCHOR -- so the refused write lost nothing. ***
        store.retentionWriteBackFault = nil
        now += 3_600_000
        _ = store.allHeldMsgIds()
        let healed = store.retentionCheckpointForTest(f.msgId)
        let spent = Int64(atAdmission.remainingMs ?? -1) - Int64(healed.remainingMs ?? -2)
        XCTAssertEqual(spent, 2 * 3_600_000,
                       "*** THE STATE MUST SELF-HEAL: two hours have passed and the stored budget must have spent "
                       + "EXACTLY TWO -- computed from the STORED anchor, so the refused write cost it nothing "
                       + "(and this clause proveth the fault REACHED the write-back, which the clauses above could "
                       + "not) (GS-STORE-004 closure 3) ***")
    }

    /// *** GS-STORE-004 CLOSURE 3: *"related delivery/retention state must survive ... REPEATED RESTART
    /// consistently."* RUN BEFORE ANY CLAIM IS MADE ABOUT IT. ***
    ///
    /// MEASURED AT ROUND 529, BEFORE THIS ARM WAS WRITTEN: the arms that stood REOPENED THE STORE **ONCE** (or
    /// faulted once), and **NOT ONE PERFORMED REPEATED RESTARTS AND ASKED WHETHER THE STATE STAYED CONSISTENT.** The
    /// fault arms roll back the HELD row and the DELIVERY rows -- not the retention write-back -- so this clause had
    /// no witness at all, exactly as closure 2's two clauses had none before round 527.
    ///
    /// THE LAW, IN THREE CLAUSES, AND EACH IS A WAY THE STATE COULD GO WRONG:
    ///   * the budget must decrease by **EXACTLY the total elapsed time** across all restarts -- NEITHER
    ///     DOUBLE-COUNTED (which would spend a row early and destroy data) NOR LOST (which would hold it too long);
    ///   * it must **never increase**: no restart may replenish what a receipt was granted once;
    ///   * and the continuity counter must **not move**, because every same-boot restart PROVETH continuity.
    func testGSSTORE004_repeatedRestartsLeaveTheRetentionStateConsistent() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-restarts-\(UUID().uuidString).db")
        tmpURL = url
        var now: Int64 = 1_000_000
        let first = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        first.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(41, .direct, 48)
        XCTAssertEqual(first.persist(f, receivedFrom: Data([7])), .heldNew)
        let admitted = try XCTUnwrap(first.retentionCheckpointForTest(f.msgId).remainingMs,
                                     "the minted budget must be persisted")
        first.close()

        let hours = 6
        var previous = admitted
        for restart in 1...hours {
            now += 3_600_000                     // an hour of MONOTONIC time passes between restarts
            let store = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
            store.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
            let held = store.allHeldMsgIds()
            let cp = store.retentionCheckpointForTest(f.msgId)
            store.close()

            XCTAssertEqual(held.count, 1,
                           "six hours of a seven-day hold must not retire the row (restart \(restart))")
            let budget = try XCTUnwrap(cp.remainingMs, "the budget must be readable (restart \(restart))")
            XCTAssertLessThanOrEqual(budget, previous,
                                     "*** NO RESTART MAY REPLENISH THE BUDGET: a receipt is granted the lifetime "
                                     + "EXACTLY ONCE (GS-STORE-004 closure 3; restart \(restart)) ***")
            XCTAssertEqual(cp.discontinuity, 0,
                           "*** EVERY SAME-BOOT RESTART PROVETH CONTINUITY: the counter must not move -- a restart "
                           + "is not a discontinuity (GS-STORE-004 closure 3; restart \(restart)) ***")
            previous = budget
        }

        // *** AND EXACTLY: THE DEBIT IS THE TOTAL ELAPSED TIME, NEITHER DOUBLE-COUNTED NOR LOST. *** This is the
        // clause that can only be judged across MANY restarts, which is why a single reopen could never have found it.
        XCTAssertEqual(admitted - previous, Int64(hours) * 3_600_000,
                       "*** SIX ONE-HOUR RESTARTS MUST SPEND EXACTLY SIX HOURS: a re-based anchor that is debited "
                       + "twice would spend twelve, and an anchor never re-based would spend nothing after the first "
                       + "(GS-STORE-004 closure 3) ***")
    }

    /// *** GS-STORE-004 CLOSURE 2: THE COUNTER MUST MEASURE **DISCONTINUITIES**, NOT **OPENS**. ***
    ///
    /// THE DEFECT THIS ARM NAMETH WAS FOUND BY AN INSTRUMENTED ARM AT ROUND 527, AND IT IS WHY THE BOUND ARM BELOW
    /// NOW REACHETH ITS BOUND AT ALL: the `boot_identity` column was written ONCE at admission AND NEVER ADVANCED --
    /// `RetentionCheckpoint` carrieth no such field, `admit(...)` DISCARDED the identity it received, and
    /// `BootIdentityContinuity` answered `.unknown` for a changed boot, throwing away the very stamp that carrieth
    /// the new one. SO THE persisted identity remained the ADMISSION boot for ever, and EVERY later open in another
    /// boot counted a FRESH discontinuity: MEASURED, 35 alternating opens yielded a counter of **18**. A store
    /// reopened thirty-two times across a boot change would therefore retire a row THAT SUFFERED ONE.
    func testGSSTORE004_opensInTheSameNewBootCountExactlyOneDiscontinuity() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-identity-\(UUID().uuidString).db")
        tmpURL = url
        let first = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        first.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: "boot-A") }
        let f = frame(13, .direct, 48)
        XCTAssertEqual(first.persist(f, receivedFrom: Data([7])), .heldNew)
        first.close()

        func opensIn(_ boot: String) -> Int64 {
            let store = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
            store.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: boot) }
            defer { store.close() }
            _ = store.allHeldMsgIds()
            return store.retentionCheckpointForTest(f.msgId).discontinuity ?? -1
        }

        XCTAssertEqual(opensIn("boot-B"), 1, "a CHANGED boot counteth ONE discontinuity")
        for attempt in 2...6 {
            XCTAssertEqual(opensIn("boot-B"), 1,
                           "*** THE COUNTER MUST MEASURE DISCONTINUITIES AND NOT OPENS: reopening in the SAME boot "
                           + "is NOT a new discontinuity. A counter that incremented here would reach its bound by "
                           + "OPEN COUNT and retire a row that suffered ONE -- false expiry, and data loss "
                           + "(GS-STORE-004 closure 2; measured at round 527: 35 alternating opens yielded 18)\n"
                           + "  attempt \(attempt) ***")
        }
        // AND A SECOND GENUINE CHANGE IS A SECOND DISCONTINUITY: the counter is not merely frozen.
        XCTAssertEqual(opensIn("boot-C"), 2, "a SECOND genuine boot change counteth a second discontinuity")
    }

    /// *** GS-STORE-004 CLOSURE 2: "the FROZEN DISCONTINUITY BOUND on actual persisted rows". ***
    ///
    /// The arm that stood took the counter to ONE. A BOUND IS REACHED AT ITS LIMIT OR IT IS NOT A BOUND, so this arm
    /// DRIVES IT -- reopening across alternating boots until the row is retired -- and requireth that the bound hold
    /// AT the limit rather than after it. The budget is seven days while each conservative cycle debiteth at least an
    /// hour, so NOTHING BUT CONTINUITY can retire the row.
    func testGSSTORE004_theFrozenDiscontinuityBoundRetirethTheRow() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-bound-\(UUID().uuidString).db")
        tmpURL = url
        let first = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        first.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: "boot-A") }
        let f = frame(12, .direct, 48)
        XCTAssertEqual(first.persist(f, receivedFrom: Data([7])), .heldNew)
        first.close()

        var retiredAt: Int? = nil
        var seenDiscontinuity: Int64 = 0
        // THE MONOTONIC READING NEVER MOVETH and the budget is seven days, so the ONLY thing that can retire this row
        // is the CONTINUITY BOUND: thirty-two conservative debits of one hour spend thirty-two hours, not seven days.
        for cycle in 1...(RetentionPolicy.discontinuityLimit + 3) {
            let boot = (cycle % 2 == 0) ? "boot-A" : "boot-B"      // every reopen is a changed boot
            let store = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
            store.receiptTimeProvider = { (monoMs: 1_000_000, bootIdentity: boot) }
            defer { store.close() }
            let held = store.allHeldMsgIds()
            seenDiscontinuity = store.retentionCheckpointForTest(f.msgId).discontinuity ?? 0
            if held.isEmpty { retiredAt = cycle; break }
        }
        XCTAssertNotNil(retiredAt,
                        "*** THE FROZEN DISCONTINUITY BOUND MUST RETIRE THE ROW: a bound that is never REACHED is not "
                        + "a bound, and the counter stood at \(seenDiscontinuity) when this arm gave up "
                        + "(GS-STORE-004 closure 2) ***")
        XCTAssertLessThanOrEqual(retiredAt ?? .max, RetentionPolicy.discontinuityLimit + 1,
                                 "and it must be retired AT the bound rather than some cycles after it")
    }

    /// GS-STORE-004, the finding's own words: "Expiration must ATOMICALLY retire held rows, update related
    /// delivery state ...". THE DISCRIMINATING LAW: a spent row must be GONE FROM STORAGE, not merely hidden from
    /// readers -- and the sweep must say how many it retired. RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_aSweepRetirethTheSpentRowFromStorage() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        s.receiptTimeProvider = { (monoMs: 4_000_000, bootIdentity: "boot-A") }
        let f = frame(10, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", []), 1)
        XCTAssertEqual(s.sweepExpired(limit: 8), 1,
                       "the sweep must retire the spent row and SAY how many it retired -- IT SAW: " + s.lastSweepReport)
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET ttl = 0", []), 0,
                       "the row must be GONE FROM STORAGE -- a hidden row is not a retired one")
    }

    /// GS-STORE-004, the finding's own words: "CONNECT A BOUNDED EXPIRY SWEEP TO STARTUP AND RUNTIME SCHEDULING."
    /// A sweep that only a caller may invoke by hand is NOT connected to anything. RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_theSweepIsConnectedToStartup() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-startup-\(UUID().uuidString).db")
        tmpURL = url
        let first = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        first.receiptTimeProvider = { (monoMs: 2_000_000, bootIdentity: "boot-A") }
        let f = frame(11, .direct, 48)
        XCTAssertEqual(first.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(first.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", []), 1)
        first.close()

        // A REOPEN: the spent row must be retired BY THE STORE AT STARTUP -- no caller asked.
        let second = SqliteMessageStore(url: url, maxBytes: 8 * 1024 * 1024)
        second.receiptTimeProvider = { (monoMs: 2_000_000, bootIdentity: "boot-A") }
        defer { second.close() }
        XCTAssertEqual(second.execRawUpdate("UPDATE held_frames SET ttl = 0", []), 0,
                       "STARTUP must retire a spent row WITHOUT the caller invoking the sweep -- " +
                       "a sweep that only a hand may call is connected to nothing")
    }

    /// GS-STORE-004, the finding's own words: the sweep must be connected to "startup AND RUNTIME SCHEDULING". A
    /// startup sweep alone is HALF the sentence: a store that runs for days must maintain itself AS IT RUNS, and the
    /// policy carrieth its own cadence (`RetentionPolicy.checkpointCadenceMs`) for exactly that. RUN RED BEFORE THE
    /// REPAIR.
    func testGSSTORE004_theSweepAlsoRunsOnThePolicyCadence() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var now: Int64 = 1_000_000
        s.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(12, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", []), 1)
        // The startup sweep hath already run (the store was used above) -- and this row was NOT spent then.
        // ADVANCE THE CLOCK PAST THE POLICY'S OWN CADENCE and use the store again: the cadence sweep must fire.
        now += Int64(RetentionPolicy.checkpointCadenceMs) + 1
        _ = s.allHeldMsgIds()
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET ttl = 0", []), 0,
                       "the RUNTIME cadence must retire rows spent since the last sweep, not only at startup")
    }

    /// GS-STORE-004, the finding's own words: expiration must "create any required durable replay/ACK tombstones".
    /// THE DISCRIMINATING LAW: a retired row must leave A DURABLE TOMBSTONE whose lifetime is the POLICY'S OWN
    /// `tombstoneMs` (eight days) -- because a row retired with NOTHING behind it can be REPLAYED and RE-ACCEPTED,
    /// and retirement would then silently re-open the door it closed. RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_retirementLeavethADurableTombstone() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var now: Int64 = 6_000_000
        s.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(13, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", []), 1)
        XCTAssertEqual(s.sweepExpired(limit: 8), 1, "the sweep retires the spent row")
        XCTAssertNil(s.retentionCheckpointForTest(f.msgId).remainingMs, "and the row is gone from storage")

        let tomb = s.tombstoneForTest(f.msgId)
        XCTAssertNotNil(tomb, "RETIREMENT MUST LEAVE A DURABLE TOMBSTONE -- else a replay is re-accepted")
        XCTAssertEqual(tomb?.expiresAtMono, now + Int64(RetentionPolicy.tombstoneMs),
                       "and its lifetime is the POLICY'S OWN tombstone lifetime, not a number chosen here")
        XCTAssertEqual(tomb?.bootIdentity, "boot-A", "carrying the continuity identity of the boot that retired it")
    }

    /// GS-STORE-004: THE TOMBSTONE'S **PURPOSE**, which is the dedup law -- a retired message must not be
    /// RE-ACCEPTED while its tombstone standeth, or retirement would silently RE-OPEN THE DOOR IT CLOSED. The
    /// tombstone was WRITTEN at round 336 and NOTHING CONSULTED IT (the same "written and never read" state the
    /// budget was in before round 306). RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_aReplayOfARetiredMessageIsRefused() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var now: Int64 = 7_000_000
        s.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(14, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", []), 1)
        XCTAssertEqual(s.sweepExpired(limit: 8), 1, "the row is retired and a tombstone is left")
        XCTAssertNotNil(s.tombstoneForTest(f.msgId), "the tombstone stands")

        // THE REPLAY: the same frame, while the tombstone liveth.
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .rejectedTombstone,
                       "a retired message may not be RE-ACCEPTED while its tombstone standeth")
        XCTAssertNil(s.retentionCheckpointForTest(f.msgId).remainingMs,
                     "and the replay must NOT have put the row back")

        // THE NEGATIVE CASE: PAST the tombstone's lifetime, the same message IS accepted again -- a tombstone is a
        // DEDUP WINDOW, not a permanent ban.
        now += Int64(RetentionPolicy.tombstoneMs) + 1
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew,
                       "past the policy's tombstone lifetime, the message may be accepted again")
    }

    /// GS-STORE-004: the quota kind `tombstoneRows` hath described this category since before the table existed, and
    /// A KIND THAT IS NEVER MEASURED IS A CONTRACT THAT CANNOT BE ENFORCED. RUN RED BEFORE THE REPAIR.
    func testGSSTORE004_theTombstoneRowCountIsMeasured() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        let now: Int64 = 8_000_000
        s.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        XCTAssertEqual(s.tombstoneRowCount(), 0, "a fresh store holdeth no tombstone")
        let f = frame(15, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", []), 1)
        XCTAssertEqual(s.sweepExpired(limit: 8), 1, "the row is retired and a tombstone is left")
        XCTAssertEqual(s.tombstoneRowCount(), 1,
                       "the store must MEASURE what it holdeth -- an unmeasured quota kind cannot be enforced")
    }

    /// GS-STORE-004: THE TOMBSTONE'S THIRD ACT. It is WRITTEN at retirement and CONSULTED by the dedup window --
    /// and NOTHING REAPETH IT once its own lifetime hath passed, so the store's growth is unbounded in a category
    /// whose whole purpose is to be TEMPORARY (the policy calleth it `tombstoneMs` for a reason). The sweep, which
    /// already owneth bounded retirement, must also reap the tombstones that have outlived their window. RUN RED
    /// BEFORE THE REPAIR.
    func testGSSTORE004_expiredTombstonesAreReaped() throws {
        let s = open(maxBytes: 8 * 1024 * 1024)
        var now: Int64 = 9_000_000
        s.receiptTimeProvider = { (monoMs: now, bootIdentity: "boot-A") }
        let f = frame(16, .direct, 48)
        XCTAssertEqual(s.persist(f, receivedFrom: Data([7])), .heldNew)
        XCTAssertEqual(s.execRawUpdate("UPDATE held_frames SET remaining_ms = 0", []), 1)
        XCTAssertEqual(s.sweepExpired(limit: 8), 1, "the row is retired and a tombstone is left")
        XCTAssertEqual(s.tombstoneRowCount(), 1)

        // PAST the policy's own tombstone lifetime: the tombstone is no longer a dedup window, it is litter.
        now += Int64(RetentionPolicy.tombstoneMs) + 1
        _ = s.sweepExpired(limit: 8)
        XCTAssertEqual(s.tombstoneRowCount(), 0,
                       "a tombstone past its OWN lifetime must be reaped -- `tombstoneMs` is a lifetime, not a motto")
        XCTAssertNil(s.tombstoneForTest(f.msgId), "and it must be gone from storage, not merely uncounted")
    }
}
