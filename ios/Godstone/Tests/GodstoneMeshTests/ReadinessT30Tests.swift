import XCTest
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T30 - the CANONICAL designated regression court, iOS side. The manifest
// required_regression_paths names this file; the narrow filter is
// `swift test --package-path ios/Packages/GodstoneFoundation --filter ReadinessT30Tests`.
// It drives the T30 private-store-encryption decision layers through deterministic
// fakes for the three injected seams -- the Keychain [PrivateStoreKeyProvider], the
// [EncryptedStoreEngine] (the SQLCipher binding), and the [PlaintextMigrationEngine] +
// [WipeRuntimeGate] -- so every required_behavioral_case is EXECUTED, not narrated:
//   * wrong DEK                 -> factory .locked, never an empty healthy store;
//   * Keychain unavailable      -> factory .unavailable, never a usable store;
//   * locked device             -> factory .unavailable (locked-device behaviour not weakened);
//   * encryption-at-rest proof  -> an opened handle must assert encryptedAtRest on the pinned
//                                  engine or it is REJECTED (.locked) -- the at-rest guarantee;
//   * no fallback plain SQLite  -> a plainSQLite engine is refused (.unavailable);
//   * failed migration preserves a recoverable source -> verify-before-select, and any fault
//                                  before the atomic swap leaves the source intact;
//   * reopen WITHOUT the DEK    -> .unavailable, never a silently-empty healthy store
//                                  (the required_semantic_negative half: ignore protection /
//                                  reopen-without-DEK must fail, and here it does);
//   * the public read-only Archive stays separate -> migration skips it, never encrypts it.
// The concrete SQLCipher binding and the real Keychain/Data-Protection are device
// evidence (deferred to the device gate); the host proves the SAME decision laws.
// ---------------------------------------------------------------------------

// ---- deterministic fakes for the three seams --------------------------------
private func testDEKBytes() -> Data { Data((0..<32).map { UInt8($0 & 0xff) }) }
private enum MigrationTestFault: Error { case unverifiedSelect }

private final class FakeKeychain: PrivateStoreKeyProvider, @unchecked Sendable {
    var stored: [String: StoreDEK] = [:]
    var dekByteCount: Int { 32 }
    var failFetch: StoreKeyError?
    var failCreate: StoreKeyError?
    var failDelete: StoreKeyError?
    var protectionResult: ProtectionResult = .success
    var fetchCalls = 0
    var createCalls = 0
    var deleteCalls = 0
    var protectionCalls = 0
    func fetchDEK(tag: String) throws -> StoreDEK {
        fetchCalls += 1
        if let f = failFetch { throw f }
        guard let d = stored[tag] else { throw StoreKeyError.dekNotFound }
        return d
    }
    func createDEK(tag: String) throws -> StoreDEK {
        createCalls += 1
        if let f = failCreate { throw f }
        let d = StoreDEK(bytes: testDEKBytes())
        stored[tag] = d
        return d
    }
    func deleteDEK(tag: String) throws {
        deleteCalls += 1
        if let f = failDelete { throw f }
        stored[tag] = nil
    }
    func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult {
        protectionCalls += 1
        return protectionResult
    }
}

private final class FakeEngine: EncryptedStoreEngine, @unchecked Sendable {
    var kind: StoreEngineKind
    var supportedCipherVersion: Int
    var throwOpen: Error?
    var throwReopen: Error?
    var assertEncrypted = true           // the handle the engine reports
    var openCalls = 0
    var reopenCalls = 0
    init(kind: StoreEngineKind = .pinnedSQLCipher, cipherVersion: Int = 4) { self.kind = kind; self.supportedCipherVersion = cipherVersion }
    func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
        openCalls += 1
        if let t = throwOpen { throw t }
        return EncryptedStoreHandle(path: path, kind: kind, encryptedAtRest: assertEncrypted, cipherVersion: supportedCipherVersion)
    }
    func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
        reopenCalls += 1
        if let t = throwReopen { throw t }
        return EncryptedStoreHandle(path: path, kind: kind, encryptedAtRest: assertEncrypted, cipherVersion: supportedCipherVersion)
    }
}

private final class FakeMigrationEngine: PlaintextMigrationEngine, @unchecked Sendable {
    var requires: Bool = true
    var rows: Int = 7
    var verification: MigrationVerification = MigrationVerification(rowCountMatched: true, headerOk: true, cipherVersionMatched: true)
    var throwRequires: Error?
    var throwRows: Error?
    var throwPrepare: Error?
    var throwVerify: Error?
    var throwSelect: Error?
    var sourcePresent = true
    var prepareCalls = 0
    var verifyCalls = 0
    var selectCalls = 0
    var order: [String] = []
    func sourceRequiresMigration(path: String) throws -> Bool { if let t = throwRequires { throw t }; return requires }
    func expectedRowCount(plaintextPath: String) throws -> Int { if let t = throwRows { throw t }; return rows }
    func prepareEncryptedCopy(plaintextPath: String, encryptedPath: String, dek: StoreDEK) throws {
        if let t = throwPrepare { throw t }
        prepareCalls += 1; order.append("prepare")
    }
    func verifyEncryptedCopy(encryptedPath: String, dek: StoreDEK, expectedRowCount: Int) throws -> MigrationVerification {
        if let t = throwVerify { throw t }
        verifyCalls += 1; order.append("verify")
        return verification
    }
    func selectEncryptedCopy(plaintextPath: String, encryptedPath: String) throws {
        if let t = throwSelect { throw t }
        if verifyCalls == 0 { throw MigrationTestFault.unverifiedSelect }   // refuse to select an unverified copy
        selectCalls += 1; order.append("select"); sourcePresent = false
    }
}

