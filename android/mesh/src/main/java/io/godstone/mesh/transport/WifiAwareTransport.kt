package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.content.Context
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.PeerHandle
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.SubscribeConfig
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareSession
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow

/**
 * Wi-Fi bulk plane. Brought up ONLY on demand, when a queued payload exceeds
 * Transport.BULK_THRESHOLD and both peers advertise BULK_CAPABLE, then torn down
 * within 5 seconds of the last byte. It is never left running.
 *
 * The link inherits the Noise session already established over BLE, so no second
 * handshake is needed and the bulk plane is authenticated from its first byte.
 */
@SuppressLint("MissingPermission")
class WifiAwareTransport(
    private val context: Context
) : Transport {

    override val name = "WiFi-Aware"
    override val isBulkCapable = false

    private val manager = context.getSystemService(WifiAwareManager::class.java)
    private var session: WifiAwareSession? = null
    private var publishSession: PublishDiscoverySession? = null

    private val inbound = MutableSharedFlow<Pair<ByteArray, ByteArray>>(
        extraBufferCapacity = 64
    )

    val isSupported: Boolean
        get() = manager != null && manager.isAvailable

    override fun start() {
        // ADR-006 is not implemented. Do not publish a service that cannot
        // authenticate or carry bytes end to end.
    }

    override fun stop() {
        publishSession?.close()
        session?.close()
        publishSession = null
        session = null
    }

    private fun publish(s: WifiAwareSession) {
        val config = PublishConfig.Builder()
            .setServiceName(SERVICE_NAME)
            .build()

        s.publish(config, object : DiscoverySessionCallback() {
            override fun onPublishStarted(session: PublishDiscoverySession) {
                publishSession = session
            }

            override fun onMessageReceived(peer: PeerHandle, message: ByteArray) {
                inbound.tryEmit(peer.toString().toByteArray() to message)
            }
        }, null)
    }

    private fun subscribe(s: WifiAwareSession) {
        val config = SubscribeConfig.Builder()
            .setServiceName(SERVICE_NAME)
            .build()

        s.subscribe(config, object : DiscoverySessionCallback() {}, null)
    }

    override fun peers(): Flow<PeerEvent> = kotlinx.coroutines.flow.emptyFlow()

    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        // Fail closed until the ADR-006 bulk protocol is implemented.
        return false
    }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> = inbound

    companion object {
        const val SERVICE_NAME = "godstone-gmp1"
        const val TEARDOWN_DELAY_MS = 5_000L
    }
}
