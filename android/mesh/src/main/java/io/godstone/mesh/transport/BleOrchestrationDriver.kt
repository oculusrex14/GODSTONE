package io.godstone.mesh.transport

/**
 * Authoritative production orchestration driver for BLE link state transitions, capacity bounding,
 * role election, and callback correlation (ADR-002, Phase C8.4D1-R2.3).
 *
 * Used by production BleTransport, GattClient, and BleGattServer and driven directly by host orchestration tests.
 */

sealed interface BleCentralAction {
    data class ConnectGatt(val peerAddress: String) : BleCentralAction
    data class DiscoverServices(val peerAddress: String) : BleCentralAction
    data class ReadLinkInfo(val peerAddress: String) : BleCentralAction
    data class WriteLinkInfo(val peerAddress: String, val localBytes: ByteArray, val remoteHint: ByteArray) : BleCentralAction
    data class SubscribeCccd(val peerAddress: String) : BleCentralAction
    data class DisconnectGatt(val peerAddress: String, val reason: String) : BleCentralAction
    data class PublishFound(val peerAddress: String, val rssi: Int?) : BleCentralAction
    data class PublishLost(val peerAddress: String) : BleCentralAction
    data object NoOp : BleCentralAction
}

class BleCentralOrchestrationDriver(
    val localHint: ByteArray,
    val localLinkInfoProvider: () -> ByteArray?,
    val maxActiveConnections: Int = BleTransport.MAX_ACTIVE_CONNECTIONS,
    private val globalCapacity: BleGlobalCapacityAuthority? = null
) {
    init {
        require(localHint.size == BleRoleElection.NODE_HINT_BYTES) {
            "localHint must be 4 bytes"
        }
    }

    private val activeConnections = mutableMapOf<String, BleConnection>()
    private val discoveredHints = mutableMapOf<String, ByteArray>()
    private val peerRssi = mutableMapOf<String, Int>()
    private val publishedFound = mutableSetOf<String>()

    fun getActiveConnection(peerAddress: String): BleConnection? = activeConnections[peerAddress]
    fun getActiveConnectionCount(): Int = activeConnections.size
    fun isPublishedFound(peerAddress: String): Boolean = publishedFound.contains(peerAddress)

    fun onScanResult(peerAddress: String, rssi: Int?, serviceDataHint: ByteArray?): BleCentralAction {
        if (serviceDataHint != null && serviceDataHint.size == BleRoleElection.NODE_HINT_BYTES) {
            discoveredHints[peerAddress] = serviceDataHint.copyOf()
        }
        if (rssi != null) {
            peerRssi[peerAddress] = rssi
        }

        val existing = activeConnections[peerAddress]
        if (existing != null && existing.isActive) {
            return BleCentralAction.NoOp
        }

        if (globalCapacity != null) {
            if (!globalCapacity.tryAdmitOutbound()) {
                return BleCentralAction.NoOp
            }
        } else {
            if (activeConnections.size >= maxActiveConnections) {
                return BleCentralAction.NoOp
            }
        }

        val conn = BleConnection(peerAddress.toByteArray())
        activeConnections[peerAddress] = conn
        return BleCentralAction.ConnectGatt(peerAddress)
    }

    fun onGattConnected(peerAddress: String, gattGeneration: Long, currentGattGen: Long): BleCentralAction {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (conn.state != BleConnectionState.PROVISIONAL_CONNECTING) return BleCentralAction.NoOp
        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        return BleCentralAction.DiscoverServices(peerAddress)
    }

    fun onServicesDiscovered(peerAddress: String, success: Boolean, gattGeneration: Long, currentGattGen: Long): BleCentralAction {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            globalCapacity?.releaseOutbound()
            return BleCentralAction.DisconnectGatt(peerAddress, "Service discovery failed")
        }
        if (conn.state != BleConnectionState.PROVISIONAL_CONNECTED) return BleCentralAction.NoOp
        conn.transitionTo(BleConnectionState.LINK_INFO_READING)
        return BleCentralAction.ReadLinkInfo(peerAddress)
    }

    fun onLinkInfoReadResult(peerAddress: String, rawBytes: ByteArray?, gattGeneration: Long, currentGattGen: Long): BleCentralAction {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (conn.state != BleConnectionState.LINK_INFO_READING) return BleCentralAction.NoOp

        if (rawBytes == null || rawBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            globalCapacity?.releaseOutbound()
            return BleCentralAction.DisconnectGatt(peerAddress, "Malformed or missing LinkInfo")
        }

        val remoteInfo = BleLinkInfoCodec.decode(rawBytes)
        if (remoteInfo == null) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            globalCapacity?.releaseOutbound()
            return BleCentralAction.DisconnectGatt(peerAddress, "Malformed LinkInfo")
        }

        val election = BleRoleElection.elect(localHint, remoteInfo.nodeHint)
        return when (election) {
            is BleRoleElectionResult.Elected -> {
                if (election.role == BleRole.INITIATOR) {
                    val localBytes = localLinkInfoProvider()
                    if (localBytes == null || localBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
                        conn.transitionTo(BleConnectionState.CLOSED)
                        activeConnections.remove(peerAddress)
                        globalCapacity?.releaseOutbound()
                        return BleCentralAction.DisconnectGatt(peerAddress, "Local LinkInfo unavailable")
                    }
                    conn.transitionTo(BleConnectionState.LINK_INFO_WRITING)
                    BleCentralAction.WriteLinkInfo(peerAddress, localBytes, remoteInfo.nodeHint)
                } else {
                    // Local > remote: We are responder; central link is wrong direction -> drop
                    conn.transitionTo(BleConnectionState.CLOSED)
                    activeConnections.remove(peerAddress)
                    globalCapacity?.releaseOutbound()
                    BleCentralAction.DisconnectGatt(peerAddress, "Elected RESPONDER on central link")
                }
            }
            BleRoleElectionResult.Tie, is BleRoleElectionResult.Invalid -> {
                conn.transitionTo(BleConnectionState.CLOSED)
                activeConnections.remove(peerAddress)
                globalCapacity?.releaseOutbound()
                BleCentralAction.DisconnectGatt(peerAddress, "Role election tie or invalid")
            }
        }
    }

    fun onLinkInfoWriteAcknowledged(peerAddress: String, success: Boolean, remoteHint: ByteArray, gattGeneration: Long, currentGattGen: Long): BleCentralAction {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (conn.state != BleConnectionState.LINK_INFO_WRITING) return BleCentralAction.NoOp

        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            globalCapacity?.releaseOutbound()
            return BleCentralAction.DisconnectGatt(peerAddress, "LinkInfo write failed")
        }

        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint)
        return BleCentralAction.SubscribeCccd(peerAddress)
    }

    fun onCccdWriteAcknowledged(peerAddress: String, success: Boolean, gattGeneration: Long, currentGattGen: Long): BleCentralAction {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (!conn.isRoleBound) return BleCentralAction.NoOp

        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            globalCapacity?.releaseOutbound()
            return BleCentralAction.DisconnectGatt(peerAddress, "CCCD subscription failed")
        }

        conn.isNotificationSubscribed = true
        if (conn.isHandshakeTransportReady && !publishedFound.contains(peerAddress)) {
            publishedFound.add(peerAddress)
            return BleCentralAction.PublishFound(peerAddress, peerRssi[peerAddress])
        }
        return BleCentralAction.NoOp
    }

    fun onMtuChanged(peerAddress: String, mtu: Int) {
        val conn = activeConnections[peerAddress] ?: return
        conn.maxAttValueLength = maxOf(20, mtu - 3)
    }

    fun onDisconnected(peerAddress: String): BleCentralAction {
        if (activeConnections.remove(peerAddress) != null) {
            globalCapacity?.releaseOutbound()
        }
        val wasPublished = publishedFound.remove(peerAddress)
        if (wasPublished) {
            return BleCentralAction.PublishLost(peerAddress)
        }
        return BleCentralAction.NoOp
    }
}

