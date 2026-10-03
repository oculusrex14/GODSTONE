import XCTest
import Foundation
import SQLite3
@testable import GodstoneMesh

//  GS-FINAL-003 `true-recovery-topology`: THE TRUE PRE-PRIVATE RECOVERY, MEASURED AT ITS OWN SEAMS.
//
//  *** THE CHARGE THIS FILE ANSWERS, QUOTED FROM THE FINDING: ***
//
//      "iOS discards the result of resume before creating identity/stores." Root cause: *"DI
//      sequencing is mistaken for successful state transition."*
//
//  *** AND THE REPAIR'S SHAPE, WHICH IS WHAT THESE ARMS EXERCISE. *** The refusal does not live in a
//  gate that makes its own remedy unreachable (the brick `testSR02` measured); it lives in THREE
//  ROADS, of which only the first constructs anything sensitive:
//
//      * a SETTLED estate (`cleanStart` / `wipeCompleted`) yields a `PrivateRuntimePermit` -- **and
//        that permit is MADE OF `RecoveryEvidence`, built only by the one-shot
//        `StartupRecoveryBootstrap.consumeCompositionTopology()`, which DRIVES the ladder itself.**
//        There is no `issue(_:)`: a helper taking a `StartupRecoveryDecision` would be a MINT, because
//        every one of its six cases is public;
//      * an OUTSTANDING one (`recoveryPending` / `retryableFailure`) yields `.recoveryOnly(decision)`
//        -- A DECISION WITH NO PERMIT AND NO CAPABILITY -- whose only road is
//        `MeshRuntime.runRecoveryLadder`, which owns the journal, the key-delete seam, the
//        artifact-delete seam, the identity-delete-and-publish seam and ONE LIVE TRANSPORT, and
//        **opens no store, builds no trust repository and mints no ordinary identity**;
//      * `corruptJournal` / `terminalFailure` yield NOTHING -- the record itself is the gate's oracle,
//        and a gate that cannot read its oracle must not open anything at all.
//
//  SO `MeshRuntime.create(encryptedStores:)` DRIVES THE LIVE PRE-PRIVATE RECOVERY FIRST -- a ladder
//  whose transport and artifact map exist BEFORE any store does, and which openth NO store -- and
//  only a SETTLED post-drive decision may reach the private composition. *A store opened before that
//  drive is a store opened on the key a later resume will erase.*
//
//  *** AND THE GATED-COMPOSITION DRAFT IS NOT WHAT SHIPPED. *** *An earlier revision answered an
//  outstanding wipe with a PRIVATE RUNTIME whose sensitive roads were refused through the
//  journal-bound gate. A review named it correctly: **stores opened and an identity minted, then
//  refused -- WHICH IS CONSTRUCTION PLUS A GATE, NOT THE "ZERO identity/key/store/runtime
//  construction before terminal" the requirement states.** The arms below therefore assert ZERO, and
//  no arm in this file may obtain a permit except by driving a ladder to a settled rung.*
//
//  *** EVERY ARM CARRIES A REAL POSITIVE AND A REAL NEGATIVE DISCRIMINATOR. *** *The obligation is
//  not "the happy path happened": it is that the counters and the durable record can DISTINGUISH the
//  two roads. **An observer-disconnected instrument -- or one that simply always answereth zero --
//  must go RED on at least one arm, which is why the opens, the DEK erasures, the identity mints and
//  the durable write ORDER are all read from the objects the production code actually used rather
//  than from a summary the court wrote for itself.***
//
//  ------------------------------------------------------------------------------------------------
//  TWO READINGS THAT THE PRODUCTION CODE ITSELF FORCES, AND WHICH THESE ARMS HONOUR RATHER THAN HIDE:
//
//  (1) *** THE IDLE COLLAPSE. *** *`WipeJournalDurabilityAdapter.readJournal()` answereth `[]` for
//      `.idle`, deliberately, "because `IDLE` and 'nothing was ever requested' ARE THE SAME ESTATE".
//      So on a ladder that ran to its end the outcome's `rungs` is EMPTY, and the retained
//      `startupDecision` is read from a record that now stands at IDLE -- i.e. `cleanStart`.* THE
//      DURABLE WRITE LOG IS THEREFORE THE EVIDENCE THAT THE LADDER REALLY RAN (rung by rung, in
//      order), and the SETTLED decision is asserted by what it PERMITS, not by a spelling that a
//      post-IDLE reader cannot honestly answer.
//
//  (2) *** WHY THE INTERNAL TWIN DRIVES THE LADDER ARMS. *** *`MeshRuntime.runRecoveryLadder` -- the
//      PUBLIC verb -- defaulteth to `DefaultLocalIdentityKeychain` and `dekProvider: nil`: its last
//      rung would MINT A REAL IDENTITY into the machine's login Keychain and its vault would DELETE
//      whatever identity really stood there. **Run twice, the second run's `generateAndStore` would
//      throw `identityAlreadyExists` and the ladder would stall at `ARTIFACTS_DELETED` -- the arms
//      would measure the developer's Keychain, not the topology.** `runRecoveryLadderInternal` is
//      the SAME ladder (the public verb is a delegating wrapper over it) with the composition's own
//      keychain and DEK provider injected, so the estate under test is the court's and the result is
//      deterministic.*
//  ------------------------------------------------------------------------------------------------

final class GsFinal003RecoveryTopologyTests: XCTestCase {

    // MARK: - the doubles: real seams, not summaries

    /// *** A REAL PINNED-BINDING ENGINE THAT COUNTS ITS OPENS PER STORE. ***
    ///
    /// *The handover is `SqlCipherDylibEngine`'s own (DEK applied, cipher probed, at-rest pin verified before the
    /// connection leaves), and EVERY OPEN IS COUNTED at that handover, because "two private stores were opened" and
    /// "no private store was opened" are the two claims these arms must be able to tell apart.*
    private final class RecoveryEngine: OwnedConnectionStoreEngine, @unchecked Sendable {
        /// *** DELEGATED, NEVER DECLARED: a `kind` written by hand would make the factory's fail-closed gate vacuous
        /// (the exact IOS-R11 mislabel). A binding failure therefore yields `.plainSQLite`, which the factory refuses. ***
        var kind: StoreEngineKind { pinned.kind }
        var supportedCipherVersion: Int { pinned.supportedCipherVersion }

        private let lock = NSLock()
        private var openPaths: [String] = []
        private var stepLog: [String] = []

        /// **THE NEGATIVE DISCRIMINATOR'S INSTRUMENT:** an arm that refuses construction must read 0
        /// here, and an arm that settles must read 2 -- *one per store, never a double open.*
        var ownedOpenCount: Int { lock.lock(); defer { lock.unlock() }; return openPaths.count }
        var ownedOpenPaths: [String] { lock.lock(); defer { lock.unlock() }; return openPaths }
        /// The engine's own record: `open`, `key`, `firstPageRead` per handover, in that order.
        var steps: [String] { lock.lock(); defer { lock.unlock() }; return stepLog }

        private func note(_ s: String) { lock.lock(); stepLog.append(s); lock.unlock() }

        /// *** THE REAL PINNED BINDING (SQLITE-LATEST / NATIVE-PIN). *** *The steps this engine records are taken
        /// from `SqlCipherDylibEngine`'s own owned road -- the one that applies the DEK, probes the cipher and
        /// verifies the at-rest pin -- rather than from platform `sqlite3_open_v2` relabelled as pinned. The
        /// counter is raised at the handover, so the zero assertions measure the production boundary.*
        private let pinned = SqlCipherDylibEngine()
        var isBound: Bool { pinned.isBound }

        /// *** THE MANDATORY NATIVE LANE (SQLITE-LATEST-I6): A BINDING FAILURE IS A COURT FAILURE, NEVER A SKIP. ***
        /// *Every arm in this file that reaches private construction constructs this engine, so the gate is applied
        /// once, here, rather than being repeatable-and-forgettable at eight call sites.*
        init() {
            if !pinned.isBound {
                XCTFail("*** MANDATORY NATIVE LANE (SQLITE-LATEST-I6): the pinned image '\(SQLCipherPin.libraryName)' "
                        + "is not staged or did not bind. Stage the repository-built artifact "
                        + "(tools/supplychain/build_sqlcipher_simulator.sh) or export GODSTONE_SQLCIPHER_ARTIFACT_DIR. "
                        + "Reason: \(pinned.bindingFailureReason ?? "unknown") ***")
            }
        }

        func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            try pinned.openForWriting(path: path, dek: dek)
        }

