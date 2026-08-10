import Foundation
import GodstoneCore

/// Delay-tolerant epidemic router, GMP/2.
///
/// V4: `ingest` now takes `FrameV2`, resolving the v1/v2 type error at
/// MeshNode.swift:111. iOS is coherently v2; Android is coherently v1.
///
/// THIS ROUTER IS NOT AT PARITY WITH ANDROID AND V4 DOES NOT CLAIM IT IS.
/// Still missing, each blocked on an ADR rather than guessed at:
///   - proof of work            (Android enforces 20-bit on GROUP/BROADCAST)
///   - frame-age expiry         (Android drops > 14 days; v2 has no timestamp)
///   - digest from a durable store, not the dedup window   (ADR-004)
///   - DIGEST/WANT anti-entropy on encounter               (ADR-001 + ADR-002)
/// docs/adr/ADR-001 carries the full divergence table.
public final class Router {

    public static let defaultTtl: UInt8 = FrameV2.defaultTtl
    public static let maxTtl: UInt8 = FrameV2.maxTtl
    private static let seenCacheCapacity = 16_384

    private var seen = LruSet<Data>(capacity: Router.seenCacheCapacity)
    private var queue: [FrameV2] = []
    private let lock = NSLock()

    public var onDeliverLocally: ((FrameV2) -> Void)?
    public var onForward: ((FrameV2) -> Void)?

    /// Optional durable hold. When attached, the anti-entropy digest is built
    /// from the store's held msg_ids (the set of frames this node CARRIES),
    /// matching Android -- not from the rolling dedup window (the set of ids
    /// this node has RECENTLY SEEN). The two describe different sets for the
    /// same node state, so before this was attached reconciliation was
    /// semantically broken even with identical hash inputs (ADR-004 criterion 6,
    /// closed in Phase G). The in-memory `queue`/`seen` remain the routing
    /// buffer; the store is the durable source of truth for the digest.
    ///
    /// Stage 4B: the store is now injected before `MeshNode.start()` (see
    /// `MeshNode.init(identity:store:)`), so a production router always carries
    /// one. The `store` remains optional here only so the storeless unit-test
    /// router (no durable configuration) can still exercise the routing buffer;
    /// such a router builds an empty digest and skips persist-before-forward.
    public var store: MessageStore?

    public init() {}

    /// True when the frame was new and has been accepted (and, when a durable
    /// store is attached, durably held before it was forwarded).
    @discardableResult
    public func ingest(_ frame: FrameV2, isAddressedToMe: Bool, receivedFrom: Data) -> Bool {
        guard frame.ttl <= Router.maxTtl,
              frame.hopCount <= Router.maxTtl else { return false }

        // Only mutate the dedup set under the lock. User callbacks execute
        // outside it so a callback cannot deadlock by re-entering the router.
        lock.lock()
        let duplicate = seen.contains(frame.msgId)
        if !duplicate { seen.insert(frame.msgId) }
        lock.unlock()
        guard !duplicate else { return false }

        // Stage 4B: persist before forward (ADR-004). A frame that this node
        // cannot durably hold is NOT delivered locally or relayed -- forwarding
        // (or accepting for delivery) what this node cannot itself carry would
        // let the only copy be dropped. The store is the durable source of
        // truth; `persist` returns false only on a store failure (a duplicate
        // msg_id is INSERT OR IGNORE, i.e. already held -> true). A storeless
        // router (unit-test routing buffer) skips this gate and forwards as
        // before. Mirrors Android Router.onFrameReceived.
        if let store, !store.persist(frame, receivedFrom: receivedFrom) { return false }

        if isAddressedToMe {
            onDeliverLocally?(frame)
            // SOS is still relayed after local delivery: someone further away
            // may be the one who can actually help.
            if frame.type != .sos { return true }
        }

        if frame.ttl > 1, frame.hopCount < Router.maxTtl {
            enqueue(FrameV2(type: frame.type,
                            msgId: frame.msgId,
                            routingTag: frame.routingTag,
                            ttl: frame.ttl - 1,
                            hopCount: frame.hopCount + 1,
                            flags: frame.flags,
                            payload: frame.payload))
        }
        return true
    }

    private func enqueue(_ frame: FrameV2) {
        lock.lock(); defer { lock.unlock() }
        queue.append(frame)
        queue.sort { priority($0) < priority($1) }
        if queue.count > 512 {
            queue.removeLast(queue.count - 512)   // SOS sorts first, never dropped
        }
    }

    /// Delivery order under congestion. SOS always wins.
    private func priority(_ f: FrameV2) -> Int {
        switch f.type {
        case .sos:        return 0
        case .ack:        return 1
        case .hello:      return 2
        case .message:    return 3
        case .digest, .want: return 4
        case .ping, .goodbye: return 5
        case .bulk_offer, .bulk_chunk: return 6
        }
    }

    public func drain(limit: Int) -> [FrameV2] {
        lock.lock(); defer { lock.unlock() }
        let out = Array(queue.prefix(limit))
        queue.removeFirst(out.count)
        return out
    }

    /// 4096-bit Bloom digest.
    ///
    /// Built from the durable store's held msg_ids (the set of frames this node
    /// CARRIES) -- matching Android, so the two platforms build the same digest
    /// from the same held set (ADR-004 criterion 6, Phase G). Stage 4B removed
    /// the previous `seen.elements` fallback: that fallback described a
    /// different set (ids this node has RECENTLY SEEN, not ids CARRIED), so it
    /// was semantically broken even with identical hash inputs, and it is no
    /// longer reachable in production now the store is injected before start.
    /// A storeless (unit-test) router returns an empty digest rather than a
    /// semantically-wrong one.
    public func bloomDigest() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let store else { return BloomDigest.build(from: []) }
        return BloomDigest.build(from: store.allHeldMsgIds())
    }
}
