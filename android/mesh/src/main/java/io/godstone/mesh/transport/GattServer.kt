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
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Peripheral-side GATT server supporting duplex bidirectional communication and LinkInfo exchange (ADR-002, Phase C8.4D1-A1/R2/R2.1).
 *
 * Exposes the canonical inbox characteristic and LINK_INFO characteristic.
 * Enforces asynchronous service add verification before advertising, serves local LinkInfo on READ,
 * validates incoming Central LinkInfo on WRITE, and requires role-binding before accepting inbox records.
 */
@SuppressLint("MissingPermission")
class BleGattServer(
    private val context: Context,
    private val serviceUuid: UUID = BleTransport.SERVICE_UUID,
    private val inboxCharUuid: UUID = BleTransport.WRITE_CHAR_UUID,
    private val linkInfoCharUuid: UUID = BleTransport.LINK_INFO_CHAR_UUID,
    private val linkInfoProvider: () -> ByteArray? = { null },
    private val onLinkInfoWrite: (peerAddress: String, value: ByteArray) -> Boolean = { _, _ -> false },
    private val isRoleBoundPredicate: (peerAddress: String) -> Boolean = { false },
    private val onInboundWrite: (peerAddress: String, value: ByteArray) -> Unit = { _, _ -> },
    private val onClientDisconnected: (peerAddress: String) -> Unit = {},
    private val onSubscriptionChanged: (peerAddress: String, isSubscribed: Boolean) -> Unit = { _, _ -> },
    private val onMtuChanged: (peerAddress: String, maxAttValueLength: Int) -> Unit = { _, _ -> },
    private val onServiceStatusChanged: (isReady: Boolean) -> Unit = {},
    private val notificationTimeoutMs: Long = NOTIFICATION_TIMEOUT_MS
) {
    private var server: BluetoothGattServer? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private var linkInfoCharacteristic: BluetoothGattCharacteristic? = null

    private val connectedDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val subscribedDevices = ConcurrentHashMap<String, Boolean>()
    private val deviceMtu = ConcurrentHashMap<String, Int>()
    private val notificationMutex = Mutex()
    private var pendingNotification: CompletableDeferred<Boolean>? = null
    private var pendingNotificationAddress: String? = null
    private var notificationToken: Long = 0L

    @Volatile
    private var serviceRegistrationEpoch: Long = 0L

    @Volatile
    var isServiceReady: Boolean = false
        private set

    val isRunning: Boolean
        get() = server != null && isServiceReady

    fun isSubscribed(peerAddress: String): Boolean = subscribedDevices[peerAddress] == true

    fun getNegotiatedAttValueLength(peerAddress: String): Int =
        deviceMtu[peerAddress] ?: BleConnection.DEFAULT_MAX_ATT_VALUE_LENGTH

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            val epoch = serviceRegistrationEpoch
            // Verify generation: if server was stopped/restarted, ignore stale callbacks
            if (server == null) {
                return
            }
            if (status == BluetoothGatt.GATT_SUCCESS && service.uuid == serviceUuid) {
                isServiceReady = true
                onServiceStatusChanged(true)
            } else {
                isServiceReady = false
                onServiceStatusChanged(false)
            }
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val address = device.address ?: return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevices[address] = device
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectedDevices.remove(address)
                subscribedDevices.remove(address)
                deviceMtu.remove(address)
                if (pendingNotificationAddress == address) {
                    pendingNotification?.complete(false)
                    pendingNotification = null
                    pendingNotificationAddress = null
                }
                onSubscriptionChanged(address, false)
                onClientDisconnected(address)
            }
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            val s = server ?: return
            if (characteristic.uuid == linkInfoCharUuid) {
                if (offset != 0) {
                    s.sendResponse(device, requestId, BluetoothGatt.GATT_INVALID_OFFSET, offset, null)
                    return
                }
                val localBytes = linkInfoProvider()
                if (localBytes == null || localBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
                    s.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                    return
                }
                s.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, localBytes)
                return
            }

            s.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
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
            val s = server
            val address = device.address ?: return

            if (characteristic.uuid == linkInfoCharUuid) {
                if (offset != 0 || preparedWrite) {
                    if (responseNeeded) {
                        s?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                    }
                    return
                }

                // Process LinkInfo write through coordinator seam
                val accepted = onLinkInfoWrite(address, value)
                if (accepted) {
                    if (responseNeeded) {
                        s?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                    }
                } else {
                    if (responseNeeded) {
                        s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                    }
                }
                return
            }

            if (characteristic.uuid == inboxCharUuid) {
                // Require connection to be role-bound before accepting inbox record traffic
                if (!isRoleBoundPredicate(address)) {
                    if (responseNeeded) {
                        s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                    }
                    return
                }

                onInboundWrite(address, value)
                if (responseNeeded) {
                    s?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                }
                return
            }

            if (responseNeeded) {
                s?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
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
            val address = device.address ?: return
            if (descriptor.uuid == GattClientConnection.CCCD_UUID) {
                val isSub = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                if (isSub) {
                    subscribedDevices[address] = true
                    onSubscriptionChanged(address, true)
                } else if (value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)) {
                    subscribedDevices.remove(address)
                    onSubscriptionChanged(address, false)
                }
            }
            if (responseNeeded) {
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            val address = device.address ?: return
            val maxAttLen = maxOf(20, mtu - 3)
            deviceMtu[address] = maxAttLen
            onMtuChanged(address, maxAttLen)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val deferred = pendingNotification
            pendingNotification = null
            pendingNotificationAddress = null
            deferred?.complete(status == BluetoothGatt.GATT_SUCCESS)
        }
    }

    fun start(): Boolean {
        if (server != null) return true

        val manager = context.getSystemService(BluetoothManager::class.java) ?: return false
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        serviceRegistrationEpoch++
        val gattServer = manager.openGattServer(context, callback) ?: return false

        // 1. Inbox Characteristic (write / write_no_response / notify)
        val inbox = BluetoothGattCharacteristic(
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
        inbox.addDescriptor(cccd)

        // 2. LinkInfo Characteristic (read / write)
        val linkInfo = BluetoothGattCharacteristic(
            linkInfoCharUuid,
            BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_READ or BluetoothGattCharacteristic.PERMISSION_WRITE
        )

        val service = BluetoothGattService(
            serviceUuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        ).apply {
            addCharacteristic(inbox)
            addCharacteristic(linkInfo)
        }

        val addInitiated = gattServer.addService(service)
        if (!addInitiated) {
            try {
                gattServer.close()
            } catch (_: Exception) {}
            return false
        }

        server = gattServer
        inboxCharacteristic = inbox
        linkInfoCharacteristic = linkInfo
        return true
    }

    /**
     * Send an ATT value notification from this peripheral to a connected, subscribed central.
     * Serialized via [notificationMutex]. Refuses to send if client has not subscribed to CCCD.
     * Bounded by [notificationTimeoutMs].
     */
    suspend fun sendNotification(deviceAddress: String, value: ByteArray): Boolean = notificationMutex.withLock {
        val s = server ?: return false
        val ch = inboxCharacteristic ?: return false
        val device = connectedDevices[deviceAddress] ?: return false

        if (subscribedDevices[deviceAddress] != true) {
            return false
        }

        val deferred = CompletableDeferred<Boolean>()
        pendingNotification = deferred
        pendingNotificationAddress = deviceAddress

        ch.value = value
        val initiated = s.notifyCharacteristicChanged(device, ch, false)
        if (!initiated) {
            pendingNotification = null
            pendingNotificationAddress = null
            return false
        }

        val result = withTimeoutOrNull(notificationTimeoutMs) {
            try {
                deferred.await()
            } catch (_: Exception) {
                false
            }
        }

        if (result == null) {
            // Timeout reached
            pendingNotification = null
            pendingNotificationAddress = null
            return false
        }
        return result
    }

    fun stop() {
        serviceRegistrationEpoch++
        isServiceReady = false
        pendingNotification?.complete(false)
        pendingNotification = null
        pendingNotificationAddress = null
        try {
            server?.clearServices()
            server?.close()
        } catch (_: Exception) {}
        server = null
        inboxCharacteristic = null
        linkInfoCharacteristic = null
        connectedDevices.clear()
        subscribedDevices.clear()
        deviceMtu.clear()
    }

    companion object {
        const val NOTIFICATION_TIMEOUT_MS = 5000L
    }
}

