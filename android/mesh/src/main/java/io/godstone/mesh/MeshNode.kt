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
 */
class MeshNode(
    private val ctx: Context,
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
    private val identity: Identity by lazy { Identity.loadOrCreate(ctx) }
    private val router: Router by lazy { Router(store, identity.nodeId) }
    val sessions: io.godstone.mesh.crypto.SessionManager by lazy {
        io.godstone.mesh.crypto.SessionManager(identity)
    }
    private val ble: BleTransport by lazy {
        BleTransport(ctx, identity, { router.currentDigest() }, sessions)
    }
    private val wifi: WifiAwareTransport by lazy { WifiAwareTransport(ctx) }
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
            // desync/magic/version/CRC/length error) and the router takes FrameV2.
            runCatching { io.godstone.mesh.wire.v2.FrameV2.decode(clear) }
                .getOrNull()?.let { router.onFrameReceived(it, peer) }
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
            val frame = router.buildSos(payload)
            // Stage 4B.1: QueuedLocally only after durable success (ADR-004). The
            // SOS must be durably held before the UI calls it queued -- a
            // queued-but-not-persisted SOS is one process death from gone. If the
            // store cannot hold it we report NotPersisted so the UI does not lie.
            // This body is unreachable while LINK_LAYER_READY=false (it returns
            // Unavailable first); the SosDispatchResult shapes are aligned with
            // iOS `.notPersisted` for parity all the same. HELD_NEW or
            // HELD_DUPLICATE both mean the SOS is durably held (a duplicate SOS
            // was already queued), so either proceeds to transport; only a
            // capacity rejection or storage failure reports NotPersisted and
            // exits before any BLE write.
            when (store.persist(frame, receivedFrom = identity.nodeId)) {
                PersistResult.HELD_NEW,
                PersistResult.HELD_DUPLICATE -> Unit
                PersistResult.REJECTED_CAPACITY,
                PersistResult.FAILED_STORAGE ->
                    return@runCatching SosDispatchResult.NotPersisted
            }
            val bytes = frame.encode()
            var handed = 0
            for (peerId in knownPeers()) if (ble.send(peerId, bytes)) handed++
            _status.value = _status.value.copy(activeSos = true)
            if (handed == 0) SosDispatchResult.QueuedLocally
            else SosDispatchResult.HandedToRelays(handed)
        }.getOrElse { SosDispatchResult.Failed(it.message ?: "unknown mesh error") }
    }

    private fun knownPeers(): List<ByteArray> = synchronized(peerLock) { peers.values.toList() }

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
