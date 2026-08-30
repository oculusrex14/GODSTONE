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
import java.util.concurrent.atomic.AtomicLong

enum class GattOpType {
    CONNECT,
    SERVICE_DISCOVERY,
    LINK_INFO_READ,
    LINK_INFO_WRITE,
    CCCD_WRITE,
    DATA_WRITE,
    MTU_REQUEST
}

data class PendingGattOp(
    val opType: GattOpType,
    val gattGeneration: Long,
    val opGeneration: Long,
    val expectedUuid: UUID? = null,
    val gatt: BluetoothGatt? = null,
    val deferred: CompletableDeferred<Boolean>? = null
)

data class GattLifetimeToken(val generation: Long)

@SuppressLint("MissingPermission")
class GattClientConnection(
    private val context: Context? = null,
    val peerAddress: String,
    val onGattConnected: (Long, Long) -> Unit = { _, _ -> },
    val onServicesDiscovered: (Boolean, Long, Long) -> Unit = { _, _, _ -> },
    val onLinkInfoReadResult: (ByteArray?, Long, Long) -> Unit = { _, _, _ -> },
    val onLinkInfoWriteAck: (Boolean, Long, Long) -> Unit = { _, _, _ -> },
    val onCccdWriteAck: (Boolean, Long, Long) -> Unit = { _, _, _ -> },
    val onMtuChanged: (Int) -> Unit = {},
    val onDisconnected: (Long, Long) -> Unit = { _, _ -> },
    val onInboundNotification: (ByteArray) -> Unit = {}
) {
    val clientToken: Long = nextClientToken()

    private var gatt: BluetoothGatt? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private var linkInfoCharacteristic: BluetoothGattCharacteristic? = null

    private val gattMutex = Mutex()
    private val opLock = Any()

    @Volatile
    var gattGeneration: Long = 0L
        private set

    @Volatile
    var isConnected: Boolean = false
        private set

    val currentLifetimeToken: GattLifetimeToken
        get() = GattLifetimeToken(gattGeneration)

    private var opGenCounter: Long = 0L
    private var currentOp: PendingGattOp? = null

    fun getCurrentPendingOp(): PendingGattOp? = synchronized(opLock) { currentOp }

    fun enqueuePendingOpForTesting(opType: GattOpType, expectedUuid: UUID? = null) {
        synchronized(opLock) {
            opGenCounter++
            currentOp = PendingGattOp(
                opType = opType,
                gattGeneration = gattGeneration,
                opGeneration = opGenCounter,
                expectedUuid = expectedUuid,
                gatt = gatt
            )
        }
    }

    fun dispatchConnectionStateChange(status: Int, newState: Int, token: GattLifetimeToken = currentLifetimeToken) {
        val gen = gattGeneration
        if (token.generation != gen) return

        if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
            isConnected = false
            synchronized(opLock) { currentOp = null }
            onDisconnected(clientToken, gen)
            return
        }

        if (newState == BluetoothProfile.STATE_CONNECTED) {
            var matched = false
            synchronized(opLock) {
                val op = currentOp
                if (op != null && op.opType == GattOpType.CONNECT && op.gattGeneration == gen) {
                    currentOp = null
                    matched = true
                }
            }
            if (!matched) return
            isConnected = true
            onGattConnected(gen, gen)
        }
    }

    fun dispatchServicesDiscovered(status: Int, token: GattLifetimeToken = currentLifetimeToken, hasRequiredCharacteristics: Boolean = true) {
        val gen = gattGeneration
        if (token.generation != gen) return

        var matched = false
        synchronized(opLock) {
            val op = currentOp
            if (op != null && op.opType == GattOpType.SERVICE_DISCOVERY && op.gattGeneration == gen) {
                currentOp = null
                matched = true
            }
        }
        if (!matched) return

        if (status == BluetoothGatt.GATT_SUCCESS && hasRequiredCharacteristics) {
            onServicesDiscovered(true, gen, gen)
            return
        }
        onServicesDiscovered(false, gen, gen)
    }

    fun dispatchCharacteristicRead(
        characteristicUuid: UUID,
        value: ByteArray?,
        status: Int,
        token: GattLifetimeToken = currentLifetimeToken
    ) {
        val gen = gattGeneration
        if (token.generation != gen) return

        var matched = false
        synchronized(opLock) {
            val op = currentOp
            if (op != null &&
                op.opType == GattOpType.LINK_INFO_READ &&
                op.gattGeneration == gen &&
                op.expectedUuid == BleTransport.LINK_INFO_CHAR_UUID &&
                characteristicUuid == BleTransport.LINK_INFO_CHAR_UUID
            ) {
                currentOp = null
                matched = true
            }
        }
        if (!matched) return

        if (status == BluetoothGatt.GATT_SUCCESS) {
            onLinkInfoReadResult(value, gen, gen)
        } else {
            onLinkInfoReadResult(null, gen, gen)
        }
    }

    fun dispatchCharacteristicWrite(
        characteristicUuid: UUID,
        status: Int,
        token: GattLifetimeToken = currentLifetimeToken
    ) {
        val gen = gattGeneration
        if (token.generation != gen) return

        if (characteristicUuid == BleTransport.LINK_INFO_CHAR_UUID) {
            var matched = false
            synchronized(opLock) {
                val op = currentOp
                if (op != null &&
                    op.opType == GattOpType.LINK_INFO_WRITE &&
                    op.gattGeneration == gen &&
                    op.expectedUuid == BleTransport.LINK_INFO_CHAR_UUID
                ) {
                    currentOp = null
                    matched = true
                }
            }
            if (!matched) return
            onLinkInfoWriteAck(status == BluetoothGatt.GATT_SUCCESS, gen, gen)
            return
        }

        if (characteristicUuid == BleTransport.WRITE_CHAR_UUID) {
            var deferredToComplete: CompletableDeferred<Boolean>? = null
            synchronized(opLock) {
                val op = currentOp
                if (op != null &&
                    op.opType == GattOpType.DATA_WRITE &&
                    op.gattGeneration == gen &&
                    op.expectedUuid == BleTransport.WRITE_CHAR_UUID
                ) {
                    deferredToComplete = op.deferred
                    currentOp = null
                }
            }
            deferredToComplete?.complete(status == BluetoothGatt.GATT_SUCCESS)
        }
    }

    fun dispatchDescriptorWrite(
        descriptorUuid: UUID,
        status: Int,
        token: GattLifetimeToken = currentLifetimeToken
    ) {
        val gen = gattGeneration
        if (token.generation != gen) return

        if (descriptorUuid == CCCD_UUID) {
            var matched = false
            synchronized(opLock) {
                val op = currentOp
                if (op != null &&
                    op.opType == GattOpType.CCCD_WRITE &&
                    op.gattGeneration == gen &&
                    op.expectedUuid == CCCD_UUID
                ) {
                    currentOp = null
                    matched = true
                }
            }
            if (!matched) return
            onCccdWriteAck(status == BluetoothGatt.GATT_SUCCESS, gen, gen)
        }
    }

    fun dispatchMtuChanged(mtu: Int, status: Int, token: GattLifetimeToken = currentLifetimeToken) {
        val gen = gattGeneration
        if (token.generation != gen) return

        var matched = false
        synchronized(opLock) {
            val op = currentOp
            if (op != null && op.opType == GattOpType.MTU_REQUEST && op.gattGeneration == gen) {
                currentOp = null
                matched = true
            }
        }
        if (!matched) return

        if (status == BluetoothGatt.GATT_SUCCESS) {
            onMtuChanged(mtu)
        }
    }

    val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (g !== gatt) return
            dispatchConnectionStateChange(status, newState, currentLifetimeToken)
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (g !== gatt) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                val service = g.services.firstOrNull { it.uuid == BleTransport.SERVICE_UUID }
                val inbox = service?.getCharacteristic(BleTransport.WRITE_CHAR_UUID)
                val linkInfo = service?.getCharacteristic(BleTransport.LINK_INFO_CHAR_UUID)

                if (inbox != null && linkInfo != null) {
                    inboxCharacteristic = inbox
                    linkInfoCharacteristic = linkInfo
                    dispatchServicesDiscovered(status, currentLifetimeToken, true)
                    return
                }
            }
            dispatchServicesDiscovered(status, currentLifetimeToken, false)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (g !== gatt) return
            dispatchCharacteristicRead(characteristic.uuid, characteristic.value, status, currentLifetimeToken)
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (g !== gatt) return
            dispatchCharacteristicWrite(characteristic.uuid, status, currentLifetimeToken)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (g !== gatt) return
            dispatchDescriptorWrite(descriptor.uuid, status, currentLifetimeToken)
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (g !== gatt) return
            dispatchMtuChanged(mtu, status, currentLifetimeToken)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (g !== gatt) return
            if (characteristic.uuid == BleTransport.WRITE_CHAR_UUID) {
                val value = characteristic.value ?: return
                onInboundNotification(value)
            }
        }
    }

    fun setMockGattForTesting(
        mockGatt: BluetoothGatt,
        mockInbox: BluetoothGattCharacteristic? = null,
        mockLinkInfo: BluetoothGattCharacteristic? = null
    ) {
        gatt = mockGatt
        inboxCharacteristic = mockInbox
        linkInfoCharacteristic = mockLinkInfo
    }

    fun setGattGenerationForTesting(gen: Long) {
        gattGeneration = gen
    }

    fun connectGatt() {
        val manager = context?.getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter ?: return
        if (!adapter.isEnabled) return

        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(peerAddress)
        } catch (_: IllegalArgumentException) {
            return
        }

        synchronized(opLock) {
            gattGeneration++
            opGenCounter++
            currentOp = PendingGattOp(
                opType = GattOpType.CONNECT,
                gattGeneration = gattGeneration,
                opGeneration = opGenCounter
            )
        }
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    fun discoverServices() {
        val g = gatt ?: return
        synchronized(opLock) {
            opGenCounter++
            currentOp = PendingGattOp(
                opType = GattOpType.SERVICE_DISCOVERY,
                gattGeneration = gattGeneration,
                opGeneration = opGenCounter,
                expectedUuid = BleTransport.SERVICE_UUID,
                gatt = g
            )
        }
        g.discoverServices()
    }

    fun readLinkInfo() {
        val g = gatt ?: return
        val linkInfo = linkInfoCharacteristic ?: return
        synchronized(opLock) {
            opGenCounter++
            currentOp = PendingGattOp(
                opType = GattOpType.LINK_INFO_READ,
                gattGeneration = gattGeneration,
                opGeneration = opGenCounter,
                expectedUuid = BleTransport.LINK_INFO_CHAR_UUID,
                gatt = g
            )
        }
        g.readCharacteristic(linkInfo)
    }

    fun writeLinkInfo(localBytes: ByteArray) {
        val g = gatt ?: return
        val linkInfo = linkInfoCharacteristic ?: return
        linkInfo.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        linkInfo.value = localBytes
        synchronized(opLock) {
            opGenCounter++
            currentOp = PendingGattOp(
                opType = GattOpType.LINK_INFO_WRITE,
                gattGeneration = gattGeneration,
                opGeneration = opGenCounter,
                expectedUuid = BleTransport.LINK_INFO_CHAR_UUID,
                gatt = g
            )
        }
        g.writeCharacteristic(linkInfo)
    }

    fun subscribeCccd() {
        val g = gatt ?: return
        val inbox = inboxCharacteristic ?: return
        g.setCharacteristicNotification(inbox, true)
        val cccd = inbox.getDescriptor(CCCD_UUID) ?: return
        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        synchronized(opLock) {
            opGenCounter++
            currentOp = PendingGattOp(
                opType = GattOpType.CCCD_WRITE,
                gattGeneration = gattGeneration,
                opGeneration = opGenCounter,
                expectedUuid = CCCD_UUID,
                gatt = g
            )
        }
        g.writeDescriptor(cccd)
    }

    fun requestMtu(mtu: Int) {
        val g = gatt ?: return
        synchronized(opLock) {
            opGenCounter++
            currentOp = PendingGattOp(
                opType = GattOpType.MTU_REQUEST,
                gattGeneration = gattGeneration,
                opGeneration = opGenCounter,
                gatt = g
            )
        }
        g.requestMtu(mtu)
    }

    suspend fun sendAttValue(bytes: ByteArray): Boolean = gattMutex.withLock {
        val g = gatt ?: return false
        val ch = inboxCharacteristic ?: return false
        if (!isConnected) return false

        val deferred = CompletableDeferred<Boolean>()
        val opGen: Long
        val gen: Long

        synchronized(opLock) {
            gen = gattGeneration
            opGenCounter++
            opGen = opGenCounter
            currentOp = PendingGattOp(
                opType = GattOpType.DATA_WRITE,
                gattGeneration = gen,
                opGeneration = opGen,
                expectedUuid = BleTransport.WRITE_CHAR_UUID,
                gatt = g,
                deferred = deferred
            )
        }

        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        ch.value = bytes

        val initiated = g.writeCharacteristic(ch)
        if (!initiated) {
            synchronized(opLock) {
                if (currentOp?.opGeneration == opGen) {
                    currentOp = null
                }
            }
            return false
        }

        val success = withTimeoutOrNull(5000L) {
            deferred.await()
        }

        if (success == null) {
            // Timed out: Invalidate and close this GATT generation so late callbacks from N1 cannot satisfy N2
            disconnect()
            return false
        }

        return success
    }

    fun disconnect() {
        synchronized(opLock) {
            gattGeneration++
            currentOp?.deferred?.complete(false)
            currentOp = null
        }
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (_: Exception) {}
        gatt = null
        isConnected = false
        inboxCharacteristic = null
        linkInfoCharacteristic = null
    }

    companion object {
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private val tokenCounter = AtomicLong(1L)
        fun nextClientToken(): Long = tokenCounter.getAndIncrement()
    }
}
