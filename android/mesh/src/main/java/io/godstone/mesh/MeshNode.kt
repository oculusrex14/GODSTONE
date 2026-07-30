// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh

import android.content.Context
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.PowerState
import io.godstone.mesh.transport.WifiAwareTransport
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Top-level facade over the mesh subsystem.
 *
 * Wires identity, router, and the two transports together and exposes the small
 * surface the app and foreground service depend on. The app touches the radio
 * only through this class so that lifecycle and power policy stay centralised.
 */
class MeshNode(
    private val ctx: Context,
    private val store: MessageStore
) {
    private val identity: Identity by lazy { Identity.loadOrCreate(ctx) }
    private val router: Router by lazy { Router(store, identity.nodeId) }
    private val ble: BleTransport by lazy { BleTransport(ctx, identity) { router.currentDigest() } }
    private val wifi: WifiAwareTransport by lazy { WifiAwareTransport(ctx) }

    private val _nightMode = MutableStateFlow(false)
    val nightModeFlow: StateFlow<Boolean> = _nightMode.asStateFlow()

    @Volatile
    private var sosActive: Boolean = false

    /** Ensure the long-term identity exists before any radio starts. */
    fun ensureIdentity() {
        // Touching the lazy identity forces load-or-create.
        identity.nodeId
    }

    /** Foreground raises the mesh duty cycle toward NORMAL. */
    fun onAppForegrounded() {
        setPowerState(PowerState.NORMAL)
    }

    /** Background lowers the duty cycle to save battery (constraint C4). */
    fun onAppBackgrounded() {
        setPowerState(PowerState.POWER_SAVE)
    }

    fun setPowerState(state: PowerState) {
        ble.setPowerState(state)
    }

    fun start() {
        ble.start()
        if (wifi.isSupported) wifi.start()
    }

    fun stop() {
        ble.stop()
        wifi.stop()
    }

    fun hasActiveSos(): Boolean = sosActive

    /**
     * Broadcast an SOS frame. Builds and persists it immediately so the message
     * survives even if no peer is in range right now.
     *
     * TODO: actually transmit on encounter and clear the flag after delivery.
     */
    fun broadcastSos(payload: ByteArray) {
        val frame = router.buildSos(payload, System.currentTimeMillis())
        kotlinx.coroutines.runBlocking { store.persist(frame, receivedFrom = identity.nodeId) }
        sosActive = true
    }

    /** Toggle the red night-mode theme signal consumed by the UI. */
    fun setNightMode(enabled: Boolean) {
        _nightMode.value = enabled
    }
}
