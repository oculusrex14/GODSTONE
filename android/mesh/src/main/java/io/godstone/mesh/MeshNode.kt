package io.godstone.mesh

import android.content.Context
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.transport.BleTransport
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
    "Encrypted BLE records and the Noise handshake driver are not implemented yet. " +
    "Radio transmission is disabled in this pre-alpha build."

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
     * Stage 4C / C6.1; C6.3). Constructed by [di.MeshModule] from the SAME
     * `StoreDb` engine as `store`: a [io.godstone.mesh.delivery.SqliteDeliveryRepository]
     * is the durable record -- one row holds the delivery state, the ACK mode,
     * and the intended recipient (the separate `ExpectedRecipientStore` seam was
     * removed in C6.1), and an [io.godstone.mesh.delivery.Ed25519AckAuthenticator]
     * over the production [io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver]
     * rejects every ACK until the M2-link identity binding wires real recipient
     * keys (fail-closed). The outbound path (C6) records the ACK mode (SOS is a
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
     * Primary test constructor with pure JVM backward compatibility.
     */
    constructor(ctx: Context?, identity: Identity, store: MessageStore, deliveryTracker: DeliveryTracker)
        : this(ctx, identity, store, deliveryTracker, io.godstone.mesh.crypto.SessionManager(
            identity = identity,
            trustAuthority = object : io.godstone.mesh.crypto.PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: io.godstone.mesh.identity.ValidatedPeerBinding): io.godstone.mesh.identity.PeerTrustApplyResult =
                    io.godstone.mesh.identity.PeerTrustApplyResult.StorageFailure()
            }
        ))

    /**
     * Production constructor: identity and sessions loaded via Hilt from MeshModule.
     */
    constructor(ctx: Context, store: MessageStore, deliveryTracker: DeliveryTracker, sessions: io.godstone.mesh.crypto.SessionManager)
        : this(ctx, Identity.loadOrCreate(ctx), store, deliveryTracker, sessions)

    constructor(ctx: Context, store: MessageStore, deliveryTracker: DeliveryTracker)
        : this(ctx, Identity.loadOrCreate(ctx), store, deliveryTracker)

    internal val router: Router by lazy { Router(store, identity.nodeId) }
    private val ble: BleTransport by lazy {
        // ctx is non-null in production; null only in pure-JVM tests
        // that never start the node and so never reach the transports.
        BleTransport(ctx!!, identity, { router.currentDigest() }, sessions)
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

    /**
     * Start only after M1-wire and M2-link are implemented and verified.
     * A non-functional encrypted transport must never silently fall back to
     * plaintext or consume battery while the UI calls it active.
     */
    fun start(): Boolean {
        if (!LINK_LAYER_READY) {
            _status.value = MeshStatus(detail = LINK_LAYER_OPEN_REASON)
            return false
        }
        synchronized(peerLock) {
            if (isStarted) return true
            isStarted = true
        }
        ble.start()
        if (wifi.isSupported) wifi.start()
        ble.peers().onEach { event ->
            synchronized(peerLock) {
                when (event) {
                    is PeerEvent.Found -> peers[event.peerId.toHexKey()] = event.peerId
                    is PeerEvent.Lost -> peers.remove(event.peerId.toHexKey())
                }
                publishStatus()
            }
        }.launchIn(scope)
        ble.receivedPlaintext().onEach { (peer, clear) ->
            // GMP/2.1 frame path (ADR-001/008): decode is fail-closed (null on any
            // desync/magic/version/CRC/length error). The inbound frame then goes
            // to [ingestInbound], which routes ACK frames to the delivery tracker
            // (C7) and every other type to the epidemic router.
            runCatching { io.godstone.mesh.wire.v2.FrameV2.decode(clear) }
                .getOrNull()?.let { ingestInbound(it, peer) }
        }.launchIn(scope)
        publishStatus()
        return true
    }

    fun stop() {
        synchronized(peerLock) {
            if (!isStarted) return
            isStarted = false
        }
        sessions.destroyAll()
        ble.stop()
        wifi.stop()
        scope.coroutineContext.cancelChildren()
        synchronized(peerLock) { peers.clear() }
        publishStatus()
    }

    fun hasActiveSos(): Boolean = _status.value.activeSos

    suspend fun broadcastSos(payload: ByteArray): SosDispatchResult = withContext(Dispatchers.IO) {
        if (!LINK_LAYER_READY) return@withContext SosDispatchResult.Unavailable(LINK_LAYER_OPEN_REASON)
        // try/catch (not runCatching) so the suspend dispatchSos call stays in the
        // coroutine body -- runCatching's lambda is non-suspend and cannot host it.
        try {
            dispatchSos(payload) { peerId, bytes -> ble.send(peerId, bytes) }
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
     * `markHandedToRelay` (idempotent: the first transitions queued -> handed;
     * further sends no-op). The body is unreachable while
     * `LINK_LAYER_READY=false` via `broadcastSos`; tests drive it directly through
     * this seam.
     */
    internal suspend fun dispatchSos(
        payload: ByteArray,
        send: suspend (peerId: ByteArray, bytes: ByteArray) -> Boolean,
    ): SosDispatchResult {
        val frame = router.buildSos(payload)
        when (store.persist(frame, receivedFrom = identity.nodeId)) {
            PersistResult.HELD_NEW,
            PersistResult.HELD_DUPLICATE -> Unit
            PersistResult.REJECTED_CAPACITY,
            PersistResult.FAILED_STORAGE -> return SosDispatchResult.NotPersisted
        }
        // C6.1: record the delivery lifecycle AFTER durable hold. SOS is a
        // broadcast -> AckMode.NONE, no recipient binding (a NONE-mode message can
        // never be acknowledged). Idempotent: a re-dispatch of the same SOS is
        // AlreadyQueuedSameBinding; only a genuine enqueue rejection (terminal
        // state / conflict / storage failure) aborts before any BLE write.
        when (val er = deliveryTracker.enqueue(frame.msgId, AckMode.NONE, expectedRecipient = null)) {
            EnqueueResult.Created, EnqueueResult.AlreadyQueuedSameBinding -> Unit
            else -> return SosDispatchResult.Failed("delivery enqueue rejected: $er")
        }
        val bytes = frame.encode()
        var handed = 0
        for (peerId in knownPeers()) {
            if (send(peerId, bytes)) {
                handed++
                deliveryTracker.markHandedToRelay(frame.msgId)
            }
        }
        _status.value = _status.value.copy(activeSos = true)
        return if (handed == 0) SosDispatchResult.QueuedLocally
        else SosDispatchResult.HandedToRelays(handed)
    }

    /**
     * Stage 4C / C6.6 -- atomic DIRECT outbound enqueue and dispatch.
     *
     * In ONE transaction, persists [frame] in held_frames and creates the initial
     * delivery_state (QUEUED_DURABLY, SINGLE_RECIPIENT, [expectedRecipient]).
     * Only upon successful commit is the transport [send] callback invoked.
     *
     * Each successful relay hand-off calls [deliveryTracker.markHandedToRelay]
     * (advancing QUEUED_DURABLY -> HANDED_TO_RELAY; never ACKNOWLEDGED_BY_RECIPIENT).
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
        for (peerId in knownPeers()) {
            if (send(peerId, bytes)) {
                handed++
                deliveryTracker.markHandedToRelay(canonicalFrame.msgId)
            }
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
        return if (frame.type == io.godstone.mesh.wire.v2.TypeV2.ACK) {
            when (deliveryTracker.acknowledge(frame.msgId, frame)) {
                AckResult.Applied, AckResult.AlreadyAcknowledged, AckResult.DuplicateAuthenticatedAck -> true
                else -> false
            }
        } else {
            router.onFrameReceived(frame, fromPeer)
        }
    }

    private fun knownPeers(): List<ByteArray> = synchronized(peerLock) { peers.values.toList() }

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
        _status.value = _status.value.copy(activeSos = false)
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
    }
}
