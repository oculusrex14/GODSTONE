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

/**
 * Persistent central-side GATT connection implementing the Connect-First LinkInfo control path (ADR-002, Phase C8.4D1-A1/R2/R2.1).
 *
 * Enforces:
 * - Bounded connect and operation timeouts (GATT_CONNECT_TIMEOUT, GATT_OPERATION_TIMEOUT)
 * - Service discovery of canonical inbox and LINK_INFO characteristics
 * - Remote LinkInfo reading and exact 13-byte validation
 * - Deterministic role election via [BleRoleBindingCoordinator]
 * - Acknowledged local LinkInfo write for elected Initiator
 * - Verified CCCD descriptor write gating and subscription propagation
 * - Non-blocking bounded MTU negotiation with safe 20-byte fallback
 * - Mutex-serialized GATT operations and completion-serialized record writes
 */
@SuppressLint("MissingPermission")
class GattClientConnection(
    private val context: Context,
    val peerAddress: String,
    private val localLinkInfoProvider: () -> ByteArray? = { null },
    private val coordinator: BleRoleBindingCoordinator? = null,
    val onInboundNotification: (ByteArray) -> Unit = {},
    val onDisconnected: () -> Unit = {},
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

    private var connectionStateDeferred = CompletableDeferred<Int>()
    private var servicesDiscoveredDeferred = CompletableDeferred<Int>()
    private var charReadDeferred = CompletableDeferred<Pair<Int, ByteArray?>>()
    private var charWriteDeferred = CompletableDeferred<Int>()
    private var descWriteDeferred = CompletableDeferred<Int>()
    private var mtuChangedDeferred = CompletableDeferred<Pair<Int, Int>>()

    private var operationToken: Long = 0L
    private var pendingWriteToken: Long = 0L
    private var pendingWriteDeferred: CompletableDeferred<Int>? = null

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
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                isConnected = false
                isRoleBound = false
                isSubscribed = false
                if (!connectionStateDeferred.isCompleted) connectionStateDeferred.complete(status)
                if (!servicesDiscoveredDeferred.isCompleted) servicesDiscoveredDeferred.complete(status)
                if (!charReadDeferred.isCompleted) charReadDeferred.complete(status to null)
                if (!charWriteDeferred.isCompleted) charWriteDeferred.complete(status)
                if (!descWriteDeferred.isCompleted) descWriteDeferred.complete(status)
                if (!mtuChangedDeferred.isCompleted) mtuChangedDeferred.complete(status to 23)
                pendingWriteDeferred?.complete(status)
                pendingWriteDeferred = null
                try {
                    g.close()
                } catch (_: Exception) {}
                onDisconnected()
                return
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                isConnected = true
                if (!connectionStateDeferred.isCompleted) connectionStateDeferred.complete(status)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (!servicesDiscoveredDeferred.isCompleted) {
                servicesDiscoveredDeferred.complete(status)
            }
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            val value = characteristic.value
            if (!charReadDeferred.isCompleted) {
                charReadDeferred.complete(status to value)
            }
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int
        ) {
            val deferred = pendingWriteDeferred
            if (deferred != null && !deferred.isCompleted) {
                pendingWriteDeferred = null
                deferred.complete(status)
            }
            if (!charWriteDeferred.isCompleted) {
                charWriteDeferred.complete(status)
            }
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int
        ) {
            if (!descWriteDeferred.isCompleted) {
                descWriteDeferred.complete(status)
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (!mtuChangedDeferred.isCompleted) {
                mtuChangedDeferred.complete(status to mtu)
            }
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid == BleTransport.WRITE_CHAR_UUID) {
                val value = characteristic.value ?: return
                onInboundNotification(value)
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

        connectionStateDeferred = CompletableDeferred()
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        val g = gatt ?: return false

        // 1. Await connection establishment
        val connStatus = withTimeoutOrNull(connectTimeoutMs) {
            connectionStateDeferred.await()
        }
        if (connStatus != BluetoothGatt.GATT_SUCCESS) {
            disconnectLocked()
            return false
        }

        // 2. Discover canonical services
        servicesDiscoveredDeferred = CompletableDeferred()
        val discStarted = g.discoverServices()
        if (!discStarted) {
            disconnectLocked()
            return false
        }
        val discStatus = withTimeoutOrNull(operationTimeoutMs) {
            servicesDiscoveredDeferred.await()
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
        charReadDeferred = CompletableDeferred()
        val readStarted = g.readCharacteristic(linkInfo)
        if (!readStarted) {
            disconnectLocked()
            return false
        }
        val readResult = withTimeoutOrNull(operationTimeoutMs) {
            charReadDeferred.await()
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
        val localBytes = localLinkInfoProvider()
        if (localBytes == null || localBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            disconnectLocked()
            return false
        }

        charWriteDeferred = CompletableDeferred()
        linkInfo.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        linkInfo.value = localBytes
        val writeStarted = g.writeCharacteristic(linkInfo)
        if (!writeStarted) {
            disconnectLocked()
            return false
        }

        val writeStatus = withTimeoutOrNull(operationTimeoutMs) {
            charWriteDeferred.await()
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

        descWriteDeferred = CompletableDeferred()
        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        val descStarted = g.writeDescriptor(cccd)
        if (!descStarted) {
            disconnectLocked()
            return false
        }

        val descStatus = withTimeoutOrNull(operationTimeoutMs) {
            descWriteDeferred.await()
        }
        if (descStatus != BluetoothGatt.GATT_SUCCESS) {
            disconnectLocked()
            return false
        }

        isSubscribed = true
        onSubscriptionReady()

        // 7. Request MTU with safe 20-byte fallback
        var maxAttValLen = BleConnection.DEFAULT_MAX_ATT_VALUE_LENGTH
        mtuChangedDeferred = CompletableDeferred()
        val mtuReqStarted = g.requestMtu(TARGET_MTU)
        if (mtuReqStarted) {
            val mtuResult = withTimeoutOrNull(operationTimeoutMs) {
                mtuChangedDeferred.await()
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

        val token = ++operationToken
        pendingWriteToken = token
        val deferred = CompletableDeferred<Int>()
        pendingWriteDeferred = deferred

        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        ch.value = bytes

        val initiated = g.writeCharacteristic(ch)
        if (!initiated) {
            pendingWriteDeferred = null
            return false
        }

        val status = withTimeoutOrNull(operationTimeoutMs) {
            try {
                deferred.await()
            } catch (_: Exception) {
                null
            }
        }

        if (status != BluetoothGatt.GATT_SUCCESS) {
            pendingWriteDeferred = null
            disconnectLocked()
            return false
        }

        return true
    }

    fun disconnect() {
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
        pendingWriteDeferred?.complete(BluetoothGatt.GATT_FAILURE)
        pendingWriteDeferred = null
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
