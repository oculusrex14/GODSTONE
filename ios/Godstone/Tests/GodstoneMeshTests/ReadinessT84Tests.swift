// T84 readiness court (iOS isle) -- the twin of ReadinessT84Test.kt (android).
//
// Forward durable ACKs through intermediate relays. The card's defect: MeshNode
// sendeth every ACK to the local DeliveryTracker, so an intermediate relay --
// which holdeth NO delivery row for a message somebody else authored -- answereth
// UnknownMessage and the multihop receipt never cometh home.
//
// One reviewed scenario per witness (W1..W14, the SAME name set as the android
// isle); every assertion is positive and expected (a present side effect is
// captured, an absent one is CAPTURED as absence through a typed refusal / zero
// census). The observable counters on the injected fakes, the ack_frames census
// and the origin's delivery state are the oracles that make the card's named
// falsifications killable: dropping a relay UnknownMessage ACK, deduping it
// against the MESSAGE id, or retiring it after a local ATT success.
//
// The world is A -- R -- B with NO A/B link. Fixtures are development-only:
// deterministic keys derived from a seed byte, no radio, no device clock.
// Readiness stays false; host tests do not prove CoreBluetooth or Data
// Protection behaviour, and no gate is closed.
import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

final class ReadinessT84Tests: XCTestCase {

    // ------------------------------------------------------------------ fakes

