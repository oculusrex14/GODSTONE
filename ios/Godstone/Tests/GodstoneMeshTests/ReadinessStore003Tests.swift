// GS-STORE-003 -- actual message-store upgrades must not DROP durable tables.
//
// The audit reproduced it behaviourally ("The Swift acceptance probe persists a real row,
// closes the store, sets user_version=1 while retaining compatible DDL, and reopens. The
// held row disappears") and confirmed it by source ("both production upgrade methods execute
// DROP TABLE"). W01/W02/W03 assert the two SOURCE facts the audit confirmed; W04/W05 drive
// the production open road end to end over a real on-disk SQLite file and assert the
// BEHAVIOUR the audit reproduced. W06 is the positive control (the arm harness can pass).
//
// All of these are RED against the destructive road: the versioned upgrade deletes held
// frames and delivery state, so an older (compatible) file loses durable rows on reopen.
import XCTest
import SQLite3
@testable import GodstoneMesh
@testable import GodstoneCore

final class ReadinessStore003Tests: XCTestCase {

    // MARK: - the SOURCE arms (what the audit confirmed by inspection)

    /// W01 -- the VERSIONED upgrade path may not drop durable tables.
    func testW01TheVersionedUpgradeDothNotDropDurableTables() throws {
        let source = try storeSource()
        let upgrade = try upgradeBody(source)
        let code = stripProse(upgrade)
        XCTAssertFalse(code.contains("DROP TABLE"),
                       "the production onUpgrade executeth DROP TABLE: a versioned reopen loseth the "
                       + "held rows the store existeth to keep (GS-STORE-003)")
    }

    /// W02 -- the migration engine that REPLACES the drop path must be the one BOUND to onUpgrade.
    func testW02TheMigrationEngineIsBoundToTheUpgrade() throws {
        let upgrade = try upgradeBody(try storeSource())
        // the CODE of the road, never the prose: a comment that NAMEth the engine proveth nothing, and
        // the first form of this arm passed on exactly such a comment.
        let code = stripProse(upgrade)
        XCTAssertTrue(code.contains("SchemaMigration") || code.contains("migrationEngine"),
                      "MessageStore must CALL the non-destructive migration engine on its upgrade road; "
                      + "its own contract sayeth 'the engine is what the runtime binds onUpgrade to once "
                      + "installs must survive' (GS-STORE-003)")
    }

    /// W03 -- the destructive path may survive ONLY for the never-shipped pre-ship case, and must SAY so.
    func testW03TheDestructivePathIsNamedAndBounded() throws {
        let source = try storeSource()
        if source.contains("DROP TABLE") {
            XCTAssertTrue(source.contains("pre-ship") || source.contains("never-shipped"),
                          "a destructive path that surviveth must be NAMED as the never-shipped "
                          + "pre-ship case, not left as the ordinary versioned road (GS-STORE-003)")
        }
    }

    // MARK: - the BEHAVIOURAL arms (the audit's own reproduction)

