package io.godstone.mesh

import android.content.Context
import io.godstone.mesh.delivery.AckDispatch
import io.godstone.mesh.delivery.AckDispatcher
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.DeliveryLabel
import io.godstone.mesh.delivery.DeliveryProjection
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRecord
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.InboxCommitResult
import io.godstone.mesh.delivery.RecipientInboxRepository
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.DispatchVerdict
import io.godstone.mesh.router.FrameDispatcher
import io.godstone.mesh.router.InventorySnapshotAuthority
import io.godstone.mesh.router.Router
import io.godstone.mesh.router.SyncControlOwner
import io.godstone.mesh.router.SyncPump
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.TransportResult
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.transport.PowerState
import io.godstone.mesh.transport.WifiAwareTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.withContext
import io.godstone.mesh.delivery.DurableAckPump
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

data class MeshStatus(
    val started: Boolean = false,
    val peerCount: Int = 0,
    val activeSos: Boolean = false,
    val linkLayerReady: Boolean = false,
    val detail: String = LINK_LAYER_OPEN_REASON
)

sealed interface SosDispatchResult {
    data class Unavailable(val reason: String) : SosDispatchResult
    data object QueuedLocally : SosDispatchResult
    data object NotPersisted : SosDispatchResult
    data class HandedToRelays(val count: Int) : SosDispatchResult
    data class Failed(val reason: String) : SosDispatchResult
}

/** Typed outcome of a DIRECT outbound send dispatch (C6.6). */
sealed interface DirectDispatchResult {
    /** Handed to [count] connected relays. State advanced to HANDED_TO_RELAY. */
    data class HandedToRelays(val count: Int) : DirectDispatchResult
    /** Persisted and queued locally (0 connected relays). State remains QUEUED_DURABLY. */
    data object QueuedLocally : DirectDispatchResult
    /** Atomic enqueue was rejected; 0 sends attempted. */
    data class Rejected(val result: OutboundEnqueueResult) : DirectDispatchResult
}

const val LINK_LAYER_OPEN_REASON =
    "BLE record framing is implemented, but cross-platform link discovery, " +
    "role binding, trusted handshake integration, and on-device validation " +
    "remain incomplete. Radio transmission is disabled in this pre-alpha build."

/**
 * Process-wide composition root for the mesh subsystem.
 *
 * There is exactly one instance, supplied by Hilt to the application, service,
 * screens, router and session registry. V3's separate service-locator instance
 * was deleted because it split peer state and SOS state across two object graphs.
 *
 * Stage 4C / C6-C7: the identity is INJECTED (mirrors iOS
 * `MeshNode(identity:store:deliveryTracker:)`), not loaded lazily from the
 * Context, so the SOS dispatch + inbound-ACK seams are unit-testable in pure
 * JVM (`:mesh:testDebugUnitTest` has no Robolectric/Android Context). The
 * production constructor below still loads the identity from the Context, so
 * [di.MeshModule] (the only production construction site) is unchanged.
 */
