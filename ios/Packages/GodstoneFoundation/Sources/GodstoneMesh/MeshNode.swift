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

/// Typed outcome of a DIRECT outbound send dispatch (C6.6).
public enum DirectDispatchResult: Equatable, Sendable {
    /// Handed to connected relays. State advanced to HANDED_TO_RELAY.
    case handedToRelays(Int)
    /// Persisted and queued locally (0 connected relays). State remains QUEUED_DURABLY.
    case queuedLocally
    /// Atomic enqueue was rejected; 0 sends attempted.
    case rejected(OutboundEnqueueResult)
}

/// One identity, router, radio stack and session registry for the process.
public final class MeshNode {
    public static let linkLayerReady = false
    public static let linkLayerOpenReason =
        "BLE record framing is implemented, but cross-platform link discovery, role binding, trusted handshake integration, and on-device validation remain incomplete. Radio transmission is disabled in this pre-alpha build."

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
    /// in C6.1), and an `Ed25519AckAuthenticator` (backed by `BoundRecipientKeyResolver`
    /// in the non-shipping `MeshRuntime` graph, while in the shipping `LIGHT` target Mesh
    /// is completely absent) rejects every unverified ACK (fail-closed). The outbound
    /// path (C6) records the ACK mode (SOS is a broadcast -> `AckMode.none`, no
    /// recipient binding; a directed message is `AckMode.singleRecipient`) +
    /// advances state on a successful relay hand-off; the inbound ACK path (C7)
    /// binds the ACK to the durable expected recipient (authenticator invoked
    /// ONLY for singleRecipient -- a none-mode message can never be
    /// acknowledged). No delivery is claimed on host-only evidence --
    /// A-03 / ADR-005 stay OPEN. Mirrors Android `MeshNode.deliveryTracker`.
    public let deliveryTracker: DeliveryTracker
    public private(set) lazy var ble = BleTransport()
    public let router: Router
    public let sessions: SessionManager
    /// The wipe admission seam, or nil for a node that was not wired to one. **Kept, not merely forwarded**, because
    /// this node's OWN SOS read roads consult it (round 638).
    private let wipeGate: (any WipeSensitiveUseGate)?

    /// T37 (section 14): the recipient inbox transaction of the authenticated
    /// link -- injectable and absent by default, so the relay/ACK-ingest
    /// behaviour of every existing composition is preserved byte-for-byte.
    /// When set, a sealed DIRECT MESSAGE additionally gets the local
    /// destination attempt; its typed outcome never alters the relay decision
    /// in `ingestInbound` (the router remains the relay truth), and an
    /// accepted delivery's canonical recipient ACK is queued on the bounded
    /// outbox for the trusted link's writer (the physical pump is T54/T73-T75
    /// territory; the production wiring point is the lab composition root).
    internal var recipientInbox: RecipientInboxRepository?
    /// GS-RUNTIME-001 step 3: **THE BOUNDED ACK WORKER'S SCHEDULE.** The node is the transport's delegate, so the
    /// readiness arriveth HERE; it must therefore be the node that telleth the pump -- otherwise "registering a
    /// queue does not send it", which is this finding's own sentence. Set by the owning runtime.
    internal var ackPump: DurableAckPump?
    /// GS-RUNTIME-001 step 4: **THE RELATION'S OWN MAPPING.** The pump is keyed by NODE ID (the authenticated
    /// identity) and the transport is keyed by the HANDLE; nothing in production held both, so a batch could not
    /// be handed anywhere. It is written at the trusted event and forgotten at the farewell -- the same two
    /// moments the route-eligible view is written and forgotten.
    /// **THE RELATION, AS THE NODE CAPTURED IT: its handle AND ITS GENERATION.** The handle alone cannot tell a
    /// replacement relation from the one the work was admitted under -- and a frame handed to the wrong hour is
    /// exactly the misrouting this programme hunteth.
    private struct AckRelationBinding { let handle: UUID; let generation: UInt64 }
    private var relationForNodeId: [Data: AckRelationBinding] = [:]
    private var handleForNodeId: [Data: UUID] = [:]
    /// GS-RUNTIME-001 step 4: **THE MONOTONIC PERIODIC DEADLINE, OWNED.** The worker must be WOKEN for the
    /// periodic turn; until this landed nothing woke it but the trusted event itself. The deadline is armed
    /// ONLY from the trusted readiness and CANCELLED with the node, so it can never outlive the runtime that
    /// owneth it -- the same law IOS-07's deadline sweep followeth on the transport.
    private var ackTurnSource: DispatchSourceTimer?
    private let ackTurnQueue = DispatchQueue(label: "io.godstone.mesh.ackturn")
    private var ackTurnsRun = 0
    internal func ackTurnsRunForTest() -> Int { ackTurnsRun }
    /// GS-RUNTIME-001 step 4: the EVENT wakes (readiness, inbound request), counted apart from the DEADLINE's
    /// turns so that a witness can tell which wake it is judging.
    private var ackEventWakes = 0
    internal func ackEventWakesForTest() -> Int { ackEventWakes }

    /// T42: the per-TrustedPeer bounded sync pump and the typed dispatcher. Both
    /// are ACTIVE by default (the default pump is built lazily from this node's
    /// own owner, store and router); the seams exist so a court may inject its
    /// own, exactly as the T84 dispatcher seam doth.
    internal var syncPumpOverride: SyncPump?
    private lazy var defaultSyncPump: SyncPump = SyncPump(
        owner: syncControlOwner, store: store, router: router,
        clock: { [clock = self.controlClock] in clock() })
    internal func pumpFor() -> SyncPump { syncPumpOverride ?? defaultSyncPump }

    private lazy var frameDispatcher: FrameDispatcher = FrameDispatcher(
        owner: syncControlOwner,
        ackAuthority: { [weak self] in self?.ackDispatcher },
        acknowledgeHistorically: { [weak self] frame in
            guard let self else { return .unknownMessage }
            return self.deliveryTracker.acknowledge(frame.msgId, frame)
        })

    /// T42: the typed dispatch statute, as the courts observe it.
    internal func dispatcherForTest() -> FrameDispatcher { frameDispatcher }

    /// T43: the EPHEMERAL ledger of local link admissions. A Boolean `send`
    /// provecth only that a radio accepted some bytes -- never that a relay
    /// holdeth them and never that a recipient received them -- so it is recorded
    /// HERE, in memory, and the durable delivery row is left alone. A restart
    /// forgetteth every offer, which is why no custody label may rest on one.
    internal let linkOffers = LinkOfferLedger()

    /// The link's identity bytes: the transport's UUID, verbatim. It is NOT a
    /// node id and NOT a recipient -- it only sayeth WHERE bytes were offered.
    internal static func linkBytes(_ peerId: UUID) -> Data {
        withUnsafeBytes(of: peerId.uuid) { Data($0) }
    }

    /// T43: the honest label a consumer may read for `msgId`.
    internal func deliveryProjection(_ msgId: Data) -> DeliveryProjection {
        // *** GS-FINAL-003 (round 699): THE DELIVERY READ ROAD IS GATED, THE SAME REPAIR AS `activeSosSnapshot`.
        // ***
        //
        // **MEASURED BY SWEEPING EVERY FUNCTION THAT TOUCHETH `store`/`deliveryTracker`, ON BOTH ISLES:** `retrySos`,
        // `activeSosSnapshot` and `cancelSos` were gated in rounds 633/638; **THIS ONE WAS NOT, AND IT READETH A
        // DELIVERY ROW.** *The identical gap existed on Android (`MeshNode.deliveryProjection`), and the two isles
        // were repaired together so a reader of either findeth the same law.*
        //
        // **GATED REGARDLESS OF REACH** (*measured: courts only today*), *because a read road that reporteth delivery
        // state from a store being erased is a claim that looks like a state* -- the same reason the ACK census
        // answereth 0 and the SOS projection answereth `nil`. **And the refusal reuseth the type's OWN vocabulary:
        // `unavailable`, which the body already returned for a corrupt or unreadable row** -- *no invented error, and
        // no plausible-looking empty answer.*
        if let gate = wipeGate, !gate.allowsSensitiveUse() { return DeliveryProjection.unavailable(msgId) }
        switch deliveryTracker.lookup(msgId) {
        case .found(let record):
            return DeliveryProjection.of(msgId, state: record.state,
                                         linkOffers: linkOffers.admittedCountFor(msgId),
                                         refusedOffers: linkOffers.refusedCountFor(msgId),
                                         lastOfferMonoMillis: linkOffers.lastOfferMonoFor(msgId))
        default:
            // a corrupt or unreadable row is never labelled queued (fail closed)
            return DeliveryProjection.unavailable(msgId)
        }
    }

    /// T42: a TRUSTED relation came up for `nodeId` (a 16-octet NODE id -- never
    /// the transport's UUID and never the 4-byte hint). The sync pump is
    /// scheduled here, and the DIGEST becomes due at once.
    @discardableResult
    internal func trustedPeerDidConnect(nodeId: Data, peerId: UUID? = nil, generation: UInt64? = nil) -> Bool {
        if let peerId, let generation { relationForNodeId[nodeId] = AckRelationBinding(handle: peerId, generation: generation) }
        if let peerId { handleForNodeId[nodeId] = peerId }
        // IOS-02 step 5: THE TRUSTED EVENT IS WHAT ADMITTETH A PEER TO THE ROUTE. The handle is optional
        // so that every existing caller (whose business is the SYNC PUMP alone) keepeth its meaning: a
        // caller with a handle to hand getteth route eligibility WITH the trust that just came up.
        if let peerId {
            peerLock.lock(); peers.insert(peerId); peerLock.unlock()
        }
        return pumpFor().register(nodeId)
    }

