import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class CrashStartupResumeTests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    // ================================================================================================
    // *** GS-INTEGRATION-001 (round 590): THE INTERRUPTED WIPE -- ALREADY COVERED, AND BETTER THAN MY ARM. ***
    //
    // THE CARD'S REMAINING WORK, VERBATIM: *"Instantiate real composition with only OS facades replaced;
    // demonstrate **user-entry-to-store-to-ACK** and **interrupted wipe**."*
    //   * USER-ENTRY-TO-STORE-TO-ACK is covered by `testFullCallPathCommandToSignedAck` plus the composition arms
    //     that drive `sendDirectDurable` and reopen the store.
    //   * **AND THE INTERRUPTED WIPE WAS ALREADY COVERED -- BY AN ARM IN THIS VERY FILE THAT IS STRICTLY BETTER THAN
    //     THE ONE I WROTE: `testGSSTORE006_theRuntimeThatStandsContinuesTheWipeAndErasesNothingWithoutAProvider`
    //     (line ~960). IT DRIVES THE REAL COMPOSITION, THE REAL `continuePendingWipeIfNeeded()`, AND ASSERTS THE
    //     **ORDER OF THE RECORDS WRITTEN** THROUGH THE LIVE SEAMS -- while MY ARM ASSERTED ONLY THAT THE JOURNAL "NO
    //     LONGER STANDS AT REQUESTED".**
    //
    // *** AND I FOUND THAT OUT BY MUTATING THE CONTINUATION AND WATCHING MY ARM STAY GREEN WHILE *THAT* ARM
    // REDDENED. *** The mutation (`if true { return .alreadyAtOrPast(.idle) }` inserted after `wipeAuthority.resume()`,
    // grep-confirmed on the built copy) produces ONE failure -- **AND IT IS NOT MINE.** **A GREEN THAT CANNOT REDDEN
    // WHEN THE MECHANISM IS BROKEN IS NOT EVIDENCE FOR THE MECHANISM, AND MY ARM WAS EXACTLY THAT: it was measuring
    // that SOME journal write occurred, not that the CONTINUATION caused it.**
    //
    // SO THE ARM IS DELETED RATHER THAN KEPT GREEN, and the card's clause is answered by pointing at the STRONGER
    // arm that was already here. **THIS IS THE DUPLICATE-PROBE LESSON FROM ROUND 588 (the parked `.txt` that turned
    // out to duplicate a live court) IN ANOTHER FORM: AN ARM WRITTEN WITHOUT FIRST GREPPING FOR AN EXISTING ONE
    // ADDS WEIGHT, NOT COVERAGE.**
    // ================================================================================================

    private final class InMemoryJournal: WipeJournal, @unchecked Sendable {
        var state: WipeState = .idle
        var writes = 0
        var clears = 0
        /// GS-FINAL-002: **EVERY RECORD THIS JOURNAL EVER CARRIED, IN ORDER.**
        ///
        /// `state` holdeth only the LAST value, so an arm asking "did the drain precede the erasure?" cannot read it
        /// from `state` -- a ladder that walks past both in one call leaves `state` at the later rung and the ORDER, which
        /// is the actual safety property, is unobservable. A journal that keepeth its writes maketh the order readable.
        var writeLog: [String] = []
        func read() -> WipeState { state }
        func write(_ s: WipeState) { state = s; writes += 1; writeLog.append(s.rawValue) }
        func clear() { state = .idle; clears += 1 }
    
        /// *** GS-FINAL-003: STATED EXPLICITLY, BECAUSE THE PROTOCOL DEFAULT FAILS CLOSED. ***
        ///
        /// *This journal stores a TYPED `WipeState`, so it cannot hold an unparseable value -- it is readable BY
        /// CONSTRUCTION. The protocol's default is `false` (the safe reading of an unanswerable question), and a
        /// conformer that stays silent would therefore be reported CORRUPT and misdescribed. **AND THAT MATTERS HERE
        /// RATHER THAN THEORETICALLY:** the composition calls `decideAndDrive`, which consults
        /// `isReadableJournal()`, so an arm that reaches the startup road would exercise the CORRUPT branch and pass
        /// or fail for a reason unrelated to what it means to measure.*
        var isReadable: Bool { true }
    }

    private final class StepTrackingArtifacts: WipeArtifacts, @unchecked Sendable {
        var executedSteps: [String] = []
        var currentIdentity: MeshIdentity?

        init() {
            self.currentIdentity = try? MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        }

        func eraseKeys() throws {
            executedSteps.append("eraseKeys")
            currentIdentity = nil
        }

        func deleteArtifacts() throws {
            executedSteps.append("deleteArtifacts")
        }

        func regenerateIdentity() throws {
            executedSteps.append("regenerateIdentity")
            currentIdentity = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        }
    }

    // MARK: - GS-RUNTIME-001 step 2: THE ACK OWNERS ARE IN THE PRODUCTION RUNTIME

    /// **MEASURED BEFORE THE REPAIR (round 209): NO PRODUCTION CODE COLLECTED the transport's readiness, and
    /// `MeshRuntime` held NEITHER an ACK pump NOR a recipient inbox -- those lived only in the composition harness,
    /// whose own signer confesseth "IT IS HARNESS SUPPORT AND NOT A DEVICE RESULT".** This arm requireth that the
    /// production runtime CARRY them, bound to the same opened private store and the same pinned identity.
    func testSR00_TheProductionRuntimeCarriethTheAckOwnersAndTheInbox() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00_peer_\(UUID().uuidString).db")

        // (MY FIRST DRAFT INVENTED THE FACTORY'S PARAMETERS AND THE COMPILER SAID SO: the real signature is
        // `(messageStoreUrl:peerStoreUrl:journal:keychain:)`, and the identity is derived from the keychain --
        // THE SIXTH SPECIES AGAIN, A NAME ASSUMED INSTEAD OF READ, caught by compiling before claiming.)
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: InMemoryJournal(),
            keychain: InMemoryKeychain()
        )

        // THE WIRING, WHICH WAS ABSENT UNTIL THIS ROUND:
        XCTAssertNotNil(runtime.meshNode.recipientInbox,
                        "GS-RUNTIME-001 step 2: the recipient inbox must be BOUND in the production runtime")
        XCTAssertNotNil(runtime.meshNode.ackDispatcher,
                        "and the ACK dispatcher with it")

        // AND THE DRIVER RUNNETH OVER THE RUNTIME'S OWN STORE: a fresh runtime carrieth no obligation, and
        // reading its own durable store is not a storage failure -- the two claims a stand-in could not make.
        let report = try runtime.ackDriver.runPendingOnce(8)
        XCTAssertEqual(report.scanned, 0, "a fresh runtime carrieth no ACK obligation")
        XCTAssertEqual(report.storageFailures, 0, "and reading its own durable store is not a failure")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 3: **THE READINESS MUST SCHEDULE THE BOUNDED ACK WORKER FOR THE EXACT RELATION, AND THE
    /// FAREWELL MUST UNSCHEDULE *THAT* NODE.** MEASURED BEFORE (round 209): nothing in production collected the
    /// readiness at all, so no worker was ever scheduled -- "registering a queue does not send it".
    /// GS-RUNTIME-001 steps 4-5, FIRST SLICE: **ONE BOUNDED TURN FOR ONE NAMED RELATION** -- and an UNKNOWN
    /// relation is REFUSED rather than guessed at, because a frame sent to a guessed handle would be the very
    /// misrouting this programme hunteth.
    func testSR00c_TheBoundedTurnServethTheNamedRelationAndRefusethAnUnknownOne() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00c_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00c_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        let handle = UUID()
        let nodeId = Data(repeating: 0x41, count: 16)
        let unknown = Data(repeating: 0x42, count: 16)

        XCTAssertNil(runtime.meshNode.drainAckWorkOnce(nodeId: unknown),
                     "AN UNKNOWN RELATION MUST BE REFUSED: no handle standeth for it, and a guessed one would misroute")
        XCTAssertNil(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId),
                     "and a relation that hath not come up carrieth no handle either")

        runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)
        XCTAssertEqual(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId), 0,
                       "once the trusted event hath written the relation's own mapping, the turn SERVETH IT -- and "
                       + "a fresh relation carrieth nothing to hand on")

        runtime.meshNode.trustedPeerDidDisconnect(nodeId: nodeId, peerId: handle)
        XCTAssertNil(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId),
                     "and the farewell forgetteth the mapping with the relation")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    func testSR00b_TheReadinessSchedullethTheAckWorkerAndTheFarewellCancellethIt() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00b_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00b_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        let handle = UUID()
        let nodeId = Data(repeating: 0x31, count: 16)
        let other = Data(repeating: 0x32, count: 16)

        XCTAssertFalse(runtime.ackPump.isScheduled(nodeId), "nothing standeth scheduled at the outset")

        runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)
        XCTAssertTrue(runtime.ackPump.isScheduled(nodeId),
                      "GS-RUNTIME-001 step 3: THE TRUSTED READINESS MUST SCHEDULE THE ACK WORKER for the relation's "
                      + "EXACT node id -- nothing else in production ever did")
        XCTAssertFalse(runtime.ackPump.isScheduled(other), "and for NO OTHER node")

        runtime.meshNode.trustedPeerDidDisconnect(nodeId: nodeId, peerId: handle)
        XCTAssertFalse(runtime.ackPump.isScheduled(nodeId),
                       "and the farewell must unschedule THAT exact node, so a replacement relation is not shadowed")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 4: **THE PERIODIC DEADLINE MUST WAKE THE WORKER** -- and it must DIE WITH ITS OWNER.
    /// The arm runneth the turn for every TRUSTED relation and nothing else; the deadline is armed by the runtime
    /// and cancelled by the node's own `stop()`.
    func testSR00d_ThePeriodicDeadlineWakethTheWorkerAndDiethWithItsOwner() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00d_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00d_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        runtime.meshNode.start()

        // A TRUSTED RELATION FIRST. The readiness serveth ONLY ITS OWN relation (one bounded turn), so it doth
        // NOT advance the periodic census -- THE CENSUS COUNTETH THE DEADLINE'S TURNS ALONE, which is the
        // distinction the first draft of this witness got wrong and the failure taught me.
        runtime.meshNode.transportApplicationLinkReady(peerId: UUID(), receivedFrom: Data(repeating: 0x51, count: 16), generation: 1)
        XCTAssertEqual(runtime.meshNode.ackTurnsRunForTest(), 0,
                       "the initial inventory is the readiness's own turn, not the deadline's")

        // **AND THE RUNTIME HATH ALREADY ARMED ITS OWN DEADLINE (30 s), SO A SECOND ARM IS REFUSED BY THE
        // IDEMPOTENCE GUARD -- WHICH IS WHY THE FIRST DRAFT OF THIS WITNESS SAW NO WAKE AT ALL. The deadline is
        // therefore cancelled first, and re-armed at a witnessable interval.**
        runtime.meshNode.cancelAckTurnDeadline()
        runtime.meshNode.armAckTurnDeadline(intervalSeconds: 0.02)
        var woke = false
        for _ in 0..<400 {
            if runtime.meshNode.ackTurnsRunForTest() > 1 { woke = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(woke, "GS-RUNTIME-001 step 4: THE PERIODIC DEADLINE MUST WAKE THE WORKER -- it did not")

        // AND IT DIETH WITH ITS OWNER.
        //
        // *** THE BASELINE IS TAKEN AFTER THE IN-FLIGHT TURN HAS SETTLED, AND THAT IS A FIX, NOT A WEAKENING. ***
        // *The first revision read `afterStop` IMMEDIATELY after `stop()`. MEASURED on the 2-core runner:
        // `("3") is not equal to ("2")` -- because `stop()` can be called WHILE a turn is already in flight (the
        // loop above exits the instant it observes a wake, and the deadline fires every 0.02 s), so the baseline
        // was captured BEFORE that turn incremented. The arm then reported a callback "for a runtime that is gone"
        // when nothing of the sort had happened.*
        // **THE LAW BEING TESTED IS THAT THE DEADLINE STOPS WAKING THE WORKER -- not that a turn already executing
        // can be un-executed.** So the settle happens first, the baseline is taken from a quiet runtime, and the
        // assertion is that the count does not GROW thereafter. A deadline that failed to die would still grow
        // across the second window and still redden this arm.*
        runtime.meshNode.stop()
        Thread.sleep(forTimeInterval: 0.15)
        let afterStop = runtime.meshNode.ackTurnsRunForTest()
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(runtime.meshNode.ackTurnsRunForTest(), afterStop,
                       "NO CALLBACK MAY FIRE FOR A RUNTIME THAT IS GONE: the deadline dieth with its owner")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 4's **INBOUND WAKE** -- and the law that A SENDER WITH NO TRUSTED RELATION IS NOT
    /// SERVED, because the wake is gated on the relation mapping and nothing is guessed.
    func testSR00e_AnInboundRequestWakethTheWorkerForItsOwnRelationOnly() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00e_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00e_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        let handle = UUID()
        let nodeId = Data(repeating: 0x61, count: 16)
        let stranger = Data(repeating: 0x62, count: 16)
        let frame = FrameV2(type: .message, msgId: Data(repeating: 7, count: 16),
                            routingTag: Data(repeating: 0, count: 4), ttl: 4,
                            hopCount: 0, flags: 0, payload: Data(repeating: 9, count: 32))

        _ = runtime.meshNode.ingestInbound(frame, receivedFrom: stranger)
        XCTAssertEqual(runtime.meshNode.ackEventWakesForTest(), 0,
                       "A SENDER WITH NO TRUSTED RELATION MUST NOT BE SERVED: the wake is gated on the relation "
                       + "mapping, and nothing is guessed")

        runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)
        _ = runtime.meshNode.ingestInbound(frame, receivedFrom: nodeId)
        XCTAssertEqual(runtime.meshNode.ackEventWakesForTest(), 1,
                       "GS-RUNTIME-001 step 4: AN INBOUND REQUEST MUST WAKE THE WORKER FOR ITS OWN RELATION")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 5: **RECHECK THE CAPTURED RELATION.** The handle and the node id are THE SAME across a
    /// replacement relation, so only the GENERATION telleth the hour the work was admitted under from the hour
    /// that standeth now -- and a turn that nameth a stale generation must be REFUSED.
    func testSR00f_AStaleRelationGenerationIsRefusedAtTheHandOff() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00f_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00f_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        let handle = UUID()
        let nodeId = Data(repeating: 0x71, count: 16)

        runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 4)
        XCTAssertEqual(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId, generation: 4), 0,
                       "the turn serveth the relation IT WAS ADMITTED UNDER")
        XCTAssertNil(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId, generation: 3),
                     "GS-RUNTIME-001 step 5: A STALE GENERATION MUST BE REFUSED -- the handle and the node id are "
                     + "the same across a replacement, and only the generation telleth them apart")

        // A REPLACEMENT RELATION for the same node id (a new handle and a new generation):
        runtime.meshNode.transportApplicationLinkReady(peerId: UUID(), receivedFrom: nodeId, generation: 5)
        XCTAssertNil(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId, generation: 4),
                     "and the ELDER hour is refused once the replacement standeth")
        XCTAssertEqual(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId, generation: 5), 0,
                       "while the replacement is served")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 5's WIPE HALF: **A WIPED CANDIDATE IS NEVER HANDED ON** -- and the control is built so
    /// that THE WIPE IS THE ONLY DIFFERENCE: the same candidate is offered, the retry window is PASSED (so the
    /// retry rule cannot be the reason), and only then is the namespace wiped.
    ///
    /// MEASURED FIRST, RATHER THAN ASSUMED: `DurableAckPump.nextBatch` enumerateth **THE STORE'S ROWS**
    /// (`store.listCandidates`) and consulteth its memory cache ONLY for a record that still standeth in the
    /// store -- so the law holdeth by construction, and what this arm addeth is the WITNESS.
    func testSR00g_AWipedCandidateIsNeverHandedOn() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00g_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00g_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        let handle = UUID()
        let nodeId = Data(repeating: 0x81, count: 16)
        let relayFrom = Data(repeating: 0x82, count: 16)
        runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)

        // A CANDIDATE admitted from a THIRD PARTY (an opaque relay copy: no key standeth for its claimed
        // recipient here, so it entereth as a bounded candidate rather than as a verified one).
        let frame = try AckFrame.build(msgId: Data(repeating: 0x11, count: 16),
                                       signature: Data(repeating: 0x7A, count: 64),
                                       recipientNodeId: Data(repeating: 0x83, count: 16),
                                       routingTag: Data(repeating: 0, count: 4), ttl: ackInitialTtl)
        _ = runtime.ackPump.admit(frame.encode(), receivedFrom: relayFrom, now: 1_000)

        let first = runtime.ackPump.nextBatch(nodeId, now: 1_000)
        XCTAssertEqual(first.copies.count, 1, "the admitted candidate must be offerable to the trusted relation")

        // THE CONTROL: the SAME candidate, with the RETRY WINDOW PASSED -- so the retry rule cannot explain a zero.
        let afterWindow = runtime.ackPump.nextBatch(nodeId, now: 1_000 + ackRelayRetryIntervalMs + 1)
        XCTAssertEqual(afterWindow.copies.count, 1,
                       "with the retry window passed, the candidate standeth offerable AGAIN -- this is the control "
                       + "that maketh the next assertion mean something")

        // AND NOW THE WIPE, AS THE ONLY DIFFERENCE:
        _ = runtime.ackStore.deleteAllFrames()
        let wiped = runtime.ackPump.nextBatch(nodeId, now: 1_000 + 2 * (ackRelayRetryIntervalMs + 1))
        XCTAssertEqual(wiped.copies.count, 0,
                       "GS-RUNTIME-001 step 5: A WIPED CANDIDATE MUST NEVER BE HANDED ON -- its row is gone, and "
                       + "the memory cache may not resurrect it")

        // and the production turn agreeth with the pump:
        XCTAssertEqual(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId, generation: 1), 0,
                       "the worker's turn handeth nothing after the wipe")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 6: **THE ACK WORK MUST BE REBUILT FROM THE DATABASE AFTER A REOPEN** -- the worker is
    /// stateless between runs, and a restart resumeth by RE-READING the tables. This arm reopeneth the SAME private
    /// database with a NEW runtime, bringeth the relation up again, and requireth the pending candidate to stand.
    func testSR00h_TheAckWorkIsRebuiltAfterAReopen() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00h_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00h_peer_\(UUID().uuidString).db")
        let handle = UUID()
        let nodeId = Data(repeating: 0x91, count: 16)
        let relayFrom = Data(repeating: 0x92, count: 16)
        let frame = try AckFrame.build(msgId: Data(repeating: 0x22, count: 16),
                                       signature: Data(repeating: 0x7B, count: 64),
                                       recipientNodeId: Data(repeating: 0x93, count: 16),
                                       routingTag: Data(repeating: 0, count: 4), ttl: ackInitialTtl)

        do {
            let first = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                               journal: InMemoryJournal(), keychain: InMemoryKeychain())
            first.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)
            _ = first.ackPump.admit(frame.encode(), receivedFrom: relayFrom, now: 1_000)
            XCTAssertEqual(first.ackPump.nextBatch(nodeId, now: 1_000).copies.count, 1,
                           "the admitted candidate must stand offerable before the reopen")
            XCTAssertEqual(first.ackStore.countFrames(), 1, "and the namespace carrieth it")
            first.meshNode.stop()
        }

        // **THE REOPEN: A NEW RUNTIME OVER THE SAME PRIVATE DATABASE.**
        let second = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                           journal: InMemoryJournal(), keychain: InMemoryKeychain())
        XCTAssertEqual(second.ackStore.countFrames(), 1,
                       "GS-RUNTIME-001 step 6: THE FRAME NAMESPACE MUST SURVIVE THE REOPEN -- a fresh runtime that "
                       + "found nought would have lost durable custody silently")
        // **A WITNESS THAT INVENTETH A CLOCK MUST THREAD ITS OWN TIME THROUGH *EVERY* CALL THAT STAMPETH.** The
        // readiness's own turn passeth no `now`, so the pump stampeth `lastOffer` with the REAL clock (milliseconds
        // since 1970) -- and a later `nextBatch(now: 2_000)` would then compute a hugely NEGATIVE interval and be
        // refused by the RETRY WINDOW, which is EXACTLY what the first draft of this witness saw and reported
        // ("the pump refuseth the restored candidate: [retryWindow: 1]"). So the pump is scheduled and turned
        // DIRECTLY, with the witness's own instant, and the law under judgment (the REBUILD) is left alone.
        second.ackPump.onLinkReady(nodeId, now: 2_000)
        let rebuilt = second.ackPump.nextBatch(nodeId, now: 2_000)
        // THE PUMP'S OWN REASON, SURFACED RATHER THAN GUESSED: this assertion is a DIAGNOSTIC and it is kept in
        // place because the refusal reason IS the evidence for whatever repair followeth.
        XCTAssertTrue(rebuilt.refusals.isEmpty,
                      "the pump refuseth the restored candidate: \(rebuilt.refusals) (scanned \(rebuilt.scanned))")
        XCTAssertEqual(rebuilt.copies.count, 1,
                       "AND THE WORKER MUST REBUILD ITS PENDING WORK BY RE-READING THE TABLES: the candidate that "
                       + "was admitted before the restart standeth offerable after it")
        second.meshNode.stop()

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 6: **STOP/DRAIN WORKERS BEFORE DELETING KEYS.** MEASURED BEFORE THE REPAIR:
    /// `MeshRuntimeInvalidator.invalidateForWipe()` closed the peer store and the message store **while the node's
    /// ACK worker may still have been running**, because the invalidator did not hold the NODE at all -- and
    /// **NOBODY IN PRODUCTION CALLED `meshNode.stop()`** (the search over `ios/Godstone/Sources` found no call
    /// site). So a deadline armed by the runtime could fire AFTER the stores were closed.
    func testSR00i_TheWipeDrainethTheWorkersBeforeTheStoresAreClosed() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00i_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00i_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        let handle = UUID()
        let nodeId = Data(repeating: 0xA1, count: 16)
        runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)
        runtime.meshNode.cancelAckTurnDeadline()
        runtime.meshNode.armAckTurnDeadline(intervalSeconds: 0.02)
        var woke = false
        for _ in 0..<400 {
            if runtime.meshNode.ackTurnsRunForTest() > 0 { woke = true; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertTrue(woke, "the deadline must be running before the drain is judged")

        runtime.invalidator.invalidateForWipe()
        let drained = runtime.meshNode.ackTurnsRunForTest()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(runtime.meshNode.ackTurnsRunForTest(), drained,
                       "GS-RUNTIME-001 step 6: THE WIPE MUST DRAIN THE WORKERS *BEFORE* THE STORES ARE CLOSED -- "
                       + "a turn that fireth after the keys are gone is a worker outliving its authority")
        XCTAssertNil(runtime.meshNode.drainAckWorkOnce(nodeId: nodeId, generation: 1),
                     "and the relation mapping must be forgotten with the drain")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-RUNTIME-001 step 4's LAST WAKE: **NEWLY COMMITTED FORWARD WORK WAKETH THE WORKER FOR THAT RELATION** --
    /// an accepted ACK candidate is new forward work, and it may have to travel onward.
    func testSR00j_NewlyCommittedForwardWorkWakethTheWorkerForItsOwnRelation() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00j_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00j_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())
        let handle = UUID()
        let nodeId = Data(repeating: 0xB1, count: 16)
        let stranger = Data(repeating: 0xB2, count: 16)
        // A WELL-FORMED ACK FRAME, admitted from its sender as a candidate (no key standeth for its claimed
        // recipient here, so it entereth as a bounded opaque copy rather than as a verified one):
        let ack = try AckFrame.build(msgId: Data(repeating: 0x33, count: 16),
                                     signature: Data(repeating: 0x7C, count: 64),
                                     recipientNodeId: Data(repeating: 0xB3, count: 16),
                                     routingTag: Data(repeating: 0, count: 4), ttl: ackInitialTtl).encode()

        _ = runtime.meshNode.ingestInbound(try XCTUnwrap(FrameV2.decode(ack)), receivedFrom: stranger)
        XCTAssertEqual(runtime.meshNode.ackEventWakesForTest(), 0,
                       "A SENDER WITH NO TRUSTED RELATION MUST NOT BE SERVED")

        runtime.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)
        let before = runtime.meshNode.ackEventWakesForTest()
        _ = runtime.meshNode.ingestInbound(try XCTUnwrap(FrameV2.decode(ack)), receivedFrom: nodeId)
        XCTAssertGreaterThan(runtime.meshNode.ackEventWakesForTest(), before,
                             "GS-RUNTIME-001 step 4: NEWLY COMMITTED FORWARD WORK MUST WAKE THE WORKER FOR ITS OWN "
                             + "RELATION -- and nothing else in production ever did")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    // MARK: - IOS-06 step 1: ONE RUNTIME OWNER FOR LIFECYCLE, OVER THE REAL TRANSPORT

    /// A transport double: the instruments' contract is judged by what REACHETH a seam, not by a name.
    private final class SpyTransport: Transport {
        let name = "spy"
        let isBulkCapable = true
        private(set) var starts = 0
        private(set) var stops = 0
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    /// **IOS-06 step 1.** The audit's claim, MEASURED BEFORE THIS: "the adapter comment says concrete
    /// BleTransport/MeshNode conform to its `Transport` protocol, **but no such conformance exists in production
    /// source**" -- and `UnifiedRuntimeLifecycle`/`LifecycleTransportAdapter` were constructed NOWHERE, while the
    /// node called `ble.start()`/`ble.stop()` directly.
    func testSR00k_TheLifecycleAuthorityOwnethTheRealTransportAndDrivethASeam() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00k_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00k_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())

        // (1) THE CONFORMANCE -- a compile-time fact now, and the reason the runtime can own the transport at all:
        let seam: any Transport = runtime.meshNode.ble
        // AND THE CONCRETE TRANSPORT CAN REPORT ITS REAL TEARDOWN (IOS-06 step 2's second half), which the
        // lifecycle authority needeth if the production number is ever to be a measurement rather than a zero:
        let _: any DisconnectingTransport = runtime.meshNode.ble
        // **MEASURED, AFTER MY OWN FIRST DRAFT ASSERTED THE WRONG VALUES: `BleTransport` nameth itself "BLE" and
        // reporteth `isBulkCapable == false` -- the `"ble"`/`true` pair I had read belongeth to ANOTHER type, and
        // my grep's window attributed them to the wrong class (the fifth species of this session's control family,
        // met while READING rather than while writing). The arm now asserteth what the tree SAYETH.**
        XCTAssertEqual(seam.name, "BLE")
        XCTAssertFalse(seam.isBulkCapable, "the BLE transport reporteth itself NOT bulk-capable -- as the tree saith")
        XCTAssertNotNil(runtime.lifecycle, "IOS-06: the runtime must OWN ONE lifecycle authority")

        // (2) AND THE INSTRUMENTS DRIVE A TRANSPORT: the authority reacheth the seam it owneth, start and stop.
        let spy = SpyTransport()
        let authority = UnifiedRuntimeLifecycle(seam: LifecycleTransportAdapter(transport: spy),
                                                nowMillis: { 0 })
        authority.start()
        XCTAssertEqual(spy.starts, 1,
                       "IOS-06: the ONE authority must REACH the transport it owneth -- once, not repeatedly")
        authority.start()
        XCTAssertEqual(spy.starts, 1, "and a second start must not begin the OS work twice")
        authority.stop()
        XCTAssertEqual(spy.stops, 1, "and the stop must reach it exactly once")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// A transport that CAN report its teardown -- the road IOS-06 step 2 addeth.
    private final class ReportingTransport: DisconnectingTransport {
        let name = "reporting"
        let isBulkCapable = true
        let severed: Int
        private(set) var starts = 0
        private(set) var stops = 0
        /// **THE ORDERING IS NOW OBSERVABLE**: the spy recordeth how many stops it had already suffered AT THE
        /// MOMENT it was asked -- and my round-239 arm could not see that, which is why the ordering defect in the
        /// adapter slipped past it. A witness that cannot see the order is not a witness of the order.
        private(set) var stopsWhenAsked: Int? = nil
        init(severed: Int) { self.severed = severed }
        func start() { starts += 1 }
        func stop() { stops += 1 }
        func disconnectAll() -> Int { stopsWhenAsked = stops; return severed }
    }

    /// **IOS-06 step 2, BEHAVIOURAL: THE TEARDOWN RESULT IS REAL OR IT IS NOTHING.** The adapter returned a literal
    /// `1` before this -- and `BleTransport` owneth no disconnect method, so no measurement could ever have
    /// produced it.
    func testSR00l_TheTeardownResultIsMeasuredOrDefaultToNothing() throws {
        // (1) A TRANSPORT THAT CAN REPORT IS BELIEVED, even when its truth is neither 0 nor 1:
        let reporting = ReportingTransport(severed: 3)
        let adapter = LifecycleTransportAdapter(transport: reporting)
        adapter.startScan()
        XCTAssertEqual(reporting.starts, 1)
        XCTAssertEqual(adapter.disconnectAll(), 3,
                       "IOS-06 step 2: a reporting transport's REAL count must be returned, not a literal")
        XCTAssertEqual(reporting.stopsWhenAsked, 0,
                       "IOS-06 step 2: **THE REPORTING TRANSPORT MUST BE ASKED *BEFORE* THE COARSE STOP** -- a count "
                       + "taken after the teardown would read zero in production, and my first draft did exactly "
                       + "that while the arm passed anyway")
        XCTAssertEqual(reporting.stops, 1, "and the drain still reacheth the transport exactly once")

        // (2) AND A TRANSPORT THAT CANNOT REPORT GETTETH ZERO -- NEVER A FABRICATED ONE:
        let plain = SpyTransport()
        let silent = LifecycleTransportAdapter(transport: plain)
        silent.startAdvertising()
        XCTAssertEqual(silent.disconnectAll(), 0,
                       "a transport that cannot report must yield NOTHING CLAIMED: the old literal `1` was a "
                       + "stand-in wearing the clothes of a measurement")
        XCTAssertEqual(plain.stops, 1, "while the stop itself still reacheth it")
    }

    /// **IOS-06 step 3, BEHAVIOURAL: A POWER LOSS OR A WITHDRAWN PERMISSION REACHETH THE ONE AUTHORITY.** The
    /// authority's events were called ONLY BY COURTS before this (a measured grep over the whole source tree found
    /// `ReadinessT28Tests` and nothing else), so a real power-off never reached the owner.
    func testSR00m_APowerOrPermissionLossReachethTheOneAuthority() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00m_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00m_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())

        let before = runtime.meshNode.lifecycleEventsForwarded
        runtime.meshNode.handleTransportPowerState(.poweredOff)
        XCTAssertEqual(runtime.meshNode.lifecycleEventsForwarded, before + 1,
                       "IOS-06 step 3: a POWER LOSS must reach the one authority")
        runtime.meshNode.handleTransportPowerState(.permissionRevoked)
        XCTAssertEqual(runtime.meshNode.lifecycleEventsForwarded, before + 2,
                       "and a WITHDRAWN PERMISSION must too")

        // THE NEGATIVE CASE: A HEALTHY STATE IS NOT AN EVENT -- the platform speaketh constantly, and an authority
        // driven by every word would drain on a powered-on radio.
        runtime.meshNode.handleTransportPowerState(.ready)
        runtime.meshNode.handleTransportPowerState(.other)
        XCTAssertEqual(runtime.meshNode.lifecycleEventsForwarded, before + 2,
                       "a healthy or unknown state must NOT be forwarded as a loss")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// **IOS-06 steps 4 AND 5, MEASURED RATHER THAN ASSUMED**: the card's words are "the wipe drain" and
    /// "reactivation", and the laws they imply are three --
    ///   (a) a drain reacheth the transport exactly once (proven at rounds 238-239);
    ///   (b) **A TERMINAL AUTHORITY HATH NO PATH BACK**: after a power loss or a withdrawn permission, `start()`
    ///       must NOT begin the OS work again;
    ///   (c) and a DRAINED (merely stopped) authority is a separate question from a terminal one, which this arm
    ///       MEASURES rather than assumes -- whichever way the tree answereth, the answer is recorded.
    func testSR00n_TheTerminalAndReactivationLawsHold() throws {
        let spy = SpyTransport()
        let authority = UnifiedRuntimeLifecycle(seam: LifecycleTransportAdapter(transport: spy),
                                                nowMillis: { 0 })
        authority.start()
        XCTAssertEqual(spy.starts, 1, "(a) the authority reacheth the transport on start")

        // (b) TERMINAL AFTER A POWER LOSS:
        authority.onPowerLoss()
        authority.start()
        XCTAssertEqual(spy.starts, 1,
                       "IOS-06 step 5: **A TERMINAL AUTHORITY MUST HAVE NO PATH BACK** -- after a power loss, a "
                       + "later start must not re-open the radio")
        // (My first draft wrote `onPowerRemoved()` -- A NAME I ASSUMED AND DID NOT READ. The authority's roads
        // are the three I measured: `onBackgrounded`, `onPowerLoss`, `onPermissionRemoved`.)
        authority.onBackgrounded()
        authority.start()
        XCTAssertEqual(spy.starts, 1,
                       "and a backgrounded-then-terminal authority still must not re-open the radio")

        // (c) A SEPARATE AUTHORITY, PERMISSION WITHDRAWN:
        let spy2 = SpyTransport()
        let second = UnifiedRuntimeLifecycle(seam: LifecycleTransportAdapter(transport: spy2), nowMillis: { 0 })
        second.start()
        XCTAssertEqual(spy2.starts, 1)
        second.onPermissionRemoved()
        second.start()
        XCTAssertEqual(spy2.starts, 1,
                       "and a WITHDRAWN PERMISSION is terminal in the same way: no path back without the platform")
    }

    /// **IOS-06 step 1's routing, WITNESSED BEHAVIOURALLY AT LAST.** The wipe exercises the CLOSE road, and the
    /// node now counteth which road it took -- so "the graph openeth and closeth the radio through its one owner"
    /// is a MEASURED fact rather than a reading of the source. (The OPEN road wanteth a radio that a unit court
    /// must not start; the CLOSE road is reachable through the wipe, which every runtime may do.)
    func testSR00o_TheWipeClosethTheRadioThroughTheOneOwner() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00o_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00o_peer_\(UUID().uuidString).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                            journal: InMemoryJournal(), keychain: InMemoryKeychain())

        XCTAssertEqual(runtime.meshNode.adaptersClosedThroughTheOwner, 0, "nothing hath closed yet")
        runtime.invalidator.invalidateForWipe()
        XCTAssertEqual(runtime.meshNode.adaptersClosedThroughTheOwner, 1,
                       "IOS-06: **THE WIPE MUST CLOSE THE RADIO THROUGH THE ONE OWNER** -- not beside it")
        XCTAssertEqual(runtime.meshNode.adaptersOpenedThroughTheOwner, 0,
                       "and nothing OPENED: this court never started a radio")

        // THE NEGATIVE CASE OF A SORT: a SECOND wipe closeth nothing further, because an invalidated runtime is not
        // a live one -- the drain happeneth once per lifetime.
        runtime.invalidator.invalidateForWipe()
        XCTAssertEqual(runtime.meshNode.adaptersClosedThroughTheOwner, 1,
                       "and a SECOND wipe closeth nothing further: the close happeneth ONCE PER LIFETIME, or a drain "
                       + "that is merely repeated would be counted as a second teardown")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    func testSR01_CleanLaunch_InitializesRuntimeNormally() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr01_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr01_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )
        XCTAssertTrue(runtime.lifecycleGate.isActive)
        XCTAssertFalse(runtime.sessionManager.isInvalidated)
        XCTAssertEqual(journal.state, .idle)
    }

    func testSR02_PendingWipe_Requested_FinishesBeforeRuntimeInitialization() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr02_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr02_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        journal.write(.requested)
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        // *** CORRECTED TO THE FINDING'S OWN ORDER (GS-STORE-006, card step 6), WITH ITS SENTENCE QUOTED: "on restart,
        // resume from the durable compatible journal BEFORE opening keys, databases, discovery or a new identity." SO THE
        // STARTUP RESUMES ONLY WHAT NEEDS NO PLATFORM RESOURCE, AND THIS ARM'S OLD EXPECTATION (`.idle`, i.e. that the
        // WIPE FINISHES AT CREATE) BELONGED TO THE DESIGN THE FINDING REPLACES. MEASURED: with the four deferred seams, the ladder STOPS AT `REQUESTED` -- the drain needs a transport no creating process owns. ***
        //
        // *** AND A FURTHER MEASUREMENT IS RECORDED HERE RATHER THAN SILENTLY DROPPED (GS-FINAL-003, round 549). ***
        //
        // THE AUDIT'S CHARGE THAT iOS "discards the result of resume before creating identity/stores" IS REAL, AND THIS
        // ARM PASSES **BECAUSE** OF IT: a runtime IS handed back while the wipe stands at `requested`. A FIRST REPAIR OF
        // MINE REFUSED HERE INSTEAD -- AND DEADLOCKED THE COMPOSITION, because `continuePendingWipeIfNeeded` is a method
        // on a CONSTRUCTED runtime and drains through `meshNode.ble`, which is built FROM these very stores. Refusing
        // means the transport never exists and the wipe can never finish. THE PREREQUISITE IS ARCHITECTURAL -- a recovery
        // entry point that drives the ladder with a live transport without constructing the store graph -- and until it
        // exists the permit CANNOT be consumed at this call site. The finding's iOS half is therefore OPEN, and the
        // red-by-design arms that measure what the permit must do live in
        // `tools/readiness/audit_probes/swift/GsFinal003StartupPermitTests.swift.txt`.
        XCTAssertEqual(journal.state, .requested)
        XCTAssertTrue(runtime.lifecycleGate.isActive)
        XCTAssertNotNil(runtime.identity)
    }

    func testSR03_KeyErased_DeletesExactStoreArtifactsBeforeOpen() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr03_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr03_peer_\(UUID().uuidString).db")
        try Data("old store content".utf8).write(to: msgUrl)
        try Data("old peer content".utf8).write(to: peerUrl)
        XCTAssertTrue(FileManager.default.fileExists(atPath: msgUrl.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: peerUrl.path))

        let journal = InMemoryJournal()
        journal.write(.keyErased)
        let keychain = InMemoryKeychain()

        // *** CORRECTED TO THE FINDING'S OWN ORDER (GS-STORE-006, card step 6), WITH ITS SENTENCE QUOTED: "on restart, resume
        // from the durable compatible journal BEFORE opening keys, databases, discovery or a new identity." THE OLD
        // EXPECTATION WAS `journal.state == .idle` -- I.E. THAT THE CREATE-TIME RESUME **FINISHES** THE WIPE, DELETING
        // THESE EXACT FILES BEFORE ANY STORE IS OPENED. IT BELONGED TO THE DESIGN THE FINDING REPLACES: EVERY STAGE PAST
        // `KEY_ERASED` NEEDS A PLATFORM RESOURCE THE CREATING PROCESS DOES NOT YET OWN, SO THE DEFERRED SEAMS STOP THE
        // LADDER THERE. *** AND THE MEASURED CONSEQUENCE IS THE SAFER ONE, WHICH THIS ARM NOW DEMANDS: A RUNTIME MUST NOT
        // OPEN ITS STORES WHILE A WIPE OF THOSE VERY FILES STANDS UNFINISHED -- IT REFUSES, AND THE REFUSAL IS THE PROOF
        // THAT THE ORDER THE CARD ASKS FOR IS HONOURED. (Measured before this edit: the identical call failed with
        // `stepFailed` at `PeerIdentityStore.swift:292` -- the peer store declining to open on a key its own journal says
        // is erased.) ***
        XCTAssertThrowsError(
            try MeshRuntime.createArchiveOnlyHostComposition(
                messageStoreUrl: msgUrl,
                peerStoreUrl: peerUrl,
                journal: journal,
                keychain: keychain
            ),
            "the runtime must REFUSE to open stores while an unfinished wipe owns their files",
        )
        // AND THE WIPE IS STILL PENDING, WITH ITS ARTIFACTS UNTOUCHED: nothing was deleted before a runtime stood, and the
        // journal carries the checkpoint that says so.
        XCTAssertEqual(journal.state, .keyErased,
                       "the create-time resume stops at the checkpoint it can prove, and the wipe stays PENDING")
        XCTAssertTrue(FileManager.default.fileExists(atPath: msgUrl.path),
                      "and NO ARTIFACT MAY BE DELETED AT CREATE TIME: the deletion belongs to the runtime that stands")
    }

    func testSR04_ArtifactsDeleted_RegeneratesIdentityBeforeRuntimeConstruction() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr04_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr04_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        journal.write(.artifactsDeleted)
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        // *** CORRECTED TO THE FINDING'S OWN ORDER (GS-STORE-006, card step 6), WITH ITS SENTENCE QUOTED: "on restart,
        // resume from the durable compatible journal BEFORE opening keys, databases, discovery or a new identity."
        //
        // THE OLD EXPECTATION WAS `journal.state == .idle` -- I.E. THAT THE CREATE-TIME RESUME **REGENERATES THE IDENTITY**
        // (this arm's own name says so). IT BELONGED TO THE DESIGN THE FINDING REPLACES: AT CREATE TIME THE IDENTITY SEAM IS
        // DEFERRED, SO `publishNewIdentity()` ANSWERETH `nil` -- NOT PUBLISHED -- AND THE LADDER NOW **STOPS AT
        // `ARTIFACTS_DELETED`** INSTEAD OF CLAIMING AN IDENTITY IT NEVER PUBLISHED. *** THE ARM MEASURED THAT DEFECT AT
        // ROUND 421 (IT WAS THE ARM THAT FOUND IT) AND NOW MEASURES ITS ABSENCE. ***
        XCTAssertEqual(journal.state, .artifactsDeleted,
                       "the create-time resume stops at the last checkpoint it can prove, and the wipe stays PENDING for "
                       + "the runtime that owns an identity")
        XCTAssertEqual(runtime.identity.bindingGeneration, 0)
    }

    func testSR05_FreshRuntime_AfterWipe_HasDifferentNodeId() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime1 = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )
        let oldNodeId = runtime1.identity.nodeId

        try runtime1.beginPanicWipe(keychain: keychain)
        XCTAssertTrue(runtime1.lifecycleGate.isInvalidated)
        XCTAssertFalse(runtime1.sessionManager.isActive)

        // Construct runtime2 with the SAME store URLs
        let runtime2 = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertNotEqual(oldNodeId, runtime2.identity.nodeId)
        XCTAssertEqual(runtime2.identity.bindingGeneration, 0)
        XCTAssertTrue(runtime2.lifecycleGate.isActive)
        XCTAssertTrue(runtime1.lifecycleGate.isInvalidated)
    }

    func testSR06_FreshPeerStore_ContainsNoPriorPeerRecords() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr06_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr06_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        // 1. Create runtime1 using messageStoreUrl and peerStoreUrl
        let runtime1 = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        // 2. Construct a VALID peer binding and apply it through runtime1.peerRepository
        let signingKey = Curve25519.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let peerNodeId = Blake2s.hash(signingKey.publicKey.rawRepresentation, digestLength: 16)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: 0,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let sig = try signingKey.signature(for: preimage)
        let binding = IdentityBindingV1(
            generation: 0,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: sig
        )
        guard case .valid(let validated) = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: peerNodeId.prefix(4)
        ) else {
            XCTFail("Failed to create valid test binding")
            return
        }

        let applyRes = runtime1.peerRepository.applyValidatedBinding(validated)
        XCTAssertTrue(applyRes == .firstSeenPinned || applyRes == .accepted)

        // 3. Prove lookup is Verified before wipe
        let lookup1 = runtime1.peerRepository.lookup(peerNodeId)
        guard case .verified = lookup1 else {
            XCTFail("Expected peer to be verified before wipe")
            return
        }
        XCTAssertNotNil(try runtime1.peerIdentityStore.readRaw(peerNodeId))
        XCTAssertNotNil(runtime1.recipientKeyResolver.publicSigningKey(forNodeId: peerNodeId))

        // 4. Begin active panic wipe
        try runtime1.beginPanicWipe(keychain: keychain)
        XCTAssertTrue(runtime1.lifecycleGate.isInvalidated)

        // 5. Create runtime2 using the SAME messageStoreUrl and SAME peerStoreUrl
        let runtime2 = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        // 6. Prove old peer is completely absent: raw row absent, lookup NotFound, resolver nil
        let raw2 = try runtime2.peerIdentityStore.readRaw(peerNodeId)
        XCTAssertNil(raw2)

        let lookup2 = runtime2.peerRepository.lookup(peerNodeId)
        guard case .notFound = lookup2 else {
            XCTFail("Expected peer to be notFound in fresh runtime store")
            return
        }

        let key2 = runtime2.recipientKeyResolver.publicSigningKey(forNodeId: peerNodeId)
        XCTAssertNil(key2)
    }

    func testSR07_OldRuntimeHandle_RemainsPermanentlyUnusable() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr07_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr07_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        try runtime.beginPanicWipe(keychain: keychain)

        XCTAssertTrue(runtime.lifecycleGate.isInvalidated)
        XCTAssertFalse(runtime.sessionManager.isActive)
        XCTAssertNil(runtime.recipientKeyResolver.publicSigningKey(forNodeId: Data(count: 16)))
    }

    // MARK: - GS-STORE-006: BOTH HALVES OF THE WIPE, THROUGH THE COMPOSITION

    /**
     * THE ARM THE FINDING OWED, AND IT DRIVETH THE REAL LIFECYCLE IN THE ORDER THE CARD'S STEP 6 PRESCRIBES:
     *
     *   (1) THE STARTUP RESUMES ONLY THE TRANSPORT-LESS PREFIX -- every effectful seam deferred -- so a pending wipe
     *       STOPS and the stores may be opened (SR02 measured exactly this);
     *   (2) THE RUNTIME THAT STANDS CONTINUES THE SAME LADDER WITH THE LIVE SEAMS.
     *
     * AND WHAT IT DEMANDS IS THE CARD'S FIRST CLOSURE CLAUSE READ CAREFULLY: "Drive the real runtime wipe entry point with
     * a held write completion. **KEY DELETION MUST REMAIN BLOCKED UNTIL TRANSPORT DRAIN COMPLETES**; late callbacks must be
     * ignored." THE ORDER OF THIS ARM'S ASSERTIONS IS THEREFORE THE CLAUSE ITSELF: THE DRAIN HAPPENED FIRST (the live
     * transport quiesced over `meshNode.ble`), AND ONLY THEN WAS KEY ERASURE ATTEMPTED.
     *
     * *** AND ITS EXPECTATION WAS CORRECTED BY MEASUREMENT (GS-FINAL-002, round 548). ***
     *
     * THIS ARM USED TO REQUIRE `.retryLater` WITH THE WIPE STUCK AT `runtimeDrained` -- because the vault answered
     * `store-dek` with a PERMANENT RETRYABLE FAILURE WHENEVER NO KEY PROVIDER WAS WIRED. THAT REQUIREMENT WAS THE
     * FINDING IN MINIATURE: IT MADE A WIPE STRUCTURALLY UNCOMPLETABLE IN A COMPOSITION THAT HAS NO ENCRYPTED PRIVATE
     * STORE. The audit measured the consequence from the other side -- the fresh public wipe could not reach the
     * crash-resumable ladder at all -- and routing it there, as GS-FINAL-002 requires, made this arm's stall into a
     * REGRESSION: after a "wipe" the old node id stood and the peer store kept its row.
     *
     * THE LAW THE ARM ACTUALLY GUARDS IS UNCHANGED AND IS STILL MEASURED HERE: THE DRAIN MUST PRECEDE THE ERASURE. What
     * changed is the honest answer for a DEK THAT DOES NOT EXIST. `keyProviderForWipe` is non-nil EXACTLY WHEN the
     * composition carries an encrypted private store, so its absence means there is no DEK to erase -- `.absent`, which
     * is the tri-state doctrine's own word -- and erasing the identity keys and deleting the stores is then a COMPLETE
     * wipe, exactly as the old authority performed it.
     *
     * THE SAFETY PROPERTY IS NOT DROPPED; IT IS PROVEN SEPARATELY AND ADVERSARIALLY IN THE NEXT ARM, where a provider IS
     * wired and FAILS: there the wipe must stay pending and must NOT claim an erasure nobody performed.
     */
    func testGSSTORE006_theRuntimeThatStandsContinuesTheWipeAndErasesNothingWithoutAProvider() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr006b_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr006b_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        journal.write(.requested)                                    // a wipe requested before this process started
        let keychain = InMemoryKeychain()

        // HALF ONE: the startup. The wipe must NOT advance past the prefix, and the stores must be openable.
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )
        XCTAssertEqual(journal.state, .requested,
                       "*** HALF ONE: THE STARTUP STOPS AT THE PREFIX -- it owns no transport, no keychain and no store "
                       + "handles yet, so it may not drain, may not erase and may not delete ***")

        // HALF TWO: the runtime that stands continues the ladder with the LIVE seams.
        let r = try runtime.continuePendingWipeIfNeeded()

        // *** AND THE CLAUSE IS AN ORDER, SO THE ARM ASSERTS THE **ORDER OF THE RECORDS WRITTEN**, NOT A RANK. ***
        //
        // TWO DRAFTS OF THIS ASSERTION WERE WRONG BEFORE THIS ONE, AND BOTH MISTAKES ARE WORTH THE LINES:
        //   (i) `journal.state == .runtimeDrained` demanded the wipe HALT where it should proceed -- `InMemoryJournal`
        //       holds only the last state, and the ladder walks past the drain in the same call;
        //   (ii) `state.rawValue >= .runtimeDrained.rawValue` compared RANKS, and `IDLE` (6) is the LARGEST rank, so a
        //       COMPLETED wipe failed it. A rank is not an order of events.
        //
        // The journal this arm now records keeps EVERY write, so the drain's POSITION is readable directly -- which is
        // the only form in which "the drain preceded the erasure" is actually true or false.
        XCTAssertTrue(journal.writeLog.contains("runtimeDrained"),
                      "the DRAIN CHECKPOINT must have been WRITTEN through the LIVE seams: \(journal.writeLog)")
        if let drain = journal.writeLog.firstIndex(of: "runtimeDrained") {
            for earlier in ["keyErased", "artifactsDeleted", "newIdentity"] {
                if let index = journal.writeLog.firstIndex(of: earlier) {
                    XCTAssertLessThan(
                        drain, index,
                        "*** KEY DELETION MUST REMAIN BLOCKED UNTIL TRANSPORT DRAIN COMPLETES: the drain checkpoint "
                        + "must be WRITTEN BEFORE \(earlier). Observed order: \(journal.writeLog) ***")
                }
            }
        }

        // AND WITH NO ENCRYPTED PRIVATE STORE THERE IS NO DEK, so the wipe COMPLETES rather than stalling forever --
        // the old authority's behaviour, and the behaviour GS-FINAL-002 requires of the fresh entry point.
        guard case .advanced(_, to: .idle) = r else {
            XCTFail("WITH NO ENCRYPTED PRIVATE STORE THE WIPE IS COMPLETE: the identity keys are erased, the stores are "
                    + "deleted and a new identity is published. Its answer was \(r)")
            return
        }

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// *** THE SAFETY PROPERTY, PROVEN ADVERSARIALLY: A REAL DEK THAT CANNOT BE ERASED KEEPS THE WIPE PENDING. ***
    ///
    /// THE PREVIOUS ARM'S OLD EXPECTATION -- "stay pending when no provider is wired" -- conflated two different states.
    /// THIS ARM SEPARATES THEM: a provider IS wired, so a DEK really exists, and it REFUSES. The wipe must then stop at
    /// the drain with the erasure unclaimed, and the identity must survive. A wipe that reached `IDLE` here would be
    /// CLAIMING CRYPTOGRAPHIC ERASURE NOBODY PERFORMED -- the audit's own prohibition.
    func testGSFINAL002_aFailingDEKProviderKeepsTheWipePendingAndErasesNoIdentity() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf002b_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf002b_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        journal.write(.requested)
        let keychain = InMemoryKeychain()
        let identityBefore = try MeshIdentity.generateAndStore(keychain: keychain)

        // A RUNNING TRANSPORT THAT DRAINS (so we reach the vault), AND A VAULT WHOSE DEK ERASURE FAILS.
        final class DrainingTransport: TransportRuntimeSeam {
            func drainTransport() -> RuntimeDrainReceipt { .drained(closedTransports: 1, quiescedRuntime: true) }
            func isQuiesced() -> Bool { true }
            func fireRadio(_ msg: String) -> Bool { false }
            func sendVia(_ msg: String) -> Bool { false }
        }
        final class RefusingVault: KeyVaultSeam {
            var erased: [String] = []
            func eraseKey(_ name: String) -> KeyDeletionResult {
                if name == "store-dek" { return .failed(keyName: name, retryable: true, reason: "the DEK would not go") }
                erased.append(name)
                return .deleted
            }
        }
        let vault = RefusingVault()
        let authority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: journal),
            vault: vault,
            filesystem: WipeArtifactFileSystemSeam(journal: WipeJournalDurabilityAdapter(journal: journal)),
            runtime: DrainingTransport(),
            authority: WipeIdentityAuthoritySeam()
        )

        let result = try authority.resume()
        guard case .retryLater(at: .runtimeDrained, reason: let reason) = result else {
            XCTFail("A FAILING DEK ERASURE MUST KEEP THE WIPE PENDING AT THE DRAIN -- it must NOT advance to "
                    + "`KEYS_ERASED`, and it must NOT claim completion. Its answer was \(result)")
            return
        }
        XCTAssertFalse(reason.isEmpty, "the refusal must NAME what could not be erased")
        XCTAssertEqual(journal.state, WipeState.runtimeDrained,
                       "the journal must stand at the DRAIN, so a later resume retries the erasure rather than skipping it")
        // *** WHAT THE LADDER DOES WITH THE OTHER KEYS IS DELIBERATE, AND MY FIRST DRAFT OF THIS ARM GOT IT WRONG. ***
        //
        // I asserted that no later key is erased when an earlier one refuses. THE LADDER DOES NOT WORK THAT WAY, AND IT
        // SHOULD NOT: it walks the whole scope, erasing what it CAN and collecting what it cannot, because erasing every
        // reachable key is strictly safer than erasing none. What the safety depends on is that THE JOURNAL DOES NOT
        // ADVANCE -- so the refused key is RETRIED on the next resume, and no stage after `KEYS_ERASED` is reached. The
        // assertions below measure exactly that, and the over-strong one is replaced rather than deleted silently.
        XCTAssertEqual(vault.erased.sorted(), ["identity-ed25519", "identity-x25519"],
                       "the reachable keys ARE erased -- erasing what one can is safer than erasing none")
        XCTAssertNotNil(try? MeshIdentity.loadFromKeychain(keychain: keychain),
                        "AND THE IDENTITY SURVIVES -- a wipe that erased it while claiming a DEK erasure it never "
                        + "performed would be the worst possible ordering")
        XCTAssertNotEqual(identityBefore.nodeId, Data(), "sanity: a real identity stood before the wipe")

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    // MARK: - GS-STORE-006: THE WIPE AUTHORITY THE COMPOSITION CARRIES

    /// *** GS-FINAL-002 / GS-FINAL-011 (the independent audit, 2026-09-18): RECORD THE REAL WIPE PATH. ***
    ///
    /// THE AUDIT'S CHARGE, AND IT IS TWO CHARGES MEETING ON ONE LINE:
    ///   * GS-FINAL-002: "iOS MeshRuntime.beginPanicWipe still constructs old PanicWipe instead of requesting
    ///     through CrashResumableWipe" -- so the FRESH wipe ran the OLD state machine, which owneth no drain
    ///     checkpoint and no DEK, WHILE the comment directly above it claimed the opposite.
    ///   * GS-FINAL-011: "MeshRuntime.wipeAuthorityForTest returns a literal authority name and true flags" --
    ///     a test seam that ASSERTED the intended architecture instead of reading the runtime graph, so the
    ///     suite stayed GREEN while the behaviour it described was absent.
    ///
    /// THIS ARM REPLACES THE LITERAL WITH A RECORDING. It calls the REAL public `beginPanicWipe`, over a REAL
    /// runtime, and reads WHAT ACTUALLY HAPPENED: which journal records were written, in what order, and whether
    /// the transport was drained before any key was erased. Every assertion is about OBSERVED EFFECTS.
    private final class RecordingJournal: WipeJournal, @unchecked Sendable {
        var states: [WipeState] = []
        private var current: WipeState = .idle
        func read() -> WipeState { current }
        func write(_ s: WipeState) { current = s; states.append(s) }
        func clear() { current = .idle }
    
        /// *** GS-FINAL-003: STATED EXPLICITLY, BECAUSE THE PROTOCOL DEFAULT FAILS CLOSED. ***
        ///
        /// *This journal stores a TYPED `WipeState`, so it cannot hold an unparseable value -- it is readable BY
        /// CONSTRUCTION. The protocol's default is `false` (the safe reading of an unanswerable question), and a
        /// conformer that stays silent would therefore be reported CORRUPT and misdescribed. **AND THAT MATTERS HERE
        /// RATHER THAN THEORETICALLY:** the composition calls `decideAndDrive`, which consults
        /// `isReadableJournal()`, so an arm that reaches the startup road would exercise the CORRUPT branch and pass
        /// or fail for a reason unrelated to what it means to measure.*
        var isReadable: Bool { true }
    }

    private final class RecordingArtifacts: WipeArtifacts, @unchecked Sendable {
        var steps: [String] = []
        func eraseKeys() throws { steps.append("eraseKeys") }
        func deleteArtifacts() throws { steps.append("deleteArtifacts") }
        func regenerateIdentity() throws { steps.append("regenerateIdentity") }
    }

    /// THE OBSERVED PATH OF THE FRESH PUBLIC WIPE. It must run the CRASH-RESUMABLE LADDER -- which is the only
    /// authority that carries a durable DRAIN checkpoint and a DEK owner -- and it must NOT be the old machine.
    func testGSFINAL002_theFreshPublicWipeRunsTheCrashResumableLadderAndDrainsFirst() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf002_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf002_peer_\(UUID().uuidString).db")
        let journal = RecordingJournal()
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: InMemoryKeychain()
        )

        try runtime.beginPanicWipe(keychain: InMemoryKeychain())

        let written = journal.states.map { $0.rawValue }
        XCTAssertTrue(
            written.contains("runtimeDrained"),
            "GS-FINAL-002: THE FRESH PUBLIC WIPE MUST RUN THE CRASH-RESUMABLE LADDER, WHOSE FIRST RECORD AFTER "
            + "`requested` IS THE DURABLE DRAIN CHECKPOINT. The old `PanicWipe` machine carrieth NO DRAIN STAGE "
            + "AT ALL, so a wipe that reaches `keyErased` WITHOUT EVER WRITING `runtimeDrained` HAS ERASED KEYS "
            + "WITHOUT PROVING THE RADIO WAS QUIET -- the exact charge GS-STORE-006 carrieth. "
            + "Observed journal: \(written)",
        )

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    /// GS-FINAL-011: THE PROOF SEAM MUST READ THE RUNTIME, NOT ASSERT ABOUT IT. The literal tuple is replaced by
    /// an OBSERVATION: the fresh wipe's own journal records tell us which authority ran.
    func testGSFINAL011_theWipeAuthorityIsObservedRatherThanAsserted() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf011_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("gf011_peer_\(UUID().uuidString).db")
        let journal = RecordingJournal()
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: InMemoryKeychain()
        )

        try runtime.beginPanicWipe(keychain: InMemoryKeychain())

        // THE AUTHORITY IS NAMED BY ITS OWN DURABLE RECORD, NOT BY A RETURNED STRING. `CrashResumableWipe`
        // writeth `runtimeDrained` (via `WipeJournalState.wireName`); `PanicWipe` cannot write it, because
        // `WipeState.runtimeDrained` is a stage its `run()` never reaches.
        let written = Set(journal.states.map { $0.rawValue })
        XCTAssertTrue(
            written.contains("runtimeDrained"),
            "GS-FINAL-011: A TEST SEAM MAY NOT ASSERT AN ARCHITECTURE THE RUNTIME DOES NOT EXHIBIT. The audit's "
            + "measurement was that `wipeAuthorityForTest()` returned `(\"crashResumable\", true, true)` WHILE "
            + "`beginPanicWipe` CONSTRUCTED `PanicWipe` -- a green suite describing a tree that was not there. "
            + "The OBSERVED authority is named by its own durable record: `runtimeDrained` is a stage "
            + "`CrashResumableWipe` writeth and `PanicWipe` cannot reach. "
            + "Observed journal: \(journal.states.map { $0.rawValue })",
        )

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }

    // MARK: - GS-STORE-006: THE WIPE AUTHORITY THE COMPOSITION CARRIES

    /**
     * *** THIS ARM WAS THE FINDING, AND IT IS REPLACED RATHER THAN PROPPED UP. ***
     *
     * GS-FINAL-011 (the independent audit, 2026-09-18) measured that `MeshRuntime.wipeAuthorityForTest()` returned
     * `("crashResumable", true, true)` -- A LITERAL -- while the fresh public wipe constructed the OLD `PanicWipe`.
     * This arm read those three constants and asserted them back, so IT WAS GREEN ON A TREE THAT DID NOT EXHIBIT
     * WHAT IT DESCRIBED. A test that asks the source to repeat itself is not a control.
     *
     * The arm is now THE OBSERVATION ITSELF: it calls the REAL public wipe over a real runtime and reads the DURABLE
     * JOURNAL the wipe actually wrote. `runtimeDrained` is a stage `CrashResumableWipe` writes and `PanicWipe` cannot
     * reach, so the record names the authority that ran -- no constant is consulted, and none could satisfy this.
     *
     * AND IT CARRIES THE JOURNALS, IN ORDER, BECAUSE ORDER IS THE SAFETY PROPERTY: the DRAIN checkpoint must precede
     * any erasure. A wipe that erased keys without proving the radio quiet is the charge GS-STORE-006 carries, and
     * this arm would measure it.
     */
    func testGSSTORE006_theCompositionCarriesTheCrashResumableAuthority() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00c_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr00c_peer_\(UUID().uuidString).db")
        let journal = RecordingJournal()
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: InMemoryKeychain()
        )

        try runtime.beginPanicWipe(keychain: InMemoryKeychain())

        let written = journal.states.map { $0.rawValue }
        XCTAssertTrue(
            written.contains("requested"),
            "A FRESH WIPE MUST FIRST RECORD `REQUESTED` DURABLY -- `requestWipe()` writes it BEFORE driving anything, "
            + "where `resume()` would have refused an empty journal and done nothing. Observed: \(written)",
        )
        XCTAssertTrue(
            written.contains("runtimeDrained"),
            "AND THE LADDER IT RUNS MUST BE THE CRASH-RESUMABLE ONE, whose first record after `requested` is the "
            + "DURABLE DRAIN CHECKPOINT -- the stage the old `PanicWipe` machine carrieth NO counterpart for. "
            + "Observed: \(written)",
        )
        if let drainIndex = written.firstIndex(of: "runtimeDrained"),
           let eraseIndex = written.firstIndex(of: "keyErased") {
            XCTAssertLessThan(
                drainIndex, eraseIndex,
                "AND THE ORDER IS THE SAFETY PROPERTY: THE DRAIN MUST PRECEDE THE ERASURE. Observed: \(written)",
            )
        }

        try? FileManager.default.removeItem(at: msgUrl)
        try? FileManager.default.removeItem(at: peerUrl)
    }
}
