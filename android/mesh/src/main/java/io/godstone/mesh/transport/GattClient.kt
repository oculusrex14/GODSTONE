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

@SuppressLint("MissingPermission")
class GattClientConnection(
    private val context: Context,
    val peerAddress: String,
    val onGattConnected: (Long, Long) -> Unit = { _, _ -> },
    val onServicesDiscovered: (Boolean, Long, Long) -> Unit = { _, _, _ -> },
    val onLinkInfoReadResult: (ByteArray?, Long, Long) -> Unit = { _, _, _ -> },
    val onLinkInfoWriteAck: (Boolean, Long, Long) -> Unit = { _, _, _ -> },
    val onCccdWriteAck: (Boolean, Long, Long) -> Unit = { _, _, _ -> },
    val onMtuChanged: (Int) -> Unit = {},
    val onDisconnected: () -> Unit = {},
    val onInboundNotification: (ByteArray) -> Unit = {}
) {
    private var gatt: BluetoothGatt? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private var linkInfoCharacteristic: BluetoothGattCharacteristic? = null

    private val gattMutex = Mutex()

    @Volatile
    var gattGeneration: Long = 0L
        private set

    @Volatile
    var isConnected: Boolean = false
        private set

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            val gen = gattGeneration
            if (g !== gatt) return

            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                isConnected = false
                onDisconnected()
                return
            }

            if (newState == BluetoothProfile.STATE_CONNECTED) {
                isConnected = true
                onGattConnected(gen, gen)
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val gen = gattGeneration
            if (g !== gatt) return
            
            if (status == BluetoothGatt.GATT_SUCCESS) {
                val service = g.services.firstOrNull { it.uuid == BleTransport.SERVICE_UUID }
                val inbox = service?.getCharacteristic(BleTransport.WRITE_CHAR_UUID)
                val linkInfo = service?.getCharacteristic(BleTransport.LINK_INFO_CHAR_UUID)

                if (inbox != null && linkInfo != null) {
                    inboxCharacteristic = inbox
                    linkInfoCharacteristic = linkInfo
                    onServicesDiscovered(true, gen, gen)
                    return
                }
            }
            onServicesDiscovered(false, gen, gen)
        }

        override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val gen = gattGeneration
            if (g !== gatt) return
            if (characteristic.uuid == BleTransport.LINK_INFO_CHAR_UUID) {
                if (status == BluetoothGatt.GATT_SUCCESS) {
                    onLinkInfoReadResult(characteristic.value, gen, gen)
                } else {
                    onLinkInfoReadResult(null, gen, gen)
                }
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val gen = gattGeneration
            if (g !== gatt) return
            if (characteristic.uuid == BleTransport.LINK_INFO_CHAR_UUID) {
                onLinkInfoWriteAck(status == BluetoothGatt.GATT_SUCCESS, gen, gen)
            }
            if (characteristic.uuid == BleTransport.WRITE_CHAR_UUID) {
                val deferred = pendingWriteDeferred
                if (deferred != null && !deferred.isCompleted) {
                    deferred.complete(status == BluetoothGatt.GATT_SUCCESS)
                }
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            val gen = gattGeneration
            if (g !== gatt) return
            if (descriptor.uuid == GattClientConnection.CCCD_UUID) {
                onCccdWriteAck(status == BluetoothGatt.GATT_SUCCESS, gen, gen)
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (g !== gatt) return
            if (status == BluetoothGatt.GATT_SUCCESS) {
                onMtuChanged(mtu)
            }
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

    fun connectGatt() {
        val manager = context.getSystemService(BluetoothManager::class.java)
        val adapter = manager?.adapter ?: return
        if (!adapter.isEnabled) return

        val device: BluetoothDevice = try {
            adapter.getRemoteDevice(peerAddress)
        } catch (_: IllegalArgumentException) {
            return
        }

        gattGeneration++
        gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    fun discoverServices() {
        gatt?.discoverServices()
    }

    fun readLinkInfo() {
        val linkInfo = linkInfoCharacteristic ?: return
        gatt?.readCharacteristic(linkInfo)
    }

    fun writeLinkInfo(localBytes: ByteArray) {
        val linkInfo = linkInfoCharacteristic ?: return
        linkInfo.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        linkInfo.value = localBytes
        gatt?.writeCharacteristic(linkInfo)
    }

    fun subscribeCccd() {
        val inbox = inboxCharacteristic ?: return
        gatt?.setCharacteristicNotification(inbox, true)
        val cccd = inbox.getDescriptor(CCCD_UUID) ?: return
        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        gatt?.writeDescriptor(cccd)
    }

    fun requestMtu(mtu: Int) {
        gatt?.requestMtu(mtu)
    }

    private var pendingWriteDeferred: CompletableDeferred<Boolean>? = null

    suspend fun sendAttValue(bytes: ByteArray): Boolean = gattMutex.withLock {
        val g = gatt ?: return false
        val ch = inboxCharacteristic ?: return false
        if (!isConnected) return false

        val deferred = CompletableDeferred<Boolean>()
        pendingWriteDeferred = deferred

        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        ch.value = bytes

        val initiated = g.writeCharacteristic(ch)
        if (!initiated) {
            pendingWriteDeferred = null
            return false
        }

        val success = withTimeoutOrNull(5000L) {
            deferred.await()
        } ?: false

        pendingWriteDeferred = null
        return success
    }

    fun disconnect() {
        gattGeneration++
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
    }
}
