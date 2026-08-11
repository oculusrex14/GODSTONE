import Foundation
import CryptoKit
import GodstoneCore

public enum SosDispatchResult: Equatable, Sendable {
    case unavailable(String)
    /// Durably held but no peer was connected to hand it to -- it will reach a
    /// peer on the next encounter via anti-entropy. Reported only AFTER durable
    /// success, so the UI never calls a one-process-death-from-gone SOS "queued".
    case queuedDurably
    case handedToRelays(Int)
    case notPersisted
    case failed(String)
}

/// One identity, router, radio stack and session registry for the process.
public final class MeshNode {
    public static let linkLayerReady = false
    public static let linkLayerOpenReason =
        "Encrypted BLE record reassembly and the Noise handshake driver are not implemented yet. Radio transmission is disabled in this pre-alpha build."

    public let identity: MeshIdentity
    /// Durable hold, injected before `start()` (ADR-004 / Stage 4B). The router
    /// builds its anti-entropy digest from this store's held msg_ids and
    /// persists every accepted frame before forwarding, so a node cannot start
    /// without the durable source of truth it relays from. Mirrors Android
    /// `MeshNode(ctx, store)`.
    public let store: MessageStore
    /// Durable, recipient-authenticated delivery state machine (ADR-005; A-03;
    /// Stage 4C / C6.1; C6.3). Constructed by the composition root from the SAME
    /// `SqliteMessageStore` as `store`: a `SqliteDeliveryRepository` is the
    /// durable record -- one row holds the delivery state, the ACK mode, and the
    /// intended recipient (the separate `ExpectedRecipientStore` seam was removed
    /// in C6.1), and an `Ed25519AckAuthenticator` over the production
    /// `UnresolvedRecipientKeyResolver` rejects every ACK until the M2-link
    /// identity binding wires real recipient keys (fail-closed). The outbound
    /// path (C6) records the ACK mode (SOS is a broadcast -> `AckMode.none`, no
    /// recipient binding; a directed message is `AckMode.singleRecipient`) +
    /// advances state on a successful relay hand-off; the inbound ACK path (C7)
    /// binds the ACK to the durable expected recipient (authenticator invoked
    /// ONLY for singleRecipient -- a none-mode message can never be
    /// acknowledged). No delivery is claimed on host-only evidence --
    /// A-03 / ADR-005 stay OPEN. Mirrors Android `MeshNode.deliveryTracker`.
    public let deliveryTracker: DeliveryTracker
    public private(set) lazy var ble = BleTransport()
    public private(set) lazy var router = Router()
    public private(set) lazy var sessions = SessionManager(identity: identity)

    private var peers: Set<UUID> = []
    private let peerLock = NSLock()
    public var onPeerCountChanged: ((Int) -> Void)?
    private var isStarted = false

    /// Production initializer: a node owns its durable store AND its durable
    /// delivery tracker (Stage 4C / C5). The tracker is constructed by the
    /// composition root from the same `SqliteMessageStore` so the delivery_state
    /// row lives in the same DB as the held frames. Mirrors Android
    /// `MeshNode(ctx, store, deliveryTracker)`.
    public init(identity: MeshIdentity, store: MessageStore,
                deliveryTracker: DeliveryTracker) {
        self.identity = identity
        self.store = store
        self.deliveryTracker = deliveryTracker
        // Inject the durable store into the router before start (Stage 4B).
        self.router.store = store
    }

    @discardableResult
    public func start() -> Bool {
        guard Self.linkLayerReady else { return false }
        guard !isStarted else { return true }
        isStarted = true
        ble.delegate = self
        ble.sessions = sessions
        router.onForward = { [weak self] frame in
            guard let self else { return }
            for peer in self.currentPeers() { _ = self.ble.send(frame, to: peer) }
        }
        ble.start()
        return true
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        sessions.destroyAll()
        ble.stop()
        peerLock.lock(); peers.removeAll(); peerLock.unlock()
        onPeerCountChanged?(0)
    }

    private func currentPeers() -> [UUID] {
        peerLock.lock(); defer { peerLock.unlock() }
        return Array(peers)
    }

    /// V4 does not fabricate a successful SOS while ADR-004 and M2-link remain open.
    public func broadcastSos(payload: Data) -> SosDispatchResult {
        guard Self.linkLayerReady else { return .unavailable(Self.linkLayerOpenReason) }
        return dispatchSos(payload: payload) { [weak self] frame, peer in
            guard let self else { return false }
            return self.ble.send(frame, to: peer)
        }
    }

    /// Stage 4B.1 (B4): the SOS dispatch logic, ungated so it is unit-testable
    /// without the link layer. Persists BEFORE any transport operation: a SOS
    /// this node cannot durably hold is NOT sent (zero sends) and reported
    /// `.notPersisted` so the UI does not lie. `.heldNew` or `.heldDuplicate` both
    /// mean durably held (a duplicate SOS was already queued), so either proceeds
    /// to transport; only a capacity rejection or storage failure exits before
    /// any BLE write. With durable success and zero connected peers the SOS is
    /// `.queuedDurably` (it reaches a peer on the next encounter via
    /// anti-entropy); with N successful sends, `.handedToRelays(N)`. The previous
    /// iOS `broadcastSos` ignored `router.ingest`'s return and could attempt BLE
    /// sends after a persistence failure -- this gate fixes that (Android
    /// `SosDispatchResult` parity). Calls `store.persist` directly (Android
    /// parity), avoiding the double-relay that routing the locally-originated
    /// SOS through `router.ingest` would cause.
    @discardableResult
    internal func dispatchSos(payload: Data, send: (FrameV2, UUID) -> Bool) -> SosDispatchResult {
        // GMP/2.1 (ADR-001 §3.3): msg_id is content-derived, not random, so
        // duplicate SOS submissions collapse in every relay's dedup cache. The
        // creation time is bound into the id (little-endian) and authenticated
        // alongside the payload by the signature below. Byte-identical to
        // Android Router.buildSos / MessageId.derive (see MessageIdTests).
        let createdAt = Int64(Date().timeIntervalSince1970)
        let msgId = MessageId.derive(
            senderNodeId: identity.nodeId,
            createdAtEpochSeconds: createdAt,
            payload: payload)

        let magic = Data("SOS1".utf8)
        guard let signature = try? identity.signingKey.signature(for: msgId + magic + payload) else {
            return .failed("SOS signing failed")
        }
        let sealed = magic + signature + payload
        let frame = FrameV2(
            type: .sos,
            msgId: msgId,
            routingTag: identity.nodeHint,
            ttl: FrameV2.maxTtl,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok),
            payload: sealed)

