package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

enum class GattOpType {
    CONNECT,
    DISCOVER_SERVICES,
    READ_LINK_INFO,
    WRITE_LINK_INFO,
    WRITE_INBOX,
    WRITE_CCCD,
    REQUEST_MTU
}

data class PendingGattOp<T>(
    val generation: Long,
    val opType: GattOpType,
    val targetUuid: UUID?,
    val deferred: CompletableDeferred<T>
)

/**
 * Persistent central-side GATT connection implementing the Connect-First LinkInfo control path (ADR-002, Phase C8.4D1-A1/R2/R2.2).
 *
 * Enforces:
 * - Generation-owned GATT callbacks: stale or cross-GATT callbacks are rejected.
 * - Strict pending operation matching by generation, operation type, and characteristic/descriptor UUID.
 * - Authoritative state progression callbacks to the owning BleConnection.
 * - Timeout/failure generation invalidation preventing stale completion.
 * - Serialized mutex and completion-serialized record writes.
 */
@SuppressLint("MissingPermission")
class GattClientConnection(
    private val context: Context,
    val peerAddress: String,
    private val localLinkInfoProvider: () -> ByteArray? = { null },
    private val coordinator: BleRoleBindingCoordinator? = null,
    val onInboundNotification: (ByteArray) -> Unit = {},
    val onDisconnected: () -> Unit = {},
    val onConnected: () -> Unit = {},
    val onLinkInfoReadStarted: () -> Unit = {},
    val onLinkInfoWriteStarted: () -> Unit = {},
    val onRoleBound: (role: BleRole, remoteHint: ByteArray, remoteInfo: BleLinkInfoV1?) -> Unit = { _, _, _ -> },
    val onSubscriptionReady: () -> Unit = {},
    val onMtuUpdated: (Int) -> Unit = {},
    private val connectTimeoutMs: Long = GATT_CONNECT_TIMEOUT_MS,
    private val operationTimeoutMs: Long = GATT_OPERATION_TIMEOUT_MS
) {
    private var gatt: BluetoothGatt? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private var linkInfoCharacteristic: BluetoothGattCharacteristic? = null

    private val gattMutex = Mutex()

    @Volatile
    var gattGeneration: Long = 0L
        private set

    private var pendingOp: PendingGattOp<*>? = null

    @Volatile
    var isConnected: Boolean = false
        private set

    @Volatile
    var isRoleBound: Boolean = false
        private set

    @Volatile
    var isSubscribed: Boolean = false
        private set

    val isReady: Boolean
        get() = isConnected && isRoleBound && isSubscribed && inboxCharacteristic != null

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            val gen = gattGeneration
            if (g !== gatt) return

            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                isConnected = false
                isRoleBound = false
                isSubscribed = false
                failPendingOpLocked(status)
                try {
                    g.close()
                } catch (_: Exception) {}
                onDisconnected()
                return
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                isConnected = true
                val op = pendingOp
                if (op != null && op.generation == gen && op.opType == GattOpType.CONNECT) {
                    @Suppress("UNCHECKED_CAST")
                    (op.deferred as CompletableDeferred<Int>).complete(status)
                    pendingOp = null
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val gen = gattGeneration
            if (g !== gatt) return
            val op = pendingOp
            if (op != null && op.generation == gen && op.opType == GattOpType.DISCOVER_SERVICES) {
                @Suppress("UNCHECKED_CAST")
                (op.deferred as CompletableDeferred<Int>).complete(status)
                pendingOp = null
            }
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            val gen = gattGeneration
            if (g !== gatt) return
            val op = pendingOp
            if (op != null && op.generation == gen && op.opType == GattOpType.READ_LINK_INFO && characteristic.uuid == op.targetUuid) {
                val value = characteristic.value
                @Suppress("UNCHECKED_CAST")
                (op.deferred as CompletableDeferred<Pair<Int, ByteArray?>>).complete(status to value)
                pendingOp = null
            }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            val gen = gattGeneration
            if (g !== gatt) return
            val op = pendingOp
            if (op != null && op.generation == gen && (op.opType == GattOpType.WRITE_LINK_INFO || op.opType == GattOpType.WRITE_INBOX) && characteristic.uuid == op.targetUuid) {
                @Suppress("UNCHECKED_CAST")
                (op.deferred as CompletableDeferred<Int>).complete(status)
                pendingOp = null
            }
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            val gen = gattGeneration
            if (g !== gatt) return
            val op = pendingOp
            if (op != null && op.generation == gen && op.opType == GattOpType.WRITE_CCCD && descriptor.uuid == op.targetUuid) {
                @Suppress("UNCHECKED_CAST")
                (op.deferred as CompletableDeferred<Int>).complete(status)
                pendingOp = null
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            val gen = gattGeneration
            if (g !== gatt) return
            val op = pendingOp
            if (op != null && op.generation == gen && op.opType == GattOpType.REQUEST_MTU) {
                @Suppress("UNCHECKED_CAST")
                (op.deferred as CompletableDeferred<Pair<Int, Int>>).complete(status to mtu)
                pendingOp = null
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (g !== gatt) return
            if (characteristic.uuid == BleTransport.WRITE_CHAR_UUID) {
                val value = characteristic.value ?: return
                onInboundNotification(value)
            }
        }
    }

    private fun failPendingOpLocked(status: Int) {
        val op = pendingOp
        pendingOp = null
        if (op != null && !op.deferred.isCompleted) {
            when (op.opType) {
                GattOpType.CONNECT, GattOpType.DISCOVER_SERVICES, GattOpType.WRITE_LINK_INFO, GattOpType.WRITE_INBOX, GattOpType.WRITE_CCCD -> {
                    @Suppress("UNCHECKED_CAST")
                    (op.deferred as CompletableDeferred<Int>).complete(status)
                }
                GattOpType.READ_LINK_INFO -> {
                    @Suppress("UNCHECKED_CAST")
                    (op.deferred as CompletableDeferred<Pair<Int, ByteArray?>>).complete(status to null)
                }
                GattOpType.REQUEST_MTU -> {
                    @Suppress("UNCHECKED_CAST")
                    (op.deferred as CompletableDeferred<Pair<Int, Int>>).complete(status to 23)
                }
            }
        }
    }

    suspend fun connect(): Boolean = gattMutex.withLock {
        val manager = context.getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter ?: return false
        if (!adapter.isEnabled) return false

        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(peerAddress)
        } catch (_: IllegalArgumentException) {
            return false
        }

        val gen = ++gattGeneration
        val connDef = CompletableDeferred<Int>()
        pendingOp = PendingGattOp(gen, GattOpType.CONNECT, null, connDef)
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        val g = gatt ?: run {
            pendingOp = null
            return false
        }

        // 1. Await connection establishment
        val connStatus = withTimeoutOrNull(connectTimeoutMs) {
            connDef.await()
        }
        if (connStatus != BluetoothGatt.GATT_SUCCESS) {
            disconnectLocked()
            return false
        }
        onConnected()

        // 2. Discover canonical services
        val discDef = CompletableDeferred<Int>()
        pendingOp = PendingGattOp(gen, GattOpType.DISCOVER_SERVICES, null, discDef)
        val discStarted = g.discoverServices()
        if (!discStarted) {
            disconnectLocked()
            return false
        }
        val discStatus = withTimeoutOrNull(operationTimeoutMs) {
            discDef.await()
        }
        if (discStatus != BluetoothGatt.GATT_SUCCESS) {
            disconnectLocked()
            return false
        }

        val service = g.services.firstOrNull { it.uuid == BleTransport.SERVICE_UUID }
        val inbox = service?.getCharacteristic(BleTransport.WRITE_CHAR_UUID)
        val linkInfo = service?.getCharacteristic(BleTransport.LINK_INFO_CHAR_UUID)

        if (inbox == null || linkInfo == null) {
            disconnectLocked()
            return false
        }
        inboxCharacteristic = inbox
        linkInfoCharacteristic = linkInfo

        // 3. Read remote LinkInfo
        onLinkInfoReadStarted()
        val readDef = CompletableDeferred<Pair<Int, ByteArray?>>()
        pendingOp = PendingGattOp(gen, GattOpType.READ_LINK_INFO, linkInfo.uuid, readDef)
        val readStarted = g.readCharacteristic(linkInfo)
        if (!readStarted) {
            disconnectLocked()
            return false
        }
        val readResult = withTimeoutOrNull(operationTimeoutMs) {
            readDef.await()
        }
        if (readResult == null || readResult.first != BluetoothGatt.GATT_SUCCESS || readResult.second == null) {
            disconnectLocked()
            return false
        }

        val remoteBytes = readResult.second!!
        if (remoteBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            disconnectLocked()
            return false
        }

        // 4. Run coordinator election
        val coord = coordinator ?: BleRoleBindingCoordinator(ByteArray(4))
        val electionAction = coord.processCentralEvent(
            BleRoleBindingEvent.RemoteLinkInfoReadRaw(peerAddress, remoteBytes)
        )

        val remoteHint: ByteArray
        when (electionAction) {
            is BleRoleBindingAction.WriteLocalLinkInfo -> {
                remoteHint = electionAction.remoteHint
            }
            else -> {
                // local >= remote or malformed: disconnect immediately and fail closed
                disconnectLocked()
                return false
            }
        }

        // 5. Write local LinkInfo with response (acknowledged write)
        onLinkInfoWriteStarted()
        val localBytes = localLinkInfoProvider()
        if (localBytes == null || localBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            disconnectLocked()
            return false
        }

        val writeDef = CompletableDeferred<Int>()
        pendingOp = PendingGattOp(gen, GattOpType.WRITE_LINK_INFO, linkInfo.uuid, writeDef)
        linkInfo.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        linkInfo.value = localBytes
        val writeStarted = g.writeCharacteristic(linkInfo)
        if (!writeStarted) {
            disconnectLocked()
            return false
        }

        val writeStatus = withTimeoutOrNull(operationTimeoutMs) {
            writeDef.await()
        }
        if (writeStatus != BluetoothGatt.GATT_SUCCESS) {
            disconnectLocked()
            return false
        }

        // Advance coordinator and mark role bound
        coord.processCentralEvent(
            BleRoleBindingEvent.LocalLinkInfoWriteAcknowledged(peerAddress, remoteHint)
        )
        val remoteInfo = BleLinkInfoCodec.decode(remoteBytes)
        isRoleBound = true
        onRoleBound(BleRole.INITIATOR, remoteHint, remoteInfo)

        // 6. Subscribe to inbox notifications (CCCD)
        val notifSet = g.setCharacteristicNotification(inbox, true)
        if (!notifSet) {
            disconnectLocked()
            return false
        }

        val cccd = inbox.getDescriptor(CCCD_UUID)
        if (cccd == null) {
            disconnectLocked()
            return false
        }

        val descDef = CompletableDeferred<Int>()
        pendingOp = PendingGattOp(gen, GattOpType.WRITE_CCCD, cccd.uuid, descDef)
        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val descStarted = g.writeDescriptor(cccd)
        if (!descStarted) {
            disconnectLocked()
            return false
        }

        val descStatus = withTimeoutOrNull(operationTimeoutMs) {
            descDef.await()
        }
        if (descStatus != BluetoothGatt.GATT_SUCCESS) {
            disconnectLocked()
            return false
        }

        isSubscribed = true
        onSubscriptionReady()

        // 7. Request MTU with safe 20-byte fallback
        var maxAttValLen = BleConnection.DEFAULT_MAX_ATT_VALUE_LENGTH
        val mtuDef = CompletableDeferred<Pair<Int, Int>>()
        pendingOp = PendingGattOp(gen, GattOpType.REQUEST_MTU, null, mtuDef)
        val mtuReqStarted = g.requestMtu(TARGET_MTU)
        if (mtuReqStarted) {
            val mtuResult = withTimeoutOrNull(operationTimeoutMs) {
                mtuDef.await()
            }
            if (mtuResult != null && mtuResult.first == BluetoothGatt.GATT_SUCCESS) {
                maxAttValLen = maxOf(20, mtuResult.second - 3)
            }
        }
        onMtuUpdated(maxAttValLen)

        return true
    }

    /**
     * Send an ATT value to the peripheral over this persistent connection.
     * Serialized via [gattMutex] and completion-serialized via [BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT].
     */
    suspend fun sendAttValue(bytes: ByteArray): Boolean = gattMutex.withLock {
        val g = gatt ?: return false
        val ch = inboxCharacteristic ?: return false
        if (!isConnected || !isRoleBound) return false

        val gen = gattGeneration
        val writeDef = CompletableDeferred<Int>()
        pendingOp = PendingGattOp(gen, GattOpType.WRITE_INBOX, ch.uuid, writeDef)

        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        ch.value = bytes

        val initiated = g.writeCharacteristic(ch)
        if (!initiated) {
            pendingOp = null
            return false
        }

        val status = withTimeoutOrNull(operationTimeoutMs) {
            try {
                writeDef.await()
            } catch (_: Exception) {
                null
            }
        }

        if (status != BluetoothGatt.GATT_SUCCESS) {
            disconnectLocked()
            return false
        }

        return true
    }

    fun disconnect() {
        gattGeneration++
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (_: Exception) {}
        gatt = null
        isConnected = false
        isRoleBound = false
        isSubscribed = false
        inboxCharacteristic = null
        linkInfoCharacteristic = null
        failPendingOpLocked(BluetoothGatt.GATT_FAILURE)
    }

    private fun disconnectLocked() {
        disconnect()
    }

    companion object {
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val TARGET_MTU = 512
        const val GATT_CONNECT_TIMEOUT_MS = 10_000L
        const val GATT_OPERATION_TIMEOUT_MS = 5_000L
    }
}
