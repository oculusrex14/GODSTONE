package io.godstone.mesh

import android.content.Context
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.transport.PowerState
import io.godstone.mesh.transport.WifiAwareTransport
import java.security.SecureRandom
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
    private val store: MessageStore
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
            runCatching { io.godstone.mesh.wire.Frame.decode(clear) }
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
            val frame = router.buildSos(payload, SecureRandom().nextLong())
            store.persist(frame, receivedFrom = identity.nodeId)
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