private final class FakeGate: WipeRuntimeGate, @unchecked Sendable {
    var permits = true
    var calls = 0
    func allowsStoreMigration() -> Bool { calls += 1; return permits }
}

final class ReadinessT30Tests: XCTestCase {
    private let tag = "store-message"

    private func dek(_ kc: FakeKeychain, _ t: String) { kc.stored[t] = StoreDEK(bytes: testDEKBytes()) }
    private func pair(_ kc: FakeKeychain, _ e: FakeEngine) -> EncryptedStoreFactory { EncryptedStoreFactory(provider: kc, engine: e) }

    // (1) happy path: an encrypted store opens .available via the pinned SQLCipher engine
    func testEncryptedStoreOpensAvailableViaPinnedSQLCipher() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let e = FakeEngine(kind: .pinnedSQLCipher)
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag)
        XCTAssertTrue(r.isAvailable, "a genuine encrypted store opens Available")
        guard case .available(let h) = r else { XCTAssert(false, "expected .available, got \(r)"); return }
        XCTAssertTrue(h.encryptedAtRest); XCTAssertEqual(h.kind, .pinnedSQLCipher)
    }

    // (2) wrong DEK -> .locked, never an empty healthy store
    func testWrongDEKYieldsLockedNeverEmptyHealthyStore() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let e = FakeEngine(); e.throwOpen = StoreOpenFault.wrongKey
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag)
        XCTAssertEqual(r, .locked, "a wrong-key open is Locked")
        XCTAssertFalse(r.isAvailable, "a wrong-key open must never surface an empty healthy store")
    }

    // (3) Keychain unavailable -> .unavailable, never a usable store
    func testKeychainUnavailableIsFailClosed() throws {
        let kc = FakeKeychain(); kc.failFetch = .keychainUnavailable
        let r = pair(kc, FakeEngine()).openStore(path: "/var/db/msg", tag: tag)
        XCTAssertEqual(r, .unavailable)
        XCTAssertFalse(r.isAvailable)
    }

    // (4) locked device -> .unavailable (locked-device behaviour not weakened for availability)
    func testLockedDeviceIsFailClosedNotWeakened() throws {
        let kc = FakeKeychain(); kc.failFetch = .deviceLocked
        let r = pair(kc, FakeEngine()).openStore(path: "/var/db/msg", tag: tag)
        XCTAssertEqual(r, .unavailable, "a locked device must fail closed, not open a weaker store")
        XCTAssertFalse(r.isAvailable)
    }

    // (5) encryption-at-rest proof: an opened handle that does not assert encryptedAtRest is REJECTED
    func testOpenedHandleMustAssertEncryptedAtRestElseRejected() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let e = FakeEngine(); e.assertEncrypted = false            // the engine lies about at-rest encryption
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag)
        XCTAssertFalse(r.isAvailable, "a store that does not assert encrypted-at-rest is never accepted")
        XCTAssertEqual(r, .locked)
    }

    // (6) no fallback plain SQLite: a plain engine is refused outright
    func testNoFallbackToPlainSQLiteEngine() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let e = FakeEngine(kind: .plainSQLite)
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag)
        XCTAssertEqual(r, .unavailable, "a plain SQLite engine is never the encrypted store path")
        XCTAssertEqual(e.openCalls, 0, "the plain engine must not even be asked to open")
    }

    // (7) reopen WITHOUT the DEK must fail (required_semantic_negative half)
    func testReopenWithoutDEKIsRejectedNeverEmptyHealthy() throws {
        let kc = FakeKeychain()                                      // Keychain has NO DEK for the tag
        let r = pair(kc, FakeEngine()).reopenExisting(path: "/var/db/msg", tag: tag)
        XCTAssertFalse(r.isAvailable, "reopening without the DEK must never yield a healthy store")
        XCTAssertEqual(r, .unavailable)
    }

    // (7b) ignore-protection-failure must fail (required_semantic_negative half)
    func testProtectionFailureIsNeverSwallowed() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        kc.protectionResult = .failure(.protectionFailure(status: -1, operation: "setAttributes"))
        let r = pair(kc, FakeEngine()).openStore(path: "/var/db/msg", tag: tag)
        XCTAssertFalse(r.isAvailable, "a failed file-protection apply must not be swallowed to a usable store")
        XCTAssertEqual(r, .unavailable)
        XCTAssertGreaterThanOrEqual(kc.protectionCalls, 1)
    }

    // (7c) ignore-protection-failure on the REOPEN path must also fail (drives the reopen protection guard)
    func testReopenProtectionFailureIsNeverSwallowed() throws {
        let kc = FakeKeychain(); dek(kc, tag)                 // DEK present -> fetch succeeds on reopen
        kc.protectionResult = .failure(.protectionFailure(status: -1, operation: "setAttributes"))
        let r = pair(kc, FakeEngine()).reopenExisting(path: "/var/db/msg", tag: tag)
        XCTAssertFalse(r.isAvailable, "a failed file-protection apply on reopen must not be swallowed to a usable store")
        XCTAssertEqual(r, .unavailable)
        XCTAssertGreaterThanOrEqual(kc.protectionCalls, 1)
    }

    // (8) failed migration preserves a recoverable source; verify runs BEFORE select
    func testFailedMigrationPreservesRecoverableSource() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let me = FakeMigrationEngine(); me.verification = MigrationVerification(rowCountMatched: false, headerOk: true, cipherVersionMatched: true)  // mismatch
        let gate = FakeGate()
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: gate, cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/plain", encryptedPath: "/var/db/enc", tag: tag)
        XCTAssertEqual(out, .sourcePreservedOnFailure(.verificationMismatch))
        XCTAssertTrue(out.sourcePreserved)
        XCTAssertEqual(me.selectCalls, 0, "an unverified copy must NEVER be selected")
        XCTAssertTrue(me.sourcePresent, "the original source is preserved recoverable")
        XCTAssertEqual(me.verifyCalls, 1)
        XCTAssertGreaterThanOrEqual(gate.calls, 1)
    }

    // (9) happy migration: verified good copy is selected; order is prepare->verify->select
    func testSuccessfulMigrationVerifiesBeforeSelecting() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let me = FakeMigrationEngine()
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: FakeGate(), cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/plain", encryptedPath: "/var/db/enc", tag: tag)
        XCTAssertEqual(out, .migrated(verifiedRows: 7))
        XCTAssertTrue(out.didMigrate)
        XCTAssertEqual(me.order, ["prepare", "verify", "select"], "the encrypted copy is verified BEFORE it is selected")
    }

    // (10) the wipe/runtime gate refuses without touching disk
    func testClosedGateRefusesMigrationWithoutTouchingDisk() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let me = FakeMigrationEngine()
        let gate = FakeGate(); gate.permits = false
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: gate, cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/plain", encryptedPath: "/var/db/enc", tag: tag)
        XCTAssertEqual(out, .refusedByGate)
        XCTAssertEqual(me.prepareCalls, 0); XCTAssertEqual(me.verifyCalls, 0); XCTAssertEqual(me.selectCalls, 0)
        XCTAssertTrue(me.sourcePresent, "a refused migration leaves the source on disk untouched")
    }

    // (11) the public read-only Archive stays separate -- never migrated or encrypted
    func testArchiveIsSkippedAndStaysSeparate() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let me = FakeMigrationEngine()
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: FakeGate(), cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/archive", encryptedPath: "/var/db/archive.enc", tag: "archive", isArchive: true)
        XCTAssertEqual(out, .archiveSkipped, "the Archive is never a migration subject")
        XCTAssertEqual(me.prepareCalls, 0); XCTAssertEqual(me.selectCalls, 0)
        XCTAssertEqual(kc.protectionCalls, 0, "the Archive is not given private-store protection")
        XCTAssertEqual(kc.createCalls, 0, "no DEK is minted for the Archive")
    }

    // (12) first-install migration mints the DEK once (fetch NotFound -> create)
    func testFirstInstallMigrationMintsDEKOnce() throws {
        let kc = FakeKeychain()                                      // no DEK yet
        let me = FakeMigrationEngine()
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: FakeGate(), cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/plain", encryptedPath: "/var/db/enc", tag: tag)
        XCTAssertTrue(out.didMigrate)
        XCTAssertEqual(kc.fetchCalls, 1)
        XCTAssertEqual(kc.createCalls, 1, "a missing DEK is minted once on first migration")
        XCTAssertEqual(me.selectCalls, 1)
    }

    // (13) erasing the DEK cryptographically erases the store: a reopen afterwards is rejected
    func testEraseDEKMakesStoresNonReopenable() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let f = pair(kc, FakeEngine())
        XCTAssertTrue(f.reopenExisting(path: "/var/db/msg", tag: tag).isAvailable)
        try kc.deleteDEK(tag: tag)                                   // panic-wipe / erasure path
        let r = f.reopenExisting(path: "/var/db/msg", tag: tag)
        XCTAssertFalse(r.isAvailable, "after the DEK is destroyed the encrypted store must not be reopenable")
        XCTAssertEqual(r, .unavailable)
    }
}
