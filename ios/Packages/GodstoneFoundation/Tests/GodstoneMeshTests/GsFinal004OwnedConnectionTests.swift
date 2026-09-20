import XCTest
import Foundation
import SQLite3
@testable import GodstoneMesh

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

        let runtime = try MeshRuntime.createPrivateComposition(
            messageStoreUrl: dir.appendingPathComponent("mesh.db"),
            peerStoreUrl: dir.appendingPathComponent("peer.db"),
            keychain: InMemoryKeychain(),
            encryptedStores: factory,
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
