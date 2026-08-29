package io.godstone.mesh.transport

/**
 * Authoritative production orchestration driver for BLE link state transitions, capacity bounding,
 * role election, and callback correlation (ADR-002, Phase C8.4D1-R2.6).
 *
 * Used by production BleTransport, GattClient, and BleGattServer and driven directly by host orchestration tests.
 */

data class BleElectionContext(
    val remoteLinkInfo: BleLinkInfoV1,
    val remoteNodeHint: ByteArray,
    val relationGen: Long,
    val gattGen: Long,
    val opGen: Long
)

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

    private val lock = Any()
    private val activeConnections = mutableMapOf<String, BleConnection>()
    private val connectionGenerations = mutableMapOf<String, Long>()
    private val activeLeases = mutableMapOf<String, CapacityLease>()
    private val electionContexts = mutableMapOf<String, BleElectionContext>()
    private val discoveredHints = mutableMapOf<String, ByteArray>()
    private val peerRssi = mutableMapOf<String, Int>()
    private val publishedFound = mutableSetOf<String>()

    fun getActiveConnection(peerAddress: String): BleConnection? = synchronized(lock) {
        activeConnections[peerAddress]
    }

    fun getActiveConnectionCount(): Int = synchronized(lock) {
        activeConnections.size
    }

    fun getActiveLease(peerAddress: String): CapacityLease? = synchronized(lock) {
        activeLeases[peerAddress]
    }

    fun getElectionContext(peerAddress: String): BleElectionContext? = synchronized(lock) {
        electionContexts[peerAddress]
    }

    fun getConnectionGeneration(peerAddress: String): Long = synchronized(lock) {
        connectionGenerations[peerAddress] ?: 0L
    }

    fun isPublishedFound(peerAddress: String): Boolean = synchronized(lock) {
        publishedFound.contains(peerAddress)
    }

    private fun releaseLeaseLocked(peerAddress: String) {
        val lease = activeLeases.remove(peerAddress)
        if (lease != null && globalCapacity != null) {
            globalCapacity.releaseLease(lease)
        }
    }

    fun onScanResult(peerAddress: String, rssi: Int?, serviceDataHint: ByteArray?): BleCentralAction = synchronized(lock) {
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

        val nextGen = (connectionGenerations[peerAddress] ?: 0L) + 1L
        if (globalCapacity != null) {
            val lease = globalCapacity.tryAdmitOutbound(peerAddress, nextGen)
            if (lease == null) {
                return BleCentralAction.NoOp
            }
            activeLeases[peerAddress] = lease
        } else {
            if (activeConnections.size >= maxActiveConnections) {
                return BleCentralAction.NoOp
            }
        }

        connectionGenerations[peerAddress] = nextGen
        val conn = BleConnection(peerAddress.toByteArray())
        activeConnections[peerAddress] = conn
        BleCentralAction.ConnectGatt(peerAddress)
    }

    fun onGattConnected(peerAddress: String, gattGeneration: Long, currentGattGen: Long): BleCentralAction = synchronized(lock) {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (conn.state != BleConnectionState.PROVISIONAL_CONNECTING) return BleCentralAction.NoOp
        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        BleCentralAction.DiscoverServices(peerAddress)
    }

    fun onServicesDiscovered(peerAddress: String, success: Boolean, gattGeneration: Long, currentGattGen: Long): BleCentralAction = synchronized(lock) {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            return BleCentralAction.DisconnectGatt(peerAddress, "Service discovery failed")
        }
        if (conn.state != BleConnectionState.PROVISIONAL_CONNECTED) return BleCentralAction.NoOp
        conn.transitionTo(BleConnectionState.LINK_INFO_READING)
        BleCentralAction.ReadLinkInfo(peerAddress)
    }

    fun onLinkInfoReadResult(peerAddress: String, rawBytes: ByteArray?, gattGeneration: Long, currentGattGen: Long): BleCentralAction = synchronized(lock) {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (conn.state != BleConnectionState.LINK_INFO_READING) return BleCentralAction.NoOp

        if (rawBytes == null || rawBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            return BleCentralAction.DisconnectGatt(peerAddress, "Malformed or missing LinkInfo")
        }

        val remoteInfo = BleLinkInfoCodec.decode(rawBytes)
        if (remoteInfo == null) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            return BleCentralAction.DisconnectGatt(peerAddress, "Malformed LinkInfo")
        }

        val election = BleRoleElection.elect(localHint, remoteInfo.nodeHint)
        when (election) {
            is BleRoleElectionResult.Elected -> {
                if (election.role == BleRole.INITIATOR) {
                    val localBytes = localLinkInfoProvider()
                    if (localBytes == null || localBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
                        conn.transitionTo(BleConnectionState.CLOSED)
                        activeConnections.remove(peerAddress)
                        electionContexts.remove(peerAddress)
                        releaseLeaseLocked(peerAddress)
                        return BleCentralAction.DisconnectGatt(peerAddress, "Local LinkInfo unavailable")
                    }
                    val relGen = connectionGenerations[peerAddress] ?: 0L
                    electionContexts[peerAddress] = BleElectionContext(
                        remoteLinkInfo = remoteInfo,
                        remoteNodeHint = remoteInfo.nodeHint.copyOf(),
                        relationGen = relGen,
                        gattGen = gattGeneration,
                        opGen = currentGattGen
                    )
                    conn.transitionTo(BleConnectionState.LINK_INFO_WRITING)
                    BleCentralAction.WriteLinkInfo(peerAddress, localBytes, remoteInfo.nodeHint)
                } else {
                    // Local > remote: We are responder; central link is wrong direction -> drop
                    conn.transitionTo(BleConnectionState.CLOSED)
                    activeConnections.remove(peerAddress)
                    electionContexts.remove(peerAddress)
                    releaseLeaseLocked(peerAddress)
                    BleCentralAction.DisconnectGatt(peerAddress, "Elected RESPONDER on central link")
                }
            }
            BleRoleElectionResult.Tie, is BleRoleElectionResult.Invalid -> {
                conn.transitionTo(BleConnectionState.CLOSED)
                activeConnections.remove(peerAddress)
                electionContexts.remove(peerAddress)
                releaseLeaseLocked(peerAddress)
                BleCentralAction.DisconnectGatt(peerAddress, "Role election tie or invalid")
            }
        }
    }

    fun onLinkInfoWriteAcknowledged(
        peerAddress: String,
        success: Boolean,
        fallbackRemoteHint: ByteArray = ByteArray(0),
        gattGeneration: Long,
        currentGattGen: Long
    ): BleCentralAction = synchronized(lock) {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (conn.state != BleConnectionState.LINK_INFO_WRITING) return BleCentralAction.NoOp

        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            return BleCentralAction.DisconnectGatt(peerAddress, "LinkInfo write failed")
        }

        val remoteHint = electionContexts[peerAddress]?.remoteNodeHint ?: fallbackRemoteHint
        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint)
        BleCentralAction.SubscribeCccd(peerAddress)
    }

    fun onCccdWriteAcknowledged(peerAddress: String, success: Boolean, gattGeneration: Long, currentGattGen: Long): BleCentralAction = synchronized(lock) {
        if (gattGeneration != currentGattGen) return BleCentralAction.NoOp
        val conn = activeConnections[peerAddress] ?: return BleCentralAction.NoOp
        if (!conn.isRoleBound) return BleCentralAction.NoOp

        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            return BleCentralAction.DisconnectGatt(peerAddress, "CCCD subscription failed")
        }

        conn.isNotificationSubscribed = true
        if (conn.isHandshakeTransportReady && !publishedFound.contains(peerAddress)) {
            publishedFound.add(peerAddress)
            return BleCentralAction.PublishFound(peerAddress, peerRssi[peerAddress])
        }
        BleCentralAction.NoOp
    }

    fun onMtuChanged(peerAddress: String, mtu: Int) = synchronized(lock) {
        val conn = activeConnections[peerAddress] ?: return
        conn.maxAttValueLength = maxOf(20, mtu - 3)
    }

    fun onProvisionalTimeout(peerAddress: String, expectedGen: Long = 0L): BleCentralAction = synchronized(lock) {
        val currentGen = connectionGenerations[peerAddress] ?: 0L
        if (expectedGen != 0L && currentGen != expectedGen) {
            return BleCentralAction.NoOp
        }
        val conn = activeConnections.remove(peerAddress)
        if (conn != null) {
            conn.transitionTo(BleConnectionState.CLOSED)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            publishedFound.remove(peerAddress)
            return BleCentralAction.DisconnectGatt(peerAddress, "Provisional timeout")
        }
        BleCentralAction.NoOp
    }

    fun onDisconnected(peerAddress: String): BleCentralAction = synchronized(lock) {
        if (activeConnections.remove(peerAddress) != null) {
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
        }
        val wasPublished = publishedFound.remove(peerAddress)
        if (wasPublished) {
            return BleCentralAction.PublishLost(peerAddress)
        }
        BleCentralAction.NoOp
    }

    fun reset() = synchronized(lock) {
        for ((_, conn) in activeConnections) {
            conn.transitionTo(BleConnectionState.CLOSED)
        }
        activeConnections.clear()
        connectionGenerations.clear()
        activeLeases.clear()
        electionContexts.clear()
        discoveredHints.clear()
        peerRssi.clear()
        publishedFound.clear()
        globalCapacity?.releaseAllOutbound()
    }
}

