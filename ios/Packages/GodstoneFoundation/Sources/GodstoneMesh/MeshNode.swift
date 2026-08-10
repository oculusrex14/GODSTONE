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
    public private(set) lazy var ble = BleTransport()
    public private(set) lazy var router = Router()
    public private(set) lazy var sessions = SessionManager(identity: identity)

    private var peers: Set<UUID> = []
    private let peerLock = NSLock()
    public var onPeerCountChanged: ((Int) -> Void)?
    private var isStarted = false

    public init(identity: MeshIdentity, store: MessageStore) {
        self.identity = identity
        self.store = store
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
            let handed = currentPeers().reduce(into: 0) { count, peer in
                if send(frame, peer) { count += 1 }
            }
            return handed == 0 ? .queuedDurably : .handedToRelays(handed)
        case .rejectedCapacity, .failedStorage:
            // Persistence failed: exit BEFORE any transport operation. Zero sends.
            return .notPersisted
        }
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
        // Stage 4B: persist before forward. The authenticated sender node_id is
        // not available in the v2 header (the sealed sender lives inside the
        // encrypted payload) and the iOS BLE transport exposes only a local
        // peer UUID, not the remote node_id; the real `receivedFrom` is wired
        // when the M2-link layer (ADR-002, Stage 4H) exposes the authenticated
        // peer node_id. Until then an empty `receivedFrom` records "sender not
        // yet identified" -- honest, and this path is unreachable while
        // linkLayerReady=false in any case.
        router.ingest(frame, isAddressedToMe: frame.routingTag == identity.nodeHint,
                     receivedFrom: Data())
    }
}
