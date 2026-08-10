package io.godstone.mesh

import android.content.Context
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.MessageStore
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
     * Stage 4C / C5). Constructed by [di.MeshModule] from the SAME `StoreDb`
     * engine as `store`: a [io.godstone.mesh.delivery.SqliteDeliveryJournal] is
     * BOTH the journal and the expected-recipient store, and an
     * [io.godstone.mesh.delivery.Ed25519AckAuthenticator] over the production
     * [io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver] rejects every
     * ACK until the M2-link identity binding wires real recipient keys
     * (fail-closed). The outbound path (C6) records the expected recipient +
     * advances state on a successful relay hand-off; the inbound ACK path (C7)
     * binds the ACK to the durable expected recipient. No delivery is claimed
     * on host-only evidence -- A-03 / ADR-005 stay OPEN.
     */
    internal val deliveryTracker: DeliveryTracker,
) {
    /**
     * Production constructor: identity loaded from the Android Context via
     * [Identity.loadOrCreate]. [di.MeshModule] is the only caller. The Context
     * is retained for the lazy BLE/Wi-Fi transports (reached only through the
     * `LINK_LAYER_READY`-gated `start()` / `broadcastSos`, never from the
     * ungated `dispatchSos` / `ingestInbound` test seams).
     */
    constructor(ctx: Context, store: MessageStore, deliveryTracker: DeliveryTracker)
        : this(ctx, Identity.loadOrCreate(ctx), store, deliveryTracker)

    internal val router: Router by lazy { Router(store, identity.nodeId) }
    val sessions: io.godstone.mesh.crypto.SessionManager by lazy {
        io.godstone.mesh.crypto.SessionManager(identity)
    }
    private val ble: BleTransport by lazy {
        // ctx is non-null in production (3-arg ctor); null only in pure-JVM tests
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
        runCatching {
            dispatchSos(payload) { peerId, bytes -> ble.send(peerId, bytes) }
        }.getOrElse { SosDispatchResult.Failed(it.message ?: "unknown mesh error") }
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
     * Stage 4C / C6: the delivery tracker is driven AFTER durable hold -- the
     * `enqueue` that records `QUEUED_DURABLY` runs only once `store.persist` has
     * succeeded (persist-before-tracker, extending the 4B.1 persist-before-forward
     * gate to the delivery state). SOS is a broadcast (no single intended
     * recipient), so `expectedRecipient = null` -- the unbound path, no recipient
     * binding. Each successful relay hand-off calls `markHandedToRelay`
     * (idempotent: the first transitions queued -> handed; further sends no-op).
     * The body is unreachable while `LINK_LAYER_READY=false` via `broadcastSos`;
     * tests drive it directly through this seam.
     */
    internal suspend fun dispatchSos(
        payload: ByteArray,
        send: (peerId: ByteArray, bytes: ByteArray) -> Boolean,
    ): SosDispatchResult {
        val frame = router.buildSos(payload)
        when (store.persist(frame, receivedFrom = identity.nodeId)) {
            PersistResult.HELD_NEW,
            PersistResult.HELD_DUPLICATE -> Unit
            PersistResult.REJECTED_CAPACITY,
            PersistResult.FAILED_STORAGE -> return SosDispatchResult.NotPersisted
        }
        // C6: record the delivery lifecycle AFTER durable hold. expectedRecipient
        // = null (broadcast SOS -> unbound path, no recipient binding).
        deliveryTracker.enqueue(frame.msgId, expectedRecipient = null)
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
    internal fun ingestInbound(frame: io.godstone.mesh.wire.v2.FrameV2, fromPeer: ByteArray) {
        if (frame.type == io.godstone.mesh.wire.v2.TypeV2.ACK) {
            deliveryTracker.acknowledge(frame.msgId, frame)
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
