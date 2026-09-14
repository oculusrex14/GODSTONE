import Foundation

// ---------------------------------------------------------------------------
// T42 -- "Wire iOS durable anti-entropy and forwarding": the per-TrustedPeer
// bounded sync pump, on an owned executor. The Swift twin of
// android/mesh/src/main/java/io/godstone/mesh/router/SyncPump.kt.
//
// The card's defect on this isle: iOS carried an OPTIONAL store, so
// `Router.accept` could report a frame accepted on MEMORY ALONE; and it carried a
// forwarding closure that the production receive path never drove. A peer's held
// set therefore never reconciled, and an inbound frame was never forwarded.
//
// The laws are T41's, restated for Swift and enforced here:
//
//   1. FORWARD ONLY AFTER DURABLE ACCEPTANCE. `enqueueForward` is called by the
//      composition AFTER the store committed the frame; the pump never sends
//      anything it was not handed a durably-held frame for.
//   2. TTL AND HOP ARE APPLIED EXACTLY ONCE, to the copy (`ForwardCopy`), built
//      by `Router.forwardCopy`; a retry re-emits those exact bytes.
//   3. NEVER BACK TO receivedFrom.
//   4. TTL 0/1 AND THE HOP CEILING REFUSE BY NAME.
//   5. STRICT PRIORITY BY THE CANONICAL FLAG BITS within bounded admitted work:
//      SOS, DIRECT, GROUP, BROADCAST, BULK -- read from the frame's own priority
//      mask, never from a type table.
//   6. THE SOURCE TOKEN IS CAPTURED BEFORE THE TURN AND REVALIDATED AFTER IT: a
//      relation cancelled mid-turn emits NOTHING.
//   7. THE TURN RUNS ON THE PUMP'S OWN EXECUTOR. Every turn is serialized on a
//      private queue, so no caller's thread (and no platform reducer lock) ever
//      holds the pump's monitor across the store read.
//   8. CANCELLATION RELEASES THE RELATION, NEVER THE DURABLE TRUTH.
//
// Nonshipping: this is the lab mesh path. The shipping LIGHT Archive-only graph
// carrieth no mesh dependency, the readiness flags stay false, and no device
// claim is made here. Host tests prove no CoreBluetooth behaviour.
// ---------------------------------------------------------------------------

/// Bounded forward leg: at most this many copies are offered per turn.
public let syncMaxForwardPerTurn: Int = 32

/// Bound on one peer's pending forward queue (drop-oldest, counted).
public let syncMaxForwardQueue: Int = 256

/// One prepared forward copy. Built ONCE -- TTL decremented and hop incremented
/// exactly once -- and every retry re-emiteth these exact bytes.
public struct ForwardCopy: Equatable, Sendable {
    public let frame: FrameV2
    /// The immediate hop it arrived from, which is never offered it back.
    public let fromPeer: Data?

    public var msgId: Data { frame.msgId }
    public var ttl: UInt8 { frame.ttl }
    public var hopCount: UInt8 { frame.hopCount }
    public var priority: Priority { Priority.fromFlags(frame.flags) }

    public func encoded() -> Data { frame.encode() }
}

/// The typed outcome of offering one durably held frame for forwarding.
public enum ForwardOffer: Equatable, Sendable {
    /// Queued for this many OTHER registered peers (never the one it came from).
    case queued(peers: Int)
    /// Refused by name; nothing was queued anywhere.
    case refused(SyncRefusal)
    /// A type that never travels the message road (control, or a T84 ACK).
    case notForwardable
}

/// Why a leg produced nothing. Named, never a silent no-op.
public enum SyncRefusal: String, Equatable, Sendable {
    case notRegistered = "NOT_REGISTERED"
    case relationLost = "RELATION_LOST"
    case ttlExhausted = "TTL_EXHAUSTED"
    case hopLimit = "HOP_LIMIT"
    case noOtherPeer = "NO_OTHER_PEER"
    case fetchStorageFailure = "FETCH_STORAGE_FAILURE"
}

/// One peer's bounded turn. Every count is an executed observation.
public struct SyncPumpBatch {
    public let peer: Data
    /// The exact frames the link writer should send, in emission order.
    public let frames: [FrameV2]
    /// The forward copies among them, for the witnesses.
    public let copies: [ForwardCopy]
    public let controlFrames: Int
    public let forwarded: Int
    public let refusals: [SyncRefusal: Int]

