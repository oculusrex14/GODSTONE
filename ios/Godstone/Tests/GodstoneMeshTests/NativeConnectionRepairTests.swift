import XCTest
import Foundation
import SQLite3
@testable import GodstoneMesh

// ================================================================================================
// *** NATIVE CONNECTION REPAIR COURTS (SQLITE-REVIEW-1/2/3/4/6/7/8). ***
//
// *EVERY ARM HERE DRIVES THE **PRODUCTION** ROAD -- `SqliteMessageStore`/`SqlitePeerIdentityStore`,
// `OwnedConnection`, `SqlCipherDylibEngine`, `HandleMigrationExecutor` -- WITH AN INTERNAL INJECTION SEAM WHERE A FAULT MUST
// BE FORCED. NO COPIED FAKE STORE, NO SOURCE-TEXT MATCH, NO NAMED-COUNTER-ONLY ORACLE, AND NO `XCTSkip` FOR A LIBRARY THIS
// REPOSITORY CAN BUILD ITSELF.*
//
// The pinned SQLCipher library is built by `tools/supplychain/build_sqlcipher_simulator.sh` -- a REPOSITORY-BUILDABLE
// road -- and it is staged for this lane by the host supply (`GODSTONE_SQLCIPHER_ARTIFACT_DIR`). *** SQLITE-LATEST-I6:
// A MISSING IMAGE ON THIS LANE IS A COURT/SYSTEM FAILURE, NOT A SKIP. *** *A skipped native acceptance lets an
// acceptance campaign count a road it never exercised as green; the mandatory arms below XCTFail with the exact
// staging reason so the lane reddens where the supply is absent.*
// ================================================================================================

// MARK: - helpers

private func ncrTempPath(_ name: String) -> String {
    NSTemporaryDirectory() + "/ncr-\(name)-\(UUID().uuidString)/msg.db"
}

/// Read `PRAGMA user_version` from a real file with a THROWAWAY handle, so a durable checkpoint can be observed
/// independently of the store that wrote it.
private func ncrReadUserVersion(_ path: String) -> Int? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
    defer { sqlite3_close_v2(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int(stmt, 0))
}

private func ncrMakeDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
}

private func ncrMsgId(_ seed: UInt8) -> Data { Data((0..<16).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) }) }

private func ncrFrame(_ seed: UInt8, payload: Data) -> FrameV2 {
    FrameV2(type: .message, msgId: ncrMsgId(seed), routingTag: Data([9, 8, 7, 6]),
            ttl: 12, hopCount: 0, flags: Priority.toFlags(.direct) | UInt16(FrameV2.Flags.sealed),
            payload: payload)
}

// ================================================================================================
// *** SQLITE-LATEST-I4 (NATIVE6): THE EXISTING PROVIDER-TABLE SEAM, WITH A FAULTABLE `bindText`. ***
//
// *The store's provider TRAVELLETH WITH ITS CONNECTION (`OwnedVerifiedConnection.provider`), so a court can hand the
// PRODUCTION store a table whose `sqlite3_bind_text` REFUSES -- the exact native fault the P1 finding names
// (`SQLITE_NOMEM` while making the parameter NULL) -- WITHOUT fabricating a trusted SQLCipher image.* **Every other
// entry point delegates to the platform `sqlite3`, so the store's own migrations and SQL run for real and only the
// injected entry point is faulted. This is the SAME `SQLiteFunctionTable` seam `GsFinal004OwnedConnectionTests`
// drives; the production road is untouched (`nil` in production).**
// ================================================================================================
private let ncrTableLock = NSLock()
private var ncrBootBindFault: Int32? = nil          // non-nil: refuse the REAP's boot-identity text bind
private var ncrCommitExecFault: Int32? = nil        // non-nil: refuse an EXEC whose SQL is exactly "COMMIT"

private func ncrResetTableFaults() {
    ncrTableLock.lock()
    ncrBootBindFault = nil
    ncrCommitExecFault = nil
    ncrTableLock.unlock()
}

