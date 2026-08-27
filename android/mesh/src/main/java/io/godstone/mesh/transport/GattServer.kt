package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Peripheral-side GATT server supporting duplex bidirectional communication (ADR-002, Phase C8.4D1).
 *
 * Exposes the canonical inbox characteristic for central-to-peripheral writes, tracks per-peer CCCD
 * subscription states, receives per-peer MTU updates, and provides a serialized notification path
 * for peripheral-to-central transmissions that strictly requires an active CCCD subscription.
 */
@SuppressLint("MissingPermission")
class BleGattServer(
    private val context: Context,
    private val serviceUuid: UUID = BleTransport.SERVICE_UUID,
    private val inboxCharUuid: UUID = BleTransport.WRITE_CHAR_UUID,
    private val onInboundWrite: (peerAddress: String, value: ByteArray) -> Unit = { _, _ -> },
    private val onClientDisconnected: (peerAddress: String) -> Unit = {},
    private val onSubscriptionChanged: (peerAddress: String, isSubscribed: Boolean) -> Unit = { _, _ -> },
    private val onMtuChanged: (peerAddress: String, maxAttValueLength: Int) -> Unit = { _, _ -> }
) {
    private var server: BluetoothGattServer? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private val connectedDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val subscribedDevices = ConcurrentHashMap<String, Boolean>()
    private val deviceMtu = ConcurrentHashMap<String, Int>()
    private val notificationMutex = Mutex()
    private var pendingNotification: CompletableDeferred<Boolean>? = null

    val isRunning: Boolean
        get() = server != null

    fun isSubscribed(peerAddress: String): Boolean = subscribedDevices[peerAddress] == true

    fun getNegotiatedAttValueLength(peerAddress: String): Int =
        deviceMtu[peerAddress] ?: BleConnection.DEFAULT_MAX_ATT_VALUE_LENGTH

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevices[device.address] = device
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectedDevices.remove(device.address)
                subscribedDevices.remove(device.address)
                deviceMtu.remove(device.address)
                onSubscriptionChanged(device.address, false)
                onClientDisconnected(device.address)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (characteristic.uuid == inboxCharUuid) {
                onInboundWrite(device.address, value)
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (descriptor.uuid == GattClientConnection.CCCD_UUID) {
                val isSub = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                if (isSub) {
                    subscribedDevices[device.address] = true
                    onSubscriptionChanged(device.address, true)
                } else if (value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)) {
                    subscribedDevices.remove(device.address)
                    onSubscriptionChanged(device.address, false)
                }
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            val maxAttLen = maxOf(20, mtu - 3)
            deviceMtu[device.address] = maxAttLen
            onMtuChanged(device.address, maxAttLen)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val deferred = pendingNotification
            pendingNotification = null
            deferred?.complete(status == BluetoothGatt.GATT_SUCCESS)
        }
    }

    fun start(): Boolean {
        if (server != null) return true

        val manager = context.getSystemService(BluetoothManager::class.java) ?: return false
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        val gattServer = manager.openGattServer(context, callback) ?: return false

        val characteristic = BluetoothGattCharacteristic(
            inboxCharUuid,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        val cccd = BluetoothGattDescriptor(
            GattClientConnection.CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        characteristic.addDescriptor(cccd)

        val service = BluetoothGattService(
            serviceUuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        ).apply {
            addCharacteristic(characteristic)
        }

        val serviceAdded = gattServer.addService(service)
        if (!serviceAdded) {
            try {
                gattServer.close()
            } catch (_: Exception) {}
            return false
        }

        server = gattServer
        inboxCharacteristic = characteristic
        return true
    }

    /**
     * Send an ATT value notification from this peripheral to a connected, subscribed central.
     * Serialized via [notificationMutex]. Refuses to send if client has not subscribed to CCCD.
     */
    suspend fun sendNotification(deviceAddress: String, value: ByteArray): Boolean = notificationMutex.withLock {
        val s = server ?: return false
        val ch = inboxCharacteristic ?: return false
        val device = connectedDevices[deviceAddress] ?: return false

        // Refuse notification to unsubscribed central
        if (subscribedDevices[deviceAddress] != true) {
            return false
        }

        val deferred = CompletableDeferred<Boolean>()
        pendingNotification = deferred

        ch.value = value
        val initiated = s.notifyCharacteristicChanged(device, ch, false)
        if (!initiated) {
            pendingNotification = null
            return false
        }

        return try {
            deferred.await()
        } catch (_: Exception) {
            false
        }
    }

    fun stop() {
        try {
            server?.clearServices()
            server?.close()
        } catch (_: Exception) {}
        server = null
        inboxCharacteristic = null
        connectedDevices.clear()
        subscribedDevices.clear()
        deviceMtu.clear()
    }
}
