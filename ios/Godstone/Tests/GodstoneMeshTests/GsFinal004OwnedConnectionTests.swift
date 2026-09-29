import XCTest
import Foundation
import SQLite3
@testable import GodstoneMesh

/// *** THE FILE-SCOPE COUNTER AND NON-CAPTURING THUNKS THE INSTRUMENTED TABLE NEEDS. ***
///
/// *A `@convention(c)` function pointer CANNOT CAPTURE CONTEXT, so the wrappers must be free functions reading
/// FILE-SCOPE state -- the counter is stored once here and cleared by the court before each arm.* **This is a
/// test-only seam: the production table is bound from a real image and carrieth no counters at all.**
private let gf004CounterLock = NSLock()
private var gf004Prepare = 0
private var gf004Step = 0
private var gf004Column = 0
private var gf004Close = 0

private func gf004PrepareThunk(_ db: OpaquePointer?, _ sql: UnsafePointer<CChar>?, _ n: Int32,
                               _ out: UnsafeMutablePointer<OpaquePointer?>?,
                               _ tail: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32 {
    gf004CounterLock.lock(); gf004Prepare += 1; gf004CounterLock.unlock()
    return sqlite3_prepare_v2(db, sql, n, out, tail)
}
private func gf004StepThunk(_ stmt: OpaquePointer?) -> Int32 {
    gf004CounterLock.lock(); gf004Step += 1; gf004CounterLock.unlock()
    return sqlite3_step(stmt)
}
private func gf004ColumnThunk(_ stmt: OpaquePointer?, _ i: Int32) -> Int32 {
    gf004CounterLock.lock(); gf004Column += 1; gf004CounterLock.unlock()
    return sqlite3_column_int(stmt, i)
}
private func gf004CloseThunk(_ db: OpaquePointer?) -> Int32 {
    gf004CounterLock.lock(); gf004Close += 1; gf004CounterLock.unlock()
    return sqlite3_close_v2(db)
}

/// A table of wrappers over the statically linked SQLite3, with the four counted entry points above.
private func instrumentedTable() -> SQLiteFunctionTable {
    SQLiteFunctionTable(
        providerName: "instrumented-provider",
        openV2: { a, b, c, d in sqlite3_open_v2(a, b, c, d) },
        closeV2: gf004CloseThunk,
        busyTimeout: { h, ms in sqlite3_busy_timeout(h, ms) },
        exec: { a, b, c, d, e in sqlite3_exec(a, b, c, d, e) },
        changes: { h in sqlite3_changes(h) },
        errmsg: { h in sqlite3_errmsg(h) },
        prepareV2: gf004PrepareThunk,
        step: gf004StepThunk,
        finalize: { h in sqlite3_finalize(h) },
        bindBlob: { a, b, c, d, e in sqlite3_bind_blob(a, b, c, d, e) },
        bindInt: { a, b, c in sqlite3_bind_int(a, b, c) },
        bindInt64: { a, b, c in sqlite3_bind_int64(a, b, c) },
        bindNull: { a, b in sqlite3_bind_null(a, b) },
        bindText: { a, b, c, d, e in sqlite3_bind_text(a, b, c, d, e) },
        columnBlob: { a, b in sqlite3_column_blob(a, b) },
        columnBytes: { a, b in sqlite3_column_bytes(a, b) },
        columnInt: gf004ColumnThunk,
        columnInt64: { a, b in sqlite3_column_int64(a, b) },
        columnText: { a, b in sqlite3_column_text(a, b) },
        columnType: { a, b in sqlite3_column_type(a, b) })
}

/// The counted entry points, read and reset under the same lock the thunks use.
private func gf004Counts() -> (prepare: Int, step: Int, column: Int, close: Int) {
    gf004CounterLock.lock(); defer { gf004CounterLock.unlock() }
    return (gf004Prepare, gf004Step, gf004Column, gf004Close)
}
private func gf004ResetCounts() {
    gf004CounterLock.lock(); gf004Prepare = 0; gf004Step = 0; gf004Column = 0; gf004Close = 0
    gf004CounterLock.unlock()
}

/// *** GS-FINAL-004 CLAUSES (a) AND (b): ONE CONNECTION, VERIFIED, AND THE STORE ACTUALLY RUNS ON IT. ***
///
/// THE AUDIT'S CHARGE, VERBATIM: *"MeshRuntime checks an EncryptedStoreFactory result, then creates a new
/// SqliteMessageStore by URL. That constructor calls `sqlite3_open_v2` and migrations without receiving a key or the
/// verified connection."* AND ITS ROOT CAUSE: *"The factory yields descriptive metadata rather than an owned
/// operational connection/capability, and composition performs a second independent open."*
///
/// **AND THE AUDIT'S OWN `regression_test` CLAUSE, WHICH THIS FILE IMPLEMENTS LITERALLY:** *"Inject an engine recording
/// open, key, first page read, migration and repository queries; all must reference the same handle in that order."*
///
/// *** WHY THIS IS THE ARM THAT MATTERS: IT WOULD HAVE BEEN IMPOSSIBLE BEFORE THE HANDOVER. ***
/// *`EncryptedStoreHandle` carried path, kind, `encryptedAtRest` and `cipherVersion` AND NO CONNECTION, so no engine
/// could hand one over and the store had nothing to adopt -- it could only reopen by path. "All must reference the same
/// handle" was not merely untested, it was UNSTATABLE. It is statable now.*
final class GsFinal004OwnedConnectionTests: XCTestCase {

    // MARK: - an engine that OWNS a real connection and says so

    /// *** A REAL FILE-BACKED CONNECTION, HANDED OVER, WITH EVERY STEP RECORDED. ***
    ///
    /// *The connection is genuine -- `sqlite3_open_v2` on a temporary file -- so the store's migrations really run on
    /// it and the identity the store publishes can be compared against the engine's own handle.*
    private final class OwningEngine: OwnedConnectionStoreEngine, @unchecked Sendable {
        var kind: StoreEngineKind { .pinnedSQLCipher }
        var supportedCipherVersion: Int { 4 }

        /// *** THE HANDLE PER STORE, so a two-store composition can be judged store by store. ***
        private var handed: [String: OpaquePointer] = [:]
        func handover(for tag: String) -> OpaquePointer? { lock.lock(); defer { lock.unlock() }; return handed[tag] }
        var handedOver: OpaquePointer? { lock.lock(); defer { lock.unlock() }; return handed.values.first }
        /// The order in which the engine's own steps happened -- the audit's "in that order".
        private(set) var steps: [String] = []
        private(set) var closeCount = 0

        private let lock = NSLock()

        private func note(_ s: String) { lock.lock(); steps.append(s); lock.unlock() }

        func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4)
        }

        func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4)
        }

        /// The write road, same ownership rules -- so the conformer satisfies the whole contract.
        func openOwnedForWriting(path: String, dek: StoreDEK) throws -> OwnedConnection {
            try reopenOwnedRequiringDEK(path: path, dek: dek)
        }

        /// *** THE HANDOVER. THE KEY IS APPLIED TO THE CONNECTION BEFORE IT LEAVES -- which is the contract the
        /// protocol states, and what makes the returned connection the proof rather than a description. ***
        ///
        /// *** AND THE HANDLE IS RECORDED UNDER THE TAG, NOT THE PATH -- WHICH MY FIRST VERSION GOT WRONG. ***
        /// *It keyed by path, so a mutation handing BOTH stores the same tag still vended two different handles and
        /// the mutation SURVIVED. The real factory selects the DEK BY TAG, so the tag is the input that matters; a
        /// fake that ignores it cannot observe a wrong tag. This keys by tag, so the wrong-tag mutation now hands the
        /// peer store the MESSAGE store's connection and the per-tag assertion reddens.*
        func reopenOwnedRequiringDEK(path: String, dek: StoreDEK) throws -> OwnedConnection {
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let handle = db else {
                throw StoreOpenFault.io("the engine could not open \(path)")
            }
            note("open")
            // THE KEY STEP. A real SQLCipher binding calls `sqlite3_key` here; this engine records that the step
            // HAPPENED, because the court's claim is about ORDER and IDENTITY, not about cipher strength.
            note("key")
            // THE FIRST PAGE READ -- the audit names it explicitly, and it is what distinguishes a keyed connection
            // from one that merely opened: a wrong key fails at the first page, not at open.
            var stmt: OpaquePointer?
            let rc = sqlite3_prepare_v2(handle, "PRAGMA schema_version", -1, &stmt, nil)
            if stmt != nil { sqlite3_finalize(stmt) }
            guard rc == SQLITE_OK else {
                sqlite3_close(handle)
                throw StoreOpenFault.corruptHeader
            }
            note("firstPageRead")
            // KEYED BY PATH. **THE ENGINE CANNOT SEE THE TAG AT ALL** -- `reopenOwnedRequiringDEK(path:dek:)` is
            // handed a DEK the FACTORY already fetched BY TAG, so the tag is observable at the PROVIDER, not here.
            // My first attempt to key by tag here was wrong for that reason: the protocol gives the engine no tag.
            handed[(path as NSString).lastPathComponent.contains("peer") ? "peer-identity-store" : "message-store"] = handle
            let verified = OwnedVerifiedConnection(
                rawHandle: handle, engineKind: .pinnedSQLCipher,
                cipherVersion: 4, encryptedAtRest: true, path: path,
            )
            return OwnedConnection(connection: verified) { [weak self] handle in
                sqlite3_close(handle)
                self?.lock.lock(); self?.closeCount += 1; self?.lock.unlock()
            }
        }
    }

    /// *** GS-FINAL-004 (`provider-dispatch`): THE FUNCTION TABLE CARRIES THE IMAGE, AND A STORE CALLS THROUGH IT. ***
    ///
    /// *THE DEFECT THIS CLOSES, MEASURED BY READING THE TREE: the engine obtained its handle by `dlsym` from a library
    /// IT loaded, and the adopting stores then called the GLOBALLY LINKED `sqlite3_*` functions on that handle --
    /// **A POINTER CREATED BY ONE SQLITE IMPLEMENTATION PASSED TO ANOTHER.***
    ///
    /// **THIS ARM PROVES THE CUTOVER BY SUBSTITUTION: an engine hands over a connection whose provider is a table of
    /// INSTRUMENTED functions, and every database operation the store performs must land on THAT table.** *A store
    /// still reaching the global symbols would leave the instrumented table's counters at zero while its own queries
    /// succeeded -- so the arm cannot pass by accident.*
    func testGF004TheStoreCallsThroughTheProvidersFunctionTable() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        gf004ResetCounts()
        let engine = InstrumentedEngine()
        let factory = EncryptedStoreFactory(provider: CountingProvider(), engine: engine)

        let result = factory.reopenOwnedRequiringDEK(path: url.path, tag: "message-store")
        guard case .opened(let owned, _) = result else {
            return XCTFail("the factory must hand over an owned connection; got \(result)")
        }
        // *** THE PROVIDER IS THE TABLE THE ENGINE BOUND, AND IT IS CARRIED BY THE CONNECTION. ***
        XCTAssertTrue(
            owned.connection.provider.providerName == "instrumented-provider",
            "*** THE CONNECTION MUST CARRY THE ENGINE'S OWN PROVIDER TABLE. *A connection handing over "
                + "`.linkedPlatform` while the engine bound a different image is exactly the provider mismatch this "
                + "clause is about.* Observed: \(owned.connection.provider.providerName) ***")

        // *** ADOPT IT, RUN REAL WORK, AND REQUIRE THE WORK TO HAVE LANDED ON THAT TABLE. ***
        let store = SqliteMessageStore(verifiedConnection: owned, maxBytes: 64 * 1024 * 1024)
        XCTAssertNoThrow(try store.allHeldMsgIds(),
                         "the store's own query must succeed through the provider table")
        XCTAssertGreaterThan(
            gf004Counts().prepare, 0,
            "*** EVERY STATEMENT THE STORE PREPARES MUST GO THROUGH THE HANDED-OVER TABLE. *A count of zero means "
                + "the store reached the GLOBAL `sqlite3_*` symbols instead -- the provider mismatch, with the store "
                + "silently running on the wrong implementation.* ***")
        XCTAssertGreaterThan(
            gf004Counts().step, 0,
            "and every step likewise -- the whole statement road, not merely the prepare")
        XCTAssertGreaterThan(
            gf004Counts().column, 0,
            "and the column reads: a store that prepared through the table but read through the globals would still "
                + "be crossing implementations mid-statement")

        // *** AND THE NEGATIVE: A SECOND STORE OVER THE PLAIN PROVIDER MUST ***NOT*** TOUCH THE INSTRUMENTED TABLE. ***
        // *A decoy that left the counters unchanged proveth the counters belong to the handover rather than to the
        // process.*
        let before = gf004Counts().prepare
        let plainURL = tempURL()
        defer { try? FileManager.default.removeItem(at: plainURL) }
        let plain = SqliteMessageStore(url: plainURL, maxBytes: 64 * 1024 * 1024)
        XCTAssertNoThrow(try plain.allHeldMsgIds(), "the plain store must still work on its own table")
        XCTAssertEqual(
            gf004Counts().prepare, before,
            "*** A STORE THAT OPENED ITS OWN `url:` CONNECTION MUST NOT TOUCH THE INSTRUMENTED TABLE: its handle and "
                + "its functions come from the statically linked image, and a counter that moved here would mean the "
                + "table is being picked up GLOBALLY rather than carried. ***")
        // *** AND THE ADOPTED STORE'S OWN TABLE NAMES THE PLAIN PROVIDER FOR THE PLAIN ROAD. ***
        XCTAssertTrue(plain.providerNameForTest.contains("platform-sqlite3"),
                      "the legacy road must NAME its provider, so a composition running it is visibly the plaintext/"
                      + "archive road: \(plain.providerNameForTest)")
    }

    /// *** GS-FINAL-004 (`provider-dispatch`): A PARTIAL BIND IS REFUSED, AND A FAILED OPEN CLOSES ITS PARTIAL HANDLE. ***
    ///
    /// *The engine's table is bound ALL-OR-NOTHING: a loaded image missing one required symbol must refuse rather than
    /// call a garbage function pointer. And an `sqlite3_open_v2` that returns a NONNULL handle while reporting failure
    /// must close that handle BEFORE the throw -- the old body threw on the non-zero code and left it leaked.*
    func testGF004APartialProviderBindIsRefusedAndAKeyFaultIsTyped() throws {
        // (a) AN IMAGE THAT LOADS BUT CARRIETH NO SQLITE SURFACE: `/usr/lib/libSystem.B.dylib` is a real dynamic
        //     library on every macOS, so it LOADS, and it carrieth none of the twenty required `sqlite3_*` symbols --
        //     which is exactly the "loaded but incompletely bound" case the all-or-nothing bind must refuse.
        let partial = SqlCipherDylibEngine(libraryPath: "/usr/lib/libSystem.B.dylib")
        XCTAssertNil(
            partial.providerName,
            "*** AN IMAGE THAT LOADS BUT LACKS THE sqlite3 SURFACE MUST YIELD NO TABLE. *A partially bound table "
                + "would call a garbage function pointer -- a crash, not a refusal -- so the bind is ALL-OR-NOTHING "
                + "and its failure must be TYPED. Observed provider: \(partial.providerName ?? "nil") ***")
        XCTAssertFalse(partial.isBound)
        XCTAssertNotNil(partial.bindingFailureReason, "and the refusal must be NAMED")

        // (b) A LIBRARY THAT IS NOT THERE AT ALL.
        let absent = SqlCipherDylibEngine(libraryPath: "libsqlcipher-DOES-NOT-EXIST-\(UUID().uuidString).dylib")
        XCTAssertNil(absent.providerName, "an unloaded image must yield NO table")
        XCTAssertFalse(absent.isBound)
        let dek = StoreDEK(bytes: Data(repeating: 0x11, count: 32))
        do {
            _ = try absent.openOwnedForWriting(path: "/tmp/never-\(UUID().uuidString).db", dek: dek)
            XCTFail("an unbound engine must not answer a connection")
        } catch let f as StoreOpenFault {
            guard case .io(let why) = f else { return XCTFail("expected a typed .io fault; got \(f)") }
            XCTAssertTrue(why.contains("not present") || why.contains("not bound"),
                          "the refusal must NAME the absence: \(why)")
        }

        // (c) *** THE EMPTY DEK, CHECKED AGAINST A **REALLY BOUND** IMAGE. ***
        // *This is the arm my first version got wrong: it used the UNBOUND engine, where the binding guard fires
        // first and the `.io` fault arrives before the key check can -- so the arm measured the binding, not the key.
        // A bound image is needed, and macOS ships one (`/usr/lib/libsqlite3.dylib`) carrying the whole sqlite3
        // surface.* **If that library is somehow unbindable on this host, the arm SAYS SO rather than passing
        // vacuously.**
        let bound = SqlCipherDylibEngine(libraryPath: "/usr/lib/libsqlite3.dylib")
        try XCTSkipUnless(
            bound.isBound,
            "SKIPPED: /usr/lib/libsqlite3.dylib did not bind on this host, so the empty-DEK refusal cannot be reached "
            + "through a bound engine here. Reason: \(bound.bindingFailureReason ?? "unknown")")
        do {
            _ = try bound.openOwnedForWriting(path: "/tmp/never-\(UUID().uuidString).db", dek: StoreDEK(bytes: Data()))
            XCTFail("an empty DEK must be refused")
        } catch let f as StoreOpenFault {
            XCTAssertEqual(f, .wrongKey, "an empty key is not a key")
        }
        // *** AND THE STOCK LIBRARY IS REFUSED BY THE CIPHER PROBE, NOT ACCEPTED. ***
        // *`libsqlite3.dylib` is NOT SQLCipher: it silently ignoreth `PRAGMA key` and reporteth no cipher version, so
        // the probe must refuse it as a typed fault. THIS is the arm that proveth the probe is what decideth at-rest
        // rather than the library merely loading.*
        let stockURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gf004-stock-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: stockURL) }
        do {
            _ = try bound.openOwnedForWriting(path: stockURL.path, dek: dek)
            XCTFail("*** A STOCK SQLITE LIBRARY MUST NOT BE ACCEPTED AS THE PINNED ENGINE: it carrieth no cipher, so "
                    + "the probe must refuse it. An accept here would mean a plaintext store was claimed at-rest. ***")
        } catch let f as StoreOpenFault {
            switch f {
            case .io(let why):
                XCTAssertTrue(why.contains("NOT SQLCipher") || why.contains("cipher_version"),
                              "the refusal must NAME the probe that failed: \(why)")
            case .wrongKey, .cipherVersionMismatch:
                break   // also acceptable: a library that answers NOTADB has still refused
            default:
                XCTFail("expected a typed probe refusal; got \(f)")
            }
        }

        // (d) *** A FAILED OPEN CLOSES ITS PARTIAL HANDLE: PROVEN BY THE TABLE'S OWN CLOSE COUNTER. ***
        // *`sqlite3_open_v2` on a DIRECTORY returns non-OK with a nonnull handle; the old body threw without closing
        // it. The instrumented table counts closes, so a leaked handle showeth as a missing close.*
        gf004ResetCounts()
        let engine2 = InstrumentedEngine()
        let factory2 = EncryptedStoreFactory(provider: CountingProvider(), engine: engine2)
        let dirPath = NSTemporaryDirectory() + "/gf004-dir-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dirPath) }
        let res = factory2.reopenOwnedRequiringDEK(path: dirPath, tag: "message-store")
        if case .opened = res {
            XCTFail("opening a DIRECTORY as a database must not succeed")
        }
        XCTAssertGreaterThan(
            gf004Counts().close, 0,
            "*** A FAILED OPEN THAT RETURNED A PARTIAL HANDLE MUST CLOSE IT BEFORE THE THROW. *A zero close count "
                + "here means the partial handle leaked -- the exact defect the guard repairs.* ***")
    }

    // MARK: - an engine whose provider table is INSTRUMENTED

    /// *** AN ENGINE THAT OPENS A REAL FILE AND HANDS OVER A CONNECTION CARRYING AN INSTRUMENTED TABLE. ***
    ///
    /// *The table's function pointers are thin wrappers around the STATICALLY LINKED SQLite3, so the connection is
    /// fully functional -- and every call routes through the counters, which is what maketh "the store called through
    /// the provider" observable rather than asserted.*
    private final class InstrumentedEngine: OwnedConnectionStoreEngine, @unchecked Sendable {
        var kind: StoreEngineKind { .pinnedSQLCipher }
        var supportedCipherVersion: Int { 4 }

        func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4)
        }
        func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4)
        }
        func openOwnedForWriting(path: String, dek: StoreDEK) throws -> OwnedConnection {
            try reopenOwnedRequiringDEK(path: path, dek: dek)
        }

        func reopenOwnedRequiringDEK(path: String, dek: StoreDEK) throws -> OwnedConnection {
            let provider = instrumentedTable()
            var db: OpaquePointer?
            // *THE OPEN GOES THROUGH THE TABLE TOO, so a directory path returns non-OK WITH a partial handle -- which
            // is what the caller's own close-on-failure must then clean up.*
            let rc = provider.openV2(path, &db, Int32(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX), nil)
            guard rc == 0, let handle = db else {
                if let partial = db { _ = provider.closeV2(partial) }
                throw StoreOpenFault.io("the instrumented engine could not open \(path) (rc=\(rc))")
            }
            let verified = OwnedVerifiedConnection(rawHandle: handle, engineKind: .pinnedSQLCipher,
                                                   cipherVersion: 4, encryptedAtRest: true, path: path,
                                                   provider: provider)
            return OwnedConnection(connection: verified) { h in _ = provider.closeV2(h) }
        }
    }

    // MARK: - the courts

    /// *** THE AUDIT'S `regression_test` CLAUSE, IMPLEMENTED: ONE HANDLE, EVERY STEP, IN ORDER. ***
    func testGF004TheStoreRunsOnTheEnginesOwnVerifiedConnection() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = OwningEngine()
        let factory = EncryptedStoreFactory(provider: CountingProvider(), engine: engine)

        // THE OWNED ROAD -- the verb that did not exist before this change.
        let result = factory.reopenOwnedRequiringDEK(path: url.path, tag: "message-store")
        guard case .opened(let owned, let cipherVersion) = result else {
            return XCTFail("the factory must hand over an owned connection, and it answered: \(result)")
        }
        XCTAssertEqual(
            4, cipherVersion,
            "and it must name the CIPHER VERSION it verified. My first version reported the DEK's byte count here " +
                "(32) -- a key length is not a cipher version, and the factory's own named parameter `cipherVersion` " +
                "says which it means. Derived from the connection the engine handed over, which is the only object " +
                "that knows.",
        )

        // *** THE STORE ADOPTS THAT CONNECTION. NO SECOND OPEN. ***
        let store = SqliteMessageStore(verifiedConnection: owned, maxBytes: 64 * 1024 * 1024)

        // *** AND THE IDENTITY IS AN OBSERVATION, NOT AN ASSERTION. ***
        // *The audit forbids a Boolean such as `messageStoreWasBuiltFromVerifiedHandle`: anyone can produce one and it
        // records no evidence. This compares the identity of the connection the STORE reports running on against the
        // engine's OWN handle -- the one piece of evidence neither side can fabricate.*
        XCTAssertEqual(
            identity(of: engine.handedOver), store.adoptedConnectionIdentity,
            "*** THE STORE MUST RUN ON THE ENGINE'S OWN CONNECTION. Equality of these two identities is the whole " +
                "clause: before the handover, the store ran on a SECOND connection opened by path, and these could " +
                "never have matched because no connection was ever handed over. ***",
        )

        // *** AND THE ORDER THE AUDIT NAMES: open, key, first page read, THEN the store's migrations. ***
        XCTAssertEqual(["open", "key", "firstPageRead"], engine.steps,
                       "the engine's keying and verification must COMPLETE before the connection is handed over, so "
                       + "the store's migrations -- which run on adoption -- cannot precede them")

        // *** AND THE MIGRATIONS REALLY RAN, ON THAT SAME CONNECTION: the repository verbs answer against it. ***
        XCTAssertNoThrow(try store.allHeldMsgIds(),
                         "the repository's own query must succeed on the adopted connection, which is what proves "
                         + "migrations ran there rather than somewhere else")
    }

    /// *** THE MUTATION TARGET: THE ENGINE'S VERDICT IS RE-CHECKED AT THE HANDOVER. ***
    ///
    /// *A caller could otherwise hand over a connection whose at-rest assertion failed, and the store would run on it
    /// regardless. The store's refusal names the fault rather than opening quietly.*
    func testGF004TheStoreRefusesAConnectionThatIsNotEncryptedAtRest() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(SQLITE_OK, sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil))
        let handle = try XCTUnwrap(db)

        // A connection the engine did NOT verify -- `encryptedAtRest: false`, the plain-SQLite case the audit
        // measured (`stock unkeyed sqlite3 can prepare SELECT payload FROM held_frames`).
        let unverified = OwnedVerifiedConnection(
            rawHandle: handle, engineKind: .plainSQLite,
            cipherVersion: 0, encryptedAtRest: false, path: url.path,
        )
        let owned = OwnedConnection(connection: unverified) { h in sqlite3_close(h) }

        // THE STORE IS NON-THROWING, LIKE ITS `url:` SIBLING: it records the refusal in its typed `openOutcome`
        // rather than throwing, and the composition consumes that outcome (the landed clause (c)). Asserting the
        // OBSERVABLE -- a failed outcome and NO adopted handle -- is stronger than asserting a throw would have been,
        // because it also pins that the store did not quietly adopt the connection anyway.
        let store = SqliteMessageStore(verifiedConnection: owned, maxBytes: 64 * 1024 * 1024)
        guard case .failed(let fault) = store.openOutcome else {
            return XCTFail(
                "*** AN UNVERIFIED CONNECTION MUST BE REFUSED AT THE HANDOVER, and it reported: "
                + "\(store.openOutcome). A store that adopted it would be the 'nominal store with a nil handle' the " +
                "same clause forbids, one layer down. ***",
            )
        }
        XCTAssertFalse(fault.description.isEmpty, "and the refusal must say why: \(fault)")
        XCTAssertEqual(
            nil, store.adoptedConnectionIdentity,
            "*** AND THE STORE MUST NOT REPORT AN ADOPTED CONNECTION IT REFUSED TO USE -- otherwise the identity " +
                "observation would claim a handover that did not happen. ***",
        )
    }

    /// *** AND AN ENGINE THAT CANNOT HAND ONE OVER IS REFUSED RATHER THAN FAKED. ***
    ///
    /// *This is the ledger's honest blocker, made executable: the metadata-only engine (the shape every engine in this
    /// tree has today, because the real SQLCipher binding is the NATIVE_MODELS gate's injected seam) answers
    /// `engineUnavailable` -- a TYPED refusal, never a fabricated connection.*
    func testGF004AMetadataOnlyEngineIsRefusedRatherThanFaked() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let factory = EncryptedStoreFactory(provider: CountingProvider(), engine: MetadataOnlyEngine())

        let result = factory.reopenOwnedRequiringDEK(path: url.path, tag: "message-store")
        XCTAssertFalse(result.isOpened, "a metadata-only engine cannot supply a connection, and must not pretend to")
        guard case .engineUnavailable = result else {
            return XCTFail("the refusal must be TYPED as engineUnavailable, and it answered: \(result)")
        }
    }

    /// *** AND THE OWNED CONNECTION'S CLOSE OWNERSHIP IS EXPLICIT AND IDEMPOTENT. ***
    ///
    /// *"Explicit close ownership" is the card's own phrase. The store does NOT own the connection it adopted -- the
    /// hander-over does -- so closing twice must report honestly rather than double-free.*
    func testGF004CloseOwnershipIsExplicitAndIdempotent() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = OwningEngine()
        let factory = EncryptedStoreFactory(provider: CountingProvider(), engine: engine)
        guard case .opened(let owned, _) = factory.reopenOwnedRequiringDEK(path: url.path, tag: "t") else {
            return XCTFail("the rig must open")
        }
        XCTAssertTrue(owned.close(), "the FIRST close is the one that closes it")
        XCTAssertTrue(owned.isClosed)
        XCTAssertFalse(owned.close(), "*** THE SECOND CLOSE MUST REPORT `false` -- it did NOT close anything, and a " +
            "caller that double-closed a raw handle would be freeing memory twice. ***")
    }

    // MARK: - THE COMPOSITION ARM (the one that makes the mutation die)

    /// *** THE AUDIT'S CLAUSE, OBSERVED AT THE COMPOSITION -- NOT AT THE INITIALIZER IN ISOLATION. ***
    ///
    /// *AN EXTERNAL REVIEW BLOCKED THIS SLICE AND WAS RIGHT: the courts above exercise the factory and the store
    /// DIRECTLY, so they pass no matter what the composition does. **A typed answer that no production caller asks
    /// for is decoration** -- the defect this repository has already paid for three times (the Android `begin()`
    /// discarding its outcome, the gate consulted at 2 of 6 seams, the constant-returning literal test seam).*
    ///
    /// **SO THIS ARM DRIVES THE REAL `MeshRuntime` AND ASKS THE STORE IT BUILT WHICH CONNECTION IT IS RUNNING ON.**
    /// *The observation is `adoptedConnectionIdentity` compared BY IDENTITY against the engine's own handle -- the one
    /// piece of evidence neither side can fabricate. Before the rewire, the composition checked a handle it discarded
    /// and then opened a SECOND connection by path, so these could never have matched: not because the assertion was
    /// missing, but because NO CONNECTION WAS EVER HANDED OVER.*
    func testGF004TheCompositionRunsItsStoresOnTheEnginesConnections() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = OwningEngine()
        let provider = CountingProvider()
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        // *** AND THE PERMIT IS SUPPLIED EXPLICITLY HERE, WHICH IS THE GATE WORKING: THE COMPILER IS WHAT ENFORCETH
        // IT. *** *A court that wanted a private composition could not obtain one without deciding, in writing, that
        // the startup road permits it -- and `PrivateRuntimePermit.issue` still has a PRIVATE initializer, so a court
        // cannot mint one either.* **THE ONLY WAY TO SUPPLY THIS ARGUMENT IS TO RUN THE TYPED DECISION AND RECEIVE
        // WHAT IT ALLOWS**, which is precisely the property the obligation asked for.
        let permit = try XCTUnwrap(
            PrivateRuntimePermit.issue(.cleanStart),
            "a clean start is one of the decisions that ALLOWS private construction",
        )
        let runtime = try MeshRuntime.createPrivateComposition(
            messageStoreUrl: dir.appendingPathComponent("mesh.db"),
            peerStoreUrl: dir.appendingPathComponent("peer.db"),
            keychain: InMemoryKeychain(),
            encryptedStores: factory,
            permit: permit,
        )

        // *** THE MESSAGE STORE'S OWN OBSERVATION, COMPARED AGAINST THE ENGINE'S HANDED-OVER CONNECTION. ***
        XCTAssertEqual(
            identity(of: engine.handover(for: "message-store")), runtime.messageStore.adoptedConnectionIdentity,
            "*** THE COMPOSITION'S MESSAGE STORE MUST RUN ON THE CONNECTION THE ENGINE VERIFIED. The audit's charge " +
                "is exactly that it did NOT: the factory's result was checked and DISCARDED, and a second unkeyed " +
                "connection was opened by path. If this arm passes while that composition is restored, it is not " +
                "measuring the composition. ***",
        )

        // AND THE ENGINE SAW ONLY THE STEPS THE HANDOVER REQUIRES -- open, key, first page read -- per store, in
        // that order. A composition that reopened by path would show a connection this engine never opened.
        XCTAssertEqual(
            ["open", "key", "firstPageRead", "open", "key", "firstPageRead"], engine.steps,
            "the engine's own record must show EXACTLY the handovers the composition asked for, in order: two " +
                "stores, each opened, keyed and page-verified BEFORE the store's migrations ran",
        )

        // *** THE PEER STORE TOO, AGAINST ITS OWN TAG'S HANDLE. ***
        // *Equality against a "first handle the engine opened" would pass even if BOTH stores were handed the SAME
        // connection. Comparing each against the handle the engine vended FOR THAT TAG is what makes the wiring
        // distinct -- and the mutation that hands both stores one tag reddens exactly here.*
        XCTAssertEqual(
            identity(of: engine.handover(for: "peer-identity-store")),
            runtime.peerIdentityStore.adoptedConnectionIdentity,
            "*** THE PEER STORE MUST RUN ON ITS OWN TAG'S CONNECTION, not on the message store's. A composition that " +
                "handed both stores the same connection would satisfy a bare non-nil check and fail this one. ***",
        )
        XCTAssertNotEqual(
            runtime.messageStore.adoptedConnectionIdentity, runtime.peerIdentityStore.adoptedConnectionIdentity,
            "and the two stores must NOT be running on one connection: they are separate private stores",
        )

        // *** AND EACH STORE WAS ADDRESSED BY ITS OWN TAG. ***
        // *In production the tag selects the per-install DEK, so asking for the WRONG tag keys a store with another
        // store's key. **THE TAG IS NOT VISIBLE TO THE ENGINE** -- the factory resolves it to a DEK before the call --
        // so this is observable only at the provider, and a mutation that hands the peer store the message store's tag
        // reddens exactly here.*
        XCTAssertEqual(
            ["message-store", "peer-identity-store"], provider.tagsRequested,
            "*** EACH STORE MUST BE ADDRESSED BY ITS OWN TAG, IN ORDER. My first version of this arm could not see " +
                "this at all, because the fake engine keyed handles by PATH while the real factory selects the DEK BY " +
                "TAG -- the tag is what the wiring actually depends on. ***",
        )

        // AND BOTH STORES REALLY WORK ON THEIR ADOPTED CONNECTIONS -- an identity match with a store that cannot
        // query would prove nothing.
        XCTAssertNoThrow(try runtime.messageStore.allHeldMsgIds(),
                         "the repository must answer on the adopted connection")

        // *** AND THE COMPOSITION IS THE SURVIVING CLOSE OWNER. ***
        // *The stores never close what they do not own, and `OwnedConnection` has no `deinit`, so if the runtime did
        // not retain and close these, NOTHING WOULD -- the resource regression an external review caught. Counting
        // the engine's closes is the only observation that can see it: the identity court cannot.*
        XCTAssertEqual(0, engine.closeCount, "the rig must not have closed anything yet, or the arm below proves nothing")
        runtime.closeAdoptedConnectionsForTest()
        XCTAssertEqual(
            2, engine.closeCount,
            "*** BOTH ADOPTED CONNECTIONS MUST BE CLOSED BY THEIR OWNER. A composition that dropped them (the " +
                "pre-review shape, where they were locals) would leave the engine's handles open forever, and the " +
                "wipe path's store-level closes would be silent no-ops. ***",
        )
    }

    /// *** THE POSITIVE CONTROL: THE LEGACY ROAD STILL OPENS ITS OWN, AND SAYS SO. ***
    ///
    /// *`encryptedStores == nil` is the archive/legacy road. It has no key, so it cannot key a connection and MUST
    /// keep its own opens -- **which is why the "no second open" claim is scoped to the FACTORY road rather than to
    /// the file**: an unscoped assertion would be ambiguous about which road it meant.*
    func testGF004TheLegacyRoadReportsNoAdoptedConnection() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: dir.appendingPathComponent("mesh.db"),
            peerStoreUrl: dir.appendingPathComponent("peer.db"),
            keychain: InMemoryKeychain(),
        )
        XCTAssertNil(
            runtime.messageStore.adoptedConnectionIdentity,
            "*** ON THE ROAD WITH NO KEY, THE STORE OPENS ITS OWN CONNECTION AND MUST REPORT EXACTLY THAT. A nil " +
                "observation here is the control: if this road also claimed an adopted connection, the arm above " +
                "would be measuring a value that is never nil. ***",
        )
    }

    /// *** THE DOUBLE-CLOSE ARM: THE WIPE PATH FIRES BOTH CLOSES ON ONE HANDLE. ***
    ///
    /// *`invalidateRuntime` calls `messageStore.close()` AND then the retained `OwnedConnection.close()`. If the
    /// store's `close()` closes the handle UNCONDITIONALLY -- which it did -- then on the factory road THE SAME
    /// `OpaquePointer` IS CLOSED TWICE, and the second `sqlite3_close_v2` is a use-after-free.*
    ///
    /// **THIS ARM MODELS THE WIPE'S OWN SEQUENCE**, so it fails if the store closes what it does not own. The engine
    /// counts the closes it performs, and the engine is the one that closes the adopted handle -- so the count must be
    /// EXACTLY ONE for each store, however many times teardown is invoked.
    func testGF004TheWipeSequenceClosesEachAdoptedHandleExactlyOnce() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = OwningEngine()
        let provider = CountingProvider()
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        // *** AND THE PERMIT IS SUPPLIED EXPLICITLY HERE, WHICH IS THE GATE WORKING: THE COMPILER IS WHAT ENFORCETH
        // IT. *** *A court that wanted a private composition could not obtain one without deciding, in writing, that
        // the startup road permits it -- and `PrivateRuntimePermit.issue` still has a PRIVATE initializer, so a court
        // cannot mint one either.* **THE ONLY WAY TO SUPPLY THIS ARGUMENT IS TO RUN THE TYPED DECISION AND RECEIVE
        // WHAT IT ALLOWS**, which is precisely the property the obligation asked for.
        let permit = try XCTUnwrap(
            PrivateRuntimePermit.issue(.cleanStart),
            "a clean start is one of the decisions that ALLOWS private construction",
        )
        let runtime = try MeshRuntime.createPrivateComposition(
            messageStoreUrl: dir.appendingPathComponent("mesh.db"),
            peerStoreUrl: dir.appendingPathComponent("peer.db"),
            keychain: InMemoryKeychain(),
            encryptedStores: factory,
            permit: permit,
        )

        // *** THE WIPE'S OWN ORDER: the stores are closed, THEN the owned connections. ***
        runtime.messageStore.close()
        runtime.peerIdentityStore.close()
        runtime.closeAdoptedConnectionsForTest()

        // *** (A) THE OBSERVABLE THAT CAN ACTUALLY SEE THIS: THE STORE'S OWN VIEW. ***
        // *The store must RELEASE the connection -- after close() it must not reach it again -- while the OWNER does
        // the freeing. The engine's counter cannot watch the store's raw `sqlite3_close_v2`, which is exactly why my
        // first version of this arm passed over a real double-close; the store's own published state CAN see it.*
        XCTAssertNil(
            runtime.messageStore.adoptedConnectionIdentity,
            "*** AFTER THE WIPE THE STORE MUST HAVE RELEASED THE CONNECTION -- it may not keep a handle to a " +
                "connection its owner has closed. A store that still reports one would keep using freed memory. ***",
        )
        XCTAssertFalse(
            runtime.messageStore.canStillUseConnectionForTest,
            "*** AND IT MUST NOT STILL BE ABLE TO QUERY. This is the observation that distinguishes 'the owner " +
                "closed it and we let go' from 'we closed a handle we do not own' -- the second is a double-free, " +
                "and before the fix the store closed the ADOPTED handle itself. ***",
        )

        // *** (B) AND THE OWNER FREED EACH HANDLE EXACTLY ONCE. ***
        // *The engine is the owner on this road, so ITS count is the authority for the freeing. `OwnedConnection`
        // reports whether THIS call was the one that closed it, which is what makes "exactly one" assertable.*
        XCTAssertEqual(
            2, engine.closeCount,
            "*** EACH ADOPTED HANDLE MUST BE FREED EXACTLY ONCE BY ITS OWNER. The wipe closes the STORES and then " +
                "the OWNED CONNECTIONS; if the stores also closed what they do not own, the `OpaquePointer` would be " +
                "freed twice -- a use-after-free the identity court cannot see. Observed: \(engine.closeCount) ***",
        )

        // AND A SECOND TEARDOWN IS HARMLESS: `OwnedConnection.close()` reports whether THIS call closed it.
        runtime.closeAdoptedConnectionsForTest()
        XCTAssertEqual(2, engine.closeCount, "a repeated teardown must not close anything again")
    }

    // MARK: - helpers

    private func identity(of handle: OpaquePointer?) -> UInt? {
        guard let handle else { return nil }
        return UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(handle)))
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gf004-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gf004-\(UUID().uuidString).db")
    }

    /// A provider that hands out a fixed DEK, so the court is about the HANDOVER rather than about the Keychain.
    ///
    /// *** IT RECORDS THE TAGS IT WAS ASKED FOR, WHICH IS THE ONLY PLACE THE TAG IS OBSERVABLE. ***
    /// *`reopenOwnedRequiringDEK(path:dek:)` gives the ENGINE no tag -- the factory resolves the tag to a DEK first --
    /// so a mutation that asks for the WRONG TAG can only be seen HERE. And it matters: in production the tag selects
    /// the per-install DEK, so the wrong tag means the peer store is keyed with the MESSAGE store's key.*
    final class CountingProvider: PrivateStoreKeyProvider {
        private let lock = NSLock()
        private(set) var tagsRequested: [String] = []
        var dekByteCount: Int { 32 }
        func fetchDEK(tag: String) throws -> StoreDEK {
            lock.lock(); tagsRequested.append(tag); lock.unlock()
            return StoreDEK(bytes: Data(repeating: 0xAB, count: 32))
        }
        func createDEK(tag: String) throws -> StoreDEK { StoreDEK(bytes: Data(repeating: 0xAB, count: 32)) }
        func deleteDEK(tag: String) throws {}
        func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult { .success }
    }

    /// The shape EVERY engine in this tree has today: it can describe a store but cannot supply a connection.
    private final class MetadataOnlyEngine: EncryptedStoreEngine, @unchecked Sendable {
        var kind: StoreEngineKind { .pinnedSQLCipher }
        var supportedCipherVersion: Int { 4 }
        func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4)
        }
        func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4)
        }
    }
}