        switch store.persist(frame, receivedFrom: identity.nodeId) {
        case .heldNew, .heldDuplicate:
            // Stage 4C.1 / C6.1: record the delivery lifecycle AFTER durable hold
            // (persist-before-tracker, extending the 4B.1 persist-before-forward
            // gate to the delivery state). SOS is a broadcast (no single intended
            // recipient), so it is enqueued with `AckMode.none` and no expected
            // recipient binding -- a none-mode message can NEVER be acknowledged
            // via this tracker (an inbound ACK for it yields `.notAckEligible` and
            // the authenticator is not invoked). Idempotent: a re-dispatch of the
            // same SOS is `.alreadyQueuedSameBinding`; only a genuine enqueue
            // rejection aborts before any BLE write. Each successful relay
            // hand-off calls `markHandedToRelay` (idempotent: first transitions
            // queued -> handed).
            switch deliveryTracker.enqueue(frame.msgId, ackMode: .none, expectedRecipient: nil) {
            case .created, .alreadyQueuedSameBinding:
                break
            default:
                return .failed("delivery enqueue rejected")
            }
            let handed = currentPeers().reduce(into: 0) { count, peer in
                if send(frame, peer) {
                    count += 1
                    deliveryTracker.markHandedToRelay(frame.msgId)
                }
            }
            return handed == 0 ? .queuedDurably : .handedToRelays(handed)
        case .rejectedCapacity, .failedStorage:
            // Persistence failed: exit BEFORE any transport operation. Zero sends.
            // The delivery tracker is NOT touched -- no delivery is claimed for a
            // message this node does not durably hold (persist-before-tracker).
            return .notPersisted
        }
    }

    /// Stage 4C / C7 -- the inbound frame dispatch, ungated so it is unit-testable
    /// without the link layer. An inbound ACK frame (`.ack`) is a point-to-point
    /// delivery confirmation for a message THIS node sent, NOT epidemic content to
    /// relay -- it goes to the `DeliveryTracker` (which binds it to the durable
    /// expected recipient and advances the state only on cryptographic proof).
    /// Every other frame type goes to the epidemic `Router` (persist + relay).
    /// Mirrors Android `ingestInbound`. The production authenticator is fail-closed
    /// (`UnresolvedRecipientKeyResolver`), so no ACK verifies until M2-link binds
    /// real recipient keys -- A-03 / ADR-005 stay OPEN.
    ///
    /// C6.1: the Bool this seam returns is true only for `.applied` (this ACK
    /// newly verified the intended recipient), `.alreadyAcknowledged`, and
    /// `.duplicateAuthenticatedAck` (the message was already terminal -- an
    /// idempotent accept, NOT a new verification; this path does NOT call
    /// `onSosAcknowledgedByRecipient`, so no UI "delivered" claim is made from
    /// host-only evidence). Every other `AckResult` is a rejection -> false.
    @discardableResult
    internal func ingestInbound(_ frame: FrameV2, receivedFrom: Data) -> Bool {
        if frame.type == .ack {
            switch deliveryTracker.acknowledge(frame.msgId, frame) {
            case .applied, .alreadyAcknowledged, .duplicateAuthenticatedAck:
                return true
            default:
                return false
            }
        }
        return router.ingest(frame, isAddressedToMe: frame.routingTag == identity.nodeHint,
                             receivedFrom: receivedFrom)
    }
}

extension MeshNode: TransportDelegate {
    public func transportDidConnect(peerId: UUID) {
        peerLock.lock(); peers.insert(peerId); let count = peers.count; peerLock.unlock()
        onPeerCountChanged?(count)
    }

    public func transportReady(peerId: UUID) {
        // Deliberately no half-handshake. M2-link owns role election, real remote
        // hints, record types HS1/HS2/HS3, reassembly and timeouts.
    }

    public func transportDidDisconnect(peerId: UUID) {
        peerLock.lock(); peers.remove(peerId); let count = peers.count; peerLock.unlock()
        sessions.drop(peerId)
        onPeerCountChanged?(count)
    }

    public func transportDidReceive(data: Data, peerId: UUID) {
        guard Self.linkLayerReady, let frame = FrameV2.decode(data) else { return }
        // Stage 4C / C7: route ACK frames to the delivery tracker, all other
        // frames to the epidemic router, via the ungated `ingestInbound` seam.
        // The authenticated sender node_id is not available in the v2 header
        // (the sealed sender lives inside the encrypted payload) and the iOS BLE
        // transport exposes only a local peer UUID, not the remote node_id; the
        // real `receivedFrom` is wired when the M2-link layer (ADR-002, Stage 4H)
        // exposes the authenticated peer node_id. Until then an empty
        // `receivedFrom` records "sender not yet identified" -- honest, and this
        // path is unreachable while linkLayerReady=false in any case.
        ingestInbound(frame, receivedFrom: Data())
    }
}