    public var total: Int { frames.count }
    public var refusedTotal: Int { refusals.values.reduce(0, +) }

    public static func empty(_ peer: Data, _ reason: SyncRefusal) -> SyncPumpBatch {
        SyncPumpBatch(peer: peer, frames: [], copies: [], controlFrames: 0, forwarded: 0,
                      refusals: [reason: 1])
    }
}

/// The per-TrustedPeer bounded sync pump, running every turn on its OWN executor.
public final class SyncPump: @unchecked Sendable {
    /// One peer's scheduling state (never the durable truth).
    public final class SyncRelation: @unchecked Sendable {
        public let peerNodeId: Data
        public var registered: Bool = true
        public var lastTurnMono: Int64 = 0
        public var turns: Int64 = 0
        public var forwardedFrames: Int64 = 0
        public var controlFrames: Int64 = 0
        public var digestsSent: Int64 = 0
        public var lastDigestMono: Int64 = 0

        init(peerNodeId: Data) { self.peerNodeId = Data(peerNodeId) }
    }

    private let owner: SyncControlOwner
    private let store: MessageStore
    private let router: Router
    private let clock: () -> Int64
    /// THE OWNED EXECUTOR: every turn is serialized here.
    private let executor = DispatchQueue(label: "io.godstone.mesh.syncpump", qos: .utility)
    private let lock = NSLock()

    private var registered: [Data: SyncRelation] = [:]
    private var forwardQueues: [Data: [ForwardCopy]] = [:]
    private var overflowed: [Data: Int64] = [:]

    public init(owner: SyncControlOwner, store: MessageStore, router: Router,
                clock: @escaping () -> Int64 = { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }) {
        self.owner = owner
        self.store = store
        self.router = router
        self.clock = clock
    }

    // ---------------------------------------------------------------- scheduling

    /// Register a TrustedPeer's sync relation. Idempotent; true iff this call
    /// created the registration. The peer is a NODE ID: a transport UUID and a
    /// 4-byte hint are neither, and may never key a relation.
    @discardableResult
    public func register(_ peer: Data, now: Int64? = nil) -> Bool {
        guard peer.count == ControlPayloadV1.idBytes else { return false }
        lock.lock(); defer { lock.unlock() }
        if registered[peer] != nil { return false }
        let rel = SyncRelation(peerNodeId: peer)
        rel.lastTurnMono = now ?? clock()
        registered[peer] = rel
        forwardQueues[peer] = []
        _ = owner.relation(for: peer)
        return true
    }

    /// Cancel a relation (relation loss). The run state, the leases and the
    /// peer's queue release; the DURABLE estate is untouched.
    @discardableResult
    public func cancel(_ peer: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let gone = registered.removeValue(forKey: peer) != nil
        forwardQueues.removeValue(forKey: peer)
        overflowed.removeValue(forKey: peer)
        let ownerHad = owner.forgetPeer(peer)
        return gone || ownerHad
    }

    public func isRegistered(_ peer: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return registered[peer] != nil
    }

