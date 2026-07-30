import Foundation
import GodstoneCore

/// Delay-tolerant epidemic router. Identical policy to the Android Router in
/// tab 04 — the two must agree or the mesh partitions along platform lines.
public final class Router {

    public static let defaultTtl: UInt8 = 12
    public static let maxTtl: UInt8 = 16
    private static let seenCacheCapacity = 16_384

    private var seen = LruSet<Data>(capacity: Router.seenCacheCapacity)
    private var queue: [Frame] = []
    private let lock = NSLock()

    public var onDeliverLocally: ((Frame) -> Void)?
    public var onForward: ((Frame) -> Void)?

    /// Returns true when the frame was new and has been accepted.
    @discardableResult
    public func ingest(_ frame: Frame, isAddressedToMe: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }

        // Deduplication is what stops an epidemic protocol from melting the
        // network. It is the single most important line in this file.
        guard !seen.contains(frame.messageId) else { return false }
        seen.insert(frame.messageId)

        guard frame.ttl <= Router.maxTtl else { return false }

        if isAddressedToMe {
            onDeliverLocally?(frame)
            // SOS is still relayed after local delivery: someone further away
            // may be the one who can actually help.
            if frame.type != .sos { return true }
        }

        if let next = frame.decremented() {
            enqueue(next)
        }
        return true
    }

    private func enqueue(_ frame: Frame) {
        queue.append(frame)
        queue.sort { $0.type.priority < $1.type.priority }
        // Bounded queue. Under flood, low-priority bulk is dropped first and
        // SOS is never dropped.
        if queue.count > 512 {
            queue.removeLast(queue.count - 512)
        }
    }

    public func drain(limit: Int) -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        let out = Array(queue.prefix(limit))
        queue.removeFirst(out.count)
        return out
    }

    /// 4096-bit Bloom digest of everything we hold, exchanged with each peer so
    /// they only send us what we are actually missing.
    public func bloomDigest() -> Data {
        lock.lock(); defer { lock.unlock() }
        return BloomDigest.build(from: seen.elements)
    }
}
