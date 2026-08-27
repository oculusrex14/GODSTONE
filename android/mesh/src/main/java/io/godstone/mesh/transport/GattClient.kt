package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/**
 * Persistent central-side GATT connection (ADR-002, Phase C8.4D1).
 *
 * Retains a single [BluetoothGatt] connection for the link lifetime, serializes GATT operations,
 * subscribes to notifications on the canonical inbox characteristic, negotiates MTU, and supports
 * multiple sequential bidirectional ATT value transmissions without disconnecting.
 */
@SuppressLint("MissingPermission")
class GattClientConnection(
    private val context: Context,
    val peerAddress: String,
    val onInboundNotification: (ByteArray) -> Unit,
    val onDisconnected: () -> Unit,
    val onMtuUpdated: (Int) -> Unit = {}
) {
    private var gatt: BluetoothGatt? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private val gattMutex = Mutex()
    private var pendingOperation: CompletableDeferred<Boolean>? = null
    private val connectDeferred = CompletableDeferred<Boolean>()

    @Volatile
    var isConnected: Boolean = false
        private set

    val isReady: Boolean
        get() = isConnected && inboxCharacteristic != null

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                isConnected = false
                if (!connectDeferred.isCompleted) connectDeferred.complete(false)
                pendingOperation?.complete(false)
                g.close()
                onDisconnected()
                return
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                isConnected = true
                g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                isConnected = false
                if (!connectDeferred.isCompleted) connectDeferred.complete(false)
                pendingOperation?.complete(false)
                g.close()
                onDisconnected()
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                if (!connectDeferred.isCompleted) connectDeferred.complete(false)
                return
            }

            val service = g.services.firstOrNull { it.uuid == BleTransport.SERVICE_UUID }
            val characteristic = service?.getCharacteristic(BleTransport.WRITE_CHAR_UUID)
            if (characteristic == null) {
                if (!connectDeferred.isCompleted) connectDeferred.complete(false)
                g.disconnect()
                return
            }

            inboxCharacteristic = characteristic

            // Enable notifications on the inbox characteristic
            g.setCharacteristicNotification(characteristic, true)
            val cccd = characteristic.getDescriptor(CCCD_UUID)
            if (cccd != null) {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                g.writeDescriptor(cccd)
            } else {
                g.requestMtu(TARGET_MTU)
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            g.requestMtu(TARGET_MTU)
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                val maxAttValueLen = maxOf(20, mtu - 3)
                onMtuUpdated(maxAttValueLen)
            }
            if (!connectDeferred.isCompleted) {
                connectDeferred.complete(true)
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val deferred = pendingOperation
            pendingOperation = null
            deferred?.complete(status == BluetoothGatt.GATT_SUCCESS)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (characteristic.uuid == BleTransport.WRITE_CHAR_UUID) {
                val value = characteristic.value ?: return
                onInboundNotification(value)
            }
        }
    }

    suspend fun connect(): Boolean {
        val manager = context.getSystemService(android.bluetooth.BluetoothManager::class.java)
        val adapter = manager?.adapter ?: return false
        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(peerAddress)
        } catch (_: IllegalArgumentException) {
            return false
        }

        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null) return false

        return try {
            connectDeferred.await()
        } catch (_: Exception) {
            disconnect()
            false
        }
    }

    /**
     * Send an ATT value to the peripheral over this persistent connection.
     * Serialized via [gattMutex] so sequential writes do not overlap.
     */
    suspend fun sendAttValue(bytes: ByteArray): Boolean = gattMutex.withLock {
        val g = gatt ?: return false
        val ch = inboxCharacteristic ?: return false
        if (!isConnected) return false

        val deferred = CompletableDeferred<Boolean>()
        pendingOperation = deferred

        ch.value = bytes
        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT

        val initiated = g.writeCharacteristic(ch)
        if (!initiated) {
            pendingOperation = null
            return false
        }

        return try {
            deferred.await()
        } catch (_: Exception) {
            false
        }
    }

    fun disconnect() {
        isConnected = false
        try {
            gatt?.disconnect()
            gatt?.close()
        } catch (_: Exception) {}
        gatt = null
        inboxCharacteristic = null
    }

    companion object {
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        const val TARGET_MTU = 517
    }
}
