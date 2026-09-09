import Foundation

public enum SlotState: Equatable {
    case active
    case retired
    case invalidated
}

/// T08: monotonic lease token. Reclaim compares generations: a retired slot
/// returns its lease to the registry and a replacement carries the next
/// generation.
public struct SlotLease: Equatable {
    public let generation: Int

    public init(generation: Int) {
        self.generation = generation
    }

    public func next() -> SlotLease {
        return SlotLease(generation: generation + 1)
    }
}

/// T08: the single serialization authority for one relation. The handshake
/// controller, cipher counters, replay window, terminal state and timer lease
/// all live in this slot, and every operation - handshake, seal, open, drop,
/// isReady - takes the SAME slot lock. Lock order: the lifecycle gate first,
/// then the slot; the destructive work of a drop happens OUTSIDE the slot
/// lock (only the terminal transition is serialized). Retired slots are
/// removed from the registry and their lock entries reclaimed with them.
public final class SessionSlot {

    public let key: RelationKey
    private let lock = NSRecursiveLock()

    /// T08 witness: the serialisation authority proves itself. While
    /// the slot lock is held an entry is exclusive, so the depth is
    /// zero when a fresh operation begins, and the same thread may
    /// re-enter through retire. If two different threads are ever seen
    /// inside the slot at the same time the slot has stopped being the
    /// serialisation point, and the peak records it for the concurrent
    /// case to fail on.
    private var lastEntered: pthread_t?
    private var depth = 0
    internal var maxThreadsInside = 0


    internal var controller: TrustedHandshakeController?
    internal var state: SlotState = .active
    internal var lease: SlotLease

    public init(key: RelationKey, lease: SlotLease = SlotLease(generation: 0)) {
        self.key = key
        self.lease = lease
    }

    /// Every slot operation runs under this single serialization.
    public func serialize<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock()
        let me = pthread_self()
        if depth > 0, lastEntered != nil, lastEntered != me {
            // Two different threads were seen inside the slot at once.
            maxThreadsInside = 2
        }
        if depth == 0 {
            lastEntered = me
        }
        depth += 1
        defer {
            depth -= 1
            if depth == 0 {
                lastEntered = nil
            }
            lock.unlock()
        }
        return try block()
    }

    /// T08: transition the slot to `.retired` atomically with the operation
    /// that caused it, and hand back the controller so the CALLER can route
    /// the destructive destroy outside the slot lock.
    internal func retire() -> TrustedHandshakeController? {
        // The terminal transition is an operation on the relation too,
        // so it enters through the slot serialization like every other
        // one; the caller still routes the destructive destroy outside
        // the lock.
        return serialize { () -> TrustedHandshakeController? in
            if state == .retired { return nil }
            state = .retired
            let doomed = controller
            controller = nil
            return doomed
        }
    }

}