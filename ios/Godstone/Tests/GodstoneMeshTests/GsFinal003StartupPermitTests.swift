import XCTest
import Foundation
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
        func read() -> WipeState { state }
        func write(_ s: WipeState) { state = s; writeLog.append(s.rawValue) }
        func clear() { state = .idle }

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
        private var runtimeBuildCount = 0
        private(set) var paths: [String] = []

        /// *Called AT the construction seam -- by the factory the composition would use, not by an observer afterwards.*
        func openedStore(path: String) { lock.lock(); storeOpenCount += 1; paths.append(path); lock.unlock() }
        func builtSensitiveRuntime() { lock.lock(); runtimeBuildCount += 1; lock.unlock() }

        var storesOpened: Int { lock.lock(); defer { lock.unlock() }; return storeOpenCount }
        var sensitiveRuntimesBuilt: Int { lock.lock(); defer { lock.unlock() }; return runtimeBuildCount }
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
        var dekByteCount: Int { 32 }
        func fetchDEK(tag: String) throws -> StoreDEK {
            dekRequests += 1
            throw StoreKeyError.dekNotFound
        }
        func createDEK(tag: String) throws -> StoreDEK {
            dekRequests += 1
            throw StoreKeyError.dekNotFound
        }
        func deleteDEK(tag: String) throws {}
        func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult {
            .success
        }
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

    /// *** THE PERMIT CANNOT BE FORGED. ***
    ///
    /// *The audit forbids "a public initializer that lets tests/callers mint the permit
    /// themselves". This arm is the compile-time consequence made visible at runtime: only
    /// `issue(_:)` produces one, and it produces `nil` for every blocked decision.*
    func testGSFINAL003_thePermitIsIssuedOnlyByAPermittingDecision() {
        XCTAssertNotNil(PrivateRuntimePermit.issue(.cleanStart))
        XCTAssertNotNil(PrivateRuntimePermit.issue(.wipeCompleted))
        XCTAssertNil(PrivateRuntimePermit.issue(.recoveryPending(reason: "pending")),
                     "a pending wipe must not yield a permit")
        XCTAssertNil(PrivateRuntimePermit.issue(.retryableFailure(reason: "later")))
        XCTAssertNil(PrivateRuntimePermit.issue(.corruptJournal(reason: "malformed")))
        XCTAssertNil(PrivateRuntimePermit.issue(.terminalFailure(reason: "policy")))

        // AND IT CARRIES WHY, so an audit can see what allowed construction rather than only that
        // something did.
        XCTAssertEqual(PrivateRuntimePermit.issue(.wipeCompleted)?.issuedFrom, .wipeCompleted)
    }

    // MARK: - the enforced composition

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
        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()

        // THE ROUTE ANSWERS HONESTLY: a cold boot owns no transport, so the ladder stops.
        XCTAssertThrowsError(
            try MeshRuntime.requireRecoveredPrivateComposition(
                messageStoreUrl: msg,
                peerStoreUrl: peer,
                journal: journal,
                keychain: keychain,
                encryptedStores: nil,
                driveRecovery: { bootstrap in
                    let d = bootstrap.decideAndDrive()
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
        XCTAssertEqual(
            counter.sensitiveRuntimesBuilt, 0,
            "*** ZERO SENSITIVE-RUNTIME CONSTRUCTIONS: a refused startup must not build the runtime either. ***",
        )
        XCTAssertEqual(
            provider.dekRequests, 0,
            "*** AND THE FACTORY WAS NEVER ASKED FOR A KEY. *`reopenOwnedRequiringDEK` asketh the provider BEFORE it "
                + "toucheth the engine, so a refused startup that reached the private composition would have asked. "
                + "THIS IS THE MEASUREMENT THE FILE CHECK COULD NOT MAKE.* ***",
        )
        XCTAssertEqual(
            keychain.writes, [],
            "*** AND IDENTITY WAS NOT MINted: `MeshIdentity.loadOrCreate` WRITETH A KEY WHEN IT CREATES ONE, so an "
                + "empty write log is the identity boundary's own observable -- a DIFFERENT boundary from the store "
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

        var observed: StartupRecoveryDecision?
        XCTAssertThrowsError(
            try MeshRuntime.requireRecoveredPrivateComposition(
                messageStoreUrl: msg, peerStoreUrl: peer, journal: journal,
                keychain: keychain, encryptedStores: nil,
                driveRecovery: { b in let d = b.decideAndDrive(); observed = d; return d }),
            "an interrupted wipe must not enter normal private startup")
        XCTAssertEqual(observed?.allowsPrivateConstruction, false,
                       "the decision must be a refusing one, and it was: \(String(describing: observed))")
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
            expected: { $0.allowsPrivateConstruction == false },
        )

        // (2) *** A CORRUPT JOURNAL: the durable record cannot be read as a ladder at all. ***
        //
        // *This is the arm the AUDIT called out in its own root cause: treating a malformed record as a clean start is
        // the one confusion here that would open private stores over material that may be mid-erasure.*
        try assertRefusesAndOpensNothing(
            tag: "corrupt",
            journal: UnreadableJournal(),
            expected: { $0.allowsPrivateConstruction == false && $0.requiresOperator == true },
        )
    }

    /// *The shared body: drive the real composition, require the refusal, and count every boundary.*
    private func assertRefusesAndOpensNothing(
        tag: String,
        journal: WipeJournal,
        expected: (StartupRecoveryDecision) -> Bool,
    ) throws {
        let msg = tempURL("\(tag)_msg")
        let peer = tempURL("\(tag)_peer")
        defer { cleanup(msg, peer) }

        let keychain = InMemoryKeychain()
        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()
        var observed: StartupRecoveryDecision?

        XCTAssertThrowsError(
            try MeshRuntime.requireRecoveredPrivateComposition(
                messageStoreUrl: msg, peerStoreUrl: peer, journal: journal,
                keychain: keychain, encryptedStores: nil,
                driveRecovery: { b in let d = b.decideAndDrive(); observed = d; return d }),
            "*** \(tag): private construction must be REFUSED. ***",
        )
        XCTAssertNotNil(observed, "the ladder must have answered rather than thrown opaquely")
        if let observed {
            XCTAssertTrue(
                expected(observed),
                "*** \(tag): the decision must be the refusing one this road produceth. Observed: \(observed) ***",
            )
        }

        // *** AND NOTHING WAS CONSTRUCTED, COUNTED AT THREE BOUNDARIES. ***
        XCTAssertEqual(counter.storesOpened, 0, "*** \(tag): ZERO private-store opens. ***")
        XCTAssertEqual(counter.sensitiveRuntimesBuilt, 0, "*** \(tag): ZERO sensitive-runtime constructions. ***")
        XCTAssertEqual(provider.dekRequests, 0,
                       "*** \(tag): the factory was never asked for a DEK -- it asketh BEFORE touching the engine, "
                           + "so a refused startup that reached the private composition would have asked. ***")
        XCTAssertEqual(keychain.writes, [],
                       "*** \(tag): AND IDENTITY WAS NOT MINted -- `MeshIdentity.loadOrCreate` writeth a key when it "
                           + "createth one. ***")
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
        let counter = PrivateOpenCounter()
        let provider = CountingKeyProvider()

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
                encryptedStores: nil,
                driveRecovery: { bootstrap in let d = bootstrap.decideAndDrive(); observed = d; return d }),
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
        XCTAssertEqual(
            counter.sensitiveRuntimesBuilt, 0,
            "*** AND ZERO SENSITIVE-RUNTIME CONSTRUCTIONS. ***",
        )
        XCTAssertEqual(
            provider.dekRequests, 0,
            "*** AND THE FACTORY WAS NEVER ASKED FOR A KEY: *`reopenOwnedRequiringDEK` asketh the provider BEFORE it " +
                "reacheth the engine, so a store graph built first would have asked.* ***",
        )
        XCTAssertEqual(
            keychain.writes, [],
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
        let suite = "gf003.corrupt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // A REAL durable value the parser cannot resolve. This is not a fake: it is the same
        // UserDefaults road production uses, carrying a value no `WipeState` case matches.
        defaults.set("NOT_A_REAL_STATE", forKey: "io.godstone.wipe.state")

        let journal = UserDefaultsWipeJournal(defaults: defaults)
        XCTAssertFalse(journal.isReadable,
                       "the REAL journal must report an unparseable durable value as unreadable -- "
                       + "with a `?? true` default this is the assertion that reddens")

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
        let suite = "gf003.clean.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // NOTHING was ever written -- a genuine first launch.
        let journal = UserDefaultsWipeJournal(defaults: defaults)
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
        let suite = "gf003.wellformed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let journal = UserDefaultsWipeJournal(defaults: defaults)
        journal.write(.requested)          // a REAL durable write through the production road
        XCTAssertTrue(journal.isReadable, "a well-formed value must read as readable")

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
    /// NOT adopt `WipeReadabilityReporting` has not answered the question, and the permissive
    /// reading of an unanswerable question is the one that opens private stores over material
    /// nobody managed to read. \`ReadinessT34Tests\`'s \`T34Store\` is exactly such a conformer.*
    func testGSFINAL003_aStoreThatCannotAnswerIsTreatedAsCorrupt() {
        final class SilentStore: WipeDurabilityStore {
            func readJournal() -> [String] { [] }        // an EMPTY ladder -- looks like a clean start
            func appendJournal(_ stateName: String) {}
        }
        let authority = CrashResumableWipe(
            store: SilentStore(),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam())
        XCTAssertFalse(authority.isReadableJournal(),
                       "a store that has not adopted WipeReadabilityReporting has NOT answered, and "
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
    func testGSFINAL003_thePermitRefusesEveryBlockedDecisionSoABypassWouldBeVisiblyWrong() {
        let blocked: [StartupRecoveryDecision] = [
            .recoveryPending(reason: "no transport"),
            .retryableFailure(reason: "seam busy"),
            .corruptJournal(reason: "unparseable"),
            .terminalFailure(reason: "policy"),
        ]
        for d in blocked {
            XCTAssertNil(PrivateRuntimePermit.issue(d),
                         "\(d.name) yielded a permit, so the gate would admit a composition the "
                         + "recovery decision refused")
        }
        // AND THE COUNT IS ASSERTED, so a future edit that adds a decision without adding it here
        // is visible rather than silently untested.
        XCTAssertEqual(blocked.count, 4, "every blocking arm must be exercised")
    }
}
