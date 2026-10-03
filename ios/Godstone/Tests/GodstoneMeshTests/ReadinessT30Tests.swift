import XCTest
@testable import GodstoneMesh
import SQLite3

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
    /// *** A PER-INSTANCE KEY DOMAIN (the sealed-lease convention). *** *The capability alias IS the physical-key
    /// authority's identity, so a SHARED domain would let the process-global alias registry merge this arm's estate
    /// with another's -- the cross-test merge that made `beginConstruction` refuse (the 107-consumer probe's
    /// `startupRefusedByRecovery(permit_refused)`). A per-instance domain keepeth every arm its own owner set.*
    private let domain = "test.t30.\(UUID().uuidString)"
    var physicalKeyDomain: String { domain }
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
    /// *** A TORN SWAP: the retirement happens and THEN the operation fails. *** The real atomic-rename seam can
    /// die between "the encrypted copy is adopted" and "the plaintext is unlinked", and a fake that only ever threw
    /// BEFORE the retirement could not model the one case where a rollback claim is unsupported.
    var retireSourceThenThrow: Error?
    /// Counts the source-presence OBSERVATIONS, so an arm can prove the outcome's claim was MEASURED rather than
    /// assumed. A claim that is never observed is the defect this court now pins.
    var sourcePresenceCalls = 0
    func sourceIsPresent(plaintextPath: String) throws -> Bool {
        sourcePresenceCalls += 1
        return sourcePresent
    }
    func selectEncryptedCopy(plaintextPath: String, encryptedPath: String) throws {
        if let t = throwSelect { throw t }
        if verifyCalls == 0 { throw MigrationTestFault.unverifiedSelect }   // refuse to select an unverified copy
        selectCalls += 1; order.append("select")
        if let torn = retireSourceThenThrow { sourcePresent = false; throw torn }   // the swap began and died
        sourcePresent = false
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
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag,
                                      scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertTrue(r.isAvailable, "a genuine encrypted store opens Available")
        guard case .available(let h) = r else { XCTAssert(false, "expected .available, got \(r)"); return }
        XCTAssertTrue(h.encryptedAtRest); XCTAssertEqual(h.kind, .pinnedSQLCipher)
    }

    // (2) wrong DEK -> .locked, never an empty healthy store
    func testWrongDEKYieldsLockedNeverEmptyHealthyStore() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let e = FakeEngine(); e.throwOpen = StoreOpenFault.wrongKey
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag,
                                      scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertEqual(r, .locked, "a wrong-key open is Locked")
        XCTAssertFalse(r.isAvailable, "a wrong-key open must never surface an empty healthy store")
    }

    // (3) Keychain unavailable -> .unavailable, never a usable store
    func testKeychainUnavailableIsFailClosed() throws {
        let kc = FakeKeychain(); kc.failFetch = .keychainUnavailable
        let r = pair(kc, FakeEngine()).openStore(path: "/var/db/msg", tag: tag,
                                                scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertEqual(r, .unavailable)
        XCTAssertFalse(r.isAvailable)
    }

    // (4) locked device -> .unavailable (locked-device behaviour not weakened for availability)
    func testLockedDeviceIsFailClosedNotWeakened() throws {
        let kc = FakeKeychain(); kc.failFetch = .deviceLocked
        let r = pair(kc, FakeEngine()).openStore(path: "/var/db/msg", tag: tag,
                                                scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertEqual(r, .unavailable, "a locked device must fail closed, not open a weaker store")
        XCTAssertFalse(r.isAvailable)
    }

    // (5) encryption-at-rest proof: an opened handle that does not assert encryptedAtRest is REJECTED
    func testOpenedHandleMustAssertEncryptedAtRestElseRejected() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let e = FakeEngine(); e.assertEncrypted = false            // the engine lies about at-rest encryption
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag,
                                      scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertFalse(r.isAvailable, "a store that does not assert encrypted-at-rest is never accepted")
        XCTAssertEqual(r, .locked)
    }

    // (6) no fallback plain SQLite: a plain engine is refused outright
    func testNoFallbackToPlainSQLiteEngine() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let e = FakeEngine(kind: .plainSQLite)
        let r = pair(kc, e).openStore(path: "/var/db/msg", tag: tag,
                                      scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertEqual(r, .unavailable, "a plain SQLite engine is never the encrypted store path")
        XCTAssertEqual(e.openCalls, 0, "the plain engine must not even be asked to open")
    }

    // (7) reopen WITHOUT the DEK must fail (required_semantic_negative half)
    func testReopenWithoutDEKIsRejectedNeverEmptyHealthy() throws {
        let kc = FakeKeychain()                                      // Keychain has NO DEK for the tag
        let r = pair(kc, FakeEngine()).reopenExisting(path: "/var/db/msg", tag: tag,
                                                    scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertFalse(r.isAvailable, "reopening without the DEK must never yield a healthy store")
        XCTAssertEqual(r, .unavailable)
    }

    // (7b) ignore-protection-failure must fail (required_semantic_negative half)
    func testProtectionFailureIsNeverSwallowed() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        kc.protectionResult = .failure(.protectionFailure(status: -1, operation: "setAttributes"))
        let r = pair(kc, FakeEngine()).openStore(path: "/var/db/msg", tag: tag,
                                                scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertFalse(r.isAvailable, "a failed file-protection apply must not be swallowed to a usable store")
        XCTAssertEqual(r, .unavailable)
        XCTAssertGreaterThanOrEqual(kc.protectionCalls, 1)
    }

    // (7c) ignore-protection-failure on the REOPEN path must also fail (drives the reopen protection guard)
    func testReopenProtectionFailureIsNeverSwallowed() throws {
        let kc = FakeKeychain(); dek(kc, tag)                 // DEK present -> fetch succeeds on reopen
        kc.protectionResult = .failure(.protectionFailure(status: -1, operation: "setAttributes"))
        let r = pair(kc, FakeEngine()).reopenExisting(path: "/var/db/msg", tag: tag,
                                                    scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
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

    // (14) *** GS-FINAL-004 CLAUSE (d): A TORN SWAP MUST NOT CLAIM A PRESERVED SOURCE. ***
    //
    // THE CARD'S SENTENCE IS "...AS A SEPARATE RESUMABLE OPERATION WITH PRESERVED ROLLBACK EVIDENCE". **ROLLBACK
    // EVIDENCE THAT IS ASSERTED RATHER THAN OBSERVED IS NOT EVIDENCE.** The migration retires the plaintext during
    // `selectEncryptedCopy`, and THE REAL ATOMIC SWAP CAN DIE AFTER THE ADOPTION AND BEFORE THE UNLINK -- at which
    // point THE SOURCE IS GONE AND `.sourcePreservedOnFailure` IS A FALSE CLAIM. The old fake could not model this
    // because it only ever threw BEFORE the retirement.
    func testTornSwapNeverClaimsAPreservedSource() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let me = FakeMigrationEngine()
        me.retireSourceThenThrow = MigrationTestFault.unverifiedSelect      // the swap began and died
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: FakeGate(), cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/plain", encryptedPath: "/var/db/enc", tag: tag)
        XCTAssertFalse(me.sourcePresent, "the precondition: the torn swap really did retire the source")
        XCTAssertFalse(
            out.sourcePreserved,
            "*** A TORN SWAP MUST NOT CLAIM A PRESERVED SOURCE -- the source is GONE, so any outcome asserting it "
                + "survives is a rollback claim the mechanism cannot support. Observed outcome: \(out) ***")
        XCTAssertFalse(out.didMigrate, "and it must NOT report a completed migration")
    }

    // (15) POSITIVE CONTROL for (14): a PRE-swap failure still reports a preserved source -- AND THE CLAIM IS OBSERVED.
    //
    // Without this arm, (14) could be satisfied by an outcome that simply never claims preservation, which would be a
    // worse bug (a real recoverable source reported as lost). AND the second assertion is the one that makes the pair
    // mean something: **the true/false must come from ASKING the engine, not from a default.**
    func testPreSwapFailureClaimsPreservedSourceOnlyAfterObservingIt() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let me = FakeMigrationEngine()
        me.throwPrepare = MigrationTestFault.unverifiedSelect                  // dies BEFORE the swap
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: FakeGate(), cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/plain", encryptedPath: "/var/db/enc", tag: tag)
        XCTAssertTrue(me.sourcePresent, "the precondition: the source really is still on disk")
        XCTAssertTrue(out.sourcePreserved, "a pre-swap failure preserves the recoverable source")
        XCTAssertEqual(me.selectCalls, 0, "nothing was ever selected")
        XCTAssertGreaterThanOrEqual(
            me.sourcePresenceCalls, 1,
            "*** THE CLAIM MUST BE MEASURED: the outcome may only say the source survives because the SOURCE WAS "
                + "OBSERVED. A preservation claim derived from the failure's POSITION is an assumption, and this "
                + "programme has already paid for counting what should be measured. ***")
    }

    // (16) THE RESUME'S NO-OP STATE: a source that no longer needs migration is reported as such, and NOTHING is touched.
    //
    // NOTE, SO THIS ARM IS NOT OVERREAD: it passes on the pre-repair revision too, because `.alreadyEncrypted` is a
    // pre-existing branch. **IT WITNESSES AN UNEXERCISED BRANCH, NOT THE REPAIR** -- and it is the state a RESUMED
    // operation depends on, which is why clause (d) needs it named. Previously no arm ever set `requires = false`, so
    // the branch had never executed in this court.
    func testAResumedRunOnAnAlreadyEncryptedSourceIsANoOp() throws {
        let kc = FakeKeychain()                                               // no DEK: a resume must not need one
        let me = FakeMigrationEngine(); me.requires = false
        let m = PlaintextToEncryptedMigration(engine: me, provider: kc, gate: FakeGate(), cipherVersion: 4)
        let out = m.migrate(plaintextPath: "/var/db/plain", encryptedPath: "/var/db/enc", tag: tag)
        XCTAssertEqual(out, .alreadyEncrypted, "an already-encrypted source is the resume's terminal no-op")
        XCTAssertEqual(me.prepareCalls, 0); XCTAssertEqual(me.verifyCalls, 0); XCTAssertEqual(me.selectCalls, 0)
        XCTAssertEqual(kc.createCalls, 0, "a resume mints no DEK")
        XCTAssertTrue(me.sourcePresent)
    }

    // (13) erasing the DEK cryptographically erases the store: a reopen afterwards is rejected
    func testEraseDEKMakesStoresNonReopenable() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let f = pair(kc, FakeEngine())
        XCTAssertTrue(f.reopenExisting(path: "/var/db/msg", tag: tag,
                      scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain)).isAvailable)
        try kc.deleteDEK(tag: tag)                                   // panic-wipe / erasure path
        let r = f.reopenExisting(path: "/var/db/msg", tag: tag,
                               scope: try t30Scope(msgPath: "/var/db/msg", tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertFalse(r.isAvailable, "after the DEK is destroyed the encrypted store must not be reopenable")
        XCTAssertEqual(r, .unavailable)
    }

    // ==========================================================================================================
    // *** GS-STORE-002 / GS-FINAL-004 `native-engine-half`: THE REAL ENGINE ADAPTER, FAILING CLOSED. ***
    //
    // *THE FINDING'S OWN REMEDIATION STEP: "Implement EncryptedStoreEngine using native SQLCipher open, key
    // application before schema reads, and a verified cipher version/configuration."* **BEFORE THIS FILE THE TREE
    // HAD NO PRODUCTION IMPLEMENTOR AT ALL** -- only courts' fakes -- so the factory answered `.engineUnavailable`
    // for every real composition. These arms measure the adapter's OWN behaviour: what it reporteth when the pinned
    // library is absent, and that it never claims at-rest through an unbound engine.
    //
    // *** AND THE POSITIVE PATH IS GATED ON THE PINNED BINARY'S PRESENCE, HONESTLY. *** *The pinned artifact, its
    // approval and the device at-rest bytes are the EXTERNAL half (`gs-store-002.sqlcipher-engine`), which this
    // builder may not write. So the arms below assert the fail-closed direction UNCONDITIONALLY, and assert the
    // positive direction only when a real library is on the host.*
    // ==========================================================================================================

    /// *The adapter bound to a name that cannot exist, so `dlopen` really fails on every host.*
    private func unboundEngine() -> SqlCipherDylibEngine {
        SqlCipherDylibEngine(libraryPath: "libsqlcipher-DOES-NOT-EXIST-\(UUID().uuidString).dylib")
    }

    // (14) an absent pinned library is NOT an engine: the kind refuseth, so the factory never opens plaintext
    func testTheDylibEngineReportethPlainWhenThePinnedLibraryIsAbsent() throws {
        let e = unboundEngine()
        XCTAssertFalse(e.isBound, "the rig must not be bound, or this arm measures the wrong direction")
        XCTAssertEqual(
            e.kind, .plainSQLite,
            "*** AN ENGINE THAT DID NOT BIND MUST NOT CLAIM `.pinnedSQLCipher`. *The factory refuses a plain "
                + "engine outright ('no plaintext fallback, ever'), so this single property is the FIRST fail-closed "
                + "gate -- and an unconditional `.pinnedSQLCipher` would make every refusal arm below vacuous.* ***",
        )
        XCTAssertNotNil(e.bindingFailureReason, "the refusal must be NAMED, not merely true")
    }

    /// *** (14b) A BOUND ARBITRARY-PATH LIBRARY IS NOT THE PINNED ENGINE -- AND `kind` MUST SAY SO. ***
    ///
    /// *T72-RC17: the previous arm bound only a NAME THAT CANNOT EXIST, so it exercised the ABSENT branch and never
    /// the ARBITRARY-PATH branch -- and the mutation `isBound ? .pinnedSQLCipher : .plainSQLite` (which drops
    /// `isArbitraryPath`) stayed green against it. This arm binds the REAL staged pinned dylib through the
    /// ARBITRARY-PATH constructor (`claimPinned: false`), so `isBound` is TRUE while the path is NOT the canonical
    /// one: `kind` must be `.plainSQLite`, else a dylib loaded from any path would claim pinned SQLCipher and the
    /// factory's 'no plaintext fallback' gate would be satisfied by a lie.* **The image is the lane's mandatory,
    /// repository-built pinned dylib -- a missing stage is a COURT/SYSTEM failure (XCTFail), never a skip. No fake
    /// symbol and no mock: the SAME bytes the production constructor verifies are loaded through the arbitrary-path
    /// door the mutation leaves open.***
    func testTheArbitraryPathLibraryIsBoundYetNeverClaimsPinned() throws {
        // THE STAGED PINNED IMAGE, resolved by the same searches as the production loader (env, test bundle,
        // main bundle, lane fallback). XCTest's device process inheriteth no lane environment, so requiring the
        // env name alone would turn a correctly staged bundle into a false supply failure.
        var searchDirs: [String] = []
        if let envDir = ProcessInfo.processInfo.environment["GODSTONE_SQLCIPHER_ARTIFACT_DIR"], !envDir.isEmpty {
            searchDirs.append(envDir)
        }
        if let frameworks = Bundle(for: SqlCipherDylibEngine.self).privateFrameworksPath { searchDirs.append(frameworks) }
        if let mainFrameworks = Bundle.main.privateFrameworksPath { searchDirs.append(mainFrameworks) }
        #if targetEnvironment(simulator)
        searchDirs.append("/tmp/sqlcipher-sim")
        #else
        searchDirs.append("/tmp/sqlcipher-macos")
        #endif
        guard let stage = searchDirs.first(where: { dir in
            FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(SQLCipherPin.libraryName),
                                          isDirectory: nil)
        }) else {
            XCTFail("*** MANDATORY NATIVE LANE 't30 arbitrary-path': '\(SQLCipherPin.libraryName)' was found in "
                    + "none of the loader's search roots \(searchDirs). The pinned image is repository-built: run "
                    + "tools/supplychain/build_sqlcipher_simulator.sh and stage it where the loader searches. ***")
            return
        }
        let image = (stage as NSString).appendingPathComponent(SQLCipherPin.libraryName)

        // (1) THE ARBITRARY-PATH BIND: the real dylib, loaded from a NON-CANONICAL path (claimPinned stays false).
        let arbitrary = SqlCipherDylibEngine(libraryPath: image)
        XCTAssertTrue(
            arbitrary.isBound,
            "*** THE REAL PINNED BYTES MUST LOAD, or this arm measureth the absent branch it existeth to "
                + "distinguish: \(arbitrary.bindingFailureReason ?? "unknown") ***",
        )
        XCTAssertEqual(
            arbitrary.kind, .plainSQLite,
            "*** A LIBRARY BOUND AT AN ARBITRARY PATH MUST NOT CLAIM `.pinnedSQLCipher`. *`kind` is the factory's "
                + "FIRST fail-closed gate; if it returned pinned for any bound path, a dylib loaded from anywhere "
                + "would satisfy it and the private stores could open outside the verified, canonical image. The "
                + "mutation that drops `isArbitraryPath` makes THIS assertion red.* ***",
        )
        XCTAssertNil(arbitrary.bindingFailureReason, "the bind itself succeeded -- the refusal is the CLAIM, not the load")

        // (2) THE HEALTHY OPPOSITE: the canonical constructor on the same staged bytes claims `.pinnedSQLCipher`,
        // so the arm proveth the discriminator rather than a `kind` that answers `plainSQLite` unconditionally.
        let canonical = SqlCipherDylibEngine()
        guard t30RequirePinnedImage(canonical, lane: "t30 arbitrary-path (opposite control)") else { return }
        XCTAssertEqual(
            canonical.kind, .pinnedSQLCipher,
            "*** THE VERIFIED CANONICAL IMAGE STILL CLAIMETH PINNED -- the arbitrary-path refusal is a "
                + "DISCRIMINATOR, not a `kind` clamped to plainSQLite. ***",
        )
    }

    // (15) the factory over the unbound engine answers .unavailable -- TYPED, and touching no file
    func testTheFactoryRefusethAnUnboundEngineWithoutTouchingDisk() throws {
        let kc = FakeKeychain(); dek(kc, tag)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t30-unbound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = dir.appendingPathComponent("msg.db")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))

        let f = EncryptedStoreFactory(provider: kc, engine: unboundEngine())
        let opened = f.openStore(path: store.path, tag: tag,
                                 scope: try t30Scope(msgPath: store.path, tag: tag, keyDomain: kc.physicalKeyDomain))
        XCTAssertEqual(
            opened, .unavailable,
            "*** AN UNBOUND ENGINE MUST YIELD `.unavailable`, NEVER A PLAINTEXT-OPENED STORE. *This is the clause "
                + "whose absence let the private stores fall back to ordinary SQLite: the factory must not be able "
                + "to satisfy a private open without a real engine.* ***",
        )
        XCTAssertFalse(opened.isAvailable)
        // *** AND THE OWNED ROAD REFUSES TYPED TOO -- `.engineUnavailable`, never a fabricated connection. ***
        let owned = f.reopenOwnedRequiringDEK(path: store.path, tag: tag,
                                             scope: try t30Scope(msgPath: store.path, tag: tag, keyDomain: kc.physicalKeyDomain))
        if case .engineUnavailable = owned {} else {
            XCTFail("*** THE OWNED ROAD MUST ANSWER `.engineUnavailable` FOR AN UNBOUND ENGINE. *A `.opened` here "
                    + "would mean a connection was fabricated -- the exact 'nominal store with a nil handle' the "
                    + "card forbids.* Observed: \(owned) ***")
        }
    }

    // (16) the unbound engine's throws are TYPED, so a caller can act on them rather than guess
    func testTheUnboundEngineThrowethATypedIoFaultOnEveryOpenRoad() throws {
        let e = unboundEngine()
        let dek = StoreDEK(bytes: testDEKBytes())
        for (label, call) in [
            ("openOwnedForWriting", { try e.openOwnedForWriting(path: "/tmp/x.db", dek: dek) }),
            ("reopenOwnedRequiringDEK", { try e.reopenOwnedRequiringDEK(path: "/tmp/x.db", dek: dek) }),
            ("openForWriting", {
                _ = try e.openForWriting(path: "/tmp/x.db", dek: dek); return OwnedConnection?.none
            }),
            ("reopenRequiringDEK", {
                _ = try e.reopenRequiringDEK(path: "/tmp/x.db", dek: dek); return OwnedConnection?.none
            }),
        ] as [(String, () throws -> OwnedConnection?)] {
            do {
                _ = try call()
                XCTFail("\(label): an unbound engine must not answer a handle")
            } catch let f as StoreOpenFault {
                guard case .io(let why) = f else {
                    XCTFail("\(label): expected a typed `.io` fault, got \(f)"); return
                }
                XCTAssertTrue(why.contains("not bound") || why.contains("not present"),
                              "\(label): the fault must NAME why the engine is absent: \(why)")
            }
        }
    }

    // (17) *** THE MANDATORY POSITIVE ROAD: POPULATED, EXACT-BYTES, REOPENED, PLATFORM-UNREADABLE. ***
    //
    // *** SQLITE-LATEST-I6: THE ORIGINAL EMPTY-FILE WRONG-KEY WITNESS IS RETIRED. *** *It opened/probed/closed a NEW
    // database through the metadata road and then changed the key -- an empty SQLCipher file answers a wrong key
    // without any encryption defect either way, so the assertion could fail while the cipher behaved perfectly. The
    // replacement writes REAL message and peer rows through the sealed, admitted, keyed road; CLOSES; reopens with
    // the exact bytes; demands the typed wrong-key/no-key refusals on the POPULATED file; and demands that stock
    // platform SQLite cannot read the rows.* **The pinned image is repository-built
    // (`tools/supplychain/build_sqlcipher_simulator.sh`) and staged by this lane's host supply, so a missing binding
    // here is a COURT/SYSTEM failure (XCTFail) -- never a distinguishable skip and never an "EXTERNAL-BLOCKED" label
    // over builder-owned work. Physical-device at-rest proof remains the separate device gate.***
    func testTheDylibEnginePopulatesBothStoresReopensExactAndRefusesWithoutTheKey() throws {
        let e = SqlCipherDylibEngine()
        guard t30RequirePinnedImage(e, lane: "t30 populated positive") else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("t30-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let msgURL = dir.appendingPathComponent("mesh.db")
        let peerURL = dir.appendingPathComponent("peer.db")
        let peerTag = "store-peer"
        let kc = FakeKeychain()
        dek(kc, tag); dek(kc, peerTag)
        let f = EncryptedStoreFactory(provider: kc, engine: e)

        // (1) POPULATE BOTH ACTUAL PRIVATE STORES THROUGH THE OWNED, ADMITTED ROAD, THEN CLOSE FOR REAL.
        let frame = FrameV2(type: .message, msgId: t30Seed(0x31), routingTag: Data([1, 2, 3, 4]),
                            ttl: 12, hopCount: 0, flags: Priority.toFlags(.direct) | UInt16(FrameV2.Flags.sealed),
                            payload: Data((0..<256).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 5) }))
        do {
            guard case .opened(let msgOwned, _) = f.openOwnedForWriting(path: msgURL.path, tag: tag,
                  scope: try t30Scope(msgPath: msgURL.path, tag: tag, keyDomain: kc.physicalKeyDomain)) else {
                return XCTFail("the first-install owned road must create and hand over the message store")
            }
            let msg = SqliteMessageStore(verifiedConnection: msgOwned, maxBytes: 64 * 1024 * 1024)
            guard case .opened = msg.openOutcome else { return XCTFail("the message store must adopt the owned connection") }
            XCTAssertEqual(.heldNew, msg.persist(frame, receivedFrom: Data(repeating: 0xAB, count: 8)))
            msg.close(); _ = msgOwned.close()

            guard case .opened(let peerOwned, _) = f.openOwnedForWriting(path: peerURL.path, tag: peerTag,
                  scope: try t30Scope(msgPath: peerURL.path, tag: peerTag, keyDomain: kc.physicalKeyDomain)) else {
                return XCTFail("the first-install owned road must create and hand over the peer store")
            }
            let peer = try SqlitePeerIdentityStore(verifiedConnection: peerOwned)
            XCTAssertEqual(1, try peer.insertFirstSeen(nodeId: t30Seed(0x32), signingPub: Data(repeating: 0x44, count: 32),
                                                      acceptedStatic: Data(repeating: 0x55, count: 32),
                                                      acceptedGeneration: 3, trustCode: 1))
            peer.close(); _ = peerOwned.close()
        }

        // (2) THE POPULATED FILE DOES NOT CARRY THE PLAINTEXT SQLITE HEADER.
        let header = try FileHandle(forReadingFrom: msgURL).readData(ofLength: 16)
        XCTAssertNotEqual(header, Data("SQLite format 3\0".utf8),
                          "*** A POPULATED PRIVATE STORE MUST NOT PRESENT THE PLAINTEXT SQLITE HEADER. ***")

        // (3) STOCK, STATICALLY LINKED PLATFORM SQLITE CANNOT READ THE POPULATED ROWS.
        var plain: OpaquePointer?
        let openRC = sqlite3_open_v2(msgURL.path, &plain, SQLITE_OPEN_READONLY, nil)
        defer { if let plain { sqlite3_close_v2(plain) } }
        var stockReadable = false
        var stockCount = -1
        if openRC == SQLITE_OK, let plain {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(plain, "SELECT count(*) FROM held_frames", -1, &stmt, nil) == SQLITE_OK, let stmt {
                stockReadable = sqlite3_step(stmt) == SQLITE_ROW
                if stockReadable { stockCount = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
        }
        XCTAssertFalse(stockReadable && stockCount >= 1,
            "*** STOCK SQLite MUST NOT READ THE POPULATED MESSAGE ROWS (open rc=\(openRC), count=\(stockCount)). "
                + "A plaintext-capable read of the private store is the exact at-rest defect this engine exists to "
                + "prevent -- a non-SQLite header ALONE is not this refusal: the SELECT must fail too. ***")

        // (4) THE SAME KEYS RE-OPEN AND ANSWER THE EXACT BYTES AFTER A REAL CLOSE/REOPEN.
        guard case .opened(let msgOwned2, let cipherVersion) = f.reopenOwnedRequiringDEK(path: msgURL.path, tag: tag,
              scope: try t30Scope(msgPath: msgURL.path, tag: tag, keyDomain: kc.physicalKeyDomain)) else {
            return XCTFail("the correct key must re-open the message store")
        }
        XCTAssertEqual(cipherVersion, SQLCipherPin.supportedCipherVersion)
        let msg2 = SqliteMessageStore(verifiedConnection: msgOwned2, maxBytes: 64 * 1024 * 1024)
        XCTAssertEqual(msg2.allHeldOrderedByPriority().first?.payload, frame.payload,
                       "*** THE EXACT PAYLOAD BYTES SURVIVE THE ACTUAL CLOSE/REOPEN. ***")
        msg2.close(); _ = msgOwned2.close()
        guard case .opened(let peerOwned2, _) = f.reopenOwnedRequiringDEK(path: peerURL.path, tag: peerTag,
              scope: try t30Scope(msgPath: peerURL.path, tag: peerTag, keyDomain: kc.physicalKeyDomain)) else {
            return XCTFail("the correct key must re-open the peer store")
        }
        let peer2 = try SqlitePeerIdentityStore(verifiedConnection: peerOwned2)
        XCTAssertEqual(try peer2.readRaw(t30Seed(0x32))?.signingPublicKeyRaw, Data(repeating: 0x44, count: 32),
                       "the exact peer row survives the actual close/reopen")
        peer2.close(); _ = peerOwned2.close()

        // (5) THE METADATA ROAD ON THE POPULATED FILE: WRONG KEY IS TYPED `.locked`; ABSENCE IS NOT A STORE.
        kc.stored[tag] = StoreDEK(bytes: Data(repeating: 0x5A, count: 32))
        XCTAssertEqual(f.reopenExisting(path: msgURL.path, tag: tag,
                       scope: try t30Scope(msgPath: msgURL.path, tag: tag, keyDomain: kc.physicalKeyDomain)),
                       .locked,
                       "*** A WRONG DEK ON THE POPULATED KEYED FILE MUST REFUSE AS `.locked` -- the original court "
                           + "demanded this of an EMPTY file, which proves nothing about the cipher. ***")
        kc.stored[tag] = nil
        XCTAssertFalse(f.reopenExisting(path: msgURL.path, tag: tag,
                       scope: try t30Scope(msgPath: msgURL.path, tag: tag, keyDomain: kc.physicalKeyDomain)).isAvailable,
                       "NO key must not answer an empty healthy store")
    }
}

