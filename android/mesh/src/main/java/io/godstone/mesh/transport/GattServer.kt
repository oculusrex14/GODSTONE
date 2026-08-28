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
import java.util.concurrent.atomic.AtomicLong

/**
 * Peripheral-side GATT server supporting duplex bidirectional communication and LinkInfo exchange (ADR-002, Phase C8.4D1-A1/R2/R2.3).
 *
 * Exposes the canonical inbox characteristic and LINK_INFO characteristic.
 * Enforces:
 * - Strict global capacity limit of 7 admitted remote devices (8th device rejected immediately).
 * - Unadmitted centrals cannot allocate subscription or MTU state, and reads/writes fail closed.
 * - Real service registration generation matching and service object validation in onServiceAdded.
 * - Stale/cross-generation onServiceAdded callback rejection.
 * - Notification timeout physical channel invalidation preventing ambiguous callback reuse.
 * - Late/stale notification callbacks cannot complete later notifications.
 * - Local LinkInfo serving on READ from precomputed snapshot provider (fail-closed if unavailable).
 * - Inbound Central LinkInfo verification on WRITE.
 * - Role-binding precondition before accepting inbox records.
 */
typealias BleLinkInfoProvider = () -> ByteArray?
typealias BleLinkInfoWriteHandler = (String, ByteArray) -> Boolean
typealias BleRoleBoundPredicate = (String) -> Boolean
typealias BleInboundWriteHandler = (String, ByteArray) -> Unit
typealias BleDisconnectHandler = (String) -> Unit
typealias BleSubscriptionHandler = (String, Boolean) -> Unit
typealias BleMtuHandler = (String, Int) -> Unit
typealias BleServiceStatusHandler = (Boolean) -> Unit

private data class PendingNotification(
    val notificationGeneration: Long,
    val peerGeneration: Long,
    val deviceAddress: String,
    val deferred: CompletableDeferred<Boolean>
)

