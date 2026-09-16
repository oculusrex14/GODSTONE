import Foundation

public enum SlotState: Equatable {
    case active
    case retired
    case invalidated
}

/// CRYPTO-001 (T08 completion): the COMPLETE immutable relation identity, and
/// the only key the crypto registry accepteth.
///
/// What the audit refuseth: a registry that resolveth a relation by the platform
/// HANDLE alone. A handle is reused -- a station is replaced while the handle
/// standeth -- so a delayed teardown, a queued ciphertext, a timer or a
/// handshake half spoken against incarnation A would resolve incarnation B and
/// slay it, or route A's work into B's lifetime.
///
/// What this type carrieth, and why each field is load-bearing:
/// - `relation.direction`: an inbound and an outbound relation of ONE platform
///   peer id are TWO relations, not one; a registry which stampeth every
///   relation outbound cannot hold them apart.
/// - `relation.peerId`: the transport's lookup handle -- the only name the
///   platform giveth, and never a node id.
/// - `relation.generation`: THE ORCHESTRATION-OWNED generation of the relation,
///   minted by the link owner when the relation is admitted. The crypto registry
///   mints NONE of its own: an independent counter could alias, and the T08
///   "remembered generation" history existed only to paper over that absence.
/// - `transportEpoch`: the radio epoch the admission belongeth to. A handle and
///   generation can recur across a radio restart; the epoch cannot.
///
/// The pair IS the tree's existing complete identity: the transport minteth both
/// halves at admission and carrieth them through every queued record, timer,
/// delegate and teardown.
public struct RelationAdmission: Hashable, Sendable {
    public let relation: RelationKey
    public let transportEpoch: UInt64

    public init(relation: RelationKey, transportEpoch: UInt64) {
        self.relation = relation
        self.transportEpoch = transportEpoch
    }

    public init(direction: BleDirection, peerId: UUID, generation: UInt64, transportEpoch: UInt64) {
        self.relation = RelationKey(direction: direction, peerId: peerId, generation: generation)
        self.transportEpoch = transportEpoch
    }

    public var direction: BleDirection { relation.direction }
    public var peerId: UUID { relation.peerId }
    public var generation: UInt64 { relation.generation }
}

/// The relation's place in the registry: ONE live incarnation per direction and
/// handle. The admission (generation and epoch) distinguisheth the incarnation.
struct RelationHandle: Hashable, Sendable {
    let direction: BleDirection
    let peerId: UUID

    init(direction: BleDirection, peerId: UUID) {
        self.direction = direction
        self.peerId = peerId
    }
}

extension RelationAdmission {
    var handle: RelationHandle {
        RelationHandle(direction: relation.direction, peerId: relation.peerId)
    }
}

/// CRYPTO-001: the typed answer of a relation's teardown. A teardown addressed
/// to an incarnation which no longer standeth is `.stale` -- the authority
/// REFUSETH it, and the standing replacement is untouched. The distinction is
/// the finding: a drop which cannot be told from a drop of the replacement is
/// not an authority over relations.
public enum RelationRetirement: Equatable, Sendable {
    case retired
    case stale
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
    /// CRYPTO-001: the incarnation this slot standeth for. Immutable for the
    /// slot's whole life: a slot never serveth two incarnations.
    internal let admission: RelationAdmission
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

    /// The relation's orchestration-owned generation: READ from the admission,
    /// never minted here.
    internal var generation: UInt64 { admission.relation.generation }

    public init(admission: RelationAdmission) {
        self.admission = admission
        self.key = admission.relation
    }

    /// Every slot operation runs under this single serialization.
    /// GS-CTRL-002 (R06): the PER-PEER (per-relation) serialisation point, under the name the
    /// composition contract useth. It is not a name added for a gate: `serialize`, and therefore
    /// every handshake operation on this relation, runneth through it.
    internal func getPeerLock() -> NSRecursiveLock { lock }

    public func serialize<T>(_ block: () throws -> T) rethrows -> T {
        getPeerLock().lock()
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