    /// T42: the trusted relation went away. The run state, the leases and the
    /// peer's queue release; the DURABLE estate is untouched, so a reconnect
    /// resumes.
    @discardableResult
    internal func trustedPeerDidDisconnect(nodeId: Data, peerId: UUID? = nil) -> Bool {
        handleForNodeId.removeValue(forKey: nodeId)
        relationForNodeId.removeValue(forKey: nodeId)
        if let peerId {
            peerLock.lock(); peers.remove(peerId); peerLock.unlock()
        }
        return trustedFarewell(nodeId)
    }

    private func trustedFarewell(_ nodeId: Data) -> Bool {
        // GS-SYNC-002 step 3: the RELATION is gone, so its epoch is retired with it and every answer it
        // queued becomes stale by construction rather than inheritable by the next relation. One law with
        // the Android isle's `retireRelationEpoch` on `PeerEvent.Lost`.
        // (The explicit `return` is required now that this body has two statements: the single-expression
        // implicit return the original relied on is gone.)
        retireRelationEpoch(nodeId)
        // GS-RUNTIME-001 step 3: **ON LinkLost THE PEER STOPPETH BEING ELIGIBLE -- THAT EXACT NODE, not another.**
        ackPump?.onLinkGone(nodeId)
        return pumpFor().cancel(nodeId)
    }

    /// T42: one bounded sync/forward turn for `nodeId` -- the link writer's
    /// source. The owner's control answers ride the control outbox T40 built; the
    /// pump addeth the schedule and the epidemic forward copies. ONE call, so no
    /// caller has to remember two sources.
    internal func drainSyncFrames(for nodeId: Data) -> [FrameV2] {
        var out = drainControlOutbox(for: nodeId)
        out.append(contentsOf: pumpFor().turn(peer: nodeId).frames)
        return out
    }

    /// T84 (section 14, the durable ACK return path): the ACK dispatcher. Bound
    /// by the composition that OWNETH the ack_frames namespace -- the same
    /// authority that binds `recipientInbox` -- and absent by default, so the
    /// historical point-to-point face below standeth byte-for-byte for every
    /// composition that carrieth no such namespace.
    ///
    /// With it bound, an inbound ACK is classified BEFORE any generic message
    /// TTL/dedup/store handling: a durable delivery row maketh it ORIGIN
    /// verification (the only road to DELIVERED), and the ABSENCE of one maketh
    /// it RELAY TRAFFIC to be carried home, rather than the UnknownMessage
    /// discard that loseth every multihop receipt. Mirrors Android
    /// `MeshNode.ackDispatcher`.
    internal var ackDispatcher: AckDispatcher?

    /// T38 (section 15): the signed-SOS authority seam. Absent by default --
    /// dispatch then keeps the legacy structural shape (documented, refused
    /// by the receiver's runtime authentication exactly as section 15 demands;
    /// byte-parity with the android legacy arm). The T54 lab composition root
    /// binds this to the durable identity.
    internal var sosAuthority: SosSigningAuthority?
    /// T38: consumers of authenticated distress indications only. An
    /// unauthenticated frame never reaches an observer; no trust or approval
    /// state moves on this path (the peer directory's own layer).
    internal var sosObserver: SosObserver?

    // T40 (ADR-009): the per-relation sync/control owner and its snapshot
    // authority. Internal and settable so the readiness court can drive the
    // pump with an injected monotonic clock; the production default reads the
    // system clock. The owner consumes the link controls at the ingress
    // demultiplex and nothing else does; T41 wires the outbound pump onto
    // this same instance.
    /// *** GS-FINAL-005 (round 709): THIS PROPERTY WAS WALL TIME WEARING A MONOTONIC NAME. ***
    ///
    /// **THE AUDIT: "InventorySnapshotAuthority and SyncControlOwner receive Date-based closures named
    /// monotonicNowMillis."** *Measured, the wall reading did not stop at those two: THIS property was the ROOT, and
    /// `defaultSyncPump` (:106), the SOS dispatch paths (:843, :943) and both control-plane seams all read through it.*
    /// **A user-set clock, an NTP step or a correction could move every one of them, and `atMonoMillis` and
    /// `lastPingSentMono` would carry the lie into comparisons that assume it cannot be set.**
    ///
    /// **AND THE OTHER ISLE ALREADY HAD IT RIGHT -- MEASURED, NOT ASSUMED: Android's `MeshNode.controlClock` readeth
    /// `System.nanoTime() / 1_000_000L`**, *which cannot be set.* This is therefore parity with a correct twin rather
    /// than a new invention. **The source is the repository's own monotonic sample**, so the two notions of "now" in
    /// this node cannot drift apart.
    ///
    /// *I FIRST REPAIRED THIS WITH A LOCAL `let` INSIDE `init`, AND MEASURED THAT IT SHADOWED THE ROOT -- the four
    /// OTHER readers above would have kept the wall clock while the two named in the audit went clean. **A repair that
    /// fixes the named sites and leaves the root is a repair that moves the defect, not one that removes it.***
    internal var controlClock: () -> Int64 = { DefaultRetentionClock.sample().monoMs }
    internal var snapshotAuthority: InventorySnapshotAuthority!
    internal var syncControlOwner: SyncControlOwner!

    /// The owner's last decision -- the observation face of the courts.
    internal var lastControlDecision: SyncControlOwner.OwnerDecision = .accepted

    /// GS-SYNC-002: a control reply with the DESTINATION it belongs to. The outbox used to hold BARE
    /// frames, so an answer raised for one relation was handed to whichever peer asked first -- the
    /// requesting peer went unanswered and two reconciliation runs were mixed.
    private struct ControlReply {
        let destination: Data
        let frame: FrameV2
        /// GS-SYNC-002 step 3: the RELATION this answer was raised for. A relation that was RETIRED (the
        /// peer was lost) has its epoch retired with it, so the answer cannot be handed to the relation that
        /// REPLACED it when the same peer returns. One law with the Android isle.
        let relationEpoch: UInt64
    }

    /// GS-SYNC-002 (the audit's ordered step 3): per-peer RELATION epochs. An epoch is created when a peer's
    /// relation is first spoken of and RETIRED when the relation is lost, so a reconnect produces a DIFFERENT
    /// epoch and every answer raised under the old one is stale by construction. A peer that never had a
    /// relation event keeps one epoch for the life of the node, so nothing else can be affected.
    private var relationEpochs: [Data: UInt64] = [:]
    private var relationEpochSeq: UInt64 = 0
    private let relationEpochLock = NSLock()

    private func currentRelationEpoch(_ peerId: Data) -> UInt64 {
        relationEpochLock.lock(); defer { relationEpochLock.unlock() }
        if let known = relationEpochs[peerId] { return known }
        relationEpochSeq += 1
        relationEpochs[peerId] = relationEpochSeq
        return relationEpochSeq
    }

    /// GS-SYNC-002 step 3: a LOST relation retires its epoch, so its queued answers are stale from here.
    private func retireRelationEpoch(_ peerId: Data) {
        relationEpochLock.lock(); defer { relationEpochLock.unlock() }
        relationEpochs.removeValue(forKey: peerId)
    }

    /// GS-SYNC-002 step 4: the PER-DESTINATION bound beside the aggregate 64 (fairness/telemetry, not
    /// memory: the aggregate cap bounds memory and drop-oldest already prevents admission starvation).
    internal static let maxControlRepliesPerDestination: Int = 16

    private var controlOutbox: [ControlReply] = []

    /// GS-SOS-002: the per-message DISPATCH LEASE. Minted where an offer loop begins, INVALIDATED by a
    /// successful cancellation (which retires the durable row), and RE-CHECKED BEFORE EVERY OFFER -- so
    /// captured local work cannot be newly offered after its row was retired.
    private var dispatchLeases: [Data: UInt64] = [:]
    private var dispatchLeaseSeq: UInt64 = 0
    private let dispatchLeaseLock = NSLock()

    private func mintDispatchLease(_ msgId: Data) -> UInt64 {
        dispatchLeaseLock.lock(); defer { dispatchLeaseLock.unlock() }
        dispatchLeaseSeq += 1
        dispatchLeases[msgId] = dispatchLeaseSeq
        return dispatchLeaseSeq
    }

    /// GS-SOS-002: the lease stands only while NO successful cancellation hath retired the message.
    private func dispatchLeaseStands(_ msgId: Data, _ lease: UInt64) -> Bool {
        dispatchLeaseLock.lock(); defer { dispatchLeaseLock.unlock() }
        return dispatchLeases[msgId] == lease
    }

    /// GS-SOS-002: a SUCCESSFUL cancellation invalidateth the message's dispatch lease.
    ///
    /// GS-SOS-002 (the audit's step-2 DURABLE half): the message must still be DISPATCHABLE by DURABLE
    /// TRUTH -- so a cancellation committed by ANY path suppresseth the offers not yet made. PRESENCE IS
    /// NOT ENOUGH: a terminal CAS KEEPS the row, so the STATE is what is tested. Absent, corrupt, invalid
    /// or unreadable stops the loop: fail-closed, never a skip.
    private func sosStillDispatchableByDurableTruth(_ msgId: Data) -> Bool {
        switch deliveryTracker.lookup(msgId) {
        case .found(let row): return !row.state.isTerminal
        default: return false
        }
    }

