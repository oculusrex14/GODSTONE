import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

/// Stage 4C / C6 + C7 -- the MeshNode outbound (C6) and inbound-ACK (C7) wiring,
/// exercised at the NODE level on a real `MeshNode` (no link layer, no BLE).
/// Mirrors `MeshNodeDeliveryIntegrationTest` on Android one-for-one.
///
/// C6 (outbound): `dispatchSos` persists BEFORE driving the delivery tracker
/// (persist-before-tracker, extending the 4B.1 persist-before-forward gate), then
/// `enqueue(msgId, ackMode: .none, expectedRecipient: nil)` (SOS broadcast ->
/// AckMode.none, no recipient binding) and `markHandedToRelay` per successful
/// send. Asserts:
///   - persist succeeds + N successful sends -> .handedToRelays(N) + .handedToRelay
///   - persist succeeds + 0 peers -> .queuedDurably + .queuedDurably
///   - persist fails -> .notPersisted + tracker UNTOUCHED (no delivery claimed for
///     a message this node does not durably hold)
///
/// C7 (inbound ACK): `ingestInbound` routes an ACK frame to `deliveryTracker
/// .acknowledge`, which binds it to the durable expected recipient (C2) and
/// advances to .acknowledgedByRecipient only on cryptographic proof. The Bool
/// this seam returns is true only for `.applied` / `.alreadyAcknowledged` /
/// `.duplicateAuthenticatedAck` (the latter two are idempotent accepts, NOT new
/// verifications -- this path does NOT call `onSosAcknowledgedByRecipient`, so
/// no UI "delivered" claim is made from host-only evidence). Asserts:
///   - ACK from the bound recipient -> .acknowledgedByRecipient
///   - ACK from a different recipient -> rejected, stays .handedToRelay
///   - production fail-closed (UnresolvedRecipientKeyResolver) -> rejected,
///     stays .handedToRelay (no delivery on host-only evidence; A-03/ADR-005 OPEN)
///   - a non-ACK frame is routed to the epidemic router, NOT the tracker
///
/// The DeliveryTracker truth-table / negative-ACK matrix / reboot recovery are
/// covered in `DeliveryTrackerTests` / `SqliteDeliveryRepositoryTests`; these
/// tests pin the MeshNode CALL-SITE wiring (the C6/C7 seams) on top of that
/// machine.
final class MeshNodeDeliveryIntegrationTests: XCTestCase {

