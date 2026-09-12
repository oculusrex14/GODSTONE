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

    private var peers: Set<UUID> = []
    private let peerLock = NSLock()
    public var onPeerCountChanged: ((Int) -> Void)?
    private var isStarted = false

    /// Production initializer: a node owns its durable store, durable delivery tracker, and trusted SessionManager.
    public init(identity: MeshIdentity, store: MessageStore,
                deliveryTracker: DeliveryTracker, sessions: SessionManager) {
        self.identity = identity
        self.store = store
        self.deliveryTracker = deliveryTracker
        self.sessions = sessions
        self.router = Router(selfNodeId: identity.nodeId)
        // Inject the durable store into the router before start (Stage 4B).
        self.router.store = store
        self.ble.store = store
        self.ble.identity = identity
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

    /// Open the radio adapter, once its consumers are already install'd.
    private func openAdapters() {
        ble.start()
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

    /// Apply one peer-connect event to the durable view, under the peer lock, and
    /// report the resulting peer count. Extracted verbatim from the former
    /// `transportDidConnect` body (behaviour preserved) so the consumer's
    /// substance is witness'd without a live radio.
    @discardableResult
    internal func handlePeerConnect(_ peerId: UUID) -> Int {
        peerLock.lock()
        peers.insert(peerId)
        let count = peers.count
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
        peers.remove(peerId)
        let count = peers.count
        peerLock.unlock()
        sessions.drop(peerId)
        return count
    }

    /// The peers currently held in the durable view (witnesses only).
    internal func knownPeersForTest() -> Set<UUID> {
        peerLock.lock(); defer { peerLock.unlock() }
        return peers
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
        // GMP/2.1 (ADR-001 §3.3, C6.7): msg_id is content-and-nonce derived.
        // The creation time and message_nonce are bound into the id (little-endian)
        // and authenticated alongside the payload by the signature below. Byte-identical to
        // Android Router.buildSos / MessageId.derive (see MessageIdTests).
        // T38: with the authority wired, the distress call is authored through
        // the single signed-SOS authority (section 15 layout, cross-isle byte
        // parity). Without it the node emits the legacy structural shape --
        // documented, refused by the receiver's runtime authentication, and
        // unreachable for real radios while the link layer stays closed.
        let frame: FrameV2
        if let authority = sosAuthority,
           let seed = authority.currentSigningSeed(),
           let dhPub = authority.currentStaticDhPublicKey() {
            let clock = authority.currentTimeEpochSeconds()
            let quality: TimeQuality = (clock == 0) ? .unknown : .userConfirmed
            do {
                frame = try SignedSosV1.author(
                    signingSeed: seed,
                    staticDhPublicKey: dhPub,
                    generation: authority.currentGeneration(),
                    createdAtEpochSeconds: clock,
                    timeQuality: quality,
                    messageNonce: authority.currentNonce(),
                    bodyUtf8: payload)
            } catch {
                return .failed("SOS authoring refused non-canonical material")
            }
        } else {
            let createdAt = Int64(Date().timeIntervalSince1970)
            let messageNonce = MessageId.generateNonce()
            let msgId = MessageId.derive(
                senderNodeId: identity.nodeId,
                createdAtEpochSeconds: createdAt,
                messageNonce: messageNonce,
                payload: payload)
            let magic = Data("SOS1".utf8)
            let sealed = magic + Data(repeating: 0, count: 64) + payload
            frame = FrameV2(
                type: .sos,
                msgId: msgId,
                routingTag: identity.nodeHint,
                ttl: FrameV2.maxTtl,
                hopCount: 0,
                flags: UInt16(FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok),
                payload: sealed)
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
        // Each successful relay hand-off calls `markHandedToRelay` (idempotent:
        // first transitions queued -> handed; a terminal row refuses, the
        // writer's follow cannot resurrect it).
        let handed = currentPeers().reduce(into: 0) { count, peer in
            if send(frame, peer) {
                count += 1
                deliveryTracker.markHandedToRelay(frame.msgId)
            }
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
        let handed = currentPeers().reduce(into: 0) { count, peer in
            if send(frame, peer) {
                count += 1
                deliveryTracker.markHandedToRelay(msgId)
            }
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
        let outcome = deliveryTracker.cancelSosBroadcast(msgId)
        sosRowLock.lock()
        if let seen = sosRowMemory, seen.msgId == msgId { sosRowMemory = nil }
        sosRowLock.unlock()
        publishSosMirrorFromMemory()
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
    /// Each successful relay hand-off calls `deliveryTracker.markHandedToRelay`
    /// (advancing QUEUED_DURABLY -> HANDED_TO_RELAY; never ACKNOWLEDGED_BY_RECIPIENT).
    @discardableResult
    internal func dispatchDirect(
        _ frame: FrameV2,
        expectedRecipient: Data,
        send: (FrameV2, UUID) -> Bool
    ) -> DirectDispatchResult {
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

        let handed = currentPeers().reduce(into: 0) { count, peer in
            if send(canonicalFrame, peer) {
                count += 1
                deliveryTracker.markHandedToRelay(canonicalFrame.msgId)
            }
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
        if frame.type == .ack {
            switch deliveryTracker.acknowledge(frame.msgId, frame) {
            case .applied, .alreadyAcknowledged, .duplicateAuthenticatedAck:
                return true
            default:
                return false
            }
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

    public func transportReady(peerId: UUID) {
        // Deliberately no half-handshake. M2-link owns role election, real remote
        // hints, record types HS1/HS2/HS3, reassembly and timeouts.
    }

    public func transportDidDisconnect(peerId: UUID) {
        let count = handlePeerDisconnect(peerId)
        onPeerCountChanged?(count)
    }

    public func transportDidReceive(data: Data, peerId: UUID) {
        guard Self.linkLayerReady, let frame = decodeInbound(data) else { return }
        // Stage 4C / C7: route ACK frames to the delivery tracker, all other
        // frames to the epidemic router, via the ungated `ingestInbound` seam.
        // T24 (the `receivedFrom` carriage is the INTEGRATION slice, its own child
        // commit): the authenticated sender node_id is not in the v2 header (the
        // sealed sender liveth inside the encrypted payload) and the iOS BLE
        // transport exposeth onely a local peer UUID, not the remote node_id; the
        // real `receivedFrom` (the immutable TrustedPeer's node id) is wired when
        // the M2-link layer (ADR-002, Stage 4H) exposeth the authenticated peer
        // node_id. Until then an empty `receivedFrom` recordeth "sender not yet
        // identified" -- honest, and this path is unreachability while
        // linkLayerReady=false in any case.
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