sealed interface BleServerAction {
    data class AdmitConnection(val deviceAddress: String) : BleServerAction
    data class RejectConnection(val deviceAddress: String) : BleServerAction
    data class SendReadResponse(val deviceAddress: String, val bytes: ByteArray) : BleServerAction
    data class RejectRead(val deviceAddress: String) : BleServerAction
    data class AcceptWrite(val deviceAddress: String, val remoteInfo: BleLinkInfoV1) : BleServerAction
    data class AcceptWriteAndPublishFound(val deviceAddress: String, val remoteInfo: BleLinkInfoV1) : BleServerAction
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

    private val lock = Any()
    private var serverCallbackEpoch: Long = 0
    private var isPoisoned: Boolean = false
    var isServerReady: Boolean = false
        private set

    private var pendingNotificationAddress: String? = null

    private val admittedDevices = mutableSetOf<String>()
    private val subscribedDevices = mutableSetOf<String>()
    private val deviceMtu = mutableMapOf<String, Int>()
    private val peerGenerations = mutableMapOf<String, Long>()
    private val inboundLeases = mutableMapOf<String, CapacityLease>()
    private val inboundConnections = mutableMapOf<String, BleConnection>()
    private val acceptedRemoteLinkInfo = mutableMapOf<String, BleLinkInfoV1>()
    private val publishedFound = mutableSetOf<String>()

