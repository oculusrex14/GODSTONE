package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.wire.v2.FrameV2
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import java.nio.ByteBuffer
import java.util.UUID

/**
 * Disabled BLE control-plane scaffold.
 *
 * ADR-002 proved the old 26-byte service-data advertisement cannot fit beside a
 * 128-bit UUID. The accepted target is UUID-only primary advertising plus a
 * 13-byte scan-response payload. MeshNode keeps this transport unreachable until
 * the record layer, handshake driver and on-device size tests are complete.
 */
@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context,
    private val identity: Identity,
    private val digestProvider: suspend () -> BloomDigest,
    /** Noise sessions. Without this the transport cannot send at all -- by design. */
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null
) : Transport {

    override val name = "BLE"
    override val isBulkCapable = false

    private val btManager = context.getSystemService(BluetoothManager::class.java)
    private val adapter get() = btManager.adapter

    private var powerState = PowerState.NORMAL
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null

    override fun start() {
        startAdvertising()
    }

    override fun stop() {
        advertiseCallback?.let { adapter.bluetoothLeAdvertiser?.stopAdvertising(it) }
        scanCallback?.let { adapter.bluetoothLeScanner?.stopScan(it) }
        advertiseCallback = null
        scanCallback = null
    }

    fun setPowerState(state: PowerState) {
        if (state == powerState) return
        powerState = state
        stop()
        start()
    }

    /**
     * Accepted 13-byte scan-response payload from ADR-002.
     *
     * This builder is not wired into advertising yet: the complete M2-link
     * lifecycle must produce it asynchronously from the durable held-message
     * digest and verify packet sizes on hardware before LINK_LAYER_READY moves.
     */
    fun buildScanResponsePayload(
        digest: ByteArray,
        queueDepth: Int,
        sosPresent: Boolean,
        clockUntrusted: Boolean = false
    ): ByteArray {
        require(digest.size >= 6) { "short digest requires at least 6 bytes" }
        var flags = 0
        if (sosPresent) flags = flags or FLAG_SOS
        if (powerState == PowerState.CRITICAL) flags = flags or FLAG_POWER_CONSTRAINED
        if (clockUntrusted) flags = flags or FLAG_CLOCK_UNTRUSTED

        return ByteBuffer.allocate(SCAN_RESPONSE_BYTES)
            .put(FrameV2.VERSION)
            .put(flags.toByte())
            .put(identity.nodeHint)
            .put(digest, 0, 6)
            .put(queueDepth.coerceIn(0, 255).toByte())
            .array()
    }

    private fun startAdvertising() {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(
                when (powerState) {
                    PowerState.SOS_ACTIVE -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                    PowerState.NORMAL -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
                    else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                }
            )
            .setTxPowerLevel(
                if (powerState == PowerState.CRITICAL)
                    AdvertiseSettings.ADVERTISE_TX_POWER_LOW
                else
                    AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
            )
            .setConnectable(true)
            .build()

        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)   // never leak the device name
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        advertiseCallback = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                // Surfaced to the user by MeshNode as a degraded-mode banner.
            }
        }

        adapter.bluetoothLeAdvertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    override fun peers(): Flow<PeerEvent> = callbackFlow {
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val sd = result.scanRecord
                    ?.getServiceData(ParcelUuid(SERVICE_UUID)) ?: return
                if (sd.size < SCAN_RESPONSE_BYTES) return

                val buf = ByteBuffer.wrap(sd)
                if (buf.get() != 0x02.toByte()) return   // refuse unknown versions

                val flags = buf.get().toInt()
                val hint = ByteArray(4).also { buf.get(it) }
                val digest = ByteArray(6).also { buf.get(it) }
                val queueDepth = buf.get().toInt() and 0xFF

                trySend(
                    PeerEvent.Found(
                        peerId = PeerId.fromAddress(result.device.address) ?: return,
                        nodeHint = hint,
                        rssi = result.rssi,
                        sosFlag = flags and FLAG_SOS != 0,
                        bulkCapable = flags and FLAG_BULK_CAPABLE != 0,
                        shortDigest = digest,
                        queueDepth = queueDepth
                    )
                )
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(
                when (powerState) {
                    PowerState.SOS_ACTIVE -> ScanSettings.SCAN_MODE_LOW_LATENCY
                    PowerState.NORMAL -> ScanSettings.SCAN_MODE_BALANCED
                    else -> ScanSettings.SCAN_MODE_LOW_POWER
                }
            )
            .build()

        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        adapter.bluetoothLeScanner?.startScan(listOf(filter), settings, cb)
        scanCallback = cb

        awaitClose { adapter.bluetoothLeScanner?.stopScan(cb) }
    }

    /**
     * Send [bytes] to [peerId] THROUGH THE NOISE SESSION.
     *
     * Audit: this method previously wrote `frame.encode()` directly to the GATT
     * characteristic. NoiseSession existed and was tested, but nothing in
     * production ever constructed one, so every byte the mesh sent was
     * plaintext while the app described itself as encrypted.
     *
     * There is deliberately NO plaintext fallback. If no session is established
     * the send fails and the router carries the frame to the next encounter --
     * delay is the designed behaviour; leaking is not.
     */
    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        require(bytes.size <= GATT_MTU) { "use the bulk plane for large payloads" }
        val sealed = sessions?.seal(peerId, bytes) ?: return false
        return GattClient.write(context, peerId, WRITE_CHAR_UUID, sealed)
    }

    /** Decrypted inbound frames. Anything that fails authentication is dropped. */
    fun receivedPlaintext(): Flow<Pair<ByteArray, ByteArray>> =
        kotlinx.coroutines.flow.flow {
            received().collect { (peer, cipher) ->
                val clear = try {
                    sessions?.open(peer, cipher)
                } catch (e: Exception) {
                    null   // tamper or replay: refuse to process
                }
                if (clear != null) emit(peer to clear)
            }
        }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> =
        GattServer.incoming(context, SERVICE_UUID, WRITE_CHAR_UUID)

    companion object {
        // GENERATED-SPEC UUIDs. These previously read 67640001-… while iOS read
        // 6F0D0001-… -- the two platforms literally could not see each other, so
        // the header and type-code defects below were never even reached. The
        // values now come from wire/wire_v2.yaml via FrameV2 and cannot drift:
        // ci/check_parity.py Invariant G fails the build if a literal UUID
        // reappears here.
        val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID
        val WRITE_CHAR_UUID: UUID = FrameV2.INBOX_UUID
        val NOTIFY_CHAR_UUID: UUID = FrameV2.DIGEST_UUID

        const val GATT_MTU = 512
        const val SCAN_RESPONSE_BYTES = 13

        const val FLAG_SOS = 0x01
        const val FLAG_BULK_CAPABLE = 0x02
        const val FLAG_POWER_CONSTRAINED = 0x04
        const val FLAG_VERIFIED_ONLY = 0x08
        const val FLAG_CLOCK_UNTRUSTED = 0x10
    }
}
