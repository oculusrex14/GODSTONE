// GS-STORE-002 -- the iOS private stores must be opened through the ENCRYPTED factory, with the
// per-install DEK applied. The audit reproduced the opposite: "AuditStorageTests writes through actual
// SqliteMessageStore. The resulting file has the SQLite format 3 header, and stock unkeyed sqlite3 can
// prepare SELECT payload FROM held_frames. MeshRuntime still instantiates both old stores."
import XCTest
import Foundation
import SQLite3
@testable import GodstoneMesh
@testable import GodstoneCore

final class ReadinessStore002Tests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class InMemoryJournal: WipeJournal, @unchecked Sendable {
        var state: WipeState = .idle
        func read() -> WipeState { state }
        func write(_ s: WipeState) { state = s }
        func clear() { state = .idle }
    }

    /// A Keychain seam that holdeth real DEKs, so a first install can mint them and a reopen can find them.
    private final class VerifyingProvider: PrivateStoreKeyProvider, @unchecked Sendable {
        var deks: [String: StoreDEK] = [:]
        /// How many times the composition ASKED this provider for a DEK -- the measurement that proveth the factory
        /// road was REACHED and not merely permitted (a first draft of the control reached for the runtime's PRIVATE
        /// `wipeKeyProvider`, and THE LAW IS THAT A PRIVATE FIELD IS NOT A DOOR: the assertion was changed rather
        /// than the field's protection -- and the count is the better witness anyway, because it observeth the
        /// REACHING rather than the RESULT).
        var fetchCount = 0
        var dekByteCount: Int { 32 }
        func fetchDEK(tag: String) throws -> StoreDEK {
            fetchCount += 1
            guard let d = deks[tag] else { throw StoreKeyError.dekNotFound }
            return d
        }
        func createDEK(tag: String) throws -> StoreDEK {
            let d = StoreDEK(bytes: Data(repeating: 0xAB, count: 32)); deks[tag] = d; return d
        }
        func deleteDEK(tag: String) throws { deks.removeValue(forKey: tag) }
        func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult {
            .success
        }
    }

    /// *** A FAKE ENGINE THAT ANSWERETH ON ITS OWN WORD -- WHICH IS EXACTLY WHAT THE CARD FORBIDDETH A CALLER FROM
    /// BELIEVING: "an enum value called pinnedSQLCipher is not engine verification." It is used ONELY as the positive
    /// control for the SHAPE of the refusal, and NOTHING in this court is evidence that any store is encrypted. ***
    private final class VerifyingEngine: EncryptedStoreEngine, @unchecked Sendable {
        var kind: StoreEngineKind { .pinnedSQLCipher }
        var supportedCipherVersion: Int { 4 }
        private func handle(_ path: String) -> EncryptedStoreHandle {
            EncryptedStoreHandle(path: path, kind: .pinnedSQLCipher, encryptedAtRest: true, cipherVersion: 4)
        }
        func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle { handle(path) }
        func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle { handle(path) }
    }

    /// The audit's own probe, exactly: **STOCK UNKEYED sqlite3** preparing against the file the composition wrote.
    /// It answereth the prepare's return code, so a caller can judge both readable and unreadable databases -- and a
    /// caller that only ever seeth one of them cannot tell a law from a file that was never created.
    private func unkeyedPrepare(_ url: URL) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='held_frames'"
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if stmt != nil { sqlite3_finalize(stmt) }
        return rc
    }

    private func privateDir(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// W01 -- THE FINDING'S CORE: the runtime must obtain its stores through the factory.
    func testW01TheRuntimeOpenethItsStoresThroughTheEncryptedFactory() throws {
        let source = try runtimeSource()
        XCTAssertTrue(source.contains("EncryptedStoreFactory"),
                      "MeshRuntime must compose its private stores through EncryptedStoreFactory, so "
                      + "the per-install DEK is applied; today it constructeth SqliteMessageStore and "
                      + "SqlitePeerIdentityStore directly (GS-STORE-002)")
        XCTAssertTrue(source.contains("encryptedStores"),
                      "and the factory must be a SEAM the composition carrieth, so a caller cannot "
                      + "compose private stores without saying how they are encrypted")
        XCTAssertTrue(source.contains("reopenExisting("),
                      "the runtime must ASK the factory for the at-rest verdict before opening a store")
    }

    /// W02 -- the seam REFUSETH a plain database: a store opened without its DEK is not a private store.
    func testW02TheFactoryRefusethAPlainDatabaseWithoutItsDEK() throws {
        let source = try factorySource()
        XCTAssertTrue(source.contains("reopenRequiringDEK"),
                      "the factory's reopen road must REQUIRE the DEK, so a plain file cannot be "
                      + "mistaken for a private store")
        XCTAssertTrue(source.contains("wrongKey"),
                      "and a file that cannot be decrypted must be a named refusal, never a silent open")
    }

    /// W03 -- the protection errors may not be SWALLOWED on the composition road.
    func testW03TheCompositionCarriethNoSwallowedProtectionError() throws {
        let source = try runtimeSource()
        // an EMPTY line spliteth to NOTHING, and `[0]` on nothing is the crash this court already
        // suffered once: the strip is guarded rather than assumed
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let cut = line.firstIndex(of: "/") else { return line }
                return line[line.startIndex..<cut]
            }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("try? SqliteMessageStore"),
                       "a store that cannot be opened under its DEK must REFUSE, never be swallowed")
        XCTAssertFalse(code.contains("try? SqlitePeerIdentityStore"))
    }

    /// W04 -- *** BEHAVIOURAL, AND THE CARD'S OWN CLOSURE TEST. RUN RED BEFORE ITS REPAIR. ***
    ///
    /// The three arms above are SOURCE laws: they read the TEXT of the composition and look for substrings. That is
    /// ONE STEP ABOVE A COMMENT -- it proveth what the code SAYETH and never what it DOTH, and this finding's whole
    /// history is a composition whose own comment claimed the legacy default "at least SAYETH so now, instead of
    /// opening ordinary SQLite in silence" WHILE THE CODE SAID NOTHING AT ALL.
    ///
    /// The card's closure test is behavioural -- "The independent testPrivateMessageStoreMustNotBeReadableByUnkeyedSQLite
    /// must pass with a nonempty private database" -- so this arm COMPOSETH the runtime through the composition root,
    /// WRITETH a private store, and then READS THAT FILE WITH STOCK UNKEYED sqlite3, which is the audit's own
    /// reproduction: "The resulting file has the SQLite format 3 header, and stock unkeyed sqlite3 can prepare SELECT
    /// payload FROM held_frames."
    ///
    /// IT ACCEPTETH EITHER OF **TWO** LAWFUL OUTCOMES AND REFUSETH EVERY OTHER: the composition either REFUSETH to
    /// compose a private store at all (no verifying factory, no private store), or it produced a store an unkeyed
    /// reader CANNOT prepare against. THE THIRD OUTCOME -- silently producing a readable "private" store -- IS THE
    /// FINDING.
    func testW04APrivateStoreIsNeverReadableByUnkeyedSQLite() throws {
        let dir = try privateDir("gs-store-002")
        defer { try? FileManager.default.removeItem(at: dir) }

        // *** (A) THE DISCRIMINATOR FIRST, OR THE SILENCE PROVETH NOTHING. *** The law below asserteth that the probe
        // CANNOT read the private store -- and that assertion would pass just as well if the probe could not read
        // ANYTHING, or if no file existed at all. So the probe is FIRST pointed at the composition that declares
        // itself plaintext, and it MUST detect that one: A CHECK THAT CANNOT SEE THE THING IT JUDGES IS NOT A CHECK.
        let plainURL = dir.appendingPathComponent("declared-plaintext.db")
        _ = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: plainURL,
            peerStoreUrl: dir.appendingPathComponent("declared-plaintext-peers.db"),
            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        XCTAssertEqual(unkeyedPrepare(plainURL), SQLITE_OK,
                       "THE DISCRIMINATOR: the unkeyed probe MUST detect a readable database, or its verdict on the "
                       + "private store proveth nothing at all")

        let messageURL = dir.appendingPathComponent("messages.db")
        let peerURL = dir.appendingPathComponent("peers.db")

        do {
            _ = try MeshRuntime.create(
                messageStoreUrl: messageURL, peerStoreUrl: peerURL,
                journal: InMemoryJournal(), keychain: InMemoryKeychain())
        } catch MeshRuntime.MeshRuntimeError.privateStoreNotEncrypted {
            // THE FIRST LAWFUL OUTCOME: the composition REFUSED to compose a private store without a verifying factory,
            // so no private store existeth to be read. The law this arm asserteth holdeth.
            return
        }

        // IT DID NOT REFUSE -- so it carrieth a PRIVATE store, and THAT store must not admit an unkeyed reader.
        let rc = unkeyedPrepare(messageURL)
        XCTAssertNotEqual(rc, SQLITE_OK,
                          "*** AN UNKEYED sqlite3 PREPARED A STATEMENT AGAINST THE COMPOSITION'S PRIVATE STORE "
                          + "(rc=\(rc)): ORDINARY SQLITE MAY NEVER BE A PRIVATE STORE (GS-STORE-002) ***")
    }

    /// W05 -- *** THE VALID POSITIVE CONTROL: THE REFUSAL IS TARGETED, NOT A WALL. ***
    ///
    /// W04 accepteth a refusal as one of its two lawful outcomes -- SO AN IMPLEMENTATION THAT REFUSED **EVERY**
    /// COMPOSITION WOULD SATISFY IT WHILE BEING USELESS: a refusal that answereth everything is not a law, it is an
    /// outage. This arm therefore composes WITH a verifying factory and requireth that the composition STAND, and
    /// that THE DEK'S OWNER reach it -- `wipeKeyProvider` is the factory's own key provider, the one verb of which
    /// eraseth the wrapping key.
    ///
    /// ITS SCOPE IS STATED SO IT CANNOT BE OVERREAD: the engine below ANSWERETH ON ITS OWN WORD. It is a control for
    /// the SHAPE of the decision, NOT evidence that any store is encrypted -- that needeth the real SQLCipher
    /// artifact, which is an EXTERNAL input, and this round doth not have it and doth not claim it.
    func testW05TheRefusalIsTargetedAndAKeyedCompositionStillStands() throws {
        let dir = try privateDir("gs-store-002-keyed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = VerifyingProvider()
        // reopenExisting minteth NOTHING (no create-on-reopen), so a first install minteth both DEKs -- which is what
        // the real composition doth and what a caller must do before reopening.
        _ = try provider.createDEK(tag: "message-store")
        _ = try provider.createDEK(tag: "peer-identity-store")
        let factory = EncryptedStoreFactory(provider: provider, engine: VerifyingEngine())

        let runtime = try MeshRuntime.create(
            messageStoreUrl: dir.appendingPathComponent("m.db"),
            peerStoreUrl: dir.appendingPathComponent("p.db"),
            journal: InMemoryJournal(), keychain: InMemoryKeychain(),
            encryptedStores: factory)
        _ = runtime
        XCTAssertGreaterThanOrEqual(provider.fetchCount, 2,
                        "the composition must STAND with a verifying factory AND ASK it for BOTH stores' DEKs -- else "
                        + "the refusal were a wall that answereth everything, which is not a law but an outage")
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

    private func runtimeSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/MeshRuntime.swift"), encoding: .utf8)
    }

    private func factorySource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/EncryptedStoreFactory.swift"), encoding: .utf8)
    }

    // ================================================================ GS-STORE-002 STEP 5: DB/WAL/SHM AND DIRECTORIES

    /**
     * *** GS-STORE-002 STEP 5: *'Apply complete file protection to created **DB/WAL/SHM AND DIRECTORIES** as
     * required, propagate errors, and retain the locked-device policy.'* ***
     *
     * MEASURED BEFORE THE REPAIR: BOTH protection call sites passed `paths: [path]` -- **THE MAIN DATABASE FILE
     * ALONE.** In WAL mode the `-wal` and `-shm` sidecars hold the very rows the main file lacks, and **AN
     * UNPROTECTED SIDECAR IS AN UNPROTECTED STORE** whatever protection the main file carries; the containing
     * DIRECTORY governs what may be created beside it.
     *
     * *** AND THE INSTRUMENT IS CHOSEN FOR WHAT IS HOST-OBSERVABLE RATHER THAN FOR WHAT IS NOT: the host cannot
     * apply a real Data-Protection class -- measured, the provider answers `.success` unconditionally off-iOS -- SO
     * THIS ARM MEASURES THE **SET OF PATHS THE FACTORY ASKS FOR**, WHICH IS EXACTLY THE CLAUSE THE REPAIR CHANGED.
     * *** A path that is never named is never protected, and a set is a measurement where a class is not.
     */
    func testGSSTORE002_theProtectionSetCarriesTheSidecarsAndTheDirectory() {
        let factory = EncryptedStoreFactory(provider: VerifyingProvider(), engine: VerifyingEngine())
        let paths = factory.protectionPaths(forStoreAt: "/tmp/godstone/store.sqlite")

        XCTAssertTrue(paths.contains("/tmp/godstone/store.sqlite"), "the main file must be protected")
        XCTAssertTrue(paths.contains("/tmp/godstone/store.sqlite-wal"),
                      "*** THE WAL SIDECAR MUST BE PROTECTED: it holds the very rows the main file lacks, so an "
                      + "unprotected `-wal` is an unprotected store (GS-STORE-002 step 5) ***")
        XCTAssertTrue(paths.contains("/tmp/godstone/store.sqlite-shm"),
                      "*** AND THE SHM SIDECAR, likewise (GS-STORE-002 step 5) ***")
        XCTAssertTrue(paths.contains("/tmp/godstone"),
                      "*** AND THE CONTAINING DIRECTORY: it governs what may be created beside the store "
                      + "(GS-STORE-002 step 5) ***")
    }
    // ================================================================================================
    // *** GS-FINAL-004 CLAUSE (c): TYPED OPEN ERRORS RATHER THAN A NOMINAL STORE WITH A NIL HANDLE. ***
    //
    // THE CARD'S OWN WORDS: *"Return typed open errors instead of a nominal store with a nil handle."* **AND THE
    // MEASURED GAP WAS EXACTLY THAT AND NOTHING MORE:** `SqliteMessageStore.init(url:maxBytes:fileProtection:)` is
    // **NON-FAILABLE**, and on a failed `sqlite3_open_v2` or a failed migration it setteth `handle = nil` and
    // **RETURNS A STORE THAT LOOKS LIKE ANY OTHER**. Every operation on it then fails closed -- *which is the right
    // runtime behaviour* -- **BUT NO CALLER CAN ASK WHETHER IT OPENED, OR WHY IT DID NOT.** *A caller that cannot
    // distinguish "ready" from "never opened" cannot decide anything; it can only discover the truth one failed
    // operation at a time.*
    //
    // *** THIS CLAUSE NEEDED NO SQLCIPHER BINDING, WHICH IS WHY IT IS THE ONE TAKEN: the open path, the migration
    // path and the handle are ALL in this repository already; what was missing was a WORD for the outcome. ***
    // ================================================================================================

    /** *** AN OPEN STORE REPORTETH ITSELF OPEN, AND NAMES NO FAULT. *** (The positive control.) */
    func testGFFinal004AnOpenedStoreReportethItselfOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf004_open_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)
        XCTAssertEqual(
            store.openOutcome, .opened,
            "*** A STORE THAT OPENED MUST SAY SO -- otherwise the typed outcome is a constant and the whole clause " +
                "is decoration. Observed: \(store.openOutcome) ***")
    }

    /** *** A STORE THAT COULD NOT OPEN REPORTETH A TYPED FAULT RATHER THAN SILENCE. *** */
    func testGFFinal004AnUnopenableStoreReportethATypedFault() throws {
        // A path whose PARENT is a FILE, not a directory: `createDirectory` fails and `sqlite3_open_v2` cannot
        // create the database. **THIS IS A REAL FAILURE MODE AND NOT A SYNTHETIC ONE** -- the store's own
        // `try? FileManager.default.createDirectory(...)` swalloweth the first error, which is precisely why the
        // caller needs a typed answer at the end.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf004_blocker_\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let url = blocker.appendingPathComponent("nested").appendingPathComponent("store.db")

        let store = SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)

        XCTAssertNotEqual(
            store.openOutcome, .opened,
            "*** A STORE THAT COULD NOT OPEN MUST NOT REPORT ITSELF OPEN. Observed: \(store.openOutcome) ***")
        guard case .failed(let fault) = store.openOutcome else {
            XCTFail("*** THE OUTCOME MUST CARRY A TYPED FAULT, NOT A BARE BOOLEAN -- the card asketh for TYPED OPEN " +
                "ERRORS so a caller can tell an unopenable FILE from a refused SCHEMA. Observed: \(store.openOutcome) ***")
            return
        }
        XCTAssertFalse(
            fault.description.isEmpty,
            "*** AND THE FAULT MUST NAME ITSELF: an empty reason is the nil-handle silence with a new type around it. " +
                "Observed: \(fault) ***")
    }

}
