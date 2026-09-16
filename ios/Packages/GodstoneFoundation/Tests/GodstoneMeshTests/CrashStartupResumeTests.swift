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

    private final class InMemoryJournal: WipeJournal, @unchecked Sendable {
        var state: WipeState = .idle
        var writes = 0
        var clears = 0
        func read() -> WipeState { state }
        func write(_ s: WipeState) { state = s; writes += 1 }
        func clear() { state = .idle; clears += 1 }
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
        let runtime = try MeshRuntime.create(
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
        let runtime = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
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
        let runtime = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
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
        let runtime = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
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

        // AND IT DIETH WITH ITS OWNER:
        runtime.meshNode.stop()
        let afterStop = runtime.meshNode.ackTurnsRunForTest()
        Thread.sleep(forTimeInterval: 0.1)
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
        let runtime = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
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
        let runtime = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
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
        let runtime = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
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
            let first = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
                                               journal: InMemoryJournal(), keychain: InMemoryKeychain())
            first.meshNode.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId, generation: 1)
            _ = first.ackPump.admit(frame.encode(), receivedFrom: relayFrom, now: 1_000)
            XCTAssertEqual(first.ackPump.nextBatch(nodeId, now: 1_000).copies.count, 1,
                           "the admitted candidate must stand offerable before the reopen")
            XCTAssertEqual(first.ackStore.countFrames(), 1, "and the namespace carrieth it")
            first.meshNode.stop()
        }

        // **THE REOPEN: A NEW RUNTIME OVER THE SAME PRIVATE DATABASE.**
        let second = try MeshRuntime.create(messageStoreUrl: msgUrl, peerStoreUrl: peerUrl,
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

    func testSR01_CleanLaunch_InitializesRuntimeNormally() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr01_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr01_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
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

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertEqual(journal.state, .idle)
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

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertEqual(journal.state, .idle)
        XCTAssertTrue(runtime.lifecycleGate.isActive)
    }

    func testSR04_ArtifactsDeleted_RegeneratesIdentityBeforeRuntimeConstruction() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr04_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr04_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        journal.write(.artifactsDeleted)
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertEqual(journal.state, .idle)
        XCTAssertEqual(runtime.identity.bindingGeneration, 0)
    }

    func testSR05_FreshRuntime_AfterWipe_HasDifferentNodeId() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime1 = try MeshRuntime.create(
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
        let runtime2 = try MeshRuntime.create(
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
        let runtime1 = try MeshRuntime.create(
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
        let runtime2 = try MeshRuntime.create(
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

        let runtime = try MeshRuntime.create(
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
}