    private func invalidateDispatchLease(_ msgId: Data) {
        dispatchLeaseLock.lock(); defer { dispatchLeaseLock.unlock() }
        dispatchLeases.removeValue(forKey: msgId)
    }
    private let controlOutboxLock = NSLock()

    /// Bounded at 64; drop-oldest, the freshest truth wins the slot (the house outbox idiom).
    private func offerControlFrames(_ frames: [FrameV2], destination: Data) {
        controlOutboxLock.lock(); defer { controlOutboxLock.unlock() }
        // GS-SYNC-002 step 3: the answer is stamped with the RELATION it belongs to.
        let epoch = currentRelationEpoch(destination)
        for f in frames {
            // GS-SYNC-002 step 4: the AGGREGATE bound, unchanged, and the PER-DESTINATION bound BESIDE it,
            // so no single destination can hold the whole budget. Drop-oldest in both (the T37 idiom).
            if controlOutbox.count >= 64 { controlOutbox.removeFirst() }
            if controlOutbox.filter({ $0.destination == destination }).count
                >= Self.maxControlRepliesPerDestination,
               let oldestMine = controlOutbox.firstIndex(where: { $0.destination == destination }) {
                controlOutbox.remove(at: oldestMine)
            }
            controlOutbox.append(ControlReply(destination: destination, frame: f, relationEpoch: epoch))
        }
    }

    /// Drain the bounded control outbox (T41's pump takes the route from here). GS-SYNC-002 step 3: an
    /// entry whose relation was retired while it waited is DROPPED, not delivered.
    internal func drainControlOutbox() -> [FrameV2] {
        controlOutboxLock.lock(); defer { controlOutboxLock.unlock() }
        let out = controlOutbox
            .filter { $0.relationEpoch == currentRelationEpoch($0.destination) }
            .map { $0.frame }
        controlOutbox.removeAll()
        return out
    }

    /// GS-SYNC-002: drain ONLY the replies that belong to `peer`; every other live peer's answer is
    /// PRESERVED. Ownership is by destination, so one peer's turn can never consume another's answer.
    ///
    /// GS-SYNC-002 step 3: ownership is by destination AND RELATION. An answer raised under a RETIRED
    /// relation is dropped here, never handed to the replacement relation -- refuse and forget, because a
    /// stale reply is not work for the new relation. One law with the Android isle.
    private func drainControlOutbox(for peer: Data) -> [FrameV2] {
        controlOutboxLock.lock(); defer { controlOutboxLock.unlock() }
        let current = currentRelationEpoch(peer)
        let mine = controlOutbox.filter { $0.destination == peer }
        if !mine.isEmpty { controlOutbox.removeAll { $0.destination == peer } }
        return mine.filter { $0.relationEpoch == current }.map { $0.frame }
    }

    /// One ingress control frame: the owner decides; any answer rides back out.
    /// T42: the decision cometh back through the typed dispatch statute, so the
    /// order is the same one `ingestInbound` walketh.
    internal func handleControlFrame(_ frame: FrameV2, fromPeer: Data) -> Bool {
        let verdict = frameDispatcher.dispatch(frame, from: fromPeer)
        guard case .control(let decision, let accepted) = verdict else { return false }
        lastControlDecision = decision
        let replies = frameDispatcher.replies(decision)
        if !replies.isEmpty { offerControlFrames(replies, destination: fromPeer) }
        return accepted
    }

    /// T39: the remembered Active-SOS projection of the one durable authority
    /// (section 14). The observable mirror `hasActiveSosBroadcast` is only ever
    /// re-published FROM this projection or a fresh scan of the tables -- it is
    /// no longer a token a stray call can spend.
    private let sosRowLock = NSLock()
    private var sosRowMemory: ActiveSos?
    private let ackOutboxLock = NSLock()
    private var ackOutbox: [FrameV2] = []

    /// T37: the bounded runtime outbox of canonical recipient ACKs awaiting
    /// the link. Runtime scheduling only -- the durable truth of a recipient
    /// ACK is the ack_frames row filed inside the repository's pair step.
    /// Drop-oldest keeps the bound honest under flood: the freshest canonical
    /// answer wins the single slot, the elder is superseded by the durable
    /// row's re-read path.
    internal static let maxOutboundAcks = 64

    /// Queue one canonical recipient ACK for the trusted link's writer.
    @discardableResult
    internal func offerAckForLink(_ ack: FrameV2) -> Bool {
        ackOutboxLock.lock()
        while ackOutbox.count >= Self.maxOutboundAcks { ackOutbox.removeFirst() }
        ackOutbox.append(ack)
        ackOutboxLock.unlock()
        return true
    }

    /// Drain up to `max` queued ACKs for the link writer (the T54 lab pump seam).
    internal func drainAckOutboxForLink(_ max: Int) -> [FrameV2] {
        var out: [FrameV2] = []
        ackOutboxLock.lock()
        var n = 0
        while n < max && !ackOutbox.isEmpty {
            out.append(ackOutbox.removeFirst())
            n += 1
        }
        ackOutboxLock.unlock()
        return out
    }

    /// Outbox depth for witnesses -- telemetry only, never authority.
    internal func ackOutboxDepthForTest() -> Int {
        ackOutboxLock.lock()
        let d = ackOutbox.count
        ackOutboxLock.unlock()
        return d
    }

    /// **THE ROUTE-ELIGIBLE VIEW.** This set is what `currentPeers()` giveth the send paths
    /// (`ble.send(frame, to:)`), so a peer entereth it ONLY upon the TRUSTED event -- the matching key
    /// confirmation -- and never upon the radio's mere presence (IOS-02 step 5).
    private var peers: Set<UUID> = []
    /// THE PHYSICAL PRESENCE VIEW: the handles the radio carrieth. Presence is NOT eligibility, and this
    /// set feedeth the count alone.
    private var presentPeers: Set<UUID> = []
    private let peerLock = NSLock()
    public var onPeerCountChanged: ((Int) -> Void)?
    private var isStarted = false

    /// Production initializer: a node owns its durable store, durable delivery tracker, and trusted SessionManager.
    /// *** GS-FINAL-003 (round 636): THE NODE CAN NOW HAND ITS ROUTER A WIPE ADMISSION SEAM. ***
    ///
    /// **MEASURED THIS ROUND: THIS INITIALISER BUILT `Router(selfNodeId:store:)` WITH NO GATE, AND `Router.accept`
    /// WRITETH THE HELD ROW THROUGH `store.persist` -- SO ON iOS A PENDING WIPE DID NOT REFUSE THE INBOUND WRITE ROAD.
    /// ANDROID CLOSED EXACTLY THIS IN ROUND 574** (*"`Router.ingest` called `store.persist` directly -- the method
    /// that writes the held row -- with NOTHING on that road"*), **AND ITS OWN NOTE RECORDED THAT "the iOS `Router`
    /// twin was NOT re-done this round." THIS IS THAT TWIN.**
    ///
    /// OPTIONAL AND DEFAULTED TO NIL, so all existing call sites are unchanged and `nil` means NO GATE -- the road
    /// exactly as it was -- rather than a silent always-allow. **A CALLER THAT HAS A GATE PASSES ONE.**
    public init(identity: MeshIdentity, store: MessageStore,
                deliveryTracker: DeliveryTracker, sessions: SessionManager,
                wipeGate: (any WipeSensitiveUseGate)? = nil) {
        self.identity = identity
        self.store = store
        self.deliveryTracker = deliveryTracker
        self.sessions = sessions
        // T42: the store is REQUIRED at construction -- a router without one
        // could report a frame accepted on memory alone.
        self.router = Router(selfNodeId: identity.nodeId, store: store, wipeGate: wipeGate)
        // *** GS-FINAL-003 (round 638): THE NODE KEEPETH THE GATE SO ITS OWN READ ROADS CAN CONSULT IT. *** Round 636
        // threaded the gate to the `Router` and DROPPED IT. **BUT `MeshNode` HAS TWO SOS READ ROADS OF ITS OWN --
        // `retrySos` AND `activeSosSnapshot` -- WHICH READ THE HELD FRAMES OUT OF THE STORE, AND ROUND 633 MEASURED ON
        // THE OTHER ISLE THAT *THOSE* WERE THE UNGATED ONES.** *A gate passed to a collaborator and not kept is a gate
        // this object cannot consult.*
        self.wipeGate = wipeGate
        self.ble.store = store
        self.ble.identity = identity
        // *** GS-FINAL-005 (round 709): THE PARAMETER SAYS `monotonic` AND IT NOW REALLY IS. ***
        //
        // **THE AUDIT'S OWN OBSERVATION, VERBATIM: "InventorySnapshotAuthority and SyncControlOwner receive Date-based
        // closures named monotonicNowMillis."** *Measured at this line: both were handed
        // `Date().timeIntervalSince1970 * 1000` -- WALL time, passed to a parameter whose NAME promiseth a monotonic
        // reading.* **A user-set clock, an NTP step or a correction can move it, and every deadline and budget computed
        // from it moves with the lie.**
        //
        // **AND THE OTHER ISLE ALREADY HAD THIS RIGHT -- MEASURED, NOT ASSUMED: Android's `MeshNode.controlClock`
        // readeth `System.nanoTime() / 1_000_000L`**, *which cannot be set.* **So this is parity with a correct twin
        // rather than a new invention.**
        //
        // *Both seams read the node's OWN clock (fixed at the property above), so the control plane and the pump cannot
        // disagree about what "monotonic" means on this isle.*
        self.snapshotAuthority = InventorySnapshotAuthority(store: store, monotonicNowMillis: { self.controlClock() })
        self.syncControlOwner = SyncControlOwner(store: store, authority: snapshotAuthority,
                                                  monotonicNowMillis: { self.controlClock() },
                                                  localNodeId: identity.nodeId)
    }