    /// A trust authority that bindeth nothing: the court never needs a real
    /// peer binding, and a host test must never fabricate one.
    private final class FailClosedTrust: PeerBindingTrustAuthority, @unchecked Sendable {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            return .storageFailure
        }
    }

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage[tag] = nil }
    }

    private struct Local { let id: MeshIdentity; let seed: Data; let pub: Data }

    private func newLocal(_ seedByte: UInt8, _ xByte: UInt8) throws -> Local {
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: xByte, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed,
                                             x25519PrivateKey: xPriv)
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        return Local(id: id, seed: edSeed, pub: Data(id.nodeId))
    }

    /// The recipient key directory: a key present == an authenticated binding.
    private final class KeyTable: RecipientKeyResolver, @unchecked Sendable {
        private var table: [Data: Data] = [:]
        func put(_ nodeId: Data, _ key: Data) { table[Data(nodeId)] = Data(key) }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? {
            if let v = table[Data(nodeId)] { return Data(v) }
            return nil
        }
    }

    private final class TestSigner: AckSignerSeam, @unchecked Sendable {
        private let local: Local
        init(_ local: Local) { self.local = local }
        var nodeId: Data? { Data(local.id.nodeId) }
        func generation() -> Int64 { 1 }
        func signingSeed(msgId: Data, recipientNodeId: Data) throws -> Data? { Data(local.seed) }
    }

    /// The minimal in-memory delivery repository: one row per msg_id holding
    /// state + ack mode + the EXPECTED recipient (the C6.1 binding). The guarded
    /// CAS mirrors the SQL one: state-only advance, binding preserved.
    private final class MemDeliveryRepo: DeliveryRepository, @unchecked Sendable {
        private var records: [Data: DeliveryRecord] = [:]
        private var order: [Data] = []

        func get(_ msgId: Data) -> DeliveryLookup {
            if msgId.count != 16 { return .invalidArgument }
            guard let rec = records[Data(msgId)] else { return .notFound }
            return .found(rec)
        }

        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            if msgId.count != 16 { return .invalidArgument }
            if (ackMode == .none && expectedRecipient != nil) ||
                (ackMode != .none && (expectedRecipient == nil || expectedRecipient!.count != 16)) {
                return .corrupt
            }
            switch get(msgId) {
            case .notFound:
                records[Data(msgId)] = DeliveryRecord(msgId: Data(msgId), state: .queuedDurably,
                                                      ackMode: ackMode,
                                                      expectedRecipientNodeId: expectedRecipient)
                order.append(Data(msgId))
                return .created
            case .found(let rec):
                if rec.state.isTerminal { return .rejectedTerminalState }
                if rec.ackMode != ackMode { return .conflictRecipient }
                if rec.expectedRecipientNodeId != expectedRecipient { return .conflictRecipient }
                return .alreadyQueuedSameBinding
            default:
                return .storageFailure
            }
        }

        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
            guard let rec = records[Data(msgId)] else { return .unknownMessage }
            let target: DeliveryState
            switch transition {
            case .expire: target = .expired
            case .cancel: target = .cancelledLocally
            case .markHanded: target = .handedToRelay
            }
            if rec.state == target { return .alreadyInTarget }
            if rec.state.isTerminal { return .rejectedState }
            records[Data(msgId)] = DeliveryRecord(
                msgId: rec.msgId, state: target, ackMode: rec.ackMode,
                expectedRecipientNodeId: rec.expectedRecipientNodeId)
            return .applied
        }

        func clear(_ msgId: Data) -> ClearResult {
            if msgId.count != 16 { return .invalidArgument }
            if records.removeValue(forKey: Data(msgId)) == nil { return .alreadyAbsent }
            return .cleared
        }

        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            if msgId.count != 16 || expectedRecipient.count != 16 { return .invalidArgument }
            guard let rec = records[Data(msgId)] else { return .unknownMessage }
            if rec.state == .acknowledgedByRecipient { return .duplicateAuthenticatedAck }
            if rec.state.isTerminal { return .rejectedState }
            if rec.ackMode != .singleRecipient { return .notAckEligible }
            guard let bound = rec.expectedRecipientNodeId else { return .corrupt }
            if bound != expectedRecipient { return .rejectedState }
            records[Data(msgId)] = DeliveryRecord(
                msgId: rec.msgId, state: .acknowledgedByRecipient, ackMode: rec.ackMode,
                expectedRecipientNodeId: rec.expectedRecipientNodeId)
            return .applied
        }
    }

    /// One node: A (origin) and B (recipient) hold delivery rows; R holdeth none.
    private final class Node {
        let label: String
        let local: Local
        let store: InMemoryMessageStore
        let ackStore: AckObligationStore
        let driver: AckObligationDriver
        let pump: DurableAckPump
        let dispatcher: AckDispatcher
        let tracker: DeliveryTracker

        init(label: String, local: Local, store: InMemoryMessageStore, ackStore: AckObligationStore,
             driver: AckObligationDriver, pump: DurableAckPump, dispatcher: AckDispatcher,
             tracker: DeliveryTracker) {
            self.label = label; self.local = local; self.store = store
            self.ackStore = ackStore; self.driver = driver; self.pump = pump
            self.dispatcher = dispatcher; self.tracker = tracker
        }
    }

    private func node(_ label: String, _ local: Local, _ keys: KeyTable) -> Node {
        let store = InMemoryMessageStore()
        let ackStore = InMemoryAckStore()
        let driver = AckObligationDriver(store: ackStore, signer: TestSigner(local),
                                        authenticator: Ed25519AckAuthenticator(resolver: keys),
                                        resolver: keys)
        let pump = DurableAckPump(store: ackStore, admitForeign: { encoded, from in
            driver.admitForeignCandidate(encoded, receivedFrom: from)
        })
        let tracker = DeliveryTracker(repo: MemDeliveryRepo(),
                                      authenticator: Ed25519AckAuthenticator(resolver: keys))
        let dispatcher = AckDispatcher(
            lookupDeliveryRow: { tracker.lookup($0) },
            verifyOrigin: { tracker.acknowledge($0.msgId, $0) },
            admitCandidate: { encoded, from in pump.admit(encoded, receivedFrom: from) })
        return Node(label: label, local: local, store: store, ackStore: ackStore, driver: driver,
                    pump: pump, dispatcher: dispatcher, tracker: tracker)
    }

    private struct World {
        let a: Node
        let r: Node
        let b: Node

        /// The A-R-B topology: A and B never speak directly.
        func hopBtoR(_ frame: FrameV2) -> AckDispatch {
            r.dispatcher.dispatch(frame, receivedFrom: Data(b.local.id.nodeId))
        }

        /// One epidemic turn: R offereth to `to` on LinkReady; `to` dispatcheth.
        func forwardTurn(_ to: Node, now: Int) -> [AckDispatch] {
            r.pump.onLinkReady(Data(to.local.id.nodeId), now: now)
            let batch = r.pump.nextBatch(Data(to.local.id.nodeId), now: now)
            return batch.copies.map { copy in
                let verdict = to.dispatcher.dispatch(try! FrameV2.decode(copy.encodedFrame)!,
                                                     receivedFrom: Data(r.local.id.nodeId))
                r.pump.onForwardOutcome(copy, peer: Data(to.local.id.nodeId), accepted: true, now: now)
                return verdict
            }
        }
    }

    private func world() throws -> World {
        let a = try newLocal(0x31, 0x41)
        let r = try newLocal(0x32, 0x42)
        let b = try newLocal(0x33, 0x43)
        // the authenticated bindings: A knows B's signing key (it addressed B),
        // and the RELAY knows nobody (it is an unknown-key relay by nature).
        let aKeys = KeyTable()
        aKeys.put(Data(b.id.nodeId), b.id.signingPublicKey)
        let bKeys = KeyTable()
        bKeys.put(Data(b.id.nodeId), b.id.signingPublicKey)
        return World(a: node("A", a, aKeys), r: node("R", r, KeyTable()), b: node("B", b, bKeys))
    }

    private func msgId(_ seed: Int) -> Data { Data((0..<16).map { UInt8(($0 + seed) & 0xFF) }) }

    private func ackOf(_ mid: Data, _ signer: Local, ttl: Int = ackRelayInitialTtl) -> FrameV2 {
        let preimage = Data("GMP2-ACK".utf8) + mid + Data(signer.id.nodeId)
        let signature = try! signer.id.sign(message: preimage)
        return FrameV2(type: .ack, msgId: mid, routingTag: Data(repeating: 7, count: 4),
                       ttl: UInt8(ttl), hopCount: 0, flags: 0,
                       payload: signature + Data(signer.id.nodeId))
    }

    private func heldFrames(_ store: InMemoryMessageStore) -> Int {
        (try? store.allHeldMsgIds().count) ?? -1
    }

    private func stateOf(_ tracker: DeliveryTracker, _ mid: Data) -> DeliveryState? {
        if case .found(let rec) = tracker.lookup(mid) { return rec.state }
        return nil
    }

    private func enqueueAtOrigin(_ w: World, _ mid: Data) {
        XCTAssertEqual(w.a.tracker.enqueue(mid, ackMode: .singleRecipient,
                                           expectedRecipient: Data(w.b.local.id.nodeId)),
                       .created)
        XCTAssertEqual(w.a.tracker.markHandedToRelay(mid), .applied)
    }

    /// A failing arm must FAIL its test, never crash the whole process: an
    /// unguarded subscript would abort the run and hide every other witness.
    private func firstCopy(_ batch: AckPumpBatch, _ label: String,
                           file: StaticString = #filePath, line: UInt = #line) -> AckForwardCopy? {
        guard let copy = batch.copies.first else {
            XCTFail("expected at least one forward copy: \(label)", file: file, line: line)
            return nil
        }
        return copy
    }

    private func firstVerdict(_ verdicts: [AckDispatch], _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) -> AckDispatch? {
        guard let verdict = verdicts.first else {
            XCTFail("expected at least one verdict: \(label)", file: file, line: line)
            return nil
        }
        return verdict
    }

    private func isOrigin(_ verdict: AckDispatch) -> Bool {
        if case .originVerification = verdict { return true }
        return false
    }

    private func isOpaque(_ verdict: AckDispatch) -> Bool {
        if case .opaqueRelay = verdict { return true }
        return false
    }

    private func refusedReason(_ verdict: AckDispatch) -> AckRefusalReason? {
        if case .refused(let reason, _) = verdict { return reason }
        return nil
    }

    // ------------------------------------------------------------ W1

    /// W1 -- the ORIGIN classification: a durable delivery row maketh an ACK
    /// origin verification, and only that road reacheth DELIVERED.
    func testW01AnAckWithADurableRowIsOriginVerification() throws {
        let w = try world()
        let mid = msgId(1)
        enqueueAtOrigin(w, mid)
        let verdict = w.a.dispatcher.dispatch(ackOf(mid, w.b.local),
                                              receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertTrue(isOrigin(verdict))
        XCTAssertEqual(verdict.dispatchClass, .originVerification)
        XCTAssertTrue(verdict.accepted)
        XCTAssertEqual(stateOf(w.a.tracker, mid), .acknowledgedByRecipient)
        XCTAssertEqual(w.a.ackStore.countFrames(), 0, "nothing entered the relay namespace at the origin")
    }

    // ------------------------------------------------------------ W2

    /// W2 -- the required three-node scenario: A -> R -> B and B's ACK -> R -> A
    /// with NO A/B link, reaching DELIVERED at the origin.
    func testW02TheThreeNodeReceiptReturnethHomeWithoutADirectLink() throws {
        let w = try world()
        let mid = msgId(2)
        enqueueAtOrigin(w, mid)
        let ack = ackOf(mid, w.b.local)

        let atRelay = w.hopBtoR(ack)
        XCTAssertTrue(isOpaque(atRelay), "the relay carrieth it, never discardeth it (was UnknownMessage)")
        XCTAssertTrue(atRelay.accepted)
        XCTAssertEqual(w.r.ackStore.countFrames(), 1)
        if case .opaqueRelay(let admission) = atRelay {
            XCTAssertEqual(admission.verificationClass, .opaqueCandidate,
                           "a relay never claimeth recipient verification")
        } else {
            XCTFail("expected opaque relay custody")
        }

        let forwards = w.forwardTurn(w.a, now: 1_000)
        XCTAssertEqual(forwards.count, 1, "exactly one copy homeward")
        guard let homeward = firstVerdict(forwards, "one copy homeward") else { return }
        XCTAssertTrue(isOrigin(homeward))
        XCTAssertTrue(homeward.accepted)
        XCTAssertEqual(stateOf(w.a.tracker, mid), .acknowledgedByRecipient,
                       "A reacheth the only truthful terminal state")
        XCTAssertEqual(w.r.ackStore.countFrames(), 1,
                       "custody is not retired by a local ATT success")
    }

    // ------------------------------------------------------------ W3

    /// W3 -- the separate namespace: a relay's custody liveth in ack_frames and
    /// NEVER in the message store (the named falsification, second limb).
    func testW03RelayCustodyNeverEnterethTheMessageNamespace() throws {
        let w = try world()
        let mid = msgId(3)
        let ack = ackOf(mid, w.b.local)
        let before = heldFrames(w.r.store)
        let atRelay = w.hopBtoR(ack)
        XCTAssertEqual(w.r.ackStore.countFrames(), 1)
        guard case .opaqueRelay(let admitted) = atRelay else {
            return XCTFail("expected opaque relay custody")
        }
        guard let admittedKey = admitted.ackKey else {
            return XCTFail("the admitted candidate carrieth its local cache key")
        }
        XCTAssertNotEqual(admittedKey, mid,
                          "the candidate's key is NOT the message id (the named falsification, second limb)")
        XCTAssertEqual(admitted.verificationClass, AckVerificationClass.opaqueCandidate)
        XCTAssertEqual(heldFrames(w.r.store), before, "the message store is untouched by an ACK")

        let signature = ack.payload.prefix(ackSigLen)
        guard let key = AckCacheKey.compute(msgId: mid, recipientNodeId: Data(w.b.local.id.nodeId),
                                            signature: Data(signature)) else {
            return XCTFail("the ACK cache key must compute")
        }
        XCTAssertNotEqual(key, mid, "the ack key is NOT the message id")
        guard case .records(let rows) = w.r.ackStore.listCandidates(64) else {
            return XCTFail("the candidate must be enumerable")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].verificationClass, .opaqueCandidate)
        XCTAssertEqual(rows[0].ackKey, admittedKey, "the stored row carrieth the very key the admission named")
        XCTAssertEqual(rows[0].ackKey, key, "and that key is the canonical ACK-cache key")
    }

    // ------------------------------------------------------------ W4

    /// W4 -- an ACK is never echoed back to the peer it came from.
    func testW04ACandidateIsNeverEchoedToReceivedFrom() throws {
        let w = try world()
        _ = w.hopBtoR(ackOf(msgId(4), w.b.local))
        w.r.pump.onLinkReady(Data(w.b.local.id.nodeId), now: 10)
        let backToB = w.r.pump.nextBatch(Data(w.b.local.id.nodeId), now: 10)
        XCTAssertEqual(backToB.copies.count, 0)
        XCTAssertEqual(backToB.refusals[.receivedFromThisPeer], 1)
        w.r.pump.onLinkReady(Data(w.a.local.id.nodeId), now: 10)
        XCTAssertEqual(w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 10).copies.count, 1,
                       "and it IS offered to the other trusted peer")
    }

    // ------------------------------------------------------------ W5

    /// W5 -- the TTL/hop statute: exactly once per copy, the canonical 12
    /// initial, and every out-of-band TTL refused BY NAME.
    func testW05TheForwardCopyTakethTtlAndHopExactlyOnce() throws {
        let w = try world()
        let mid = msgId(5)
        let original = ackOf(mid, w.b.local, ttl: ackRelayInitialTtl)
        _ = w.hopBtoR(original)
        w.r.pump.onLinkReady(Data(w.a.local.id.nodeId), now: 5)
        let batch = w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 5)
        XCTAssertEqual(batch.copies.count, 1)
        guard let copy = firstCopy(batch, "the canonical copy") else { return }
        XCTAssertEqual(copy.ttl, ackRelayInitialTtl - 1)
        XCTAssertEqual(copy.hopCount, 1)
        let decoded = try FrameV2.decode(copy.encodedFrame)!
        XCTAssertEqual(decoded.flags, 0)
        XCTAssertEqual(decoded.payload.count, 80, "the 80-byte payload travelleth whole")
        XCTAssertEqual(decoded.payload, original.payload, "the signed payload is preserved byte for byte")
        XCTAssertEqual(decoded.msgId, original.msgId)
        XCTAssertEqual(decoded.routingTag, original.routingTag)

        let again = w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 5 + ackRelayRetryIntervalMs)
        XCTAssertEqual(again.copies.count, 1)
        guard let retried = again.copies.first else { return XCTFail("the retry must offer a copy") }
        XCTAssertEqual(retried.encodedFrame, copy.encodedFrame,
                       "the retry re-emiteth the IDENTICAL bytes: never a second decrement")
        XCTAssertEqual(retried.ttl, copy.ttl)
        XCTAssertEqual(retried.hopCount, copy.hopCount)

        let exhausted = try world()
        _ = exhausted.hopBtoR(ackOf(msgId(51), exhausted.b.local, ttl: 1))
        exhausted.r.pump.onLinkReady(Data(exhausted.a.local.id.nodeId), now: 5)
        let e = exhausted.r.pump.nextBatch(Data(exhausted.a.local.id.nodeId), now: 5)
        XCTAssertEqual(e.copies.count, 0)
        XCTAssertEqual(e.refusals[.ttlExhausted], 1)

        let inflated = try world()
        _ = inflated.hopBtoR(ackOf(msgId(52), inflated.b.local, ttl: 13))
        inflated.r.pump.onLinkReady(Data(inflated.a.local.id.nodeId), now: 5)
        let i = inflated.r.pump.nextBatch(Data(inflated.a.local.id.nodeId), now: 5)
        XCTAssertEqual(i.copies.count, 0)
        XCTAssertEqual(i.refusals[.ttlAboveProductionInitial], 1)
    }

    // ------------------------------------------------------------ W6

    /// W6 -- scheduling and budgets: no LinkReady, no offer; batch 32; one retry
    /// per candidate/peer per 30 s; burst 16 with a 1/s refill.
    func testW06ThePumpIsScheduledBoundedAndRateLimited() throws {
        let w = try world()
        _ = w.hopBtoR(ackOf(msgId(6), w.b.local))
        let unscheduled = w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 1)
        XCTAssertEqual(unscheduled.copies.count, 0)
        XCTAssertEqual(unscheduled.refusals[.notScheduled], 1)
        XCTAssertFalse(w.r.pump.isScheduled(Data(w.a.local.id.nodeId)))

        w.r.pump.onLinkReady(Data(w.a.local.id.nodeId), now: 1)
        XCTAssertTrue(w.r.pump.isScheduled(Data(w.a.local.id.nodeId)))
        XCTAssertEqual(w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 1).copies.count, 1)
        let gated = w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 1 + ackRelayRetryIntervalMs - 1)
        XCTAssertEqual(gated.copies.count, 0)
        XCTAssertEqual(gated.refusals[.retryWindow], 1)
        XCTAssertEqual(w.r.pump.nextBatch(Data(w.a.local.id.nodeId),
                                          now: 1 + 2 * ackRelayRetryIntervalMs).copies.count, 1)

        let burst = try world()
        for i in 0..<(ackRelayBurstPerPeer + 4) {
            _ = burst.hopBtoR(ackOf(msgId(600 + i), burst.b.local, ttl: ackRelayInitialTtl))
        }
        burst.r.pump.onLinkReady(Data(burst.a.local.id.nodeId), now: 9)
        let batched = burst.r.pump.nextBatch(Data(burst.a.local.id.nodeId), now: 9)
        XCTAssertEqual(batched.copies.count, ackRelayBurstPerPeer)
        XCTAssertLessThanOrEqual(batched.copies.count, ackRelayBatchLimit,
                                 "the batch bound is never exceeded")
        XCTAssertEqual(batched.refusals[.peerRateLimit], 4)
        XCTAssertEqual(burst.r.pump.nextBatch(Data(burst.a.local.id.nodeId),
                                              now: 9 + ackRelayRateMs).copies.count, 1,
                       "one second later, one more token")
    }

    // ------------------------------------------------------------ W7

    /// W7 -- the named falsification, third limb: a LOCAL ATT ACCEPTANCE never
    /// retireth ACK custody; only expiry and quota do.
    func testW07ALocalAttAcceptanceNeverRetirethCustody() throws {
        let w = try world()
        _ = w.hopBtoR(ackOf(msgId(7), w.b.local))
        w.r.pump.onLinkReady(Data(w.a.local.id.nodeId), now: 20)
        guard let copy = firstCopy(w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 20),
                                   "the custody copy") else { return }
        w.r.pump.onForwardOutcome(copy, peer: Data(w.a.local.id.nodeId), accepted: true, now: 20)
        XCTAssertTrue(w.r.pump.custodyHolds(copy.ackKey),
                      "the radio accepted some bytes; the custody standeth")
        XCTAssertEqual(w.r.ackStore.countFrames(), 1)
        w.r.pump.onForwardOutcome(copy, peer: Data(w.a.local.id.nodeId), accepted: false, now: 20)
        XCTAssertEqual(w.r.ackStore.countFrames(), 1, "a refused hand-off retireth nothing")
        XCTAssertEqual(w.r.pump.nextBatch(Data(w.a.local.id.nodeId),
                                          now: 20 + ackRelayRetryIntervalMs).copies.count, 1)
    }

    // ------------------------------------------------------------ W8

    /// W8 -- an ACK that PRECEDETH its message is not discarded; when the origin
    /// row appears later it is the origin road that decideth.
    func testW08AnAckPrecedingItsMessageIsCarriedNotDiscarded() throws {
        let w = try world()
        let mid = msgId(8)
        let ack = ackOf(mid, w.b.local)
        if case .notFound = w.a.tracker.lookup(mid) {} else {
            XCTFail("no delivery row stands anywhere yet")
        }
        let early = w.hopBtoR(ack)
        XCTAssertTrue(isOpaque(early), "relay traffic, never an automatic discard")
        XCTAssertEqual(w.r.ackStore.countFrames(), 1)
        let again = w.hopBtoR(ack)
        XCTAssertTrue(isOpaque(again))
        XCTAssertEqual(w.r.ackStore.countFrames(), 1, "the same signature is ONE candidate")

        enqueueAtOrigin(w, mid)
        let atOrigin = w.a.dispatcher.dispatch(ack, receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertTrue(isOrigin(atOrigin))
        XCTAssertEqual(stateOf(w.a.tracker, mid), .acknowledgedByRecipient)
        XCTAssertEqual(w.r.ackStore.countFrames(), 1,
                       "the relay's candidacy standeth independently")
    }

    // ------------------------------------------------------------ W9

    /// W9 -- a forged candidate is refused and cannot suppress a later VALID one;
    /// a rejected origin candidate leaveth delivery unchanged.
    func testW09AForgedCandidateCannotSuppressALaterValidSignature() throws {
        let w = try world()
        let mid = msgId(9)
        let forged = FrameV2(type: .ack, msgId: mid, routingTag: Data(repeating: 7, count: 4),
                             ttl: UInt8(ackRelayInitialTtl), hopCount: 0, flags: 0,
                             payload: Data(repeating: 0x5A, count: 64) + Data(w.b.local.id.nodeId))
        let refused = w.b.dispatcher.dispatch(forged, receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertEqual(refusedReason(refused), .knownInvalidSignature)
        XCTAssertEqual(w.b.ackStore.countFrames(), 0, "nothing was written")

        _ = w.hopBtoR(ackOf(mid, w.b.local))
        XCTAssertEqual(w.r.ackStore.countFrames(), 1)

        enqueueAtOrigin(w, mid)
        let stranger = try newLocal(0x44, 0x55)
        let badAck = ackOf(mid, stranger)
        let rejected = w.a.dispatcher.dispatch(badAck, receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertTrue(isOrigin(rejected))
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(stateOf(w.a.tracker, mid), .handedToRelay,
                       "delivery is UNCHANGED by a rejected candidate")
        let good = w.a.dispatcher.dispatch(ackOf(mid, w.b.local),
                                          receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertTrue(good.accepted)
        XCTAssertEqual(stateOf(w.a.tracker, mid), .acknowledgedByRecipient)
    }

    // ------------------------------------------------------------ W10

    /// W10 -- process death and reconnect: a NEW pump over the SAME durable store
    /// rebuildeth custody from the store alone, and reacheth the origin.
    func testW10RelayProcessDeathAndReconnectStillReturnethTheReceipt() throws {
        let w = try world()
        let mid = msgId(10)
        enqueueAtOrigin(w, mid)
        _ = w.hopBtoR(ackOf(mid, w.b.local))
        XCTAssertEqual(w.r.ackStore.countFrames(), 1)

        let reborn = DurableAckPump(store: w.r.ackStore, admitForeign: { encoded, from in
            w.r.driver.admitForeignCandidate(encoded, receivedFrom: from)
        })
        XCTAssertEqual(reborn.custodyCount(), 1, "custody surviveth the process")
        XCTAssertFalse(reborn.isScheduled(Data(w.a.local.id.nodeId)))
        reborn.onLinkReady(Data(w.a.local.id.nodeId), now: 50)
        let batch = reborn.nextBatch(Data(w.a.local.id.nodeId), now: 50)
        XCTAssertEqual(batch.copies.count, 1)
        guard let rebornCopy = firstCopy(batch, "the reborn copy") else { return }
        let verdict = w.a.dispatcher.dispatch(try FrameV2.decode(rebornCopy.encodedFrame)!,
                                             receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertTrue(verdict.accepted)
        XCTAssertEqual(stateOf(w.a.tracker, mid), .acknowledgedByRecipient)

        let sweep = reborn.sweep(now: 50, wallEstimateMs: 0, continuity: .unknown)
        XCTAssertEqual(sweep.scanned, 1)
        XCTAssertEqual(sweep.refusedReplenish, 0)
        XCTAssertTrue(sweep.debited == 1 || sweep.expired == 1,
                      "an unknown continuity debiteth at least one hour")

        // the debit never REPLENISHETH: an equal or greater value changeth
        // nothing, so no restart and no duplicate can extend a life
        guard case .records(let standing) = w.r.ackStore.listCandidates(64) else {
            return XCTFail("the estate must be enumerable")
        }
        XCTAssertEqual(standing.count, 1, "the estate standeth after a one-hour debit")
        guard let candidate = standing.first else { return XCTFail("the estate must be enumerable") }
        XCTAssertFalse(w.r.ackStore.debitCandidateLifetime(candidate.ackKey,
                                                           remainingLifetimeMs: Int64.max),
                       "a debit may never EXTEND a candidate's life")
        XCTAssertFalse(w.r.ackStore.debitCandidateLifetime(candidate.ackKey,
                                                           remainingLifetimeMs: candidate.remainingLifetimeMs),
                       "an EQUAL value changeth nothing either")
        XCTAssertTrue(w.r.ackStore.debitCandidateLifetime(candidate.ackKey,
                                                          remainingLifetimeMs: candidate.remainingLifetimeMs - 1_000),
                      "a strictly shorter life IS applied")
    }

    // ------------------------------------------------------------ W11

    /// W11 -- an expired or cancelled origin cannot be acknowledged, and a
    /// TTL-exhausted candidate is never forwarded.
    func testW11AnExpiredOrCancelledOriginAndTtlExhaustion() throws {
        let w = try world()
        let expiredMid = msgId(11)
        enqueueAtOrigin(w, expiredMid)
        XCTAssertEqual(w.a.tracker.expire(expiredMid), .applied)
        let atExpired = w.a.dispatcher.dispatch(ackOf(expiredMid, w.b.local),
                                               receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertFalse(atExpired.accepted)
        XCTAssertEqual(stateOf(w.a.tracker, expiredMid), .expired)

        let cancelledMid = msgId(12)
        enqueueAtOrigin(w, cancelledMid)
        XCTAssertEqual(w.a.tracker.cancel(cancelledMid), .applied)
        let atCancelled = w.a.dispatcher.dispatch(ackOf(cancelledMid, w.b.local),
                                                  receivedFrom: Data(w.r.local.id.nodeId))
        XCTAssertFalse(atCancelled.accepted)
        XCTAssertEqual(stateOf(w.a.tracker, cancelledMid), .cancelledLocally)

        _ = w.hopBtoR(ackOf(msgId(13), w.b.local, ttl: 1))
        w.r.pump.onLinkReady(Data(w.a.local.id.nodeId), now: 60)
        let batch = w.r.pump.nextBatch(Data(w.a.local.id.nodeId), now: 60)
        XCTAssertEqual(batch.copies.count, 0)
        XCTAssertEqual(batch.refusals[.ttlExhausted], 1)
        XCTAssertEqual(w.r.ackStore.countFrames(), 1,
                       "the estate is retained, never silently dropped")
    }

    // ------------------------------------------------------------ W12

    /// W12 -- capacity is refused EXPLICITLY, and a refusal poisoneth nothing.
    func testW12CandidateCapacityIsRefusedExplicitly() throws {
        let w = try world()
        let mid = msgId(14)
        enqueueAtOrigin(w, mid)
        let claimed = try newLocal(0x61, 0x71)
        var refusedSeen = 0
        for i in 0..<6 {
            let signature = Data((0..<64).map { UInt8(($0 + i) & 0xFF) })
            let frame = FrameV2(type: .ack, msgId: mid, routingTag: Data(repeating: 7, count: 4),
                                ttl: UInt8(ackRelayInitialTtl), hopCount: 0, flags: 0,
                                payload: signature + Data(claimed.id.nodeId))
            let verdict = w.r.dispatcher.dispatch(frame, receivedFrom: Data(w.a.local.id.nodeId))
            if case .refused(let reason, _) = verdict {
                XCTAssertEqual(reason, .candidateCapacity)
                refusedSeen += 1
            }
            if case .opaqueRelay(let admission) = verdict {
                XCTAssertNotEqual(admission.verificationClass, AckVerificationClass.verifiedRecipiant,
                                  "an unknown-key relay never claimeth recipient verification")
            }
        }
        XCTAssertEqual(refusedSeen, 2, "the fifth and the sixth are refused, not silently dropped")
        XCTAssertEqual(w.r.ackStore.countFrames(), 4, "four candidates of one pair stand")
        XCTAssertEqual(stateOf(w.a.tracker, mid), .handedToRelay, "the origin state is untouched")
        XCTAssertEqual(heldFrames(w.r.store), 0, "the original message is untouched")
    }

    // ------------------------------------------------------------ W13

    /// W13 -- malformed and non-canonical ACKs are refused by name before any
    /// write, and a FAILED delivery lookup is never read as relay traffic.
    func testW13MalformedFramesAndAFailedLookupAreRefusedByName() throws {
        let w = try world()
        let mid = msgId(15)
        let short = FrameV2(type: .ack, msgId: mid, routingTag: Data(repeating: 7, count: 4),
                            ttl: UInt8(ackRelayInitialTtl), hopCount: 0, flags: 0,
                            payload: Data(repeating: 0, count: 16))
        XCTAssertEqual(refusedReason(w.r.dispatcher.dispatch(short, receivedFrom: Data(w.a.local.id.nodeId))),
                       .malformedPayload)

        let flagged = FrameV2(type: .ack, msgId: mid, routingTag: Data(repeating: 7, count: 4),
                              ttl: UInt8(ackRelayInitialTtl), hopCount: 0,
                              flags: FrameV2.Flags.relay_ok, payload: Data(repeating: 0, count: 80))
        XCTAssertEqual(refusedReason(w.r.dispatcher.dispatch(flagged, receivedFrom: Data(w.a.local.id.nodeId))),
                       .nonCanonicalFlags)
        XCTAssertEqual(w.r.ackStore.countFrames(), 0, "no write preceded either refusal")

        let failing = AckDispatcher(lookupDeliveryRow: { _ in .storageFailure },
                                    verifyOrigin: { _ in .storageFailure },
                                    admitCandidate: { _, _ in
                                        AckAdmission(result: .stored(ackKey: Data(repeating: 1, count: 32)),
                                                     ackKey: nil, verificationClass: nil)
                                    })
        XCTAssertEqual(refusedReason(failing.dispatch(ackOf(mid, w.b.local), receivedFrom: nil)),
                       .deliveryStateUnreadable)
        let corrupt = AckDispatcher(lookupDeliveryRow: { _ in .corrupt },
                                    verifyOrigin: { _ in .corrupt },
                                    admitCandidate: { _, _ in
                                        AckAdmission(result: .stored(ackKey: Data(repeating: 1, count: 32)),
                                                     ackKey: nil, verificationClass: nil)
                                    })
        XCTAssertEqual(refusedReason(corrupt.dispatch(ackOf(mid, w.b.local), receivedFrom: nil)),
                       .deliveryStateUnreadable)
    }

    // ------------------------------------------------------------ W14

    /// W14 -- the WIRING: MeshNode route eth an ACK to the dispatcher before any
    /// generic message TTL/dedup/store handling, and the historical
    /// point-to-point face standeth when no namespace is bound.
    func testW14MeshNodeDispatchethTheAckAndNeverDiscardethRelayTraffic() throws {
        let w = try world()
        let mid = msgId(16)
        let wired = MeshNode(identity: w.a.local.id, store: w.a.store,
                             deliveryTracker: w.a.tracker,
                             sessions: SessionManager(identity: w.a.local.id,
                                                      trustAuthority: FailClosedTrust()))
        XCTAssertNil(wired.ackDispatcher, "no namespace is bound by default")
        let ack = ackOf(mid, w.b.local)
        XCTAssertFalse(wired.ingestInbound(ack, receivedFrom: Data(w.r.local.id.nodeId)),
                       "the historical face is point-to-point: an unknown msgId is refused")
        XCTAssertEqual(w.a.ackStore.countFrames(), 0)

        wired.ackDispatcher = w.a.dispatcher
        XCTAssertTrue(wired.ingestInbound(ack, receivedFrom: Data(w.r.local.id.nodeId)),
                      "relay traffic is carried, never silently dropped")
        XCTAssertEqual(w.a.ackStore.countFrames(), 1)
        XCTAssertEqual(heldFrames(w.a.store), 0,
                       "the router never saw it (no bloom/inventory entry)")
    }
}
