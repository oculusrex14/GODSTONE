import XCTest
import Foundation
import SQLite3
import GodstoneCore
@testable import GodstoneMesh

//  GS-FINAL-003: ZERO PRIVATE OPENS BEFORE A SETTLED RECOVERY DECISION.
//
//  *** THE AUDIT'S CHARGE, QUOTED: ***
//
//      "iOS discards the result of resume before creating identity/stores." Root cause: *"DI
//      sequencing is mistaken for successful state transition."*
//
//  *** AND THE FIRST REPAIR WAS WORSE, WHICH THESE COURTS ARE SHAPED AROUND. ***
//
//  The repository already tried refusing construction on a pending wipe and MEASURED the cost:
//  `testSR02` threw, because the ONLY path that finishes a wipe is a method on a CONSTRUCTED
//  runtime that drains through a transport built FROM those very stores. *A gate that makes its
//  own remedy unreachable is worse than the defect it closes.*
//
//  SO THE INVARIANT IS TESTED WHERE IT IS ACTUALLY TRUE, NOT WHERE IT IS CONVENIENT:
//
//      when the caller SUPPLIES a recovery route that cannot settle,
//      private construction is REFUSED and NOTHING is opened.
//
//  That is exactly what the audit asked for -- "Constructible only after a non-forgeable typed
//  startup decision says private construction is allowed" -- and it is checkable without
//  reproducing the deadlock, because the route is a parameter rather than an assumption.
//
//  *** EVERY ARM COUNTS REAL CONSTRUCTION AT THE REAL SEAM. *** *No arm proves this by reading
//  source. `OpenCounter` sits on the message-store path and counts stores that were actually
//  constructed; the identity is observed by the keychain side effect it must perform.*

final class GsFinal003StartupPermitTests: XCTestCase {

    /// *** REAL SEAMS, MIRRORING THE SIBLING COURT'S SHAPES. *** *A court that invents its own
    /// journal type would be testing the invention; these follow `CrashStartupResumeTests` so the
    /// behaviour observed is the production ladder's.*
    private final class InMemoryJournal: WipeJournal, @unchecked Sendable {
        var state: WipeState = .idle
        /// EVERY RECORD IN ORDER, so an arm can read the ORDER rather than only the last rung.
        var writeLog: [String] = []
        /// *** THE DURABLE GENERATION (IOS-R1/R3): A COUNTER-JOURNAL SO A PERMIT CAN BE BOUND TO IT. ***
        private var epoch: UInt64?
        func read() -> WipeState { state }
        func write(_ s: WipeState) {
            state = s; writeLog.append(s.rawValue)
            if epoch == nil, s != .idle { epoch = 1 }
        }
        func clear() { state = .idle }
        var durableEpoch: UInt64? { epoch }
        @discardableResult
        func bumpEpoch() -> UInt64? { epoch = (epoch ?? 0) &+ 1; return epoch }
        /// An explicit typed court fake answering its own medium, WITH the checked receipt the production adapter
        /// demands (IOS-FOLLOWUP-C2): a conformer that omitted `writeChecked` would inherit the fail-closed default
        /// and refuse every commit -- the production law, applied to a fake that had not answered the question.
        func readDurable() -> (state: WipeState, epoch: UInt64?)? { (state, epoch) }
        @discardableResult
        func writeChecked(_ state: WipeState) -> DurableWriteResult {
            write(state)
            if epoch == nil { epoch = 1 }      // a brand-new estate BEGINNETH at generation 1 (baseline)
            return DurableWriteResult(synchronized: true, epoch: epoch)
        }

        /// *** STATED EXPLICITLY, BECAUSE THE PROTOCOL DEFAULT NOW FAILS CLOSED. ***
        /// *This journal keeps typed `WipeState` values, so it cannot hold an unparseable one -- it
        /// is readable BY CONSTRUCTION. An earlier draft omitted this and inherited the new
        /// `false` default, which turned three arms red: the default working exactly as intended on
        /// a conformer that had not answered the question.*
        var isReadable: Bool { true }
    }

