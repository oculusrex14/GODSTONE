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
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import java.nio.ByteBuffer
import java.util.UUID

/**
 * BLE control plane. Always on, aggressively duty-cycled.
 *
 * The most important power optimisation in the system lives here: a peer decides
 * whether to connect purely from the 26-byte advertisement. When the bloom
 * digests show neither side holds anything the other lacks, no connection is
 * made and the encounter costs one scan result and nothing more.
 */
@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context,
    private val identity: Identity,
    private val digestProvider: suspend () -> BloomDigest
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
     * 26-byte advertisement payload, protocol section 3.1.
     *   0  1   version
     *   1  1   flags
     *   2  4   node_hint
     *   6  16  bloom_digest_short
     *   22 2   queue_depth
     *   24 2   epoch
     */
    fun buildAdvertisementPayload(
        digest: ByteArray,
        queueDepth: Int,
        sosPresent: Boolean
    ): ByteArray {
        var flags = FLAG_BULK_CAPABLE
        if (sosPresent) flags = flags or FLAG_SOS
        if (powerState == PowerState.CRITICAL) flags = flags or FLAG_POWER_CONSTRAINED

        return ByteBuffer.allocate(26)
            .put(0x01)
            .put(flags.toByte())
            .put(identity.nodeHint)
            .put(digest, 0, 16)
            .putShort(queueDepth.coerceAtMost(65535).toShort())
            .putShort(((System.currentTimeMillis() / 60000) % 65536).toShort())
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
                if (sd.size < 26) return

                val buf = ByteBuffer.wrap(sd)
                if (buf.get() != 0x01.toByte()) return   // refuse unknown versions

                val flags = buf.get().toInt()
                val hint = ByteArray(4).also { buf.get(it) }
                val digest = ByteArray(16).also { buf.get(it) }
                val queueDepth = buf.getShort().toInt() and 0xFFFF

                trySend(
                    PeerEvent.Found(
                        peerId = result.device.address.toByteArray(),
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

    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        require(bytes.size <= GATT_MTU) { "use the bulk plane for large payloads" }
        return GattClient.write(context, peerId, WRITE_CHAR_UUID, bytes)
    }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> =
        GattServer.incoming(context, SERVICE_UUID, WRITE_CHAR_UUID)

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("67640001-1000-8000-00805f9b34fb")
        val WRITE_CHAR_UUID: UUID = UUID.fromString("67640002-1000-8000-00805f9b34fb")
        val NOTIFY_CHAR_UUID: UUID = UUID.fromString("67640003-1000-8000-00805f9b34fb")

        const val GATT_MTU = 512

        const val FLAG_SOS = 0x01
        const val FLAG_BULK_CAPABLE = 0x02
        const val FLAG_POWER_CONSTRAINED = 0x04
        const val FLAG_VERIFIED_ONLY = 0x08
    }
}