    internal func canStart(linkReady: Bool) -> Bool {
        return linkReady && sessions.isActive
    }

    @discardableResult
    public func start() -> Bool {
        guard canStart(linkReady: Self.linkLayerReady) else { return false }
        guard !isStarted else { return true }
        isStarted = true
        // T24 (section 6, "observers/flow emissions can ... lose authoritative
        // events"): the authoritative consumers (the transport delegate that
        // receiveth connect / ready / receive / disconnect, and the router's
        // forward fan-out) are install'd BEFORE the radio adapter is open'd, so
        // no event the link emiteth in the instant it waketh is lost in a window
        // between open and subscribe. The order is fixed by construction via the
        // selfsame startInOrder decision point the witnesses funnel through.
        startInOrder(
            attach: { [weak self] in self?.attachConsumers() },
            open: { [weak self] in self?.openAdapters() }
        )
        return true
    }

    /// Fix the start ordering by construction: register the consumers first,
    /// only then open the adapter. Both production `start()` and its witnesses
    /// funnel through this single decision point, so the consume-before-open
    /// law holdeth wherever it is observ'd (section 6; T24).
    internal func startInOrder(attach: () -> Void, open: () -> Void) {
        attach()
        open()
    }

    /// Install the transport delegate (the peer-presence / inbound consumers) and
    /// the router's forward fan-out, ere the adapter is open'd. Extracted
    /// verbatim from the former `start()` body (behaviour preserved).
    private func attachConsumers() {
        ble.delegate = self
        ble.sessions = sessions
        ble.identity = identity
        ble.store = store
        router.onForward = { [weak self] frame in
            guard let self else { return }
            for peer in self.currentPeers() { _ = self.ble.send(frame, to: peer) }
        }
    }

    /// IOS-06 step 1's second half: **ONE RUNTIME OWNER FOR LIFECYCLE.** When the runtime hath given this node an
    /// authority (it doth, over this node's own transport), THE RADIO IS OPENED *THROUGH* IT; the direct road
    /// standeth ONLY for rigs that own no authority, WHICH IS WHAT MAKETH THIS CHANGE ADDITIVE -- every existing
    /// court keepeth working while the production graph loseth its second, unowned path to the radio.
    internal var lifecycleOwner: UnifiedRuntimeLifecycle?

    /// **IOS-06 step 1's routing, MADE OBSERVABLE**: which road the node took is a fact about the graph, and a
    /// witness that cannot see it is a witness of the source text only. These two censuses turn the routing into
    /// something a court can MEASURE -- the same idiom this session useth for every owned worker.
    internal private(set) var adaptersOpenedThroughTheOwner = 0
    internal private(set) var adaptersClosedThroughTheOwner = 0
    private var adaptersClosed = false

    /// **IOS-06 step 3: A POWER LOSS OR A WITHDRAWN PERMISSION REACHETH THE ONE AUTHORITY.** The platform speaketh
    /// through the transport; the authority is the only thing that may act on it -- and a HEALTHY STATE IS NOT AN
    /// EVENT, which the arm requireth.
    internal private(set) var lifecycleEventsForwarded = 0

    internal func handleTransportPowerState(_ state: TransportPowerState) {
        guard let lifecycleOwner else { return }
        switch state {
        case .poweredOff: lifecycleOwner.onPowerLoss()
        case .permissionRevoked: lifecycleOwner.onPermissionRemoved()
        case .ready, .other: return
        }
        lifecycleEventsForwarded += 1
    }

    /// Open the radio adapter, once its consumers are already install'd.
    /// *** GS-FINAL-010: THE OPEN ROAD IS THE SEAM THE LATCH BELONGETH TO, SO IT IS TESTABLE BY NAME. ***
    ///
    /// IT WAS `private`, AND THAT IS WHY THE FIRST DRAFT OF THIS FINDING'S ARM COULD NOT SEE THE DEFECT: the arm
    /// called `startInOrder(attach:open:)` with its own closures, so `adaptersOpenedThroughTheOwner` never moved and
    /// the latch was never exercised. **AN ARM THAT CANNOT REACH THE LOAD-BEARING LINE MEASURES ITS OWN RIG.** The
    /// production `start()` funnels here through `startInOrder`, so making this `internal` changes no behaviour and
    /// lets the arm drive the REAL road.
    internal func openAdapters() {
        ble.onCentralStateChanged = { [weak self] state in
            self?.handleTransportPowerState(state)
        }
        // *** GS-FINAL-010 (the independent audit, 2026-09-18): A NEW ACTIVATION RE-ARMS THE CLOSE. ***
        //
        // THE AUDIT'S MEASUREMENT: *"MeshNode.stop sets adaptersClosed once. The inspected start/open paths never
        // reset it. ... Root cause: A lifetime-wide Boolean is used where restartable epoch state appears to be
        // required."* MEASURED BEFORE THIS EDIT: activate -> stop -> activate -> stop left `adapterCloses` at 1 while
        // **TWO** adverts had been started -- so the second stop closed NOTHING and the process kept the radio
        // running for a runtime it had torn down.
        //
        // THE LATCH'S ORIGINAL PURPOSE IS PRESERVED EXACTLY: it exists so that a stop which closes NOTHING (a second
        // stop with no activation between) does not count as a second teardown. What was wrong is that it was
        // LIFETIME-WIDE rather than PER-ACTIVATION. Re-arming it here keeps every closed-before-open and
        // double-close guarantee the existing courts measure (a stop with no intervening open still closeth once,
        // because this line never runs) while letting a genuinely NEW activation be closed by its own stop.
        //
        // AND IT IS RE-ARMED ONLY WHERE AN OPEN HAPPENS, ON THE OWNER ROAD, AFTER THE OWNER AGREED: `lifecycle.start()`
        // refuseth on a terminal capability, so a power loss cannot be undone by this line -- the terminal-owner arm
        // measures that.
        if let lifecycleOwner {
            adaptersOpenedThroughTheOwner += 1
            let wasStarted = lifecycleOwner.isStarted()
            lifecycleOwner.start()
            // ONLY AN ACTIVATION THAT REALLY TOOK RE-ARMS THE CLOSE. A terminal owner refuseth `start()`, and then
            // no radio stands to close, so the latch must stay as it was.
            if !wasStarted && lifecycleOwner.isStarted() {
                adaptersClosed = false
            }
        } else {
            ble.start()
            adaptersClosed = false
        }
    }

    public func stop() {
        // GS-RUNTIME-001 step 4: **THE DEADLINE IS CANCELLED *BEFORE* THE `isStarted` GUARD.** A deadline armed
        // by the runtime must not outlive it EVEN WHEN THE NODE WAS NEVER STARTED -- and in this shipping tree
        // `isStarted` is FALSE by construction (the link-layer flag is frozen off), so a cancel placed after the
        // guard would leak a live timer for ever. THE WITNESS TAUGHT THIS: it watched the census climb from 2 to
        // 7 AFTER `stop()`, which is a callback firing for a runtime that is gone.
        cancelAckTurnDeadline()
        handleNodeMappingsForget()
        // **IOS-06's OWN WITNESS FOUND THIS (round 244), AND IT IS THE SAME EARLY-RETURN CLASS AS ROUND 220's TIMER
        // LEAK: THE CLOSE ROAD SAT *AFTER* THE `isStarted` GUARD -- AND IN THIS SHIPPING TREE `isStarted` IS FALSE BY
        // CONSTRUCTION, SO THE RADIO WAS NEVER CLOSED THROUGH THE ONE OWNER AT ALL; the guard returned first, and the
        // census the new arm reads stayed at zero.** The close now standeth BEFORE the guard, ONCE PER LIFETIME (the
        // transport's own `stop` is idempotent, but a second drain must not be counted as a second close).
        if !adaptersClosed {
            adaptersClosed = true
            if let lifecycleOwner {
                adaptersClosedThroughTheOwner += 1
                lifecycleOwner.stop()
            } else {
                ble.stop()
            }
        }
        guard isStarted else { return }
        isStarted = false
        sessions.destroyAll()
        peerLock.lock(); peers.removeAll(); peerLock.unlock()
        onPeerCountChanged?(0)
    }

    /// GS-RUNTIME-001 step 4: the relation mapping is forgotten on BOTH roads (the early return and the full
    /// stop), so no elder relation surviveth a stop in the mapping even when the node was never started.
    private func handleNodeMappingsForget() { handleForNodeId.removeAll(); relationForNodeId.removeAll() }