    fun getAdmittedCount(): Int = synchronized(lock) { admittedDevices.size }
    fun isDeviceAdmitted(deviceAddress: String): Boolean = synchronized(lock) { admittedDevices.contains(deviceAddress) }
    fun isDeviceSubscribed(deviceAddress: String): Boolean = synchronized(lock) { subscribedDevices.contains(deviceAddress) }
    fun getInboundConnection(deviceAddress: String): BleConnection? = synchronized(lock) { inboundConnections[deviceAddress] }
    fun getInboundLease(deviceAddress: String): CapacityLease? = synchronized(lock) { inboundLeases[deviceAddress] }
    fun getAcceptedRemoteLinkInfo(deviceAddress: String): BleLinkInfoV1? = synchronized(lock) { acceptedRemoteLinkInfo[deviceAddress] }

    private fun releaseLeaseLocked(deviceAddress: String) {
        val lease = inboundLeases.remove(deviceAddress)
        if (lease != null && globalCapacity != null) {
            globalCapacity.releaseLease(lease)
        }
    }

    fun startNewServerEpoch(): Long = synchronized(lock) {
        isPoisoned = false
        isServerReady = false
        serverCallbackEpoch++

        for ((_, conn) in inboundConnections) {
            conn.transitionTo(BleConnectionState.CLOSED)
        }
        admittedDevices.clear()
        subscribedDevices.clear()
        deviceMtu.clear()
        peerGenerations.clear()
        inboundLeases.clear()
        inboundConnections.clear()
        acceptedRemoteLinkInfo.clear()
        publishedFound.clear()
        pendingNotificationAddress = null
        globalCapacity?.releaseAllInbound()
        serverCallbackEpoch
    }