// ---------------------------------------------------------------------------
// *** THE SEALED LEASE ROAD AND THE MANDATORY IMAGE GATE (SQLITE-LATEST-C3 / I6). ***
//
// *The court obtains admission ONLY through the production boundary: a settled, generation-known journal; the
// real ladder driven for a permit; and `PhysicalEstateAuthority.beginConstruction` -- the sole issuer -- presenting
// that permit against the live record. `EncryptedStoreAdmissionLedger` and `EncryptedStoreAdmissionScope.forTest`
// are DELETED; there is no court convenience to route around.*
// ---------------------------------------------------------------------------

private func t30RequirePinnedImage(_ engine: SqlCipherDylibEngine, lane: String) -> Bool {
    if engine.isBound { return true }
    XCTFail("*** MANDATORY NATIVE LANE '\(lane)' (SQLITE-LATEST-I6): the pinned image '\(SQLCipherPin.libraryName)' "
            + "is not staged or did not bind. It is repository-built: run "
            + "tools/supplychain/build_sqlcipher_simulator.sh and stage it where the loader searches, or export "
            + "GODSTONE_SQLCIPHER_ARTIFACT_DIR. Reason: \(engine.bindingFailureReason ?? "unknown") ***")
    return false
}

private func t30Seed(_ seed: UInt8) -> Data { Data((0..<16).map { UInt8(truncatingIfNeeded: Int($0) &+ Int(seed)) }) }