    private func msgId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
    }
    private let routingTag = Data([0, 1, 2, 3])
    private func nodeA() -> Data { Data(repeating: 0x01, count: 16) }
    private func nodeB() -> Data { Data(repeating: 0x02, count: 16) }

    /// C6.4-B helper: the state inside a `.found` lookup (fail the test otherwise).
    /// Replaces the lossy `tracker.state(mid)` seam, which collapsed notFound /
    /// corrupt / storageFailure all to `.unavailable`.
    private func stateOf(_ tracker: DeliveryTracker, _ mid: Data) -> DeliveryState {
        if case .found(let rec) = tracker.lookup(mid) { return rec.state }
        XCTFail("expected .found(\(mid))"); return .unavailable
    }

    /// In-memory `DeliveryRepository` (mirroring `SqliteDeliveryRepository` over
    /// a real DB). Stores the full `DeliveryRecord` so the binding is preserved
    /// across state transitions; `transition` / `acknowledgeBound` advance only
    /// the state column (recipient is IMMUTABLE post-creation). C6.4: the public
    /// `compareAndSet(validFroms,target)` / `acknowledgeAndRetire` seams were
    /// replaced by the truth-table-owned `transition(msgId, DeliveryTransition)`
    /// and the binding-CAS `acknowledgeBound`; `clear` is typed (`ClearResult`).
    private final class InMemoryDeliveryRepository: DeliveryRepository {
        var map: [Data: DeliveryRecord] = [:]

        func get(_ msgId: Data) -> DeliveryLookup {
            if let rec = map[msgId] { return .found(rec) }
            return .notFound
        }
        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            guard bindingConsistent(ackMode: ackMode, expectedRecipient: expectedRecipient) else { return .corrupt }
            switch get(msgId) {
            case .notFound:
                map[msgId] = DeliveryRecord(msgId: msgId, state: .queuedDurably,
                                             ackMode: ackMode, expectedRecipientNodeId: expectedRecipient)
                return .created
            case .found(let rec):
                return classifyExisting(rec: rec, ackMode: ackMode, expectedRecipient: expectedRecipient)
            case .corrupt:
                return .corrupt
            case .storageFailure:
                return .storageFailure
            case .invalidArgument:
                return .invalidArgument
            }
        }
        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
            let target: DeliveryState, validFroms: Set<DeliveryState>
            switch transition {
            case .markHanded: target = .handedToRelay; validFroms = [.queuedDurably]
            case .expire:     target = .expired;        validFroms = [.queuedDurably, .handedToRelay]
            case .cancel:     target = .cancelledLocally; validFroms = [.queuedDurably, .handedToRelay]
            }
            switch get(msgId) {
            case .notFound: return .unknownMessage
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            case .found(let rec):
                let s = rec.state
                if s == target { return .alreadyInTarget }
                if validFroms.contains(s) {
                    map[msgId] = DeliveryRecord(msgId: msgId, state: target,
                                                 ackMode: rec.ackMode,
                                                 expectedRecipientNodeId: rec.expectedRecipientNodeId)
                    return .applied
                }
                return .rejectedState
            }
        }
        func acknowledgeBound(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            switch get(msgId) {
            case .notFound: return .unknownMessage
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            case .found(let rec):
                if rec.ackMode != .singleRecipient || rec.expectedRecipientNodeId != .some(expectedRecipient) {
                    return .unknownMessage
                }
                switch rec.state {
                case .acknowledgedByRecipient: return .duplicateAuthenticatedAck
                case .expired, .cancelledLocally: return .rejectedState
                case .queuedDurably, .handedToRelay:
                    map[msgId] = DeliveryRecord(msgId: msgId, state: .acknowledgedByRecipient,
                                                 ackMode: rec.ackMode,
                                                 expectedRecipientNodeId: rec.expectedRecipientNodeId)
                    return .applied
                default: return .rejectedState
                }
            }
        }
        func clear(_ msgId: Data) -> ClearResult {
            if map.removeValue(forKey: msgId) != nil { return .cleared }
            return .alreadyAbsent
        }

        private func classifyExisting(rec: DeliveryRecord, ackMode: AckMode,
                                      expectedRecipient: Data?) -> EnqueueResult {
            if rec.state.isTerminal { return .rejectedTerminalState }
            if rec.ackMode == ackMode && rec.expectedRecipientNodeId == expectedRecipient {
                return .alreadyQueuedSameBinding
            }
            return .conflictRecipient
        }

        private func bindingConsistent(ackMode: AckMode, expectedRecipient: Data?) -> Bool {
            switch ackMode {
            case .none: return expectedRecipient == nil
            case .singleRecipient:
                guard let r = expectedRecipient else { return false }
                return r.count == 16
            }
        }
    }

    /// Resolver binding two distinct node ids to two distinct keys (C2 binding).
    private final class TwoRecipientResolver: RecipientKeyResolver {
        let a: Data, pubA: Data, b: Data, pubB: Data
        init(_ a: Data, _ pubA: Data, _ b: Data, _ pubB: Data) {
            self.a = a; self.pubA = pubA; self.b = b; self.pubB = pubB
        }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? {
            if nodeId == a { return pubA }
            if nodeId == b { return pubB }
            return nil
        }
    }

    /// A `MessageStore` whose `persist` always fails (`.failedStorage`) -- the C6
    /// persist-failure gate.
    private final class AlwaysFailingStore: MessageStore {
        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult { .failedStorage }
        func allHeldOrderedByPriority() -> [FrameV2] { [] }
        func allHeldMsgIds() -> [Data] { [] }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
        func forEachHeldMsgId(_ visit: (Data) -> Bool) {}
        var heldBytes: Int64 { 0 }
    }

    /// A real Ed25519 keypair (32-byte raw pub/priv).
    private func realKeypair() -> (pub: Data, priv: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv.publicKey.rawRepresentation, priv.rawRepresentation)
    }

    /// Build a node over `store` + an in-memory repository/tracker with the
    /// supplied resolver. Returns the node + the repository so tests can assert
    /// on the durable delivery state. The caller retains its own `store`
    /// reference.
    private func makeNode(store: MessageStore,
                          resolver: RecipientKeyResolver) -> (MeshNode, InMemoryDeliveryRepository) {
        let identity = MeshIdentity(
            signingKey: Curve25519.Signing.PrivateKey(),
            agreementKey: Curve25519.KeyAgreement.PrivateKey())
        let journal = InMemoryDeliveryRepository()
        let tracker = DeliveryTracker(repo: journal,
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver))
        let node = MeshNode(identity: identity, store: store, deliveryTracker: tracker)
        return (node, journal)
    }

    // --- C6: outbound SOS dispatch drives the delivery tracker ---

    /// C6: persist succeeds + 1 successful send -> .handedToRelays(1) and the
    /// tracker reaches .handedToRelay (persist-before-tracker: enqueue runs only
    /// after persist succeeded, markHandedToRelay after the send returned true).
    func testC6DispatchSosWithASuccessfulSendReachesHandedToRelay() {
        let store = InMemoryMessageStore()
        let (node, journal) = makeNode(store: store, resolver: UnresolvedRecipientKeyResolver())
        node.transportDidConnect(peerId: UUID())
        var sentFrame: FrameV2?
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { frame, _ in
            sentFrame = frame
            return true
        }
        XCTAssertEqual(result, .handedToRelays(1))
        guard let mid = sentFrame?.msgId else { return XCTFail("send must receive the frame") }
        XCTAssertEqual(stateOf(node.deliveryTracker, mid), .handedToRelay)
        // SOS broadcast is AckMode.none and binds NO recipient (C6.1).
        guard let rec = journal.map[mid] else { return XCTFail("tracker must record the handed SOS") }
        XCTAssertEqual(rec.ackMode, .none)
        XCTAssertNil(rec.expectedRecipientNodeId)
        XCTAssertEqual(store.allHeldMsgIds().count, 1, "SOS durably held before the send")
    }

    /// C6: persist succeeds + 0 peers -> .queuedDurably and the tracker reaches
    /// .queuedDurably (enqueued, but never handed -- no peer to hand to).
    func testC6DispatchSosWithZeroPeersStaysQueuedDurably() {
        let store = InMemoryMessageStore()
        let (node, journal) = makeNode(store: store, resolver: UnresolvedRecipientKeyResolver())
        var sendCalls = 0
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, _ in
            sendCalls += 1
            return true
        }
        XCTAssertEqual(result, .queuedDurably)
        XCTAssertEqual(sendCalls, 0, "no peers -> no sends, but durably held")
        XCTAssertEqual(store.allHeldMsgIds().count, 1, "SOS durably held")
        let mid = store.allHeldMsgIds().first!
        XCTAssertEqual(stateOf(node.deliveryTracker, mid), .queuedDurably)
        guard let rec = journal.map[mid] else { return XCTFail("tracker must record the queued SOS") }
        XCTAssertEqual(rec.ackMode, .none)
    }

    /// C6: persist fails -> .notPersisted, ZERO sends, and the tracker is NOT
    /// touched -- no delivery is claimed for a message this node does not durably
    /// hold (persist-before-tracker).
    func testC6DispatchSosPersistFailureLeavesTheTrackerUntouched() {
        let store = AlwaysFailingStore()
        let (node, journal) = makeNode(store: store, resolver: UnresolvedRecipientKeyResolver())
        node.transportDidConnect(peerId: UUID())
        var sendCalls = 0
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, _ in
            sendCalls += 1
            return true
        }
        XCTAssertEqual(result, .notPersisted)
        XCTAssertEqual(sendCalls, 0, "persistence failure must exit before any transport operation")
        XCTAssertTrue(journal.map.isEmpty, "tracker must not record a message that was not durably held")
        XCTAssertTrue(store.allHeldMsgIds().isEmpty)
    }

    // --- C7: inbound ACK dispatch binds to the durable expected recipient ---

    /// C7: an ACK from the bound recipient advances the state to
    /// .acknowledgedByRecipient. The expected recipient was bound in durable
    /// outbound state INDEPENDENT of the ACK (C1/C2).
    func testC7IngestInboundAckFromBoundRecipientReachesAcknowledged() throws {
        let (pubA, privA) = realKeypair()
        let a = nodeA()
        let resolver = TwoRecipientResolver(a, pubA, nodeB(), Data(count: 32))
        let (node, _) = makeNode(store: InMemoryMessageStore(), resolver: resolver)
        let mid = msgId(1)
        // Pre-bind the outbound state (a directed message's enqueue), then hand it.
        XCTAssertEqual(EnqueueResult.created, node.deliveryTracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: a))
        XCTAssertEqual(TransitionResult.applied, node.deliveryTracker.markHandedToRelay(mid))
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                     recipientNodeId: a, routingTag: routingTag)
        let accepted = node.ingestInbound(ack, receivedFrom: a)
        XCTAssertTrue(accepted, "an ACK from the bound recipient must be accepted")
        XCTAssertEqual(stateOf(node.deliveryTracker, mid), .acknowledgedByRecipient)
    }

    /// C7: an ACK from a DIFFERENT recipient (bound recipient was A, ACK claims
    /// B and is signed by B) is rejected -- the expected recipient bound in
    /// durable state is independent of the ACK, so a stranger's ACK cannot
    /// advance delivery. State stays .handedToRelay.
    func testC7IngestInboundAckFromWrongRecipientIsRejected() throws {
        let (pubA, _) = realKeypair()
        let (pubB, privB) = realKeypair()
        let a = nodeA(), b = nodeB()
        let resolver = TwoRecipientResolver(a, pubA, b, pubB)
        let (node, _) = makeNode(store: InMemoryMessageStore(), resolver: resolver)
        let mid = msgId(2)
        XCTAssertEqual(EnqueueResult.created, node.deliveryTracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: a))
        XCTAssertEqual(TransitionResult.applied, node.deliveryTracker.markHandedToRelay(mid))
        // ACK claims B and is signed by B -- but the bound recipient is A.
        let wrongAck = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privB,
                                          recipientNodeId: b, routingTag: routingTag)
        let accepted = node.ingestInbound(wrongAck, receivedFrom: b)
        XCTAssertFalse(accepted, "an ACK from a recipient other than the bound one must be rejected")
        XCTAssertEqual(stateOf(node.deliveryTracker, mid), .handedToRelay)
    }

    /// C7: the PRODUCTION authenticator is fail-closed
    /// (UnresolvedRecipientKeyResolver resolves no key), so even a well-formed
    /// ACK signed by the bound recipient is rejected and the state stays
    /// .handedToRelay -- no delivery is claimed until M2-link binds real
    /// recipient keys (A-03 / ADR-005 OPEN).
    func testC7ProductionIngestInboundAckIsFailClosedUnderUnresolvedResolver() throws {
        let (_, privA) = realKeypair()
        let a = nodeA()
        let (node, _) = makeNode(store: InMemoryMessageStore(), resolver: UnresolvedRecipientKeyResolver())
        let mid = msgId(3)
        XCTAssertEqual(EnqueueResult.created, node.deliveryTracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: a))
        XCTAssertEqual(TransitionResult.applied, node.deliveryTracker.markHandedToRelay(mid))
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                     recipientNodeId: a, routingTag: routingTag)
        let accepted = node.ingestInbound(ack, receivedFrom: a)
        XCTAssertFalse(accepted, "fail-closed: the unresolved resolver rejects every ACK")
        XCTAssertEqual(stateOf(node.deliveryTracker, mid), .handedToRelay)
    }

    /// C7: a non-ACK frame is routed to the epidemic router, NOT the delivery
    /// tracker (ACK frames are point-to-point; every other type is epidemic
    /// content to persist + relay). The tracker is left untouched, and the router
    /// durably holds the epidemic frame.
    func testC7IngestInboundNonAckFrameDoesNotTouchTheDeliveryTracker() {
        let store = InMemoryMessageStore()
        let (node, journal) = makeNode(store: store, resolver: UnresolvedRecipientKeyResolver())
        // A non-ACK (SOS) frame, built inline (mirrors dispatchSos's frame shape).
        let sos = FrameV2(
            type: .sos,
            msgId: msgId(7),
            routingTag: routingTag,
            ttl: FrameV2.maxTtl,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok),
            payload: Data(count: 8))
        let accepted = node.ingestInbound(sos, receivedFrom: Data(repeating: 0x20, count: 16))
        XCTAssertTrue(accepted, "the router must accept a fresh epidemic SOS")
        // The router persists the SOS (epidemic); the delivery tracker does not
        // track it (an inbound SOS is not a delivery confirmation for THIS node).
        XCTAssertTrue(journal.map.isEmpty, "the tracker must not track an inbound non-ACK frame")
        XCTAssertEqual(store.allHeldMsgIds().count, 1, "the router durably held the epidemic SOS")
    }
}