    /// W04 -- THE AUDIT'S PROBE. An older stamped file whose DDL is already compatible must be
    /// MIGRATED on reopen: the held frame and the delivery binding must survive, byte for byte.
    func testW04OlderVersionFileMustMigrateInsteadOfLosingDurableRows() throws {
        let url = tempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        var s1: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let r1 = SqliteDeliveryRepository(s1!)
        let mid = msgId(70)
        XCTAssertEqual(EnqueueResult.created,
                       r1.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        plantHeld(s1!, mid)
        let heldBefore = s1!.allHeldOrderedByPriority().first { $0.msgId == mid }
        XCTAssertNotNil(heldBefore, "boot 1 must actually hold the frame being protected")
        // A stale dev file: the DDL is already the CURRENT one, only the stamp is old.
        try s1!.execRawSql("PRAGMA user_version = 4")
        s1 = nil
        // boot 2: an EXISTING older file must migrate, never delete.
        var s2: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        var r2: SqliteDeliveryRepository? = SqliteDeliveryRepository(s2!)
        XCTAssertNotEqual(DeliveryLookup.notFound, r2!.get(mid),
                          "a versioned reopen LOSETH the durable delivery binding (GS-STORE-003)")
        let heldAfter = s2!.allHeldOrderedByPriority().first { $0.msgId == mid }
        XCTAssertEqual(heldBefore?.payload, heldAfter?.payload,
                       "the held frame's signed bytes must survive the migration byte for byte")
        r2 = nil; s2 = nil
        XCTAssertEqual(Int32(StoreSchema.dbVersion), userVersion(of: url),
                       "the migrated file is stamped at the current revision")
    }

    /// W05 -- THE NEGATIVE. A drifted (mismatched) older schema must be REFUSED with a typed
    /// failure: nothing deleted, nothing re-stamped, the file left as it was.
    func testW05DriftingOlderSchemaIsRefusedWithoutDeletingOrRestamping() throws {
        let url = tempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        var s1: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let mid = msgId(71)
        XCTAssertEqual(EnqueueResult.created,
                       SqliteDeliveryRepository(s1!).enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        // Tamper INTO a drifted older file: held_frames recreated WITHOUT its CHECK (the
        // pre-C6.4 shape the destructive road used to "handle" by deleting everything).
        try s1!.execRawSql("DROP TABLE IF EXISTS \(StoreSchema.table)")
        try s1!.execRawSql("CREATE TABLE \(StoreSchema.table) (\(StoreSchema.colMsgId) BLOB PRIMARY KEY, \(StoreSchema.colType) INTEGER)")
        try s1!.execRawSql("PRAGMA user_version = 4")
        s1 = nil
        let s2 = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        XCTAssertThrowsError(try s2.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                                   ackModeOrdinal: AckMode.none.rawValue,
                                                   expectedRecipient: nil),
                             "a drifted older schema must be refused fail-closed, not recreated (GS-STORE-003)")
        XCTAssertEqual(4, userVersion(of: url),
                       "a refused file must NOT be re-stamped to the current revision")
        XCTAssertEqual(1, scalar(of: url, "SELECT COUNT(*) FROM \(StoreSchema.deliveryTable)"),
                       "a refused file must NOT lose its durable rows")
    }

    /// W06 -- THE POSITIVE CONTROL: a brand-new empty file still opens, creates all four
    /// tables and is stamped at the current revision (the create road must not be broken by
    /// the repair, and this proves the harness can PASS as well as FAIL).
    func testW06BrandNewFileIsCreatedAtCurrentRevision() throws {
        let url = tempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        let s = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let mid = msgId(72)
        XCTAssertEqual(EnqueueResult.created,
                       SqliteDeliveryRepository(s).enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        for table in [StoreSchema.table, StoreSchema.deliveryTable,
                      StoreSchema.ackObligationTable, StoreSchema.ackFrameTable] {
            XCTAssertEqual(1, scalar(of: url,
                                     "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '\(table)'"),
                           "a brand-new file must create \(table)")
        }
        XCTAssertEqual(Int32(StoreSchema.dbVersion), userVersion(of: url),
                       "a brand-new file is stamped at the current revision")
    }

    /// W07 -- the executor's immutable-cell digest must report REAL bytes: it survives a
    /// migration unchanged, it CHANGES when an immutable cell changes, and it does NOT
    /// react to a legal transition of a non-immutable cell. A constant (or a digest taken
    /// over the frozen definition rather than the file) satisfies none of these.
    func testW07ImmutableDigestReadsRealBytesAcrossTheMigration() throws {
        let url = tempUrl()
        defer { try? FileManager.default.removeItem(at: url) }
        var s1: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let mid = msgId(73)
        XCTAssertEqual(EnqueueResult.created,
                       SqliteDeliveryRepository(s1!).enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        plantHeld(s1!, mid)
        let before = s1!.durableImmutableDigest()
        // A legal transition of a NON-immutable cell must not register.
        XCTAssertEqual(1, s1!.execRawUpdate("UPDATE \(StoreSchema.deliveryTable) SET \(StoreSchema.colDState) = 2 WHERE \(StoreSchema.colDMsgId) = ?", [mid]))
        XCTAssertEqual(before, s1!.durableImmutableDigest(),
                       "the digest is scoped to the IMMUTABLE domain: a legal state transition must not move it")
        try s1!.execRawSql("PRAGMA user_version = 4")
        s1 = nil
        var s2: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let after = s2!.durableImmutableDigest()
        XCTAssertEqual(before, after,
                       "the immutable cells must be byte-identical after the migration")
        // And the digest really reads the bytes: change one immutable cell and it moves.
        XCTAssertEqual(1, s2!.execRawUpdate("UPDATE \(StoreSchema.deliveryTable) SET \(StoreSchema.colDExpected) = ? WHERE \(StoreSchema.colDMsgId) = ?",
                                            [Data(repeating: 0x02, count: 16), mid]))
        XCTAssertNotEqual(after, s2!.durableImmutableDigest(),
                          "the digest must CHANGE when an immutable cell changes (else it is a constant)")
        s2 = nil
    }

    // MARK: - helpers

    private func tempUrl() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-store003-\(UUID().uuidString).db")
    }

    private func msgId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
    }

    private func nodeA() -> Data { Data(repeating: 0x01, count: 16) }

    private func plantHeld(_ store: SqliteMessageStore, _ mid: Data) {
        let f = FrameV2(type: .message, msgId: mid, routingTag: Data(count: 4), ttl: 10,
                        hopCount: 0, flags: 0, payload: Data(count: 32))
        _ = store.persist(f, receivedFrom: Data())
    }

    /// Read a scalar from the file on a SEPARATE read-only connection (the store under test
    /// is closed or idle by then; this never writes).
    private func scalar(of url: URL, _ sql: String) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return -1
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(stmt, 0)
    }

    private func userVersion(of url: URL) -> Int32 { scalar(of: url, "PRAGMA user_version") }

    /// Strip line prose so a source arm reads CODE, never a comment that QUOTES the very
    /// token it forbids (the first form of W01 failed on its own comment).
    private func stripProse(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let cut = line.firstIndex(of: "/") else { return line }
                return line[line.startIndex..<cut]
            }
            .joined(separator: "\n")
    }

    private func repoRoot() -> URL {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        return repo
    }

    private func storeSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/MessageStore.swift"), encoding: .utf8)
    }

    /// The body of the production upgrade method, from its declaration to the next top-level brace.
    private func upgradeBody(_ source: String) throws -> String {
        guard let start = source.range(of: "private func runMigrations(") else {
            // the method was RENAMED: that is itself worth failing on, because this arm addressth it BY NAME
            XCTFail("the versioned migration method is not called runMigrations(_:) any more: "
                    + "re-point this arm at its new name rather than skipping (GS-STORE-003)")
            return ""
        }
        let tail = source[start.lowerBound...]
        var depth = 0
        var body = ""
        for character in tail {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            body.append(character)
            if depth == 0 && body.contains("{") { break }
        }
        return body
    }
}