    public func registeredCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return registered.count
    }

    public func relationFor(_ peer: Data) -> SyncRelation? {
        lock.lock(); defer { lock.unlock() }
        return registered[peer]
    }

    public func registeredPeers() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return Array(registered.keys)
    }

    public func pendingForwardCount(_ peer: Data) -> Int {
        lock.lock(); defer { lock.unlock() }
        return forwardQueues[peer]?.count ?? 0
    }

    public func overflowCount(_ peer: Data) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return overflowed[peer] ?? 0
    }

    // ---------------------------------------------------------------- forwarding

    /// Offer one DURABLY HELD frame for epidemic forwarding.
    public func enqueueForward(_ frame: FrameV2, fromPeer: Data?, now: Int64? = nil) -> ForwardOffer {
        guard frame.type == .message || frame.type == .sos else {
            // control frames are link-local; ACKs travel on their own bounded
            // pump (T84), never on the message road
            return .notForwardable
        }
        if frame.ttl <= 1 { return .refused(.ttlExhausted) }
        if Int(frame.hopCount) + 1 > FrameV2.maxTtl { return .refused(.hopLimit) }
        guard let forwarded = router.forwardCopy(frame) else { return .refused(.hopLimit) }
        let copy = ForwardCopy(frame: forwarded, fromPeer: fromPeer.map { Data($0) })
        lock.lock(); defer { lock.unlock() }
        var queued = 0
        for (key, rel) in registered {
            if !rel.registered { continue }
            if let from = fromPeer, rel.peerNodeId == from { continue }   // never echo
            var queue = forwardQueues[key] ?? []
            while queue.count >= syncMaxForwardQueue {
                queue.removeFirst()
                overflowed[key] = (overflowed[key] ?? 0) + 1
            }
            insertByPriority(&queue, copy)
            forwardQueues[key] = queue
            queued += 1
        }
        return queued == 0 ? .refused(.noOtherPeer) : .queued(peers: queued)
    }

    /// Strict priority insertion: SOS first .. BULK last; FIFO within a rank.
    private func insertByPriority(_ queue: inout [ForwardCopy], _ copy: ForwardCopy) {
        let rank = copy.priority.rawValue
        var index = queue.count
        for (i, existing) in queue.enumerated() where existing.priority.rawValue > rank {
            index = i
            break
        }
        queue.insert(copy, at: index)
    }

    // ---------------------------------------------------------------- the turn

    /// One bounded turn for `peer`, SERIALIZED on the pump's own executor.
    public func turn(peer: Data, now: Int64? = nil) -> SyncPumpBatch {
        executor.sync { self.turnOnExecutor(peer: peer, now: now ?? self.clock()) }
    }

    private func turnOnExecutor(peer: Data, now: Int64) -> SyncPumpBatch {
        lock.lock()
        guard let rel = registered[peer], rel.registered else {
            lock.unlock()
            return SyncPumpBatch.empty(peer, .notRegistered)
        }
        lock.unlock()

        // the source token, captured BEFORE anything is built
        let relation = owner.relation(for: peer)
        let token = relation.generation

        var frames: [FrameV2] = []

        // 1a. the DIGEST leg (section 14: initial encounter and every 5 minutes)
        lock.lock()
        let digestDue = rel.digestsSent == 0 ||
            now - rel.lastDigestMono >= SyncControlOwner.periodicInventoryMs
        lock.unlock()
        if digestDue, let built = owner.buildDigestFrame() {
            frames.append(built.frame)
            lock.lock()
            rel.digestsSent += 1
            rel.lastDigestMono = now
            lock.unlock()
        }

        // 1b. our own run: a due run opens, then the owner's bounded requests
        if owner.shouldScheduleInventory(peer, now: now) {
            _ = owner.startInventoryRun(peer)
        }
        let control = owner.pumpNextInventoryFrames(peer)
        frames.append(contentsOf: control)

        // 2. the forward leg: bounded, strict priority, one copy per frame per
        //    peer per turn. The lock is held only to POP the copies.
        lock.lock()
        var queue = forwardQueues[peer] ?? []
        var popped: [ForwardCopy] = []
        while !queue.isEmpty && popped.count < syncMaxForwardPerTurn {
            popped.append(queue.removeFirst())
        }
        forwardQueues[peer] = queue
        lock.unlock()

        var emitted = Set<Data>(frames.map { $0.msgId })
        var copies: [ForwardCopy] = []
        for copy in popped {
            if emitted.contains(copy.msgId) { continue }
            frames.append(copy.frame)
            copies.append(copy)
            emitted.insert(copy.msgId)
        }

        lock.lock()
        rel.controlFrames += Int64(control.count + (digestDue ? 1 : 0))
        rel.forwardedFrames += Int64(copies.count)
        rel.turns += 1
        rel.lastTurnMono = now
        lock.unlock()

        // 3. revalidate the token: a relation cancelled mid-turn emits NOTHING
        if relation.generation != token {
            return SyncPumpBatch(peer: peer, frames: [], copies: [], controlFrames: 0,
                                 forwarded: 0, refusals: [.relationLost: 1])
        }
        return SyncPumpBatch(peer: peer, frames: frames, copies: copies,
                             controlFrames: control.count, forwarded: copies.count, refusals: [:])
    }
}
