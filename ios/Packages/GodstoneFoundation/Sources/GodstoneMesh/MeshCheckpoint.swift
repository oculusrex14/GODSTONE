import Foundation

// ================================================================================================
// GS-INTEGRATION-001 `scenarios` (step 6): THE DURABLE-BOUNDARY CHECKPOINT SEAM.
//
// *** THE OBLIGATION THIS FILE EXISTeth TO MAKE POSSIBLE, IN THE CARD'S OWN WORDS: *** *"abrupt child-process
// crash checkpoints"* -- and the measurement discipline that goeth with it: *"Never accept a graceful close or a
// timed sleep as crash proof."* **A PROCESS CAN ONLY BE KILLED AT A BOUNDARY THE PRODUCTION CODE ITSELF NAMES**,
// so those boundaries must be observable from outside the owner without changing what the owner does.
//
// *** WHY A PROCESS-WIDE REGISTRY RATHER THAN A PARAMETER ON EVERY OWNER. *** *The seven boundaries live in five
// different owners (`MeshNode`, `RecipientInboxRepository`, `MessageStore`, `BleTransport`) and in the
// composition that builds them -- and the composition root is the ONE road a host fixture may not re-implement.
// Threading an observer parameter through all of them would mean editing the composition's constructor graph for
// a court's convenience, which is exactly the kind of test-shaped change the card forbids.* **One registry,
// defaulting to NO OBSERVER, is additive by construction: `emit` returneth before it toucheth anything when
// nothing is installed, so every existing arm runs byte-identically.**
//
// *** AND EVERY EMISSION IS PLACED WHERE THE DURABLE FACT IS ALREADY TRUE. *** *The distinction the plan draws is
// load-bearing: `after_delivery_insert` INSIDE `withTransaction` is NOT a durable-commit marker -- the transaction
// may still roll back. **So each `emit` below stands AFTER the owning call RETURNED SUCCESS,** at exactly the
// boundary the crash table names, and never before it. NO TRANSACTION ORDERING IS CHANGED FOR A TEST.*
//
// **WHAT A HOLDER MAY DO WITH AN EVENT: NOTHING THAT AFFECTS PRODUCTION.** *The lab fixture's observer BLOCKS
// (that is the whole point -- the parent SIGKILLs the child at that instant). Nothing in production ever installs
// one: `install(nil)` is the state every shipped graph is in, and `tearDown` restores it.*
// ================================================================================================

/// One named durable boundary the production code has just reached.
internal struct MeshCheckpointEvent: Sendable, Equatable {
    /// One of `MeshCheckpointNames` -- the crash table's own spelling, verbatim.
    let name: String
    /// A non-secret, human-legible qualifier (which sub-site, which holder). NEVER key material or plaintext.
    let detail: String
    /// The transport epoch current at the emission, when the site knoweth one (0 otherwise).
    let epoch: UInt64
    /// A byte count where one is the site's own subject (payload, record, write), 0 otherwise.
    let bytes: Int
}

internal protocol MeshCheckpointObserver: AnyObject, Sendable {
    func checkpoint(_ event: MeshCheckpointEvent)
}

/// *** THE CRASH TABLE'S OWN VOCABULARY, DECLARED ONCE. *** *A marker name spelled differently at a call site than
/// in the harness is a boundary that silently never holds -- which is precisely the "missing marker" failure the
/// assignment nameth as a FAILED scenario. So both sides read these constants and neither carries a literal.*
internal enum MeshCheckpointNames {
    /// After the atomic held+delivery enqueue RETURNED SUCCESS, before the first radio submission.
    static let outboundEnqueue = "outboundEnqueue"
    /// After the recipient held+ACK-obligation transaction returned, before signing.
    static let inboundCommit = "inboundCommit"
    /// After canonical ACK construction/self-verification, before `commitFrameAndRetireObligation`.
    static let ackCreate = "ackCreate"
    /// After `commitFrameAndRetireObligation` returned committed/idempotent, before outbox/wire.
    static let ackCommit = "ackCommit"
    /// After `atomicAcknowledgeAndRetire` committed.
    static let senderAckRetire = "senderAckRetire"
    /// Immediately before a bound writer's external write, after durable acceptance.
    static let preSend = "preSend"
    /// The sealed handshake: `handshakeDetailPreReady` before LinkReady, `handshakeDetailAuthenticated` after
    /// authentication and before the first DATA record.
    static let handshake = "handshake"
    static let handshakeDetailPreReady = "pre-ready"
    static let handshakeDetailAuthenticated = "authenticated"
}

/// The registrar. A plain lock and one slot; `emit`'s fast path is a single uncontended lock acquisition.
internal final class MeshCheckpointRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: (any MeshCheckpointObserver)?

    var current: (any MeshCheckpointObserver)? {
        lock.lock(); defer { lock.unlock() }
        return observer
    }

    func install(_ next: (any MeshCheckpointObserver)?) {
        lock.lock(); observer = next; lock.unlock()
    }
}

internal enum MeshCheckpoint {
    private static let registry = MeshCheckpointRegistry()

    internal static func install(_ observer: (any MeshCheckpointObserver)?) {
        registry.install(observer)
    }

    internal static var installedObserver: (any MeshCheckpointObserver)? { registry.current }

    /// *** THE FAST PATH IS THE PRODUCTION PATH. *** *An uninstalled registry returneth without allocating, without
    /// formatting and without touching a lock twice -- so the emission costs one lock acquisition per durable
    /// boundary and nothing else.* **NO SHIPPED GRAPH, AND NO EXISTING ARM, INSTALLS AN OBSERVER.**
    internal static func emit(_ name: String, detail: String = "", epoch: UInt64 = 0, bytes: Int = 0) {
        guard let observer = registry.current else { return }
        observer.checkpoint(MeshCheckpointEvent(name: name, detail: detail, epoch: epoch, bytes: bytes))
    }
}
