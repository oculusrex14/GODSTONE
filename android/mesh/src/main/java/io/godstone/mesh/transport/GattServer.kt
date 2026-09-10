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
import java.util.ArrayList
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

private data class PendingNotification(
    val notificationGeneration: Long,
    val peerGeneration: Long,
    val serverEpoch: Long,
    val deviceAddress: String,
    val deferred: CompletableDeferred<Boolean>
)

@SuppressLint("MissingPermission")
class BleGattServer(
    private val context: Context? = null,
    val serviceUuid: UUID = BleTransport.SERVICE_UUID,
    val inboxCharUuid: UUID = BleTransport.WRITE_CHAR_UUID,
    val digestCharUuid: UUID = BleTransport.DIGEST_CHAR_UUID,
    val linkInfoCharUuid: UUID = BleTransport.LINK_INFO_CHAR_UUID,
    val linkInfoProvider: () -> ByteArray? = { null },
    val isRoleBoundPredicate: (String) -> Boolean = { false },
    val onInboundWrite: (String, ByteArray) -> Unit = { _, _ -> },
    val onLinkInfoWrite: (String, ByteArray) -> Boolean = { _, _ -> false },
    val onSubscriptionChanged: (String, Boolean) -> Unit = { _, _ -> },
    val onClientDisconnected: (String, Long) -> Unit = { _, _ -> },
    val onMtuChanged: (String, Int) -> Unit = { _, _ -> },
    val onServiceStatusChanged: (Boolean) -> Unit = {},
    val onClientAdmitted: ((String, Long) -> Unit)? = null,
    private val orchestrationDriver: BleServerOrchestrationDriver? = null,
    private val notificationTimeoutMs: Long = NOTIFICATION_TIMEOUT_MS
) {
    private var server: BluetoothGattServer? = null
    private var inboxCharacteristic: BluetoothGattCharacteristic? = null
    private var digestCharacteristic: BluetoothGattCharacteristic? = null
    private var linkInfoCharacteristic: BluetoothGattCharacteristic? = null

    private val connectedDevices = ConcurrentHashMap<String, BluetoothDevice>()
    private val subscribedDevices = ConcurrentHashMap<String, Boolean>()
    private val deviceMtu = ConcurrentHashMap<String, Int>()
    private val peerGenerations = ConcurrentHashMap<String, Long>()
    private val notificationMutex = Mutex()

    private var pendingNotification: PendingNotification? = null
    private var notificationGeneration: Long = 0L

    /**
     * T12: tokens for connection arrivals. Each platform connection event
     * is stamped with its own never-reused generation at the callback
     * boundary, so admissions never correlate an absent token to the
     * current slot by deriving from it.
     */
    private val connectionArrivals = AtomicLong(1L)

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

    /**
     * T09 test/diagnostic seam: records the service registration outcome the
     * platform callback would report (the same transition performed inside
     * makeServerCallback). Production never calls this; JVM tests and the
     * lab diagnostics use it to exercise the advertising gate without a radio
     * stack. The backing field is the single authority the
     * [BleTransport.canonicalAdvertiseSettings] readiness gate reads.
     */
    internal fun markServiceReadyForTest(ready: Boolean) {
        isServiceReady = ready
    }

    @Volatile
    var isPoisoned: Boolean = false
        private set

    private var activeCallback: BluetoothGattServerCallback? = null

    val isRunning: Boolean
        get() = server != null && isServiceReady && !isPoisoned

    fun isSubscribed(peerAddress: String): Boolean = subscribedDevices[peerAddress] == true

    fun getNegotiatedAttValueLength(peerAddress: String): Int =
        deviceMtu[peerAddress] ?: BleConnection.DEFAULT_MAX_ATT_VALUE_LENGTH

    fun getConnectedDeviceCount(): Int =
        orchestrationDriver?.getAdmittedCount() ?: connectedDevices.size

    fun isDeviceAdmitted(peerAddress: String): Boolean =
        orchestrationDriver?.isDeviceAdmitted(peerAddress) ?: connectedDevices.containsKey(peerAddress)

    fun getActiveCallback(): BluetoothGattServerCallback? = activeCallback

    fun cancelConnection(peerAddress: String) {
        val device = connectedDevices[peerAddress]
        if (device != null) {
            try {
                server?.cancelConnection(device)
            } catch (_: Exception) {}
        }
    }

    fun processConnectionStateChange(address: String, status: Int, newState: Int, device: BluetoothDevice? = null) {
        if (isPoisoned) return

        if (newState == BluetoothProfile.STATE_CONNECTED) {
            if (orchestrationDriver != null) {
                val action = orchestrationDriver.onClientConnected(address, connectionArrivals.getAndIncrement())
                if (action is BleServerAction.AdmitConnection) {
                    val gen = action.generation
                    if (device != null) {
                        connectedDevices[address] = device
                    }
                    peerGenerations[address] = gen
                    onClientAdmitted?.invoke(address, gen)
                } else {
                    if (device != null) {
                        try {
                            server?.cancelConnection(device)
                        } catch (_: Exception) {}
                    }
                }
            } else if (connectedDevices.containsKey(address) || connectedDevices.size >= MAX_ADMITTED_CLIENTS) {
                if (device != null) {
                    try {
                        server?.cancelConnection(device)
                    } catch (_: Exception) {}
                }
            } else {
                val gen = 1L
                if (device != null) {
                    connectedDevices[address] = device
                }
                peerGenerations[address] = gen
                onClientAdmitted?.invoke(address, gen)
            }
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            // T12: the disconnection event is delivered with the registered
            // handle value of this facade's own registry; the driver matches
            // it exactly and treats a foreign or already terminal slot as an
            // idempotent no-op.
            val driver = orchestrationDriver
            val action = driver?.let { it.onClientDisconnected(address, it.getClientGeneration(address)) }
            if (action is BleServerAction.TearDownPhysicalChannel) {
                val retiredGen = action.generation
                peerGenerations.remove(address)
                connectedDevices.remove(address)
                subscribedDevices.remove(address)
                deviceMtu.remove(address)
                val pending = pendingNotification
                if (pending != null && pending.deviceAddress == address) {
                    pendingNotification = null
                    pending.deferred.complete(false)
                }
                onSubscriptionChanged(address, false)
                onClientDisconnected(address, retiredGen)
            } else {
                connectedDevices.remove(address)
            }
        }
    }

    fun makeServerCallback(callbackEpoch: Long): BluetoothGattServerCallback {
        return object : BluetoothGattServerCallback() {
            override fun onServiceAdded(status: Int, service: BluetoothGattService) {
                if (callbackEpoch != serverGeneration || isPoisoned) return
                if (server == null || callbackEpoch != pendingServiceGeneration || service !== pendingService) {
                    return
                }
                pendingService = null
                val success = status == BluetoothGatt.GATT_SUCCESS && service.uuid == serviceUuid
                if (orchestrationDriver != null) {
                    val ready = orchestrationDriver.onServiceAdded(callbackEpoch, success)
                    isServiceReady = ready
                    onServiceStatusChanged(ready)
                } else {
                    if (success) {
                        isServiceReady = true
                        onServiceStatusChanged(true)
                    } else {
                        isServiceReady = false
                        onServiceStatusChanged(false)
                    }
                }
            }

            override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
                if (callbackEpoch != serverGeneration || isPoisoned) return
                val address = device.address ?: return
                processConnectionStateChange(address, status, newState, device)
            }

            override fun onCharacteristicReadRequest(
                device: BluetoothDevice,
                requestId: Int,
                offset: Int,
                characteristic: BluetoothGattCharacteristic
            ) {
                if (callbackEpoch != serverGeneration || isPoisoned) return
                val s = server ?: return
                val address = device.address ?: return

                if (classifyInbound(characteristic.uuid) === InboundRoute.TO_LINK_INFO) {
                    if (orchestrationDriver != null) {
                        val action = orchestrationDriver.onLinkInfoReadRequest(address)
                        when (action) {
                            is BleServerAction.SendReadResponse -> {
                                s.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, action.bytes)
                            }
                            else -> {
                                s.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                            }
                        }
                    } else {
                        val data = linkInfoProvider()
                        if (data != null && data.size == BleLinkInfoConstants.LINK_INFO_BYTES) {
                            s.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, data)
                        } else {
                            s.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                        }
                    }
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
                if (callbackEpoch != serverGeneration || isPoisoned) return
                val s = server
                val address = device.address ?: return

                if (classifyInbound(characteristic.uuid) === InboundRoute.TO_LINK_INFO) {
                    if (offset != 0 || preparedWrite) {
                        if (responseNeeded) {
                            s?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                        }
                        return
                    }

                    if (orchestrationDriver != null) {
                        val action = orchestrationDriver.onLinkInfoWriteRequest(address, value)
                        when (action) {
                            is BleServerAction.AcceptWrite,
                            is BleServerAction.AcceptDuplicateWrite,
                            is BleServerAction.AcceptWriteAndPublishFound -> {
                                val accepted = onLinkInfoWrite(address, value)
                                if (accepted) {
                                    if (responseNeeded) s?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                                } else {
                                    if (responseNeeded) s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                                    connectedDevices.remove(address)
                                    try {
                                        s?.cancelConnection(device)
                                    } catch (_: Exception) {}
                                }
                            }
                            is BleServerAction.RejectWrite -> {
                                if (responseNeeded) s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                                connectedDevices.remove(address)
                                try {
                                    s?.cancelConnection(device)
                                } catch (_: Exception) {}
                            }
                            else -> {
                                if (responseNeeded) s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                                connectedDevices.remove(address)
                                try {
                                    s?.cancelConnection(device)
                                } catch (_: Exception) {}
                            }
                        }
                    } else {
                        if (!connectedDevices.containsKey(address)) {
                            if (responseNeeded) s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                            return
                        }
                        val accepted = onLinkInfoWrite(address, value)
                        if (accepted) {
                            if (responseNeeded) s?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                        } else {
                            if (responseNeeded) s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                            connectedDevices.remove(address)
                            try {
                                s?.cancelConnection(device)
                            } catch (_: Exception) {}
                        }
                    }
                    return
                }

                if (classifyInbound(characteristic.uuid) === InboundRoute.TO_DEFRAMER) {
                    if (orchestrationDriver != null && !orchestrationDriver.isDeviceAdmitted(address)) {
                        if (responseNeeded) {
                            s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                        }
                        return
                    } else if (orchestrationDriver == null && !connectedDevices.containsKey(address)) {
                        if (responseNeeded) {
                            s?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                        }
                        return
                    }

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
                if (callbackEpoch != serverGeneration || isPoisoned) return
                val address = device.address ?: return

                if (descriptor.uuid == GattClientConnection.CCCD_UUID) {
                    val isSub = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)

                    val owner = descriptor.characteristic?.uuid
                    if (owner != null && owner != inboxCharUuid) {
                        // T10: a CCC write on a non-inbox descriptor (the digest now
                        // carries one too) is accepted silently at the attribute
                        // layer, mirroring CoreBluetooth whose didSubscribe filters
                        // non-inbox subscriptions. It must not touch the inbox
                        // subscription state nor the duplex-ready emission.
                        if (responseNeeded) {
                            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                        }
                        return
                    }

                    if (orchestrationDriver != null) {
                        val action = orchestrationDriver.onDescriptorWriteRequest(address, isSub)
                        when (action) {
                            is BleServerAction.AcceptDescriptorWrite,
                            is BleServerAction.AcceptDescriptorWriteAndPublishFound -> {
                                subscribedDevices[address] = isSub
                                onSubscriptionChanged(address, isSub)
                                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                            }
                            is BleServerAction.RejectDescriptorWrite -> {
                                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                            }
                            else -> {
                                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                            }
                        }
                    } else {
                        if (!connectedDevices.containsKey(address)) {
                            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, offset, null)
                            return
                        }
                        if (isSub) {
                            subscribedDevices[address] = true
                            onSubscriptionChanged(address, true)
                        } else if (value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)) {
                            subscribedDevices.remove(address)
                            onSubscriptionChanged(address, false)
                        }
                        if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
                    }
                } else {
                    if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_REQUEST_NOT_SUPPORTED, offset, null)
                }
            }

            override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
                if (callbackEpoch != serverGeneration || isPoisoned) return
                val address = device.address ?: return
                if (orchestrationDriver != null) {
                    orchestrationDriver.onMtuChanged(address, mtu)
                }
                if (!connectedDevices.containsKey(address)) {
                    return
                }
                val maxAttLen = maxOf(20, mtu - 3)
                deviceMtu[address] = maxAttLen
                onMtuChanged(address, maxAttLen)
            }

            override fun onNotificationSent(device: BluetoothDevice, status: Int) {
                if (callbackEpoch != serverGeneration || isPoisoned) return
                val address = device.address ?: return
                if (orchestrationDriver != null) {
                    val action = orchestrationDriver.onNotificationSent(address, status == BluetoothGatt.GATT_SUCCESS)
                    if (action is BleServerAction.NoOp && !orchestrationDriver.isDeviceAdmitted(address)) {
                        return
                    }
                }

                val pending = pendingNotification ?: return
                val currentPeerGen = peerGenerations[address]

                if (pending.deviceAddress == address &&
                    pending.notificationGeneration == notificationGeneration &&
                    pending.serverEpoch == callbackEpoch &&
                    currentPeerGen != null &&
                    pending.peerGeneration == currentPeerGen &&
                    connectedDevices.containsKey(address)
                ) {
                    pendingNotification = null
                    pending.deferred.complete(status == BluetoothGatt.GATT_SUCCESS)
                }
            }
        }
    }

    fun dispatchServiceAdded(status: Int, service: BluetoothGattService, callback: BluetoothGattServerCallback? = null) =
        (callback ?: activeCallback)?.onServiceAdded(status, service)

    fun dispatchConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int, callback: BluetoothGattServerCallback? = null) =
        (callback ?: activeCallback)?.onConnectionStateChange(device, status, newState)

    fun dispatchCharacteristicReadRequest(
        device: BluetoothDevice,
        requestId: Int,
        offset: Int,
        characteristic: BluetoothGattCharacteristic,
        callback: BluetoothGattServerCallback? = null
    ) = (callback ?: activeCallback)?.onCharacteristicReadRequest(device, requestId, offset, characteristic)

    fun dispatchCharacteristicWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        characteristic: BluetoothGattCharacteristic,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray,
        callback: BluetoothGattServerCallback? = null
    ) = (callback ?: activeCallback)?.onCharacteristicWriteRequest(device, requestId, characteristic, preparedWrite, responseNeeded, offset, value)

    fun dispatchDescriptorWriteRequest(
        device: BluetoothDevice,
        requestId: Int,
        descriptor: BluetoothGattDescriptor,
        preparedWrite: Boolean,
        responseNeeded: Boolean,
        offset: Int,
        value: ByteArray,
        callback: BluetoothGattServerCallback? = null
    ) = (callback ?: activeCallback)?.onDescriptorWriteRequest(device, requestId, descriptor, preparedWrite, responseNeeded, offset, value)

    fun dispatchMtuChanged(device: BluetoothDevice, mtu: Int, callback: BluetoothGattServerCallback? = null) =
        (callback ?: activeCallback)?.onMtuChanged(device, mtu)

    fun dispatchNotificationSent(device: BluetoothDevice, status: Int, callback: BluetoothGattServerCallback? = null) =
        (callback ?: activeCallback)?.onNotificationSent(device, status)

    internal fun setServerGenerationForTesting(gen: Long) {
        serverGeneration = gen
    }

    fun start(): Boolean {
        if (server != null && !isPoisoned) return true

        val manager = context?.getSystemService(BluetoothManager::class.java) ?: return false
        val adapter = manager.adapter ?: return false
        if (!adapter.isEnabled) return false

        isPoisoned = false
        var gen = serverGeneration
        if (orchestrationDriver != null) {
            gen = orchestrationDriver.startNewServerEpoch()
            serverGeneration = gen
        } else {
            gen = ++serverGeneration
        }
        serviceRegistrationEpoch = gen
        val currentCallback = makeServerCallback(gen)
        activeCallback = currentCallback
        val gattServer = manager.openGattServer(context, currentCallback) ?: return false

        val installed = ArrayList<BluetoothGattCharacteristic>()
        for (entry in serverBlueprint()) {
            installed.add(buildCharacteristic(entry))
        }

        val service = BluetoothGattService(
            serviceUuid,
            BluetoothGattService.SERVICE_TYPE_PRIMARY
        )
        for (characteristic in installed) {
            service.addCharacteristic(characteristic)
        }

        pendingServiceGeneration = gen
        pendingService = service

        val addInitiated = gattServer.addService(service)
        if (!addInitiated) {
            stop()
            return false
        }

        server = gattServer
        inboxCharacteristic = installed.firstOrNull { it.uuid == inboxCharUuid }
        digestCharacteristic = installed.firstOrNull { it.uuid == digestCharUuid }
        linkInfoCharacteristic = installed.firstOrNull { it.uuid == linkInfoCharUuid }
        return true
    }

    /**
     * T10: the canonical service tree the server installs, read from the
     * generated wire contract through RequiredCharacteristicSet. One service,
     * three characteristics, exact property sets; the legacy FD short-form
     * values are never named here.
     */
    fun serverBlueprint(): List<ContractCharacteristic> =
        RequiredCharacteristicSet.MESH.characteristics

    /**
     * The one platform mapping: contract entry to installed object, a single
     * data-driven loop over the blueprint. Every notify characteristic gains
     * the CCC descriptor (CoreBluetooth attaches the same one implicitly on
     * its platform side), so a subscribing central can enable notifications
     * of inbox and digest alike.
     */
    private fun buildCharacteristic(entry: ContractCharacteristic): BluetoothGattCharacteristic {
        val characteristic = BluetoothGattCharacteristic(
            entry.uuid,
            RequiredCharacteristicSet.maskOf(entry.properties),
            RequiredCharacteristicSet.permissionsFor(entry.properties)
        )
        if (entry.properties.contains(GattProperty.NOTIFY)) {
            characteristic.addDescriptor(
                BluetoothGattDescriptor(
                    GattClientConnection.CCCD_UUID,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
                )
            )
        }
        return characteristic
    }

    /**
     * T10 inbound routing decision by uuid equality against the configured
     * roles: LinkInfo records go to the link info store, never through the
     * record decoder; frame records go to the record decoder; anything else
     * is answered request-not-supported, including the legacy FD values.
     */
    fun classifyInbound(uuid: UUID): InboundRoute = when (uuid) {
        linkInfoCharUuid -> InboundRoute.TO_LINK_INFO
        inboxCharUuid -> InboundRoute.TO_DEFRAMER
        else -> InboundRoute.NOT_SUPPORTED
    }

    suspend fun sendNotificationTyped(deviceAddress: String, value: ByteArray): WriteCompletion = notificationMutex.withLock {
        if (isPoisoned) return WriteCompletion.Failed
        val s = server ?: return WriteCompletion.Failed
        val ch = inboxCharacteristic ?: return WriteCompletion.Failed
        val device = connectedDevices[deviceAddress] ?: return WriteCompletion.Failed

        if (orchestrationDriver != null) {
            // T18: the driver's admission control refused the value: the
            // outlet's own buffer is full, not the relation nor the record.
            if (!orchestrationDriver.beginNotification(deviceAddress)) return WriteCompletion.QueueFull
        }

        if (subscribedDevices[deviceAddress] != true) {
            return WriteCompletion.Failed
        }

        val pGen = peerGenerations[deviceAddress] ?: return WriteCompletion.Failed
        val epoch = serverGeneration
        val gen = ++notificationGeneration
        val deferred = CompletableDeferred<Boolean>()
        pendingNotification = PendingNotification(gen, pGen, epoch, deviceAddress, deferred)

        ch.value = value
        val initiated = s.notifyCharacteristicChanged(device, ch, false)
        if (!initiated) {
            // T18: the stack refused to start the write: busy, retry later.
            pendingNotification = null
            return WriteCompletion.QueueFull
        }

        val result = withTimeoutOrNull(notificationTimeoutMs) {
            try {
                deferred.await()
            } catch (_: Exception) {
                false
            }
        }

        if (result == null) {
            notificationGeneration++
            pendingNotification = null
            if (orchestrationDriver != null) {
                val action = orchestrationDriver.onNotificationTimeout(deviceAddress)
                if (action is BleServerAction.PoisonServer) {
                    isPoisoned = true
                    stop()
                    onServiceStatusChanged(false)
                }
            } else {
                invalidatePeerPhysicalConnection(deviceAddress, device)
            }
            return WriteCompletion.Failed
        }
        return if (result) WriteCompletion.Accepted else WriteCompletion.Failed
    }

    /** The Boolean voice of the leg, kept for its existing callers:
     * a value counts as travelled only when the completion is Accepted. */
    suspend fun sendNotification(deviceAddress: String, value: ByteArray): Boolean =
        sendNotificationTyped(deviceAddress, value) == WriteCompletion.Accepted

    private fun invalidatePeerPhysicalConnection(deviceAddress: String, device: BluetoothDevice?) {
        val pGen = peerGenerations.remove(deviceAddress) ?: 0L
        connectedDevices.remove(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        try {
            if (device != null) {
                server?.cancelConnection(device)
            }
        } catch (_: Exception) {}
        onSubscriptionChanged(deviceAddress, false)
        onClientDisconnected(deviceAddress, pGen)
    }

    fun stop() {
        var gen = serverGeneration
        if (orchestrationDriver != null) {
            gen = orchestrationDriver.startNewServerEpoch()
            serverGeneration = gen
        } else {
            gen = ++serverGeneration
        }
        serviceRegistrationEpoch = gen
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
        activeCallback = null
        inboxCharacteristic = null
        digestCharacteristic = null
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