    fun onServiceAdded(epoch: Long, success: Boolean): Boolean = synchronized(lock) {
        if (epoch != serverCallbackEpoch || isPoisoned) return false
        if (success) {
            isServerReady = true
            return true
        }
        false
    }

    fun onClientConnected(deviceAddress: String, peerGeneration: Long): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.RejectConnection(deviceAddress)

        if (admittedDevices.contains(deviceAddress)) {
            peerGenerations[deviceAddress] = peerGeneration
            return BleServerAction.AdmitConnection(deviceAddress)
        }

        if (globalCapacity != null) {
            val lease = globalCapacity.tryAdmitInbound(deviceAddress, peerGeneration)
            if (lease == null) {
                return BleServerAction.RejectConnection(deviceAddress)
            }
            inboundLeases[deviceAddress] = lease
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
        BleServerAction.AdmitConnection(deviceAddress)
    }

    fun onClientDisconnected(deviceAddress: String): BleServerAction = synchronized(lock) {
        admittedDevices.remove(deviceAddress)
        releaseLeaseLocked(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        peerGenerations.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        acceptedRemoteLinkInfo.remove(deviceAddress)
        publishedFound.remove(deviceAddress)
        if (pendingNotificationAddress == deviceAddress) {
            pendingNotificationAddress = null
        }
        BleServerAction.NoOp
    }

    fun onLinkInfoReadRequest(deviceAddress: String): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.RejectRead(deviceAddress)
        if (!admittedDevices.contains(deviceAddress)) {
            return BleServerAction.RejectRead(deviceAddress)
        }
        val bytes = localLinkInfoProvider()
        if (bytes == null || bytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            return BleServerAction.RejectRead(deviceAddress)
        }
        BleServerAction.SendReadResponse(deviceAddress, bytes)
    }

    private fun rejectAndTeardownLocked(deviceAddress: String, reason: String): BleServerAction {
        admittedDevices.remove(deviceAddress)
        releaseLeaseLocked(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        peerGenerations.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        acceptedRemoteLinkInfo.remove(deviceAddress)
        publishedFound.remove(deviceAddress)
        return BleServerAction.RejectWrite(deviceAddress, reason)
    }

    fun onLinkInfoWriteRequest(deviceAddress: String, rawBytes: ByteArray): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.RejectWrite(deviceAddress, "Server is poisoned")
        if (!admittedDevices.contains(deviceAddress)) {
            return BleServerAction.RejectWrite(deviceAddress, "Unadmitted client")
        }
        val conn = inboundConnections[deviceAddress] ?: return BleServerAction.RejectWrite(deviceAddress, "No active connection")
        if (conn.state != BleConnectionState.PROVISIONAL_CONNECTED) {
            return BleServerAction.RejectWrite(deviceAddress, "Connection state is not PROVISIONAL_CONNECTED")
        }

        val remoteInfo = BleLinkInfoCodec.decode(rawBytes)
        if (remoteInfo == null) {
            return rejectAndTeardownLocked(deviceAddress, "Malformed LinkInfo payload")
        }

        val election = BleRoleElection.elect(localHint, remoteInfo.nodeHint)
        when (election) {
            is BleRoleElectionResult.Elected -> {
                if (election.role == BleRole.RESPONDER) {
                    conn.bindResponderFromAcceptedIncomingLinkInfo(remoteInfo.nodeHint)
                    acceptedRemoteLinkInfo[deviceAddress] = remoteInfo
                    if (subscribedDevices.contains(deviceAddress)) {
                        conn.isNotificationSubscribed = true
                    }
                    if (conn.isHandshakeTransportReady && !publishedFound.contains(deviceAddress)) {
                        publishedFound.add(deviceAddress)
                        BleServerAction.AcceptWriteAndPublishFound(deviceAddress, remoteInfo)
                    } else {
                        BleServerAction.AcceptWrite(deviceAddress, remoteInfo)
                    }
                } else {
                    rejectAndTeardownLocked(deviceAddress, "Central is not initiator")
                }
            }
            BleRoleElectionResult.Tie, is BleRoleElectionResult.Invalid -> {
                rejectAndTeardownLocked(deviceAddress, "Tie or invalid role election")
            }
        }
    }