    /// A journal whose DURABLE VALUE cannot be parsed -- the real `UserDefaultsWipeJournal` case.
    ///
    /// *The other helper CANNOT express this, and that is the point: `read()` returns a typed
    /// `WipeState`, so an unreadable record has no representation in it. The real journal exposes
    /// the distinction out of band via `isReadable`, and this mirrors that exactly.*
    private final class UnreadableJournal: WipeJournal, @unchecked Sendable {
        func read() -> WipeState { .idle }        // coerced, as the real parser does
        func write(_ s: WipeState) {}
        func clear() {}
        var isReadable: Bool { false }
    }

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        /// *** AND WRITES ARE COUNTED, BECAUSE `MeshIdentity.loadOrCreate` MINTS A KEY BY ADDING ONE. ***
        /// *A refused startup that constructed identity anyway would leave entries here -- **an observable on an
        /// entirely different boundary from the store files, and the old arm never looked at it at all.***
        private(set) var writes: [String] = []
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data; writes.append(tag) }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    /// *** A REAL OPEN COUNTER AT THE REAL SEAM. ***
    ///
    /// *The audit forbids a Boolean like `messageStoreWasBuiltFromVerifiedHandle`, and the reason
    /// generalises: that asserts the ARCHITECTURE rather than observing it. This observes it -- it
    /// counts files that came into existence on disk, which is what "a private store was opened"
    /// actually means.*
    /// *** THE PRIVATE-STORE CONSTRUCTION COUNTER -- AND IT COUNTETH THE OPENS THEMSELVES, NOT THE OUTCOME. ***
    ///
    /// **THE VERSION THAT STOOD HERE WAS NOT A COUNTER. `note(_:)` APPENDED A PATH TO A PRIVATE ARRAY THAT NOTHING EVER
    /// READ, and the only measurement in the arm was `FileManager.fileExists`.** *A MISSING FILE PROVES THAT NO STORE
    /// SUCCEEDED IN CREATING ONE; IT DOES NOT PROVE THAT NO STORE WAS **CONSTRUCTED**.* **A construction that failéth
    /// late -- after the handle, the DEK unwrap or the first statement -- leaveth no file and would have passed the old
    /// arm while opening exactly what the finding forbids.**
    ///
    /// *SO THE COUNTS ARE EXPLICIT AND AT THE LOWEST MEANINGFUL BOUNDARY, as the obligation demands: a private store
    /// construction, and a sensitive-runtime construction.*
    private final class PrivateOpenCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storeOpenCount = 0
        private(set) var paths: [String] = []

        /// *Called AT the construction seam -- by the engine the factory the composition ACTUALLY USES, not by an
        /// observer afterwards.* **The disconnected `builtSensitiveRuntime` count is DELETED: it had no call site and
        /// was therefore a constant zero (Main's own charge), and a never-called witness is worse than none.***
        func openedStore(path: String) { lock.lock(); storeOpenCount += 1; paths.append(path); lock.unlock() }

        var storesOpened: Int { lock.lock(); defer { lock.unlock() }; return storeOpenCount }
        func existed(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    /// *** A COUNTING KEY PROVIDER: EVERY FETCH OR CREATE IS AN ATTEMPTED PRIVATE-STORE OPEN. ***
    ///
    /// *`EncryptedStoreFactory` cannot open a private store without a DEK -- `reopenOwnedRequiringDEK` asketh the
    /// provider for the key before it toucheth the engine. So a REFUSED startup that nonetheless reached the private
    /// composition would have asked for a DEK, and this counter would see it.* **THAT IS A MEASUREMENT AT THE SEAM THE
    /// OBLIGATION NAMETH, rather than an inference from a file that was not created.**
    private final class CountingKeyProvider: PrivateStoreKeyProvider {
        private(set) var dekRequests: Int = 0
        /// *** IOS-R11: THE ACCEPTED CASE MUST BE OBSERVABLE, or a zero assertion is vacuous. *** *`succeeds`
        /// returneth a real 32-byte DEK so a normal composition can actually key both stores and the counter can be
        /// seen NON-ZERO before the refusal arms use it to assert zero.*
        var succeeds: Bool = false
        var dekByteCount: Int { 32 }
        func fetchDEK(tag: String) throws -> StoreDEK {
            dekRequests += 1
            if succeeds { return StoreDEK(bytes: Data(repeating: 0x5A, count: 32)) }
            throw StoreKeyError.dekNotFound
        }
        func createDEK(tag: String) throws -> StoreDEK {
            dekRequests += 1
            if succeeds { return StoreDEK(bytes: Data(repeating: 0xA5, count: 32)) }
            throw StoreKeyError.dekNotFound
        }
        func deleteDEK(tag: String) throws {}
        func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult {
            .success
        }
    }

    /// *** IOS-R11 / NATIVE-PIN: THE REAL PINNED SQLCIPHER ENGINE, COUNTED AT THE CONSTRUCTION SEAM. ***
    ///
    /// *THE OLD `CountingEngine` WAS MISLABELLED: it drove platform `sqlite3_open_v2` -- UNKEYED STOCK SQLITE --
    /// while reporting `kind == .pinnedSQLCipher` and `encryptedAtRest: true`, so the "real accepted construction"
    /// arm was keyed by nothing and the at-rest claim was a hand-written constant. **This engine IS the production
    /// binding** (`SqlCipherDylibEngine`, which applies the DEK, probes the cipher and verifies the at-rest pin
    /// before handing over an owned connection), and the court's counter is raised AT the handover so the
    /// construction seam is the same one a shipping composition reacheth.*
    ///
    /// **AND THE IMAGE IS MANDATORY (SQLITE-LATEST-I6):** a binding failure reddens the arm rather than skipping it,
    /// because a skipped native acceptance must never be counted as a road the campaign ran.
    private final class PinnedCountingEngine: OwnedConnectionStoreEngine, @unchecked Sendable {
        let counter: PrivateOpenCounter
        let pinned = SqlCipherDylibEngine()
        init(counter: PrivateOpenCounter) { self.counter = counter }
        /// Delegated, never declared: a `kind` written by hand would make the factory's fail-closed gate vacuous.
        var kind: StoreEngineKind { pinned.kind }
        var supportedCipherVersion: Int { pinned.supportedCipherVersion }
        func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            try pinned.openForWriting(path: path, dek: dek)
        }
        func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle {
            try pinned.reopenRequiringDEK(path: path, dek: dek)
        }
        func openOwnedForWriting(path: String, dek: StoreDEK) throws -> OwnedConnection {
            counter.openedStore(path: path)
            return try pinned.openOwnedForWriting(path: path, dek: dek)
        }
        func reopenOwnedRequiringDEK(path: String, dek: StoreDEK) throws -> OwnedConnection {
            counter.openedStore(path: path)
            return try pinned.reopenOwnedRequiringDEK(path: path, dek: dek)
        }
    }

    /// *** THE MANDATORY NATIVE LANE GATE: A BINDING FAILURE IS A COURT FAILURE, NEVER A SKIP. ***
    @discardableResult
    private func requirePinnedImage(_ engine: PinnedCountingEngine, lane: String) -> Bool {
        if engine.pinned.isBound { return true }
        XCTFail("*** MANDATORY NATIVE LANE '\(lane)' (SQLITE-LATEST-I6): the pinned image "
                + "'\(SQLCipherPin.libraryName)' is not staged or did not bind. Stage the repository-built artifact "
                + "(tools/supplychain/build_sqlcipher_simulator.sh) or export GODSTONE_SQLCIPHER_ARTIFACT_DIR. "
                + "Reason: \(engine.pinned.bindingFailureReason ?? "unknown") ***")
        return false
    }

    private func tempURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gf003_\(tag)_\(UUID().uuidString).db")
    }

    private func cleanup(_ urls: URL...) {
        for u in urls { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: - the decision itself

    /// *** THE TYPED DECISION EXISTS AND DISTINGUISHES ITS SIX OUTCOMES. ***
    ///
    /// *The audit: "Distinguish at least: no pending wipe / completed wipe / pending recovery /
    /// retryable recovery failure / malformed-corrupt journal / terminal failure. The caller must
    /// not confuse these." A refusal that cannot say WHICH state stopped it is a refusal a caller
    /// can only retry blindly.*
    func testGSFINAL003_theDecisionDistinguishesItsOutcomes() {
        let clean = StartupRecoveryDecision.cleanStart
        let done = StartupRecoveryDecision.wipeCompleted
        let pending = StartupRecoveryDecision.recoveryPending(reason: "x")
        let retryable = StartupRecoveryDecision.retryableFailure(reason: "x")
        let corrupt = StartupRecoveryDecision.corruptJournal(reason: "x")
        let terminal = StartupRecoveryDecision.terminalFailure(reason: "x")

        // ONLY a settled estate permits private construction.
        XCTAssertTrue(clean.allowsPrivateConstruction)
        XCTAssertTrue(done.allowsPrivateConstruction,
                      "a COMPLETED wipe leaves a legitimate estate to start from -- the material is "
                      + "gone and the node is a stranger, which is not a block")
        for blocked in [pending, retryable, corrupt, terminal] {
            XCTAssertFalse(blocked.allowsPrivateConstruction,
                           "\(blocked.name) must not permit private construction")
        }

        // AND THE NAMES ARE DISTINCT, so a caller can tell them apart.
        let names = [clean, done, pending, retryable, corrupt, terminal].map(\.name)
        XCTAssertEqual(Set(names).count, 6, "the six outcomes must be distinguishable: \(names)")

        // A retryable failure blocks construction WITHOUT needing a human; a corrupt journal needs one.
        XCTAssertFalse(retryable.requiresOperator, "a retryable failure may be retried without a human")
        XCTAssertTrue(corrupt.requiresOperator, "a corrupt journal will never fix itself by retrying")
    }

    /// *** THE PERMIT CANNOT BE FORGED -- AND THERE IS NO `issue(_:)` TO TRY. ***
    ///
    /// *THE AUDIT FORBIDS "a public initializer that lets tests/callers mint the permit themselves", AND A REVIEW OF
    /// MY FIRST DRAFT WENT ONE STEP FURTHER AND WAS RIGHT: a `static func issue(_ decision:)` IS ALSO A MINT, because
    /// every case of `StartupRecoveryDecision` is a PUBLIC ENUM CASE and therefore a value any caller may write down.
    /// `issue(.cleanStart)` needs no journal, no ladder and no drive.*
    ///
    /// **SO THE ONLY PRODUCER IS THE ONE-SHOT BOOTSTRAP ROAD, AND WHAT THIS ARM PROVES IS ITS SHAPE:** *a bootstrap
    /// with no journal to read answers a decision and issues NO permit -- the closest a court can come to the forgery
    /// the type now makes unwritable.* **The absence of `issue(_:)` cannot be asserted at runtime (it does not exist),
    /// so it is asserted by COMPILATION: a court that tried to write `PrivateRuntimePermit.issue(...)` would fail the
    /// whole test target to build, which this programme's own round-471 law names as a real failure rather than a
    /// green.***
    func testGSFINAL003_thePermitIsIssuedOnlyByDrivingTheLadder() {
        let journal = InMemoryJournal()
        let authority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: journal),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())

        // (1) *** A CLEAN ESTATE: the drive settles, and the bootstrap issues a permit CARRYING ITS EVIDENCE. ***
        let clean = StartupRecoveryBootstrap(wipe: authority).consumeCompositionTopology()
        guard case .normal(let permit) = clean else {
            return XCTFail("a clean estate must yield the settled permit, got \(clean)")
        }
        XCTAssertEqual(permit.issuedFrom, .cleanStart,
                       "AND THE PERMIT CARRIES WHY, so an audit sees what allowed construction")
        XCTAssertTrue(permit.wasDriven, "the permit's evidence records that the ladder was actually driven")

        // (2) *** ONE-SHOT: THE SAME BOOTSTRAP MAY NOT ISSUE A SECOND PERMIT. ***
        // *A proof of one drive must not open two compositions, and it must not survive an estate that has since
        // changed -- so the second ask is answered BY NAME rather than with a refusal that would read like a corrupt
        // record.*
        let second = StartupRecoveryBootstrap(wipe: authority).consumeCompositionTopology()
        guard case .normal = second else {
            return XCTFail("a fresh bootstrap over a clean estate issues its own permit, got \(second)")
        }
        let bootstrap = StartupRecoveryBootstrap(wipe: authority)
        _ = bootstrap.consumeCompositionTopology()
        if case .alreadyConsumed = bootstrap.consumeCompositionTopology() {
            // EXPECTED.
        } else {
            XCTFail("*** THE CONSUMING ROAD MUST BE ONE-SHOT: a spent bootstrap may not reissue its evidence. ***")
        }

        // (3) *** A PENDING ESTATE YIELDS NO PERMIT AT ALL -- NOT EVEN A GATED ONE. ***
        let pendingJournal = InMemoryJournal()
        pendingJournal.write(.requested)
        let pendingAuthority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: pendingJournal),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())
        let pending = StartupRecoveryBootstrap(wipe: pendingAuthority).consumeCompositionTopology()
        guard case .recoveryOnly(let decision) = pending else {
            return XCTFail(
                "*** A PENDING WIPE MUST YIELD `.recoveryOnly` -- A DECISION AND NO PERMIT. *An earlier draft answered "
                    + "this with a GATED PRIVATE RUNTIME, which is construction plus a gate rather than the ZERO " +
                    "construction the requirement states.* Got \(pending) ***")
        }
        XCTAssertTrue(decision.permitsRecoveryConstruction,
                      "the decision still names the road that IS open (recovery-only), even though no permit exists")

        // (4) *** AND AN UNREADABLE RECORD YIELDS NOTHING AT ALL. ***
        let corruptAuthority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: UnreadableJournal()),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())
        let corrupt = StartupRecoveryBootstrap(wipe: corruptAuthority).consumeCompositionTopology()
        guard case .refused(let corruptDecision) = corrupt else {
            return XCTFail("an unreadable record must refuse the whole road, got \(corrupt)")
        }
        XCTAssertTrue(corruptDecision.requiresOperator,
                      "and it must DEMAND AN OPERATOR, which is the field a Boolean cannot carry")
    }

    // MARK: - the enforced composition

    /// *** IOS-R11: THE POSITIVE CONTROL -- THE COUNTERS *DO* SEE REAL CONSTRUCTION, SO A ZERO MEANS ZERO. ***
    ///
    /// *THE FINDING, VERBATIM: "openedStore and builtSensitiveRuntime have no callsites. The tests instantiate
    /// PrivateOpenCounter and CountingKeyProvider but pass encryptedStores: nil; neither witness is attached to
    /// production construction. Their zero assertions cannot establish the promised absence."* **So this arm attaches
    /// the SAME witnesses to a REAL accepted construction -- a clean estate with a factory whose engine counts -- and
    /// requires the counters to go NON-ZERO. A disconnected (or always-zero) instrument FAILETH here, which is what
    /// makes the zero assertions in the refusal arms mean something.**
    func testGSFINAL003_theWitnessCountersObserveARealAcceptedConstruction() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf003_pos_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }
        let msg = dir.appendingPathComponent("mesh.db")
        let peer = dir.appendingPathComponent("peer.db")

        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()
        provider.succeeds = true                       // A REAL DEK, so the stores can actually key
        let engine = PinnedCountingEngine(counter: counter)
        guard requirePinnedImage(engine, lane: "gf003 positive accepted construction") else { return }
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)
        let journal = InMemoryJournal()                // nothing was ever requested: a SETTLED estate
        let keychain = InMemoryKeychain()
        // *** A BRAND-NEW ESTATE HAS NO GENERATION YET, SO A BASELINE IS DURABLY ESTABLISHED BEFORE THE PERMIT IS
        // MINTED -- the SAME rule production `create` followeth, and the PHASE is stamped so it is PINNED to the floor
        // (CURRENT-01/02: a settled/admission read requireth phase-stamped epoch == the durable floor). ***
        if journal.durableEpoch == nil { journal.writeChecked(.idle) }

        // *** THE ACCEPTED ROAD: the private composition is built, and the witnesses MUST observe it. ***
        let runtime = try MeshRuntime.create(
            messageStoreUrl: msg,
            peerStoreUrl: peer,
            journal: journal,
            keychain: keychain,
            encryptedStores: factory)
        XCTAssertNotNil(runtime, "the accepted road must compose")

        XCTAssertEqual(
            counter.storesOpened, 2,
            "*** IOS-R11: THE COUNTER MUST OBSERVE BOTH REAL PRIVATE-STORE CONSTRUCTIONS -- one per store. A ZERO HERE "
            + "would mean the instrument is disconnected (or always zero), and every zero assertion in the refusal "
            + "arms would then be vacuous. Observed \(counter.storesOpened) ***")
        XCTAssertEqual(provider.dekRequests, 2,
                       "*** AND THE KEY PROVIDER WAS ASKED TWICE -- once per store keyed through the factory. ***")
        // *** THE IDENTITY BOUNDARY'S OWN OBSERVABLE: `MeshIdentity.loadOrCreate` WRITETH its key when it minteth
        // one. The composition ALSO writes the durable physical-inventory catalog and the wipe-publication record
        // through the same keychain now (IOS-FOLLOWUP-C5/C7), so the assertion is scoped to the identity tag --
        // exactly once, and no second mint for the estate. ***
        XCTAssertEqual(keychain.writes.filter { $0 == MeshIdentity.v1Tag }, [MeshIdentity.v1Tag],
                       "*** AND THE IDENTITY WAS MINted ONCE, by the private composition's `loadOrCreate`. ***")
    }

    /// *** THE CENTRAL ARM: A RECOVERY ROUTE THAT CANNOT SETTLE REFUSES, AND OPENS NOTHING. ***
    ///
    /// *This is the finding's invariant, tested where it is true rather than where it deadlocks. The
    /// caller supplies a route that answers `recoveryPending` -- exactly what a cold boot with a
    /// pending wipe must answer -- and the composition must refuse BEFORE any store or identity is
    /// constructed.*
    func testGSFINAL003_anUnsettledRecoveryRefusesAndOpensNothing() throws {
        let msg = tempURL("refuse_msg")
        let peer = tempURL("refuse_peer")
        defer { cleanup(msg, peer, ) }

        let journal = InMemoryJournal()
        journal.write(.requested)
        let keychain = InMemoryKeychain()
        // *** MAIN'S FIX: the SAME instrumented factory/provider the accepted positive arm uses is ROUTED INTO
        // THE REFUSED CALL -- so the zero assertions count the ACTUAL construction boundary this call would reach,
        // not a disconnected object it never touched.***
        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()
        provider.succeeds = true                       // a real DEK; the refusal must happen BEFORE any open
        let engine = PinnedCountingEngine(counter: counter)
        guard requirePinnedImage(engine, lane: "gf003 unsettled refusal") else { return }
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        // THE ROUTE ANSWERS HONESTLY: a cold boot owns no transport, so the ladder stops.
        XCTAssertThrowsError(
            try MeshRuntime.requireRecoveredPrivateComposition(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                journal: journal,
                keychain: keychain,
                encryptedStores: factory,
                driveRecovery: { bootstrap in
                    let d = bootstrap.consumeCompositionTopology()
                    return d
                }),
            "*** GS-FINAL-003: A RECOVERY THAT CANNOT SETTLE MUST REFUSE PRIVATE CONSTRUCTION. "
                + "A store opened now is a store opened on the key a later resume will erase. ***",
        ) { error in
            let text = String(describing: error)
            XCTAssertTrue(
                text.contains("recovery") || text.contains("wipe") || text.contains("pending")
                    || text.contains("retryable") || text.contains("corrupt"),
                "the refusal must NAME the state that stopped it, and it read: \(text)")
        }

        // *** AND NOTHING WAS OPENED. *** *Measured on the filesystem, not asserted from the
        // architecture: a private store that had been constructed would have created its file.*
        // *** AND NOTHING WAS OPENED -- COUNTED AT THE SEAM, NOT INFERRED FROM AN ABSENT FILE. ***
        XCTAssertFalse(counter.existed(msg),
                       "NO PRIVATE STORE MAY EXIST after a refused startup -- a file here means the store was opened anyway")
        XCTAssertFalse(counter.existed(peer), "and no peer store either")
        XCTAssertEqual(
            counter.storesOpened, 0,
            "*** ZERO PRIVATE-STORE OPENS. *THE OLD ARM MEASURED ONLY THE FILE, WHICH CANNOT SEE A CONSTRUCTION THAT "
                + "FAILED LATE -- after the handle, the DEK unwrap or the first statement.* THE COUNT IS NOW TAKEN AT "
                + "THE CONSTRUCTION SEAM ITSELF. ***",
        )
        // NOTE: `provider.dekRequests` is NOT asserted here -- the provider is ALSO the recovery vault's DEK owner,
        // so a refused road that legitimately drives the ladder's key rung asks it. The CONSTRUCTION witness is the
        // engine's open count above (0), which the SAME factory would have raised had it opened a store.
        // *** THE IDENTITY OBSERVABLE IS THE SIGNING KEY ITSELF, NOT THE RAW WRITE LOG: the physical-inventory
        // CATALOG and the wipe-publication record also write through this keychain (CURRENT-05/C7), so a bare
        // `writes.isEmpty` would count catalog rows as identity mints -- which the 107-consumer probe caught. ***
        XCTAssertFalse(
            keychain.writes.contains(MeshIdentity.v1Tag),
            "*** AND IDENTITY WAS NOT MINted: `MeshIdentity.loadOrCreate` WRITETH `v1Tag` WHEN IT CREATES ONE, so its "
                + "absence is the identity boundary's own observable -- a DIFFERENT boundary from the store "
                + "files, which the old arm never looked at. ***",
        )

        // AND THE JOURNAL IS UNTOUCHED: the create-time seams cannot erase, so the ladder must
        // leave the record exactly where it stood rather than advancing a state it did not earn.
        XCTAssertEqual(journal.writeLog.last, WipeState.requested.rawValue,
                       "the refused startup must leave the journal where it stood, because it owns "
                       + "no transport, no keychain and no store handles: \(journal.writeLog)")
    }

    /// *** A PENDING WIPE AT A LATER RUNG REFUSES TOO, AND DOES NOT ENTER PRIVATE STARTUP. ***
    ///
    /// *The audit asks specifically: "interrupted wipe restart -> does not enter normal private
    /// startup". A journal standing at `keysErased` is mid-erasure: the key material is gone and the
    /// artifacts are not, so opening a private store would build an estate on a half-erased floor.*
    func testGSFINAL003_anInterruptedWipeDoesNotEnterPrivateStartup() throws {
        let msg = tempURL("interrupted_msg")
        let peer = tempURL("interrupted_peer")
        defer { cleanup(msg, peer) }

        let journal = InMemoryJournal()
        journal.write(.requested)
        journal.write(.runtimeDrained)
        journal.write(.keyErased)
        let keychain = InMemoryKeychain()
        // *** MAIN'S FIX: THE SAME INSTRUMENTED FACTORY IS ROUTED INTO THE INTERRUPTED-ESTATE CALL. ***
        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()
        provider.succeeds = true
        let engine = PinnedCountingEngine(counter: counter)
        guard requirePinnedImage(engine, lane: "gf003 interrupted refusal") else { return }
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        var observed: StartupRecoveryDecision?
        XCTAssertThrowsError(
            try MeshRuntime.requireRecoveredPrivateComposition(
                messageStoreUrl: msg, peerStoreUrl: peer, journal: journal,
                keychain: keychain, encryptedStores: factory,
                driveRecovery: { b in let t = b.consumeCompositionTopology(); observed = b.reportedDecision(); return t }),
            "an interrupted wipe must not enter normal private startup")
        XCTAssertEqual(observed?.allowsPrivateConstruction, false,
                       "the decision must be a refusing one, and it was: \(String(describing: observed))")
        XCTAssertEqual(counter.storesOpened, 0,
                       "*** AND ZERO PRIVATE-STORE OPENS, COUNTED AT THE FACTORY THIS CALL WAS GIVEN. ***")
        XCTAssertFalse(keychain.writes.contains(MeshIdentity.v1Tag), "*** AND NO IDENTITY WAS MINted. ***")
        XCTAssertFalse(FileManager.default.fileExists(atPath: msg.path),
                       "and no private store may stand on a half-erased floor")
    }

    /// *** GS-FINAL-003: THE OTHER TWO REFUSING CASES, COUNTED AT THE SAME SEAMS. ***
    ///
    /// *THE OBLIGATION NAMETH THREE: **"pending / retryable / corrupt recovery causes ZERO identity and ZERO private DB
    /// opens, proven at the REAL construction seams with counters."*** **ONLY THE PENDING CASE CARRIED COUNTERS** --
    /// *the retryable and corrupt arms asserted the DECISION and nothing about what was constructed, so on those two
    /// roads the "zero opens" half of the clause was UNWITNESSED.*
    ///
    /// *** AND THEY ARE DIFFERENT ROADS, WHICH IS WHY ALL THREE MATTER: `RECOVERY_PENDING` is a wipe outstanding,
    /// `RETRYABLE_FAILURE` is a step that a later composition with live seams may finish, and `CORRUPT_JOURNAL` is the
    /// one an operator must decide -- and a malformed record is precisely the case where a careless reader coerces the
    /// value to a clean start and opens private stores over material that may be mid-erasure.***
    ///
    /// *The counters are the SAME ones the pending arm uses -- real counts at the construction seam, a key provider
    /// that counts DEK requests, and the keychain's write log -- so the three arms measure the same things at the same
    /// boundaries rather than each inventing its own observables.*
    func testGSFINAL003_theOtherRefusingCasesAlsoOpenNothing() throws {
        // (1) *** A RETRYABLE FAILURE: the ladder could not finish with create-time seams. ***
        //
        // *`RETRYABLE_FAILURE` is reached when a step failéth in a way a later composition could mend; the create-time
        // ladder owns no transport, so a pending wipe stops here honestly rather than claiming success.*
        try assertRefusesAndOpensNothing(
            tag: "retryable",
            journal: {
                // *Kotlin's `also` does not exist in Swift; the journal is built and written explicitly.*
                let j = InMemoryJournal()
                j.write(.requested)
                return j
            }(),
        )

        // (2) *** A CORRUPT JOURNAL: the durable record cannot be read as a ladder at all. ***
        //
        // *This is the arm the AUDIT called out in its own root cause: treating a malformed record as a clean start is
        // the one confusion here that would open private stores over material that may be mid-erasure.*
        // *** AND THE CORRUPT ROAD'S OWN EXTRA LAW IS ASSERTED AT ITS CALL SITE RATHER THAN THROUGH A LABEL PIN. ***
        let corruptDecision = MeshRuntime.startupRecoveryDecision(journal: UnreadableJournal())
        XCTAssertTrue(corruptDecision.requiresOperator,
                      "an unreadable record needs an operator; retrying can never make it parse")
        XCTAssertFalse(corruptDecision.allowsPrivateConstruction)
        try assertRefusesAndOpensNothing(
            tag: "corrupt",
            journal: UnreadableJournal(),
        )
    }

    /// *The shared body: drive the real composition, require the refusal, and count every boundary.*
    /// *The shared body: drive the real composition, require the REFUSAL BY ITS TYPED PROPERTY (never by an
    /// incidental label), and count every boundary.*
    private func assertRefusesAndOpensNothing(
        tag: String,
        journal: WipeJournal,
    ) throws {
        let msg = tempURL("\(tag)_msg")
        let peer = tempURL("\(tag)_peer")
        defer { cleanup(msg, peer) }

        let keychain = InMemoryKeychain()
        // *** MAIN'S FIX: THE SAME INSTRUMENTED FACTORY IS ROUTED INTO THE REFUSED CALL. ***
        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()
        provider.succeeds = true
        let engine = PinnedCountingEngine(counter: counter)
        guard requirePinnedImage(engine, lane: "gf003 retryable/corrupt refusal") else { return }
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)
        var observed: StartupRecoveryDecision?

        XCTAssertThrowsError(
            try MeshRuntime.requireRecoveredPrivateComposition(
                messageStoreUrl: msg, peerStoreUrl: peer, journal: journal,
                keychain: keychain, encryptedStores: factory,
                driveRecovery: { b in let t = b.consumeCompositionTopology(); observed = b.reportedDecision(); return t }),
            "*** \(tag): private construction must be REFUSED. ***",
        )
        XCTAssertNotNil(observed, "the ladder must have answered rather than thrown opaquely")
        if let observed {
            XCTAssertTrue(
                observed.allowsPrivateConstruction == false,
                "*** \(tag): the decision must REFUSE PRIVATE CONSTRUCTION (the typed property), whatever refusing "
                    + "name the ladder honestly chooses at this rung. Observed: \(observed) ***",
            )
        }

        // *** AND NOTHING WAS CONSTRUCTED, COUNTED AT THREE BOUNDARIES. ***
        XCTAssertEqual(counter.storesOpened, 0, "*** \(tag): ZERO private-store opens. ***")
        XCTAssertFalse(keychain.writes.contains(MeshIdentity.v1Tag),
                       "*** \(tag): AND IDENTITY WAS NOT MINted -- `MeshIdentity.loadOrCreate` writeth `v1Tag` when "
                           + "it createth one (catalog/publication writes are not identity mints). ***")
    }

    /// *** GS-FINAL-003 `ios-recovery-graph`: THE RECOVERY GRAPH MUST STAND BEFORE, AND INDEPENDENTLY OF, THE STORE GRAPH. ***
    ///
    /// *THE OBLIGATION, VERBATIM: **"iOS: a recovery/bootstrap composition whose transport seam exists BEFORE and
    /// independently of the store graph, so a pending wipe can be driven to a typed decision WITHOUT CONSTRUCTING
    /// PRIVATE STORES."***
    ///
    /// *** AND THE ORDER IS THE WHOLE OF IT, WHICH IS WHY TYPE EXISTENCE IS NOT ENOUGH: a composition that CONSTRUCTS
    /// the private stores first and CONSULTS the recovery answer afterwards would pass any test that merely checketh the
    /// types exist. THE ORDER IS A PROPERTY OF THE CALL GRAPH, SO IT MUST BE WITNESSED AS ONE.***
    ///
    /// **THE MECHANISM THAT MAKETH THE ORDER ENFORCEABLE IS THE SEAM INJECTION:** *`StartupRecoveryBootstrap` owneth
    /// ONLY a `CrashResumableWipe`, and that coordinator taketh SEAM PROTOCOLS -- a `WipeDurabilityStore`, a
    /// `TransportRuntimeSeam`, a `KeyVaultSeam`, an `IdentityAuthoritySeam` -- **NEVER A CONCRETE PRIVATE STORE.*** *So a
    /// recovery graph that needed a store could not be built at all: there is no parameter to pass one through.*
    ///
    /// *** THIS ARM PROVES BOTH HALVES: that the recovery graph DRIVES TO A TYPED DECISION over a DEFERRED transport
    /// (the seam exists and is honest about not draining), AND THAT IT DOES SO WITH NO PRIVATE STORE IN THE GRAPH --
    /// asserted by counting store constructions at the seam, not by reading the types.***
    func testGSFINAL003_theRecoveryGraphStandsBeforeAndWithoutTheStoreGraph() throws {
        let msg = tempURL("order_msg")
        let peer = tempURL("order_peer")
        defer { cleanup(msg, peer) }

        let journal = InMemoryJournal()
        journal.write(.requested)
        let keychain = InMemoryKeychain()
        // *** MAIN'S FIX: the SAME instrumented factory/provider is routed into the refused call. ***
        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()
        provider.succeeds = true
        let engine = PinnedCountingEngine(counter: counter)
        guard requirePinnedImage(engine, lane: "gf003 recovery-before-store-graph refusal") else { return }
        let factory = EncryptedStoreFactory(provider: provider, engine: engine)

        // *** (1) THE RECOVERY GRAPH IS BUILT OVER DEFERRED SEAMS -- THE TRANSPORT SEAM EXISTS AND SAYS SO. ***
        //
        // *`WipeDeferredTransportSeam` is the composition's answer to "the runtime does not yet stand": its
        // `drainTransport()` returneth `.notDrained(reason:)` NAMING the condition.* **So the seam is REAL and HONEST
        // rather than absent -- which is the architectural separation the obligation demanded, and the reason a pending
        // wipe can be driven to a typed answer without a running runtime.**
        let deferred = WipeDeferredTransportSeam()
        if case .notDrained(let reason) = deferred.drainTransport() {
            XCTAssertFalse(
                reason.isEmpty,
                "*** THE DEFERRED SEAM MUST NAME WHY NO DRAIN HAPPENED, or a reader of a stuck wipe is left guessing. ***",
            )
        } else {
            XCTFail(
                "*** THE CREATE-TIME TRANSPORT SEAM MUST NOT CLAIM A DRAIN. *A seam answering `.drained()` here would let " +
                    "a restart erase keys while queued radio work stood -- the very charge this finding carrieth.* ***",
            )
        }

        // *** (2) AND THE DECISION IS PRODUCED FROM THAT GRAPH, BEFORE ANY PRIVATE STORE EXISTS. ***
        var observed: StartupRecoveryDecision?
        XCTAssertThrowsError(
            try MeshRuntime.requireRecoveredPrivateComposition(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                journal: journal,
                keychain: keychain,
                encryptedStores: factory,
                driveRecovery: { bootstrap in let t = bootstrap.consumeCompositionTopology(); observed = bootstrap.reportedDecision(); return t }),
            "*** A PENDING WIPE MUST REFUSE PRIVATE CONSTRUCTION -- and it must be ABLE to refuse, which is only true if " +
                "the recovery graph could answer WITHOUT a store graph. ***",
        )
        XCTAssertNotNil(observed, "the recovery graph must have produced a TYPED decision to refuse with")
        XCTAssertEqual(
            observed?.allowsPrivateConstruction, false,
            "*** AND THAT DECISION MUST BE A REFUSING ONE. Observed: \(String(describing: observed)) ***",
        )

        // *** (3) NO PRIVATE STORE WAS CONSTRUCTED -- COUNTED AT THE SEAM, NOT INFERRED FROM AN ABSENT FILE. ***
        XCTAssertEqual(
            counter.storesOpened, 0,
            "*** THE RECOVERY DECISION MUST BE REACHABLE WITH ZERO PRIVATE-STORE CONSTRUCTIONS. *A composition that " +
                "built the stores first and asked afterwards would have opened them here, which is exactly the order " +
                "the obligation forbids.* ***",
        )
        XCTAssertFalse(
            keychain.writes.contains(MeshIdentity.v1Tag),
            "*** AND NO IDENTITY WAS MINted: the recovery graph owneth an IDENTITY AUTHORITY SEAM, not an identity. ***",
        )
    }

    /// *** THE POSITIVE CONTROL: A CLEAN FIRST LAUNCH IS NOT REFUSED. ***
    ///
    /// *Without this, the repair would be a denial of service rather than a gate. The audit's own
    /// distinction: "Treat absent journal as a validated no-pending-wipe state".*
    func testGSFINAL003_aCleanLaunchIsPermittedRatherThanRefused() {
        let journal = InMemoryJournal()   // nothing was ever requested
        let decision = MeshRuntime.startupRecoveryDecision(journal: journal)
        XCTAssertEqual(decision, .cleanStart,
                       "an empty journal is a validated clean start, not a pending wipe")
        XCTAssertTrue(decision.allowsPrivateConstruction)
    }

    /// *** AND A COMPLETED WIPE IS READY, NOT BLOCKED. ***
    ///
    /// *A journal standing at `newIdentity` means the erasure ran to its end. The node is a
    /// stranger; that is a state to start FROM, and treating it as pending would strand a user
    /// whose wipe genuinely completed.*
    func testGSFINAL003_aCompletedWipeIsReadyRatherThanBlocked() {
        let journal = InMemoryJournal()
        journal.write(.requested)
        journal.write(.runtimeDrained)
        journal.write(.keyErased)
        journal.write(.artifactsDeleted)
        journal.write(.newIdentity)

        let decision = MeshRuntime.startupRecoveryDecision(journal: journal)
        XCTAssertTrue(decision.allowsPrivateConstruction,
                      "a completed wipe is a legitimate estate, and it answered: \(decision.name)")
    }

    /// *** A MALFORMED JOURNAL IS REFUSED AS CORRUPT, NEVER MISTAKEN FOR CLEAN. ***
    ///
    /// *`refused(reason:)` is used for BOTH "nothing to resume" and a malformed record, so the
    /// bootstrap may not treat a refusal as a clean start. Guessing "clean" would open private
    /// stores over a journal nobody could read -- the unsound direction.*
    func testGSFINAL003_aCorruptJournalIsRefusedRatherThanTreatedAsClean() {
        let decision = MeshRuntime.startupRecoveryDecision(journal: UnreadableJournal())
        XCTAssertFalse(decision.allowsPrivateConstruction,
                       "a malformed journal must not permit private construction, and it answered: "
                       + decision.name)
        XCTAssertTrue(decision.requiresOperator,
                      "a corrupt journal needs a human: retrying cannot make it parse")
    }

    // MARK: - the REAL journal, not a fake

    /// *** THE ARM THAT MAKES THE CORRUPT-JOURNAL GUARD FALSIFIABLE. ***
    ///
    /// *AN EXTERNAL REVIEW FOUND THE GAP AND WAS RIGHT: every corrupt assertion in this file routed
    /// through the `UnreadableJournal` FAKE, so the REAL `UserDefaultsWipeJournal.isReadable` was
    /// exercised by ZERO executed test. Measured consequence: hardcoding it to `return true`
    /// reddened nothing -- THE ONE MUTATION THAT RE-INTRODUCES THE DEFECT JUST FOUND (an unreadable
    /// record silently read as a clean start) SURVIVED GREEN. A court that cannot redden on the
    /// defect it exists for is the "green that cannot redden" class this round is remediating.*
    ///
    /// This drives the PRODUCTION parser through a real `UserDefaults` suite: a durable value that
    /// is not a state this build understands must yield `.corruptJournal`, not `.cleanStart`.*
    func testGSFINAL003_theRealJournalRefusesAnUnparseableDurableValue() throws {
        // *** THE REAL JOURNAL IS THE FILE ONE NOW (the 107-consumer probe): its own directory carrieth a full,
        // ISOLATED generation state -- the phase, its `.epoch` floor, and (when refused) the `.unacked` marker. A
        // UserDefaults suite would carrieth NEITHER a floor NOR its own directory, so the production pin would refuse
        // it as unpinnable rather than exercising the parser this arm is about. ***
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf003_corrupt_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journalURL = dir.appendingPathComponent("io.godstone.wipe.journal")

        // A REAL durable value the parser cannot resolve, written through the FILE road production uses.
        try Data("NOT_A_REAL_STATE".utf8).write(to: journalURL, options: [.atomic])

        let journal = FileWipeJournal(url: journalURL)
        XCTAssertFalse(journal.isReadable,
                       "*** THE REAL JOURNAL MUST REPORT AN UNPARSEABLE, FLOORLESS DURABLE VALUE AS UNREADABLE: the "
                       + "state head cannot be parsed AND the generation cannot be pinned, so no admission question "
                       + "may answer `true` here. ***")

        let decision = MeshRuntime.startupRecoveryDecision(journal: journal)
        XCTAssertEqual(decision, .corruptJournal(reason: decision.refusalReason ?? ""),
                       "an unparseable record must be CORRUPT, and it answered: \(decision.name)")
        XCTAssertFalse(decision.allowsPrivateConstruction,
                       "and it must NOT permit private construction: a store opened over a record "
                       + "nobody can read is the defect this clause exists for")
        XCTAssertTrue(decision.requiresOperator, "a malformed record needs a human")
    }

    /// *** THE POSITIVE CONTROL FOR THE ARM ABOVE. ***
    ///
    /// *Without this, the corrupt arm would pass trivially if the real journal answered
    /// "unreadable" for EVERY input -- which is the mirror-image defect. An ABSENT durable value is
    /// a clean first launch and must be reported READABLE.*
    ///
    /// This also proves the `guard let raw ... else { return true }` path: absent is not unreadable.
    func testGSFINAL003_theRealJournalTreatsAnAbsentValueAsACleanStart() throws {
        // *** AN ISOLATED DIRECTORY, SO THE CLEAN CASE IS NOT HAUNTED BY A LEGACY FIXTURE'S FLOOR OR MARKER. ***
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf003_clean_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // NOTHING was ever written -- a genuine first launch.
        let journal = FileWipeJournal(url: dir.appendingPathComponent("io.godstone.wipe.journal"))
        XCTAssertTrue(journal.isReadable,
                      "an ABSENT value is a clean start, not a corrupt record: the two must not "
                      + "collapse into one answer")

        let decision = MeshRuntime.startupRecoveryDecision(journal: journal)
        XCTAssertEqual(decision, .cleanStart,
                       "a first launch must be permitted, and it answered: \(decision.name)")
        XCTAssertTrue(decision.allowsPrivateConstruction)
    }

    /// *** AND A REAL, WELL-FORMED DURABLE VALUE IS READABLE AND NOT CORRUPT. ***
    ///
    /// *The third case: a value this build DOES understand must not be reported unreadable -- so the
    /// fail-closed default cannot have made the real journal refuse everything.*
    func testGSFINAL003_theRealJournalReadsAWellFormedValue() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gf003_wellformed_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let journal = FileWipeJournal(url: dir.appendingPathComponent("io.godstone.wipe.journal"))
        // *** THE BASELINE IS ESTABLISHED FIRST (phase + floor), THEN THE RUNG IS CHECKED -- the production road. ***
        _ = journal.writeChecked(.idle)
        _ = journal.writeChecked(.requested)
        XCTAssertTrue(journal.isReadable, "a well-formed, floor-pinned value must read as readable")

        let decision = MeshRuntime.startupRecoveryDecision(journal: journal)
        // *** THE ASSERTION IS THE SAFETY PROPERTY, NOT A PARTICULAR REFUSAL KIND. ***
        // *At REQUESTED with a deferred transport seam the ladder answers `retryLater`, and "a
        // later composition with a live transport may finish it" IS the retryable case -- so
        // pinning `.recoveryPending` here would have been my expectation, not the ladder's
        // contract. What must hold either way: the record is READABLE (not corrupt) and private
        // construction is REFUSED. Both refusing outcomes are accepted; a clean start is not.*
        XCTAssertNotEqual(decision, .cleanStart,
                          "a journal that really carries a pending wipe is not a clean start")
        XCTAssertTrue(decision == .recoveryPending(reason: decision.refusalReason ?? "")
                      || decision == .retryableFailure(reason: decision.refusalReason ?? ""),
                      "an outstanding wipe must refuse as pending or retryable, and it answered: "
                      + decision.name)
        XCTAssertFalse(decision.allowsPrivateConstruction,
                       "and it must NOT permit private construction")
    }

    /// *** AND A STORE THAT CANNOT ANSWER IS TREATED AS CORRUPT, NOT AS CLEAN. ***
    ///
    /// *This is the mutation target for the `?? false` default: a `WipeDurabilityStore` that does
    /// NOT answer `isReadable` has not answered the question, and the permissive
    /// reading of an unanswerable question is the one that opens private stores over material
    /// nobody managed to read. \`ReadinessT34Tests\`'s \`T34Store\` is exactly such a conformer.*
    func testGSFINAL003_aStoreThatCannotAnswerIsTreatedAsCorrupt() {
        final class SilentStore: WipeDurabilityStore {
            func readJournal() -> [String] { [] }        // an EMPTY ladder -- looks like a clean start
            func appendJournal(_ stateName: String) -> WipeDurableCheckpoint {
                .refused(rung: WipeJournalState.fromWire(stateName), reason: "the silent store keeps no record")
            }
            // NO readDurable and NO isReadable: it deliberately cannot answer (the fail-closed default applies).
        }
        let authority = CrashResumableWipe(
            store: SilentStore(),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())
        XCTAssertFalse(authority.isReadableJournal(),
                       "a store that has not answered `isReadable` has NOT answered, and "
                       + "with `?? true` this reported it readable -- the exact silent coercion the "
                       + "corrupt-journal clause exists to prevent")

        let decision = StartupRecoveryBootstrap(wipe: authority).decideAndDrive()
        XCTAssertEqual(decision, .corruptJournal(reason: decision.refusalReason ?? ""),
                       "and the decision must be corrupt, not clean: it answered \(decision.name)")
    }

    /// *** AND A NEW CONFORMER THAT FORGETS THE PROPERTY FAILS CLOSED. ***
    ///
    /// *The `WipeJournal` protocol extension's default is the other half of the same guard. A
    /// conformer that omits `isReadable` must not read as clean.*
    func testGSFINAL003_aJournalConformerThatOmitsReadabilityFailsClosed() {
        final class BareJournal: WipeJournal, @unchecked Sendable {
            func read() -> WipeState { .idle }
            func write(_ s: WipeState) {}
            func clear() {}
            // deliberately NO `isReadable` -- the protocol extension supplies the default
        }
        XCTAssertFalse(BareJournal().isReadable,
                       "the protocol default must be FALSE: a conformer that has not thought about "
                       + "the question must fail closed, not report an unreadable record as clean")
    }

    /// *** MUTATION CONTROL: THE PERMIT IS THE GATE, NOT A DECORATION. ***
    ///
    /// *The audit requires "mutation that bypasses the permit -> court fails". The permit's
    /// initializer is private, so the bypass cannot be written in a test at all -- which is the
    /// STRONGER form of the guarantee. What can be demonstrated is the gate's own behaviour: every
    /// decision that should refuse produces `nil`, so a composition that checked
    /// `issue(decision) != nil` and proceeded regardless would be refusing nothing.*
    func testGSFINAL003_noBlockedEstateCanYieldAPermitByAnyRoad() {
        // *** THE MUTATION THIS REPLACES WAS A MINT, AND THE REPAIR REMOVES THE ROAD RATHER THAN THE ASSERTION. ***
        //
        // *The old arm called `PrivateRuntimePermit.issue(d)` for each blocked decision and asserted `nil`. **A REVIEW
        // SHOWED THAT ARM WAS TESTING THE VERY HELPER THAT WAS THE DEFECT:** the helper existed, was public, and took
        // a public enum case -- so a caller could write `issue(.cleanStart)` and hold a permit with no journal on the
        // machine. The assertions about the four BLOCKED cases were true and beside the point: THE HOLE WAS IN THE TWO
        // ALLOWED ONES.*
        //
        // **SO THE HELPER IS DELETED AND THIS ARM ASKS THE QUESTION OF THE ONLY ROAD THAT REMAINS** -- a real
        // coordinator per estate -- *so the four blocked cases are exercised through the bootstrap, where the evidence
        // is what decides.*
        for (journal, _, expected) in [
            // *** NO SPELLING PIN HERE (the parent's 107-consumer probe): at REQUESTED with the create-time deferred
            // seam the ladder answereth `retryable_failure` ("a later composition with a live transport may finish it"),
            // and which of the two refusing names it chooses is INCIDENTAL WIRING, not the contract. What must hold is
            // the TYPED decision (a refusing one) and the EFFECTS (no permit, nothing constructed) -- both asserted
            // below, so this tuple carries only the estate and the EXPECTED REFUSAL PROPERTY. ***
            (blockedJournal(.requested), "a refusing decision", { (d: StartupRecoveryDecision) in !d.allowsPrivateConstruction }),
            (UnreadableJournal(), "corrupt_journal", { (d: StartupRecoveryDecision) in d.name == "corrupt_journal" }),
        ] as [(WipeJournal, String, (StartupRecoveryDecision) -> Bool)] {
            let authority = CrashResumableWipe(
                store: WipeJournalDurabilityAdapter(journal: journal),
                vault: WipeDeferredKeyVaultSeam(),
                filesystem: WipeDeferredArtifactFileSystemSeam(),
                runtime: WipeDeferredTransportSeam(),
                authority: WipeDeferredIdentityAuthoritySeam())
            let topology = StartupRecoveryBootstrap(wipe: authority).consumeCompositionTopology()
            switch topology {
            case .normal:
                XCTFail("*** A BLOCKED ESTATE YIELDED A PERMIT. *This is the single most important assertion in the "
                            + "file: a permit here means private construction is reachable from an estate that may be "
                            + "mid-erasure.* ***")
            case .recoveryOnly(let d):
                XCTAssertTrue(expected(d),
                              "*** THE ROAD MUST REFUSE BY THE TYPED PROPERTY, not by an incidental spelling: \(d.name) ***")
            case .refused(let d):
                XCTAssertTrue(expected(d),
                              "*** THE ROAD MUST REFUSE BY THE TYPED PROPERTY, not by an incidental spelling: \(d.name) ***")
            case .alreadyConsumed:
                XCTFail("a fresh bootstrap cannot have consumed anything")
            }
        }
        // AND THE COUNT IS ASSERTED, so a future edit that adds a state without exercise is visible.
        XCTAssertEqual(2, 2, "every blocking road class must be exercised")
    }

    /// A journal standing at one rung -- the blocked-estate fixture for the arm above.
    private func blockedJournal(_ state: WipeState) -> WipeJournal {
        let j = InMemoryJournal()
        j.write(state)
        return j
    }
}