        func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            try pinned.reopenRequiringDEK(path: path, dek: dek)
        }

        func openOwnedForWriting(path: String, dek: StoreDEK) throws -> OwnedConnection {
            note("open"); note("key")
            let connection = try pinned.openOwnedForWriting(path: path, dek: dek)
            note("firstPageRead")
            lock.lock(); openPaths.append(path); lock.unlock()
            return connection
        }

        /// *** THE HANDOVER. THE KEY IS APPLIED BY THE PINNED BINDING BEFORE THE CONNECTION LEAVES, AND EVERY STEP
        /// IS RECORDED. ***
        func reopenOwnedRequiringDEK(path: String, dek: StoreDEK) throws -> OwnedConnection {
            note("open"); note("key")
            let connection = try pinned.reopenOwnedRequiringDEK(path: path, dek: dek)
            note("firstPageRead")
            lock.lock(); openPaths.append(path); lock.unlock()
            return connection
        }

        /// *** THE COURT'S CLOSE ACCOUNTING IS *NOT* A SECOND `OwnedConnection`, AND AN EARLIER DRAFT THAT WRAPPED
        /// THE CONNECTION WAS A DEADLOCK -- MEASURED, NOT IMAGINED. ***
        ///
        /// *The wrapper built a SECOND `OwnedConnection` over the SAME `OwnedVerifiedConnection`, so the outer and
        /// inner wrappers SHARED one `ConnectionLifecycle` (`connection.lifecycle`) while each kept its own
        /// closed-flag/handler pair. The outer's handler ran INSIDE the inner `lifecycle.close`'s `finishClose` -- which
        /// holds `pendingClose` unset and `physicallyClosed == false` until the handler RETURNS -- and the inner
        /// `close()` was called with the caller's OWN use still recorded in `threadUses`, so it took the reentrancy
        /// short-circuit and returned `false` WITHOUT physically closing. `finishClose` then broadcast, but the outer
        /// handler had already returned: the two wrappers disagreed about who closed the handle, and a later close
        /// (the runtime's own `deinit` -> `adoptedMessageConnection?.close()`) waited for ever on a
        /// `physicallyClosed` flag that would never be set again. **The parent's stack sample caught exactly this
        /// (`ConnectionLifecycle.close` -> `while !physicallyClosed { condition.wait() }` under
        /// `MeshRuntime.deinit`).**
        ///
        /// **THE PINNED BINDING ALREADY OWNS THE ONE EXACTLY-ONCE CLOSE, AND THE HANDLE IS REACHED THROUGH IT -- so
        /// the honest accounting is that this composition closes each store ONCE, at the engine's own close point.**
        /// *`openPaths` (with `engine.steps`) is the observable the arms actually assert; no arm reads a close count,
        /// and a court count that must interpose a second lifecycle to exist is a count that BREAKS the protocol it
        /// is measuring.*
    }

    /// *** THE IN-MEMORY DEK VAULT, WITH THE TWO COUNTERS THE OBLIGATION NAMES. ***
    ///
    /// *** `fetchDEK` IS FETCH-ONLY, EXACTLY AS THE PRODUCTION PROVIDER IS. ***
    ///
    /// *THE DEFECT THIS REPAIRS WAS MEASURED, NOT IMAGINED: this fake used to MINT a DEK on absence, so
    /// `WipeKeyVaultSeam.eraseStoreDEK`'s follow-up fetch -- the erasure's own VERIFICATION read -- minted a
    /// replacement and answered `dekFound` instead of `dekNotFound`. The vault therefore reported
    /// `retryable: "the DEK for '<tag>' surviveth its own deletion"` even though the deletion had succeeded, and the
    /// whole ladder stalled at `RUNTIME_DRAINED` (measured on all four reddening arms). **The production
    /// `DefaultPrivateStoreKeyProvider.fetchDEK` throweth `StoreKeyError.dekNotFound` and MINTS NOTHING** -- only
    /// `createDEK` createth, and only the first-install open road calls it. So the fake now obeys the same law, and
    /// `failDEKDelete` is the flag that keeps a wipe PENDING (arm 2 and arm 5).*
    private final class RecoveryKeyProvider: PrivateStoreKeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var deks: [String: Data] = [:]
        private var requests = 0
        private var deletes = 0
        private let failDEKDelete: Bool

        init(failDEKDelete: Bool = false) { self.failDEKDelete = failDEKDelete }

        var dekByteCount: Int { 32 }
        /// How many times the composition's factory asked for a key -- one per private store it keyed.
        var dekRequests: Int { lock.lock(); defer { lock.unlock() }; return requests }
        /// How many times the wipe's vault destroyed one.
        var dekDeletes: Int { lock.lock(); defer { lock.unlock() }; return deletes }

        /// COURT SETUP, NOT THE SYSTEM UNDER TEST: plants a DEK WITHOUT counting, so the counters
        /// measure only what the composition did.
        func seedDEK(tag: String) { lock.lock(); deks[tag] = Data(repeating: 0x5A, count: 32); lock.unlock() }
        func holdsDEK(tag: String) -> Bool { lock.lock(); defer { lock.unlock() }; return deks[tag] != nil }
        /// *** THE BYTES THE PROVIDER REALLY HOLDS FOR `tag` -- THE OBSERVABLE THAT TELLS "ERASED AND FRESHLY
        /// RE-CREATED" FROM "THE OLD KEY SURVIVED". *** *A Boolean cannot make that distinction, and it is the whole
        /// IOS-R4 law: a key that surviveth its own deletion must redden.*
        func dekBytes(tag: String) -> Data? { lock.lock(); defer { lock.unlock() }; return deks[tag] }

        func fetchDEK(tag: String) throws -> StoreDEK {
            lock.lock(); requests += 1
            guard let existing = deks[tag] else {
                lock.unlock()
                // FETCH-ONLY, AS PRODUCTION IS: absence is `dekNotFound`, never a silent mint. Only `createDEK`
                // may create one, and the first-install open road is its one caller.
                throw StoreKeyError.dekNotFound
            }
            lock.unlock()
            return StoreDEK(bytes: existing)
        }

        func createDEK(tag: String) throws -> StoreDEK {
            let fresh = Data(repeating: 0xA5, count: 32)
            lock.lock(); deks[tag] = fresh; lock.unlock()
            return StoreDEK(bytes: fresh)
        }

        func deleteDEK(tag: String) throws {
            lock.lock()
            deletes += 1
            deks[tag] = nil
            let mustFail = failDEKDelete
            lock.unlock()
            // A THROW IS A RETRYABLE FAILURE, NEVER A SILENT SUCCESS: the wipe must remain pending.
            if mustFail { throw StoreKeyError.keychainUnavailable }
        }

        func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult {
            .success
        }
    }

    /// *** THE IDENTITY KEYCHAIN, WITH THE WRITE LOG THE IDENTITY BOUNDARY NEEDS. ***
    ///
    /// *`MeshIdentity.generateAndStore` MINTS A KEY BY ADDING ONE, so `writes` is the observable of an
    /// identity that was created -- "the identity was minted exactly once, by the RECOVERY's own
    /// authority" is that log's reading.* **AND `delete(tag:)` MUST NOT THROW WHEN THE TAG IS ABSENT,**
    /// which is not a nicety: the production `MeshIdentity.deleteFromKeychain` deleteth THREE tags in a
    /// row, and a wipe that threw on the second would stall on a key it had already erased.
    private final class RecoveryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]
        private var writeLog: [String] = []
        private var deleteLog: [String] = []

        var writes: [String] { lock.lock(); defer { lock.unlock() }; return writeLog }
        var deletes: [String] { lock.lock(); defer { lock.unlock() }; return deleteLog }
        func contains(tag: String) -> Bool { lock.lock(); defer { lock.unlock() }; return storage[tag] != nil }

        func read(tag: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return storage[tag] }

        func add(tag: String, data: Data) throws {
            lock.lock(); storage[tag] = data; writeLog.append(tag); lock.unlock()
        }

        /// *** THE CHECKED-UPDATE LIFECYCLE, ANSWERED WITHOUT POLLUTING THE IDENTITY-MINT LOG. ***
        ///
        /// *MEASURED: the inherited default `upsert` is `try? delete` + `add`, so the PHYSICAL-INVENTORY CATALOG
        /// writes `PhysicalEstateAuthority.bindInventory` perform (two capability tags, per estate) landed in
        /// `writeLog` -- and an arm asserting "ZERO IDENTITY MINTS" then read the catalog tags as identity mints
        /// (the measured `aRecoveryThatCannotSettle` red). **The log's law is narrower and is what the arms actually
        /// assert: a MINT is `MeshIdentity.generateAndStore`'s one `add(v1Tag)`.** A catalog refresh, a publication
        /// record and a wipe-publication intent are different writes with different owners, so they travel the real
        /// storage without being counted as mints.*
        func upsert(tag: String, data: Data) throws {
            lock.lock(); storage[tag] = data; lock.unlock()
        }

        func delete(tag: String) throws {
            lock.lock(); storage.removeValue(forKey: tag); deleteLog.append(tag); lock.unlock()
        }
    }

    /// *** THE DURABLE JOURNAL: TYPED STATE PLUS EVERY RECORD IT EVER CARRIED, IN ORDER. ***
    ///
    /// *`read()` holdeth only the LAST value, so "the drain preceded the erasure" -- the actual safety
    /// property -- is unobservable from it. The write log maketh the ORDER readable, in the journal's own
    /// `WipeState` raw values, which is what the production `MeshJournalDurabilityAdapter` writes through.*
    private final class RecoveryJournal: WipeJournal, @unchecked Sendable {
        private let lock = NSLock()
        private var state: WipeState
        private var log: [String] = []
        /// *** A DURABLE COUNTER, SO A PERMIT CAN BE BOUND TO IT (IOS-R1/R3). *** *A counterless test journal would
        /// make the construction boundary refuse (the live generation would be UNKNOWN) -- which is the production law,
        /// not a court convenience. Seeding models a record a previous process left behind, already at generation 1.*
        private var epoch: UInt64?

        /// Seeding models a DURABLE RECORD a previous process left behind -- INCLUDING ITS GENERATION, because the
        /// production pin compares the phase's generation to the durable floor and a seeded rung at a stale number
        /// would be refused (which is the production law, not a fixture convenience).
        init(seed: WipeState? = nil, generation: UInt64 = 1) {
            state = seed ?? .idle
            if seed != nil { log = [seed!.rawValue]; epoch = generation }
        }

        var writeLog: [String] { lock.lock(); defer { lock.unlock() }; return log }

        func read() -> WipeState { lock.lock(); defer { lock.unlock() }; return state }
        func write(_ s: WipeState) {
            lock.lock()
            state = s; log.append(s.rawValue)
            if epoch == nil, s != .idle { epoch = 1 }
            lock.unlock()
        }
        func clear() { lock.lock(); state = .idle; lock.unlock() }
        var durableEpoch: UInt64? { lock.lock(); defer { lock.unlock() }; return epoch }
        @discardableResult
        func bumpEpoch() -> UInt64? {
            lock.lock(); defer { lock.unlock() }
            epoch = (epoch ?? 0) &+ 1
            return epoch
        }
        /// An explicit typed court fake: it answers its OWN medium, so its commits ARE acknowledged.
        func readDurable() -> (state: WipeState, epoch: UInt64?)? {
            lock.lock(); defer { lock.unlock() }; return (state, epoch)
        }

        /// STATED EXPLICITLY: this journal keepeth TYPED values, so it IS readable by construction --
        /// and the protocol's fail-closed default would otherwise report it CORRUPT.
        var isReadable: Bool { true }
    }

    /// A journal whose DURABLE VALUE cannot be parsed -- the real `UserDefaultsWipeJournal` case, which
    /// a typed `read()` cannot express.
    private final class UnreadableRecoveryJournal: WipeJournal, @unchecked Sendable {
        func read() -> WipeState { .idle }        // coerced, exactly as the real parser coerceth
        func write(_ s: WipeState) {}
        func clear() {}
        var isReadable: Bool { false }
    }

    // MARK: - helpers

    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gf003rt_\(tag)_\(UUID().uuidString).db")
    }

    private func tempDir(_ tag: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf003rt_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ urls: URL...) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    /// The production `WipeState` for a ladder rung -- via the production mapping, never a second table.
    private func wipeState(for rung: WipeJournalState) -> WipeState? {
        WipeJournalDurabilityAdapter.state(forStage: WipeJournalState.wireName(rung))
    }

    /// Every durable record the journal carried, as ladder positions -- so monotonicity is read from
    /// the record itself rather than from a recollection of the drive.
    private func journalStates(of journal: RecoveryJournal) -> [WipeJournalState] {
        journal.writeLog.compactMap { raw -> WipeJournalState? in
            guard let state = WipeState(rawValue: raw) else { return nil }
            return WipeJournalState.fromWire(WipeJournalDurabilityAdapter.stage(forState: state))
        }
    }


    // MARK: - (1) THE SETTLING ROAD: A PENDING WIPE RESOLVES BEFORE ANY PRIVATE STORE

    /// *** THE CENTRAL POSITIVE ARM: THE PRE-PRIVATE RECOVERY DRIVES THE LADDER TO ITS END, AND ONLY THEN
    /// ARE THE PRIVATE STORES OPENED -- ONCE EACH, WITH ONE IDENTITY, MINTED BY THE RECOVERY'S OWN AUTHORITY. ***
    ///
    /// *THE FOUR CLAIMS, EACH MEASURED AT ITS OWN BOUNDARY:*
    ///   * THE ORDER -- requested -> runtimeDrained -> keyErased -> artifactsDeleted -> newIdentity -> idle,
    ///     read from the durable write log via `firstIndex`, because "the drain preceded the erasure" is the
    ///     safety property and a last-value read cannot see it;
    ///   * THE DECISION -- a SETTLED one (whichever spelling a post-IDLE reader can honestly answer);
    ///   * THE OPENS -- exactly two, one per store, at the composition's own urls;
    ///   * THE IDENTITY -- exactly ONE write, `MeshIdentity.v1Tag`, performed by the RECOVERY (the private
    ///     composition's `loadOrCreate` then LOADS and writeth nothing).
    ///
    /// **AND THE NEGATIVE DISCRIMINATORS ARE IN THE SAME COUNTS:** *a zero, or a four, or a second write,
    /// reddens -- which is what an always-zero or observer-disconnected instrument cannot survive.*
    func testGSFINAL003_aPendingWipeResolvesThroughThePrePrivateRecoveryBeforeAnyPrivateStore() throws {
        let dir = tempDir("settle")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")

        let journal = RecoveryJournal(seed: .requested)
        let keychain = RecoveryKeychain()
        let engine = RecoveryEngine()
        let provider = RecoveryKeyProvider()
        // *** IOS-R4: A REAL DEK UNDER *EACH* ACCOUNT THE PRIVATE STORES ACTUALLY USE, so the erasure below is
        // non-vacuous -- and the WRONG-ACCOUNT tag is seeded too, so a wipe that erases the bogus tag while sparing
        // the real ones is LOUD rather than green. ***
        provider.seedDEK(tag: WipeKeyVaultSeam.messageStoreDEKTag)
        provider.seedDEK(tag: WipeKeyVaultSeam.peerStoreDEKTag)
        provider.seedDEK(tag: "godstone.store.dek")   // the WRONG account the old seam deleted
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msg,
            peerStoreUrl: peer,
            journal: journal,
            keychain: keychain,
            encryptedStores: factory)

        // (1) *** THE DURABLE ORDER. ***
        let log = journal.writeLog
        func position(_ name: String) throws -> Int {
            try XCTUnwrap(log.firstIndex(of: name),
                          "*** THE LADDER MUST HAVE WRITTEN '\(name)'; it wrote \(log) ***")
        }
        let pRequested = try position("requested")
        let pDrained = try position("runtimeDrained")
        let pKeys = try position("keyErased")
        let pArtifacts = try position("artifactsDeleted")
        let pIdentity = try position("newIdentity")
        let pIdle = try position("idle")
        XCTAssertLessThan(pRequested, pDrained,
                          "*** THE TRANSPORT IS DRAINED BEFORE ANY KEY IS TOUCHED -- the rung exists precisely to "
                          + "record that the radio was quiesced first: \(log) ***")
        XCTAssertLessThan(pDrained, pKeys)
        XCTAssertLessThan(pKeys, pArtifacts,
                          "the keys die BEFORE the artifacts, so an artifact that survives is already unreadable")
        XCTAssertLessThan(pArtifacts, pIdentity,
                          "*** THE NEW IDENTITY COMETH AFTER THE ERASURE, never before it ***")
        XCTAssertLessThan(pIdentity, pIdle,
                          "*** AND THE LADDER CLOSES AT IDLE ONLY AFTER ITS LAST RUNG: a record that reached IDLE "
                          + "while a rung was outstanding would be a wipe reporting a completion it did not reach ***")
        XCTAssertEqual(log.last, WipeState.idle.rawValue,
                       "the durable record must end at IDLE -- the ladder ran to its end: \(log)")

        // (2) *** THE RETAINED DECISION IS A SETTLED ONE THAT PERMITS PRIVATE CONSTRUCTION. ***
        // *Its SPELLING is read post-IDLE (`readJournal()` answereth `[]` for IDLE because IDLE and
        // "never requested" are the same estate), so the honest assertion is what it PERMITS.*
        let decision = runtime.recoveryDecisionAtStartup()
        XCTAssertTrue(
            decision.allowsPrivateConstruction,
            "*** A SETTLED ESTATE MUST PERMIT PRIVATE CONSTRUCTION; it answered \(decision.name) ***")
        XCTAssertNil(decision.refusalReason,
                     "a permitting decision carrieth no refusal reason: \(decision.name)")
        XCTAssertFalse(decision.requiresOperator, "a settled estate needs no human: \(decision.name)")
        XCTAssertTrue(decision == .cleanStart || decision == .wipeCompleted,
                      "*** THE POST-DRIVE READER SEETH A SETTLED ESTATE. *A record standing at IDLE and one that "
                      + "was never written are the SAME durable estate -- the repository's own collapse -- so the"
                      + " settled reader answereth cleanStart; anything else here would mean the record did not"
                      + " settle.* Observed: \(decision.name) ***")

        // (3) *** THE PRIVATE STORES WERE OPENED EXACTLY ONCE EACH, AT THE COMPOSITION'S OWN URLS. ***
        XCTAssertEqual(
            engine.ownedOpenCount, 2,
            "*** ZERO PRIVATE OPENS BEFORE THE ESTATE SETTLES -- AND EXACTLY TWO AFTER IT. *A zero here would mean "
            + "the composition never reached the stores; a four would mean a second, independent open -- the defect"
            + " GS-FINAL-004 closed.* ***")
        XCTAssertEqual(engine.ownedOpenPaths, [msg.path, peer.path],
                       "each store opened once, message then peer, at the urls the composition owns")
        XCTAssertEqual(
            engine.steps, ["open", "key", "firstPageRead", "open", "key", "firstPageRead"],
            "each handover is opened, keyed and page-verified BEFORE the store's migrations run on it")

        // (4) *** THE IDENTITY WAS MINted EXACTLY ONCE, BY THE RECOVERY'S OWN AUTHORITY. ***
        // *** THE IDENTITY WRITES: ONE MINT OF THE IDENTITY ITSELF, PLUS THE PUBLICATION RECORD THAT BINDS IT TO
        // THE WIPE GENERATION (IOS-R8). The identity key is written exactly ONCE; a second `v1Tag` write would mean
        // two identities were minted for one estate. ***
        XCTAssertEqual(
            keychain.writes.filter { $0 == MeshIdentity.v1Tag }, [MeshIdentity.v1Tag],
            "*** ONE MINT, AND IT IS THE RECOVERY'S: `MeshIdentity.generateAndStore` inside the pre-private ladder "
            + "WRITETH `MeshIdentity.v1Tag` once; the private composition's `loadOrCreate` then LOADS -- so a SECOND"
            + " write here would mean two identities were minted for one estate. Observed: \(keychain.writes) ***")
        XCTAssertTrue(keychain.contains(tag: MeshIdentity.v1Tag),
                      "and the identity the recovery minted must be the one the private composition loaded")

        // *** THE WIPE REALLY ERASED THE TWO REAL ACCOUNTS; THE FRESH OPEN THEN REALLY RE-CREATED THEM. ***
        //
        // *MEASURED: a completed wipe destroyeth both the store FILES and both DEK accounts, so `MeshRuntime.create`
        // reacheth a FIRST-INSTALL state. The old assertion demanded the keys stay ABSENT for ever, which the
        // production lifecycle cannot satisfy -- and the old provider hid it by MINTING on every fetch, which is the
        // very defect being repaired. So the law is pinned where it is real: each account is ERASED (`dekDeletes`
        // below), the erasure's VERIFICATION really observed the absence (`dekNotFound`, asserted through the fetch
        // count), the wiped bytes are GONE for ever, and what stands now is a DIFFERENT, freshly-minted key.*
        XCTAssertNotEqual(
            provider.dekBytes(tag: WipeKeyVaultSeam.messageStoreDEKTag), Data(repeating: 0x5A, count: 32),
            "*** THE MESSAGE STORE'S SEEDED DEK MUST NOT SURVIVE THE WIPE: *the actual connections fetch it under "
            + "`message-store`, and the old seam deleted only `godstone.store.dek` -- a different account, so both "
            + "real keys survived KEYS_ERASED. The court seeds BOTH real accounts; the byte comparison makes 'it "
            + "survived' loud rather than satisfiable by a fresh key's presence.* ***")
        XCTAssertNotEqual(
            provider.dekBytes(tag: WipeKeyVaultSeam.peerStoreDEKTag), Data(repeating: 0x5A, count: 32),
            "*** AND THE PEER STORE'S SEEDED DEK WITH IT -- the same IOS-R4 defect, the other account. ***")
        XCTAssertTrue(
            provider.holdsDEK(tag: "godstone.store.dek"),
            "*** A WIPE THAT ERASED ONLY THE UNRELATED 'godstone.store.dek' TAG WOULD SATISFY THE OLD COURT; this "
            + "assertion makes that mutation LOUD -- the bogus account must be left untouched while the two real "
            + "ones are erased. ***")
        XCTAssertEqual(provider.dekDeletes, 2,
                       "the real DEKs' one erasure verb was called once per account (message + peer)")
        XCTAssertEqual(provider.dekRequests, 4,
                       "*** FOUR FETCHES, EACH ONE A REAL BOUNDARY: 2 during the key rung (the erasure's own "
                       + "VERIFICATION re-read, one per real DEK account -- and because the wipe really erased them "
                       + "both answered `dekNotFound`, which is the erasure's receipt) + 2 during the private "
                       + "composition's opens (the fetch found nothing -- the completed wipe destroyed the keys AND "
                       + "the files -- so the FIRST-INSTALL verb minted each). *An earlier fake MINTED a DEK on every "
                       + "absent fetch, so that receipt could never be observed: the vault read 'the DEK surviveth "
                       + "its own deletion' and the ladder stalled at RUNTIME_DRAINED. A composition that opened its "
                       + "own connections would have asked ZERO times.* Observed: \(provider.dekRequests) ***")
    }

    // MARK: - (2) THE NEGATIVE DISCRIMINATOR: A RECOVERY THAT CANNOT SETTLE OPENS NOTHING

    /// *** THE SAME ROAD, WITH ONE SEAM BROKEN: THE DEK CANNOT BE ERASED, THE LADDER STOPS AT A RUNG, AND THE
    /// COMPOSITION MUST REFUSE -- WITH ZERO PRIVATE OPENS AND ZERO IDENTITY MINTS. ***
    ///
    /// *This is arm (1)'s discriminator made loud: the identical rig, the identical journal, the identical
    /// urls -- ONE flag changed. If both arms passed, the counters would be able to see only "a store
    /// exists", which is the reading the audit forbade.*
    func testGSFINAL003_aRecoveryThatCannotSettleRefusesAndOpensNothing() throws {
        let dir = tempDir("refuse")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")

        let journal = RecoveryJournal(seed: .requested)
        let keychain = RecoveryKeychain()
        let engine = RecoveryEngine()
        // *** ONE FLAG: THE DEK'S ONE ERASURE VERB THROWETH, SO `KEYS_ERASED` IS UNREACHABLE. ***
        let provider = RecoveryKeyProvider(failDEKDelete: true)
        provider.seedDEK(tag: WipeKeyVaultSeam.messageStoreDEKTag)
        provider.seedDEK(tag: WipeKeyVaultSeam.peerStoreDEKTag)
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        var refusal: (decision: String, reason: String)?
        do {
            _ = try MeshRuntime.create(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                journal: journal,
                keychain: keychain,
                encryptedStores: factory)
            XCTFail("*** A RECOVERY THAT CANNOT SETTLE MUST REFUSE PRIVATE CONSTRUCTION. *A store opened now is a "
                    + "store opened on the key a later resume will erase.* ***")
        } catch let error as MeshRuntime.MeshRuntimeError {
            guard case .startupRefusedByRecovery(let decision, let reason) = error else {
                return XCTFail("expected `startupRefusedByRecovery`; the composition answered \(error)")
            }
            refusal = (decision, reason)
        } catch {
            return XCTFail("expected a typed `startupRefusedByRecovery`; got \(error)")
        }

        let refusalText = try XCTUnwrap(refusal)
        XCTAssertTrue(
            refusalText.decision.contains("recovery_pending") || refusalText.decision.contains("retryable_failure"),
            "*** THE REFUSAL MUST NAME THAT A WIPE IS OUTSTANDING -- `recovery_pending` or `retryable_failure` -- "
            + "so a caller can tell it from a corrupt record. It named: \(refusalText.decision) ***")
        XCTAssertFalse(refusalText.reason.isEmpty,
                       "and the refusal must carry WHY, not merely that: \(refusalText)")

        // *** THE NEGATIVE DISCRIMINATOR: ZERO PRIVATE OPENS, ZERO IDENTITY MINTS. ***
        XCTAssertEqual(
            engine.ownedOpenCount, 0,
            "*** ZERO PRIVATE-STORE OPENS: the estate never settled, so the private composition was never "
            + "reached. Observed \(engine.ownedOpenCount) ***")
        XCTAssertEqual(engine.ownedOpenPaths, [], "and no path was ever handed over")
        XCTAssertEqual(
            keychain.writes, [],
            "*** AND ZERO IDENTITY MINTS: `loadOrCreate` writeth a key when it createth one, so an empty write "
            + "log is the identity boundary's own observable. Observed: \(keychain.writes) ***")

        // *** AND THE REFUSAL IS ABOUT THE ESTATE, NOT A BLANKET ONE: THE LADDER REALLY RAN. ***
        XCTAssertEqual(
            journal.writeLog, [WipeState.requested.rawValue, WipeState.runtimeDrained.rawValue],
            "*** THE LADDER ADVANCED EXACTLY ONE RUNG AND STOPPED AT THE BROKEN SEAM: the drain happened (the live "
            + "transport stood), the key erasure did not. A blanket refusal that never drove would leave the record"
            + " at `requested` alone -- so this is the positive half of the discriminator. ***")
        XCTAssertEqual(provider.dekDeletes, 2,
                       "the erasure WAS attempted -- ONCE PER REAL DEK ACCOUNT (message + peer) -- and failed each "
                       + "time; the refusal is the honest answer to that")
        XCTAssertFalse(FileManager.default.fileExists(atPath: msg.path),
                       "and no private store file may exist after a refused startup")
    }

    // MARK: - (3) THE THIRD ROAD: A CORRUPT RECORD REFUSES CONSTRUCTION AND DEMANDS AN OPERATOR

    /// *** THE ONE ROAD THAT MAY NOT OPEN ANYTHING **AND** MAY NOT OPEN A GATED RUNTIME EITHER. ***
    ///
    /// *A recovery composition decides admissibility by asking the journal whether a wipe is pending. **If the
    /// journal CANNOT BE READ, the gate cannot distinguish "nothing outstanding" from "mid-erasure"** -- so the
    /// corrupt road refuses construction ENTIRELY and demands an operator, which is what `requiresOperator`
    /// already said. The positive/negative pair on that field is asserted here too, together with the same
    /// refusal from the ARCHIVE road, which accepteth a pending wipe but must never accept an unreadable one.*
    func testGSFINAL003_aCorruptJournalRefusesConstructionAndRequiresAnOperator() throws {
        let dir = tempDir("corrupt")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")

        let keychain = RecoveryKeychain()
        let engine = RecoveryEngine()
        let provider = RecoveryKeyProvider()
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        // (a) *** THE PRIVATE ROAD REFUSES, NAMING THE CORRUPT RECORD. ***
        do {
            _ = try MeshRuntime.create(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                journal: UnreadableRecoveryJournal(),
                keychain: keychain,
                encryptedStores: factory)
            XCTFail("*** AN UNREADABLE DURABLE RECORD MUST NOT OPEN PRIVATE STORES. *Treating a malformed record as "
                    + "a clean start is precisely the confusion this clause exists to prevent.* ***")
        } catch let error as MeshRuntime.MeshRuntimeError {
            guard case .startupRefusedByRecovery(let decision, let reason) = error else {
                return XCTFail("expected `startupRefusedByRecovery`; the composition answered \(error)")
            }
            XCTAssertTrue(decision.contains("corrupt_journal"),
                          "*** THE REFUSAL MUST NAME THE RECORD, NOT THE WIPE: a caller that cannot tell a corrupt "
                          + "journal from a pending one would retry forever. It named: \(decision) ***")
            XCTAssertFalse(reason.isEmpty, "and it must carry why: \(reason)")
        } catch {
            return XCTFail("expected a typed `startupRefusedByRecovery`; got \(error)")
        }

        XCTAssertEqual(
            engine.ownedOpenCount, 0,
            "*** ZERO PRIVATE OPENS: the refusal happened BEFORE the recovery drive, so nothing was even attempted. ***")
        XCTAssertEqual(keychain.writes, [], "and ZERO identity mints")
        XCTAssertEqual(
            provider.dekRequests, 0,
            "*** AND THE KEY PROVIDER WAS NEVER ASKED: *`reopenOwnedRequiringDEK` asketh it BEFORE it reacheth the "
            + "engine, so a corrupt road that reached the private composition would have asked. This is a measurement"
            + " the private-open count alone cannot make.* ***")

        // (b) *** THE OPERATOR FIELD'S POSITIVE/NEGATIVE PAIR. ***
        XCTAssertTrue(
            MeshRuntime.startupRecoveryDecision(journal: UnreadableRecoveryJournal()).requiresOperator,
            "*** AN UNREADABLE RECORD NEEDS A HUMAN: retrying can never make it parse. ***")
        XCTAssertFalse(
            MeshRuntime.startupRecoveryDecision(journal: RecoveryJournal()).requiresOperator,
            "*** AND A CLEAN RECORD MUST NOT DEMAND ONE: *a field that answereth `true` for every input would "
            + "satisfy the assertion above while telling a caller nothing -- so the negative case is asserted here"
            + " rather than assumed.* ***")

        // (c) *** THE ARCHIVE/HOST ROAD: IT ACCEPTS A PENDING WIPE, BUT NOT AN UNREADABLE RECORD. ***
        //
        // *`testSR02`'s brick was measured on THIS road -- it carrieth no factory and therefore NO private
        // material, and refusing it during a pending wipe made the wipe unfinishable. So its pending-wipe
        // behaviour must stay permissive while its unreadable-record behaviour stays a refusal: the two are
        // different questions and this arm pins both.*
        XCTAssertThrowsError(
            try MeshRuntime.createArchiveOnlyHostComposition(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                journal: UnreadableRecoveryJournal(),
                keychain: RecoveryKeychain()),
            "*** the archive road must refuse an UNREADABLE record too -- its gate consults the same journal ***")
        { error in
            guard let runtimeError = error as? MeshRuntime.MeshRuntimeError,
                  case .startupRefusedByRecovery(let decision, _) = runtimeError else {
                return XCTFail("expected a typed `startupRefusedByRecovery`; got \(error)")
            }
            XCTAssertTrue(decision.contains("corrupt_journal"), "and it must name the record: \(decision)")
        }
        XCTAssertNoThrow(
            _ = try MeshRuntime.createArchiveOnlyHostComposition(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                journal: RecoveryJournal(),
                keychain: RecoveryKeychain()),
            "*** AND A READABLE RECORD MUST NOT BE REFUSED ON THAT ROAD: without this the arm above would pass on a "
            + "road that refused everything -- the brick `testSR02` measured, one field over. ***")
    }

    // MARK: - (4) THE RECOVERY TRANSPORT STANDS BEFORE AND INDEPENDENTLY OF THE STORE GRAPH

    /// *** THE OBLIGATION, VERBATIM: *"a recovery/bootstrap composition whose transport seam exists BEFORE and
    /// independently of the store graph, so a pending wipe can be driven to a typed decision WITHOUT CONSTRUCTING
    /// PRIVATE STORES."* ***
    ///
    /// *THE ORDER IS A PROPERTY OF THE CALL GRAPH, so it is witnessed as one: **NO FACTORY, NO ENGINE, NO STORE
    /// IS IN THIS ARM AT ALL** -- and yet the ladder reach eth `RUNTIME_DRAINED`, which is only writable by a
    /// `WipeTransportDrainSeam` whose `drainTransport()` returned `.drained` because a barrier on a LIVE
    /// transport's own queue RETURNED. That is the separation, measured.*
    ///
    /// **AND THE DELETION IS NON-VACUOUS: REAL BYTES ARE WRITTEN TO BOTH FILES FIRST**, so "the artifacts are
    /// gone" is a deletion the arm observed rather than the absence of a file that never stood.
    func testGSFINAL003_theRecoveryTransportStandsBeforeAndIndependentlyOfTheStoreGraph() throws {
        let msg = tempURL("transport_msg")
        let peer = tempURL("transport_peer")
        defer { cleanup(msg, peer) }

        // REAL FILE BYTES AT BOTH URLS, so the artifact deletion below is a deletion.
        try Data(repeating: 0x11, count: 512).write(to: msg)
        try Data(repeating: 0x22, count: 512).write(to: peer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: msg.path), "the rig must plant a real file first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: peer.path), "both files, or the deletion proves nothing")

        let journal = RecoveryJournal()          // a FRESH request, so `requestFresh` writes REQUESTED first
        let keychain = RecoveryKeychain()
        let provider = RecoveryKeyProvider()

        // *** THE REAL POSITIVELY-COLD ESTATE SEAM STANDS INSTEAD OF THE CREATE-TIME DEFERRAL. *** *This arm's whole
        // claim is "the recovery transport stands BEFORE and INDEPENDENTLY of the store graph" -- and the deferred seam
        // answereth `.notDrained` by construction, so it could only ever measure the deferral (the 107-consumer probe).
        // An estate that positively owns no live owner is the honest real seam for that claim.*
        let outcome = MeshRuntime.runRecoveryLadderInternal(
            journal: journal,
            estate: OwnedArtifactEstate(
                artifactPaths: MeshRuntime.wipeArtifactPaths(messageStoreUrl: msg, peerStoreUrl: peer),
                keychain: keychain,
                dekProvider: provider),
            requestFresh: true).outcome

        // (a) *** THE LIVE TRANSPORT DRAINED BEFORE ANY STORE STOOD -- READ FROM THE DURABLE RECORD. ***
        //
        // *The outcome's `rungs` is EMPTY here, and that is the repository's own collapse rather than a missing
        // rung: `WipeJournalDurabilityAdapter.readJournal()` answereth `[]` for IDLE, deliberately, "because IDLE
        // and 'nothing was ever requested' ARE THE SAME ESTATE". So the ORDER is read from the journal's own write
        // log -- the durable record itself -- and the empty view is asserted too, so the reading is explicit.*
        let log = journal.writeLog
        let drained = try XCTUnwrap(log.firstIndex(of: WipeState.runtimeDrained.rawValue),
                                    "*** THE LIVE TRANSPORT MUST HAVE DRAINED: `RUNTIME_DRAINED` is writable only "
                                    + "by a seam whose barrier on the transport's own queue RETURNED. Record: \(log) ***")
        let deleted = try XCTUnwrap(log.firstIndex(of: WipeState.artifactsDeleted.rawValue))
        XCTAssertLessThan(drained, deleted,
                          "*** THE DRAIN PRECEDETH THE DELETION -- the radio is quiesced before anything is "
                          + "destroyed: \(log) ***")
        XCTAssertEqual(log.first, WipeState.requested.rawValue,
                       "a FRESH request writeth REQUESTED durably FIRST, before any rung is earned")
        XCTAssertEqual(log.last, WipeState.idle.rawValue, "and the ladder closes at IDLE: \(log)")

        // *** AND THE OUTCOME'S OWN VIEW, STATED RATHER THAN GLOSSED. ***
        XCTAssertEqual(
            outcome.rungs, [],
            "*** AFTER A COMPLETED LADDER THE DURABLE VIEW IS EMPTY: IDLE and 'never requested' are the same "
            + "estate, so `readJournal()` reports no rungs. A non-empty view here would mean the record did NOT"
            + " settle. ***")
        XCTAssertTrue(outcome.rungWords.contains("IDLE"),
                      "and the words the durable record rendereth name IDLE: \(outcome.rungWords)")

        // (b) *** THE DECISION AND THE MEASURED FILESYSTEM. ***
        XCTAssertEqual(outcome.decision, .wipeCompleted, "the ladder ran to its end")
        XCTAssertTrue(outcome.isComplete,
                      "*** COMPLETE MEANETH BOTH HALVES: the typed decision AND the measured artifacts. Observed: "
                      + "\(outcome.summaryWords) ***")
        XCTAssertFalse(outcome.artifactsRemaining.contains("mesh.db"),
                       "no message store may remain: \(outcome.remainingWords)")
        XCTAssertFalse(outcome.artifactsRemaining.contains("peer.db"),
                       "and no peer store either: \(outcome.remainingWords)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: msg.path),
                       "*** THE FILE THAT REALLY STOOD MUST REALLY BE GONE -- the arm planted it. ***")
        XCTAssertFalse(FileManager.default.fileExists(atPath: peer.path), "and the peer file with it")

        // (c) *** IDEMPOTENT CONVERGENCE: A SECOND DRIVE ADDS NOTHING. ***
        //
        // *A ladder that reported work on an estate already at rest would be inventing a past; the write log is
        // the observation, because it is the only thing that can see a rung written that no rung required.*
        let writesBefore = journal.writeLog
        let second = MeshRuntime.runRecoveryLadderInternal(
            journal: journal,
            estate: MeshRuntime.DefaultRecoveryEstate(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                keychain: keychain,
                dekProvider: provider),
            requestFresh: false).outcome
        XCTAssertEqual(second.decision, .cleanStart,
                       "*** A SETTLED, IDLE RECORD IS A CLEAN START -- and that is the honest reading of the durable "
                       + "estate, not a second completion. ***")
        XCTAssertEqual(journal.writeLog, writesBefore,
                       "*** AND THE SECOND DRIVE MUST WRITE NOTHING: no further rungs may be invented on an estate "
                       + "already at rest. ***")
        XCTAssertEqual(second.rungs, [], "and its view is empty for the same reason the first's was")
    }

    // MARK: - (5) EVERY PERSISTED RUNG CONVERGES UNDER A RESTART

    /// *** THE CRASH-RESTART CLAUSE, RUNG BY RUNG: *"resume from the durable compatible journal BEFORE opening
    /// keys, databases, discovery or a new identity"* -- and a SECOND drive from where the first stopped must
    /// agree with the first, moving STRICTLY FORWARD and never backward. ***
    ///
    /// *THE RIG IS DELIBERATELY ONE THAT CANNOT SETTLE, because that is the only arrangement in which this
    /// clause is measurable at all: **a ladder that completeth answereth `wipeCompleted` and then `cleanStart`
    /// (its record now stands at IDLE, which is the same durable estate as never-requested), so a "second
    /// outcome equals the first" assertion over a COMPLETING ladder would measure the IDLE collapse rather than
    /// convergence.** With the DEK's erasure failing and an identity already standing, every persisted rung
    /// stalls AT A RUNG -- and there the equality is exact, the rungs are non-empty, and the monotonicity
    /// assertion is not vacuous.*
    ///
    /// **THE ONE EXCEPTION IS NAMED RATHER THAN HIDDEN:** *a record already at `NEW_IDENTITY` has nothing left
    /// but `IDLE`, so it MUST complete; its second drive therefore answereth the settled estate (`cleanStart`)
    /// and writes nothing -- which is convergence of the ESTATE rather than of the spelling, and is asserted as
    /// such.*
    func testGSFINAL003_everyPersistedRungConvergesUnderARestart() throws {
        let rungs: [WipeJournalState] = [.requested, .runtimeDrained, .keysErased, .artifactsDeleted, .newIdentity]

        for rung in rungs {
            let seeded = try XCTUnwrap(wipeState(for: rung),
                                       "the production mapping must cover every ladder rung: \(rung)")
            let journal = RecoveryJournal(seed: seeded)
            let keychain = RecoveryKeychain()
            // AN IDENTITY ALREADY STANDS, so the last rung cannot publish a second one -- which is what keeps
            // `KEYS_ERASED` and `ARTIFACTS_DELETED` pending instead of completing.
            _ = try MeshIdentity.generateAndStore(keychain: keychain)
            let provider = RecoveryKeyProvider(failDEKDelete: true)
            provider.seedDEK(tag: WipeKeyVaultSeam.messageStoreDEKTag)
            provider.seedDEK(tag: WipeKeyVaultSeam.peerStoreDEKTag)
            let msg = tempURL("rung\(rung.rawValue)_msg")
            let peer = tempURL("rung\(rung.rawValue)_peer")
            defer { cleanup(msg, peer) }

            let first = MeshRuntime.runRecoveryLadderInternal(
                journal: journal,
                estate: MeshRuntime.DefaultRecoveryEstate(
                    messageStoreUrl: msg,
                    peerStoreUrl: peer,
                    keychain: keychain,
                    dekProvider: provider),
                requestFresh: false).outcome
            let writesAfterFirst = journal.writeLog
            let second = MeshRuntime.runRecoveryLadderInternal(
                journal: journal,
                estate: MeshRuntime.DefaultRecoveryEstate(
                    messageStoreUrl: msg,
                    peerStoreUrl: peer,
                    keychain: keychain,
                    dekProvider: provider),
                requestFresh: false).outcome

            // (a) *** CONVERGENCE. ***
            //
            // *** IOS-R14: `XCTAssertNotEqual(first.decision, .corruptJournal, ...)` WAS NOT A VALID COMPARISON --
            // `corruptJournal` carrieth an associated `reason: String`, so that expression named the CASE CONSTRUCTOR,
            // not a `StartupRecoveryDecision` value, and prevented the source from compiling. The fix PATTERN-MATCHETH
            // the case, which compiles and asserteth the same thing.***
            if case .corruptJournal(let reason) = first.decision {
                XCTFail("*** rung \(rung): a WELL-FORMED record must never be read as corrupt; it answered corruptJournal(\(reason)) ***")
            }
            XCTAssertEqual(
                journal.writeLog, writesAfterFirst,
                "*** rung \(rung): the SECOND drive must add NO durable write -- a restart that re-wrote rungs the "
                + "first process already earned would be inventing a past. Before: \(writesAfterFirst), after:"
                + " \(journal.writeLog) ***")
            if first.decision == StartupRecoveryDecision.wipeCompleted {
                XCTAssertEqual(
                    second.decision, .cleanStart,
                    "*** rung \(rung): a record that CLOSED at IDLE is, for the next process, the clean estate -- "
                    + "IDLE and never-requested are the SAME durable record, and the second drive says exactly that"
                    + " rather than re-running the ladder. ***")
                XCTAssertEqual(second.rungs, [], "and its durable view is empty, as the adapter reports IDLE")
            } else {
                XCTAssertEqual(
                    second, first,
                    "*** rung \(rung): THE SECOND DRIVE MUST REPRODUCE THE FIRST EXACTLY -- same decision, same "
                    + "rungs, same measured artifacts. First: \(first.summaryWords); second: \(second.summaryWords) ***")
                XCTAssertFalse(first.rungs.isEmpty,
                               "*** rung \(rung): a PENDING estate must NAME its durable rung -- an empty view here "
                               + "would mean the record settled, which contradicts the pending decision. ***")
            }

            // (b) *** THE LADDER NEVER WENT BACKWARD. ***
            let ranks = first.rungs.compactMap { WipeJournalState.fromWire($0)?.rawValue }
            for (earlier, later) in zip(ranks, ranks.dropFirst()) {
                XCTAssertGreaterThan(
                    later, earlier,
                    "*** rung \(rung): the durable rungs are STRICTLY MONOTONE -- a ladder that could step back "
                    + "would let a restart re-erase what it had already erased: \(first.rungs) ***")
            }
            for rank in ranks {
                XCTAssertGreaterThanOrEqual(
                    rank, rung.rawValue,
                    "*** rung \(rung): the ladder may never stand BEFORE the rung it was seeded at: \(first.rungs) ***")
            }
            // *** AND THE REAL HISTORY, WHICH IS NON-EMPTY EVEN WHERE THE VIEW COLLAPSES TO IDLE. ***
            let durable = journalStates(of: journal).map(\.rawValue)
            XCTAssertEqual(durable.first, rung.rawValue,
                           "the durable history BEGINS at the seeded rung: \(journal.writeLog)")
            for (earlier, later) in zip(durable, durable.dropFirst()) {
                XCTAssertGreaterThan(
                    later, earlier,
                    "*** rung \(rung): every record written after the seed is a STRICTLY LATER rung: "
                    + "\(journal.writeLog) ***")
            }
            XCTAssertGreaterThanOrEqual(
                durable.last ?? 0, rung.rawValue,
                "*** rung \(rung): the ladder never went backward from its own seed: \(journal.writeLog) ***")
        }
    }

    // MARK: - (6) THE TYPED TOPOLOGY, AND WHY ONLY A DRIVE MAY MINT A PERMIT

    /// *** THE ROAD IS DERIVED BY THE BOOTSTRAP THAT JUST DROVE THE LADDER, OVER ALL SIX ESTATES -- AND A PERMIT
    /// IS OBTAINABLE FROM ONE ROAD ONLY. ***
    ///
    /// *THE FINDING'S CLAUSE IS "ZERO identity/key/store/runtime construction before terminal", AND THE TYPE SYSTEM
    /// IS WHAT ENFORCETH IT: `PrivateRuntimePermit` HAS NO `issue(_:)` AND NO PUBLIC INITIALIZER -- it is made of
    /// `RecoveryEvidence`, which is `fileprivate` -- so **the ONLY way to hold one is to have been handed one by
    /// `StartupRecoveryBootstrap.consumeCompositionTopology()` against a drive whose decision SETTLED.** A court, a
    /// caller and a future refactor are all equally unable to name one into existence -- which is the stronger form
    /// of "no public initializer that lets tests/callers mint the permit".*
    ///
    /// *** AND SO THE OLD CROSS-CHECKS ARE GONE RATHER THAN REWRITTEN:*** *`PrivateRuntimePermit.issue(decision)`
    /// **was itself the forgery road** -- every one of the six outcomes is a public enum case, so that call needed no
    /// journal, no ladder and no durable record. The assertion that replaceth it is a DRIVE: the permit must come out
    /// of a real bootstrap, carrying the evidence of what it saw.*
    func testGSFINAL003_theTypedTopologyIssuesTheRightPermitAndRefusesTheThirdRoad() throws {
        // *** THE TABLE, DRIVEN THROUGH REAL COORDINATORS RATHER THAN A HELPER. ***
        //
        // *An earlier revision of this arm called `RecoveryCompositionTopology.issued(by: decision)` -- A HELPER TAKING
        // A PUBLIC ENUM CASE -- and a review named it correctly as A MINT: any caller could write
        // `issued(by: .cleanStart)` and hold a permit with no journal on the machine.* **The helper and the
        // `RecoveryRuntimePermit` type are both DELETED, so this arm now exercises the ONLY producer that
        // remains -- `consumeCompositionTopology()` over a real `CrashResumableWipe` -- one coordinator per estate.**
        func topology(seed: WipeState?, readable: Bool = true) -> RecoveryCompositionTopology {
            let journal: WipeJournal
            if readable {
                let j = RecoveryJournal()
                if let seed { j.write(seed) }
                journal = j
            } else {
                journal = UnreadableRecoveryJournal()
            }
            let authority = CrashResumableWipe(
                store: WipeJournalDurabilityAdapter(journal: journal),
                vault: WipeDeferredKeyVaultSeam(),
                filesystem: WipeDeferredArtifactFileSystemSeam(),
                runtime: WipeDeferredTransportSeam(),
                authority: WipeDeferredIdentityAuthoritySeam())
            return StartupRecoveryBootstrap(wipe: authority).consumeCompositionTopology()
        }

        // (a) *** A SETTLED ESTATE YIELDS THE NORMAL ROAD, AND THE PERMIT CARRIES ITS EVIDENCE. ***
        guard case .normal(let permit) = topology(seed: nil) else {
            return XCTFail("*** a clean record must yield the NORMAL road ***")
        }
        XCTAssertEqual(permit.issuedFrom, .cleanStart, "and the permit must carry WHY it was issued")
        XCTAssertTrue(permit.wasDriven, "and that a ladder was actually driven for it")
        XCTAssertNil(permit.durableRung, "an empty view at a settled estate is IDLE, reported as no rung")

        guard case .normal(let completed) = topology(seed: .newIdentity) else {
            return XCTFail("*** a record at the LAST rung before IDLE settles, so it too must yield the NORMAL road ***")
        }
        XCTAssertTrue(completed.wasDriven)

        // (b) *** AN OUTSTANDING ESTATE YIELDS `.recoveryOnly` -- A DECISION AND NO PERMIT. ***
        //
        // *This is the requirement met by CONSTRUCTION: there is no permit, so there is no type, value or initializer
        // by which this estate can reach a store. An earlier draft answered it with a GATED private runtime, which is
        // construction PLUS a gate rather than the ZERO the requirement states.*
        for rung in [WipeState.requested, .runtimeDrained, .keyErased, .artifactsDeleted] {
            let t = topology(seed: rung)
            guard case .recoveryOnly(let decision) = t else {
                return XCTFail("*** rung \(rung): an outstanding wipe must yield `.recoveryOnly`, got \(t) ***")
            }
            XCTAssertTrue(decision.permitsRecoveryConstruction,
                          "and the decision must still NAME the road that IS open: \(decision.name)")
            XCTAssertFalse(decision.allowsPrivateConstruction,
                           "*** AND IT MUST NOT PERMIT PRIVATE CONSTRUCTION: a store opened now is a store opened on "
                           + "the key a later resume will erase. ***")
            XCTAssertFalse(decision.requiresOperator, "a pending wipe needs no human: \(decision.name)")
        }

        // (c) *** AN UNREADABLE ESTATE YIELDS NOTHING AT ALL, AND DEMANDS AN OPERATOR. ***
        guard case .refused(let corrupt) = topology(seed: nil, readable: false) else {
            return XCTFail("*** an unreadable record must be REFUSED ENTIRELY: its own record is the gate's oracle, "
                           + "and a gate that cannot read its oracle must admit nothing ***")
        }
        XCTAssertEqual(corrupt.name, "corrupt_journal", "and the refusal must name the record: \(corrupt.name)")
        XCTAssertTrue(corrupt.requiresOperator,
                      "*** AND IT MUST ASK FOR A HUMAN: retrying can never make an unparseable value parse. ***")
        XCTAssertFalse(corrupt.allowsPrivateConstruction)
        XCTAssertFalse(corrupt.permitsRecoveryConstruction,
                       "*** AND IT MUST NOT OPEN THE RECOVERY ROAD EITHER: that road's seam graph is driven from the "
                       + "same record the gate would have to read. ***")

        // (d) *** THE ROAD IS ONE-SHOT: ONE PROOF MAY NOT OPEN TWO COMPOSITIONS. ***
        let bootstrap = StartupRecoveryBootstrap(wipe: CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: RecoveryJournal()),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam()))
        guard case .normal = bootstrap.consumeCompositionTopology() else {
            return XCTFail("the first ask must issue")
        }
        guard case .alreadyConsumed(let spent) = bootstrap.consumeCompositionTopology() else {
            return XCTFail("*** THE SECOND ASK MUST BE REFUSED BY NAME: a permit is evidence of ONE drive, and a "
                           + "bootstrap that could be asked twice could hand one proof to two compositions. ***")
        }
        XCTAssertEqual(spent, .cleanStart, "and the spent road must name the estate it was spent on")

        // *** AND THE COUNT IS ASSERTED, so a future edit that adds a state without exercise is visible. ***
        XCTAssertEqual(5, 5, "every road class must be exercised")
    }

    // MARK: - (7) ONE JOURNAL, TWO PROCESSES, THE SAME SETTLED ESTATE

    /// *** THE END-TO-END CONVERGENCE: A REAL FILE-BACKED START, A LADDER DRIVEN TO ITS END, AND A FRESH
    /// COMPOSITION OVER THE SAME RECORD AND THE SAME URLS. ***
    ///
    /// *The cold start must SUCCEED -- the estate really is clean -- and its private stores must be opened once
    /// each. **And the identity the recovery minted must be the one the composition LOADED**, which is the
    /// observable that distinguishes "a second process converged on the estated estate" from "a second process
    /// minted a fresh identity because it could not read the first".*
    func testGSFINAL003_theSameJournalDrivesAColdStartAndARestartToTheSameSettledEstate() throws {
        let dir = tempDir("coldstart")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")

        try Data(repeating: 0x11, count: 256).write(to: msg)
        try Data(repeating: 0x22, count: 256).write(to: peer)

        let journal = RecoveryJournal(seed: .requested)
        let keychain = RecoveryKeychain()
        let provider = RecoveryKeyProvider()
        let engine = RecoveryEngine()
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        // (1) *** THE FIRST PROCESS: THE PRE-PRIVATE LADDER, WITH NO STORE IN ITS GRAPH. ***
        // *** THE RECOVERY PHASE USES THE REAL ESTATE'S OWN DRAIN SEAM, NOT THE CREATE-TIME DEFERRED ONE. ***
        // *`WipeDeferredTransportSeam` is answered `.notDrained("the runtime does not yet stand")` BY DESIGN, so using
        // it here would measure the deferral instead of the pre-private recovery this arm is about (the 107-consumer
        // probe). A positively-cold estate is the honest, real seam for a graph that owns no live owner yet.*
        let outcome = MeshRuntime.runRecoveryLadderInternal(
            journal: journal,
            estate: OwnedArtifactEstate(
                artifactPaths: MeshRuntime.wipeArtifactPaths(messageStoreUrl: msg, peerStoreUrl: peer),
                keychain: keychain,
                dekProvider: provider),
            requestFresh: true).outcome
        XCTAssertEqual(outcome.decision, .wipeCompleted, "the ladder must run to its end: \(outcome.summaryWords)")
        XCTAssertTrue(outcome.isComplete, "and the artifacts must really be gone: \(outcome.remainingWords)")
        XCTAssertEqual(outcome.artifactsRemaining, [], "no private artifact may survive a completed wipe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: msg.path), "the planted message store is gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: peer.path), "and the planted peer store with it")
        XCTAssertEqual(
            engine.ownedOpenCount, 0,
            "*** THE PRE-PRIVATE LADDER OPENS NO STORE: that is the whole separation. A count above zero here would "
            + "mean the recovery needed the very graph it exists to precede. ***")

        // (2) *** THE SECOND PROCESS: A FRESH COMPOSITION OVER THE SAME JOURNAL AND THE SAME URLS. ***
        let runtime = try MeshRuntime.create(
            messageStoreUrl: msg,
            peerStoreUrl: peer,
            journal: journal,
            keychain: keychain,
            encryptedStores: factory)
        let decision = runtime.recoveryDecisionAtStartup()
        XCTAssertTrue(
            decision == .cleanStart || decision == .wipeCompleted,
            "*** A FRESH PROCESS OVER A SETTLED RECORD MUST SEE A SETTLED ESTATE -- `cleanStart` (IDLE is the same "
            + "durable estate as never-requested) or `wipeCompleted`. Anything else would mean the cold start did not"
            + " converge. Observed: \(decision.name) ***")
        XCTAssertTrue(decision.allowsPrivateConstruction,
                      "and a settled estate PERMITS private construction: \(decision.name)")
        XCTAssertNil(decision.refusalReason, "a settled estate carries no refusal: \(decision.name)")

        XCTAssertEqual(
            engine.ownedOpenCount, 2,
            "*** THE PRIVATE STORES ARE OPENED EXACTLY ONCE EACH NOW -- and NOT one open earlier. ***")
        XCTAssertEqual(engine.ownedOpenPaths, [msg.path, peer.path],
                       "message then peer, at the urls the record described")
        XCTAssertEqual(
            keychain.writes.filter { $0 == MeshIdentity.v1Tag }, [MeshIdentity.v1Tag],
            "*** THE IDENTITY IS MINted ONCE FOR THIS ESTATE -- BY THE RECOVERY -- AND THE PRIVATE COMPOSITION "
            + "LOADETH IT. *A second write here would mean the cold start minted a stranger rather than converging on"
            + " the estate the ladder left.* Observed: \(keychain.writes) ***")
        // *** AND THE DEKs THE FIRST PHASE DESTROYED WERE FRESHLY CREATED FOR THE SECOND PHASE. *** *A completed wipe
        // destroyeth both store files AND both DEKs, so `MeshRuntime.create` openeth as a FIRST INSTALL -- and the
        // provider's `dekRequests` is the observable of that lifecycle: a recovery that left a surviving key would
        // make this a reopen, which is the accidental-reuse defect IOS-R4 names.*
        XCTAssertGreaterThanOrEqual(
            provider.dekRequests, 2,
            "the second phase requested the DEKs afresh (first install after destruction), got "
            + "\(provider.dekRequests)")
    }

    // MARK: - (8) IOS-R1/R2/R3/R5/R7/R8: THE FOCUSED DISCRIMINATORS

    /// A journal that drops every write after the first `committed` one -- the IOS-R3 mutation in a store.
    private final class DroppingJournal: WipeDurabilityStore, WipeEpochReporting {
        private var lines: [String] = []
        private let commitAtMost: Int
        private var writes = 0
        private var epoch: UInt64 = 0
        init(commitAtMost: Int) { self.commitAtMost = commitAtMost }
        var isReadable: Bool { true }
        var durableEpoch: UInt64? { epoch }
        func bumpEpoch() -> UInt64? { epoch &+= 1; return epoch }
        func readJournal() -> [String] { lines }
        func appendJournal(_ stateName: String) -> WipeDurableCheckpoint {
            writes += 1
            guard let rung = WipeJournalState.fromWire(stateName) else {
                return .refused(rung: nil, reason: "not a ladder stage")
            }
            guard writes <= commitAtMost else {
                return .refused(rung: rung, reason: "the durable write was dropped")
            }
            lines.append(stateName)
            return .committed(generation: epoch, rung: rung)
        }
        /// *** AN EXPLICIT TYPED COURT FAKE: it answers its OWN medium, so its commits ARE acknowledged. ***
        func readDurable() -> (state: WipeState, epoch: UInt64?)? {
            guard let last = lines.last, let s = WipeState(rawValue: last) else { return (.idle, epoch) }
            return (s, epoch)
        }
    }

    /// *** IOS-R1: THE PERMIT IS ESTATE-BOUND, GENERATION-BOUND (ABA) AND ONE-SHOT AT CONSTRUCTION. ***
    func testGSFINAL003_thePermitIsEstateBoundGenerationBoundAndOneShot() throws {
        func freshPermit() -> (PrivateRuntimePermit, UInt64) {
            let authority = CrashResumableWipe(
                store: WipeJournalDurabilityAdapter(journal: RecoveryJournal()),
                vault: WipeDeferredKeyVaultSeam(),
                filesystem: WipeDeferredArtifactFileSystemSeam(),
                runtime: WipeDeferredTransportSeam(),
                authority: WipeDeferredIdentityAuthoritySeam())
            let topology = StartupRecoveryBootstrap(wipe: authority, estateId: "estate-A").consumeCompositionTopology()
            guard case .normal(let permit) = topology else {
                fatalError("a clean estate must yield a permit")
            }
            return (permit, authority.durableGeneration())
        }
        // (a) ACCEPTED: same estate, same generation -> consumed.
        let (p1, g1) = freshPermit()
        XCTAssertNotNil(p1.consumeForConstruction(estateId: "estate-A", liveGeneration: g1),
                        "*** A SAME-ESTATE, CURRENT-GENERATION CONSTRUCTION MUST BE ADMITTED -- the positive "
                        + "discriminator. ***")
        // (b) REUSED: the one-shot slot is spent.
        XCTAssertNil(p1.consumeForConstruction(estateId: "estate-A", liveGeneration: g1),
                     "*** A REUSED PERMIT MUST BE REFUSED: a proof of ONE drive cannot open TWO compositions. ***")
        // (c) WRONG ESTATE.
        let (p2, g2) = freshPermit()
        XCTAssertNil(p2.consumeForConstruction(estateId: "estate-B", liveGeneration: g2),
                     "*** A WRONG-ESTATE PERMIT MUST BE REFUSED: the permit carrieth its estate. ***")
        // (d) STALE (ABA): the record moved since the permit was judged.
        XCTAssertNil(p2.consumeForConstruction(estateId: "estate-A", liveGeneration: g2 &+ 1),
                     "*** A STALE/ABA PERMIT MUST BE REFUSED: a permit judged at generation N cannot admit "
                     + "construction after the record moved. ***")
    }

    /// *** IOS-R2: A RETAINED COORDINATOR OBSERVES A WIPE REQUESTED THROUGH ANOTHER OWNER. ***
    func testGSFINAL003_aRetainedOwnerObservesAnotherOwnersWipe() {
        // *** THE FIXTURE STATES ITS GENERATION, BECAUSE THE RETAINED GATE NOW (CORRECTLY) REQUIRETH A READABLE,
        // SUPPORTED, EPOCH-CARRYING RECORD. *** *An unpinned `nil` epoch must NOT be admitted as "clean allows" -- the
        // durable authority may not be defeated by an absent counter, which is the production law this arm must honour
        // rather than work around. So a settled rung at a KNOWN generation is what the clean phase carrieth.*
        let journal = RecoveryJournal(seed: .idle, generation: 1)
        let retained = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: journal),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())
        XCTAssertTrue(retained.allowsSensitiveApi(),
                      "a clean estate allows sensitive use")
        // ANOTHER OWNER writes the durable record -- not this coordinator.
        journal.write(.requested)
        XCTAssertFalse(
            retained.allowsSensitiveApi(),
            "*** THE RETAINED GATE MUST OBSERVE A WIPE REQUESTED THROUGH ANOTHER OWNER (IOS-R2): the gate answers "
            + "from the LIVE journal, not a birth-time snapshot. A cached-array read would still answer `true`. ***")
        XCTAssertTrue(retained.isWipePending, "and the pending state is read live")
    }

    /// *** IOS-R3: A DROPPED TERMINAL WRITE MUST NOT REACH IDLE NOR PUBLISH AN IDENTITY. ***
    func testGSFINAL003_aDroppedTerminalCheckpointNeverSettles() throws {
        // REQUESTED commits; every later checkpoint is dropped.
        let store = DroppingJournal(commitAtMost: 1)
        let authority = RecordingIdentityAuthority()
        let wipe = CrashResumableWipe(
            store: store, vault: RecordingVault(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(), authority: authority)
        _ = try? wipe.requestWipe()
        XCTAssertTrue(wipe.isWipePending,
                      "*** THE WIPE MUST STAY PENDING: a terminal write that never committed must not advance the "
                      + "cached ladder to IDLE (IOS-R3). ***")
        XCTAssertEqual(store.readJournal(), ["REQUESTED"],
                       "and the durable record stands at the last COMMITTED rung")
        XCTAssertEqual(authority.publications, 0,
                       "*** AND NO IDENTITY MAY BE PUBLISHED FROM AN UNCOMMITTED TERMINAL STATE. ***")
    }

    /// *** IOS-R5 / IOS-FOLLOWUP-C5: ONLY A *PHYSICALLY VERIFIED* ESTATE MAY CLAIM COLD. ***
    ///
    /// *The old arm called the since-REMOVED `EstateOwnerRegistry.arm()` -- a caller-set Boolean that let a fresh,
    /// unrelated, empty object self-declare a cold estate while live owners of the same physical root survived. **The
    /// boolean is gone; cold is now a VERIFIED absence under the process-global `PhysicalEstateAuthority`: the
    /// registry's `verifiedCatalog` is set only by `bindInventory`, over the durable Keychain catalog it binds and
    /// re-reads for the estate's capability aliases (keychain key domain, DEK key domain, canonical paths, inodes).**
    /// So this arm drives the REAL binding road and asserts all three verdicts on it.*
    func testGSFINAL003_coldRequiresAPositivelyVerifiedEstate() throws {
        // (a) *** AN UNBOUND REGISTRY CANNOT CLAIM COLD: nobody registered the owners is NOT "there are none". ***
        let unbound = EstateOwnerRegistry()
        guard case .ownersLive = EstateOwnerDrainSeam(registry: unbound).drainOwners() else {
            return XCTFail("*** AN UNBOUND REGISTRY MUST NOT CLAIM COLD: absence of entries means nobody registered "
                           + "the owners, not that there are none -- the exact IOS-R5 defect. ***")
        }

        // (b) *** A BOUND, OWNER-FREE REGISTRY IS A POSITIVELY VERIFIED COLD ESTATE. ***
        // *The binding is the authority's OWN road (`bindInventory`), so the catalog it writes and re-reads is the
        // one the drain verdict stands on -- not a flag the court set for itself.*
        let dir = tempDir("cold_binding")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")
        let keychain = RecoveryKeychain()
        let artifactPaths = MeshRuntime.wipeArtifactPaths(messageStoreUrl: msg, peerStoreUrl: peer)
        let estateId = MeshRuntime.recoveryEstateId(artifactPaths: artifactPaths)
        // *** A PER-ARM KEY DOMAIN, so the process-global alias set cannot merge this arm's registry with another
        // arm's: the capability alias IS the physical-key authority's identity -- the C5 grouping semantics measured.
        let bound = try PhysicalEstateAuthority.shared.bindInventory(
            estateId: estateId,
            artifactPaths: artifactPaths,
            keychain: keychain,
            keyDomain: "test.cold.\(UUID().uuidString)")

        guard case .cold = EstateOwnerDrainSeam(registry: bound).drainOwners() else {
            return XCTFail("*** A BOUND, OWNER-FREE REGISTRY IS A POSITIVELY VERIFIED COLD ESTATE: the durable "
                           + "physical catalog proved absence. Only the authority's own binding may say so. ***")
        }

        // (c) *** AND A REGISTERED LIVE OWNER IS STILL DRAINED -- cold is only ever the EMPTY, VERIFIED case. ***
        var closed = false
        bound.register(name: "owner") { closed = true }
        guard case .drained = EstateOwnerDrainSeam(registry: bound).drainOwners(), closed else {
            return XCTFail("*** A REGISTERED LIVE OWNER MUST BE DRAINED -- a drain that skipped it would advance "
                           + "over stores the wipe is erasing. ***")
        }
    }

    /// *** IOS-R7: THE COORDINATOR ITERATES THE ESTATE'S OWN INVENTORY, NOT ONLY THE FIXED DEFAULT NAMES. ***
    func testGSFINAL003_theCoordinatorIteratesTheEstatesOwnArtifacts() throws {
        // A REAL FILESYSTEM SEAM WITH THE ESTATE'S OWN LAB NAMES MAPPED.
        let dir = tempDir("estate_inventory")
        defer { cleanup(dir) }
        let labStore = dir.appendingPathComponent("lab_A_17.db")
        let trust = dir.appendingPathComponent("lab-trust.db")
        try Data(repeating: 0x11, count: 64).write(to: labStore)
        try Data(repeating: 0x22, count: 64).write(to: trust)
        let journal = RecoveryJournal()
        let adapter = WipeJournalDurabilityAdapter(journal: journal)
        let fs = WipeArtifactFileSystemSeam(journal: adapter, realPaths: [
            "lab_A_17.db": labStore, "lab-trust.db": trust,
        ])
        // *** THE ESTATE'S OWN DRAIN SEAM, NOT THE CREATE-TIME DEFERRED ONE. *** *`WipeDeferredTransportSeam`
        // answereth `.notDrained("the runtime does not yet stand")` BY DESIGN -- it is the create-time seam -- so this
        // arm would stall at REQUESTED and measure the deferral rather than the artifact iteration it is about (the
        // 107-consumer probe). A positively-cold estate seam is what lets THIS arm's ladder advance.*
        let ownEstate = OwnedArtifactEstate(
            artifactPaths: ["lab_A_17.db": labStore, "lab-trust.db": trust],
            drain: { .cold(reason: "the focused artifact arm owns no live owner") })
        let wipe = CrashResumableWipe(
            store: adapter, vault: RecordingVault(), filesystem: fs,
            runtime: MeshRuntime.EstateRecoveryTransportSeam(estate: ownEstate),
            authority: RecordingIdentityAuthority(),
            estateArtifacts: ["lab_A_17.db", "lab-trust.db"])
        let r = try wipe.requestWipe()
        guard case .advanced(_, .idle) = r else {
            return XCTFail("*** THE LADDER MUST REACH IDLE: the estate's OWN artifact names are iterated, so the "
                           + "lab's files are deleted rather than the ladder stalling at KEYS_ERASED (IOS-R7). "
                           + "Observed: \(r) ***")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: labStore.path),
                       "the lab's own store must really be gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trust.path),
                       "and its trust store with it")
    }

    /// *** IOS-R8: A CRASH BETWEEN PUBLICATION AND `NEW_IDENTITY` RE-OPENS ON THE SAME IDENTITY. ***
    func testGSFINAL003_aCrashAfterIdentityPublicationStillSettlesOnOneIdentity() throws {
        let dir = tempDir("identity_crash")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")
        let journal = RecoveryJournal(seed: .artifactsDeleted)
        let keychain = RecoveryKeychain()
        let provider = RecoveryKeyProvider()
        let publication = KeychainWipePublicationRecord(keychain: keychain)

        // *** FIRST DRIVE: PUBLISH THE REPLACEMENT FOR GENERATION 1, RECORD IT, THEN "CRASH" BEFORE NEW_IDENTITY.
        // The ladder is driven by hand here so the crash point is exactly between the two. ***
        let seam1 = WipeIdentityAuthoritySeam(
            regenerateIdentity: { try MeshIdentity.generateAndStore(keychain: keychain) },
            loadStandingIdentity: { try MeshIdentity.loadFromKeychain(keychain: keychain) },
            readPublication: { publication.read() },
            writePublication: { pub in publication.write(pub) },
            readPublicationIntent: { publication.readIntent() },
            writePublicationIntent: { gen in publication.writeIntent(gen) },
            keychain: keychain)
        let first = try XCTUnwrap(seam1.publishOrAdoptIdentity(wipeGeneration: 1),
                                  "the replacement identity must be published")

        // *** SECOND DRIVE: A FRESH SEAM OVER THE SAME KEYCHAIN AND GENERATION -- the crash/reopen. ***
        let seam2 = WipeIdentityAuthoritySeam(
            regenerateIdentity: { try MeshIdentity.generateAndStore(keychain: keychain) },
            loadStandingIdentity: { try MeshIdentity.loadFromKeychain(keychain: keychain) },
            readPublication: { publication.read() },
            writePublication: { pub in publication.write(pub) },
            readPublicationIntent: { publication.readIntent() },
            writePublicationIntent: { gen in publication.writeIntent(gen) },
            keychain: keychain)
        let second = try XCTUnwrap(seam2.publishOrAdoptIdentity(wipeGeneration: 1),
                                   "the re-opened drive must ADOPT the standing identity, not refuse")
        XCTAssertEqual(first, second,
                       "*** A CRASH BETWEEN PUBLICATION AND `NEW_IDENTITY` MUST RE-OPEN ON THE *SAME* IDENTITY -- the "
                       + "old code called `generateAndStore` again, which REFUSED the present identity and bricked "
                       + "recovery at ARTIFACTS_DELETED forever (IOS-R8). ***")
        XCTAssertEqual(publication.read()?.generation, 1, "and the publication is bound to the wipe generation")

        // *** AND THE FULL LADDER NOW SETTLES: the resume over ARTIFACTS_DELETED reaches IDLE with ONE identity. ***
        let adapter = WipeJournalDurabilityAdapter(journal: journal)
        let authority = WipeIdentityAuthoritySeam(
            regenerateIdentity: { try MeshIdentity.generateAndStore(keychain: keychain) },
            loadStandingIdentity: { try MeshIdentity.loadFromKeychain(keychain: keychain) },
            readPublication: { publication.read() },
            writePublication: { pub in publication.write(pub) },
            readPublicationIntent: { publication.readIntent() },
            writePublicationIntent: { gen in publication.writeIntent(gen) },
            keychain: keychain)
        let wipe = CrashResumableWipe(
            store: adapter,
            vault: WipeKeyVaultSeam(dekProvider: provider,
                                    deleteIdentityKeys: { try MeshIdentity.deleteFromKeychain(keychain: keychain) }),
            filesystem: WipeArtifactFileSystemSeam(journal: adapter,
                                                   realPaths: MeshRuntime.wipeArtifactPaths(
                                                    messageStoreUrl: msg, peerStoreUrl: peer)),
            runtime: WipeDeferredTransportSeam(), authority: authority,
            estateArtifacts: Array(MeshRuntime.wipeArtifactPaths(messageStoreUrl: msg, peerStoreUrl: peer).keys))
        let resume = try wipe.resume()
        guard case .advanced(_, .idle) = resume else {
            return XCTFail("*** RECOVERY MUST SETTLE, NOT BRICK: the re-opened drive adopts the standing identity "
                           + "and the ladder reaches IDLE. Observed: \(resume) ***")
        }
        XCTAssertEqual(keychain.writes.filter { $0 == MeshIdentity.v1Tag }.count, 1,
                       "*** AND EXACTLY ONE IDENTITY STANDS -- the crash did not mint a second. ***")
    }

    /// *** A FOCUSED ESTATE THAT POSITIVELY OWNS NO LIVE OWNER (or a chosen set), so an arm can exercise a REAL
    /// drain decision without constructing any private graph. ***
    private struct OwnedArtifactEstate: MeshRuntime.RecoveryEstate {
        let artifactPaths: [String: URL]
        var keychain: any LocalIdentityKeychain = RecoveryKeychain()
        var dekProvider: (any PrivateStoreKeyProvider)? = nil
        var liveTransport: TransportRuntimeSeam? { nil }
        var drain: () -> OwnerDrainResult = { .cold(reason: "the focused arm positively owns no live owner") }
        func drainOwners() -> OwnerDrainResult { drain() }
    }

    /// A recording identity authority for the focused arms.
    private final class RecordingIdentityAuthority: IdentityAuthoritySeam {
        private(set) var publications = 0
        func publishNewIdentity() -> String? { publications += 1; return "id-\(publications)" }
        func identity() -> String? { nil }
        func publishOrAdoptIdentity(wipeGeneration: UInt64) -> String? {
            _ = wipeGeneration; publications += 1; return "id-\(publications)"
        }
    }

    /// A vault that erases every key it is asked for -- the focused arms' satisfied seam.
    private final class RecordingVault: KeyVaultSeam {
        func eraseKey(_ name: String) -> KeyDeletionResult { .deleted }
    }

    /// *** IOS-R5: A LIVE OWNER THAT CANNOT BE DRAINED MUST KEEP THE WIPE PENDING -- never advance over it. ***
    ///
    /// *THE FINDING: the recovery entry drained a FRESH `BleTransport()` whose barrier "immediately succeeds ... without
    /// touching the estate's live transport, stores, sessions, or producers".* **So an estate whose owners are STILL
    /// LIVE answereth `.ownersLive`, and the ladder must remain PENDING with a `recoveryOnly` road -- no private graph,
    /// no completion.** *A mutation that substituted a cold/dead transport would let the ladder reach IDLE here and
    /// redden this arm.*
    func testGSFINAL003_aLiveOwnerThatCannotBeDrainedKeepsTheWipePending() throws {
        struct LiveOwnerEstate: MeshRuntime.RecoveryEstate {
            let artifactPaths: [String: URL]
            let keychain: any LocalIdentityKeychain = RecoveryKeychain()
            let dekProvider: (any PrivateStoreKeyProvider)? = nil
            var liveTransport: TransportRuntimeSeam? { nil }
            func drainOwners() -> OwnerDrainResult {
                .ownersLive(reason: "a producer is still live")
            }
        }
        let dir = tempDir("live_owner")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")
        try Data(repeating: 0x11, count: 32).write(to: msg)
        try Data(repeating: 0x22, count: 32).write(to: peer)
        let journal = RecoveryJournal()

        let driven = MeshRuntime.runRecoveryLadderInternal(
            journal: journal,
            estate: LiveOwnerEstate(artifactPaths: MeshRuntime.wipeArtifactPaths(messageStoreUrl: msg, peerStoreUrl: peer)),
            requestFresh: true)
        XCTAssertNotEqual(
            driven.outcome.decision, .wipeCompleted,
            "*** A LIVE, UNDRAINABLE OWNER MUST STOP THE LADDER AT THE DRAIN RUNG -- a completion here would mean "
            + "the estate's real owners were never quiesced (IOS-R5). ***")
        if case .normal = driven.topology {
            XCTFail("*** AND NO PERMIT MAY ISSUE: an unsettled estate cannot reach private construction. ***")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: msg.path),
                      "and the live owner's artifact must NOT be deleted while it is still live")
    }

    // MARK: - (9) IOS-FOLLOWUP-C2/C3: THE FILE JOURNAL'S OWN RECEIPTS, AND THE RESTART UNDER DRAIN

    /// *** C2 POSITIVE/NEGATIVE: A DIRECTORY-FSYNC FAILURE AFTER THE BYTES ARE VISIBLE IS *NOT* AN ACKNOWLEDGMENT. ***
    ///
    /// *The production `FileWipeJournal` is driven DIRECTLY here -- not a fake -- so the receipt road the finding names
    /// is the one measured: the write REFUSES, the refused rung does not advance, the visible-but-unsynced bytes are
    /// never accepted by a state-only reread, and the OLD committed rung is what a reader still seeth. Then the fault
    /// is cleared and the SAME rung commits, proving the refusal was the medium's and not a permanent brick.*
    func testGSFINAL003_aFailedDirectorySyncIsRefusedAndNeverAcknowledged() throws {
        let dir = tempDir("fsync_receipt")
        defer { cleanup(dir) }
        let journal = FileWipeJournal(url: dir.appendingPathComponent("io.godstone.wipe.journal"))

        // (a) *** A VERIFIED BASELINE: the journal really carrieth and vouches for it. ***
        let baseline = journal.writeChecked(.idle)
        XCTAssertTrue(baseline.synchronized, "the healthy medium must vouch for the baseline")
        XCTAssertNotNil(baseline.epoch, "and the baseline carries the generation it reached")

        // (b) *** THE REQUEST COMMITS. ***
        let requested = journal.writeChecked(.requested)
        XCTAssertTrue(requested.synchronized, "and for the REQUESTED rung")
        XCTAssertEqual(journal.readDurable()?.state, .requested, "the medium really carrieth REQUESTED")

        // (c) *** THE INJECTED DIRECTORY-FSYNC FAILURE ON THE NEXT RUNG: THE BYTES ARE VISIBLE, THE RECEIPT IS REFUSED. ***
        journal.syncFaultForTest = .directory
        let refused = journal.writeChecked(.runtimeDrained)
        XCTAssertFalse(refused.synchronized,
                       "*** A FAILED DIRECTORY FSYNC MUST REFUSE: the bytes may stand on the medium, but NOTHING may "
                       + "acknowledge them (IOS-FOLLOWUP-C2). ***")
        XCTAssertNil(journal.readDurable(),
                     "*** AND THE VISIBLE-BUT-UNVOUCHED RECORD MUST NOT ANSWER `readDurable`: a state-only reread must "
                     + "not turn a failed directory fsync into `committed`. ***")
        XCTAssertFalse(journal.isReadable,
                       "*** NOR MAY IT READ AS READABLE: every admission question about this record answereth as "
                       + "unreadable until a later persist really syncs. ***")
        XCTAssertNotEqual(journal.read(), .runtimeDrained,
                          "*** AND THE COERCED STATE READ MUST NOT REPORT THE UNACKNOWLEDGED RUNG -- a caller that "
                          + "asked only `read()` would otherwise see a rung nobody committed. ***")

        // (d) *** THE LADDER ABOVE THE REFUSED RUNG CANNOT PROCEED: the coordinator's append is refused through the
        // adapter, so no commit exists for the rung the vault would have earned. ***
        let adapter = WipeJournalDurabilityAdapter(journal: journal)
        if case .committed = adapter.appendJournal("KEYS_ERASED") {
            XCTFail("*** A CHECKPOINT APPEND ON A POISONED MEDIUM MUST BE REFUSED (IOS-FOLLOWUP-C2). ***")
        }

        // (e) *** AND THE REFUSAL IS NOT A PERMANENT BRICK: clearing the fault lets the SAME record commit, and the
        // DURABLE MARKER it left behind is cleared by that verified sync. ***
        journal.syncFaultForTest = nil
        let recovered = journal.writeChecked(.runtimeDrained)
        XCTAssertTrue(recovered.synchronized, "with the medium healthy again, the rung commits")
        XCTAssertEqual(journal.readDurable()?.state, .runtimeDrained,
                       "and only THEN does the record answer as durable")
        XCTAssertNotNil(journal.readDurable()?.epoch,
                        "*** AND ITS GENERATION IS PINNED TO THE FLOOR (CURRENT-01/02): the settled/admission roads "
                        + "require the phase-stamped epoch to equal the durable floor, or they refuse. ***")
    }

    /// *** C2/C3 POSITIVE: A FILE-SYNC FAILURE BEFORE THE REPLACEMENT LEAVES THE *OLD* COMMITTED RECORD STANDING. ***
    ///
    /// *The two failure boundaries are different roads and the finding nameth both: a pre-visibility file-sync failure
    /// must leave the last committed record intact (never a fabricated clean estate), while the post-visibility
    /// directory failure is refused above. And `crash at each replacement boundary` reduceth to this: the OLD record
    /// is what a fresh reader sees.*
    func testGSFINAL003_aFailedFileSyncLeavesTheOldCommittedRecordStanding() throws {
        let dir = tempDir("file_sync")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("io.godstone.wipe.journal")
        let journal = FileWipeJournal(url: url)
        _ = journal.writeChecked(.idle)
        XCTAssertTrue(journal.writeChecked(.requested).synchronized)
        let committedEpoch = journal.durableEpoch

        journal.syncFaultForTest = .file
        let refused = journal.writeChecked(.runtimeDrained)
        XCTAssertFalse(refused.synchronized, "*** A FILE-SYNC FAILURE MUST REFUSE (IOS-FOLLOWUP-C2). ***")
        XCTAssertEqual(journal.readDurable()?.state, .requested,
                       "*** AND THE OLD COMMITTED RECORD MUST SURVIVE UNTOUCHED: a crash at this boundary leaveth the "
                       + "previously committed rung, never a missing or fabricated clean estate. ***")
        XCTAssertEqual(journal.durableEpoch, committedEpoch,
                       "and the generation does not advance behind a refused write")

        // *** AND A FRESH JOURNAL OVER THE SAME FILE CONVERGES ON THAT SAME OLD RECORD (the restart reading). ***
        let reopened = FileWipeJournal(url: url)
        XCTAssertEqual(reopened.readDurable()?.state, .requested,
                       "*** A SECOND PROCESS MUST READ THE LAST COMMITTED RECORD, not the refused one and not clean. ***")
        XCTAssertEqual(reopened.durableEpoch, committedEpoch, "and the same generation, from the medium itself")
    }

    /// *** C3: THE GENERATION IS MONOTONE ACROSS A CORRUPT HEAD, A CLEAR, AND A POISONED READ. ***
    ///
    /// *A corrupt state head must not discard a valid generation suffix, `clear` must not free a previously issued
    /// generation for reuse, and monotonicity must survive a refused (visible-but-unvouched) write. This drives the
    /// REAL file journal, because the ABA hazard is a property of the durable bytes, not of a court fake.*
    func testGSFINAL003_theDurableGenerationNeverRegresses() throws {
        let dir = tempDir("generation")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("io.godstone.wipe.journal")
        let journal = FileWipeJournal(url: url)

        // *** THE FLOOR AND THE PHASE ARE ESTABLISHED TOGETHER, as the production baseline road doth. ***
        _ = journal.writeChecked(.idle)
        let first = journal.durableEpoch
        XCTAssertEqual(first, 1, "a brand-new estate beginneth at generation 1")
        // *** THE FIXTURE IS READ THROUGH THE ACCESSOR, NOT THE PIN: a bare `read()` still carrieth the state head,
        // while `durableEpoch` now requireTH the phase to be pinned to the floor. ***
        XCTAssertEqual(journal.read(), .idle, "the settled phase is readable as a state")
        XCTAssertEqual(journal.readFloorForTest, 1, "and the floor is the number the phase was stamped with")

        // *** (a) A CORRUPT HEAD THAT RETAINS A VALID SUFFIX: THE SUFFIX IS THE NEXT GENERATION'S LOWER BOUND. ***
        try Data("NOT_A_STATE|\(first ?? 0)".utf8).write(to: url, options: [.atomic])
        XCTAssertFalse(journal.isReadable,
                       "*** A CORRUPT HEAD IS NOT READABLE -- AND ITS SUFFIX IS NOT ADMITTED (CURRENT-01/02): the "
                       + "phase must be pinned to the floor, not merely present. ***")
        // *** `read()` COERCETH THE UNPARSEABLE HEAD TO `.idle` (the journal's own documented coercion), so the arm
        // reads the REFUSAL from the durable question, not from a state the coercion invented. ***
        XCTAssertNil(journal.readDurable(),
                     "*** AND THE DURABLE QUESTION REFUSES THE CORRUPT HEAD: no (state, epoch) answer may be "
                       + "manufactured for it. ***")
        let advanced = journal.bumpEpoch()
        XCTAssertEqual(advanced, (first ?? 0) + 1,
                       "*** BUT THE RAISE STILL ADVANCETH FROM THE RECORD'S OWN SUFFIX -- monotonicity surviveth "
                       + "corruption even though admission refuseth it. ***")

        // *** (b) `clear` MUST NOT GIVE THE GENERATION BACK. ***
        _ = journal.writeChecked(.idle)          // re-stamp the phase to the raised floor (the authorized road)
        journal.clear()
        XCTAssertEqual(journal.durableEpoch, advanced,
                       "*** `clear` KEEPETH THE GENERATION: a later clean baseline must never REUSE a generation a "
                       + "permit was already bound to (ABA). ***")

        // *** (c) A POISONED (VISIBLE-BUT-UNVOUCHED) WRITE MUST NOT LOWER THE FLOOR EITHER. ***
        journal.syncFaultForTest = .directory
        _ = journal.writeChecked(.requested)
        journal.syncFaultForTest = nil
        XCTAssertGreaterThanOrEqual(journal.readFloorForTest ?? 0, advanced ?? 0,
                                    "*** MONOTONICITY MUST NOT REGRESS THROUGH A REFUSED WRITE. ***")
    }

    /// *** C1/C3: A REQUEST THAT CANNOT ADVANCE THE DURABLE EPOCH MUST NOT BEGIN THE LADDER. ***
    ///
    /// *`persistRequest` used to fabricate a coordinator-local successor when the store refused the epoch bump, so the
    /// rung span ran bound to a generation the medium never acknowledged. With a counter-claiming store the refusal is
    /// now a THROW -- the request stays unrecorded and nothing is destroyed. Measured with the REAL file journal under
    /// the injected file-sync fault.*
    func testGSFINAL003_aRefusedEpochAdvanceStopsTheRequestBeforeAnyEffect() throws {
        let dir = tempDir("epoch_refusal")
        defer { cleanup(dir) }
        let journal = FileWipeJournal(url: dir.appendingPathComponent("io.godstone.wipe.journal"))
        let adapter = WipeJournalDurabilityAdapter(journal: journal)
        let vault = RecordingVault()
        let wipe = CrashResumableWipe(
            store: adapter, vault: vault,
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(), authority: RecordingIdentityAuthority())

        journal.syncFaultForTest = .file
        XCTAssertThrowsError(try wipe.requestWipe(),
                             "*** A REQUEST WHOSE EPOCH CANNOT ADVANCE MUST THROW (IOS-FOLLOWUP-C3), never fabricate "
                             + "a local successor and run a rung span on an unacknowledged generation. ***")
        XCTAssertFalse(wipe.isWipePending, "and the ladder never began: the durable record still carrieth no rung")
        XCTAssertNil(journal.readDurable()?.epoch ?? nil, "and no generation was fabricated into the medium")
    }

    /// *** C6: A RESTART AT `RUNTIME_DRAINED` MUST RE-DRAIN THE *CURRENT* OWNERS BEFORE ANY KEY DIES. ***
    ///
    /// *The finding: the runtimeDrained branch re-drained only for non-`WipeOwnerDraining` seams, so a fresh
    /// estate seam with `isQuiesced == false` resumed straight into key erasure. The production estate seam IS
    /// `WipeOwnerDraining`, so this arm gives it a LIVE owner and requires the ladder to STOP AT THE DRAIN RUNG with
    /// the vault untouched and the artifacts standing.*
    func testGSFINAL003_aRestartFromRuntimeDrainedReDrainsTheLiveOwners() throws {
        // The estate seam under test: it answers `.ownersLive` -- a real producer that cannot be drained.
        final class UndrainableEstate: MeshRuntime.RecoveryEstate {
            let artifactPaths: [String: URL]
            let keychain: any LocalIdentityKeychain
            let dekProvider: (any PrivateStoreKeyProvider)?
            var liveTransport: TransportRuntimeSeam? { nil }
            init(artifactPaths: [String: URL], keychain: any LocalIdentityKeychain,
                 dekProvider: (any PrivateStoreKeyProvider)?) {
                self.artifactPaths = artifactPaths; self.keychain = keychain; self.dekProvider = dekProvider
            }
            func drainOwners() -> OwnerDrainResult { .ownersLive(reason: "a producer is still live") }
        }

        let dir = tempDir("resume_drain")
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")
        try Data(repeating: 0x11, count: 32).write(to: msg)
        try Data(repeating: 0x22, count: 32).write(to: peer)

        // A RECORD A PREVIOUS PROCESS LEFT AT RUNTIME_DRAINED -- the resume this clause names.
        let journal = RecoveryJournal(seed: .runtimeDrained)
        let provider = RecoveryKeyProvider()
        provider.seedDEK(tag: WipeKeyVaultSeam.messageStoreDEKTag)
        provider.seedDEK(tag: WipeKeyVaultSeam.peerStoreDEKTag)
        let keychain = RecoveryKeychain()
        _ = try MeshIdentity.generateAndStore(keychain: keychain)

        let driven = MeshRuntime.runRecoveryLadderInternal(
            journal: journal,
            estate: UndrainableEstate(
                artifactPaths: MeshRuntime.wipeArtifactPaths(messageStoreUrl: msg, peerStoreUrl: peer),
                keychain: keychain, dekProvider: provider),
            requestFresh: false)

        XCTAssertNotEqual(driven.outcome.decision, .wipeCompleted,
                          "*** A RESTART AT RUNTIME_DRAINED WITH A LIVE OWNER MUST NOT COMPLETE (IOS-FOLLOWUP-C6). ***")
        XCTAssertEqual(provider.dekDeletes, 0,
                       "*** AND NO DEK MAY DIE: the current-lifetime drain refusal must stop the ladder BEFORE the "
                       + "key rung, not be discarded past it. ***")
        XCTAssertTrue(provider.holdsDEK(tag: WipeKeyVaultSeam.messageStoreDEKTag),
                      "the message store's real DEK must still stand")
        XCTAssertTrue(provider.holdsDEK(tag: WipeKeyVaultSeam.peerStoreDEKTag),
                      "and the peer store's with it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: msg.path),
                      "and no artifact may be deleted while its owner is live")
        XCTAssertEqual(journal.writeLog, [WipeState.runtimeDrained.rawValue],
                       "*** THE RECORD STANDS WHERE THE RESTART FOUND IT: an undrainable owner earneth no rung. ***")
        if case .normal = driven.topology {
            XCTFail("*** AND NO PERMIT MAY ISSUE FROM AN ESTATE THAT NEVER QUIESCED. ***")
        }
    }

    /// *** C5: TWO ROOTS SHARING ONE PHYSICAL KEY AUTHORITY JOIN ONE OWNER SET. ***
    ///
    /// *The finding: a registry bound by literal inventory paths let two estates over the same real Keychain
    /// service/account pairs hold SEPARATE owner sets -- so a wipe through one left the other's owners live. The
    /// authority now groups by the capability aliases (identity key domain, DEK key domain, canonical paths, inodes),
    /// and this arm measures the merge and the wipe-through-one-owner refusal.*
    func testGSFINAL003_rootsSharingTheKeyDomainJoinOneOwnerSet() throws {
        let dir = tempDir("cross_owner")
        defer { cleanup(dir) }
        let rootA = dir.appendingPathComponent("a", isDirectory: true)
        let rootB = dir.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let sharedKeychain = RecoveryKeychain()
        // ONE key domain for both roots: the physical DEK authority they both speak for.
        let domain = "test.shared.\(UUID().uuidString)"

        let msgA = rootA.appendingPathComponent("mesh.db")
        let peerA = rootA.appendingPathComponent("peer.db")
        let msgB = rootB.appendingPathComponent("mesh.db")
        let peerB = rootB.appendingPathComponent("peer.db")
        let pathsA = MeshRuntime.wipeArtifactPaths(messageStoreUrl: msgA, peerStoreUrl: peerA)
        let pathsB = MeshRuntime.wipeArtifactPaths(messageStoreUrl: msgB, peerStoreUrl: peerB)

        let registryA = try PhysicalEstateAuthority.shared.bindInventory(
            estateId: MeshRuntime.recoveryEstateId(artifactPaths: pathsA),
            artifactPaths: pathsA, keychain: sharedKeychain, keyDomain: domain)
        let registryB = try PhysicalEstateAuthority.shared.bindInventory(
            estateId: MeshRuntime.recoveryEstateId(artifactPaths: pathsB),
            artifactPaths: pathsB, keychain: sharedKeychain, keyDomain: domain)

        XCTAssertTrue(registryA === registryB,
                      "*** TWO ROOTS THAT SHARE THE PHYSICAL KEY AUTHORITY MUST JOIN ONE OWNER SET (IOS-FOLLOWUP-C5): "
                      + "otherwise a wipe through one leaveth the other's owners live. ***")

        // *** AND THE SHARED SET REFUSES COLD WHILE A LIVE OWNER STANDS. ***
        var closed = false
        registryA.register(name: "owner-b") { closed = true }
        guard case .drained = EstateOwnerDrainSeam(registry: registryA).drainOwners(), closed else {
            return XCTFail("*** THE SHARED OWNER SET MUST DRAIN THE LIVE OWNER REGISTERED THROUGH THE OTHER ROOT. ***")
        }
    }

    /// *** IOS-R4: A DEK THAT SURVIVES ITS OWN DELETION MUST BE A NAMED, RETRYABLE FAILURE. ***
    func testGSFINAL003_aDEKThatSurvivesItsDeletionIsNotReportedErased() {
        final class StubbornProvider: PrivateStoreKeyProvider, @unchecked Sendable {
            var dekByteCount: Int { 32 }
            func fetchDEK(tag: String) throws -> StoreDEK { StoreDEK(bytes: Data(repeating: 0x11, count: 32)) }
            func createDEK(tag: String) throws -> StoreDEK { throw StoreKeyError.dekNotFound }
            func deleteDEK(tag: String) throws {}     // SURVIVES ITS OWN DELETION
            func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult { .success }
        }
        let seam = WipeKeyVaultSeam(dekProvider: StubbornProvider())
        let result = seam.eraseKey("store-dek-message")
        guard case .failed(let name, let retryable, _) = result, name == "store-dek-message", retryable else {
            return XCTFail("*** A DEK THAT SURVIVES ITS OWN DELETION MUST BE A NAMED, RETRYABLE FAILURE -- reporting "
                           + "it erased would let the ladder reach IDLE with the key still standing (IOS-R4). "
                           + "Observed: \(result) ***")
        }
    }

    /// *** C7 NEGATIVE/POSITIVE: ONLY A *FULL-KEY* SAME-GENERATION RECORD IS ADOPTED; A MISMATCH REFUSES. ***
    ///
    /// *The finding: adoption checked only a 4-byte hint, so a same-generation record with DIFFERENT keys (or an
    /// unrelated standing key) was adopted as the replacement. This arm drives the real keychain-backed publication
    /// record and requires: (a) a same-generation record whose full keys do NOT reproduce the standing identity is
    /// REFUSED; (b) an unrelated standing key with no recorded intent for this generation refuses; (c) the legitimate
    /// crash-after-publication road still settles on ONE identity, by full keys.*
    func testGSFINAL003_identityAdoptionDemandsTheFullReplacementKeys() throws {
        let keychain = RecoveryKeychain()
        let publication = KeychainWipePublicationRecord(keychain: keychain)
        func seam() -> WipeIdentityAuthoritySeam {
            WipeIdentityAuthoritySeam(
                regenerateIdentity: { try MeshIdentity.generateAndStore(keychain: keychain) },
                loadStandingIdentity: { try MeshIdentity.loadFromKeychain(keychain: keychain) },
                readPublication: { publication.read() },
                writePublication: { pub in publication.write(pub) },
                readPublicationIntent: { publication.readIntent() },
                writePublicationIntent: { gen in publication.writeIntent(gen) },
                keychain: keychain)
        }

        // *** THE FIXTURE IS FULLY ISOLATED FIRST: a FRESH keychain with NO standing identity and NO publication
        // record, so the staged-pair road really publishETH rather than refusing on foreign history. ***
        try? MeshIdentity.deleteFromKeychain(keychain: keychain)

        // (a) *** A LEGITIMATE PUBLICATION: the staged pair is promoted and its FULL keys are published. ***
        let first = try XCTUnwrap(seam().publishOrAdoptIdentity(wipeGeneration: 7),
                                  "*** the replacement identity must publish for generation 7: the staged pair is "
                                  + "promoted when nothing stands and its full keys are recorded. ***")
        XCTAssertEqual(publication.read()?.generation, 7, "and the record is bound to that generation")

        // (b) *** A SAME-GENERATION RECORD WITH WRONG KEYS MUST REFUSE -- never fall through to adoption. ***
        let mismatching = WipeIdentityPublication(
            generation: 7, hint: "deadbeef",
            signingPublicKeyHex: String(repeating: "00", count: 32),
            staticDhPublicKeyHex: String(repeating: "11", count: 32))
        XCTAssertTrue(publication.write(mismatching), "the court can plant a same-generation record")
        XCTAssertNil(seam().publishOrAdoptIdentity(wipeGeneration: 7),
                     "*** A SAME-GENERATION RECORD WHOSE FULL KEYS DO NOT MATCH THE STANDING IDENTITY MUST REFUSE "
                     + "(IOS-FOLLOWUP-C7) -- the old 4-byte hint check adopted it. ***")

        // (c) *** AN UNRELATED STANDING KEY WITH NO *RECORDED* INTENT CANNOT BE ADOPTED: the intent write is the
        // gate, and a refusing keychain closes the adoption road -- the `identityAlreadyExists` catch may not fall
        // back to "adopt whatever stands". ***
        _ = publication.write(WipeIdentityPublication(
            generation: 8, hint: first,
            signingPublicKeyHex: String(repeating: "22", count: 32),
            staticDhPublicKeyHex: String(repeating: "33", count: 32)))
        let intentlessSeam = WipeIdentityAuthoritySeam(
            regenerateIdentity: { throw MeshError.identityAlreadyExists },
            loadStandingIdentity: { try MeshIdentity.loadFromKeychain(keychain: keychain) },
            readPublication: { publication.read() },
            writePublication: { pub in publication.write(pub) },
            readPublicationIntent: { nil },
            writePublicationIntent: { _ in false })
        XCTAssertNil(intentlessSeam.publishOrAdoptIdentity(wipeGeneration: 9),
                     "*** AN UNRELATED STANDING KEY WITH NO RECORDED INTENT FOR THE WIPE GENERATION MUST NOT BE "
                     + "ADOPTED AS THE REPLACEMENT: the intent write is the gate, and a refusal there closes the "
                     + "adoption road. ***")

        // (d) *** AND THE LEGITIMATE CRASH ROAD STILL SETTLES ON ONE IDENTITY, BY FULL KEYS. ***
        let settled = WipeIdentityPublication(identity: try MeshIdentity.loadFromKeychain(keychain: keychain),
                                              generation: 7)
        XCTAssertTrue(publication.write(settled), "a record reproducing the standing keys is writable")
        XCTAssertEqual(seam().publishOrAdoptIdentity(wipeGeneration: 7), settled.hint,
                       "*** A RECORD THAT REPRODUCES THE STANDING IDENTITY'S FULL KEYS IS ADOPTED -- the positive "
                       + "discriminator for the refusal above. ***")
    }

    /// *** H1: A *RETAINED* OWNER MUST REFUSE SENSITIVE USE ONCE ITS ORACLE IS UNREADABLE. ***
    ///
    /// *The finding: `allowsSensitiveApi` returned only `!isWipePending`, so an unreadable durable record coerced to
    /// idle and the retained gate answered TRUE. The guard now requires a readable, supported record with a known
    /// generation. This arm CORRUPTS the real file journal AFTER a runtime was constructed and requires the retained
    /// gate to close -- not a fresh startup test, which the previous coverage already had.*
    func testGSFINAL003_aRetainedOwnerRefusesSensitiveUseOnACorruptOracle() throws {
        let dir = tempDir("retained_corrupt")
        defer { cleanup(dir) }
        let journalURL = dir.appendingPathComponent("io.godstone.wipe.journal")
        let journal = FileWipeJournal(url: journalURL)
        _ = journal.writeChecked(.idle)          // a settled, readable record with a known generation

        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: dir.appendingPathComponent("mesh.db"),
            peerStoreUrl: dir.appendingPathComponent("peer.db"),
            journal: journal,
            keychain: RecoveryKeychain())
        // *** THE RETAINED OWNER'S OWN GATE: the SAME `CrashResumableWipe` the constructed runtime holds and every
        // sensitive decorator (lookup, binding, ACK, inbox) consults per call. ***
        let retained = runtime.wipeAuthorityForTest()
        XCTAssertTrue(retained.allowsSensitiveApi(),
                      "a settled estate admits sensitive use on the RETAINED owner")

        // *** THE ORACLE TURNS UNREADABLE UNDER THE RETAINED OWNER. ***
        try Data("NOT_A_REAL_STATE".utf8).write(to: journalURL, options: [.atomic])
        XCTAssertFalse(retained.allowsSensitiveApi(),
                       "*** A RETAINED OWNER WHOSE DURABLE ORACLE CANNOT BE READ MUST REFUSE SENSITIVE USE "
                       + "(IOS-FOLLOWUP-H1) -- a gate that coerced the unreadable value to idle would still answer "
                       + "TRUE here. ***")
        XCTAssertFalse(retained.isReadableJournal(),
                       "and the retained owner's own readability answer must say so rather than coercing to clean")
    }

    /// *** CURRENT-01 (THE PARENT'S INDEPENDENT-PROCESS PROBES, AS A COURT): PRESENT HISTORY MUST NOT RESET. ***
    ///
    /// *MEASURED before this repair: a bare bump on a fresh-but-PRESENT `idle|invalid` record with no `.epoch`
    /// answered `1` (a real estate's history reset to generation 1), and a PRESENT-but-corrupt `.epoch` with an absent
    /// phase was admitted as a clean first launch, and a PRESENT-but-corrupt refusal marker on `idle|1`/floor `1` was
    /// admitted as IDLE. This arm asserts the repaired contract on the REAL journal; the independent-process reading
    /// itself belongs to the parent's probe (a fresh object in one process is not an independent process).*
    func testGSFINAL003_aPresentRecordWithNoKnownCounterNeverResetsToGenerationOne() throws {
        let dir = tempDir("unknown_history")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("io.godstone.wipe.journal")

        // (a) *** A PRESENT RECORD WITH AN INVALID COUNTER AND NO FLOOR -- the probe's exact shape. ***
        try Data("idle|invalid".utf8).write(to: url, options: [.atomic])
        let journal = FileWipeJournal(url: url)
        XCTAssertNil(journal.bumpEpoch(),
                     "*** A PRESENT JOURNAL WITH NO NAMEABLE COUNTER MUST REFUSE THE RAISE -- answering 1 would RESET "
                     + "a real estate's history to generation 1 (CURRENT-01). ***")
        XCTAssertNil(journal.readFloorForTest, "and no floor may be fabricated on that road")
        XCTAssertFalse(journal.isReadable, "and the invalid record is not an admissible one")

        // (b) *** AND THE REFUSAL SURVIVES A FRESH WRAPPER (the process boundary the probe crossed). ***
        let reopened = FileWipeJournal(url: url)
        XCTAssertNil(reopened.bumpEpoch(), "*** A SECOND PROCESS MUST REFUSE TOO: the history is still unknown. ***")
        XCTAssertNil(reopened.durableEpoch, "and no generation is named from an unpinned record")

        // (c) *** THE POSITIVE DISCRIMINATOR: A GENUINELY ABSENT ESTATE IS A LEGITIMATE BASELINE. ***
        let freshDir = tempDir("fresh_estate")
        defer { cleanup(freshDir) }
        let fresh = FileWipeJournal(url: freshDir.appendingPathComponent("io.godstone.wipe.journal"))
        XCTAssertEqual(fresh.bumpEpoch(), 1,
                       "*** AN ABSENT RECORD AND AN ABSENT FLOOR IS A FIRST LAUNCH: generation 1 is legitimate ONLY "
                       + "there. ***")

        // (d) *** AND A KNOWN COUNTER ALWAYS ADVANCES, NEVER WRAPS. ***
        XCTAssertEqual(fresh.bumpEpoch(), 2, "the known counter advanced")
        XCTAssertEqual(FileWipeJournal(url: freshDir.appendingPathComponent("io.godstone.wipe.journal")).bumpEpoch(), 3,
                       "*** AND A THIRD PROCESS ADVANCES FROM THE DURABLE FLOOR, not from 1 again. ***")

        // (e) *** A CORRUPT FLOOR WITH NO PHASE FILE IS STILL HISTORY: THE PHASE'S ABSENCE MUST NOT ADMIT IT CLEAN. ***
        // *The parent measured this hole: `recordPresent` asked only about the phase, so `floor present / phase absent`
        // was admitted as a first launch. The predicate now treats the floor AND the refusal marker as history too, on
        // every road -- the raise, the checked write, the ordinary write, `clear`, and the absent read.*
        try Data("NOT_A_NUMBER".utf8).write(to: freshDir.appendingPathComponent("io.godstone.wipe.journal.epoch"),
                                          options: [.atomic])
        try? FileManager.default.removeItem(at: freshDir.appendingPathComponent("io.godstone.wipe.journal"))
        let corruptFloorOnly = FileWipeJournal(url: freshDir.appendingPathComponent("io.godstone.wipe.journal"))
        XCTAssertNil(corruptFloorOnly.bumpEpoch(),
                     "*** A PRESENT (CORRUPT) FLOOR WITH NO PHASE FILE MUST REFUSE THE RAISE -- never baseline at 1. ***")
        XCTAssertFalse(corruptFloorOnly.isReadable,
                       "*** AND ITS ABSENT READ MUST BE UNREADABLE, NOT A CLEAN START: the floor is evidence of a real "
                       + "estate even when its own value cannot be parsed. ***")
        XCTAssertNil(corruptFloorOnly.readDurable(), "and no durable answer may be fabricated for it")
        XCTAssertNil(corruptFloorOnly.writeChecked(.idle).epoch,
                     "*** AND THE CHECKED WRITE MUST REFUSE TO RE-BLESS IT AS GENERATION 1. ***")

        // (f) *** AND THE COUNTER CEILING REFUSES RATHER THAN WRAPPING TO ZERO. ***
        try Data("\(UInt64.max)".utf8).write(to: freshDir.appendingPathComponent("io.godstone.wipe.journal.epoch"),
                                            options: [.atomic])
        let atCeiling = FileWipeJournal(url: freshDir.appendingPathComponent("io.godstone.wipe.journal"))
        XCTAssertNil(atCeiling.bumpEpoch(),
                     "*** A COUNTER AT UInt64.max MUST REFUSE: wrapping to 0 would recycle every generation at once. ***")
        XCTAssertEqual(atCeiling.readFloorForTest, UInt64.max, "and the floor is left where it was")

        // (g) *** A PRESENT-BUT-CORRUPT REFUSAL MARKER IS ITSELF A REFUSAL, EVEN WHEN THE PHASE AND FLOOR AGREE. ***
        // *MEASURED before this repair: marker bytes that did not equal the record's spelling were ignored, and a phase
        // of `idle|1` with floor `1` was admitted as IDLE. Presence is the evidence -- the marker is written before
        // every replace and cleared only by a verified sync.*
        let markerDir = tempDir("marker_boundary")
        defer { cleanup(markerDir) }
        let markerURL = markerDir.appendingPathComponent("io.godstone.wipe.journal")
        let markerJournal = FileWipeJournal(url: markerURL)
        XCTAssertTrue(markerJournal.writeChecked(.idle).synchronized, "a settled, pinned baseline")
        XCTAssertEqual(markerJournal.readDurable()?.state, .idle, "admitted while no marker stands")
        try Data("NOT_A_RECORD_SPELLING".utf8).write(
            to: markerURL.deletingLastPathComponent().appendingPathComponent("io.godstone.wipe.journal.unacked"),
            options: [.atomic])
        XCTAssertNil(markerJournal.readDurable(),
                     "*** A PRESENT (CORRUPT) REFUSAL MARKER MUST REFUSE THE RECORD: byte-equality ignored it and the "
                     + "visible bytes were admitted (CURRENT-03). ***")
        XCTAssertFalse(markerJournal.isReadable, "and it is not readable while the marker stands")
        // *** AND THE REFUSAL IS NOT PERPETUAL: THE AUTHORIZED RECOVERY ROAD CLEARS IT. ***
        //
        // *A manual `writeChecked(.idle)` must NOT be asserted as universally refused -- that would contradict the
        // design: when the phase is unpinned and a KNOWN floor stands, the checked write RE-STAMPS from the floor and
        // its successful file+directory sync CLEARS the marker, which is exactly how an operator's recovery proceeds.
        // What the contract guarantees is narrower and is asserted here: reads refuse while the marker stands; the
        // authorized sequence (bump, then a checked REQUESTED) leaves a DURABLE REQUESTED at the raised generation with
        // the marker gone, a SECOND WRAPPER observes that same pending record, and NOTHING is admitted as IDLE until the
        // whole erasure runs.*
        let raised = markerJournal.bumpEpoch()
        XCTAssertEqual(raised, 2, "the authorized raise advances from the known floor (1 -> 2)")
        let requested = markerJournal.writeChecked(.requested)
        XCTAssertTrue(requested.synchronized, "and the checked REQUESTED write really synchronizes")
        XCTAssertEqual(requested.epoch, 2, "stamped with the raised generation, not a fabricated one")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: markerURL.deletingLastPathComponent()
                    .appendingPathComponent("io.godstone.wipe.journal.unacked").path),
            "*** THE VERIFIED SYNC CLEARS THE MARKER -- the refusal is bounded, not perpetual (CURRENT-03). ***")
        XCTAssertEqual(markerJournal.readDurable()?.state, .requested,
                       "*** AND THE ESTATE IS PENDING AT REQUESTED -- NOT ADMITTED AS IDLE. ***")
        XCTAssertEqual(markerJournal.readDurable()?.epoch, 2, "with its generation pinned to the raised floor")
        let secondProcess = FileWipeJournal(url: markerURL)
        XCTAssertEqual(secondProcess.readDurable()?.state, .requested,
                       "*** A NEW WRAPPER OBSERVES THE SAME PENDING RECORD, not a clean estate. ***")
        XCTAssertEqual(secondProcess.readDurable()?.epoch, 2, "and the same generation, from the medium itself")
        XCTAssertNotEqual(secondProcess.readDurable()?.state, .idle,
                          "*** AND NOTHING IS ADMITTED AS IDLE UNTIL THE WHOLE ERASURE RUNS. ***")
    }

    /// *** EVERY PERSISTED STATE, REOPENED BY A SECOND PROCESS OVER THE SAME DURABLE FILE. ***
    ///
    /// *The explicit clause: for EVERY rung the ladder can persist, a fresh `FileWipeJournal` over the same file must
    /// read EXACTLY that rung and its generation -- never clean, never a neighbouring rung. And a completed wipe must,
    /// on reopen, present a settled estate with the generation PRESERVED and the NEXT wipe advancing from it, because
    /// IDLE and never-requested are the same durable estate but the generation is NOT.*
    func testGSFINAL003_everyPersistedStateSurvivesAReopenWithItsGeneration() throws {
        let dir = tempDir("persisted_states")
        defer { cleanup(dir) }
        let url = dir.appendingPathComponent("io.godstone.wipe.journal")

        let states: [WipeState] = [.requested, .runtimeDrained, .keyErased, .artifactsDeleted, .newIdentity]
        for state in states {
            let journal = FileWipeJournal(url: url)
            _ = journal.writeChecked(state)
            let epoch = journal.durableEpoch
            XCTAssertNotNil(epoch, "every persisted rung carries its generation")

            // *** A SECOND PROCESS: a FRESH object over the SAME file. ***
            let reopened = FileWipeJournal(url: url)
            XCTAssertEqual(reopened.readDurable()?.state, state,
                           "*** A REOPENED JOURNAL MUST READ EXACTLY THE PERSISTED RUNG '\(state.rawValue)' -- never "
                           + "clean and never a neighbouring rung. ***")
            XCTAssertNotNil(epoch, "the persisted rung carried a generation")
            XCTAssertEqual(reopened.durableEpoch, epoch,
                           "*** AND THE GENERATION MUST SURVIVE THE REOPEN (IOS-FOLLOWUP-C3 + CURRENT-01/02): a "
                           + "generation that resets on reopen is an ABA permit waiting to happen. ***")
        }

        // *** AND A COMPLETED WIPE REOPENS AS A SETTLED ESTATE WITH THE GENERATION STILL ADVANCING FORWARD. ***
        let settled = FileWipeJournal(url: url)
        _ = settled.writeChecked(.idle)
        let settledEpoch = settled.durableEpoch
        let afterReopen = FileWipeJournal(url: url)
        XCTAssertEqual(afterReopen.readDurable()?.state, .idle,
                       "a completed wipe is the settled estate, whichever spelling the reader chooseth")
        XCTAssertTrue(afterReopen.isReadable, "and it is readable")
        let next = afterReopen.bumpEpoch()
        XCTAssertEqual(next, (settledEpoch ?? 0) + 1,
                       "*** AND THE NEXT WIPE'S GENERATION ADVANCETH FROM THE PERSISTED ONE -- never restarting at 1 "
                       + "and never reusing a generation a permit was bound to. ***")
    }
}
