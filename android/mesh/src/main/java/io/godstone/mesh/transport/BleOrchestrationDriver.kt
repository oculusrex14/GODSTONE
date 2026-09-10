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
    data class DisconnectGatt(val peerAddress: String, val reason: String, val generation: Long) : BleCentralAction
    data class PublishFound(val peerAddress: String, val rssi: Int?) : BleCentralAction
    /**
     * T12: the Lost publication effect names the exact relation that came
     * down. Its token travels with the effect; the executor never re-reads
     * the current registration to decide which publication to remove.
     */
    data class PublishLost(val peerAddress: String, val generation: Long) : BleCentralAction
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
    // T11: the hint and signal observations of the scan path share one
    // bounded surface, so a flood of distinct advertisers cannot grow the
    // caches without limit. Entries of currently active connections are
    // pinned: the bound evicts the least recently observed unpinned
    // entry, deterministically, in observation order.
    private val scanSurface = BoundedDiscoveryIndex<DriverScanRecord>(
        capacity = BleTransport.MAX_DISCOVERED_PEERS,
        isPinned = { address -> activeConnections[address]?.isActive == true }
    )

    /** Test seam: the bounded scan record of one address, or null. */
    internal fun driverScanRecordForTest(address: String): DriverScanRecord? = synchronized(lock) {
        scanSurface.valueOf(address)
    }

    /** Test seam: the size of the bounded scan surface. */
    internal fun driverScanCountForTest(): Int = synchronized(lock) {
        scanSurface.size
    }
    private val publishedFound = mutableSetOf<String>()
    private val outboundSlots = mutableMapOf<String, OutboundPeerSlot>()
    /** T12: the last terminated generation per address, for once-semantics. */
    private val terminatedOnce = mutableMapOf<String, Long>()

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

    private fun releaseLeaseLocked(deviceAddress: String): Boolean {
        val lease = activeLeases.remove(deviceAddress)
        if (lease != null && globalCapacity != null) {
            globalCapacity.releaseLease(lease)
            return true
        }
        return lease != null
    }

    fun onScanResult(peerAddress: String, rssi: Int?, serviceDataHint: ByteArray?): BleCentralAction = synchronized(lock) {
        if (serviceDataHint != null && serviceDataHint.size == BleRoleElection.NODE_HINT_BYTES) {
            val carried = serviceDataHint.copyOf()
            var record = scanSurface.valueOf(peerAddress)
            if (record == null) {
                record = DriverScanRecord()
            }
            record.absorb(carried, null)
            scanSurface.observe(peerAddress, record)
        }
        if (rssi != null) {
            var record = scanSurface.valueOf(peerAddress)
            if (record == null) {
                record = DriverScanRecord()
            }
            record.absorb(null, rssi)
            scanSurface.observe(peerAddress, record)
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
            terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
            return BleCentralAction.DisconnectGatt(peerAddress, "Service discovery failed", gen)
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
            terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
            return BleCentralAction.DisconnectGatt(peerAddress, "Malformed or missing LinkInfo", gen)
        }

        val remoteInfo = BleLinkInfoCodec.decode(rawBytes)
        if (remoteInfo == null) {
            terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
            return BleCentralAction.DisconnectGatt(peerAddress, "Malformed LinkInfo", gen)
        }

        val election = BleRoleElection.elect(localHint, remoteInfo.nodeHint)
        when (election) {
            is BleRoleElectionResult.Elected -> {
                if (election.role == BleRole.INITIATOR) {
                    val localBytes = localLinkInfoProvider()
                    if (localBytes == null || localBytes.size != BleLinkInfoConstants.LINK_INFO_BYTES) {
                        terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
                        return BleCentralAction.DisconnectGatt(peerAddress, "Local LinkInfo unavailable", gen)
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
                    terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
                    BleCentralAction.DisconnectGatt(peerAddress, "Elected RESPONDER on central link", gen)
                }
            }
            BleRoleElectionResult.Tie, is BleRoleElectionResult.Invalid -> {
                terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
                BleCentralAction.DisconnectGatt(peerAddress, "Role election tie or invalid", gen)
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
            terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
            return BleCentralAction.DisconnectGatt(peerAddress, "LinkInfo write failed", gen)
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
            terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, gen), TerminalReason.REJECTED))
            return BleCentralAction.DisconnectGatt(peerAddress, "CCCD subscription failed", gen)
        }

        conn.isNotificationSubscribed = true
        if (conn.isHandshakeTransportReady && !publishedFound.contains(peerAddress)) {
            publishedFound.add(peerAddress)
            return BleCentralAction.PublishFound(peerAddress, scanSurface.valueOf(peerAddress)?.rssi)
        }
        BleCentralAction.NoOp
    }

    fun onMtuChanged(peerAddress: String, mtu: Int) = synchronized(lock) {
        val conn = activeConnections[peerAddress] ?: return
        conn.maxAttValueLength = maxOf(20, mtu - 3)
    }

    fun onProvisionalTimeout(peerAddress: String, expectedGen: Long): BleCentralAction = synchronized(lock) {
        // T12: the timeout is a local termination. The exact relation goes
        // terminal here - slot at IDLE, lease released once, publication
        // taken down once - and the close of the captured handle is
        // scheduled as an effect. Nothing waits for a didDisconnect that a
        // locally closed handle can no longer deliver.
        val outcome = terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, expectedGen), TerminalReason.PROVISIONAL_TIMEOUT))
        if (!outcome.transitioned) {
            return BleCentralAction.NoOp
        }
        BleCentralAction.DisconnectGatt(peerAddress, "Provisional timeout", expectedGen)
    }

    fun onDisconnected(peerAddress: String, expectedGen: Long): BleCentralAction = synchronized(lock) {
        // T12: the platform terminal arrives with its exact token. The one
        // transition runs through the terminal authority; a repeat or a
        // foreign-generation event is refused there and stays silent here.
        val outcome = terminateLocked(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peerAddress, expectedGen), TerminalReason.PLATFORM_DISCONNECT))
        if (outcome.unpublishEffectPending) {
            BleCentralAction.PublishLost(peerAddress, expectedGen)
        } else {
            BleCentralAction.NoOp
        }
    }


    /**
     * T12: the one terminal authority for outbound attempts. The event
     * names the exact relation - direction, address and generation. Under
     * the driver lock that relation transitions to terminal: its lease
     * leaves the authority once (only the holder's own entry can leave,
     * the authority matches lease identity and generation), the
     * publication is taken down once, and the slot rests at IDLE of that
     * generation, awaiting no callback that could not arrive. The outcome
     * reports what this very event did, so callers schedule effects from
     * it instead of re-reading current state. A repeat event for the
     * same exact relation is idempotent; an event naming another
     * generation than the registered one is refused and changes nothing:
     * a late terminal of a dead attempt never disturbs the successor's
     * slot, lease or publication.
     */
    private fun terminateLocked(event: TerminalEvent): TerminalOutcome {
        val key = event.relationKey
        if (key.direction != BleDirection.OUTBOUND) {
            return TerminalOutcome(false, true, false, false, false)
        }
        val slot = outboundSlots[key.peerAddress]
        val conn = activeConnections[key.peerAddress]
        if (conn == null && (slot == null || slot.state == OutboundPeerSlotState.IDLE)) {
            val once = terminatedOnce[key.peerAddress] == key.generation
            return TerminalOutcome(false, !once, once, false, false)
        }
        val registeredGen = slot?.generation ?: (connectionGenerations[key.peerAddress] ?: 0L)
        if (registeredGen != key.generation) {
            return TerminalOutcome(false, true, false, false, false)
        }
        if (terminatedOnce[key.peerAddress] == key.generation) {
            return TerminalOutcome(false, false, true, false, false)
        }
        val hadConnection = conn != null
        releaseLeaseLocked(key.peerAddress)
        val wasPublished = publishedFound.remove(key.peerAddress)
        if (conn != null) {
            conn.transitionTo(BleConnectionState.CLOSED)
        }
        activeConnections.remove(key.peerAddress)
        electionContexts.remove(key.peerAddress)
        outboundSlots[key.peerAddress] = OutboundPeerSlot(OutboundPeerSlotState.IDLE, key.generation, key.peerAddress, null)
        terminatedOnce[key.peerAddress] = key.generation
        return TerminalOutcome(true, false, false, wasPublished, hadConnection)
    }

    /** The terminal authority under the driver lock, for callers outside. */
    fun terminate(event: TerminalEvent): TerminalOutcome = synchronized(lock) {
        terminateLocked(event)
    }

    /** Test seam: the registered outbound slot of one address. */
    internal fun outboundSlotForTest(peerAddress: String): OutboundPeerSlot? = synchronized(lock) {
        outboundSlots[peerAddress]
    }

    fun reset() = synchronized(lock) {
        for ((_, conn) in activeConnections) {
            conn.transitionTo(BleConnectionState.CLOSED)
        }
        activeConnections.clear()
        connectionGenerations.clear()
        activeLeases.clear()
        electionContexts.clear()
        terminatedOnce.clear()
        scanSurface.releaseAll()
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
    data class AdmitConnection(val deviceAddress: String, val generation: Long) : BleServerAction
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
    data class TearDownPhysicalChannel(val deviceAddress: String, val generation: Long) : BleServerAction
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

    fun onClientConnected(deviceAddress: String, peerGeneration: Long): BleServerAction = synchronized(lock) {
        if (isPoisoned) return BleServerAction.RejectConnection(deviceAddress, "Server is poisoned")
        if (peerGeneration <= 0L) {
            // T12: the connection arrival must carry its immutable token. An
            // absent token is refused, never correlated to the current slot.
            return BleServerAction.RejectConnection(deviceAddress, "Connection arrival must carry a positive generation token")
        }

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

        val gen = peerGeneration
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

    fun onClientDisconnected(deviceAddress: String, expectedGen: Long): BleServerAction = synchronized(lock) {
        // T12: the event names the exact registration it terminates. A
        // terminal slot (IDLE or QUARANTINED) makes the event idempotent;
        // a foreign generation is refused and changes nothing.
        val slot = peerSlots[deviceAddress]
        if (slot == null || slot.state == ServerPeerSlotState.IDLE) {
            return BleServerAction.NoOp
        }
        if (slot.state == ServerPeerSlotState.QUARANTINED) {
            return BleServerAction.NoOp
        }
        val gen = slot.generation
        if (gen != expectedGen) {
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
            // T12: local cancellation is terminal in itself; it awaits no
            // didDisconnect that a locally closed handle can no longer deliver.
            peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.QUARANTINED, currentGen, deviceAddress, null)
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

    fun onInboundTimeout(deviceAddress: String, expectedGen: Long): BleServerAction = synchronized(lock) {
        // T12: the timeout names the exact registration it ends. An event
        // for another generation is refused; it changes nothing.
        val slot = peerSlots[deviceAddress]
        val currentGen = slot?.generation ?: (peerGenerations[deviceAddress] ?: 0L)
        if (currentGen != expectedGen) {
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
            // T12: local cancellation is terminal in itself; it awaits no didDisconnect.
            peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.QUARANTINED, currentGen, deviceAddress, null)
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
            // T12: local cancellation is terminal in itself; it awaits no
            // didDisconnect that a locally closed handle can no longer deliver.
            peerSlots[deviceAddress] = ServerPeerSlot(ServerPeerSlotState.QUARANTINED, currentGen, deviceAddress, null)
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

