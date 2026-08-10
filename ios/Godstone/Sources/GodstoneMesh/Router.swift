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

    public convenience init() { self.init(seenCacheCapacity: Router.seenCacheCapacity) }

    /// Test-only init with a smaller dedup window so a test can age an id OUT of
    /// the window while it is still durably held, exercising the durable-UNIQUE-
    /// authority duplicate path (B1) -- unreachable at the production cache size
    /// without 16384+ frames.
    internal init(seenCacheCapacity: Int) {
        self.seen = LruSet<Data>(capacity: seenCacheCapacity)
    }

    /// True when the frame was new and has been accepted (and, when a durable
    /// store is attached, durably held before it was forwarded).
    @discardableResult
    public func ingest(_ frame: FrameV2, isAddressedToMe: Bool, receivedFrom: Data) -> Bool {
        guard frame.ttl <= Router.maxTtl,
              frame.hopCount <= Router.maxTtl else { return false }

        // Stage 4B.1 (B1): the durable store is the dedup authority and the
        // in-memory `seen` LRU is only an optimisation populated AFTER durable
        // acceptance. The accept/deliver/forward decision is taken under the
        // router lock so two concurrent same-msg_id arrivals cannot both pass
        // the dedup gate (at-most-once); user callbacks and `enqueue` run AFTER
        // the lock is released so they cannot deadlock re-entering the router or
        // the non-recursive queue lock. The store lock is acquired AFTER the
        // router lock here and in `bloomDigest` -- consistent ordering, no
        // deadlock.
        let d = accept(frame, isAddressedToMe: isAddressedToMe, receivedFrom: receivedFrom)
        guard d.accepted else { return false }
        if d.deliver { onDeliverLocally?(frame) }
        if let fwd = d.forwardCopy { enqueue(fwd) }
        return true
    }

    private struct IngestDecision {
        let accepted: Bool
        let deliver: Bool
        let forwardCopy: FrameV2?
    }

    /// Dedup + durable persist + deliver/forward decision under the router lock.
    /// `seen` is populated only AFTER durable acceptance, so a persist failure
    /// never poisons retry (B1): the same msg_id can be re-offered after the
    /// store recovers. A duplicate (LRU hit, or durable `.heldDuplicate`) is
    /// suppressed without re-relay. `.rejectedCapacity` / `.failedStorage` leave
    /// `seen` untouched so the retry path stays open. A storeless router uses
    /// `seen` as the authority (unit-test routing buffer).
    private func accept(_ frame: FrameV2, isAddressedToMe: Bool, receivedFrom: Data) -> IngestDecision {
        let none = IngestDecision(accepted: false, deliver: false, forwardCopy: nil)
        lock.lock()
        defer { lock.unlock() }
        // 1. Fast duplicate path (B1): the LRU is an OPTIMISATION only. A hit means
        //    this id was durably accepted at some point (or is a within-window
        //    duplicate), so short-circuit without touching the store.
        if seen.contains(frame.msgId) { return none }
        // 2. Durable authority (B1/B2). persist runs insert, hard-cap enforcement
        //    and the final-presence check in one transaction (B3) and reports the
        //    result; the relay/deliver decision is taken ONLY from this result.
        if let store {
            switch store.persist(frame, receivedFrom: receivedFrom) {
            case .heldNew:
                seen.insert(frame.msgId)
            case .heldDuplicate:
                // Already durably held (LRU aged the id out but the durable PK
                // still carries it): suppress re-relay, cache the id for fast-path.
                seen.insert(frame.msgId)
                return none
            case .rejectedCapacity, .failedStorage:
                // NOT durably held. Do NOT mark seen -- the same msg_id may be
                // re-offered after the store has room or recovers (B1: retry not
                // poisoned). No deliver, no relay.
                return none
            }
        } else {
            seen.insert(frame.msgId)   // storeless: dedup window is the authority
        }
        // 3. Accepted (HELD_NEW / storeless novel). Decide deliver + forward.
        let deliver = isAddressedToMe
        // SOS is still relayed after local delivery: someone further away may be
        // the one who can actually help. Non-SOS addressed-to-me is delivered and
        // NOT relayed further.
        let shouldRelay = !(isAddressedToMe && frame.type != .sos)
        var forwardCopy: FrameV2? = nil
        if shouldRelay && frame.ttl > 1 && frame.hopCount < Router.maxTtl {
            forwardCopy = FrameV2(type: frame.type,
                                  msgId: frame.msgId,
                                  routingTag: frame.routingTag,
                                  ttl: frame.ttl - 1,
                                  hopCount: frame.hopCount + 1,
                                  flags: frame.flags,
                                  payload: frame.payload)
        }
        return IngestDecision(accepted: true, deliver: deliver, forwardCopy: forwardCopy)
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
