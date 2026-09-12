import Foundation
import XCTest
@testable import GodstoneMesh
@testable import GodstoneCore

// T39 readiness court (iOS isle) -- the twin of ReadinessT39Test.kt.
//
// One durable authority for the SOS broadcast lifecycle (section 14): the held
// frame and its NONE-mode delivery row commit together or not at all; the
// Active-SOS projection is read FROM the durable row, never from a UI memory;
// cancel moves the row terminal and retires the held work transactionally and
// tells the truth about copies already relayed; retry resumes the SAME
// authored bytes. The card's named behavioral cases are the witnesses:
// enqueue second-write failure (W1), restart with an active SOS (W2), cancel
// versus the queued writer (W3), relay already sent (W4), duplicate
// cancellation (W5), and NONE-mode ACK rejection (W6) -- plus the same-bytes
// law of retry (W7), the command-surface routing (W8), the one-authority
// census (W9), the no-torn-pair campaign (W10), and the flag-truth witness
// (W11). The named semantic negative -- "cancel only clears the UI flag" --
// dies on W2/W3/W4/W10/W11 together: they read the tables, not the flag.
//
// The court drives the durable route (the store-backed repository overriding
// enqueueSosOutbound) exactly as the composition root wires it in production
// (the SQL store over the shared handle is that route's sibling); the
// compatible two-step route for plain journals is the sealed T24/T38
// observables' road, proven by MeshNodeDeliveryIntegrationTests and
// ReadinessT38Tests standing unchanged.
final class ReadinessT39Tests: XCTestCase {

    // ---------------------------------------------------------------- fixtures