private func ncrExecThunk(_ db: OpaquePointer?, _ sql: UnsafePointer<CChar>?,
                          _ callback: (@convention(c) (UnsafeMutableRawPointer?, Int32,
                                                       UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                                                       UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32)?,
                          _ context: UnsafeMutableRawPointer?,
                          _ errmsg: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    if let sql, String(cString: sql) == "COMMIT" {
        ncrTableLock.lock(); let fault = ncrCommitExecFault; ncrTableLock.unlock()
        if let fault { return fault }
    }
    return sqlite3_exec(db, sql, callback, context, errmsg)
}

/// *** THE REAP'S BOOT-IDENTITY BIND IS THE **ONLY** TEXT BIND AT INDEX 1 IN THIS STORE (the reap statement binds
/// `boot_identity` first). Gating on the index AND the probe identity keepeth the fault SURGICAL: the tombstone
/// INSERT's boot bind (index 3) and the held-row INSERT's (index 13) are NOT faulted, so the court measureth the
/// REAP road alone.***
private func ncrBindTextThunk(_ stmt: OpaquePointer?, _ index: Int32, _ text: UnsafePointer<CChar>?,
                              _ n: Int32,
                              _ destructor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32 {
    ncrTableLock.lock(); let fault = ncrBootBindFault; ncrTableLock.unlock()
    if let fault, index == 1, let text, String(cString: text) == "ncr-probe-boot" { return fault }
    return sqlite3_bind_text(stmt, index, text, n, destructor)
}

private func ncrTable() -> SQLiteFunctionTable {
    SQLiteFunctionTable(
        providerName: "native6-instrumented",
        openV2: { a, b, c, d in sqlite3_open_v2(a, b, c, d) },
        closeV2: { h in sqlite3_close_v2(h) },
        busyTimeout: { h, ms in sqlite3_busy_timeout(h, ms) },
        exec: ncrExecThunk,
        changes: { h in sqlite3_changes(h) },
        errmsg: { h in sqlite3_errmsg(h) },
        prepareV2: { a, b, c, d, e in sqlite3_prepare_v2(a, b, c, d, e) },
        step: { s in sqlite3_step(s) },
        finalize: { s in sqlite3_finalize(s) },
        bindBlob: { a, b, c, d, e in sqlite3_bind_blob(a, b, c, d, e) },
        bindInt: { a, b, c in sqlite3_bind_int(a, b, c) },
        bindInt64: { a, b, c in sqlite3_bind_int64(a, b, c) },
        bindNull: { a, b in sqlite3_bind_null(a, b) },
        bindText: ncrBindTextThunk,
        columnBlob: { a, b in sqlite3_column_blob(a, b) },
        columnBytes: { a, b in sqlite3_column_bytes(a, b) },
        columnInt: { a, b in sqlite3_column_int(a, b) },
        columnInt64: { a, b in sqlite3_column_int64(a, b) },
        columnText: { a, b in sqlite3_column_text(a, b) },
        columnType: { a, b in sqlite3_column_type(a, b) })
}

/// *** A REAL ADOPTED `SqliteMessageStore` RUNNING ON THE INSTRUMENTED TABLE (the existing test seam, no fabricated
/// image). *** *The connection is minted in the test module exactly as the engine would hand one over, carrying the
/// instrumented provider and a SHARED `ConnectionLifecycle` -- so the store's migrations/SQL run for real over the
/// platform image and the OWNER's deferred close is the exact production lifecycle.*
private func ncrAdoptedInstrumentedStore(_ path: String, maxBytes: Int64 = 64 * 1024 * 1024)
    -> (store: SqliteMessageStore, owned: OwnedConnection)? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          let handle = db else { return nil }
    let verified = OwnedVerifiedConnection(
        rawHandle: handle, engineKind: .pinnedSQLCipher, cipherVersion: 4,
        encryptedAtRest: true, path: path, provider: ncrTable(), lifecycle: ConnectionLifecycle())
    let owned = OwnedConnection(connection: verified) { h in _ = sqlite3_close_v2(h) }
    return (SqliteMessageStore(verifiedConnection: owned, maxBytes: maxBytes), owned)
}

/// A spent tombstone seeded through a THROWAWAY handle, in the boot the store's clock names, so the reap has a real
/// row to delete and the court can observe whether it was reaped.
private func ncrSeedSpentTombstone(_ path: String, _ msgId: Data, expiresAtMono: Int64, boot: String) {
    var tdb: OpaquePointer?
    guard sqlite3_open_v2(path, &tdb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let tdb else { return }
    defer { sqlite3_close_v2(tdb) }
    let sql = "INSERT OR REPLACE INTO \(StoreSchema.tombstoneTable) (\(StoreSchema.colTMsgId), " +
        "\(StoreSchema.colTExpiresAtMono), \(StoreSchema.colTBootIdentity)) VALUES (?,?,?)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(tdb, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
    defer { sqlite3_finalize(stmt) }
    msgId.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(msgId.count),
                                              unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    sqlite3_bind_int64(stmt, 2, expiresAtMono)
    boot.withCString { sqlite3_bind_text(stmt, 3, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    _ = sqlite3_step(stmt)
}

/// A WELL-FORMED intent entry (all width guards satisfied), so the refusal arms measure the ABANDONED connection
/// rather than a rejected initializer.
private func ncrJournalEntry(intentId: Data) -> JournalEntry {
    JournalEntry(intentId: intentId, logicalMessageId: ncrMsgId(0x41), signedPlaintextBytes: Data([0x01]),
                 canonicalFrameBytes: Data([0xAA, 0xAA]), recipientNodeId: ncrMsgId(0x42),
                 recipientStaticDhPub: Data(repeating: 3, count: 32), acceptedGeneration: 1,
                 bindingDigest: Data(repeating: 4, count: 32), createdAtEpochSeconds: 1_700_000_000,
                 messageNonce: Data(repeating: 5, count: 16), priorityCode: 0, stateRank: .authored)!
}

/// *** THE TOMBSTONE CENSUS READ **AROUND THE STORE** (a throwaway handle), so an arm can observe whether a row
/// stands WITHOUT triggering the store's own first-use/cadence sweep -- the store's `withDb` read path runneth a
/// maintenance sweep, which would itself reap the very row under observation. ***
private func ncrRawTombstoneCount(_ path: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return -1 }
    defer { sqlite3_close_v2(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(StoreSchema.tombstoneTable)", -1, &stmt, nil) == SQLITE_OK,
          let stmt else { return -1 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int(stmt, 0))
}

/// *** THE SPECIFIC GHOST ROW'S PRESENCE, READ AROUND THE STORE. *** *`tombstoneRowCount()` runneth a maintenance
/// sweep and so MUTATES the ledger it reports; and a raw count is polluted by every OTHER live tombstone. This asks
/// the one question the arms care about -- "doth THIS seeded spent tombstone still stand?" -- over a throwaway
/// handle, with no store-side mutation.*
private func ncrRawTombstoneExists(_ path: String, _ msgId: Data) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return false }
    defer { sqlite3_close_v2(db) }
    var stmt: OpaquePointer?
    let sql = "SELECT 1 FROM \(StoreSchema.tombstoneTable) WHERE \(StoreSchema.colTMsgId) = ? LIMIT 1"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
    defer { sqlite3_finalize(stmt) }
    msgId.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(msgId.count),
                                              unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    return sqlite3_step(stmt) == SQLITE_ROW
}

/// *** A SECOND REAL PLATFORM SQLITE CONNECTION THAT ACQUIRES A WRITE LOCK AND PERSISTS A ROW. ***
///
/// *This is the CONSUMER-VISIBLE discriminator for "the connection was PHYSICALLY closed", NOT merely flag-latched:
/// a `BEGIN IMMEDIATE` carrieth a RESERVED lock, so if an ABANDONED connection still held the unresolved write
/// transaction, THIS connection's `BEGIN IMMEDIATE` would answer `SQLITE_BUSY` (a small, deterministic `busy_timeout`
/// maketh it so without waiting on tolerance). If the handle was really closed -- and SQLite therefore rolled back
/// and released the lock -- it succeedeth IMMEDIATELY and the write is durable.*
///
/// **`busyMs` is deliberately SMALL and fixed**, so the arm is deterministic: lock-holder -> `SQLITE_BUSY`, freed ->
/// `SQLITE_OK`, with no timing tolerance to bump.
private func ncrSecondConnectionWrite(_ path: String, busyMs: Int32 = 100) -> Int32 {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return SQLITE_ERROR }
    defer { sqlite3_close_v2(db) }
    sqlite3_busy_timeout(db, busyMs)
    var rc = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
    guard rc == SQLITE_OK else { return rc }
    let sql = "INSERT OR REPLACE INTO \(StoreSchema.tombstoneTable) (\(StoreSchema.colTMsgId), " +
        "\(StoreSchema.colTExpiresAtMono), \(StoreSchema.colTBootIdentity)) VALUES (?,?,?)"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
        _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil); return SQLITE_ERROR
    }
    let probe = Data(repeating: 0xE1, count: 16)
    probe.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(probe.count),
                                              unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    sqlite3_bind_int64(stmt, 2, 0)
    "ncr-second".withCString { sqlite3_bind_text(stmt, 3, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    let stepRC = sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    guard stepRC == SQLITE_DONE else {
        _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil); return stepRC
    }
    rc = sqlite3_exec(db, "COMMIT", nil, nil, nil)
    return rc
}

final class NativeConnectionRepairTests: XCTestCase {

    // ================================================================================================
    // *** SQLITE-REVIEW-8: A STORAGE FAULT ON THE INTENT SELECT IS **NOT** ABSENCE. ***
    // ================================================================================================
    func testReview8IntentReadFaultIsStorageFailureNeverAbsence() throws {
        let path = ncrTempPath("intent-fault")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let store = SqliteMessageStore(url: URL(fileURLWithPath: path), maxBytes: 64 * 1024 * 1024)
        guard case .opened = store.openOutcome else { return XCTFail("rig must open: \(store.openOutcome)") }

        // A GENUINELY ABSENT INTENT IS ABSENCE -- the control that makes the fault arm mean something.
        let absent = try store.readIntent(ncrMsgId(0x40))
        XCTAssertNil(absent, "an intent that was never stored is ABSENCE (nil), not a fault")

        // NOW FORCE `SQLITE_IOERR` AT THE SELECT'S `step` THROUGH THE PRODUCTION READER.
        store.intentReadFaultForTest = { 10 }   // SQLITE_IOERR
        XCTAssertThrowsError(
            try store.readIntent(ncrMsgId(0x41)),
            "*** A STORAGE FAULT ON THE INTENT SELECT MUST THROW, NOT ANSWER `nil`. *The previous body returned `nil` for "
                + "EVERY non-ROW step result, and `SqliteOutboundIntentJournal` translates `nil` to `.notFound` -- which "
                + "`SendDirectAuthority` treats as permission to enter FRESH trust resolution and nonce creation. A BUSY/"
                + "IOERR/NOTADB read of a stored durable intent therefore became authority to author a new one.* ***",
        ) { _ in
            // the store threw -- which is the point: the journal's own `catch` maps it to `.storageFailure`
            // (asserted immediately below through the seam).
        }
        store.intentReadFaultForTest = nil

        // AND THE SEAM TRANSLATES IT: a fault -> `.storageFailure`, never `.notFound`.
        store.intentReadFaultForTest = { 10 }
        let journal = SqliteOutboundIntentJournal(store: store)
        switch journal.load(ncrMsgId(0x42)) {
        case .storageFailure: break
        case .notFound:
            XCTFail("*** A STORAGE FAULT MUST NOT REACH THE CALLER AS `.notFound` -- that is the whole finding. ***")
        default:
            XCTFail("expected .storageFailure")
        }
        store.intentReadFaultForTest = nil
    }

    // ================================================================================================
    // *** SQLITE-REVIEW-2: OWNER CLOSE WAITS FOR ACTIVE USE, AND POST-CLOSE USE IS A TYPED REFUSAL. ***
    // ================================================================================================
    func testReview2OwnerCloseWaitsForActiveUseAndRefusesAfterwards() throws {
        let path = ncrTempPath("close-wait")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let engine = SqlCipherDylibEngine()
        guard ncrRequirePinnedImage(engine, lane: "review2 close-wait") else { return }
        let dek = StoreDEK(bytes: Data(repeating: 0x3C, count: 32))
        let owned = try engine.openOwnedForWriting(path: path, dek: dek)

        // *** HOLD A REAL USE, START CLOSE ON ANOTHER WORKER, AND REQUIRE CLOSE TO HAVE NOT COMPLETED. ***
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let useDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? owned.usingConnection { _ in
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            useDone.signal()
        }
        XCTAssertEqual(.success, entered.wait(timeout: .now() + 2),
                       "*** the held use must reach the critical section -- bounded, so a mis-driven arm reddens rather than hangs ***")
        XCTAssertEqual(owned.activeUsesForTest, 1, "the use must be observably in flight before close is attempted")

        let closeReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = owned.close(); closeReturned.signal() }
        XCTAssertEqual(
            .timedOut, closeReturned.wait(timeout: .now() + 0.3),
            "*** `OwnedConnection.close()` MUST WAIT FOR AN ACTIVE USE, NOT RACE IT. *The previous body marked closed and "
                + "freed immediately; a worker between prepare/step/finalize then dispatched through a freed or zombied "
                + "handle. A close that returns while a use is in flight is the defect this arm witnesses.* ***",
        )

        release.signal()
        XCTAssertEqual(.success, useDone.wait(timeout: .now() + 2),
                       "the held use must return once released (bounded)")
        XCTAssertEqual(.success, closeReturned.wait(timeout: .now() + 2), "close completes once the use drains")
        XCTAssertTrue(owned.isClosed)

        // *** AND A POST-CLOSE USE IS A TYPED REFUSAL, NOT A STALE-HANDLE DISPATCH. ***
        XCTAssertThrowsError(try owned.usingConnection { _ in 0 },
                             "a use after close must be REFUSED (ownerClosed), never dispatched to SQLite") { error in
            XCTAssertEqual(
                error as? StoreConnectionError, .ownerClosed,
                "*** THE POST-CLOSE REFUSAL MUST NAME THE TYPED `.ownerClosed` GATE -- a bare `throws` is not the claim. "
                    + "The mutant `NCR-03` neuters the admission (`beginUse() || true`), so NO error is thrown at all and "
                    + "this assertion reddens. ***",
            )
        }
        XCTAssertEqual(
            0, owned.activeUsesForTest,
            "and it must not have incremented the use count",
        )

        // ================================================================================================
        // *** PHASE B -- THE **STORE'S** OWN THROWING ROAD MUST ADMIT ITSELF AGAINST THE OWNER'S USE/CLOSE CRITICAL
        // SECTION. ***
        //
        // *A DIRECT `owned.usingConnection` arm cannot see the SQLITE-REVIEW-2 hole: what `MessageStore.withDbThrowing`
        // carrieth is that its THROWING operations skip the owner's admission and dispatch `dbSectionThrowing`
        // directly. So this phase drives the REAL adopted store's intent reader -- through `withDbThrowing` -- and
        // holds it INSIDE the fault seam (a deterministically bounded in-flight point) while a concurrent `close()` is
        // attempted.*
        //
        // **A STORE OPERATION THAT SKIPS THE ADMISSION LEAVES `activeUsesForTest` AT 0 AND LETS `close()` FREE THE
        // NATIVE HANDLE IMMEDIATELY -- the two named assertions below then redden (the mutant `NCR-01`).** *The hold
        // is released before any further statement runs, so the mutant is observed by a bounded use-count/close
        // discriminator rather than by a crash.*
        // ================================================================================================
        let pathB = ncrTempPath("close-wait-store")
        ncrMakeDir(pathB)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: pathB)) }
        let dekB = StoreDEK(bytes: Data(repeating: 0x4D, count: 32))
        let ownedB = try engine.openOwnedForWriting(path: pathB, dek: dekB)
        let storeB = SqliteMessageStore(verifiedConnection: ownedB, maxBytes: 64 * 1024 * 1024)
        guard case .opened = storeB.openOutcome else {
            return XCTFail("the adopted store must open: \(storeB.openOutcome)")
        }

        let enteredB = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        let opDoneB = DispatchSemaphore(value: 0)
        // SQLITE_DONE -- a real, non-throwing absence answer, so the body runs to its `defer { finalize }` on release.
        storeB.intentReadFaultForTest = { enteredB.signal(); _ = releaseB.wait(timeout: .now() + 5); return 101 }
        DispatchQueue.global().async {
            _ = try? storeB.readIntent(ncrMsgId(0x40))
            opDoneB.signal()
        }
        XCTAssertEqual(.success, enteredB.wait(timeout: .now() + 2),
                       "*** the held store operation must reach the fault seam -- bounded, so a mis-driven arm reddens rather than hangs ***")
        XCTAssertEqual(
            ownedB.activeUsesForTest, 1,
            "*** A **STORE** THROWING OPERATION MUST ADMIT ITSELF AGAINST THE OWNER'S USE/CLOSE CRITICAL SECTION. "
                + "*`withDbThrowing` must run its body INSIDE `owner.usingConnection`; a store whose throwing path "
                + "dispatched `dbSectionThrowing` directly would leave the use count at 0 -- exactly the SQLITE-REVIEW-2 "
                + "hole this arm witnesses (the mutant `NCR-01`).* ***",
        )
        guard ownedB.activeUsesForTest == 1 else {
            // *** BOUNDED AND ATTRIBUTABLE (NCR-01). *** *The named assertion above IS the witness. A store operation
            // that SKIPPED the owner's admission has already let a concurrent `close()` free the native handle; do NOT
            // dispatch another store statement here (it would answer through a closed handle, or hang on the store's
            // own lock when the peer-transaction mutant is in force). Release the in-flight use and stop at the red we
            // caused, so the roster reports an assertion failure rather than a timeout.*
            releaseB.signal()
            return
        }

        let closeReturnedB = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = ownedB.close(); closeReturnedB.signal() }
        XCTAssertEqual(
            .timedOut, closeReturnedB.wait(timeout: .now() + 0.3),
            "*** `close()` MUST WAIT FOR A **STORE** OPERATION, NOT MERELY A DIRECT `usingConnection`. *If the store's "
                + "throwing body skipped the owner's admission, close would free the native handle out from under an "
                + "open statement and return at once -- this assertion reddens (the mutant `NCR-01`).* ***",
        )
        releaseB.signal()
        XCTAssertEqual(.success, opDoneB.wait(timeout: .now() + 2),
                       "the held store operation must return once released (bounded)")
        storeB.intentReadFaultForTest = nil
        XCTAssertEqual(.success, closeReturnedB.wait(timeout: .now() + 2),
                       "close completes once the store operation drains")
        XCTAssertTrue(ownedB.isClosed)

        // *** AND A POST-CLOSE USE OF THE SECOND OWNER IS THE SAME TYPED REFUSAL (`{ _ in 0 }` -- NO native dispatch). ***
        XCTAssertThrowsError(try ownedB.usingConnection { _ in 0 },
                             "*** a use after the second owner's close must be REFUSED ***") { error in
            XCTAssertEqual(error as? StoreConnectionError, .ownerClosed,
                           "*** the second owner must surface the SAME typed `.ownerClosed` gate (the mutant `NCR-03`). ***")
        }
        XCTAssertEqual(0, ownedB.activeUsesForTest, "and the refused use must not have counted")
    }

    // ================================================================================================
    // *** SQLITE-REVIEW-3/1: A REJECTED ADOPTION IS UNUSABLE, AND AN ADOPTED STORE KEEPS THE IMAGE ALIVE. ***
    // ================================================================================================
    func testReview3RejectedAdoptionIsRefusedAndLeaseHeld() throws {
        let path = ncrTempPath("rejected")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let engine = SqlCipherDylibEngine()
        guard ncrRequirePinnedImage(engine, lane: "review3 rejected-adoption") else { return }
        let dek = StoreDEK(bytes: Data(repeating: 0x21, count: 32))
        let owned = try engine.openOwnedForWriting(path: path, dek: dek)

        // AN ADOPTION THE STORE REFUSES (the at-rest guard) MARKETH THE CONNECTION UNUSABLE.
        owned.connection.lifecycle?.markAdoptionRejected()
        let store = SqliteMessageStore(verifiedConnection: owned, maxBytes: 1024)
        guard case .failed = store.openOutcome else {
            return XCTFail("a rejected connection must fail the store's open, got \(store.openOutcome)")
        }
        XCTAssertThrowsError(
            try owned.usingConnection { _ in 0 },
            "*** A REJECTED ADOPTION MUST BE UNUSABLE: a store that refused the connection must not leave it dispatchable. ***",
        )
        XCTAssertEqual(store.adoptedConnectionIdentity, nil, "and the store must not report adopting it")
    }

    // ================================================================================================
    // *** SQLITE-REVIEW-4: A TORN `user_version` STAMP NEVER CLAIMS A DURABLE ADVANCEMENT. ***
    // ================================================================================================
    func testReview4TornMigrationStampLeavesDurableVersionUnadvanced() throws {
        let path = ncrTempPath("torn-stamp")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        // THE STORE OPENS AND CREATES ITS CURRENT SCHEMA (revision 10).
        let store = SqliteMessageStore(url: URL(fileURLWithPath: path), maxBytes: 1024)
        guard case .opened = store.openOutcome else { return XCTFail("rig must open: \(store.openOutcome)") }

        // THEN THE FILE IS STAMPED **DOWN** TO 9 THROUGH A SECOND RAW HANDLE -- the migration courts' own fixture shape
        // ("current DDL, stamped down"), so the `9 -> 10` edge has only a STAMP to write (its DDL is idempotent/skipped).
        var handle: OpaquePointer?
        XCTAssertEqual(SQLITE_OK, sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil))
        let db = try XCTUnwrap(handle)
        XCTAssertEqual(SQLITE_OK, sqlite3_exec(db, "PRAGMA user_version = 9", nil, nil, nil))

        let executor = SqliteMessageStore.makeMigrationExecutorForTest(store: store, db: db, checkpoint: 9)
        let engine = SchemaMigrationEngine(
            steps: StoreSchema.migrationPlan(from: 9, creatingTables: false, supportedMax: Int(StoreSchema.dbVersion)),
            supportedMax: Int(StoreSchema.dbVersion), fingerprint: StoreSchema.frozenFingerprint)
        // The DDL is skipped (tables already stand); only the STAMP runs -- and it is FORCED TO FAIL.
        store.migrationStampFaultForTest = { 10 }   // SQLITE_IOERR on the version write
        let verdict = engine.migrate(currentVersion: 9,
                                     observed: SqliteMessageStore.observeFingerprintForTest(store, db: db),
                                     executor: executor)
        store.migrationStampFaultForTest = nil
        sqlite3_close_v2(db)

        guard case .failed = verdict else { return XCTFail("a torn edge must fail, got \(verdict)") }
        XCTAssertEqual(executor.checkpointedThrough(), 9,
                       "*** A FAILED EDGE MUST NOT ADVANCE THE IN-MEMORY CHECKPOINT. ***")
        XCTAssertEqual(
            ncrReadUserVersion(path), 9,
            "*** AND THE DURABLE `user_version` MUST STILL BE 9. *The stamp is written INSIDE the edge's transaction, so a "
                + "failed edge rolls it back. The PREVIOUS body stamped it in a SEPARATE, untransactional statement with "
                + "`try?` and advanced the memory checkpoint regardless -- so a store could publish `.opened`/`.upgraded` "
                + "over a revision that never moved. THIS ARM DISCRIMINATES THE TWO: restore that body and the durable "
                + "version becomes 10 (or the memory checkpoint advances), and the assertion reddens.* ***",
        )
    }

    // ================================================================================================
    // *** SQLITE-REVIEW-6/7: THE REAL PINNED SQLCIPHER, POPULATED, EXACT-BYTES, CLOSE/REOPEN, REFUSED WITHOUT THE KEY. ***
    // ================================================================================================
    func testReview6RealPinnedRoundTripExactBytesAndWrongKeyRefusal() throws {
        let engine = SqlCipherDylibEngine()
        guard ncrRequirePinnedImage(engine, lane: "review6 pinned-roundtrip") else { return }
        let path = ncrTempPath("pinned")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let dek = StoreDEK(bytes: Data(repeating: 0x5E, count: 32))
        let payload = Data((0..<512).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let frame = ncrFrame(0x11, payload: payload)

        // POPULATE THROUGH AN ADOPTED CONNECTION, THEN CLOSE BOTH THE STORE AND ITS OWNER.
        do {
            let owned = try engine.openOwnedForWriting(path: path, dek: dek)
            let store = SqliteMessageStore(verifiedConnection: owned, maxBytes: 64 * 1024 * 1024)
            guard case .opened = store.openOutcome else { return XCTFail("store must open: \(store.openOutcome)") }
            XCTAssertEqual(.heldNew, store.persist(frame, receivedFrom: Data(repeating: 0xAB, count: 8)))
            store.close()
            XCTAssertTrue(owned.close())
        }

        // *** AND THE FILE IS NOT A PLAINTEXT SQLITE DATABASE. ***
        let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)).readData(ofLength: 16)
        XCTAssertNotEqual(
            header, Data("SQLite format 3\0".utf8),
            "*** A POPULATED STORE MUST NOT CARRY THE PLAINTEXT SQLITE HEADER -- else it is readable by stock sqlite3 "
                + "regardless of the key. ***",
        )

        // REOPEN WITH THE CORRECT KEY AND READ THE EXACT BYTES.
        let reopened = try engine.reopenOwnedRequiringDEK(path: path, dek: dek)
        let store2 = SqliteMessageStore(verifiedConnection: reopened, maxBytes: 64 * 1024 * 1024)
        guard case .opened = store2.openOutcome else { return XCTFail("reopen must open: \(store2.openOutcome)") }
        let rows = store2.allHeldOrderedByPriority()
        XCTAssertEqual(rows.count, 1, "the exact message must survive an actual close/reopen")
        XCTAssertEqual(rows.first?.msgId, frame.msgId)
        XCTAssertEqual(rows.first?.payload, payload, "*** THE EXACT PAYLOAD BYTES MUST SURVIVE. ***")
        store2.close()
        _ = reopened.close()

        // *** WRONG KEY AND NO-KEY MUST BE REFUSED, WITH THE TYPE THAT PROVES THE KEY WAS REALLY APPLIED. ***
        let wrong = StoreDEK(bytes: Data(repeating: 0x77, count: 32))
        XCTAssertThrowsError(
            try engine.reopenOwnedRequiringDEK(path: path, dek: wrong),
            "a wrong DEK must be refused (the key really is applied)",
        ) { error in
            XCTAssertEqual(error as? StoreOpenFault, .wrongKey,
                           "*** A WRONG DEK ON A KEYED FILE MUST REFUSE AS `.wrongKey` -- SQLite's NOTADB is NORMALISED to it "
                               + "at both prepare and step. A mutant that stops normalising NOTADB would throw a generic `.io` "
                               + "instead, and THIS assertion (not a bare not-throw) reddens. ***")
        }
        XCTAssertThrowsError(
            try engine.reopenOwnedRequiringDEK(path: path, dek: StoreDEK(bytes: Data())),
            "an empty DEK must be refused",
        ) { error in
            XCTAssertEqual(error as? StoreOpenFault, .wrongKey, "an empty key is not a key")
        }
    }

    // ================================================================================================
    // *** SQLITE-REVIEW-7: A REAL TWO-STORE (MESSAGE + PEER) COMPOSITION, DURABLE, EXACT, CROSS-CLOSED. ***
    // ================================================================================================
    func testReview7RealTwoStoreCompositionPersistsAndRefusesWithoutKey() throws {
        let engine = SqlCipherDylibEngine()
        guard ncrRequirePinnedImage(engine, lane: "review7 dual-store") else { return }
        let msgPath = NSTemporaryDirectory() + "/ncr-dual-\(UUID().uuidString)/mesh.db"
        let peerPath = (msgPath as NSString).deletingLastPathComponent + "/peer.db"
        ncrMakeDir(msgPath); ncrMakeDir(peerPath)
        defer {
            _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: msgPath))
            _ = SqlitePeerIdentityStore.panicWipe(at: URL(fileURLWithPath: peerPath))
        }
        let msgDEK = StoreDEK(bytes: Data(repeating: 0x11, count: 32))
        let peerDEK = StoreDEK(bytes: Data(repeating: 0x22, count: 32))
        let frame = ncrFrame(0x22, payload: Data(repeating: 0xC3, count: 300))
        let node = ncrMsgId(0x33)
        let sign = Data(repeating: 0x44, count: 32)
        let staticDh = Data(repeating: 0x55, count: 32)

        do {
            let ownedMsg = try engine.openOwnedForWriting(path: msgPath, dek: msgDEK)
            let msg = SqliteMessageStore(verifiedConnection: ownedMsg, maxBytes: 64 * 1024 * 1024)
            let ownedPeer = try engine.openOwnedForWriting(path: peerPath, dek: peerDEK)
            let peer = try SqlitePeerIdentityStore(verifiedConnection: ownedPeer)

            guard case .opened = msg.openOutcome else { return XCTFail("message store must open: \(msg.openOutcome)") }
            XCTAssertEqual(.heldNew, msg.persist(frame, receivedFrom: Data(repeating: 0xAB, count: 8)))
            XCTAssertEqual(1, try peer.insertFirstSeen(nodeId: node, signingPub: sign,
                                                       acceptedStatic: staticDh,
                                                       acceptedGeneration: 3, trustCode: 1))
            msg.close(); peer.close()
            XCTAssertTrue(ownedMsg.close()); XCTAssertTrue(ownedPeer.close())
        }

        // BOTH STORES REOPEN WITH THEIR OWN KEYS AND READ EXACTLY WHAT WAS WRITTEN.
        let ownedMsg2 = try engine.reopenOwnedRequiringDEK(path: msgPath, dek: msgDEK)
        let msg2 = SqliteMessageStore(verifiedConnection: ownedMsg2, maxBytes: 64 * 1024 * 1024)
        guard case .opened = msg2.openOutcome else { return XCTFail("message reopen must open") }
        XCTAssertEqual(msg2.allHeldOrderedByPriority().first?.payload, frame.payload)
        msg2.close(); _ = ownedMsg2.close()

        let ownedPeer2 = try engine.reopenOwnedRequiringDEK(path: peerPath, dek: peerDEK)
        let peer2 = try SqlitePeerIdentityStore(verifiedConnection: ownedPeer2)
        let row = try peer2.readRaw(node)
        XCTAssertEqual(row?.signingPublicKeyRaw, sign)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, staticDh)
        peer2.close(); _ = ownedPeer2.close()

        // AND THE PEER FILE IS REFUSED WITHOUT ITS KEY.
        XCTAssertThrowsError(
            try engine.reopenOwnedRequiringDEK(path: peerPath, dek: StoreDEK(bytes: Data(repeating: 0x99, count: 32))),
            "the peer store must refuse a wrong DEK",
        )
    }

    // ================================================================================================
    // *** SQLITE-REVIEW-2/8 (SWEEP): A REFUSED BEGIN DISPATCHES NO MUTATION; A FAILED COMMIT PUBLISHES NOTHING. ***
    // ================================================================================================
    func testReviewSweepRefusesWithoutTransactionAndWithoutCommit() throws {
        let path = ncrTempPath("sweep")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let store = SqliteMessageStore(url: URL(fileURLWithPath: path), maxBytes: 64 * 1024 * 1024)
        guard case .opened = store.openOutcome else { return XCTFail("rig must open") }

        // A REAL CLOCK: a row's receipt budget is spent once `now - receivedAt` exceedeth its lifetime. Persist a frame
        // and advance the INJECTED clock, so the sweep really has a retirement to attempt -- which is what makes the
        // begin-fault arm's "no mutation dispatched" observable mean something.
        let fA = ncrFrame(0x66, payload: Data(repeating: 1, count: 16))
        store.receiptTimeProvider = { (monoMs: 0, bootIdentity: "ncr-boot") }
        _ = store.persistAt(fA, receivedFrom: Data(repeating: 5, count: 8), receivedAt: 0)
        store.receiptTimeProvider = { (monoMs: 10_000_000_000, bootIdentity: "ncr-boot") }
        _ = try store.sweepExpired()                   // burns the first-use maintenance sweep and retires fA
        let fB = ncrFrame(0x67, payload: Data(repeating: 2, count: 16))
        _ = store.persistAt(fB, receivedFrom: Data(repeating: 5, count: 8), receivedAt: 10_000_000_000)   // fresh
        store.receiptTimeProvider = { (monoMs: 20_000_000_000, bootIdentity: "ncr-boot") }                 // now fB spent

        // *** THE SPENT TOMBSTONE IS SEEDED AFTER THE LAST CLEAN SWEEP CAN FIRE: the BEGIN-fault arm must find it
        // STANDING, and only an ACKNOWLEDGED sweep may reap it. (The old body ran this very DELETE BEFORE the checked
        // BEGIN, with its bind/step faults swallowed -- SQLITE-LATEST-I4; `sweepMutationCountForTest` cannot see it,
        // so this row, not the counter, is the discriminator.) ***
        var tdb: OpaquePointer?
        let ghostId = ncrMsgId(0x6A)
        if sqlite3_open_v2(path, &tdb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let tdb {
            let tsql = "INSERT OR REPLACE INTO \(StoreSchema.tombstoneTable) (\(StoreSchema.colTMsgId), " +
                "\(StoreSchema.colTExpiresAtMono), \(StoreSchema.colTBootIdentity)) VALUES (?,?,?)"
            var ts: OpaquePointer?
            if sqlite3_prepare_v2(tdb, tsql, -1, &ts, nil) == SQLITE_OK, let ts {
                ghostId.withUnsafeBytes { sqlite3_bind_blob(ts, 1, $0.baseAddress, Int32(ghostId.count),
                                                            unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                sqlite3_bind_int64(ts, 2, 0)                       // spent at the sweep's clock (now == 0)
                "ncr-boot".withCString { sqlite3_bind_text(ts, 3, $0, -1,
                                                            unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                _ = sqlite3_step(ts); sqlite3_finalize(ts)
            }
            sqlite3_close_v2(tdb)
        }

        // A REFUSED BEGIN: NO DELETE/INSERT/UPDATE/TOMBSTONE-REAP IS DISPATCHED AND NO RETIREMENT IS PUBLISHED.
        store.sweepBeginFaultForTest = { 5 }   // SQLITE_BUSY (the real BEGIN is NOT run -- the seam intercepts it)
        do {
            _ = try store.sweepExpired()
            XCTFail("*** a refused BEGIN must surface a typed fault, not a silent zero ***")
        } catch let f as SqliteMessageStore.StoreSweepFault {
            XCTAssertEqual(f, .beginFailed(code: 5),
                           "*** the fault must NAME its stage and engine code -- not a generic storage error ***")
        }
        XCTAssertEqual(store.sweepMutationCountForTest, 0,
                       "*** NO MUTATION MAY BE DISPATCHED OUTSIDE A TRANSACTION: a `try?`-swallowed BEGIN ran every statement "
                           + "autocommitting one-by-one. With a spent row standing, a sweep that ran the DELETEs anyway would "
                           + "show a non-zero count here. ***")
        // *** READ THE GHOST'S SURVIVAL AROUND THE STORE, NOT THROUGH IT. *** *`store.tombstoneRowCount()` runs a
        // maintenance sweep (a BEGIN/COMMIT that would REAP this very tombstone -- its expires=0 is spent at this
        // clock), so asking the store would mutate the state under test and make the assertion measure its own side
        // effect. The raw probe asks the one question: doth the seeded spent tombstone still stand?*
        XCTAssertTrue(
            ncrRawTombstoneExists(path, ghostId),
            "*** THE TOMBSTONE REAP RUNS INSIDE THE CHECKED TRANSACTION: a BEGIN-faulted sweep that had reaped the spent "
                + "tombstone (the old pre-BEGIN road) leaves it GONE here. ***",
        )
        store.sweepBeginFaultForTest = nil
        XCTAssertEqual(try store.sweepExpired(), .retired(1), "an unfaulted sweep retires the expired row")
        // The acknowledged sweep's reap window is `now + tombstoneMs`, so the seeded tombstone (expires=0) is
        // outlived and reaped here -- a fresh tombstone for fB's retirement also stands at `now + 8 days`.
        XCTAssertFalse(
            ncrRawTombstoneExists(path, ghostId),
            "the acknowledged sweep reaps the outlived tombstone",
        )

        // A FAILED COMMIT: THE POSITIVE COUNT IS NOT PUBLISHABLE. (A THIRD frame, because fB is now tombstoned.)
        let fC = ncrFrame(0x68, payload: Data(repeating: 3, count: 16))
        _ = store.persistAt(fC, receivedFrom: Data(repeating: 5, count: 8), receivedAt: 20_000_000_000)
        store.receiptTimeProvider = { (monoMs: 30_000_000_000, bootIdentity: "ncr-boot") }                 // fC spent
        store.sweepCommitFaultForTest = { 10 }  // SQLITE_IOERR (the real COMMIT is NOT run)
        do {
            _ = try store.sweepExpired()
            XCTFail("*** A FAILED COMMIT MUST SURFACE A TYPED FAULT, NOT A SILENT ZERO. ***")
        } catch let f as SqliteMessageStore.StoreSweepFault {
            XCTAssertEqual(f, .commitFailed(code: 10),
                           "*** the commit gate must be NAMED -- this is the fault, not an empty scan ***")
        }
        XCTAssertGreaterThan(store.sweepMutationCountForTest, 0,
                             "the failed-commit sweep DID reach its mutations (so the fault above is the commit gate, not an empty scan)")
        store.sweepCommitFaultForTest = nil
        // *** NO FAULT IS INHERITED BY THE NEXT ATTEMPT. *** *The old road kept `lastSweepFault` alive until a
        // NONEMPTY commit, so a clean retry could rethrow the previous attempt's error or launder a clean zero; here
        // the fault is the THROW itself -- nothing to inherit -- and the sweep completes whatever its first attempt.*
        do { _ = try store.sweepExpired() } catch { XCTFail("the faulted attempt's error must not be inherited: \(error)") }
        XCTAssertFalse(store.allHeldMsgIds().contains(fC.msgId),
                       "and the durable end state stands: the spent row is retired exactly once, by an acknowledged sweep")
        // *** THE SEEDED GHOST IS GONE AND fC'S FRESH TOMBSTONE STANDS -- read around the store. *** *The ghost
        // (expires=0) was reaped by the acknowledged sweep; fC's retirement wrote a tombstone at `now + 8 days`,
        // which is NOT spent at any clock this arm reaches. The raw probe avoideth both the store's own mutating
        // maintenance sweep and the 8-day expiry that a bare count would misread.*
        XCTAssertFalse(ncrRawTombstoneExists(path, ghostId),
                       "the seeded spent tombstone is gone only now -- reaped inside an ACKNOWLEDGED transaction")
        XCTAssertTrue(
            ncrRawTombstoneExists(path, fC.msgId),
            "*** fC'S RETIREMENT WROTE ITS OWN FRESH TOMBSTONE (now + 8 days): a tombstone that failed to be written "
                + "would re-open the dedup window the retirement just closed. ***",
        )
    }

    // ================================================================================================
    // *** IOS-R4: THE OWNED FIRST-INSTALL VERB CREATES A DESTROYED KEY; THE REOPEN ROAD DOES NOT. ***
    // ================================================================================================
    func testReview4OwnedFirstInstallCreatesDEKAndReopenRefusesWithoutKey() throws {
        let engine = SqlCipherDylibEngine()
        guard ncrRequirePinnedImage(engine, lane: "first-install") else { return }
        final class Provider: PrivateStoreKeyProvider {
            var store: [String: StoreDEK] = [:]
            var dekByteCount: Int { 32 }
            let domain: String
            init(domain: String) { self.domain = domain }
            /// *** A PER-ARM KEY DOMAIN (the GsFinal003 convention): the capability alias IS the physical-key
            /// authority's identity, so a per-arm domain keepeth the PROCESS-GLOBAL alias registry from merging this
            /// arm's estate with another test's -- the exact cross-test merge that made `beginConstruction` refuse.*
            var physicalKeyDomain: String { domain }
            func fetchDEK(tag: String) throws -> StoreDEK {
                if let d = store[tag] { return d }; throw StoreKeyError.dekNotFound
            }
            func createDEK(tag: String) throws -> StoreDEK {
                let d = StoreDEK(bytes: Data(repeating: 0x9A, count: 32)); store[tag] = d; return d
            }
            func deleteDEK(tag: String) throws { store[tag] = nil }
            func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult { .success }
        }
        let path = ncrTempPath("firstinstall")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let provider = Provider(domain: "test.ncr.firstinstall.\(UUID().uuidString)")
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)
        let estate = ncrEstate(messageStoreUrl: URL(fileURLWithPath: path),
                               peerStoreUrl: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent + "/peer.db"))

        // *** FIRST INSTALL: NO DEK STANDS, SO THE OWNED OPEN CREATES ONE AND HANDS OVER A WORKING CONNECTION. ***
        let opened = factory.openOwnedForWriting(path: path, tag: "message-store",
                                                 scope: try ncrSealedScope(estate: estate, keyDomain: provider.physicalKeyDomain,
                                                                            tag: "message-store", path: path))
        guard case .opened(let connection, _) = opened else {
            return XCTFail("*** IOS-R4: THE OWNED FIRST-INSTALL ROAD MUST CREATE THE DEK AND OPEN, and it answered \(opened). "
                + "The composition called the REOPEN verb unconditionally post-wipe, which fetchETH (never createth) and "
                + "therefore failed on a destroyed key. ***")
        }
        XCTAssertNotNil(provider.store["message-store"], "the first-install road must have CREATED the DEK")
        let store = SqliteMessageStore(verifiedConnection: connection, maxBytes: 1024)
        guard case .opened = store.openOutcome else { return XCTFail("the store must adopt the first-install connection") }
        store.close(); _ = connection.close()

        // *** THE REAL PRIVATE FILE STILL STANDS -- ONLY THE DEK IS DESTROYED (exactly "missing key over existing
        // private bytes"). Deleting the data file would change the arm's meaning.*
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "the private key file must survive the key's destruction")

        // *** AND THE REOPEN ROAD DOES NOT CREATE: A MISSING DEK IS A REFUSAL, NEVER A SILENT FRESH STORE. ***
        try? provider.deleteDEK(tag: "message-store")
        let reopen: OwnedConnectionResult
        do {
            reopen = factory.reopenOwnedRequiringDEK(path: path, tag: "message-store",
                                                     scope: try ncrSealedScope(estate: estate, keyDomain: provider.physicalKeyDomain,
                                                                              tag: "message-store", path: path))
        } catch let fault as MeshRuntime.MeshRuntimeError {
            // *** A REFUSAL FROM THE SEALED ISSUER IS A TYPED, LAWFUL ANSWER -- AND ITS DECISION IS CARRIED SO THE
            // CAUSE IS NAMEABLE (never an NSError wording). *** *A destroyed key over a standing private file is
            // precisely a state the durable authority may refuse before the factory is reached; when it does, the
            // arm asserts the ACTUAL decision rather than forcing a bypass.*
            guard case .startupRefusedByRecovery(let decision, let reason) = fault else {
                return XCTFail("the sealed issuer refused with an unexpected MeshRuntimeError: \(fault)")
            }
            XCTAssertFalse(
                decision.isEmpty || reason.isEmpty,
                "*** THE SEALED REFUSAL MUST NAME ITS DECISION AND REASON: \(fault) ***",
            )
            return
        }
        guard case .engineUnavailable = reopen else {
            return XCTFail("a reopen without a DEK must refuse (never a silent create); got \(reopen)")
        }
    }

    // ================================================================================================
    // *** THE LEDGER ONE-SHOT: A SPENT MINT IS REFUSED, AND A WELL-FORMED SCOPE IS NOT A PERMISSION. ***
    // ================================================================================================
    func testAdmissionRefusesASpentMintAndAnUnissuedOne() throws {
        let engine = SqlCipherDylibEngine()
        guard ncrRequirePinnedImage(engine, lane: "admission one-shot") else { return }
        final class CountingProvider: PrivateStoreKeyProvider {
            private let lock = NSLock()
            private(set) var fetchCalls = 0
            private(set) var createCalls = 0
            var dekByteCount: Int { 32 }
            let domain: String
            init(domain: String) { self.domain = domain }
            /// A PER-ARM KEY DOMAIN (the GsFinal003 convention), so this arm's estate cannot merge with another
            /// test's through the process-global alias registry.
            var physicalKeyDomain: String { domain }
            func fetchDEK(tag: String) throws -> StoreDEK {
                lock.lock(); fetchCalls += 1; lock.unlock()
                return StoreDEK(bytes: Data(repeating: 0x11, count: 32))
            }
            func createDEK(tag: String) throws -> StoreDEK {
                lock.lock(); createCalls += 1; lock.unlock()
                return StoreDEK(bytes: Data(repeating: 0x11, count: 32))
            }
            func deleteDEK(tag: String) throws {}
            func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult { .success }
        }
        let path = ncrTempPath("admission")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let provider = CountingProvider(domain: "test.ncr.admission.\(UUID().uuidString)")
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)
        let estate = ncrEstate(messageStoreUrl: URL(fileURLWithPath: path),
                               peerStoreUrl: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent + "/peer.db"))

        // *** A CLAIMED CAPABILITY IS ONE-SHOT AT THE FACTORY BOUNDARY ITSELF. ***
        // *The claim is taken in the authority's serialization section BEFORE any Keychain verb, so the replay is
        // refused with ZERO new provider attempts -- the instruments are wired to the road under test, not beside it.*
        let scope = try ncrSealedScope(estate: estate, keyDomain: provider.physicalKeyDomain,
                                       tag: "message-store", path: path)
        guard case .opened(let first, _) = factory.openOwnedForWriting(path: path, tag: "message-store", scope: scope) else {
            return XCTFail("*** the first admitted open must succeed through the sealed lease ***")
        }
        _ = first.close()
        let acceptedAttempts = provider.fetchCalls + provider.createCalls
        XCTAssertGreaterThan(acceptedAttempts, 0,
            "*** the ACCEPTED arm must reach the Keychain for real -- a permanently-refusing boundary cannot satisfy this court ***")
        guard case .engineUnavailable = factory.reopenOwnedRequiringDEK(path: path, tag: "message-store", scope: scope) else {
            return XCTFail("*** A SPENT CAPABILITY MUST BE REFUSED, never re-open a private store ***")
        }
        XCTAssertEqual(provider.fetchCalls + provider.createCalls, acceptedAttempts,
                       "*** the REPLAY must be refused BEFORE the Keychain is touched -- zero additional DEK attempts ***")

        // *** A MISDIRECTED PRESENTATION IS A TYPED BINDING REFUSAL AND SPENDETH NOTHING. ***
        let bound = try ncrSealedScope(estate: estate, keyDomain: provider.physicalKeyDomain,
                                        tag: "message-store", path: path)
        guard case .engineUnavailable = factory.reopenOwnedRequiringDEK(path: path + ".other", tag: "message-store", scope: bound) else {
            return XCTFail("a capability bound to another path must be refused")
        }
        XCTAssertEqual(provider.fetchCalls + provider.createCalls, acceptedAttempts,
                       "the misdirected attempt must observe ZERO keychain work")
        guard case .opened(let second, _) = factory.reopenOwnedRequiringDEK(path: path, tag: "message-store", scope: bound) else {
            return XCTFail("*** the correctly-bound pair must still open exactly once AFTER a misdirected attempt ***")
        }
        _ = second.close()
        XCTAssertGreaterThan(provider.fetchCalls + provider.createCalls, acceptedAttempts,
                             "and that open must have reached the Keychain for real")

        // *** THE FORGERY ROAD DOES NOT EXIST. *** *`PhysicalEstateAuthority.ConstructionLease.init` is FILEPRIVATE
        // and the only issuer is `beginConstruction`, which verifieth the settled record, the live generation and the
        // one-shot permit in the authority's own serialization section; `EncryptedStoreAdmissionLedger` and
        // `EncryptedStoreAdmissionScope.forTest` are DELETED, so a court that tried to hand-write admission metadata
        // fails the BUILD -- which this programme's own law counts as a real control, not a green.*
    }

    // ================================================================================================
    // *** SQLITE-LATEST-C1: A REAL PEER TRANSACTION COMPLETES (NO DOUBLE-LOCK SELF-DEADLOCK). ***
    // ================================================================================================
    func testPeerTransactionCompletesWithoutDeadlock() throws {
        let path = ncrTempPath("peertx")
        ncrMakeDir(path)
        defer { _ = SqlitePeerIdentityStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let store = try SqlitePeerIdentityStore(url: URL(fileURLWithPath: path))
        let node = ncrMsgId(0x77), sign = Data(repeating: 0x11, count: 32), sdh = Data(repeating: 0x22, count: 32)
        let done = DispatchSemaphore(value: 0)
        var affected = -1
        DispatchQueue.global().async {
            affected = (try? store.inImmediateTransaction { tx in
                try tx.insertFirstSeen(nodeId: node, signingPub: sign, acceptedStatic: sdh,
                                       acceptedGeneration: 1, trustCode: 1)
            }) ?? -2
            done.signal()
        }
        let settled = done.wait(timeout: .now() + 5)
        XCTAssertEqual(
            .success, settled,
            "*** A REAL PEER `inImmediateTransaction` MUST COMPLETE. *The old body took the store's non-recursive NSLock "
                + "in `usingConnection` and THEN again in `transactionSection`, so every binding/approve/confirm/revoke "
                + "HUNG before BEGIN IMMEDIATE. A `close`-from-another-worker test cannot see this reentrant deadlock.* ***")
        guard settled == .success else {
            // *** BOUNDED AND ATTRIBUTABLE (NCR-11). *** *The named assertion above IS the witness. On the
            // reentrant-deadlock mutant the worker thread still HOLDS the store's non-recursive `NSLock`, so
            // dispatching ANOTHER store verb here (the durability re-read below) would block this thread for ever and
            // the roster would TIMEOUT instead of reporting an attributable assertion failure. We therefore stop at the
            // red we caused, with NO further native dispatch.*
            return
        }
        XCTAssertEqual(affected, 1, "the transaction must have committed its insert")
        XCTAssertEqual(try store.readRaw(node)?.signingPublicKeyRaw, sign, "and the row must be durable")
        store.close()
    }

    // ================================================================================================
    // *** SQLITE-LATEST-C2: THE IMAGE OUTLIVES THE ENGINE THAT LOADED IT (ARC, NOT A MANUAL COUNTER). ***
    // ================================================================================================
    func testEngineImageOutlivesTheEngineThatLoadedIt() throws {
        let path = ncrTempPath("imagelifetime")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let dek = StoreDEK(bytes: Data(repeating: 0x5E, count: 32))
        var store: SqliteMessageStore?
        var owned: OwnedConnection?
        var providerCopy: SQLiteFunctionTable?
        weak var leaseWitness: SQLiteImageLease?
        do {
            let engine = SqlCipherDylibEngine()
            guard ncrRequirePinnedImage(engine, lane: "image-lifetime") else { return }
            let o = try engine.openOwnedForWriting(path: path, dek: dek)
            store = SqliteMessageStore(verifiedConnection: o, maxBytes: 64 * 1024 * 1024)
            owned = o
            // *** THE COPY THAT ESCAPES: a public table VALUE copied out, exactly what the manual counter used to
            // fail to protect -- the ordinary struct copy incremented nothing, and the image could still be closed. ***
            providerCopy = o.connection.provider
            leaseWitness = o.connection.provider.lease
        }   // `engine` is dropped here; the store/connection/escaped copy must keep the image loaded
        XCTAssertEqual(
            store?.persist(ncrFrame(0x99, payload: Data(repeating: 7, count: 64)), receivedFrom: Data(repeating: 1, count: 8)),
            .heldNew,
            "*** AFTER THE ENGINE IS DROPPED, THE ADOPTED STORE MUST STILL DISPATCH SAFELY. *A manual reference counter "
                + "let the image unload while a live table/connection copy remained, so this dispatch would target a "
                + "freed image. The lease is now kept by ARC until the last user falls.* ***")
        XCTAssertEqual(store?.allHeldMsgIds().count, 1, "and it must read the exact row")
        XCTAssertNotNil(leaseWitness, "the escaped copy must itself be a strong ARC user of the lease")
        XCTAssertFalse(providerCopy?.lease?.isUnloadedForTest ?? true,
                       "*** the image is STILL LOADED while the escaped table copy lives -- the C pointers this copy "
                           + "carrieth remain dispatchable, which is the exact invariant the counter betrayed ***")
        store?.close(); _ = owned?.close()
        owned = nil; store = nil
        XCTAssertNotNil(leaseWitness, "the LAST reachable user is the escaped copy, so the lease must still stand")
        providerCopy = nil
        XCTAssertNil(leaseWitness,
                     "*** THE IMAGE RELEASES ONLY WHEN THE LAST ARC USER FALLS: dropping the escaped copy was the "
                         + "final reference, and ARC -- not a manual counter -- performed the unload. ***")
    }

    // ================================================================================================
    // *** SQLITE-LATEST-I5: A CORRUPT EXISTING INTENT IS STORAGE FAILURE, NOT ABSENCE. ***
    // ================================================================================================
    func testIntentCorruptExistingRowIsStorageFailureNotAbsence() throws {
        let path = ncrTempPath("intentcorrupt")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        let store = SqliteMessageStore(url: URL(fileURLWithPath: path), maxBytes: 64 * 1024 * 1024)
        guard case .opened = store.openOutcome else { return XCTFail("rig must open") }
        let intentId = ncrMsgId(0x50)
        // A ROW THAT EXISTS BUT BREAKS ITS INVARIANTS: a 4-byte binding_digest (the initializer requires 32).
        var db: OpaquePointer?
        sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        if let db {
            let sql = "INSERT INTO \(StoreSchema.intentTable) (\(StoreSchema.colIIntentId), \(StoreSchema.colILogicalMessageId), " +
                "\(StoreSchema.colISignedPlaintext), \(StoreSchema.colICanonicalFrame), \(StoreSchema.colIRecipientNodeId), " +
                "\(StoreSchema.colIRecipientStaticDhPub), \(StoreSchema.colIAcceptedGeneration), \(StoreSchema.colIBindingDigest), " +
                "\(StoreSchema.colICreatedAt), \(StoreSchema.colIMessageNonce), \(StoreSchema.colIPriorityCode), \(StoreSchema.colIStateRank)) " +
                "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
            var st: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st {
                let short = Data(repeating: 1, count: 4)
                func bindBlob(_ i: Int32, _ d: Data) { d.withUnsafeBytes { sqlite3_bind_blob(st, i, $0.baseAddress, Int32(d.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
                bindBlob(1, intentId); bindBlob(2, ncrMsgId(0x51)); bindBlob(3, Data(repeating: 2, count: 8))
                bindBlob(4, Data(repeating: 3, count: 8)); bindBlob(5, ncrMsgId(0x52)); bindBlob(6, Data(repeating: 4, count: 32))
                sqlite3_bind_int64(st, 7, 1); bindBlob(8, short); sqlite3_bind_int64(st, 9, 0)
                bindBlob(10, Data(repeating: 5, count: 16)); sqlite3_bind_int(st, 11, 0); sqlite3_bind_int(st, 12, 0)
                _ = sqlite3_step(st); sqlite3_finalize(st)
            }
            sqlite3_close_v2(db)
        }
        do {
            _ = try store.readIntent(intentId)
            XCTFail("*** A ROW THAT EXISTS BUT CANNOT BE REBUILT IS CORRUPTION, NOT ABSENCE. *The failable `JournalEntry.init?` "
                + "was returned directly, so a malformed nonce/digest became `nil` -> the journal's `.notFound` -> fresh "
                + "trust/nonce/signing in `SendDirectAuthority`.* ***")
        } catch let f as SqliteMessageStore.IntentReadFault {
            guard case .corrupt = f else { return XCTFail("a malformed existing row must be typed `.corrupt`, got \(f)") }
        }
        switch SqliteOutboundIntentJournal(store: store).load(intentId) {
        case .corrupt: break
        case .notFound:
            XCTFail("*** a malformed row mapped to `.notFound` -- the exact permission-laundering SQLITE-LATEST-I5 names: "
                    + "absence invites FRESH trust/nonce/signing over a durably existing row ***")
            default:
                XCTFail("the journal seam must map a malformed existing row to `.corrupt`, never the generic storage fault")
        }
    }

    // ================================================================================================
    // *** SQLITE-LATEST-I4 (NATIVE6): A REAP BIND FAULT IS A TYPED SWEEP FAULT -- NEVER A CLEAN ZERO. ***
    //
    // *THE FINDING: `reapExpiredTombstonesNoLock` discarded `fn.bindText`'s result at the boot-identity parameter, so
    // a REFUSED text bind left the parameter NULL, the `boot_identity = NULL` predicate matched no rows, `step`
    // reached DONE, the COMMIT succeeded, and the sweep reported a CLEAN outcome -- advancing maintenance cadence and
    // publishing retirements -- while the expired tombstones were never reaped.*
    //
    // **THIS COURT DRIVES THE PRODUCTION STORE OVER THE EXISTING PROVIDER-TABLE SEAM WITH A `bindText` WHOSE
    // BOOT-IDENTITY BIND REFUSES, using the REAL clock identity the store's `receiptTimeProvider` names.** A SPENT,
    // in-boot tombstone stands, so a green reap would observably delete it: the discriminator is the ROW, not a
    // counter. *** Restore the discarded bind (`_ = fn.bindText(...)`) and this arm reddens: the sweep answers
    // `.nothingToRetire`, cadence advances, and the spent tombstone survives. ***
    // ================================================================================================
    func testNative6ReapBindFaultThrowsAndTheSpentTombstoneStands() throws {
        ncrResetTableFaults()
        let path = ncrTempPath("reap-bind")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        guard let (store, owned) = ncrAdoptedInstrumentedStore(path) else {
            return XCTFail("the instrumented adopted store must open")
        }
        guard case .opened = store.openOutcome else { return XCTFail("rig must open: \(store.openOutcome)") }

        let boot = "ncr-probe-boot"
        store.receiptTimeProvider = { (monoMs: 0, bootIdentity: boot) }
        // A spent, in-boot tombstone (expires at 0; the sweep's clock is 0, so it is outlived). **THE FAULTED WRITE IS
        // SEEDED **BEFORE** THE STORE FIRST WRITES THROUGH ITS OWN TABLE**, so this court's raw connection is the only
        // writer and no store-side tombstone write (which also binds boot identity, at index 3) ever occurs.
        let spent = ncrMsgId(0x7A)
        ncrSeedSpentTombstone(path, spent, expiresAtMono: 0, boot: boot)

        // *** FORCE THE NATIVE FAULT: `SQLITE_NOMEM` (7) on the reap's boot-identity text bind. ***
        ncrTableLock.lock(); ncrBootBindFault = 7; ncrTableLock.unlock()

        do {
            let outcome = try store.runScheduledMaintenance()
            ncrResetTableFaults()
            return XCTFail("*** A REFUSED REAP BIND MUST THROW, NOT ANSWER \(outcome). *The old body discarded the bind "
                + "result, so a NULL boot parameter matched no rows and the sweep reported a clean outcome.* ***")
        } catch let fault as SqliteMessageStore.StoreSweepFault {
            ncrTableLock.lock(); ncrBootBindFault = nil; ncrTableLock.unlock()
            XCTAssertEqual(
                fault, .reapBindFailed(code: 7),
                "*** THE FAULT MUST NAME ITS STAGE AND THE ENGINE'S **ACTUAL** BIND CODE (not a fabricated -1): the "
                    + "discarded-bind defect raised -1 or nothing at all. ***",
            )
        }
        ncrResetTableFaults()

        // *** AND THE SPENT TOMBSTONE IS STILL THERE: the faulted sweep reaped NOTHING. *** The census is taken OVER A
        // THROWAWAY HANDLE, not through the store, so it neither triggers a cadence sweep nor is itself faulted.
        XCTAssertTrue(
            store.canStillUseConnectionForTest,
            "an ordinary reap-bind fault is recoverable -- its rollback succeeded, so the connection is NOT withdrawn",
        )
        XCTAssertEqual(
            ncrRawTombstoneCount(path), 1,
            "*** THE SPENT TOMBSTONE MUST SURVIVE A REFUSED-BIND SWEEP. *A sweep that reached DONE over a NULL boot "
                + "parameter would have reaped it (or reported a clean zero), which is exactly the P1 hole.* ***",
        )

        // *** THE CADENCE DID NOT ADVANCE: a store READ still runs the first-use maintenance sweep, because
        // `startupMaintenanceDone` was NOT set by the faulted attempt -- so the read reaps the spent tombstone. A store
        // whose cadence HAD advanced past the fault would SKIP the sweep, and the raw census below would still be 1. ***
        XCTAssertEqual(
            store.tombstoneRowCount(), 0,
            "*** CADENCE MUST NOT ADVANCE PAST A FAULTED SWEEP: the read's own maintenance sweep still ran (reaping the "
                + "tombstone). A cadence marked done by the faulted attempt would have skipped it. ***",
        )
        XCTAssertEqual(
            ncrRawTombstoneCount(path), 0,
            "and the spent tombstone is reaped only by an acknowledged maintenance sweep",
        )
        store.close()
        _ = owned.close()
    }

    // ================================================================================================
    // *** SQLITE-LATEST-I4 (NATIVE6): A SWEEP WHOSE CLEANUP FAILED REPORTS IT AND WITHDRAWS THE CONNECTION. ***
    //
    // *THE FINDING: `sweepFault` ignored its `ROLLBACK` (`fn.exec(db, "ROLLBACK", ...)`), so a sweep that failed its
    // COMMIT and then failed to roll back kept serving later operations inside the unresolved transaction.*
    //
    // **HERE THE COMMIT AND THE SWEEP'S OWN ROLLBACK ARE BOTH REFUSED through existing store seams, and the arm
    // requires the CLEANUP failure to be REPORTED (its actual code) and the connection WITHDRAWN.** *A later read MUST
    // refuse, so a retirement can no longer masquerade as durable on an abandoned transaction.*
    // ================================================================================================
    func testNative6SweepRollbackFailureReportsCleanupAndWithdrawsTheConnection() throws {
        ncrResetTableFaults()
        let path = ncrTempPath("sweep-rb")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        guard let (store, owned) = ncrAdoptedInstrumentedStore(path) else {
            return XCTFail("the instrumented adopted store must open")
        }
        guard case .opened = store.openOutcome else { return XCTFail("rig must open: \(store.openOutcome)") }

        store.receiptTimeProvider = { (monoMs: 0, bootIdentity: "ncr-probe-boot") }
        let f = ncrFrame(0x90, payload: Data(repeating: 8, count: 16))
        XCTAssertEqual(.heldNew, store.persistAt(f, receivedFrom: Data(repeating: 1, count: 8), receivedAt: 0))
        store.receiptTimeProvider = { (monoMs: 10_000_000_000, bootIdentity: "ncr-probe-boot") }   // f now spent

        // A refused COMMIT and a refused CLEANUP ROLLBACK (the real COMMIT/ROLLBACK are NOT run).
        store.sweepCommitFaultForTest = { 10 }
        store.sweepRollbackFaultForTest = { 11 }
        do {
            let outcome = try store.sweepExpired()
            store.sweepCommitFaultForTest = nil; store.sweepRollbackFaultForTest = nil
            return XCTFail("*** A SWEEP WHOSE CLEANUP FAILED MUST THROW, NOT ANSWER \(outcome). ***")
        } catch let fault as SqliteMessageStore.StoreAbandonedConnectionFault {
            store.sweepCommitFaultForTest = nil; store.sweepRollbackFaultForTest = nil
            XCTAssertEqual(
                fault.cleanupCode, 11,
                "*** THE SWEEP'S CLEANUP FAILURE MUST BE REPORTED WITH THE ENGINE'S ACTUAL ROLLBACK CODE -- the old "
                    + "`sweepFault` discarded it entirely. ***",
            )
            XCTAssertEqual(fault.cause, "COMMIT", "the sweep's original cause (the failed COMMIT) must be preserved")
        }
        store.sweepCommitFaultForTest = nil; store.sweepRollbackFaultForTest = nil
        XCTAssertEqual(store.lastSweepFault, .commitFailed(code: 10),
                       "the STAGE fault stays recorded for the store's own bookkeeping")

        // *** AND NO LATER OPERATION MAY RUN ON THE ABANDONED TRANSACTION. ***
        XCTAssertFalse(store.canStillUseConnectionForTest,
                       "*** A FAILED SWEEP CLEANUP WITHDRAWS THE CONNECTION. ***")
        XCTAssertThrowsError(try store.readIntent(ncrMsgId(0x05)), "a LATER READ must refuse") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        XCTAssertThrowsError(try store.sweepExpired(), "a LATER SWEEP must refuse") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        // *** THE FRAME-EXIT PHYSICAL CLOSE HATH RUN (before teardown), and the free was EXACTLY ONCE. ***
        XCTAssertTrue(owned.isPhysicallyClosed,
                      "*** THE SWEEP ROAD MUST ALSO PHYSICALLY CLOSE AT THE CURRENT FRAME'S EXIT, not merely latch. ***")
        XCTAssertFalse(owned.close(), "and a later `close()` must be a no-op (exactly-once).")
        XCTAssertThrowsError(try owned.usingConnection { _ in 0 },
                             "every alias must be refused, even a retained handle")
        store.close()
        _ = owned.close()
    }

    // ================================================================================================
    // *** SQLITE-LATEST-I4 (NATIVE6): THE OWNED (`url:`) ROAD FREES ITS OWN HANDLE AT A SAFE PHASE. ***
    //
    // *The `url:` composition opens and OWNS its handle (`owner == nil`, `ownsConnection == true`), so there is no
    // owner frame to defer through. A failed transaction whose cleanup also failed must still not leave the native
    // connection open: the store freeeth the EXACT owned handle in place -- at a safe phase, with every statement
    // ALREADY FINALIZED (the ROLLBACK was the transaction's last statement) and NO post-close SQLite call -- and
    // droppeth it, so `close()`/`deinit` do NOT double-close.*
    // ================================================================================================
    func testNative6OwnedRoadFailedCleanupClosesItsOwnHandleAndRefusesLaterOps() throws {
        ncrResetTableFaults()
        let path = ncrTempPath("owned-rb")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        // THE PLAIN `url:` STORE -- the owned road, `owner == nil`, `ownsConnection == true`, on a WRITABLE platform
        // handle (its `url:` initializer opens READWRITE|CREATE).
        let store = SqliteMessageStore(url: URL(fileURLWithPath: path), maxBytes: 64 * 1024 * 1024)
        guard case .opened = store.openOutcome else { return XCTFail("rig must open: \(store.openOutcome)") }
        store.receiptTimeProvider = { (monoMs: 0, bootIdentity: "ncr-owned-boot") }

        // *** A REAL WRITE IS PERSISTED THROUGH THE STORE (a genuine committed transaction), so the durable file is
        // writable and the later lock probe measureth the ABANDONED transaction, not an empty database. ***
        let frame = ncrFrame(0x91, payload: Data(repeating: 6, count: 16))
        XCTAssertEqual(.heldNew, store.persistAt(frame, receivedFrom: Data(repeating: 1, count: 8), receivedAt: 0))
        store.receiptTimeProvider = { (monoMs: 10_000_000_000, bootIdentity: "ncr-owned-boot") }   // frame now spent

        // BOTH FAILURES through the store's own sweep seams (store-level injectors, no provider table): a refused
        // COMMIT (so the sweep's write transaction is left UNRESOLVED) and a refused cleanup ROLLBACK.
        store.sweepCommitFaultForTest = { 10 }
        store.sweepRollbackFaultForTest = { 11 }
        do {
            _ = try store.sweepExpired()
            store.sweepCommitFaultForTest = nil; store.sweepRollbackFaultForTest = nil
            return XCTFail("a failed sweep cleanup must throw")
        } catch let fault as SqliteMessageStore.StoreAbandonedConnectionFault {
            store.sweepCommitFaultForTest = nil; store.sweepRollbackFaultForTest = nil
            XCTAssertEqual(fault.cleanupCode, 11, "the actual cleanup code must be reported")
            XCTAssertEqual(fault.cause, "COMMIT", "the original cause must be preserved")
        }
        store.sweepCommitFaultForTest = nil; store.sweepRollbackFaultForTest = nil

        // *** THE UNRESOLVED TRANSACTION IS A REAL WRITE TRANSACTION, NOT AN EMPTY BEGIN. *** *The sweep's own DELETE
        // (reap + held-row), INSERT (tombstone) and UPDATE (delivery) steps ran before the refused COMMIT, so the
        // abandoned handle really carrieth an open WRITE transaction -- which is what the second-connection lock probe
        // below measureth. An empty `BEGIN IMMEDIATE` would already have released its lock and the probe would pass
        // for the wrong reason.*
        XCTAssertGreaterThan(
            store.sweepMutationCountForTest, 0,
            "*** THE ABANDONED TRANSACTION MUST CONTAIN REAL WRITES (the sweep's DELETE/INSERT/UPDATE), not an empty BEGIN. ***",
        )

        // *** THE CONSUMER-VISIBLE PHYSICAL-CLEANUP DISCRIMINATOR. ***
        // *This arm keeps the abandoned `store` RETAINED (alive, unreleased) while a SECOND real platform sqlite
        // connection to the SAME file obtaineth a write lock (`BEGIN IMMEDIATE`) and persists a row.*
        //   * A merely FLAG-LATCHED handle (the `else` branch's `fn.closeV2(db); handle = nil` deleted) would STILL
        //     hold the unresolved write transaction, so `BEGIN IMMEDIATE` would answer **SQLITE_BUSY**.
        //   * The REAL physical close released the lock, so the second connection succeedeth IMMEDIATELY (**SQLITE_OK**).
        // **This kills the delete-`close`-alone and the metadata-`nil`-handle assertions: `canStillUseConnectionForTest`
        // and the typed refusals are ALL STILL GREEN with the close removed, but the LOCK is not.**
        //
        // (Ordering note: the owned in-place `close_v2` can run while the sweep's SCAN statement is still unfinalized
        // -- `close_v2` then marks a zombie that is freed as the scan's `defer finalize` runs on the same return path.
        // This probe runs AFTER `sweepExpired()` has fully returned, so the deferred finalize has already freed the
        // connection and released the lock -- which is exactly the state this arm must measure.)
        XCTAssertEqual(
            ncrSecondConnectionWrite(path), SQLITE_OK,
            "*** THE OWNED ROAD MUST **PHYSICALLY** CLOSE THE ABANDONED HANDLE -- NOT MERELY LATCH A FLAG. *If the "
                + "delete-close half were removed, the first store would still hold the unresolved write transaction "
                + "and this second connection's `BEGIN IMMEDIATE` would answer SQLITE_BUSY. A green `canStillUse` and "
                + "typed refusals prove only the latch; THIS proves the lock was released.* ***",
        )

        // *** AND THE FIRST (RETAINED) STORE STILL REFUSES EVERY OPERATION. ***
        XCTAssertFalse(
            store.canStillUseConnectionForTest,
            "*** THE OWNED ROAD MUST DROP ITS OWN HANDLE -- it must not stay usable after unresolved cleanup. ***",
        )
        XCTAssertThrowsError(try store.readIntent(ncrMsgId(0x06)), "a later read must refuse") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        XCTAssertThrowsError(try store.sweepExpired(), "a later sweep must refuse") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        // A second `close()` must NOT double-close: after the in-place free the handle is already nil, so it is a no-op.
        store.close()
    }

    // ================================================================================================
    // *** SQLITE-LATEST-I4 (NATIVE6): A FAILED ROLLBACK REFUSES ALL LATER OPERATIONS -- ONE CLEANUP. ***
    //
    // *THE FINDING: `transactionSection` discarded every `ROLLBACK` result and executed ROLLBACK TWICE on its
    // COMMIT-failure path. A failed transaction whose CLEANUP also failed left the shared connection usable inside an
    // UNRESOLVED transaction, so a later insert could run inside it and report a durable success the file never
    // received.*
    //
    // **THIS COURT FORCES BOTH THE TRANSACTION FAILURE (COMMIT refused) AND THE CLEANUP FAILURE (ROLLBACK refused)
    // through the existing seams, then requires: (1) the cleanup failure is REPORTED with its ACTUAL code, (2) the
    // connection is WITHDRAWN, (3) EVERY later insert/advance/read/transaction refuseth, and (4) EXACTLY ONE rollback
    // was attempted.**
    //
    // *** A NOTE ON WHY THIS IS THE MEANINGFUL COURT AND NOT A KILLED COMPILATION ASSERTION: *** *the P1 report's
    // native failure scenario is `[INFERENCE]`; a court that merely asserted a struct field would be killed by a
    // refactor. This drives the real store, the real begin/commit sequence, and the real refusal road, and its
    // assertions FAIL if any part of the repair is reverted.*
    // ================================================================================================
    func testNative6FailedRollbackRefusesAllLaterOperationsAndRunsOneCleanup() throws {
        ncrResetTableFaults()
        let path = ncrTempPath("rollback-fail")
        ncrMakeDir(path)
        defer { _ = SqliteMessageStore.panicWipe(at: URL(fileURLWithPath: path)) }
        guard let (store, owned) = ncrAdoptedInstrumentedStore(path) else {
            return XCTFail("the instrumented adopted store must open")
        }
        guard case .opened = store.openOutcome else { return XCTFail("rig must open: \(store.openOutcome)") }
        store.receiptTimeProvider = { (monoMs: 0, bootIdentity: "ncr-probe-boot") }

        // A standing delivery row, so the failing ACK CAS reaches its DELETE (body throws AFTER its mutation) rather
        // than short-circuiting on an absent row.
        let frame = ncrFrame(0x88, payload: Data(repeating: 9, count: 16))
        XCTAssertEqual(.heldNew, store.persist(frame, receivedFrom: Data(repeating: 1, count: 8)))

        // *** BOTH FAILURES: the guarded ACK CAS matches nothing (`0` changes -> `.stepFailed`), the COMMIT is refused,
        // and the CLEANUP `ROLLBACK` is refused. *** The guards keep this surgical: only a `COMMIT` exec and a
        // `ROLLBACK` exec are faulted; the store's migrations and every other statement run for real.
        ncrTableLock.lock(); ncrCommitExecFault = 10; ncrTableLock.unlock()
        store.rollbackFaultForTest = { 11 }        // SQLITE_CORRUPT on the cleanup
        // A two-placeholder guarded CAS (the body binds exactly two blobs): no delivery row stands, so it matches
        // nothing and returns `.noMatch` -- the COMMIT that follows is the faulted one.
        let guardedAck = "UPDATE \(StoreSchema.deliveryTable) SET \(StoreSchema.colDState) = ? " +
            "WHERE \(StoreSchema.colDMsgId) = ?"

        do {
            let outcome = try store.atomicAcknowledgeAndRetire(guardedAckSql: guardedAck,
                                                               msgId: frame.msgId,
                                                               expectedRecipient: Data(repeating: 2, count: 16))
            ncrResetTableFaults(); store.rollbackFaultForTest = nil
            return XCTFail("*** A FAILED TRANSACTION WHOSE CLEANUP FAILED MUST THROW, NOT ANSWER \(outcome). ***")
        } catch let fault as SqliteMessageStore.StoreAbandonedConnectionFault {
            ncrTableLock.lock(); ncrCommitExecFault = nil; ncrTableLock.unlock()
            store.rollbackFaultForTest = nil
            XCTAssertEqual(
                fault.cleanupCode, 11,
                "*** THE CLEANUP FAILURE MUST BE REPORTED WITH THE **ACTUAL** ENGINE CODE -- the old body discarded it "
                    + "entirely, so a caller could not even learn cleanup had failed. ***",
            )
            XCTAssertEqual(fault.cause, "COMMIT",
                           "the original cause (the failed COMMIT) must be preserved on the abandoned fault")
        }
        ncrResetTableFaults(); store.rollbackFaultForTest = nil

        // *** THE CONNECTION IS WITHDRAWN: no later operation may run on the abandoned transaction. ***
        XCTAssertFalse(
            store.canStillUseConnectionForTest,
            "*** AN UNRESOLVED TRANSACTION WITHDRAWS THE SHARED CONNECTION: it may not keep serving operations. ***",
        )
        XCTAssertThrowsError(try store.readIntent(ncrMsgId(0x01)), "a LATER READ must refuse") { error in
            guard let f = error as? SqliteMessageStore.StoreAbandonedConnectionFault else {
                return XCTFail("a read after unresolved cleanup must refuse with the typed abandonment, got \(error)")
            }
            XCTAssertEqual(f.cleanupCode, 11, "and the refusal must carry the ACTUAL cleanup code")
        }
        XCTAssertThrowsError(try store.insertIntent(ncrJournalEntry(intentId: ncrMsgId(0x03))),
                             "a LATER INSERT must refuse") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        XCTAssertThrowsError(try store.advanceIntent(intentId: ncrMsgId(0x02),
                                                     from: .authored, to: .committed),
                             "a LATER ADVANCE must refuse") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        XCTAssertThrowsError(try store.execRawSql("SELECT 1"),
                             "a LATER STATEMENT must refuse before dispatching") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        // *** EXACTLY ONE CLEANUP: install a rollback seam that FAILS if invoked, and require a subsequent read to
        // refuse WITHOUT ever reaching it -- an abandoned connection never issues a second `ROLLBACK`. Together with
        // the single `ROLLBACK` on the failed-transaction path (the double rollback was removed), this proves the
        // cleanup ran ONCE. ***
        var cleanupAttempts = 0
        store.rollbackFaultForTest = { cleanupAttempts += 1; return 11 }
        XCTAssertThrowsError(try store.readIntent(ncrMsgId(0x04)), "a later read must refuse") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        store.rollbackFaultForTest = nil
        XCTAssertEqual(cleanupAttempts, 0,
                       "*** NO SECOND CLEANUP MAY BE ATTEMPTED on an abandoned connection: it refuseth BEFORE any "
                           + "dispatch, and the failed transaction's rollback ran exactly once. ***")
        XCTAssertThrowsError(try store.atomicAcknowledgeAndRetire(guardedAckSql: guardedAck,
                                                                  msgId: frame.msgId,
                                                                  expectedRecipient: Data(repeating: 2, count: 16)),
                             "*** A LATER TRANSACTION MUST REFUSE BEFORE IT `BEGIN`s -- an abandoned transaction is never "
                                 + "inherited. ***") { error in
            XCTAssertTrue(error is SqliteMessageStore.StoreAbandonedConnectionFault, "got \(error)")
        }
        // The non-throwing legacy readers fail closed too.
        XCTAssertEqual(store.tombstoneRowCount(), 0, "the non-throwing reader must answer its fail-closed default")
        XCTAssertTrue(store.allHeldMsgIds().isEmpty, "and so must the held-id roster")

        // *** AND THE OWNER'S DEFERRED CLOSE HATH RUN -- **BEFORE TEST TEARDOWN**. *** *`recordAbandoned` schedules the
        // exactly-once `close_v2` inside the CURRENT USE FRAME (`owner.close()` sets the handler and returns without
        // waiting, because this thread holds the frame's use); the frame's own `endUse` then performeth `finishClose`
        // as it unwinds -- so by the time the failing call returneth to THIS court, the native handle is ALREADY
        // physically closed. A `url:`/adopted unresolved transaction is therefore NOT left holding a connection open.*
        XCTAssertTrue(owned.isClosed, "the owner must be marked closed")
        XCTAssertTrue(
            owned.isPhysicallyClosed,
            "*** THE NATIVE HANDLE MUST BE PHYSICALLY CLOSED AT THE FRAME'S EXIT -- BEFORE TEST TEARDOWN. *A latch "
                + "that only refused later calls while the connection stayed open would leave the unresolved "
                + "transaction holding a native connection. THIS is the arm that distinguishes them.* ***",
        )
        XCTAssertFalse(
            owned.close(),
            "*** A LATER `close()` MUST BE A NO-OP: the free happened EXACTLY ONCE at the frame's exit, so a second "
                + "close must report `false` rather than double-free the handle. ***",
        )
        XCTAssertThrowsError(
            try owned.usingConnection { _ in 0 },
            "*** EVERY ALIAS OF THE CONNECTION MUST BE REFUSED -- even a RETAINED `OwnedConnection` handle: no use may "
                + "be admitted after the failed cleanup. ***",
        )
        XCTAssertFalse(owned.connection.lifecycle?.isUsable ?? true,
                       "the shared lifecycle must be withdrawn for EVERY adopter, not just this store")

        store.close()
        _ = owned.close()
    }
}

// MARK: - the sealed lease and mandatory-image helpers (SQLITE-LATEST-C3 / I6)

/// The lane's pinned image is repository-built (`tools/supplychain/build_sqlcipher_simulator.sh`); a binding
/// failure is a COURT/SYSTEM failure, not a distinguishable skip (SQLITE-LATEST-I6) -- a skipped native
/// acceptance must never be counted green for a road the campaign did not run.
private func ncrRequirePinnedImage(_ engine: SqlCipherDylibEngine, lane: String) -> Bool {
    if engine.isBound { return true }
    XCTFail("*** MANDATORY NATIVE LANE '\(lane)' (SQLITE-LATEST-I6): the pinned image '\(SQLCipherPin.libraryName)' "
            + "is not staged or did not bind. Build it with tools/supplychain/build_sqlcipher_simulator.sh and stage "
            + "it where the loader searches, or export GODSTONE_SQLCIPHER_ARTIFACT_DIR. "
            + "Reason: \(engine.bindingFailureReason ?? "unknown") ***")
    return false
}

/// The court's own durable wipe journal: readable by construction, IDLE after a checked write, and carrying the
/// epoch that `beginConstruction` refuseth to fabricate.
private final class NCRJournal: WipeJournal, @unchecked Sendable {
    var state: WipeState = .idle
    func read() -> WipeState { state }
    func write(_ s: WipeState) { state = s }
    func clear() { state = .idle }
    var isReadable: Bool { true }
    private var _wipeEpoch: UInt64?
    var durableEpoch: UInt64? { _wipeEpoch }
    @discardableResult func bumpEpoch() -> UInt64? { _wipeEpoch = (_wipeEpoch ?? 0) + 1; return _wipeEpoch }
    func readDurable() -> (state: WipeState, epoch: UInt64?)? { (read(), _wipeEpoch) }
    @discardableResult func writeChecked(_ state: WipeState) -> DurableWriteResult {
        write(state)
        if _wipeEpoch == nil { _wipeEpoch = 1 }
        return DurableWriteResult(synchronized: true, epoch: _wipeEpoch)
    }
}

private final class NCRKeychain: LocalIdentityKeychain, @unchecked Sendable {
    var storage: [String: Data] = [:]
    func read(tag: String) throws -> Data? { storage[tag] }
    func add(tag: String, data: Data) throws { storage[tag] = data }
    func delete(tag: String) throws { storage.removeValue(forKey: tag) }
}

/// A physical estate DECLARED once: the artifact-path set is the PRODUCTION derivation, so the sealed issuer's
/// own inventory check bindeth the court to the same computation rather than a hand-named constant.
private struct NCREstate {
    let estateId: String
    let artifactPaths: [String: URL]
    let stores: [String: URL]
    let journal: NCRJournal
    let keychain: NCRKeychain
}

private func ncrEstate(messageStoreUrl: URL, peerStoreUrl: URL) -> NCREstate {
    let artifactPaths = MeshRuntime.wipeArtifactPaths(messageStoreUrl: messageStoreUrl, peerStoreUrl: peerStoreUrl)
    return NCREstate(estateId: MeshRuntime.recoveryEstateId(artifactPaths: artifactPaths),
                     artifactPaths: artifactPaths,
                     stores: ["message-store": messageStoreUrl, "peer-identity-store": peerStoreUrl],
                     journal: NCRJournal(), keychain: NCRKeychain())
}

/// *** THE ONE LEASE ROAD FOR COURTS (SQLITE-LATEST-C3). ***
/// *Drive the REAL ladder over a settled, generation-known journal to obtain the one-shot permit, then present it
/// to the sealed sole issuer. There is NO court convenience: `ConstructionLease.init` is fileprivate,
/// `EncryptedStoreAdmissionLedger` and `.forTest` are DELETED, and a copied spent permit/claim refuseth typed at
/// the factory boundary itself.*
private func ncrSealedScope(estate: NCREstate, keyDomain: String, tag: String, path: String) throws -> EncryptedStoreAdmissionScope {
    _ = estate.journal.writeChecked(.idle)          // settled record with a KNOWN generation -- never a fabricated zero
    let authority = CrashResumableWipe(
        store: WipeJournalDurabilityAdapter(journal: estate.journal),
        vault: WipeDeferredKeyVaultSeam(),
        filesystem: WipeDeferredArtifactFileSystemSeam(),
        runtime: WipeDeferredTransportSeam(),
        authority: WipeDeferredIdentityAuthoritySeam())
    guard case .normal(let permit) = StartupRecoveryBootstrap(wipe: authority, estateId: estate.estateId)
            .consumeCompositionTopology() else {
        XCTFail("a driven clean estate must issue the permit; the ladder refused the normal road")
        throw StoreKeyError.keychainUnavailable
    }
    let lease = try PhysicalEstateAuthority.shared.beginConstruction(
        permit: permit, estateId: estate.estateId, journal: estate.journal,
        artifactPaths: estate.artifactPaths, keychain: estate.keychain,
        keyDomain: keyDomain, stores: estate.stores)
    return EncryptedStoreAdmissionScope(authorityLease: lease, storeTag: tag, storePath: path)
}