    private func currentPeers() -> [UUID] {
        peerLock.lock(); defer { peerLock.unlock() }
        return Array(peers)
    }

    /// Apply one peer-connect event to the PRESENCE view, under the peer lock, and report the resulting
    /// count. **IOS-02 step 5: A MERELY PHYSICAL RELATION IS NOT ROUTE-ELIGIBLE.** The audited body
    /// inserted the handle into the very set the send paths iterate, so a peer that had authenticated
    /// NOTHING was handed frames; the radio carrieth a handle, and only the matching confirmation proveth
    /// whose identity standeth behind it. The route-eligible view is admitted by `trustedPeerDidConnect`.
    @discardableResult
    internal func handlePeerConnect(_ peerId: UUID) -> Int {
        peerLock.lock()
        presentPeers.insert(peerId)
        let count = presentPeers.count
        peerLock.unlock()
        return count
    }

    /// Apply one peer-disconnect event: remove it from the durable view under the
    /// peer lock, drop its session, and report the resulting peer count. Extracted
    /// verbatim from the former `transportDidDisconnect` body (behaviour
    /// preserved: the session is dropped after the lock is releas'd, as before).
    @discardableResult
    internal func handlePeerDisconnect(_ peerId: UUID) -> Int {
        peerLock.lock()
        presentPeers.remove(peerId)
        // A DEPARTED RADIO CANNOT ROUTE: the handle leaveth BOTH views, so a peer whose link fell is
        // never handed a frame while its trust lingereth in the registry.
        peers.remove(peerId)
        let count = presentPeers.count
        peerLock.unlock()
        // CRYPTO-001: A NODE WHICH LEARNS OF A PEER'S DEPARTURE KNOWETH THE PEER, NOT THE
        // RELATION. It therefore speaketh the handle-scoped verb -- every incarnation of that
        // handle retires -- rather than guessing an admission, and it can no longer retire a
        // relation of a peer which merely shareth a reused handle.
        sessions.retireIncarnations(ofPeerId: peerId)
        return count
    }

    /// THE ROUTE-ELIGIBLE peers (witnesses only): those admitted by the trusted event.
    internal func knownPeersForTest() -> Set<UUID> {
        peerLock.lock(); defer { peerLock.unlock() }
        return peers
    }

    /// THE PRESENT peers (witnesses only): the handles the radio carrieth, trusted or not.
    internal func presentPeersForTest() -> Set<UUID> {
        peerLock.lock(); defer { peerLock.unlock() }
        return presentPeers
    }