    fun onDescriptorWriteRequest(deviceAddress: String, isSubscribed: Boolean): BleServerAction = synchronized(lock) {
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
        BleServerAction.AcceptDescriptorWrite(deviceAddress, isSubscribed)
    }

    fun onInboundTimeout(deviceAddress: String, expectedGen: Long = 0L): BleServerAction = synchronized(lock) {
        val currentGen = peerGenerations[deviceAddress] ?: 0L
        if (expectedGen != 0L && currentGen != expectedGen) {
            return BleServerAction.NoOp
        }
        val conn = inboundConnections[deviceAddress]
        if (conn != null && !conn.isHandshakeTransportReady) {
            admittedDevices.remove(deviceAddress)
            releaseLeaseLocked(deviceAddress)
            subscribedDevices.remove(deviceAddress)
            deviceMtu.remove(deviceAddress)
            peerGenerations.remove(deviceAddress)
            inboundConnections.remove(deviceAddress)?.transitionTo(BleConnectionState.CLOSED)
            acceptedRemoteLinkInfo.remove(deviceAddress)
            publishedFound.remove(deviceAddress)
            return BleServerAction.TearDownPhysicalChannel(deviceAddress)
        }
        BleServerAction.NoOp
    }

    fun onMtuChanged(deviceAddress: String, mtu: Int) = synchronized(lock) {
        if (!admittedDevices.contains(deviceAddress)) return
        val maxAttLen = maxOf(20, mtu - 3)
        deviceMtu[deviceAddress] = maxAttLen
        val conn = inboundConnections[deviceAddress] ?: return
        conn.maxAttValueLength = maxAttLen
    }

    fun beginNotification(deviceAddress: String): Boolean = synchronized(lock) {
        if (isPoisoned) return false
        if (!admittedDevices.contains(deviceAddress)) return false
        pendingNotificationAddress = deviceAddress
        true
    }

    fun onNotificationTimeout(deviceAddress: String): BleServerAction = synchronized(lock) {
        isPoisoned = true
        pendingNotificationAddress = null
        admittedDevices.remove(deviceAddress)
        releaseLeaseLocked(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        peerGenerations.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        acceptedRemoteLinkInfo.remove(deviceAddress)
        publishedFound.remove(deviceAddress)
        BleServerAction.PoisonServer
    }

    fun onNotificationSent(
        deviceAddress: String,
        statusSuccess: Boolean
    ): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.NoOp
        if (pendingNotificationAddress != deviceAddress) return BleServerAction.NoOp
        pendingNotificationAddress = null
        if (!admittedDevices.contains(deviceAddress)) return BleServerAction.NoOp
        if (statusSuccess) {
            BleServerAction.NotificationSuccess(deviceAddress)
        } else {
            BleServerAction.NotificationFailure(deviceAddress)
        }
    }
}