sealed interface BleServerAction {
    data class AdmitConnection(val deviceAddress: String) : BleServerAction
    data class RejectConnection(val deviceAddress: String) : BleServerAction
    data class SendReadResponse(val deviceAddress: String, val bytes: ByteArray) : BleServerAction
    data class RejectRead(val deviceAddress: String) : BleServerAction
    data class AcceptWrite(val deviceAddress: String, val remoteHint: ByteArray) : BleServerAction
    data class AcceptWriteAndPublishFound(val deviceAddress: String, val remoteHint: ByteArray) : BleServerAction
    data class RejectWrite(val deviceAddress: String, val reason: String) : BleServerAction
    data class AcceptDescriptorWrite(val deviceAddress: String, val isSubscribed: Boolean) : BleServerAction
    data class AcceptDescriptorWriteAndPublishFound(val deviceAddress: String) : BleServerAction
    data class RejectDescriptorWrite(val deviceAddress: String) : BleServerAction
    data class TearDownPhysicalChannel(val deviceAddress: String) : BleServerAction
    data object PoisonServer : BleServerAction
    data class NotificationSuccess(val deviceAddress: String) : BleServerAction
    data class NotificationFailure(val deviceAddress: String) : BleServerAction
    data object NoOp : BleServerAction
}

class BleServerOrchestrationDriver(
    val localHint: ByteArray,
    val localLinkInfoProvider: () -> ByteArray?,
    val maxAdmittedClients: Int = BleGattServer.MAX_ADMITTED_CLIENTS,
    private val globalCapacity: BleGlobalCapacityAuthority? = null
) {
    init {
        require(localHint.size == BleRoleElection.NODE_HINT_BYTES) {
            "localHint must be 4 bytes"
        }
    }

    private var serverCallbackEpoch: Long = 0
    private var isPoisoned: Boolean = false
    var isServerReady: Boolean = false
        private set

    private var pendingNotificationAddress: String? = null

    private val admittedDevices = mutableSetOf<String>()
    private val subscribedDevices = mutableSetOf<String>()
    private val deviceMtu = mutableMapOf<String, Int>()
    private val peerGenerations = mutableMapOf<String, Long>()
    private val inboundConnections = mutableMapOf<String, BleConnection>()
    private val publishedFound = mutableSetOf<String>()

    fun getAdmittedCount(): Int = admittedDevices.size
    fun isDeviceAdmitted(deviceAddress: String): Boolean = admittedDevices.contains(deviceAddress)
    fun isDeviceSubscribed(deviceAddress: String): Boolean = subscribedDevices.contains(deviceAddress)
    fun getInboundConnection(deviceAddress: String): BleConnection? = inboundConnections[deviceAddress]

    fun startNewServerEpoch(): Long {
        isPoisoned = false
        isServerReady = false
        serverCallbackEpoch++
        
        admittedDevices.clear()
        subscribedDevices.clear()
        deviceMtu.clear()
        peerGenerations.clear()
        inboundConnections.clear()
        publishedFound.clear()
        pendingNotificationAddress = null
        return serverCallbackEpoch
    }

    fun onServiceAdded(epoch: Long, success: Boolean): Boolean {
        if (epoch != serverCallbackEpoch) return false
        if (success) {
            isServerReady = true
            return true
        }
        return false
    }

    fun onClientConnected(deviceAddress: String, peerGeneration: Long): BleServerAction {
        if (isPoisoned) return BleServerAction.RejectConnection(deviceAddress)

        if (admittedDevices.contains(deviceAddress)) {
            // Idempotent reconnect update
            peerGenerations[deviceAddress] = peerGeneration
            return BleServerAction.AdmitConnection(deviceAddress)
        }

        if (globalCapacity != null) {
            if (!globalCapacity.tryAdmitInbound()) {
                return BleServerAction.RejectConnection(deviceAddress)
            }
        } else {
            if (admittedDevices.size >= maxAdmittedClients) {
                return BleServerAction.RejectConnection(deviceAddress)
            }
        }

        admittedDevices.add(deviceAddress)
        peerGenerations[deviceAddress] = peerGeneration
        val conn = BleConnection(deviceAddress.toByteArray())
        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        inboundConnections[deviceAddress] = conn
        return BleServerAction.AdmitConnection(deviceAddress)
    }

    fun onClientDisconnected(deviceAddress: String): BleServerAction {
        if (admittedDevices.remove(deviceAddress)) {
            globalCapacity?.releaseInbound()
        }
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        peerGenerations.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        publishedFound.remove(deviceAddress)
        if (pendingNotificationAddress == deviceAddress) {
            pendingNotificationAddress = null
        }
        return BleServerAction.NoOp
    }

    fun onLinkInfoReadRequest(deviceAddress: String): BleServerAction {
        if (isPoisoned) return BleServerAction.RejectRead(deviceAddress)
        if (!admittedDevices.contains(deviceAddress)) {
            return BleServerAction.RejectRead(deviceAddress)
        }
        val bytes = localLinkInfoProvider()
        if (bytes == null || bytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            return BleServerAction.RejectRead(deviceAddress)
        }
        return BleServerAction.SendReadResponse(deviceAddress, bytes)
    }

    fun onLinkInfoWriteRequest(deviceAddress: String, rawBytes: ByteArray): BleServerAction {
        if (isPoisoned) return BleServerAction.RejectWrite(deviceAddress, "Server is poisoned")
        if (!admittedDevices.contains(deviceAddress)) {
            return BleServerAction.RejectWrite(deviceAddress, "Unadmitted client")
        }
        val conn = inboundConnections[deviceAddress] ?: return BleServerAction.RejectWrite(deviceAddress, "No active connection")
        if (conn.state != BleConnectionState.PROVISIONAL_CONNECTED) {
            return BleServerAction.RejectWrite(deviceAddress, "Connection state is not PROVISIONAL_CONNECTED")
        }

        val remoteInfo = BleLinkInfoCodec.decode(rawBytes)
            ?: return BleServerAction.RejectWrite(deviceAddress, "Malformed LinkInfo payload")

        val election = BleRoleElection.elect(localHint, remoteInfo.nodeHint)
        return when (election) {
            is BleRoleElectionResult.Elected -> {
                if (election.role == BleRole.RESPONDER) {
                    // Central is initiator, we are RESPONDER -> accept write and bind responder
                    conn.bindResponderFromAcceptedIncomingLinkInfo(remoteInfo.nodeHint)
                    if (subscribedDevices.contains(deviceAddress)) {
                        conn.isNotificationSubscribed = true
                    }
                    if (conn.isHandshakeTransportReady && !publishedFound.contains(deviceAddress)) {
                        publishedFound.add(deviceAddress)
                        BleServerAction.AcceptWriteAndPublishFound(deviceAddress, remoteInfo.nodeHint)
                    } else {
                        BleServerAction.AcceptWrite(deviceAddress, remoteInfo.nodeHint)
                    }
                } else {
                    BleServerAction.RejectWrite(deviceAddress, "Central is not initiator")
                }
            }
            BleRoleElectionResult.Tie, is BleRoleElectionResult.Invalid -> {
                BleServerAction.RejectWrite(deviceAddress, "Tie or invalid role election")
            }
        }
    }

    fun onDescriptorWriteRequest(deviceAddress: String, isSubscribed: Boolean): BleServerAction {
        if (isPoisoned) return BleServerAction.RejectDescriptorWrite(deviceAddress)
        if (!admittedDevices.contains(deviceAddress)) {
            return BleServerAction.RejectDescriptorWrite(deviceAddress)
        }
        val conn = inboundConnections[deviceAddress] ?: return BleServerAction.RejectDescriptorWrite(deviceAddress)

        if (isSubscribed) {
            subscribedDevices.add(deviceAddress)
            conn.isNotificationSubscribed = true
        } else {
            subscribedDevices.remove(deviceAddress)
            conn.isNotificationSubscribed = false
        }

        if (conn.isHandshakeTransportReady && !publishedFound.contains(deviceAddress)) {
            publishedFound.add(deviceAddress)
            return BleServerAction.AcceptDescriptorWriteAndPublishFound(deviceAddress)
        }
        return BleServerAction.AcceptDescriptorWrite(deviceAddress, isSubscribed)
    }

    fun onMtuChanged(deviceAddress: String, mtu: Int) {
        if (!admittedDevices.contains(deviceAddress)) return
        val maxAttLen = maxOf(20, mtu - 3)
        deviceMtu[deviceAddress] = maxAttLen
        val conn = inboundConnections[deviceAddress] ?: return
        conn.maxAttValueLength = maxAttLen
    }

    fun beginNotification(deviceAddress: String): Boolean {
        if (isPoisoned) return false
        if (!admittedDevices.contains(deviceAddress)) return false
        pendingNotificationAddress = deviceAddress
        return true
    }

    fun onNotificationTimeout(deviceAddress: String): BleServerAction {
        isPoisoned = true
        pendingNotificationAddress = null
        if (admittedDevices.remove(deviceAddress)) {
            globalCapacity?.releaseInbound()
        }
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        peerGenerations.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        publishedFound.remove(deviceAddress)
        return BleServerAction.PoisonServer
    }

    fun onNotificationSent(
        deviceAddress: String,
        statusSuccess: Boolean
    ): BleServerAction {
        if (isPoisoned) return BleServerAction.NoOp
        if (pendingNotificationAddress != deviceAddress) return BleServerAction.NoOp
        pendingNotificationAddress = null
        if (!admittedDevices.contains(deviceAddress)) return BleServerAction.NoOp
        return if (statusSuccess) {
            BleServerAction.NotificationSuccess(deviceAddress)
        } else {
            BleServerAction.NotificationFailure(deviceAddress)
        }
    }
}
