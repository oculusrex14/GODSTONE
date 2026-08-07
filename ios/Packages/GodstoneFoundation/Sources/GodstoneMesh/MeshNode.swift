import Foundation
import CryptoKit
import GodstoneCore

public enum SosDispatchResult: Equatable, Sendable {
    case unavailable(String)
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
    public private(set) lazy var ble = BleTransport()
    public private(set) lazy var router = Router()
    public private(set) lazy var sessions = SessionManager(identity: identity)

    private var peers: Set<UUID> = []
    private let peerLock = NSLock()
    public var onPeerCountChanged: ((Int) -> Void)?
    private var isStarted = false

    public init(identity: MeshIdentity) { self.identity = identity }

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

        // The current iOS router is memory-only. A zero-peer result is therefore
        // not QUEUED: termination would lose it. ADR-004 must land before that word
        // can appear in the UI.
        router.ingest(frame, isAddressedToMe: false)
        let handed = currentPeers().reduce(into: 0) { count, peer in
            if ble.send(frame, to: peer) { count += 1 }
        }
        return handed > 0 ? .handedToRelays(handed) : .notPersisted
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
        router.ingest(frame, isAddressedToMe: frame.routingTag == identity.nodeHint)
    }
}