class MeshNode(
    private val ctx: Context?,
    private val identity: Identity,
    private val store: MessageStore,
    /**
     * Durable, recipient-authenticated delivery state machine (ADR-005; A-03;
     * Stage 4C / C6.1; C6.3; C8.4B). Constructed by [di.MeshModule] from the SAME
     * `StoreDb` engine as `store`: a [io.godstone.mesh.delivery.SqliteDeliveryRepository]
     * is the durable record -- one row holds the delivery state, the ACK mode,
     * and the intended recipient, and an [io.godstone.mesh.delivery.Ed25519AckAuthenticator]
     * over [io.godstone.mesh.delivery.BoundRecipientKeyResolver] binds real recipient
     * keys with peer trust. The outbound path (C6) records the ACK mode (SOS is a
     * broadcast -> [AckMode.NONE], no recipient binding; a directed message is
     * [AckMode.SINGLE_RECIPIENT]) + advances state on a successful relay
     * hand-off; the inbound ACK path (C7) binds the ACK to the durable expected
     * recipient (authenticator invoked ONLY for SINGLE_RECIPIENT -- a NONE-mode
     * message can never be acknowledged). No delivery is claimed on host-only
     * evidence -- A-03 / ADR-005 stay OPEN.
     */
    internal val deliveryTracker: DeliveryTracker,
    val sessions: io.godstone.mesh.crypto.SessionManager,
) {
    /**
     * T37 (section 14): the recipient inbox transaction of the authenticated
     * link -- injectable and absent by default, so the relay/ACK-ingest
     * behaviour of every existing composition is preserved byte-for-byte.
     * When set, a sealed DIRECT MESSAGE additionally gets the local
     * destination attempt; its typed outcome never alters the relay decision
     * in [ingestInbound] (the router remains the relay truth), and an
     * accepted delivery's canonical recipient ACK is queued on the bounded
     * outbox for the trusted link's writer (the physical pump is T54/T73-T75
     * territory; the production wiring point is the lab composition root).
     */
    internal var recipientInbox: RecipientInboxRepository? = null

    /**
     * T84 (section 14, the durable ACK return path): the ACK dispatcher. Bound
     * by the composition that OWNETH the ack_frames namespace -- the same
     * authority that binds [recipientInbox] -- and absent by default, so the
     * historical point-to-point face below standeth byte-for-byte for every
     * composition that carrieth no such namespace.
     *
     * With it bound, an inbound ACK is classified BEFORE any generic message
     * TTL/dedup/store handling: a durable delivery row maketh it ORIGIN
     * verification (the only road to DELIVERED), and the ABSENCE of one maketh
     * it RELAY TRAFFIC to be carried home, rather than the UnknownMessage
     * discard that loseth every multihop receipt.
     */
    internal var ackDispatcher: AckDispatcher? = null

    // ================== GS-RUNTIME-001 steps 3-4 on THIS isle: THE BOUNDED ACK WORKER ==================
    //
    // MEASURED BEFORE THIS: nothing on this isle collected `BleTransport.applicationLinkReady()` (round 209: the
    // declaration and NOT ONE COLLECTOR), and the node held no pump. **AND TWO MEASURED SIMPLIFICATIONS STAND HERE
    // BESIDE THE SWIFT TWIN: this isle's transport is keyed by NODE ID and TAKES BYTES
    // (`send(peerId: ByteArray, bytes: ByteArray)`), so a relay copy needeth NO handle mapping and NO decode --
    // the canonical bytes travel as they stand.**

    internal var ackPump: DurableAckPump? = null
    private var ackTurnsRun = 0
    private var ackEventWakes = 0
    internal fun ackTurnsRunForTest(): Int = ackTurnsRun
    internal fun ackEventWakesForTest(): Int = ackEventWakes

    /** ONE BOUNDED TURN FOR ONE NAMED RELATION, handed through the SAME authenticated transport. */
    internal suspend fun drainAckWorkOnce(nodeId: ByteArray): Int? {
        val pump = ackPump ?: return null
        val batch = pump.nextBatch(nodeId)
        var handed = 0
        for (copy in batch.copies) {
            val verdict = ble.send(nodeId, copy.encodedFrame)
            val accepted = verdict is TransportResult.Admitted
            pump.onForwardOutcome(copy, nodeId, accepted)
            if (accepted) handed++
        }
        return handed
    }

    /** ONE BOUNDED TURN FOR EVERY RELATION THE PUMP HATH SCHEDULED -- the deadline's own work. */
    internal suspend fun runAckTurnForEveryTrustedRelation(scheduled: List<ByteArray>): Int {
        var handed = 0
        for (nodeId in scheduled) handed += (drainAckWorkOnce(nodeId) ?: 0)
        ackTurnsRun++
        return handed
    }

    /**
     * **THE READINESS SUBSCRIPTION.** A collector on the transport's own readiness flow schedu1eth the bounded
     * worker for THE EXACT RELATION it nameth -- and an untrusted or unknown relation is NOT served, because the
     * pump schedulleth only what it is told and nothing is guessed.
     */
    internal fun subscribeToReadiness(scope: CoroutineScope, intervalMillis: Long? = null) {
        scope.launch {
            ble.applicationLinkReady().collect { nodeId ->
                ackPump?.onLinkReady(nodeId)
                ackEventWakes++
                drainAckWorkOnce(nodeId)
            }
        }
        if (intervalMillis != null) {
            scope.launch {
                while (true) {
                    delay(intervalMillis)
                    ackPump?.let { pump -> runAckTurnForEveryTrustedRelation(pump.scheduledPeersForTest()) }
                }
            }
        }
    }

    /**
     * T43: the EPHEMERAL ledger of local link admissions. A Boolean `send`
     * provecth only that a radio accepted some bytes -- never that a relay holdeth
     * them and never that a recipient received them -- so it is recorded HERE, in
     * memory, and the durable delivery row is left alone. A restart forgetteth
     * every offer, which is exactly why no custody label may rest on one.
     */
    internal val linkOffers = io.godstone.mesh.delivery.LinkOfferLedger()

    /** T43: the honest label a consumer may read for [msgId]. */
    internal fun deliveryProjection(msgId: ByteArray): DeliveryProjection =
        when (val lookup = deliveryTracker.lookup(msgId)) {
            is DeliveryLookup.Found -> DeliveryProjection.of(
                msgId, lookup.record.state,
                linkOffers = linkOffers.admittedCountFor(msgId),
                refusedOffers = linkOffers.refusedCountFor(msgId),
                lastOfferMonoMillis = linkOffers.lastOfferMonoFor(msgId),
            )
            // a corrupt or unreadable row is never labelled queued (fail closed)
            else -> DeliveryProjection.unavailable(msgId)
        }

    /**
     * T41 (section 14): the per-TrustedPeer bounded sync pump -- the scheduler and
     * forwarder whose absence left an Android node receiving and persisting frames
     * without ever connecting them into a complete peer sync/forward road. It is
     * ACTIVE by default; the seam existeth so a court may inject its own.
     */
    internal var syncPump: SyncPump? = null

    private val defaultSyncPump: SyncPump by lazy {
        SyncPump(syncControlOwner, store, router, controlClock)
    }

    /** The pump in force: the injected one, else the default (never null). */
    internal fun pumpFor(): SyncPump = syncPump ?: defaultSyncPump

    private val frameDispatcher: FrameDispatcher by lazy {
        FrameDispatcher(syncControlOwner, { ackDispatcher }) { frame ->
            deliveryTracker.acknowledge(frame.msgId, frame)
        }
    }

    /** T38: the signed-SOS authority seam. Absent by default -- dispatch then
     * keeps emitting the legacy structural shape (documented, and refused by
     * the receiver's runtime authentication exactly as section 15 demands).
     * The T54 lab composition root binds this to the durable identity. */
    internal var sosAuthority: io.godstone.mesh.wire.v2.SosSigningAuthority? = null

    /** T38: consumers of authenticated distress indications only. An
     * unauthenticated frame never reaches an observer; no trust or approval
     * state moves on this path (that is the peer directory's own layer). */
    internal var sosObserver: io.godstone.mesh.wire.v2.SosObserver? = null

    /** T40 (ADR-009): the per-relation sync/control owner and its snapshot
     * authority. Internal and settable so the readiness court can drive the
     * pump with an injected monotonic clock; the production default reads the
     * node's own monotonic nanosecond clock. The owner consumes the link
     * controls at the ingress demultiplex and nothing else does; T41 wires
     * the outbound pump onto this same instance. */
    internal var controlClock: () -> Long = { System.nanoTime() / 1_000_000L }
    internal var snapshotAuthority: InventorySnapshotAuthority =
        InventorySnapshotAuthority(store, controlClock)
    internal var syncControlOwner: SyncControlOwner =
        SyncControlOwner(store, snapshotAuthority, controlClock, identity.nodeId)

    /** The owner's last decision -- the observation face of the courts. */
    internal var lastControlDecision: SyncControlOwner.OwnerDecision =
        SyncControlOwner.OwnerDecision.Accepted
        private set

    /**
     * GS-SYNC-002: a control reply with the DESTINATION it belongeth to. The outbox used to hold
     * BARE frames, so an answer raised for one relation was handed to whichever peer asked first --
     * the requesting peer went unanswered and two reconciliation runs were mixed.
     */
    private class ControlReply(
        val destination: ByteArray,
        val frame: io.godstone.mesh.wire.v2.FrameV2,
        /** GS-SYNC-002 step 3: the RELATION this answer was raised for. A relation that was RETIRED
         *  (the peer was lost) hath its epoch retired with it, so the answer cannot be handed to the
         *  relation that REPLACED it when the same peer returneth. */
        val relationEpoch: Long,
    )

    /**
     * GS-SYNC-002 (the audit's ordered step 3): per-peer RELATION epochs. An epoch is created when a peer's
     * relation is first spoken of and RETIRED when the relation is lost, so a reconnect produceth a DIFFERENT
     * epoch and every answer raised under the old one is stale-by-construction. A peer that never had a
     * relation event keepeth one epoch for the life of the node, so nothing that never lost a relation can be
     * affected by this rule.
     */
    private val relationEpochs = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val relationEpochSeq = java.util.concurrent.atomic.AtomicLong(0)

    private fun currentRelationEpoch(peerId: ByteArray): Long =
        relationEpochs.computeIfAbsent(leaseKey(peerId)) { relationEpochSeq.incrementAndGet() }

    /** GS-SYNC-002 step 3: a LOST relation retireth its epoch, so its queued answers are stale from here. */
    private fun retireRelationEpoch(peerId: ByteArray) {
        relationEpochs.remove(leaseKey(peerId))
    }

    /**
     * GS-SOS-002: the per-message DISPATCH LEASE. Minted when an offer loop beginneth, INVALIDATED by a
     * successful cancellation (which retireth the durable row), and consulted BEFORE EVERY offer -- so
     * captured local work cannot be newly offered after the row was retired. A lease that no longer
     * standeth STOPPETH the loop.
     */
    private val dispatchLeases = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val dispatchLeaseSeq = java.util.concurrent.atomic.AtomicLong(0)

    /**
     * GS-SOS-002 (the audit's step 2, the DURABLE half): the message must still be DISPATCHABLE by
     * DURABLE TRUTH before the next offer -- so a cancellation committed by ANY path (not merely through
     * this node's command door) suppresseth the offers not yet made. An absent, corrupt, invalid, or
     * UNREADABLE row STOPPETH the loop: fail-closed, never a skip.
     */
    private fun sosStillDispatchableByDurableTruth(msgId: ByteArray): Boolean =
        when (val row = deliveryTracker.lookup(msgId)) {
            // a row that standeth but hath reached a TERMINAL state (cancelled, expired, acknowledged)
            // is no longer dispatchable: the durable terminal CAS keepeth the row, so PRESENCE alone
            // would not suppress the later offer
            is io.godstone.mesh.delivery.DeliveryLookup.Found -> !row.record.state.isTerminal
            else -> false
        }

    /** GS-SOS-002: a stable key for one message id (the lease map's key). */
    private fun leaseKey(msgId: ByteArray): String =
        msgId.joinToString("") { b -> "%02x".format(b) }

    private fun mintDispatchLease(msgId: ByteArray): Long {
        val token = dispatchLeaseSeq.incrementAndGet()
        dispatchLeases[leaseKey(msgId)] = token
        return token
    }

    /** GS-SOS-002: the lease standeth only while NO successful cancellation hath retired the message. */
    private fun dispatchLeaseStands(msgId: ByteArray, lease: Long): Boolean =
        dispatchLeases[leaseKey(msgId)] == lease

    /** GS-SOS-002: a SUCCESSFUL cancellation invalidateth the message's dispatch lease. */
    private fun invalidateDispatchLease(msgId: ByteArray) {
        dispatchLeases.remove(leaseKey(msgId))
    }

    private val controlOutbox = ArrayList<ControlReply>()
    private val controlOutboxLock = Any()

    /** GS-SYNC-002 step 4: the PER-DESTINATION bound beside the aggregate 64. Internal so the court can
     *  read the production value rather than mirror a literal. */
    internal val MAX_CONTROL_REPLIES_PER_DESTINATION: Int = 16

    /** Bounded at 64 in AGGREGATE and per destination; drop-oldest, the freshest truth wins the slot. */
    private fun offerControlFrames(
        frames: List<io.godstone.mesh.wire.v2.FrameV2>,
        destination: ByteArray,
    ) = synchronized(controlOutboxLock) {
        val epoch = currentRelationEpoch(destination)
        for (f in frames) {
            // GS-SYNC-002 (the audit's ordered step 4): the AGGREGATE bound, unchanged...
            if (controlOutbox.size >= 64) controlOutbox.removeAt(0)
            // ...and the PER-DESTINATION bound BESIDE it, so no single destination can hold the whole
            // budget. Drop-oldest in both, the T37 idiom: the freshest truth wins the slot. This is a
            // FAIRNESS/telemetry bound, not a memory one -- the aggregate cap already bounds memory, and
            // drop-oldest already meaneth a flood cannot deny a LATER reply its admission, which is why the
            // arm asserteth the BOUND and makes no starvation claim.
            if (controlOutbox.count { it.destination.contentEquals(destination) } >=
                MAX_CONTROL_REPLIES_PER_DESTINATION
            ) {
                val oldestMine = controlOutbox.indexOfFirst { it.destination.contentEquals(destination) }
                if (oldestMine >= 0) controlOutbox.removeAt(oldestMine)
            }
            // GS-SYNC-002 step 3: the answer is stamped with the RELATION it belongeth to.
            controlOutbox.add(ControlReply(destination.copyOf(), f, epoch))
        }
    }

    /**
     * GS-SYNC-002: drain ONLY the replies that belong to [peer]; every other live peer's answer is
     * PRESERVED. Ownership is by destination, so one peer's turn can never consume another's answer
     * and two reconciliation runs are never mixed.
     */
    private fun drainControlOutboxFor(peer: ByteArray): List<io.godstone.mesh.wire.v2.FrameV2> =
        synchronized(controlOutboxLock) {
            // GS-SYNC-002 (the audit's ordered step 3): ownership is by destination AND RELATION. An answer
            // raised under a RETIRED relation is dropped here, never handed to the replacement relation --
            // the frame is refuse-and-forget, because a stale reply is not work for the new relation.
            val current = currentRelationEpoch(peer)
            val mine = controlOutbox.filter { it.destination.contentEquals(peer) }
            if (mine.isNotEmpty()) controlOutbox.removeAll { it.destination.contentEquals(peer) }
            mine.filter { it.relationEpoch == current }.map { it.frame }
        }

    /** Drain the bounded control outbox (T41's pump takes the route from here). GS-SYNC-002 step 3: an
     *  entry whose relation was retired while it waited is DROPPED, not delivered. */
    internal fun drainControlOutbox(): List<io.godstone.mesh.wire.v2.FrameV2> = synchronized(controlOutboxLock) {
        val out = controlOutbox
            .filter { it.relationEpoch == currentRelationEpoch(it.destination) }
            .map { it.frame }
        controlOutbox.clear()
        out
    }

    /** One ingress control frame: the owner decides; any answer rides back out. */
    internal suspend fun handleControlFrame(frame: io.godstone.mesh.wire.v2.FrameV2, fromPeer: ByteArray): Boolean {
        val verdict = frameDispatcher.dispatch(frame, fromPeer)
        if (verdict !is DispatchVerdict.Control) return false
        lastControlDecision = verdict.decision
        val replies = frameDispatcher.replies(verdict.decision)
        if (replies.isNotEmpty()) offerControlFrames(replies, destination = fromPeer)
        return verdict.accepted
    }
    /**
     * Pure JVM test convenience constructor: builds a fail-closed SessionManager from the SAME [identity].
     */
    internal constructor(ctx: Context?, identity: Identity, store: MessageStore, deliveryTracker: DeliveryTracker)
        : this(ctx, identity, store, deliveryTracker, io.godstone.mesh.crypto.SessionManager(
            identity = identity,
            trustAuthority = object : io.godstone.mesh.crypto.PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: io.godstone.mesh.identity.ValidatedPeerBinding): io.godstone.mesh.identity.PeerTrustApplyResult =
                    io.godstone.mesh.identity.PeerTrustApplyResult.StorageFailure()
            }
        ))

    internal val router: Router by lazy { Router(store, identity.nodeId) }
    private val ble: BleTransport by lazy {
        // ctx is non-null in production; null only in pure-JVM tests
        // that never start the node and so never reach the transports.
        BleTransport(
            context = ctx!!,
            identity = identity,
            digestProvider = { router.currentDigest() },
            sessions = sessions,
            store = store
        )
    }
    private val wifi: WifiAwareTransport by lazy { WifiAwareTransport(ctx!!) }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _nightMode = MutableStateFlow(false)
    val nightModeFlow: StateFlow<Boolean> = _nightMode.asStateFlow()

    private val _status = MutableStateFlow(MeshStatus())
    val statusFlow: StateFlow<MeshStatus> = _status.asStateFlow()

    @Volatile private var isStarted = false
    private val peerLock = Any()
    private val peers = LinkedHashMap<String, ByteArray>()

    private fun ByteArray.toHexKey(): String = joinToString("") { "%02x".format(it) }

    fun ensureIdentity() { identity.nodeId }
    fun onAppForegrounded() { if (isStarted) setPowerState(PowerState.NORMAL) }
    fun onAppBackgrounded() { if (isStarted) setPowerState(PowerState.POWER_SAVE) }
    fun setPowerState(state: PowerState) { if (isStarted) ble.setPowerState(state) }

    internal fun canStart(linkReady: Boolean): Boolean =
        linkReady && sessions.isActive

    /**
     * Start only after M1-wire and M2-link are implemented and verified and runtime is active.
     * A non-functional encrypted transport must never silently fall back to
     * plaintext or consume battery while the UI calls it active.
     */
    fun start(): Boolean {
        if (!canStart(LINK_LAYER_READY)) {
            _status.value = MeshStatus(detail = LINK_LAYER_OPEN_REASON)
            return false
        }
        synchronized(peerLock) {
            if (isStarted) return true
            isStarted = true
        }
        // T24 (section 6, "observers/flow emissions can ... lose authoritative
        // events"): the consumers of peer-presence and inbound traffic are
        // registered BEFORE the radio adapters are opened, so no event emitted
        // the instant the link wakes is lost in a window between open and
        // subscribe. The order is fixed by construction via startInOrder.
        startInOrder({ attachConsumers() }, { openAdapters() })
        // T39: after a cold restart the remembered projection is empty -- the flag
        // starts false rather than lie; the first [refreshSosStatusAfterScan] (or
        // any commit/cancel arm) re-derives it FROM the durable rows, which is how
        // "restart with active SOS" re-exposes a call the tables still carry.
        refreshSosStatusFromDurable()
        publishStatus()
        return true
    }

    /**
     * Fix the start ordering by construction: register the authoritative
     * consumers first, only then open the adapters. Both the production
     * [start] path and its witnesses funnel through this single decision
     * point, so the "consume-before-open" law holdeth wherever it is applied.
     */
    internal fun startInOrder(attach: () -> Unit, open: () -> Unit) {
        attach()
        open()
    }

    /** Subscribe the peer-presence and inbound-frame collectors to the transport. */
    private fun attachConsumers() {
        ble.peers().onEach { event -> handlePeerEvent(event) }.launchIn(scope)
        ble.received().onEach { (peer, clear) -> handleInboundFrame(peer, clear) }.launchIn(scope)
    }

    /** Open the radio adapters, once their consumers are already attached. */
    private fun openAdapters() {
        ble.start()
        if (wifi.isSupported) wifi.start()
    }

    /**
     * Apply one peer-presence event to the durable view, under the peer lock.
     * Extracted verbatim from the former peers() collector body (behaviour
     * preserved) so the consumer's substance is witnessed without a live
     * Android Context.
     */
    internal fun handlePeerEvent(event: PeerEvent) {
        synchronized(peerLock) {
            when (event) {
                is PeerEvent.Found -> peers[event.peerId.toHexKey()] = event.peerId
                is PeerEvent.Lost -> peers.remove(event.peerId.toHexKey())
            }
            publishStatus()
        }
        // GS-RUNTIME-001 step 3, THE ANDROID TWIN: **THE FAREWELL UNSCHEDULETH THAT EXACT RELATION.** MEASURED
        // BEFORE THIS: NOTHING CALLED `ackPump.onLinkGone` ON THIS ISLE, so a relation that went away STAYED
        // SCHEDULED and the worker would keep offering to a departed peer -- the same defect class the Swift twin
        // closed at round 218. **AND THE CALL STANDETH *OUTSIDE* THE `peerLock` BLOCK, WHERE MY FIRST DRAFT PUT IT:
        // a second lock taken inside the first is a nesting nobody asked for, and the pump's own lock needeth no
        // company.**
        if (event is PeerEvent.Lost) ackPump?.onLinkGone(event.peerId)
        // T41: a peer that became present must have a REGISTERED sync relation, or
        // no DIGEST is ever scheduled and its held set never reconciles; a peer
        // that went away must have its relation cancelled (the run state and the
        // snapshot leases release; the durable estate stays). Called OUTSIDE the
        // peer lock: the pump owneth its own monitor and never nesteth one.
        when (event) {
            is PeerEvent.Found -> pumpFor().register(event.peerId)
            is PeerEvent.Lost -> {
                pumpFor().cancel(event.peerId)
                // GS-SYNC-002 step 3: the RELATION is gone, so its epoch is retired with it and every
                // answer it queued becometh stale-by-construction rather than inheritable by the next one.
                retireRelationEpoch(event.peerId)
            }
        }
    }

    /**
     * T41: one bounded sync/forward turn for [peer] -- the link writer's source.
     * Control (DIGEST / inventory / WANT) first, then the frames the peer asked
     * for (fetched from the durable held set), then the epidemic forwards. A peer
     * with no registered relation yields nothing.
     */
    internal suspend fun drainSyncFramesForPeer(peer: ByteArray): List<io.godstone.mesh.wire.v2.FrameV2> {
        // The owner's answers (a WANT's served frames, an inventory page, a PING
        // reply) ride the control outbox T40 built; the pump addeth the schedule
        // and the epidemic forward copies. ONE call for the link writer, so no
        // caller has to remember two sources.
        val out = ArrayList<io.godstone.mesh.wire.v2.FrameV2>(drainControlOutboxFor(peer))
        out.addAll(pumpFor().pump(peer).frames)
        return out
    }

    /**
     * Decode an inbound clear, fail-closed: null on any desync/magic/version/
     * CRC/length error. Pure and non-suspend, so the fail-closed gate is
     * witnessed without a coroutine; the collector ingests onely when this
     * yieldeth a frame.
     */
    internal fun decodeInbound(clear: ByteArray): io.godstone.mesh.wire.v2.FrameV2? =
        runCatching { io.godstone.mesh.wire.v2.FrameV2.decode(clear) }.getOrNull()

    /**
     * Decode and ingest one inbound clear, fail-closed. A null decode is dropt
     * (reported as false) and naught is ingested; a decoded frame goeth to
     * [ingestInbound], which routeth ACK frames to the delivery tracker (C7) and
     * every other type to the epidemic router. Extracted from the former
     * received() collector body (behaviour preserved; ingests in the collector's
     * suspend context).
     */
    internal suspend fun handleInboundFrame(fromPeer: ByteArray, clear: ByteArray): Boolean {
        val frame = decodeInbound(clear) ?: return false
        return ingestInbound(frame, fromPeer)
    }

    /** The hex keys of the peers currently held in the durable view (witnesses only). */
    internal fun knownPeersForTest(): Set<String> = synchronized(peerLock) { peers.keys.toSet() }

    fun stop() {
        // GS-RUNTIME-001 step 6 on THIS isle: **THE WORKERS ARE CANCELLED *BEFORE* THE `isStarted` GUARD.** A
        // worker armed by the runtime must not outlive it EVEN WHEN THE NODE WAS NEVER STARTED -- and in this
        // shipping tree `isStarted` is FALSE by construction (the link-layer flag is frozen off), so a cancel
        // placed after the guard would leave the readiness collectors alive for ever. THE SWIFT TWIN LEARNED THIS
        // FROM ITS OWN WITNESS (round 220: the turn census climbed from 2 to 7 AFTER `stop()`), and this isle
        // carrieth the same early return.
        scope.coroutineContext.cancelChildren()
        synchronized(peerLock) {
            if (!isStarted) return
            isStarted = false
        }
        sessions.destroyAll()
        ble.stop()
        wifi.stop()
        synchronized(peerLock) { peers.clear() }
        publishStatus()
    }

    fun hasActiveSos(): Boolean = _status.value.activeSos

    // ---- T39 (section 14): the one durable authority for the SOS lifecycle ----
    //
    // The commands below never mutate authoritative state on a validation
    // failure; every result is typed so that failure is distinguishable from
    // the idempotent no-op (C6.4-A/J law, applied to the broadcast path).

    @Volatile
    private var activeSosRow: ActiveSos? = null

    /**
     * T39: resume the SAME authored bytes of a still-live broadcast call. The
     * held frame is read back from the durable authority and re-handed to the
     * relays verbatim -- no re-derivation, no fresh seal: the msg_id is immutable
     * content and a retry that re-authored would betray it. A terminal row
     * (cancelled, expired, acknowledged) refuses the resume; a vanished frame or
     * row fails typed, never masquerading as an empty success.
     */
    internal suspend fun retrySos(
        msgId: ByteArray,
        send: suspend (peerId: ByteArray, bytes: ByteArray) -> Boolean,
    ): SosDispatchResult {
        if (msgId.size != 16) return SosDispatchResult.Failed("retry: msg_id must be 16 bytes")
        val row: DeliveryRecord = when (val l = deliveryTracker.lookup(msgId)) {
            is DeliveryLookup.Found -> l.record
            DeliveryLookup.NotFound ->
                return SosDispatchResult.Failed("retry: no durable row for this msg_id")
            DeliveryLookup.Corrupt ->
                return SosDispatchResult.Failed("retry: corrupt delivery row")
            DeliveryLookup.StorageFailure ->
                return SosDispatchResult.Failed("retry: storage failure reading the row")
            DeliveryLookup.InvalidArgument ->
                return SosDispatchResult.Failed("retry: invalid msg_id")
        }
        if (row.ackMode != AckMode.NONE)
            return SosDispatchResult.Failed("retry: not a broadcast row")
        when (row.state) {
            // T43: HANDED_TO_RELAY is a LEGACY label a pre-T43 row may still
            // carry (the migration rewriteth it); it is read here as the queued,
            // retryable estate it always was -- never as custody.
            DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY -> Unit
            else -> return SosDispatchResult.Failed(
                "retry: obligation already terminal (" + row.state + ")",
            )
        }
        val frame = store.allHeldOrderedByPriority().firstOrNull {
            it.msgId.contentEquals(msgId) && it.type == io.godstone.mesh.wire.v2.TypeV2.SOS
        } ?: return SosDispatchResult.Failed("retry: no held frame to resume")
        val bytes = frame.encode()
        var handed = 0
        val dispatchLease = mintDispatchLease(msgId)
        var offersAttempted = 0
        for (peerId in knownPeers()) {
            // GS-SOS-002: the lease is re-checked BEFORE every offer, so a cancellation committed
            // inside a send callback suppresseth the offers not yet made. Durable truth is consulted
            // only from the SECOND offer on, because this path may not have committed its row yet.
            if (!dispatchLeaseStands(msgId, dispatchLease)) break
            if (offersAttempted > 0 && !sosStillDispatchableByDurableTruth(msgId)) break
            offersAttempted++
            val admitted = send(peerId, bytes)
            // T43: a LINK OFFER, not a custody claim. The durable row is NOT
            // advanced -- it standeth QUEUED_DURABLY until an intended
            // recipient's authenticated ACK moveth it.
            linkOffers.record(msgId, peerId, admitted, controlClock())
            if (admitted) handed++
        }
        // GS-SOS-002 (the audit's ordered step 6): the projection is re-derived from the DURABLE ROW,
        // never from the frame captured before the offer loop -- a cancellation that landed mid-dispatch
        // must not be re-lit as an active call. ONE law with the iOS twin's `rememberSosCommit`.
        rememberSosCommit(frame, activeSosRow?.committedAtMillis)
        return if (handed == 0) SosDispatchResult.QueuedLocally
        else SosDispatchResult.HandedToRelays(handed)
    }

    /**
     * T39: cancel one broadcast call DURABLY -- the guarded terminal CAS on the
     * row plus the retirement of the scheduled/held work, in the authority's one
     * transaction. Already relayed copies cannot be recalled: the result carries
     * the truth of whether any had gone out ([SosCancelResult.Cancelled.wasRelayed])
     * so the UI can say so too. Duplicate cancellation is the idempotent
     * [SosCancelResult.AlreadyCancelled], never an error; a directed obligation
     * is [SosCancelResult.NotBroadcast] and stands untouched.
     */
    internal suspend fun cancelSos(msgId: ByteArray): SosCancelResult {
        val result = deliveryTracker.cancelSosBroadcast(msgId)
        // GS-SOS-002: a SUCCESSFUL cancellation retireth the message's dispatch lease, so an offer
        // loop already iterating cannot newly offer a call whose durable row was just retired.
        if (result is SosCancelResult.Cancelled) invalidateDispatchLease(msgId)
        if (activeSosRow?.msgId?.contentEquals(msgId) == true) activeSosRow = null
        refreshSosStatusFromDurable()
        // T43: "wasRelayed" meaneth "copies MAY be out", and the only honest
        // source for that is the EPHEMERAL link-offer ledger -- a durable row no
        // longer carrieth a relayed flag, because a local ATT admission was never
        // custody. A pre-T43 row that still carrieth the legacy label keepeth its
        // own answer (the tracker's), and an offer that was ADMITTED upgrades a
        // false to the truthful "some bytes left this device".
        if (result is SosCancelResult.Cancelled && !result.wasRelayed &&
            linkOffers.anyAdmitted(msgId)
        ) {
            return SosCancelResult.Cancelled(wasRelayed = true)
        }
        return result
    }

    /**
     * T39: the command surface. Author runs the established dispatch arm
     * (returns the same [SosDispatchResult] taxonomy the sealed courts speak);
     * Retry resumes the same bytes; Cancel retires durably. One entry point,
     * three honest outcomes -- no arm reports a success it did not achieve.
     */
    internal suspend fun handleSosCommand(
        command: SosCommand,
        send: suspend (peerId: ByteArray, bytes: ByteArray) -> Boolean,
    ): SosCommandResult = when (command) {
        is SosCommand.Author -> SosCommandResult.Enqueued(dispatchSos(command.payload, send))
        is SosCommand.Retry -> SosCommandResult.Enqueued(retrySos(command.msgId, send))
        is SosCommand.Cancel -> SosCommandResult.Cancelled(cancelSos(command.msgId))
    }

    /**
     * T39: the durable Active-SOS projection, read FROM the delivery row joined
     * with the held frame -- never from a UI memory. A call counts active while
     * its row is NONE-mode and QUEUED_DURABLY or HANDED_TO_RELAY and its frame
     * is still held; terminal rows (cancelled, expired) are not active. After a
     * restart the very same scan re-exposes what the tables still carry, which
     * is what the plain UI flag could never promise. Broadcast shows the local
     * queue only: nothing here claims recipient-delivered or guaranteed rescue.
     */
    internal suspend fun activeSosSnapshot(): ActiveSos? {
        for (frame in store.allHeldOrderedByPriority()) {
            if (frame.type != io.godstone.mesh.wire.v2.TypeV2.SOS) continue
            val row = when (val l = deliveryTracker.lookup(frame.msgId)) {
                is DeliveryLookup.Found -> l.record
                else -> continue
            }
            if (row.ackMode != AckMode.NONE) continue
            // T43: the legacy label is tolerated on READ (it is queued in truth)
            if (row.state != DeliveryState.QUEUED_DURABLY &&
                row.state != DeliveryState.HANDED_TO_RELAY
            ) continue
            val remembered = if (activeSosRow?.msgId?.contentEquals(frame.msgId) == true)
                activeSosRow?.committedAtMillis else null
            val seen = ActiveSos(frame.msgId.copyOf(), row.state, frame, remembered)
            activeSosRow = seen
            return seen
        }
        activeSosRow = null
        return null
    }

    /** The last projection this node published through its own arms (may be
     *  stale across a restart; [activeSosSnapshot] re-derives it from the
     *  tables). */
    internal fun lastKnownActiveSos(): ActiveSos? = activeSosRow

    /** Re-publish the observable flag from the remembered projection. Cheap,
     *  idempotent, non-suspending: the flag only ever says what the durable row
     *  said last time this node looked. */
    internal fun refreshSosStatusFromDurable() {
        _status.value = _status.value.copy(activeSos = activeSosRow != null)
    }

    /**
     * GS-SOS-002 (the audit's ordered step 6): remember the projection this node committed by reading the
     * row back FROM the authority -- never from the frame captured before the offer loop, which a
     * cancellation landing mid-dispatch maketh stale. A row that is absent, unreadable, not NONE-mode or
     * terminal leaveth NO active projection: fail-closed, and the mirror goeth dark with it. The iOS twin
     * (`rememberSosCommit`) already read the row back; this isle published from its captured frame, so the
     * two isles disagreed until now.
     */
    private fun rememberSosCommit(
        frame: io.godstone.mesh.wire.v2.FrameV2,
        committedAtMillis: Long?,
    ) {
        val live = when (val row = deliveryTracker.lookup(frame.msgId)) {
            is io.godstone.mesh.delivery.DeliveryLookup.Found ->
                row.record
                    .takeIf {
                        it.ackMode == io.godstone.mesh.delivery.AckMode.NONE && !it.state.isTerminal
                    }
                    ?.state
            else -> null
        }
        activeSosRow = if (live == null) null
        else ActiveSos(frame.msgId.copyOf(), live, frame, committedAtMillis)
        refreshSosStatusFromDurable()
    }

    /** The authoritative route: scan the tables, re-derive the projection, and
     *  refresh the flag from what the store actually holds. This is what the
     *  restart cases exercise; it returns what it saw. */
    internal suspend fun refreshSosStatusAfterScan(): ActiveSos? {
        val seen = activeSosSnapshot()
        refreshSosStatusFromDurable()
        return seen
    }

    suspend fun broadcastSos(payload: ByteArray): SosDispatchResult = withContext(Dispatchers.IO) {
        if (!LINK_LAYER_READY) return@withContext SosDispatchResult.Unavailable(LINK_LAYER_OPEN_REASON)
        // try/catch (not runCatching) so the suspend dispatchSos call stays in the
        // coroutine body -- runCatching's lambda is non-suspend and cannot host it.
        try {
            dispatchSos(payload) { peerId, bytes -> ble.send(peerId, bytes) == TransportResult.Admitted }
        } catch (t: Throwable) {
            SosDispatchResult.Failed(t.message ?: "unknown mesh error")
        }
    }

    /**
     * Stage 4B.1 / Stage 4C C6 -- the SOS dispatch logic, ungated so it is
     * unit-testable without the link layer (mirrors iOS `dispatchSos`). Persists
     * BEFORE any transport operation: a SOS this node cannot durably hold is NOT
     * sent (zero sends) and reported `NotPersisted` so the UI does not lie.
     * `HELD_NEW` or `HELD_DUPLICATE` both mean durably held (a duplicate SOS was
     * already queued), so either proceeds to transport; only a capacity rejection
     * or storage failure exits before any BLE write. With durable success and
     * zero successful sends the SOS is `QueuedLocally` (it reaches a peer on the
     * next encounter via anti-entropy); with N successful sends,
     * `HandedToRelays(N)`.
     *
     * Stage 4C / C6.1: the delivery tracker is driven AFTER durable hold -- the
     * `enqueue` that records `QUEUED_DURABLY` runs only once `store.persist` has
     * succeeded (persist-before-tracker, extending the 4B.1 persist-before-forward
     * gate to the delivery state). SOS is a broadcast (no single intended
     * recipient), so it is enqueued with [AckMode.NONE] and no expected recipient
     * binding -- a NONE-mode message can NEVER be acknowledged via this tracker
     * (an inbound ACK for it yields [AckResult.NotAckEligible] and the
     * authenticator is not invoked). Each successful relay hand-off calls
     * an EPHEMERAL link offer (T43). The body is unreachable while
     * `LINK_LAYER_READY=false` via `broadcastSos`; tests drive it directly through
     * this seam.
     */
    internal suspend fun dispatchSos(
        payload: ByteArray,
        send: suspend (peerId: ByteArray, bytes: ByteArray) -> Boolean,
    ): SosDispatchResult {
        val authority = sosAuthority ?: return SosDispatchResult.Failed(
            "no SOS signing authority: an unauthenticated distress call may not be offered")
        val frame = authorSignedSos(authority, payload) ?: return SosDispatchResult.Failed(
            "the SOS signing authority yielded no signing material: refusing rather than offering " +
                "an unsigned distress call")
        // T39: the held frame AND its NONE-mode delivery row commit as ONE durable
        // pair (section 14's both-or-neither law for the broadcast path). The
        // repository is the authority: the shared SQL engine runs the pair in one
        // transaction, the store-backed repository writes both tables under the
        // store's one monitor, and a plain journal inherits the compatible
        // two-step route (persist, then record) the pre-T39 dispatch spoke --
        // its observable sequence of operations is byte-unchanged. A half-committed
        // pair is unnameable now: every rejection leaves no held orphan behind and
        // no orphan row, and the failure is reported typed, never fabled.
        when (val pair = deliveryTracker.enqueueSosOutbound(frame, identity.nodeId) {
                store.persist(frame, receivedFrom = identity.nodeId)
            }
        ) {
            is OutboundEnqueueResult.Created,
            is OutboundEnqueueResult.AlreadyQueuedSameBinding -> Unit
            OutboundEnqueueResult.RejectedCapacity,
            OutboundEnqueueResult.StorageFailure -> return SosDispatchResult.NotPersisted
            else -> return SosDispatchResult.Failed("delivery pair commit rejected: " + pair)
        }
        val bytes = frame.encode()
        var handed = 0
        val retryLease = mintDispatchLease(frame.msgId)
        var retryOffers = 0
        for (peerId in knownPeers()) {
            // GS-SOS-002: re-checked before every offer; durable truth from the SECOND offer on
            if (!dispatchLeaseStands(frame.msgId, retryLease)) break
            if (retryOffers > 0 && !sosStillDispatchableByDurableTruth(frame.msgId)) break
            retryOffers++
            val admitted = send(peerId, bytes)
            linkOffers.record(frame.msgId, peerId, admitted, controlClock())
            if (admitted) handed++
        }
        // T39 + T43: remember the projection this node committed, then publish the
        // observable flag FROM it -- the flag only says what the DURABLE row said.
        // A successful send is an ephemeral link offer, so the remembered state is
        // the row's own (QUEUED_DURABLY) whether or not a radio admitted the bytes:
        // the SOS row reacheth a terminal state only through cancellation or the
        // durable estate (a NONE-mode call can never be acknowledged).
        // GS-SOS-002 (step 6): read the row BACK, so a cancellation that raced this
        // dispatch leaveth no active projection behind.
        rememberSosCommit(frame, System.currentTimeMillis())
        return if (handed == 0) SosDispatchResult.QueuedLocally
        else SosDispatchResult.HandedToRelays(handed)
    }

    /** Author one signed SOS under the wired authority. GS-SOS-001 (both defects, rounds
     * 155-162): an authority that cannot yield canonical material -- no seed, no static DHCP
     * key, or NO ISSUED BINDING -- is a reason to REFUSE, and a null return meaneth
     * REFUSED: no frame is built, nothing is queued and nothing is offered. The structural
     * fallback and the private binding strike are both GONE from this path. */
    private fun authorSignedSos(
        authority: io.godstone.mesh.wire.v2.SosSigningAuthority,
        payload: ByteArray,
    ): io.godstone.mesh.wire.v2.FrameV2? {
        // GS-SOS-001: AN AUTHORITY THAT YIELDETH NO MATERIAL IS A REASON TO REFUSE, NEVER A REASON TO
        // SEND. The audited form returned `router.buildSos(payload)` here -- an UNSIGNED structural frame
        // which the dispatch road then queued and offered to relays; the audit's card sayeth so verbatim:
        // "missing signing authority still queues and offers an unauthenticated SOS." A null return now
        // meaneth REFUSED.
        val seed = authority.currentSigningSeed() ?: return null
        authority.currentStaticDhPublicKey() ?: return null
        // GS-SOS-001, SECOND DEFECT (round 163): THE BINDING COMETH FROM THE AUTHORITY, NEVER FROM A
        // PRIVATE RE-DERIVATION. `SignedSosV1.author` used to strike it here-adjacent from the seed and
        // generation it was handed, which is the issuance bypass `check_local_identity_controls`
        // refuseth by name. An authority that holdeth no binding is a reason to refuse, exactly as one
        // that holdeth no seed is.
        val binding = authority.currentIdentityBinding() ?: return null
        val nonce = authority.currentNonce()
        val clock = authority.currentTimeEpochSeconds()
        val quality = if (clock == 0L) io.godstone.mesh.wire.v2.TimeQuality.UNKNOWN
        else io.godstone.mesh.wire.v2.TimeQuality.USER_CONFIRMED
        return io.godstone.mesh.wire.v2.SignedSosV1.author(
            binding, seed, clock, quality, nonce, payload,
        )
    }

    /**
     * Stage 4C / C6.6 -- atomic DIRECT outbound enqueue and dispatch.
     *
     * In ONE transaction, persists [frame] in held_frames and creates the initial
     * delivery_state (QUEUED_DURABLY, SINGLE_RECIPIENT, [expectedRecipient]).
     * Only upon successful commit is the transport [send] callback invoked.
     *
     * Each successful relay hand-off records an EPHEMERAL link offer (T43): the
     * durable state standeth QUEUED_DURABLY and is advanced ONLY by an intended
     * recipient's authenticated ACK.
     */
    internal suspend fun dispatchDirect(
        frame: io.godstone.mesh.wire.v2.FrameV2,
        expectedRecipient: ByteArray,
        send: suspend (peerId: ByteArray, bytes: ByteArray) -> Boolean,
    ): DirectDispatchResult {
        val enqueueRes = store.enqueueDirectOutbound(frame, expectedRecipient, identity.nodeId)
        val canonicalFrame = when (enqueueRes) {
            is OutboundEnqueueResult.Created -> enqueueRes.canonicalFrame
            is OutboundEnqueueResult.AlreadyQueuedSameBinding -> enqueueRes.canonicalFrame
            else -> return DirectDispatchResult.Rejected(enqueueRes)
        }

        val bytes = canonicalFrame.encode()
        var handed = 0
        val directLease = mintDispatchLease(canonicalFrame.msgId)
        var directOffers = 0
        for (peerId in knownPeers()) {
            // GS-SOS-002: re-checked before every offer; durable truth from the SECOND offer on, because
            // THIS path commits its delivery row only after the offers are made.
            if (!dispatchLeaseStands(canonicalFrame.msgId, directLease)) break
            if (directOffers > 0 && !sosStillDispatchableByDurableTruth(canonicalFrame.msgId)) break
            directOffers++
            val admitted = send(peerId, bytes)
            linkOffers.record(canonicalFrame.msgId, peerId, admitted, controlClock())
            if (admitted) handed++
        }
        return if (handed == 0) DirectDispatchResult.QueuedLocally
        else DirectDispatchResult.HandedToRelays(handed)
    }

    /**
     * Stage 4C / C7 -- the inbound frame dispatch, ungated so it is unit-testable
     * without the link layer. An inbound ACK frame (TypeV2.ACK) is a point-to-
     * point delivery confirmation for a message THIS node sent, NOT epidemic
     * content to relay -- it goes to the [DeliveryTracker] (which binds it to the
     * durable expected recipient and advances the state only on cryptographic
     * proof). Every other frame type goes to the epidemic [Router] (persist +
     * relay offer). Mirrors iOS `ingestInbound`. The production authenticator is
     * fail-closed (UnresolvedRecipientKeyResolver), so no ACK verifies until
     * M2-link binds real recipient keys -- A-03 / ADR-005 stay OPEN.
     */
    internal suspend fun ingestInbound(
        frame: io.godstone.mesh.wire.v2.FrameV2,
        fromPeer: ByteArray,
    ): Boolean {
        // ACK -> point-to-point delivery confirmation (tracker.acknowledge returns
        // a typed AckResult); non-ACK -> epidemic router (returns whether the frame
        // was accepted for persist+relay). Mirrors iOS `ingestInbound -> Bool`.
        //
        // C6.1: only [AckResult.Applied] means "this ACK newly verified the
        // intended recipient". AlreadyAcknowledged / DuplicateAuthenticatedAck mean
        // the message was already terminal (idempotent accept -- NOT a new
        // verification; this path does NOT call onSosAcknowledgedByRecipient, so no
        // UI "delivered" claim is made from host-only evidence). Every other
        // AckResult (NotAckEligible / UnknownMessage / RejectedAuthentication /
        // RejectedState / StorageFailure / Corrupt) is a rejection.
        // T41: the dispatch statute is a TYPE now, in one place and in one order:
        // control -> ACK -> the generic durable road, and a refusal by name for
        // anything this profile carrieth not.
        when (val verdict = frameDispatcher.dispatch(frame, fromPeer)) {
            is DispatchVerdict.Control -> {
                lastControlDecision = verdict.decision
                val replies = frameDispatcher.replies(verdict.decision)
                if (replies.isNotEmpty()) offerControlFrames(replies, destination = fromPeer)
                return verdict.accepted
            }
            is DispatchVerdict.Ack -> {
                // GS-RUNTIME-001 step 4's LAST WAKE, THE ANDROID TWIN: **NEWLY COMMITTED FORWARD WORK WAKETH THE
                // WORKER.** An accepted ACK candidate IS new forward work -- it may have to travel onward -- and
                // the wake is gated on THE PUMP'S OWN SCHEDULE: a relation the runtime hath not declared ready is
                // NOT served, and nothing is guessed.
                if (verdict.accepted && ackPump?.isScheduled(fromPeer) == true) {
                    ackEventWakes++
                    scope.launch { drainAckWorkOnce(fromPeer) }
                }
                return verdict.accepted
            }
            is DispatchVerdict.Refused -> return false
            DispatchVerdict.Message, DispatchVerdict.Sos -> Unit   // the generic road below
        }
        // GS-RUNTIME-001 step 4's INBOUND WAKE, THE ANDROID TWIN: AN INBOUND REQUEST WAKETH THE WORKER FOR ITS OWN
        // RELATION -- gated on the pump's own schedule, so an unready relation is not served.
        if (ackPump?.isScheduled(fromPeer) == true) {
            ackEventWakes++
            scope.launch { drainAckWorkOnce(fromPeer) }
        }
        return run {
            val relay = router.onFrameReceived(frame, fromPeer)
            val inbox = recipientInbox
            if (inbox != null &&
                frame.type == io.godstone.mesh.wire.v2.TypeV2.MESSAGE &&
                (frame.flags and io.godstone.mesh.wire.v2.FrameV2.SEALED) != 0
            ) {
                // T37: the local destination attempt rides beside the relay -- it
                // decides nothing about forwarding (the router's decision above
                // stands untouched) and only queues an accepted delivery's
                // canonical ACK for the link's writer.
                // try/catch (not runCatching): the suspend accept must stay in
                // the coroutine body; a receiver fault must never escape the
                // collector and must never touch the relay decision below.
                val accepted = try {
                    inbox.acceptVerifiedAndRequireAck(frame, fromPeer)
                } catch (_: Throwable) {
                    null
                }
                val ack = when (accepted) {
                    is InboxCommitResult.New -> accepted.ack
                    is InboxCommitResult.Duplicate -> accepted.ack
                    else -> null
                }
                if (ack != null) offerAckForLink(ack)
            }
            if (frame.type == io.godstone.mesh.wire.v2.TypeV2.SOS) {
                val observer = sosObserver
                if (observer != null) {
                    // T38: the distress indication is announced only to consumers
                    // of an authenticated key binding. The relay decision above was
                    // computed FIRST and stands untouched -- refusing to
                    // authenticate is a verdict about the INDICATION, never about
                    // the frame's epidemic duty.
                    val result = try {
                        io.godstone.mesh.wire.v2.SignedSosV1.verify(frame, null)
                    } catch (_: Throwable) {
                        null
                    }
                    when {
                        result is io.godstone.mesh.wire.v2.SosAuthResult.Authenticated ->
                            observer.onSosAuthenticated(result.verified)
                        result is io.godstone.mesh.wire.v2.SosAuthResult.Unauthenticated ->
                            observer.onSosUnauthenticated(frame, result.reason)
                        result == null -> observer.onSosUnauthenticated(
                            frame, io.godstone.mesh.wire.v2.SignedSosV1.Reason.MALFORMED)
                    }
                }
            }
            // T41: FORWARD ONLY AFTER DURABLE ACCEPTANCE. `relay` is true exactly
            // when the router accepted the frame for persist+relay, i.e. the store
            // committed it; the copy is prepared once (TTL-1 / hop+1) and queued
            // for every registered TrustedPeer except the one it arrived from.
            if (relay) pumpFor().enqueueForward(frame, fromPeer)
            relay
        }
    }

    private fun knownPeers(): List<ByteArray> = synchronized(peerLock) { peers.values.toList() }

    // ------------------------------------------------------------------ T37 ACK outbox
    // Runtime scheduling only -- the durable truth of a recipient ACK is the
    // ack_frames row filed inside the repository's pair step. Drop-oldest keeps
    // the bound honest under flood: the freshest canonical answer wins the
    // single slot, the elder is superseded by the durable row's re-read path.

    private val ackOutboxLock = Any()
    private val ackOutbox = ArrayDeque<io.godstone.mesh.wire.v2.FrameV2>()

    /** Queue one canonical recipient ACK for the trusted link's writer. */
    internal fun offerAckForLink(ack: io.godstone.mesh.wire.v2.FrameV2): Boolean = synchronized(ackOutboxLock) {
        while (ackOutbox.size >= MAX_OUTBOUND_ACKS) {
            ackOutbox.removeFirst()
        }
        ackOutbox.addLast(ack)
        true
    }

    /** Drain up to [max] queued ACKs for the link writer (the T54 lab pump seam). */
    internal fun drainAckOutboxForLink(max: Int): List<io.godstone.mesh.wire.v2.FrameV2> = synchronized(ackOutboxLock) {
        val out = ArrayList<io.godstone.mesh.wire.v2.FrameV2>()
        var n = 0
        while (n < max && ackOutbox.size > 0) {
            out.add(ackOutbox.removeFirst())
            n += 1
        }
        out
    }

    /** Outbox depth for witnesses -- telemetry only, never authority. */
    internal fun ackOutboxDepthForTest(): Int = synchronized(ackOutboxLock) { ackOutbox.size }

    /**
     * Test-only seam: inject a connected peer so `dispatchSos` has a recipient
     * to hand a frame to. Production peers arrive only via the `ble.peers()` flow
     * collected in `start()`, which is unreachable in pure-JVM tests (no Android
     * Context / no Robolectric). Mirrors the iOS `transportDidConnect(peerId:)`
     * seam. `internal` keeps it within the `:mesh` module (non-shipping).
     */
    internal fun injectPeerForTest(peerId: ByteArray) {
        synchronized(peerLock) { peers[peerId.toHexKey()] = peerId }
    }

    fun onSosAcknowledgedByRecipient() {
        // T39: the flag is no longer a token to spend. A NONE-mode obligation can
        // never be acknowledged (C6.1), and this call may not retire what the
        // durable row still carries: it re-publishes what the remembered
        // authority projection says, no more and no less. A rogue or mistaken
        // call here changes nothing that the tables do not already say.
        refreshSosStatusFromDurable()
    }

    fun setNightMode(enabled: Boolean) { _nightMode.value = enabled }

    private fun publishStatus() {
        val count = synchronized(peerLock) { peers.size }
        _status.value = _status.value.copy(
            started = isStarted,
            peerCount = count,
            linkLayerReady = LINK_LAYER_READY,
            detail = if (LINK_LAYER_READY) "Mesh control plane active" else LINK_LAYER_OPEN_REASON
        )
    }

    companion object {
        /** Flipped only when ADR-001/M1-wire and ADR-002/M2-link acceptance tests pass. */
        const val LINK_LAYER_READY = false

        /** T37: the bounded runtime outbox of canonical recipient ACKs awaiting the link. */
        const val MAX_OUTBOUND_ACKS: Int = 64
    }
}
