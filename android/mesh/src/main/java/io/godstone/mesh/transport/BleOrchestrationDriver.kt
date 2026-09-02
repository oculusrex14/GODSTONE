package io.godstone.mesh.transport

/**
 * Authoritative production orchestration driver for BLE link state transitions, capacity bounding,
 * role election, and callback correlation (ADR-002, Phase C8.4D1-R2.8).
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

enum class OutboundPeerSlotState {
    IDLE,
    ACTIVE,
    CLOSING
}

data class OutboundPeerSlot(
    val state: OutboundPeerSlotState,
    val generation: Long,
    val peerAddress: String,
    val lease: CapacityLease? = null
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
    private val outboundSlots = mutableMapOf<String, OutboundPeerSlot>()

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

    fun getOutboundSlot(peerAddress: String): OutboundPeerSlot? = synchronized(lock) {
        outboundSlots[peerAddress]
    }

    fun getOutboundSlotState(peerAddress: String): OutboundPeerSlotState = synchronized(lock) {
        outboundSlots[peerAddress]?.state ?: OutboundPeerSlotState.IDLE
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

        val slot = outboundSlots[peerAddress]
        if (slot?.state == OutboundPeerSlotState.CLOSING ||
            slot?.state == OutboundPeerSlotState.ACTIVE
        ) {
            return BleCentralAction.NoOp
        }

        val existing = activeConnections[peerAddress]
        if (existing != null && existing.isActive) {
            return BleCentralAction.NoOp
        }

        val nextGen = (connectionGenerations[peerAddress] ?: 0L) + 1L
        val lease = if (globalCapacity != null) {
            val l = globalCapacity.tryAdmitOutbound(peerAddress, nextGen)
            if (l == null) return BleCentralAction.NoOp
            l
        } else {
            if (activeConnections.size >= maxActiveConnections) {
                return BleCentralAction.NoOp
            }
            null
        }

        connectionGenerations[peerAddress] = nextGen
        if (lease != null) {
            activeLeases[peerAddress] = lease
        }
        val conn = BleConnection(peerAddress.toByteArray())
        activeConnections[peerAddress] = conn
        outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.ACTIVE, nextGen, peerAddress, lease)
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
        val gen = connectionGenerations[peerAddress] ?: 0L
        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
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
        val gen = connectionGenerations[peerAddress] ?: 0L

        if (rawBytes == null || rawBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
            return BleCentralAction.DisconnectGatt(peerAddress, "Malformed or missing LinkInfo")
        }

        val remoteInfo = BleLinkInfoCodec.decode(rawBytes)
        if (remoteInfo == null) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
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
                        outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
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
                    conn.transitionTo(BleConnectionState.CLOSED)
                    activeConnections.remove(peerAddress)
                    electionContexts.remove(peerAddress)
                    releaseLeaseLocked(peerAddress)
                    outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
                    BleCentralAction.DisconnectGatt(peerAddress, "Elected RESPONDER on central link")
                }
            }
            BleRoleElectionResult.Tie, is BleRoleElectionResult.Invalid -> {
                conn.transitionTo(BleConnectionState.CLOSED)
                activeConnections.remove(peerAddress)
                electionContexts.remove(peerAddress)
                releaseLeaseLocked(peerAddress)
                outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
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
        val gen = connectionGenerations[peerAddress] ?: 0L

        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
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
        val gen = connectionGenerations[peerAddress] ?: 0L

        if (!success) {
            conn.transitionTo(BleConnectionState.CLOSED)
            activeConnections.remove(peerAddress)
            electionContexts.remove(peerAddress)
            releaseLeaseLocked(peerAddress)
            outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, gen, peerAddress, null)
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
            outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.CLOSING, currentGen, peerAddress, null)
            return BleCentralAction.DisconnectGatt(peerAddress, "Provisional timeout")
        }
        BleCentralAction.NoOp
    }

    fun onDisconnected(peerAddress: String, expectedGen: Long = 0L): BleCentralAction = synchronized(lock) {
        val slot = outboundSlots[peerAddress]
        val currentGen = slot?.generation ?: (connectionGenerations[peerAddress] ?: 0L)
        if (expectedGen != 0L && currentGen != expectedGen) {
            return BleCentralAction.NoOp
        }
        val conn = activeConnections.remove(peerAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        electionContexts.remove(peerAddress)
        releaseLeaseLocked(peerAddress)
        val wasPublished = publishedFound.remove(peerAddress)
        outboundSlots[peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.IDLE, currentGen, peerAddress, null)
        if (wasPublished) {
            BleCentralAction.PublishLost(peerAddress)
        } else {
            BleCentralAction.NoOp
        }
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
        outboundSlots.clear()
        globalCapacity?.releaseAllOutbound()
    }
}

enum class ServerPeerSlotState {
    IDLE,
    ACTIVE,
    CLOSING,
    QUARANTINED
}

data class ServerPeerSlot(
    val state: ServerPeerSlotState,
    val generation: Long,
    val deviceAddress: String,
    val lease: CapacityLease? = null
)

sealed interface BleServerAction {
    data class AdmitConnection(val deviceAddress: String, val generation: Long = 0L) : BleServerAction
    data class RejectConnection(val deviceAddress: String, val reason: String = "") : BleServerAction
    data class SendReadResponse(val deviceAddress: String, val bytes: ByteArray) : BleServerAction
    data class RejectRead(val deviceAddress: String) : BleServerAction
    data class AcceptWrite(val deviceAddress: String, val remoteInfo: BleLinkInfoV1) : BleServerAction
    data class AcceptDuplicateWrite(val deviceAddress: String, val remoteInfo: BleLinkInfoV1) : BleServerAction
    data class AcceptWriteAndPublishFound(val deviceAddress: String, val remoteInfo: BleLinkInfoV1) : BleServerAction
    data class RejectWrite(val deviceAddress: String, val reason: String) : BleServerAction
    data class AcceptDescriptorWrite(val deviceAddress: String, val isSubscribed: Boolean) : BleServerAction
    data class AcceptDescriptorWriteAndPublishFound(val deviceAddress: String) : BleServerAction
    data class RejectDescriptorWrite(val deviceAddress: String) : BleServerAction
    data class TearDownPhysicalChannel(val deviceAddress: String, val generation: Long = 0L) : BleServerAction
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
    private val peerSlots = mutableMapOf<String, ServerPeerSlot>()

    fun getAdmittedCount(): Int = synchronized(lock) { admittedDevices.size }
    fun isDeviceAdmitted(deviceAddress: String): Boolean = synchronized(lock) { admittedDevices.contains(deviceAddress) }
    fun isDeviceSubscribed(deviceAddress: String): Boolean = synchronized(lock) { subscribedDevices.contains(deviceAddress) }
    fun getInboundConnection(deviceAddress: String): BleConnection? = synchronized(lock) { inboundConnections[deviceAddress] }
    fun getInboundLease(deviceAddress: String): CapacityLease? = synchronized(lock) { inboundLeases[deviceAddress] }
    fun getAcceptedRemoteLinkInfo(deviceAddress: String): BleLinkInfoV1? = synchronized(lock) { acceptedRemoteLinkInfo[deviceAddress] }
    fun getClientGeneration(deviceAddress: String): Long = synchronized(lock) {
        peerSlots[deviceAddress]?.generation ?: (peerGenerations[deviceAddress] ?: 0L)
    }
    fun isPhysicalReady(deviceAddress: String): Boolean = synchronized(lock) { publishedFound.contains(deviceAddress) }
    fun getPeerSlot(deviceAddress: String): ServerPeerSlot? = synchronized(lock) { peerSlots[deviceAddress] }
    fun getPeerSlotState(deviceAddress: String): ServerPeerSlotState = synchronized(lock) {
        peerSlots[deviceAddress]?.state ?: ServerPeerSlotState.IDLE
    }

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
        inboundLeases.clear()
        inboundConnections.clear()
        acceptedRemoteLinkInfo.clear()
        publishedFound.clear()
        peerSlots.clear()
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

    fun onClientConnected(deviceAddress: String, peerGeneration: Long = 0L): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.RejectConnection(deviceAddress, "Server is poisoned")

        val slot = peerSlots[deviceAddress]
        if (slot?.state == ServerPeerSlotState.QUARANTINED) {
            return BleServerAction.RejectConnection(deviceAddress, "Client is QUARANTINED in current server epoch")
        }
        if (slot?.state == ServerPeerSlotState.ACTIVE) {
            return BleServerAction.RejectConnection(deviceAddress, "Client is already ACTIVE")
        }
        if (slot?.state == ServerPeerSlotState.CLOSING) {
            return BleServerAction.RejectConnection(deviceAddress, "Client slot is CLOSING")
        }

        val gen = if (peerGeneration > 0L) peerGeneration else (peerGenerations[deviceAddress] ?: 0L) + 1L
        val lease = if (globalCapacity != null) {
            val l = globalCapacity.tryAdmitInbound(deviceAddress, gen)
            if (l == null) {
                return BleServerAction.RejectConnection(deviceAddress, "Capacity exhausted")
            }
            l
        } else {
            if (admittedDevices.size >= maxAdmittedClients) {
                return BleServerAction.RejectConnection(deviceAddress, "Max admitted clients reached")
            }
            null
        }

        peerGenerations[deviceAddress] = gen
        if (lease != null) {
            inboundLeases[deviceAddress] = lease
        }
        admittedDevices.add(deviceAddress)
        val conn = BleConnection(deviceAddress.toByteArray())
        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        inboundConnections[deviceAddress] = conn
        peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.ACTIVE, gen, deviceAddress, lease)
        BleServerAction.AdmitConnection(deviceAddress, gen)
    }

    fun onClientDisconnected(deviceAddress: String, expectedGen: Long = 0L): BleServerAction = synchronized(lock) {
        val slot = peerSlots[deviceAddress]
        if (slot == null || slot.state == ServerPeerSlotState.IDLE) {
            return BleServerAction.NoOp
        }
        if (slot.state == ServerPeerSlotState.QUARANTINED) {
            return BleServerAction.NoOp
        }
        val gen = slot.generation
        if (expectedGen != 0L && gen != expectedGen) {
            return BleServerAction.NoOp
        }
        admittedDevices.remove(deviceAddress)
        releaseLeaseLocked(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        acceptedRemoteLinkInfo.remove(deviceAddress)
        publishedFound.remove(deviceAddress)
        if (pendingNotificationAddress == deviceAddress) {
            pendingNotificationAddress = null
        }
        peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.QUARANTINED, gen, deviceAddress, null)
        BleServerAction.TearDownPhysicalChannel(deviceAddress, gen)
    }

    fun onLinkInfoReadRequest(deviceAddress: String): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.RejectRead(deviceAddress)
        val slot = peerSlots[deviceAddress]
        if (slot?.state == ServerPeerSlotState.QUARANTINED) {
            return BleServerAction.RejectRead(deviceAddress)
        }
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
        val currentGen = peerGenerations[deviceAddress] ?: 0L
        admittedDevices.remove(deviceAddress)
        releaseLeaseLocked(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        acceptedRemoteLinkInfo.remove(deviceAddress)
        publishedFound.remove(deviceAddress)
        if (currentGen != 0L) {
            peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.CLOSING, currentGen, deviceAddress, null)
        }
        return BleServerAction.RejectWrite(deviceAddress, reason)
    }

    fun onLinkInfoWriteRequest(deviceAddress: String, rawBytes: ByteArray): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.RejectWrite(deviceAddress, "Server is poisoned")
        val slot = peerSlots[deviceAddress]
        if (slot?.state == ServerPeerSlotState.QUARANTINED) {
            return BleServerAction.RejectWrite(deviceAddress, "Client is QUARANTINED")
        }
        if (slot?.state == ServerPeerSlotState.CLOSING) {
            return BleServerAction.RejectWrite(deviceAddress, "Client slot is CLOSING")
        }
        if (!admittedDevices.contains(deviceAddress)) {
            return BleServerAction.RejectWrite(deviceAddress, "Unadmitted client")
        }
        val conn = inboundConnections[deviceAddress] ?: return BleServerAction.RejectWrite(deviceAddress, "No active connection")

        val remoteInfo = BleLinkInfoCodec.decode(rawBytes)
        if (remoteInfo == null) {
            return rejectAndTeardownLocked(deviceAddress, "Malformed LinkInfo payload")
        }

        // Exact duplicate handling on active / role-bound relation
        if (conn.isRoleBound || conn.state == BleConnectionState.READY) {
            val existing = acceptedRemoteLinkInfo[deviceAddress]
            if (existing != null) {
                val isExactDuplicate = (existing == remoteInfo)
                if (isExactDuplicate) {
                    if (conn.isHandshakeTransportReady && !publishedFound.contains(deviceAddress)) {
                        publishedFound.add(deviceAddress)
                        return BleServerAction.AcceptWriteAndPublishFound(deviceAddress, remoteInfo)
                    }
                    return BleServerAction.AcceptDuplicateWrite(deviceAddress, remoteInfo)
                } else {
                    return BleServerAction.RejectWrite(deviceAddress, "Conflicting LinkInfo write on active relation")
                }
            }
        }

        if (conn.state != BleConnectionState.PROVISIONAL_CONNECTED) {
            return BleServerAction.RejectWrite(deviceAddress, "Connection state is not PROVISIONAL_CONNECTED")
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
        val slot = peerSlots[deviceAddress]
        if (slot?.state == ServerPeerSlotState.QUARANTINED) {
            return BleServerAction.RejectDescriptorWrite(deviceAddress)
        }
        if (slot?.state == ServerPeerSlotState.CLOSING) {
            return BleServerAction.RejectDescriptorWrite(deviceAddress)
        }
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
        val slot = peerSlots[deviceAddress]
        val currentGen = slot?.generation ?: (peerGenerations[deviceAddress] ?: 0L)
        if (expectedGen != 0L && currentGen != expectedGen) {
            return BleServerAction.NoOp
        }
        val conn = inboundConnections[deviceAddress]
        if (conn != null && !conn.isHandshakeTransportReady) {
            admittedDevices.remove(deviceAddress)
            releaseLeaseLocked(deviceAddress)
            subscribedDevices.remove(deviceAddress)
            deviceMtu.remove(deviceAddress)
            inboundConnections.remove(deviceAddress)?.transitionTo(BleConnectionState.CLOSED)
            acceptedRemoteLinkInfo.remove(deviceAddress)
            publishedFound.remove(deviceAddress)
            peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.CLOSING, currentGen, deviceAddress, null)
            return BleServerAction.TearDownPhysicalChannel(deviceAddress, currentGen)
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
        val currentGen = peerGenerations[deviceAddress] ?: 0L
        admittedDevices.remove(deviceAddress)
        releaseLeaseLocked(deviceAddress)
        subscribedDevices.remove(deviceAddress)
        deviceMtu.remove(deviceAddress)
        val conn = inboundConnections.remove(deviceAddress)
        conn?.transitionTo(BleConnectionState.CLOSED)
        acceptedRemoteLinkInfo.remove(deviceAddress)
        publishedFound.remove(deviceAddress)
        if (currentGen != 0L) {
            peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.CLOSING, currentGen, deviceAddress, null)
        }
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