    private func newIdentity(_ seedByte: UInt8, _ xByte: UInt8) throws -> MeshIdentity {
        let state = try LocalIdentityStateV1(generation: 0,
            ed25519Seed: Data(repeating: seedByte, count: 32),
            x25519PrivateKey: Data(repeating: xByte, count: 32))
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = try state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    private func peerData(_ seedByte: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seedByte &* 31) })
    }

    private struct CourtFault: Error { let name: String }

    private func sosFrame(
        msgId: Data,
        flags: UInt16 = FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok,
        type: TypeV2 = .sos,
        tag: Data = Data(repeating: 0, count: 4),
        payload: Data = Data((0..<200).map { UInt8(truncatingIfNeeded: $0 % 251) })
    ) throws -> FrameV2 {
        try FrameV2(type: type, msgId: msgId, routingTag: tag,
                    ttl: 4, hopCount: 0, flags: flags, payload: payload)
    }

    private final class RecordingAuthenticator: AckAuthenticator, @unchecked Sendable {
        var calls = 0
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
            calls += 1
            return true // would accept -- the witnesses assert it is never consulted
        }
    }

    /// The durable route as the composition root walks it: the store-backed
    /// repository owns BOTH tables through the store's one lock. The counters
    /// prove the two-step road was never taken; the named fault seam reproduces
    /// the second-write failure the card names.
    private final class AuthorityRepository: DeliveryRepository, @unchecked Sendable {
        private let store: InMemoryMessageStore
        private let failAt: String?
        private let inner: InMemoryStoreDeliveryRepository
        var pairCommitCalls = 0
        var persistClosuresInvoked = 0

        init(store: InMemoryMessageStore, failAt: String?) {
            self.store = store
            self.failAt = failAt
            self.inner = InMemoryStoreDeliveryRepository(store: store)
        }

        func get(_ msgId: Data) -> DeliveryLookup { inner.get(msgId) }
        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            inner.enqueue(msgId, ackMode: ackMode, expectedRecipient: expectedRecipient)
        }
        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
            inner.transition(msgId, transition)
        }
        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            inner.acknowledgeBoundAndRetire(msgId, expectedRecipient: expectedRecipient)
        }
        func clear(_ msgId: Data) -> ClearResult { inner.clear(msgId) }

        func enqueueSosOutbound(
            _ frame: FrameV2,
            localOriginNodeId: Data,
            persist: () -> PersistResult
        ) -> OutboundEnqueueResult {
            pairCommitCalls += 1
            if let point = failAt {
                return store.enqueueSosOutboundAtWithFault(
                    frame,
                    localOriginNodeId: localOriginNodeId,
                    receivedAt: Int64(Date().timeIntervalSince1970 * 1000)
                ) { name in
                    if name == point { throw CourtFault(name: name) }
                }
            }
            return inner.enqueueSosOutbound(frame, localOriginNodeId: localOriginNodeId) {
                self.persistClosuresInvoked += 1
                return persist()
            }
        }
    }

    private final class Rig {
        let store: InMemoryMessageStore
        let tracker: DeliveryTracker
        let node: MeshNode
        let auth: RecordingAuthenticator

        init(store: InMemoryMessageStore, tracker: DeliveryTracker, node: MeshNode,
             auth: RecordingAuthenticator) {
            self.store = store; self.tracker = tracker; self.node = node; self.auth = auth
        }
    }

    private func newRig(failAt: String? = nil) throws -> Rig {
        let store = InMemoryMessageStore()
        let auth = RecordingAuthenticator()
        let tracker = DeliveryTracker(repo: AuthorityRepository(store: store, failAt: failAt),
                                      authenticator: auth)
        let node = MeshNode(
            identity: try newIdentity(0xC9, 0xE1),
            store: store,
            deliveryTracker: tracker
        )
        return Rig(store: store, tracker: tracker, node: node, auth: auth)
    }

    private func heldIds(_ store: InMemoryMessageStore) -> [Data] { store.allHeldMsgIds() }

    private func firstHeldFrame(_ store: InMemoryMessageStore) throws -> FrameV2 {
        try XCTUnwrap(store.allHeldOrderedByPriority().first)
    }

    private func rowOf(_ tracker: DeliveryTracker, _ msgId: Data) -> DeliveryLookup {
        tracker.lookup(msgId)
    }

    /// Dispatch once on a fresh rig and return (msg_id, result) -- both read
    /// back FROM the durable tables, the authority as the oracle.
    private func authorOnce(_ rig: Rig, _ payload: Data, peers: Int) throws -> (Data, SosDispatchResult) {
        for i in 0..<peers { rig.node.transportDidConnect(peerId: UUID(uuidString: Self.peerUuid(i))!) }
        var result: SosDispatchResult = .failed("the dispatch never ran")
        result = rig.node.dispatchSos(payload: payload) { _, _ in true }
        XCTAssertEqual(heldIds(rig.store).count, 1, "dispatch must commit exactly one held frame")
        return (try firstHeldFrame(rig.store).msgId, result)
    }

    private static func peerUuid(_ slot: Int) -> String {
        String(format: "0A0B0C0D-0000-4000-8000-%012X", slot + 1)
    }

    // ------------------------------------------------- W1 second-write failure

    /// W1 -- the card's "enqueue second-write failure": when the delivery row
    /// cannot be written, the held frame written moments before is taken back.
    /// Neither table keeps a trace of the half-commit, and the failure is
    /// reported (.notPersisted), never fabled as an empty success. Every named
    /// fault seam is probed at the authority, and once through the node.
    func testEnqueueSecondWriteFailureRollsTheWholePairBack() throws {
        let mid = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ 1) })
        for seam in ["before_held_insert", "after_held_insert",
                     "before_delivery_insert", "after_delivery_insert"] {
            let store = InMemoryMessageStore()
            let outcome = store.enqueueSosOutboundAtWithFault(
                try sosFrame(msgId: mid), localOriginNodeId: Data(repeating: 7, count: 16),
                receivedAt: 0
            ) { name in
                if name == seam { throw CourtFault(name: name) }
            }
            XCTAssertEqual(outcome, .storageFailure, "seam \(seam) must yield storageFailure")
            XCTAssertEqual(heldIds(store).count, 0,
                "seam \(seam) left a held orphan -- the pair must not half-commit")
            let fresh = DeliveryTracker(repo: InMemoryStoreDeliveryRepository(store: store),
                                        authenticator: RecordingAuthenticator())
            if case .notFound = fresh.lookup(mid) {} else {
                XCTFail("seam \(seam) left a delivery row without its frame")
            }
        }
        // Through the node: the same injected second-write failure surfaces as
        // .notPersisted and no table moves -- and the control distinguishes it
        // from an idempotent no-op.
        let r = try newRig(failAt: "before_delivery_insert")
        let failed = r.node.dispatchSos(payload: Data("hold the line".utf8)) { _, _ in true }
        XCTAssertEqual(failed, .notPersisted, "node route must report notPersisted")
        XCTAssertEqual(heldIds(r.store).count, 0, "no held frame may survive the rolled-back pair")
        let ok = try newRig()
        let good = ok.node.dispatchSos(payload: Data("hold the line".utf8)) { _, _ in true }
        XCTAssertEqual(good, .queuedDurably, "the control must commit")
        XCTAssertEqual(heldIds(ok.store).count, 1, "the control holds exactly one frame")
    }

    // ---------------------------------------------------------------- W2 restart

    /// W2 -- "restart with active SOS": a second node over the same durable
    /// tables re-exposes the call FROM THE ROW and can cancel it truthfully,
    /// learning it had been relayed. A UI-memory flag could never do this.
    func testRestartRevealsTheActiveSosFromTheDurableRow() throws {
        let r = try newRig()
        let (mid, dispatched) = try authorOnce(r, Data("medic".utf8), peers: 2)
        XCTAssertEqual(dispatched, .handedToRelays(2), "two relays must have taken the frame")
        if case .found(let rec) = rowOf(r.tracker, mid) {
            XCTAssertEqual(rec.state, .handedToRelay, "the row must stand handed")
        } else { XCTFail("the row must stand") }
        let node2 = MeshNode(
            identity: try newIdentity(0xCA, 0xE2),
            store: r.store,
            deliveryTracker: DeliveryTracker(repo: InMemoryStoreDeliveryRepository(store: r.store),
                                            authenticator: RecordingAuthenticator())
        )
        XCTAssertFalse(node2.hasActiveSosBroadcast, "a cold node must not claim an active SOS from thin air")
        let seen = try XCTUnwrap(node2.refreshSosStatusAfterScan())
        XCTAssertEqual(seen.msgId, mid, "the projection must name the same msg_id")
        XCTAssertEqual(seen.state, .handedToRelay, "the restarted projection must read the durable state")
        let stillHeld = try firstHeldFrame(r.store)
        XCTAssertEqual(seen.frame.encode(), stillHeld.encode(),
                       "the restarted projection carries the held frame verbatim")
        XCTAssertTrue(node2.hasActiveSosBroadcast, "the flag must follow the row after the scan")
        let restartCancel = node2.cancelSos(mid)
        XCTAssertEqual(restartCancel, .cancelled(wasRelayed: true),
                       "the restart's cancel must know it was relayed")
    }

    // --------------------------------------- W3 cancel versus the queued writer

    /// W3 -- "cancel versus queued writer": a cancellation that lands while a
    /// relay hand is in flight must not be resurrected by the writer's
    /// mark-handed follow. The bytes that left cannot be recalled -- the
    /// result says so -- and the row stays terminal.
    func testCancelVersusQueuedWriterNeverResurrects() throws {
        let r = try newRig()
        let mid = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ 1) })
        // commit the pair through the durable authority first (deterministic mid)
        let commit = r.store.enqueueSosOutboundAtWithFault(
            try sosFrame(msgId: mid), localOriginNodeId: Data(repeating: 7, count: 16),
            receivedAt: 0, fault: nil
        )
        if case .created = commit {} else { XCTFail("authority commit must succeed: \(commit)") }
        r.node.transportDidConnect(peerId: UUID(uuidString: "0A0B0C0D-0000-4000-8000-0000000000F9")!)
        var cancelledDuring = false
        let result = r.node.retrySos(msgId: mid) { _, _ in
            // the cancellation lands while this hand is carrying the bytes
            let c = r.node.cancelSos(mid)
            cancelledDuring = (c == .cancelled(wasRelayed: false))
            return true
        }
        XCTAssertEqual(result, .handedToRelays(1),
                       "the bytes did go out before the cancel was known")
        XCTAssertTrue(cancelledDuring, "the mid-flight cancel must have moved the row")
        if case .found(let rec) = rowOf(r.tracker, mid) {
            XCTAssertEqual(rec.state, .cancelledLocally,
                           "the writer's mark-handed follow must not resurrect the row")
        } else { XCTFail("the row must stand terminal") }
        XCTAssertEqual(heldIds(r.store).count, 0, "the cancel retired the held work")
        XCTAssertFalse(r.node.hasActiveSosBroadcast, "no active SOS may be claimed once the row is terminal")
    }

    // ------------------------------------------------------------ W4 relay already sent

    /// W4 -- "relay already sent": cancellation of a call whose bytes left
    /// reports the truth (wasRelayed) so the UI can say already relayed copies
    /// cannot be recalled, and retires the local work in one move.
    func testCancelOfARelayedCallTellsTheRelayedTruth() throws {
        let r = try newRig()
        let (mid, dispatched) = try authorOnce(r, Data("priority one".utf8), peers: 2)
        XCTAssertEqual(dispatched, .handedToRelays(2), "must have handed to two relays")
        let moved = r.node.cancelSos(mid)
        XCTAssertEqual(moved, .cancelled(wasRelayed: true),
                       "the result must tell the UI the copies are out")
        XCTAssertEqual(heldIds(r.store).count, 0, "the held frame must be retired with the row")
        XCTAssertFalse(r.node.hasActiveSosBroadcast)
    }

    // --------------------------------------------------- W5 duplicate cancellation

    /// W5 -- "duplicate cancellation" is idempotent, never an error: the first
    /// cancellation moves the pair; every later one names the same terminal
    /// truth and touches nothing.
    func testDuplicateCancellationIsIdempotentNotAnError() throws {
        let r = try newRig()
        let (mid, dispatched) = try authorOnce(r, Data("again and again".utf8), peers: 0)
        XCTAssertEqual(dispatched, .queuedDurably, "queued with no relays in sight")
        let firstMove = r.node.cancelSos(mid)
        XCTAssertEqual(firstMove, .cancelled(wasRelayed: false), "the first cancel moves the pair")
        let dup = r.node.cancelSos(mid)
        XCTAssertEqual(dup, .alreadyCancelled(wasRelayed: nil),
                       "the duplicate must be the idempotent no-op")
        let triple = r.node.cancelSos(mid)
        XCTAssertEqual(triple, .alreadyCancelled(wasRelayed: nil), "and stay so")
        if case .found(let rec) = rowOf(r.tracker, mid) {
            XCTAssertEqual(rec.state, .cancelledLocally, "the row stays terminal throughout")
        } else { XCTFail("the row must stand") }
        XCTAssertEqual(heldIds(r.store).count, 0, "and the held frame stays gone")
    }

    // ------------------------------------------------ W6 NONE-mode ACK rejection

    /// W6 -- "NONE-mode ACK rejection": a broadcast call is not addressed to
    /// anybody, so no authenticated ACK of it exists. A correctly signed ACK for
    /// the msg_id is refused at the mode gate BEFORE any cryptography -- the
    /// authenticator must never be consulted -- and the row, the frame and the
    /// mirror all stand as they were.
    func testNoneModeAckIsRejectedBeforeCryptography() throws {
        let r = try newRig()
        let (mid, dispatched) = try authorOnce(r, Data("no recipient".utf8), peers: 1)
        if case .handedToRelays(let n) = dispatched { XCTAssertEqual(n, 1) } else {
            XCTFail("one relay took it")
        }
        let ack = try AckFrame.build(
            msgId: mid,
            recipientSigningPrivKey: Data(repeating: 0x2A, count: 32),
            recipientNodeId: Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ 0x40) }),
            routingTag: Data([3, 3, 3, 3])
        )
        let accepted = r.node.ingestInbound(ack, receivedFrom: peerData(1))
        XCTAssertFalse(accepted, "a NONE-mode call has no recipient that could acknowledge it")
        XCTAssertEqual(r.auth.calls, 0, "the authenticator must never have been consulted")
        XCTAssertEqual(r.tracker.acknowledge(mid, ack), .notAckEligible,
                       "the direct tracker path must return notAckEligible")
        if case .found(let rec) = rowOf(r.tracker, mid) {
            XCTAssertEqual(rec.state, .handedToRelay, "the row must stand as it was")
            XCTAssertEqual(rec.ackMode, .none)
        } else { XCTFail("the row must stand") }
        XCTAssertEqual(heldIds(r.store).count, 1, "the held frame must stand as it was")
        XCTAssertTrue(r.node.hasActiveSosBroadcast, "and the projection must still say active")
    }

    // ----------------------------------------- W7 retry resumes the same bytes

    /// W7 -- "Retry resumes the same authored SOS bytes": the resume re-sends
    /// the held frame verbatim (byte-identical to the first hand-offs), the row
    /// stays handed, and the unknown or terminal cases FAIL typed -- they never
    /// masquerade as empty successes.
    func testRetryResumesTheSameAuthoredBytesAndFailsTyped() throws {
        let r = try newRig()
        r.node.transportDidConnect(peerId: UUID(uuidString: "0A0B0C0D-0000-4000-8000-0000000000A1")!)
        r.node.transportDidConnect(peerId: UUID(uuidString: "0A0B0C0D-0000-4000-8000-0000000000A2")!)
        var firstHand: [Data] = []
        _ = r.node.dispatchSos(payload: Data("same bytes please".utf8)) { frame, _ in
            firstHand.append(frame.encode()); return true
        }
        XCTAssertEqual(firstHand.count, 2, "two hands, two captures")
        let mid = try firstHeldFrame(r.store).msgId
        var again: [Data] = []
        let resume = r.node.retrySos(msgId: mid) { frame, _ in
            again.append(frame.encode()); return true
        }
        XCTAssertEqual(resume, .handedToRelays(2), "the resume must hand the same count")
        XCTAssertEqual(again, firstHand, "the bytes must be verbatim, not re-authored")
        if case .found(let rec) = rowOf(r.tracker, mid) {
            XCTAssertEqual(rec.state, .handedToRelay, "the row stays handed (idempotent target)")
        } else { XCTFail("the row must stand") }
        // unknown msg_id: failure, not an empty success
        let stranger = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ 0x77) })
        var sends = 0
        let unknown = r.node.retrySos(msgId: stranger) { _, _ in sends += 1; return true }
        if case .failed(let reason) = unknown {
            XCTAssertTrue(reason.contains("no durable row"), "and its reason must name itself: \(reason)")
        } else { XCTFail("an unknown msg_id must fail typed: \(unknown)") }
        XCTAssertEqual(sends, 0, "no bytes may go out for a stranger")
        // terminal row: the resume is refused, no resurrection
        _ = r.node.cancelSos(mid)
        let afterCancel = r.node.retrySos(msgId: mid) { _, _ in sends += 1; return true }
        if case .failed = afterCancel {} else { XCTFail("a cancelled call must not be resumed: \(afterCancel)") }
        XCTAssertEqual(sends, 0, "and no bytes may go out for it either")
    }

    // ------------------------------------------------------ W8 the command surface

    /// W8 -- SosCommand.author/retry/cancel route through one door and each
    /// returns the honest result of its arm: authoring enqueues durably,
    /// cancelling retires durably, retrying resumes; no arm reports a success
    /// the tables do not show.
    func testCommandSurfaceRoutesEveryArmToTheDurableTruth() throws {
        let r = try newRig()
        r.node.transportDidConnect(peerId: UUID(uuidString: "0A0B0C0D-0000-4000-8000-0000000000B1")!)
        let authoring = r.node.handleSosCommand(.author(Data("command one".utf8))) { _, _ in true }
        if case .enqueued(let dispatch) = authoring {
            if case .handedToRelays = dispatch {} else { XCTFail("author must enqueue durably: \(dispatch)") }
        } else { XCTFail("author must reach the dispatch arm: \(authoring)") }
        let mid = try firstHeldFrame(r.store).msgId
        let cancelling = r.node.handleSosCommand(.cancel(mid)) { _, _ in true }
        if case .cancelled(let outcome) = cancelling {
            if case .cancelled = outcome {} else { XCTFail("cancel must report its durable result: \(outcome)") }
        } else { XCTFail("cancel must reach its arm: \(cancelling)") }
        // a fresh author, then the retry arm resumes the same bytes
        let r2 = try newRig()
        let authoring2 = r2.node.handleSosCommand(.author(Data("command two".utf8))) { _, _ in true }
        if case .enqueued = authoring2 {} else { XCTFail("author again: \(authoring2)") }
        let mid2 = try firstHeldFrame(r2.store).msgId
        r2.node.transportDidConnect(peerId: UUID(uuidString: "0A0B0C0D-0000-4000-8000-0000000000B2")!)
        let resuming = r2.node.handleSosCommand(.retry(mid2)) { _, _ in true }
        if case .enqueued(let dispatch) = resuming {
            if case .handedToRelays = dispatch {} else { XCTFail("retry must reach the resume arm: \(dispatch)") }
        } else { XCTFail("retry must be the enqueue family: \(resuming)") }
        // value semantics of the commands: duplicate logical records are the
        // same command (and a distinct one is distinct)
        XCTAssertEqual(SosCommand.retry(mid2), .retry(Data(mid2)), "same bytes, same command")
        XCTAssertNotEqual(SosCommand.retry(mid2), .retry(mid))
    }

    // --------------------------------------------------------- W9 the one authority

    /// W9 -- the broadcast pair-commit is ONE call on the authority that owns
    /// both tables: the compatible persist closure must never be invoked on
    /// this route, and what the row names (mode NONE, no recipient, queued) is
    /// what the tables hold.
    func testTheBroadcastPairIsCommittedByOneAuthorityCall() throws {
        let store = InMemoryMessageStore()
        let repo = AuthorityRepository(store: store, failAt: nil)
        let auth = RecordingAuthenticator()
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let node = MeshNode(identity: try newIdentity(0xCB, 0xE3), store: store, deliveryTracker: tracker)
        _ = node.dispatchSos(payload: Data("one door".utf8)) { _, _ in true }
        XCTAssertEqual(repo.pairCommitCalls, 1, "exactly one authority call must commit the broadcast pair")
        XCTAssertEqual(repo.persistClosuresInvoked, 0, "the two-step route must never be walked here")
        let frame = try firstHeldFrame(store)
        if case .found(let rec) = tracker.lookup(frame.msgId) {
            XCTAssertEqual(rec.ackMode, .none, "the mode must be NONE")
            XCTAssertNil(rec.expectedRecipientNodeId, "and name no recipient")
            XCTAssertEqual(rec.state, .queuedDurably, "and stand queued durably")
        } else { XCTFail("the row must be found") }
        // frames that are not well-formed distress calls are refused BEFORE any
        // write: the type octet and the required flag bits are policy, not hope.
        // (The fixed widths need no probe on this isle: FrameV2's initializer
        // precondition fail-closes them at construction -- a mis-sized frame is
        // unnameable here, stricter than the android gate at enqueue; the
        // store's width gates stand as defense-in-depth.)
        let strays = [
            try sosFrame(msgId: Data(repeating: 1, count: 16), type: .message),
            try sosFrame(msgId: Data(repeating: 2, count: 16), flags: FrameV2.Flags.ack_req),
            try sosFrame(msgId: Data(repeating: 5, count: 16), flags: FrameV2.Flags.relay_ok),
        ]
        for stray in strays {
            let rejected = store.enqueueSosOutboundAtWithFault(
                stray, localOriginNodeId: Data(repeating: 7, count: 16), receivedAt: 0, fault: nil)
            XCTAssertEqual(rejected, .invalidArgument,
                           "policy must refuse a stray (\(stray.type)) with invalidArgument")
        }
        XCTAssertEqual(heldIds(store).count, 1, "and none of the strays may leave a trace")
    }

    // ------------------------------------------------------------ W10 no torn pair

    /// W10 -- the campaign: authoring, cancelling (some twice), and retrying in
    /// interleave; after EVERY step the cross-table invariant holds -- a held
    /// frame iff its live row, a terminal row iff its frame gone. The torn pair
    /// this task was named for becomes unnameable.
    func testNoTornPairEverAcrossTheInterleavedCampaign() throws {
        let r = try newRig()
        var mids: [Data] = []
        func certify(_ step: String) {
            let held = Set(heldIds(r.store))
            for mid in mids {
                let isHeld = held.contains(mid)
                switch rowOf(r.tracker, mid) {
                case .found(let rec):
                    let live = rec.state == .queuedDurably || rec.state == .handedToRelay
                    XCTAssertEqual(live, isHeld,
                                   "torn pair at \(step): live row \(rec.state) without its frame (or a frame without its row)")
                case .notFound:
                    XCTAssertFalse(isHeld, "torn pair at \(step): frame without its row")
                case .corrupt, .storageFailure, .invalidArgument:
                    XCTFail("the durable rows must read sound at \(step)")
                }
            }
        }
        // step: author four calls, two of them relayed
        for i in 0..<4 {
            if i < 2 {
                r.node.transportDidConnect(peerId: UUID(uuidString: "0A0B0C0D-0000-4000-8000-0000000000C\(i)")!)
            }
            let before = Set(heldIds(r.store))
            _ = r.node.dispatchSos(payload: Data("campaign \(i)".utf8)) { _, _ in true }
            let fresh = try XCTUnwrap(heldIds(r.store).first { !before.contains($0) })
            mids.append(fresh)
            certify("author \(i)")
        }
        // step: cancel the first two -- and the first twice more (idempotence)
        for k in [0, 1, 0] {
            _ = r.node.cancelSos(mids[k])
            certify("cancel \(k)")
        }
        // step: retry the live one and a cancelled one (refused, still no tear)
        _ = r.node.retrySos(msgId: mids[3]) { _, _ in true }
        certify("retry live")
        _ = r.node.retrySos(msgId: mids[0]) { _, _ in true }
        certify("retry cancelled")
        let liveCount = mids.filter { mid in
            if case .found(let rec) = rowOf(r.tracker, mid) {
                return rec.state == .queuedDurably || rec.state == .handedToRelay
            }
            return false
        }.count
        XCTAssertEqual(liveCount, 2, "exactly the two uncanceled calls must remain live")
        XCTAssertEqual(heldIds(r.store).count, 2, "and exactly those two must still be held")
    }

    // ------------------------------------------------- W11 the flag only ever follows

    /// W11 -- the observable mirror is a faithful record, no more: it lights
    /// when the durable row stands and goes when the row is terminal, and it
    /// can be re-derived from the tables at any moment (the restart reads) --
    /// never spent by a stray hand, never lit from thin air.
    func testTheFlagOnlyEverSaysWhatTheDurableRowSays() throws {
        let r = try newRig()
        XCTAssertFalse(r.node.hasActiveSosBroadcast, "before any authoring the mirror is dark")
        let (mid, _) = try authorOnce(r, Data("mirror".utf8), peers: 1)
        XCTAssertTrue(r.node.hasActiveSosBroadcast, "with a live row the mirror shines")
        // a redundant refresh cannot desensitize the mirror while the row lives
        _ = r.node.refreshSosStatusAfterScan()
        XCTAssertTrue(r.node.hasActiveSosBroadcast,
                      "while the row lives, the mirror may not be dimmed by mere re-reading")
        let outcome = r.node.cancelSos(mid)
        if case .cancelled = outcome {} else { XCTFail("the durable cancel moved the pair: \(outcome)") }
        XCTAssertFalse(r.node.hasActiveSosBroadcast, "and the mirror went dark with the row")
        // and it cannot be lit again by a remembered projection: a fresh scan of
        // the terminal tables says the same as the mirror
        XCTAssertNil(r.node.activeSosSnapshot(), "the scan must agree with the darkness")
    }
}