@SuppressLint("MissingPermission")
class BleGattServer(
    private val context: Context,
    private val serviceUuid: UUID = BleTransport.SERVICE_UUID,
    private val inboxCharUuid: UUID = BleTransport.WRITE_CHAR_UUID,
    private val linkInfoCharUuid: UUID = BleTransport.LINK_INFO_CHAR_UUID,
    private val linkInfoProvider: BleLinkInfoProvider = { null },
    private val onLinkInfoWrite: BleLinkInfoWriteHandler = { _, _ -> false },
    private val isRoleBoundPredicate: BleRoleBoundPredicate = { false },
    private val onInboundWrite: BleInboundWriteHandler = { _, _ -> },
    private val onClientDisconnected: BleDisconnectHandler = {},
    private val onSubscriptionChanged: BleSubscriptionHandler = { _, _ -> },
    private val onMtuChanged: BleMtuHandler = { _, _ -> },
    private val onServiceStatusChanged: BleServiceStatusHandler = {},
    private val notificationTimeoutMs: Long = NOTIFICATION_TIMEOUT_MS
) {
    private var server: BluetoothGattServer? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private var linkInfoCharacteristic: BluetoothGattCharacteristic? = null

    private val connectedDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val subscribedDevices = ConcurrentHashMap<String, Boolean>()
    private val deviceMtu = ConcurrentHashMap<String, Int>()
    private val peerGenerations = ConcurrentHashMap<String, Long>()
    private val globalPeerGenCounter = AtomicLong(0L)
    private val notificationMutex = Mutex()

    private var pendingNotification: PendingNotification? = null
    private var notificationGeneration: Long = 0L

    @Volatile
    var serverGeneration: Long = 0L
        private set

    @Volatile
    var serviceRegistrationEpoch: Long = 0L
        private set

    private var pendingService: BluetoothGattService? = null
    private var pendingServiceGeneration: Long = 0L

    @Volatile
    var isServiceReady: Boolean = false
        private set

    val isRunning: Boolean
        get() = server != null && isServiceReady

    fun isSubscribed(peerAddress: String): Boolean = subscribedDevices[peerAddress] == true

    fun getNegotiatedAttValueLength(peerAddress: String): Int =
        deviceMtu[peerAddress] ?: BleConnection.DEFAULT_MAX_ATT_VALUE_LENGTH

    fun getConnectedDeviceCount(): Int = connectedDevices.size

    fun isDeviceAdmitted(peerAddress: String): Boolean = connectedDevices.containsKey(peerAddress)

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            val gen = serverGeneration
            if (server == null || gen != pendingServiceGeneration || service !== pendingService) {
                return
            }
            pendingService = null
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
                if (connectedDevices.containsKey(address)) {
                    // Idempotent reconnect / update for already-admitted device
                    connectedDevices[address] = device
                } else if (connectedDevices.size >= MAX_ADMITTED_CLIENTS) {
                    // Enforce hard capacity bound: reject 8th device immediately
                    try {
                        server?.cancelConnection(device)
                    } catch (_: Exception) {}
                    return
                } else {
                    val pGen = globalPeerGenCounter.incrementAndGet()
                    peerGenerations[address] = pGen
                    connectedDevices[address] = device
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectedDevices.remove(address)
                subscribedDevices.remove(address)
                deviceMtu.remove(address)
                peerGenerations.remove(address)
                val pending = pendingNotification
                if (pending != null && pending.deviceAddress == address) {
                    pendingNotification = null
                    pending.deferred.complete(false)
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
            val address = device.address ?: return

            // Unadmitted devices cannot read LinkInfo or any characteristic
            if (!connectedDevices.containsKey(address)) {
                s.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                return
            }

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

            // Unadmitted devices cannot write to LinkInfo or Inbox
            if (!connectedDevices.containsKey(address)) {
                if (responseNeeded) {
                    s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                }
                return
            }

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

            // Unadmitted devices cannot write to descriptors
            if (!connectedDevices.containsKey(address)) {
                if (responseNeeded) {
                    server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                }
                return
            }

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
            if (!connectedDevices.containsKey(address)) {
                return
            }
            val maxAttLen = maxOf(20, mtu - 3)
            deviceMtu[address] = maxAttLen
            onMtuChanged(address, maxAttLen)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val address = device.address ?: return
            val pending = pendingNotification ?: return
            val currentPeerGen = peerGenerations[address]

            // Verify device address, notification generation, peer generation, and active admission
            if (pending.deviceAddress == address &&
                pending.notificationGeneration == notificationGeneration &&
                currentPeerGen != null &&
                pending.peerGeneration == currentPeerGen &&
                connectedDevices.containsKey(address)
            ) {
                pendingNotification = null
                pending.deferred.complete(status == BluetoothGatt.GATT_SUCCESS)
            }
        }
    }

    fun start(): Boolean {
        if (server != null) return true

        val manager = context.getSystemService(BluetoothManager::class.java) ?: return false
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        val gen = ++serverGeneration
        serviceRegistrationEpoch = gen
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

        pendingServiceGeneration = gen
        pendingService = service

        val addInitiated = gattServer.addService(service)
        if (!addInitiated) {
            stop()
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
     *
     * On timeout: invalidates the peer's physical channel and disconnects the device so that no further
     * notification may be sent on the same ambiguous physical generation.
     */
    suspend fun sendNotification(deviceAddress: String, value: ByteArray): Boolean = notificationMutex.withLock {
        val s = server ?: return false
        val ch = inboxCharacteristic ?: return false
        val device = connectedDevices[deviceAddress] ?: return false

        if (subscribedDevices[deviceAddress] != true) {
            return false
        }

        val pGen = peerGenerations[deviceAddress] ?: return false
        val gen = ++notificationGeneration
        val deferred = CompletableDeferred<Boolean>()
        pendingNotification = PendingNotification(gen, pGen, deviceAddress, deferred)

        ch.value = value
        val initiated = s.notifyCharacteristicChanged(device, ch, false)
        if (!initiated) {
            pendingNotification = null
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
            // Timeout reached: channel correlation is ambiguous.
            // Invalidate notification generation AND tear down this physical connection relation.
            notificationGeneration++
            pendingNotification = null
            invalidatePeerPhysicalConnection(deviceAddress, device)
            return false
        }
        return result
    }

    private fun invalidatePeerPhysicalConnection(deviceAddress: String, device: BluetoothDevice?) {
        connectedDevices.remove(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        peerGenerations.remove(deviceAddress)
        try {
            if (device != null) {
                server?.cancelConnection(device)
            }
        } catch (_: Exception) {}
        onSubscriptionChanged(deviceAddress, false)
        onClientDisconnected(deviceAddress)
    }

    fun stop() {
        serverGeneration++
        serviceRegistrationEpoch = serverGeneration
        notificationGeneration++
        isServiceReady = false
        pendingService = null
        pendingNotification?.deferred?.complete(false)
        pendingNotification = null
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
        peerGenerations.clear()
    }

    companion object {
        const val MAX_ADMITTED_CLIENTS = 7
        const val NOTIFICATION_TIMEOUT_MS = 5000L
    }
}
