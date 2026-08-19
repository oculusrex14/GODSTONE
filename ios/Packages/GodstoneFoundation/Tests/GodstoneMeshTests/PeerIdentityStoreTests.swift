import XCTest
import SQLite3
@testable import GodstoneMesh

final class PeerIdentityStoreTests: XCTestCase {

    private func tempDbUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peer_store_test_\(UUID().uuidString).db")
    }

    func testFreshDatabaseInitialization() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let row = try store.readRaw(Data(repeating: 0x01, count: 16))
        XCTAssertNil(row)

        // Verify user_version
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 1)
        sqlite3_finalize(stmt)
        sqlite3_close_v2(db)
    }

    func testReopenExistingValidDatabase() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let nodeId = Data(repeating: 0x11, count: 16)
        let signPub = Data(repeating: 0x22, count: 32)
        let staticPub = Data(repeating: 0x33, count: 32)

        do {
            let store = try SqlitePeerIdentityStore(url: url)
            let affected = try store.insertFirstSeen(
                nodeId: nodeId,
                signingPub: signPub,
                acceptedStatic: staticPub,
                acceptedGeneration: 0,
                trustCode: Int32(PeerTrustLevel.tofuPinned.persistedCode)
            )
            XCTAssertEqual(affected, 1)
        }

        // Reopen
        let store2 = try SqlitePeerIdentityStore(url: url)
        let row = try store2.readRaw(nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.nodeIdRaw, nodeId)
        XCTAssertEqual(row?.signingPublicKeyRaw, signPub)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, staticPub)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.trustCodeRaw, Int32(PeerTrustLevel.tofuPinned.persistedCode))
        XCTAssertNil(row?.pendingStaticDhPublicKeyRaw)
        XCTAssertNil(row?.pendingGenerationRaw)
    }

    func testMalformedCurrentSchemaFailsClosed() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE peer_identities (node_id BLOB PRIMARY KEY, signing_public_key BLOB)", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA user_version = 1", nil, nil, nil)
        sqlite3_close_v2(db)

        XCTAssertThrowsError(try SqlitePeerIdentityStore(url: url))
    }

    func testFutureVersionFailsClosed() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA user_version = 2", nil, nil, nil)
        sqlite3_close_v2(db)

        XCTAssertThrowsError(try SqlitePeerIdentityStore(url: url))
    }

    func testUnversionedExistingTableFailsClosed() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        sqlite3_exec(db, PeerIdentitySchema.createTableSql, nil, nil, nil)
        sqlite3_exec(db, "PRAGMA user_version = 0", nil, nil, nil)
        sqlite3_close_v2(db)

        XCTAssertThrowsError(try SqlitePeerIdentityStore(url: url))
    }

    func testFileProtectionCompleteByDefault() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        XCTAssertEqual(store.fileProtection, .complete)
    }

    struct InjectedProtectionError: Error {}

    func testFileProtectionFailureFailsClosed() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(
            try SqlitePeerIdentityStore(url: url, protectionSetter: { _, _ in
                throw InjectedProtectionError()
            })
        ) { error in
            guard case PeerStoreError.fileProtectionFailed = error else {
                XCTFail("Expected fileProtectionFailed error, got \(error)")
                return
            }
        }
    }
}