    /// V4 does not fabricate a successful SOS while ADR-004 and M2-link remain open.
    public func broadcastSos(payload: Data) -> SosDispatchResult {
        guard Self.linkLayerReady else { return .unavailable(Self.linkLayerOpenReason) }
        return dispatchSos(payload: payload) { [weak self] frame, peer in
            guard let self else { return false }
            return self.ble.send(frame, to: peer) == .admitted
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
        // *** GS-FINAL-003 (round 699): THE `Author` ARM IS GATED -- AND IT WAS FOUND BY ENUMERATING THE DOOR, NOT BY
        // READING A ROAD. ***
        //
        // **THE COMMAND SURFACE IS ONE DOOR WITH THREE ARMS, AND TWO OF THE THREE WERE GATED:** `retrySos` asketh the
        // gate first (round 633) and `cancelSos` consulteth it. **`dispatchSos` -- WHICH IS THE ARM THAT WRITETH --
        // DID NOT.** *It calleth `deliveryTracker.enqueueSosOutbound` and `store.persist` below.* **A PENDING WIPE MUST
        // NOT BE HANDED NEW DURABLE WORK.** *The identical defect existed on Android, and both isles were repaired
        // together so a reader of either findeth the same law.*
        //
        // **THE GATE COMETH FIRST, BEFORE THE AUTHORITY LOOKUP**, and the ordering is load-bearing for a reason beyond
        // the one round 633 already paid for (*a gate that runs after the thing it gates is a report, not a gate*):
        // **`SignedSosV1.author` CONSUMETH A NONCE**, so a refused authoring must leave the nonce stream untouched --
        // *otherwise a wipe would burn a nonce for a call it never queued.* The refusal useth the type's OWN
        // vocabulary (a typed `.failed` naming the wipe), never an invented error.
        if let gate = wipeGate, !gate.allowsSensitiveUse() {
            return .failed("sos: a wipe is pending; sensitive use is refused")
        }
        // GMP/2.1 (ADR-001 §3.3, C6.7): msg_id is content-and-nonce derived.
        // The creation time and message_nonce are bound into the id (little-endian)
        // and authenticated alongside the payload by the signature below. Byte-identical to
        // Android Router.buildSos / MessageId.derive (see MessageIdTests).
        // T38: with the authority wired, the distress call is authored through
        // the single signed-SOS authority (section 15 layout, cross-isle byte
        // parity). GS-SOS-001 (the iOS twin of the Android repair): WITHOUT
        // usable signing material the node REFUSETH -- it emiteth no legacy
        // structural shape and offereth nothing, because a receiver refusing a
        // frame the SENDER was willing to offer is not a control, it is a hope.
        // The refusal happeneth BEFORE any durable hold, any C6 row and any
        // send, so a refused distress leaveth no trace that could be mistaken
        // for a queued one. `currentSigningSeed()` is consulted first, so an
        // authority that yieldeth no material consumes no nonce.
        let frame: FrameV2
        if let authority = sosAuthority,
           let seed = authority.currentSigningSeed(),
           authority.currentStaticDhPublicKey() != nil,
           // GS-SOS-001, SECOND DEFECT (round 164): THE BINDING COMETH FROM THE AUTHORITY, never
           // from a private re-derivation -- `SignedSosV1.author` used to strike it here-adjacent
           // from the material it was handed, which is the issuance bypass the repository's
           // local-identity control refuseth. An authority that holdeth no binding is a reason to
           // refuse, exactly as one that holdeth no seed is.
           let binding = authority.currentIdentityBinding() {
            let clock = authority.currentTimeEpochSeconds()
            let quality: TimeQuality = (clock == 0) ? .unknown : .userConfirmed
            do {
                frame = try SignedSosV1.author(
                    binding: binding,
                    signingSeed: seed,
                    createdAtEpochSeconds: clock,
                    timeQuality: quality,
                    messageNonce: authority.currentNonce(),
                    bodyUtf8: payload)
            } catch {
                return .failed("SOS authoring refused non-canonical material")
            }
        } else {
            // GS-SOS-001: the audited form built the legacy structural shape here
            // -- a zeroed seal with the payload in the clear -- and handed it to
            // relays as though it were a distress call. The card's law is a TYPED
            // REFUSAL: no frame, no hold, no C6 row, no send. The wording is
            // IDENTICAL to the Android isle's (`SosDispatchResult.Failed`), so a
            // court that asserteth the refusal by name passeth on both isles.
            return .failed(
                "no SOS signing authority: an unauthenticated distress call may not be offered")
        }

        // T39: the held frame AND its NONE-mode delivery row commit as ONE durable
        // pair (section 14's both-or-neither law for the broadcast path). The
        // repository is the authority: the SQL store over the shared handle runs
        // the pair in one transaction, the store-backed repository writes both
        // tables under the store's one lock, and a plain journal inherits the
        // compatible two-step route (persist, then record) the pre-T39 dispatch
        // spoke -- its observable sequence of operations is byte-unchanged. A
        // half-committed pair is unnameable now: every rejection leaves no held
        // orphan behind and no orphan row, and the failure is reported typed,
        // never fabled. The B4 gate stands covering both tables: a pair this
        // node cannot durably hold is NOT sent (zero sends) and reported
        // `.notPersisted` so the UI does not lie.
        let pair = deliveryTracker.enqueueSosOutbound(
            frame,
            localOriginNodeId: identity.nodeId
        ) {
            // Stage 4C.1 / C6.1: the compatible route records the delivery
            // lifecycle AFTER durable hold (persist-before-tracker, extending the
            // 4B.1 persist-before-forward gate to the delivery state). SOS is a
            // broadcast (no single intended recipient), so the row is enqueued
            // with `AckMode.none` and no expected recipient binding -- a
            // none-mode message can NEVER be acknowledged via this tracker (an
            // inbound ACK for it yields `.notAckEligible` and the authenticator
            // is not invoked). Idempotent: a re-delivery of the identical pair is
            // `.alreadyQueuedSameBinding`; only a genuine rejection aborts
            // before any BLE write.
            store.persist(frame, receivedFrom: identity.nodeId)
        }
        switch pair {
        case .created, .alreadyQueuedSameBinding:
            break
        case .rejectedCapacity, .storageFailure:
            // The pair was not held (capacity, or a rolled-back storage attempt at
            // either table): exit BEFORE any transport operation. Zero sends. No
            // delivery is claimed for a message this node does not durably hold.
            return .notPersisted
        default:
            // conflict / terminal / torn / invalid: the standing authority refuses
            // the pair; nothing moved, nothing is promised.
            return .failed("delivery pair commit rejected")
        }
        // T43: each send records an EPHEMERAL link offer, never a custody claim.
        // The durable row standeth QUEUED_DURABLY until an intended recipient's
        // authenticated ACK moveth it.
        // GS-SOS-002: the lease is re-checked BEFORE every offer, so a cancellation committed
        // inside a send callback suppresseth the offers not yet made.
        let dispatchLease = mintDispatchLease(frame.msgId)
        var dispatchOffers = 0
        var handed = 0
        for peer in currentPeers() {
            if !dispatchLeaseStands(frame.msgId, dispatchLease) { break }
            // GS-SOS-002: durable truth gates the SECOND offer onwards, because this path may
            // not have committed its row yet (the DIRECT path commits after offering).
            if dispatchOffers > 0 && !sosStillDispatchableByDurableTruth(frame.msgId) { break }
            dispatchOffers += 1
            let admitted = send(frame, peer)
            linkOffers.record(frame.msgId, linkId: Self.linkBytes(peer), admitted: admitted,
                              atMonoMillis: controlClock())
            if admitted { handed += 1 }
        }
        rememberSosCommit(frame: frame)
        return handed == 0 ? .queuedDurably : .handedToRelays(handed)
    }

    // ---- T39 (section 14): the one durable authority for the SOS lifecycle ----
    //
    // The commands below never mutate authoritative state on a validation
    // failure; every result is typed so that failure is distinguishable from
    // the idempotent no-op (C6.4-A/J law, applied to the broadcast path).

    /// The observable mirror of the durable projection (UI parity with the
    /// Android status field). Read-only; refreshed only from the tables or the
    /// remembered projection they justified.
    public private(set) var hasActiveSosBroadcast: Bool = false

    private func publishSosMirrorFromMemory() {
        sosRowLock.lock()
        let active = sosRowMemory != nil
        sosRowLock.unlock()
        hasActiveSosBroadcast = active
    }

    /// Remember the projection this node just committed -- reading the row back
    /// FROM the tables (the authority, not the caller's hope, decides whether
    /// the projection lives: a cancellation that landed mid-send must not be
    /// remembered as active).
    private func rememberSosCommit(frame: FrameV2) {
        var live: DeliveryState? = nil
        switch deliveryTracker.lookup(frame.msgId) {
        case .found(let rec) where rec.ackMode == .none:
            if rec.state == .queuedDurably || rec.state == .handedToRelay {
                live = rec.state
            }
        default:
            break
        }
        guard let state = live else {
            sosRowLock.lock(); sosRowMemory = nil; sosRowLock.unlock()
            publishSosMirrorFromMemory()
            return
        }
        let projection = ActiveSos(
            msgId: frame.msgId, state: state, frame: frame,
            committedAtMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
        sosRowLock.lock(); sosRowMemory = projection; sosRowLock.unlock()
        publishSosMirrorFromMemory()
    }

    /// T39: resume the SAME authored bytes of a still-live broadcast call. The
    /// held frame is read back from the durable authority and re-handed to the
    /// relays verbatim -- no re-derivation, no fresh seal: the msg_id is
    /// immutable content and a retry that re-authored would betray it. A
    /// terminal row (cancelled, expired, acknowledged) refuses the resume; a
    /// vanished frame or row fails typed, never masquerading as an empty
    /// success.
    @discardableResult
    internal func retrySos(msgId: Data, send: (FrameV2, UUID) -> Bool) -> SosDispatchResult {
        guard msgId.count == 16 else { return .failed("retry: msg_id must be 16 bytes") }
        // *** GS-FINAL-003 (round 638): THE GATE COMES FIRST -- AND THE ORDERING IS THE POINT, MEASURED ON THE OTHER
        // ISLE. *** Round 633 placed Android's first attempt at this AFTER the tracker read and **ITS OWN ARM NAMED
        // THE MISTAKE** (`retry: no durable row`), meaning the durable row was CONSULTED BEFORE THE WIPE WAS
        // CONSIDERED. *A security gate that runs after the thing it gates is a report, not a gate.* Asked here, before
        // any read, so a pending wipe reacheth nothing and the caller can tell this refusal from an ordinary drop.
        if let gate = wipeGate, !gate.allowsSensitiveUse() {
            return .failed("retry: a wipe is pending; sensitive use is refused")
        }
        let row: DeliveryRecord
        switch deliveryTracker.lookup(msgId) {
        case .found(let rec): row = rec
        case .notFound: return .failed("retry: no durable row for this msg_id")
        case .corrupt: return .failed("retry: corrupt delivery row")
        case .storageFailure: return .failed("retry: storage failure reading the row")
        case .invalidArgument: return .failed("retry: invalid msg_id")
        }
        if row.ackMode != .none { return .failed("retry: not a broadcast row") }
        if row.state != .queuedDurably && row.state != .handedToRelay {
            return .failed("retry: obligation already terminal (\(row.state))")
        }
        guard let frame = store.allHeldOrderedByPriority().first(where: {
            $0.msgId == msgId && $0.type == .sos
        }) else {
            return .failed("retry: no held frame to resume")
        }
        // GS-SOS-002: the lease is re-checked BEFORE every offer, so a cancellation committed
        // inside a send callback suppresseth the offers not yet made.
        let dispatchLease = mintDispatchLease(msgId)
        var retryOffers = 0
        var handed = 0
        for peer in currentPeers() {
            if !dispatchLeaseStands(msgId, dispatchLease) { break }
            // GS-SOS-002: durable truth gates the SECOND offer onwards, because this path may
            // not have committed its row yet (the DIRECT path commits after offering).
            if retryOffers > 0 && !sosStillDispatchableByDurableTruth(msgId) { break }
            retryOffers += 1
            let admitted = send(frame, peer)
            linkOffers.record(msgId, linkId: Self.linkBytes(peer), admitted: admitted,
                              atMonoMillis: controlClock())
            if admitted { handed += 1 }
        }
        rememberSosCommit(frame: frame)
        return handed == 0 ? .queuedDurably : .handedToRelays(handed)
    }

    /// T39: cancel one broadcast call DURABLY -- the guarded terminal CAS on the
    /// row plus the retirement of the held/scheduled work, in the authority's one
    /// transaction. Already relayed copies cannot be recalled: the result carries
    /// the truth of whether any had gone out (`.cancelled(wasRelayed:)`) so the
    /// UI can say so too. Duplicate cancellation is the idempotent
    /// `.alreadyCancelled`, never an error; a directed obligation is
    /// `.notBroadcast` and stands untouched.
    @discardableResult
    internal func cancelSos(_ msgId: Data) -> SosCancelResult {
        // *** GS-FINAL-003 (round 699): THE CANCEL ROAD IS GATED -- IT LOOKS LIKE A WRITE AND IS *ALSO A READ*. ***
        //
        // *It tombstones the row (a write) AND returneth a result DERIVED FROM THAT ROW* -- `.cancelled(wasRelayed:)`,
        // `.alreadyCancelled(wasRelayed:)`, `.rejectedTerminal(state)`. **WHILE A WIPE IS PENDING THAT DISCLOSES
        // DURABLE STATE FROM A STORE BEING ERASED** -- *the same class as `deliveryProjection` and the ACK census,
        // hiding on a road whose NAME suggesteth a mutation.* The Android arm caught it in exactly that form: pre-fix
        // it returned `Cancelled(wasRelayed=false)` from a wiping node. **THE IDENTICAL GAP WAS ON BOTH ISLES, AND THEY
        // WERE REPAIRED TOGETHER SO A READER OF EITHER FINDETH THE SAME LAW.**
        //
        // **AND THE DIRECTION IS THE SAFE ONE TO GATE, MEASURED RATHER THAN ASSUMED.** The gate protecteth USE, not
        // DESTRUCTION (*`WipeGatedAckObligationStore.deleteAllFrames()` is deliberately open, because the eraser must
        // be able to erase*). **SO I CHECKED WHETHER THE WIPE'S OWN PATH NEEDS THIS ROAD: `cancelSos`/`.cancel` do not
        // appear in `CrashResumableWipe.swift` or `MeshRuntime.swift`** -- *refusing here cannot deadlock the wipe,
        // the failure mode this programme measured twice on constructor gates.* Cancelling is a USE of the store.
        //
        // **THE REFUSAL USETH THE TYPE'S OWN VOCABULARY: `.storageFailure`, whose docstring already readeth "a storage
        // failure during the guarded transaction: rolled back whole"** -- *precisely true here: nothing moved, nothing
        // was disclosed, no invented case added for callers to exhaust.*
        if let gate = wipeGate, !gate.allowsSensitiveUse() { return .storageFailure }
        let outcome = deliveryTracker.cancelSosBroadcast(msgId)
        // GS-SOS-002: a SUCCESSFUL cancellation retireth the message's dispatch lease, so an offer
        // loop already iterating cannot newly offer a call whose durable row was just retired.
        if case .cancelled = outcome { invalidateDispatchLease(msgId) }
        sosRowLock.lock()
        if let seen = sosRowMemory, seen.msgId == msgId { sosRowMemory = nil }
        sosRowLock.unlock()
        publishSosMirrorFromMemory()
        // T43: "wasRelayed" meaneth "copies MAY be out", and the only honest source
        // for that is the EPHEMERAL link-offer ledger -- a durable row no longer
        // carrieth a relayed flag, because a local ATT admission was never custody.
        // The ADJUSTMENT happeneth after the mirror refresh, never instead of it:
        // the first attempt returned early and left the mirror lit, which the T39
        // witness caught at once.
        if case .cancelled(false) = outcome, linkOffers.anyAdmitted(msgId) {
            return .cancelled(wasRelayed: true)
        }
        return outcome
    }

    /// T39: the command surface. Author runs the established dispatch arm
    /// (returns the same `SosDispatchResult` taxonomy the sealed courts speak);
    /// Retry resumes the same bytes; Cancel retires durably. One entry point,
    /// three honest outcomes -- no arm reports a success the tables do not show.
    @discardableResult
    internal func handleSosCommand(_ command: SosCommand, send: (FrameV2, UUID) -> Bool) -> SosCommandResult {
        switch command {
        case .author(let payload):
            return .enqueued(dispatchSos(payload: payload, send: send))
        case .retry(let msgId):
            return .enqueued(retrySos(msgId: msgId, send: send))
        case .cancel(let msgId):
            return .cancelled(cancelSos(msgId))
        }
    }

    /// T39: the durable Active-SOS projection, read FROM the delivery row joined
    /// with the held frame -- never from a UI memory. A call counts active while
    /// its row is NONE-mode and queuedDurably or handedToRelay and its frame is
    /// still held; terminal rows (cancelled, expired) are not active. After a
    /// restart the very same scan re-exposes what the tables still carry, which
    /// is what the plain UI flag could never promise. Broadcast shows the local
    /// queue only: nothing here claims recipient-delivered or guaranteed rescue.
    internal func activeSosSnapshot() -> ActiveSos? {
        // *** GS-FINAL-003 (round 638): THE PROJECTION IS GATED TOO. *** *"A call counts active while its row is ... and
        // its frame is still held"* -- **BUT WHILE A WIPE IS PENDING NOTHING MAY BE CLAIMED ABOUT A STORE WHOSE
        // CONTENTS ARE BEING ERASED.** The honest answer is `nil` (no active call), for the same reason the ACK census
        // answereth 0: a projection read from an erasing store is A CLAIM THAT LOOKS LIKE A STATE.
        if let gate = wipeGate, !gate.allowsSensitiveUse() { return nil }
        for frame in store.allHeldOrderedByPriority() {
            guard frame.type == .sos else { continue }
            var row: DeliveryRecord? = nil
            switch deliveryTracker.lookup(frame.msgId) {
            case .found(let rec): row = rec
            default: continue
            }
            guard let rec = row, rec.ackMode == .none,
                  rec.state == .queuedDurably || rec.state == .handedToRelay
            else { continue }
            var remembered: Int64? = nil
            sosRowLock.lock()
            if let seen = sosRowMemory, seen.msgId == frame.msgId {
                remembered = seen.committedAtMillis
            }
            sosRowLock.unlock()
            let seen = ActiveSos(msgId: frame.msgId, state: rec.state, frame: frame,
                                 committedAtMillis: remembered)
            sosRowLock.lock(); sosRowMemory = seen; sosRowLock.unlock()
            publishSosMirrorFromMemory()
            return seen
        }
        sosRowLock.lock(); sosRowMemory = nil; sosRowLock.unlock()
        publishSosMirrorFromMemory()
        return nil
    }

    /// The last projection this node published through its own arms (may be
    /// stale across a restart; `activeSosSnapshot` re-derives it from the
    /// tables).
    internal func lastKnownActiveSos() -> ActiveSos? {
        sosRowLock.lock(); defer { sosRowLock.unlock() }
        return sosRowMemory
    }

    /// The authoritative route: scan the tables, re-derive the projection, and
    /// refresh the mirror from what the store actually holds. This is what the
    /// restart cases exercise; it returns what it saw.
    @discardableResult
    internal func refreshSosStatusAfterScan() -> ActiveSos? {
        let seen = activeSosSnapshot()
        publishSosMirrorFromMemory()
        return seen
    }

    /// Stage 4C / C6.6 -- atomic DIRECT outbound enqueue and dispatch.
    ///
    /// In ONE transaction, persists `frame` in held_frames and creates the initial
    /// delivery_state (QUEUED_DURABLY, SINGLE_RECIPIENT, `expectedRecipient`).
    /// Only upon successful commit is the transport `send` callback invoked.
    ///
    /// Each successful relay hand-off records an EPHEMERAL link offer (T43): the
    /// durable state standeth QUEUED_DURABLY and is advanced ONLY by an intended
    /// recipient's authenticated ACK.
    @discardableResult
    internal func dispatchDirect(
        _ frame: FrameV2,
        expectedRecipient: Data,
        send: (FrameV2, UUID) -> Bool
    ) -> DirectDispatchResult {
        // *** GS-FINAL-003 (round 701): THE DIRECTED AUTHORING ROAD IS GATED -- `dispatchSos`'s OWN TWIN. ***
        //
        // **`dispatchDirect` IS THE DIRECTED TWIN OF `dispatchSos`: same class of road, same durable write**
        // (*`store.enqueueDirectOutbound` inserts the frame AND the `QUEUED_DURABLY` delivery row in one transaction*).
        // **A PENDING WIPE MUST NOT BE HANDED NEW DURABLE WORK ON EITHER ROAD**, and gating one twin while leaving the
        // other open is the same two-of-three asymmetry the command door had. *Found by the same enumeration, not by a
        // reading.*
        //
        // **THE REFUSAL USETH THE TYPE'S OWN VOCABULARY: `.rejected(.storageFailure)`, whose docstring already readeth
        // "a real SQL / IO failure occurred during the transaction; rolled back"** -- *which is honestly what a
        // pending wipe is from this road's point of view: the store is not available for use, and nothing was added.*
        // No invented error, and no plausible-looking success.
        if let gate = wipeGate, !gate.allowsSensitiveUse() {
            return .rejected(.storageFailure)
        }
        let enqueueRes = store.enqueueDirectOutbound(
            frame,
            expectedRecipient: expectedRecipient,
            localOriginNodeId: identity.nodeId
        )
        let canonicalFrame: FrameV2
        switch enqueueRes {
        case .created(let f), .alreadyQueuedSameBinding(let f):
            canonicalFrame = f
        default:
            return .rejected(enqueueRes)
        }

        // GS-SOS-002: the lease is re-checked BEFORE every offer, so a cancellation committed
        // inside a send callback suppresseth the offers not yet made.
        let dispatchLease = mintDispatchLease(canonicalFrame.msgId)
        var directOffers = 0
        var handed = 0
        for peer in currentPeers() {
            if !dispatchLeaseStands(canonicalFrame.msgId, dispatchLease) { break }
            // GS-SOS-002: durable truth gates the SECOND offer onwards, because this path may
            // not have committed its row yet (the DIRECT path commits after offering).
            if directOffers > 0 && !sosStillDispatchableByDurableTruth(canonicalFrame.msgId) { break }
            directOffers += 1
            let admitted = send(canonicalFrame, peer)
            linkOffers.record(canonicalFrame.msgId, linkId: Self.linkBytes(peer), admitted: admitted,
                              atMonoMillis: controlClock())
            if admitted { handed += 1 }
        }
        return handed == 0 ? .queuedLocally : .handedToRelays(handed)
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
        // T42: the dispatch statute is a TYPE, in one place and in one order:
        // control -> ACK -> the generic durable road, and a refusal BY NAME for
        // anything this profile carries not.
        switch frameDispatcher.dispatch(frame, from: receivedFrom) {
        case .control(let decision, let accepted):
            lastControlDecision = decision
            let replies = frameDispatcher.replies(decision)
            if !replies.isEmpty { offerControlFrames(replies, destination: receivedFrom) }
            return accepted
        case .ack(let dispatch):
            // GS-RUNTIME-001 step 4's LAST WAKE: **NEWLY COMMITTED FORWARD WORK WAKETH THE WORKER FOR THAT
            // RELATION.** An accepted ACK candidate IS new forward work -- it may have to travel onward -- and
            // the wake is gated on the TRUSTED RELATION MAPPING, so an untrusted sender is not served and
            // nothing is guessed.
            if dispatch.accepted, handleForNodeId[receivedFrom] != nil {
                ackEventWakes += 1
                _ = drainAckWorkOnce(nodeId: receivedFrom)
            }
            return dispatch.accepted
        case .refused:
            return false
        case .message, .sos:
            break   // the generic durable road below
        }
        // GS-RUNTIME-001 step 4: **AN INBOUND REQUEST WAKETH THE WORKER FOR ITS OWN RELATION.** A frame that
        // reacheth the generic durable road is a message from a peer; a peer that requesteth or awaiteth an ACK
        // must have the worker woken FOR THAT EXACT NODE ID -- and the wake is gated on the TRUSTED RELATION
        // MAPPING, so A SENDER WITH NO TRUSTED RELATION IS NOT SERVED AND NOTHING IS GUESSED.
        if handleForNodeId[receivedFrom] != nil {
            ackEventWakes += 1
            _ = drainAckWorkOnce(nodeId: receivedFrom)
        }
        let relay = router.ingest(frame, isAddressedToMe: frame.routingTag == identity.nodeHint,
                                  receivedFrom: receivedFrom)
        let inbox = recipientInbox
        if let inbox = inbox, frame.type == .message,
           (frame.flags & FrameV2.Flags.sealed) != 0 {
            // T37: the local destination attempt rides beside the relay -- it
            // decides nothing about forwarding (the router's decision above
            // stands untouched) and only queues an accepted delivery's
            // canonical ACK for the link's writer. try/catch: a receiver fault
            // must never escape the collector and never touches the relay
            // truth (the suspend-propagating fault seam of the T83 doctrine).
            do {
                let accepted = try inbox.acceptVerifiedAndRequireAck(
                    frame, receivedFrom: receivedFrom, fault: nil)
                var ack: FrameV2? = nil
                switch accepted {
                case .new(ack: let a): ack = a
                case .duplicate(ack: let a): ack = a
                case .rejected: ack = nil
                }
                if let a = ack { offerAckForLink(a) }
            } catch {
                // the durable authorities stand; the outbox stays as it is
            }
        }
        // T42: FORWARD ONLY AFTER DURABLE ACCEPTANCE. `relay` is true exactly when
        // the router accepted the frame for persist+relay, i.e. the store
        // committed it; the copy is prepared once (TTL-1 / hop+1) and queued for
        // every registered TrustedPeer except the one it arrived from.
        if relay { _ = pumpFor().enqueueForward(frame, fromPeer: receivedFrom) }
        if frame.type == .sos, let observer = sosObserver {
            // T38: the distress indication is announced only to consumers of an
            // authenticated key binding. The relay decision above was computed
            // FIRST and stands untouched -- refusing to authenticate is a
            // verdict about the INDICATION, never about the frame's epidemic
            // duty.
            switch SignedSosV1.verify(frame, expectedNodeId: nil) {
            case .authenticated(let view):
                observer.onSosAuthenticated(view: view)
            case .unauthenticated(let reason, _):
                observer.onSosUnauthenticated(frame: frame, reason: reason)
            }
        }
        return relay
    }
}

extension MeshNode: TransportDelegate {
    public func transportDidConnect(peerId: UUID) {
        let count = handlePeerConnect(peerId)
        onPeerCountChanged?(count)
    }
    /// IOS-02 step 5, THE SHIPPING WIRING: the transport telleth the node of the trusted hour WITH THE IDENTITY IT
    /// CARRIED, and the node admitteth that peer to the ROUTE-ELIGIBLE view. Until this landed the event reacheth the
    /// node only through the composition's hand-wiring (`ComposedRuntime.link`), so the law held in the harness and
    /// not in the shipping delegate path.
    /// GS-RUNTIME-001 steps 4 and 5, FIRST SLICE: **ONE BOUNDED TURN FOR ONE NAMED RELATION, HANDED THROUGH THE
    /// SAME AUTHENTICATED TRANSPORT.** The batch cometh from the pump keyed by the NODE ID; the frames leave by
    /// `ble.send` keyed by the HANDLE; and the outcome returneth to the pump so its retry interval is honoured.
    /// An UNKNOWN relation is REFUSED (nil) rather than guessed at, because a frame sent to a guessed handle
    /// would be exactly the misrouting this programme hunteth.
    @discardableResult
    internal func drainAckWorkOnce(nodeId: Data, generation: UInt64? = nil) -> Int? {
        guard let pump = ackPump, let handle = handleForNodeId[nodeId] else { return nil }
        // GS-RUNTIME-001 step 5: **RECHECK THE CAPTURED RELATION.** A caller that nameth the generation it was
        // admitted under is REFUSED when the relation hath moved since -- the handle and the node id are the
        // SAME across a replacement, and only the generation telleth them apart.
        if let generation, relationForNodeId[nodeId]?.generation != generation { return nil }
        let batch = pump.nextBatch(nodeId)
        var handed = 0
        for copy in batch.copies {
            // (MY FIRST DRAFT REACHED FOR `copy.frame` AND THERE IS NO SUCH MEMBER: the copy carrieth
            // `encodedFrame`, ALREADY THE CANONICAL SIGNED BYTES -- the harness handeth exactly those bytes on,
            // and the transport's own road for bytes that are already canonical is `send(clear:)`, THE SAME ROAD
            // THE KEY-CONFIRMATION CHALLENGE TRAVELLETH. Sealing them again would corrupt the very signature
            // the recipient verifieth.)
            let verdict = ble.send(clear: copy.encodedFrame, to: handle)
            let accepted = (verdict == .admitted)
            pump.onForwardOutcome(copy, peer: nodeId, accepted: accepted)
            if accepted { handed += 1 }
        }
        return handed
    }

    /// GS-RUNTIME-001 step 4: **ONE BOUNDED TURN FOR EVERY TRUSTED RELATION** -- the mapping IS the set of live
    /// relations, so nothing is guessed and a departed relation is not served.
    @discardableResult
    internal func runAckTurnForEveryTrustedRelation() -> Int {
        var handed = 0
        for nodeId in Array(handleForNodeId.keys) { handed += (drainAckWorkOnce(nodeId: nodeId) ?? 0) }
        ackTurnsRun += 1
        return handed
    }

    /// Arm the periodic deadline. Idempotent: a second arm while one standeth is REFUSED rather than doubled,
    /// so two timers can never retire each other's turns.
    internal func armAckTurnDeadline(intervalSeconds: TimeInterval) {
        guard ackTurnSource == nil, intervalSeconds > 0 else { return }
        let source = DispatchSource.makeTimerSource(queue: ackTurnQueue)
        source.schedule(deadline: .now() + intervalSeconds, repeating: intervalSeconds)
        source.setEventHandler { [weak self] in _ = self?.runAckTurnForEveryTrustedRelation() }
        ackTurnSource = source
        source.resume()
    }

    /// The deadline dieth with its owner: no callback may fire for a runtime that is gone.
    internal func cancelAckTurnDeadline() {
        ackTurnSource?.cancel()
        ackTurnSource = nil
    }

    public func transportApplicationLinkReady(peerId: UUID, receivedFrom nodeId16: Data, generation: UInt64) {
        _ = trustedPeerDidConnect(nodeId: nodeId16, peerId: peerId, generation: generation)
        // GS-RUNTIME-001 step 3: **ON LinkReady THE PEER BECOMETH ELIGIBLE, FOR THAT EXACT NODE ID.** The pump
        // schedu1eth ONE bounded worker per relation; nothing else in production ever told it.
        ackPump?.onLinkReady(nodeId16)
        // AND THE FIRST INVENTORY IS TAKEN AT ONCE, for THAT relation alone: the card's step 4 asketh the worker
        // to be woken for the initial inventory. (The periodic deadline, inbound requests and newly committed
        // forward work are the remaining wakes of that step, and are NOT claimed here.)
        _ = drainAckWorkOnce(nodeId: nodeId16)
    }

    public func transportReady(peerId: UUID) {
        // Deliberately no half-handshake. M2-link owns role election, real remote
        // hints, record types HS1/HS2/HS3, reassembly and timeouts.
    }

    public func transportDidDisconnect(peerId: UUID) {
        let count = handlePeerDisconnect(peerId)
        onPeerCountChanged?(count)
    }

    /// IOS-04 (T24) step 3's consumer half (round 250): THE APPLICATION IS TOLD WHOSE IDENTITY SENT THE FRAME.
    /// The audited body passed an EMPTY `receivedFrom` and recorded 'sender not yet identified'; the transport now
    /// delivereth the authenticated node id it captured at the sealed round, and this override passeth it ONWARD to the
    /// dispatcher -- so the router, the ACK tracker and every durable road downstream learn the SENDER, not a handle.
    public func transportDidReceive(data: Data, peerId: UUID, receivedFrom nodeId16: Data) {
        guard Self.linkLayerReady, let frame = decodeInbound(data) else { return }
        handleInboundFrame(frame, receivedFrom: nodeId16)
    }

    public func transportDidReceive(data: Data, peerId: UUID) {
        guard Self.linkLayerReady, let frame = decodeInbound(data) else { return }
        // Stage 4C / C7: route ACK frames to the delivery tracker, all other
        // frames to the epidemic router, via the ungated `ingestInbound` seam.
        // T24 (CORRECTED at round 250): THE TRANSPORT NOW DELIVERETH THE AUTHENTICATED NODE ID, so this path's
        // empty `receivedFrom` is NO LONGER the whole truth. The comment that stood here said the iOS transport
        // 'exposeth onely a local peer UUID, not the remote node_id' -- TRUE WHEN IT WAS WRITTEN, AND MADE FALSE BY
        // THE ROUND-249 REPAIR, which giveth `transportDidReceive(data:peerId:receivedFrom:)` with the captured peer's
        // sixteen-octet node id. THE OVERRIDE BELOW TAKETH IT; this handle-only entry point remaineth for a relation
        // whose peer was never captured, and it carrieth an EMPTY `receivedFrom` -- 'sender not yet identified' --
        // which is honest rather than convenient.
        handleInboundFrame(frame, receivedFrom: Data())
    }

    /// Decode an inbound clear, fail-closed: nil on any desync / magic / version /
    /// CRC / length error. Pure and non-throwing, so the fail-closed gate is
    /// witness'd without a radio; the consumer ingests onely when this yieldeth a
    /// frame. Extracted from the former `transportDidReceive` body.
    internal func decodeInbound(_ data: Data) -> FrameV2? {
        return FrameV2.decode(data)
    }

    /// Decode-then-ingest for an already-decod'd frame, preserving the former
    /// collector body verbatim (behaviour preserved): ACK frames go to the
    /// delivery tracker, all others to the epidemic router.
    @discardableResult
    internal func handleInboundFrame(_ frame: FrameV2, receivedFrom: Data) -> Bool {
        return ingestInbound(frame, receivedFrom: receivedFrom)
    }
}