private final class T30Journal: WipeJournal, @unchecked Sendable {
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

private final class T30Keychain: LocalIdentityKeychain, @unchecked Sendable {
    var storage: [String: Data] = [:]
    func read(tag: String) throws -> Data? { storage[tag] }
    func add(tag: String, data: Data) throws { storage[tag] = data }
    func delete(tag: String) throws { storage.removeValue(forKey: tag) }
}

/// One admitted scope, issued by the sealed sole issuer against a settled, generation-known estate.
private func t30Scope(msgPath: String, tag: String, keyDomain: String) throws -> EncryptedStoreAdmissionScope {
    let declaredURL = URL(fileURLWithPath: msgPath)
    let companionURL = URL(fileURLWithPath: msgPath + "-companion")
    let artifactPaths = MeshRuntime.wipeArtifactPaths(messageStoreUrl: declaredURL, peerStoreUrl: companionURL)
    let estateId = MeshRuntime.recoveryEstateId(artifactPaths: artifactPaths)
    let journal = T30Journal()
    _ = journal.writeChecked(.idle)              // settled record with a KNOWN generation -- never a fabricated zero
    let authority = CrashResumableWipe(
        store: WipeJournalDurabilityAdapter(journal: journal),
        vault: WipeDeferredKeyVaultSeam(),
        filesystem: WipeDeferredArtifactFileSystemSeam(),
        runtime: WipeDeferredTransportSeam(),
        authority: WipeDeferredIdentityAuthoritySeam())
    guard case .normal(let permit) = StartupRecoveryBootstrap(wipe: authority, estateId: estateId)
            .consumeCompositionTopology() else {
        XCTFail("*** '\(laneName(msgPath))': a driven clean estate must issue the permit; the ladder refused for "
                + "estate '\(estateId)' ***")
        throw StoreKeyError.keychainUnavailable
    }
    do {
        let lease = try PhysicalEstateAuthority.shared.beginConstruction(
            permit: permit, estateId: estateId, journal: journal,
            artifactPaths: artifactPaths, keychain: T30Keychain(),
            keyDomain: keyDomain, stores: [tag: declaredURL])
        return EncryptedStoreAdmissionScope(authorityLease: lease, storeTag: tag, storePath: msgPath)
    } catch let fault as MeshRuntime.MeshRuntimeError {
        // *** THE TYPED DECISION AND REASON ARE CARRIED VERBATIM, so a future runner reads the ACTUAL cause rather
        //     than the bare `MeshRuntimeError error 2` the 107-consumer probe printed. ***
        if case .startupRefusedByRecovery(let decision, let reason) = fault {
            XCTFail("*** '\(laneName(msgPath))': the sealed issuer REFUSED estate '\(estateId)' for tag '\(tag)': "
                    + "decision=\(decision) reason=\(reason) ***")
        } else {
            XCTFail("*** '\(laneName(msgPath))': the sealed issuer refused with an unexpected MeshRuntimeError: \(fault) ***")
        }
        throw fault
    }
}

private func laneName(_ path: String) -> String { (path as NSString).lastPathComponent }
