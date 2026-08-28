package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.wire.v2.FrameV2
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Snapshot of local discovery metadata broadcast in scan response (ADR-002 §2).
 */
data class BleDiscoverySnapshot(
    val shortDigest: ByteArray,
    val queueDepth: Int,
    val sosPresent: Boolean = false,
    val clockUntrusted: Boolean = false
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (javaClass != other?.javaClass) return false
        other as BleDiscoverySnapshot
        if (!shortDigest.contentEquals(other.shortDigest)) return false
        if (queueDepth != other.queueDepth) return false
        if (sosPresent != other.sosPresent) return false
        if (clockUntrusted != other.clockUntrusted) return false
        return true
    }

    override fun hashCode(): Int {
        var result = shortDigest.contentHashCode()
        result = 31 * result + queueDepth
        result = 31 * result + sosPresent.hashCode()
        result = 31 * result + clockUntrusted.hashCode()
        return result
    }
}

/**
 * Persistent duplex BLE control-plane substrate (ADR-002, Phase C8.4D1-A1/R2/R2.2).
 *
 * Implements:
 * - UUID-only discovery baseline and provisional GATT connections.
 * - Connect-First / Elect-Before-Handshake role binding via [BleRoleBindingCoordinator].
 * - Authoritative state progression: PROVISIONAL_CONNECTING -> PROVISIONAL_CONNECTED -> LINK_INFO_READING -> LINK_INFO_WRITING -> ROLE_BOUND.
 * - Canonical 13-byte LinkInfo GATT characteristic exchange via [LinkInfoSnapshotAuthority].
 * - Asynchronous GATT service readiness gating before advertising.
 * - Persistent bidirectional GATT client/server links.
 * - Connection-local [BleRecord] fragmentation/reassembly seam.
 * - Strict gating against application DATA transmission before cryptographic READY.
 * - Authoritative PeerEvent.Found publication only after physical duplex readiness (CCCD subscription + role binding).
 */
@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context,
    private val identity: Identity,
    private val digestProvider: (suspend () -> BloomDigest)? = null,
    /** Noise sessions. Without this the transport cannot send at all -- by design. */
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null,
    private val snapshotProvider: (() -> BleDiscoverySnapshot)? = null,
    private val store: MessageStore? = null,
    private val clientFactory: (
        context: Context,
        address: String,
        localLinkInfoProvider: () -> ByteArray?,
        coordinator: BleRoleBindingCoordinator,
        onInboundNotification: (ByteArray) -> Unit,
        onDisconnected: () -> Unit,
        onConnected: () -> Unit,
        onLinkInfoReadStarted: () -> Unit,
        onLinkInfoWriteStarted: () -> Unit,
        onRoleBound: (role: BleRole, remoteHint: ByteArray, remoteInfo: BleLinkInfoV1?) -> Unit,
        onSubscriptionReady: () -> Unit,
        onMtuUpdated: (Int) -> Unit
    ) -> GattClientConnection = { ctx, addr, linkInfoProv, coord, onInbound, onDisc, onConn, onReadStart, onWriteStart, onBound, onSubReady, onMtu ->
        GattClientConnection(
            context = ctx,
            peerAddress = addr,
            localLinkInfoProvider = linkInfoProv,
            coordinator = coord,
            onInboundNotification = onInbound,
            onDisconnected = onDisc,
            onConnected = onConn,
            onLinkInfoReadStarted = onReadStart,
            onLinkInfoWriteStarted = onWriteStart,
            onRoleBound = onBound,
            onSubscriptionReady = onSubReady,
            onMtuUpdated = onMtu
        )
    },
    private val coroutineScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) : Transport {

    override val name = "BLE"
    override val isBulkCapable = false

    private val btManager = context.getSystemService(BluetoothManager::class.java)
    private val adapter get() = btManager?.adapter

    private var powerState = PowerState.NORMAL
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null

    val roleCoordinator = BleRoleBindingCoordinator(identity.nodeHint)

    val snapshotAuthority = LinkInfoSnapshotAuthority(
        identityProvider = { identity },
        storeProvider = { store },
        powerStateProvider = { powerState }
    )

    // Owned peripheral GATT server
    private val gattServer: BleGattServer = BleGattServer(
        context = context,
        serviceUuid = SERVICE_UUID,
        inboxCharUuid = WRITE_CHAR_UUID,
        linkInfoCharUuid = LINK_INFO_CHAR_UUID,
        linkInfoProvider = { getLocalLinkInfoBytes() },
        onLinkInfoWrite = { peerAddress, value -> handleIncomingLinkInfoWrite(peerAddress, value) },
        isRoleBoundPredicate = { peerAddress -> activeConnections[peerAddress]?.isRoleBound == true },
        onInboundWrite = { peerAddress, value -> handleInboundAttValue(peerAddress, value) },
        onClientDisconnected = { peerAddress -> handlePeerDisconnected(peerAddress) },
        onSubscriptionChanged = { peerAddress, isSubscribed ->
            val conn = activeConnections[peerAddress]
            if (conn != null) {
                conn.isNotificationSubscribed = isSubscribed
                if (isSubscribed) {
                    val peerMacBytes = PeerId.fromAddress(peerAddress) ?: peerAddress.toByteArray()
                    emitFoundIfDuplexReady(peerAddress, peerMacBytes, conn)
                }
            }
        },
        onMtuChanged = { peerAddress, maxAttLen ->
            activeConnections[peerAddress]?.let { conn ->
                conn.maxAttValueLength = maxAttLen
                conn.markConnected(maxAttLen)
            }
        },
        onServiceStatusChanged = { isReady ->
            if (isReady && isStarted) {
                startAdvertising()
            }
        }
    )

    // Discovered peer cache (bounded to MAX_DISCOVERED_PEERS) - HINT ONLY
    private val discoveryLock = Any()
    private val discoveredPeers = LinkedHashMap<String, BleDiscoveryMetadata>()
    private val peerRssi = ConcurrentHashMap<String, Int>()

    // Pending remote LinkInfo metadata awaiting duplex readiness
    private val pendingRemoteLinkInfo = ConcurrentHashMap<String, BleLinkInfoV1>()
    private val publishedPeers = ConcurrentHashMap<String, Boolean>()

    // Active persistent connections (bounded to MAX_ACTIVE_CONNECTIONS)
    private val activeConnections = ConcurrentHashMap<String, BleConnection>()
    private val activeClientConnections = ConcurrentHashMap<String, GattClientConnection>()

    // Inbound raw record events
    private val inboundRecordFlow = MutableSharedFlow<Pair<ByteArray, BleReassembledRecord>>(extraBufferCapacity = 64)
    private val peerEventsFlow = MutableSharedFlow<PeerEvent>(extraBufferCapacity = 64)

    @Volatile
    private var isStarted = false

    val isRunning: Boolean
        get() = isStarted && gattServer.isRunning

    init {
        snapshotAuthority.refresh()
    }

    fun getLocalLinkInfoBytes(): ByteArray? {
        return snapshotAuthority.currentBytes()
    }

    fun refreshLocalLinkInfoSnapshotSync(): BleLinkInfoV1? {
        return snapshotAuthority.refresh()
    }

    suspend fun refreshLocalLinkInfoSnapshot(): BleLinkInfoV1? {
        return snapshotAuthority.refresh()
    }

    override fun start() {
        if (isStarted) return
        isStarted = true

        snapshotAuthority.refresh()

        // 1. Open GATT server. Advertising will begin only when onServiceAdded confirms readiness.
        val serverInitiated = gattServer.start()
        if (!serverInitiated) {
            isStarted = false
            return
        }
    }

    private fun startAdvertising() {
        if (!isStarted || !gattServer.isServiceReady) return
        if (advertiseCallback != null) return

        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(
                when (powerState) {
                    PowerState.SOS_ACTIVE -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                    PowerState.NORMAL -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
                    else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                }
            )
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()

        val advData = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()

        val respBuilder = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)

        val linkInfoPayload = getLocalLinkInfoBytes()
        if (linkInfoPayload != null) {
            respBuilder.addServiceData(ParcelUuid(SERVICE_UUID), linkInfoPayload)
        }

        val scanRespData = respBuilder.build()

        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {}
            override fun onStartFailure(errorCode: Int) {}
        }

        advertiser.startAdvertising(settings, advData, scanRespData, cb)
        advertiseCallback = cb
    }

    override fun stop() {
        if (!isStarted) return
        isStarted = false

        if (advertiseCallback != null) {
            try {
                adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
            } catch (_: Exception) {}
            advertiseCallback = null
        }

        if (scanCallback != null) {
            try {
                adapter?.bluetoothLeScanner?.stopScan(scanCallback)
            } catch (_: Exception) {}
            scanCallback = null
        }

        gattServer.stop()

        activeClientConnections.values.forEach { it.disconnect() }
        activeClientConnections.clear()

        activeConnections.values.forEach { it.markDisconnected() }
        activeConnections.clear()
        pendingRemoteLinkInfo.clear()
        publishedPeers.clear()
        peerRssi.clear()
    }

    fun setPowerState(state: PowerState) {
        if (powerState == state) return
        powerState = state
        snapshotAuthority.refresh()

        if (isStarted) {
            if (advertiseCallback != null) {
                try {
                    adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
                } catch (_: Exception) {}
                advertiseCallback = null
                startAdvertising()
            }
        }
    }

    override fun peers(): Flow<PeerEvent> = callbackFlow {
        val peerJob = coroutineScope.launch {
            peerEventsFlow.collect { event ->
                trySend(event)
            }
        }

        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device.address ?: return
                val peerMacBytes = PeerId.fromAddress(address) ?: return
                peerRssi[address] = result.rssi

                // UUID-Only Discovery: A scan result with SERVICE_UUID is sufficient to begin provisional connection
                val sd = result.scanRecord?.getServiceData(ParcelUuid(SERVICE_UUID))
                val metadata = if (sd != null && sd.size == BleLinkInfoConstants.LINK_INFO_BYTES) {
                    BleLinkInfoCodec.decode(sd)
                } else {
                    null
                }

                if (metadata != null) {
                    synchronized(discoveryLock) {
                        if (discoveredPeers.size >= MAX_DISCOVERED_PEERS && !discoveredPeers.containsKey(address)) {
                            val oldest = discoveredPeers.keys.firstOrNull()
                            if (oldest != null) discoveredPeers.remove(oldest)
                        }
                        discoveredPeers[address] = metadata
                    }
                }

                // Initiate one bounded provisional Central attempt if not active or in-flight
                handleProvisionalDiscovery(peerMacBytes, address)
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(
                when (powerState) {
                    PowerState.SOS_ACTIVE -> ScanSettings.SCAN_MODE_LOW_LATENCY
                    PowerState.NORMAL -> ScanSettings.SCAN_MODE_BALANCED
                    else -> ScanSettings.SCAN_MODE_LOW_POWER
                }
            )
            .build()

        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        adapter?.bluetoothLeScanner?.startScan(listOf(filter), settings, cb)
        scanCallback = cb

        awaitClose {
            peerJob.cancel()
            adapter?.bluetoothLeScanner?.stopScan(cb)
        }
    }

    private fun handleProvisionalDiscovery(peerMacBytes: ByteArray, address: String) {
        val existing = activeConnections[address]
        if (existing != null && existing.isActive) return

        if (activeConnections.size >= MAX_ACTIVE_CONNECTIONS && !activeConnections.containsKey(address)) {
            return
        }

        val conn = BleConnection(
            peerId = peerMacBytes
        )
        activeConnections[address] = conn

        val client = clientFactory(
            context,
            address,
            { getLocalLinkInfoBytes() },
            roleCoordinator,
            { value -> handleInboundAttValue(address, value) },
            { handlePeerDisconnected(address) },
            { conn.markConnected() },
            { conn.startLinkInfoRead() },
            { conn.startLinkInfoWrite() },
            { role, remoteHint, remoteInfo ->
                conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint)
                if (remoteInfo != null) {
                    pendingRemoteLinkInfo[address] = remoteInfo
                }
            },
            {
                conn.isNotificationSubscribed = true
                emitFoundIfDuplexReady(address, peerMacBytes, conn)
            },
            { maxAttLen ->
                conn.maxAttValueLength = maxAttLen
            }
        )
        activeClientConnections[address] = client

        coroutineScope.launch {
            val ok = client.connect()
            if (ok) {
                conn.markConnected()
            } else {
                activeClientConnections.remove(address)?.disconnect()
                activeConnections.remove(address)?.markDisconnected()
            }
        }
    }

    private fun handleIncomingLinkInfoWrite(peerAddress: String, value: ByteArray): Boolean {
        if (activeConnections.size >= MAX_ACTIVE_CONNECTIONS && !activeConnections.containsKey(peerAddress)) {
            return false
        }
        val action = roleCoordinator.processPeripheralLinkInfoWrite(peerAddress, value)
        return when (action) {
            is BleRoleBindingAction.AcceptIncomingWrite -> {
                val peerMacBytes = PeerId.fromAddress(peerAddress) ?: peerAddress.toByteArray()
                var conn = activeConnections[peerAddress]
                if (conn == null || !conn.isActive) {
                    conn = BleConnection(peerId = peerMacBytes)
                    conn.markConnected()
                    activeConnections[peerAddress] = conn
                } else if (conn.state == BleConnectionState.PROVISIONAL_CONNECTING || conn.state == BleConnectionState.DISCOVERED) {
                    conn.markConnected()
                }
                if (!conn.isRoleBound) {
                    conn.bindResponderFromAcceptedIncomingLinkInfo(action.remoteHint)
                }
                val meta = BleLinkInfoCodec.decode(value)
                if (meta != null) {
                    pendingRemoteLinkInfo[peerAddress] = meta
                }
                if (gattServer.isSubscribed(peerAddress)) {
                    conn.isNotificationSubscribed = true
                    emitFoundIfDuplexReady(peerAddress, peerMacBytes, conn)
                }
                true
            }
            else -> false
        }
    }

    private fun emitFoundIfDuplexReady(address: String, peerMacBytes: ByteArray, conn: BleConnection) {
        if (!conn.isHandshakeTransportReady) return
        if (publishedPeers.putIfAbsent(address, true) == null) {
            val meta = pendingRemoteLinkInfo[address]
            if (meta != null) {
                peerEventsFlow.tryEmit(
                    PeerEvent.Found(
                        peerId = peerMacBytes,
                        nodeHint = meta.nodeHint,
                        rssi = peerRssi[address],
                        sosFlag = meta.isSosPresent,
                        bulkCapable = meta.isBulkCapable,
                        shortDigest = meta.shortDigest,
                        queueDepth = meta.queueDepth
                    )
                )
            }
        }
    }

    private fun handleInboundAttValue(peerAddress: String, value: ByteArray) {
        val conn = activeConnections[peerAddress] ?: return
        if (!conn.isRoleBound) return

        val record = conn.ingestInboundAttValue(value) ?: return
        val peerId = conn.peerId
        inboundRecordFlow.tryEmit(peerId to record)
    }

    private fun handlePeerDisconnected(peerAddress: String) {
        val conn = activeConnections.remove(peerAddress)
        conn?.markDisconnected()
        activeClientConnections.remove(peerAddress)?.disconnect()
        pendingRemoteLinkInfo.remove(peerAddress)
        val wasPublished = publishedPeers.remove(peerAddress) == true
        val peerMacBytes = PeerId.fromAddress(peerAddress) ?: peerAddress.toByteArray()
        if (wasPublished) {
            peerEventsFlow.tryEmit(PeerEvent.Lost(peerMacBytes))
        }
    }

    fun getConnection(address: String): BleConnection? = activeConnections[address]
    fun getClient(address: String): GattClientConnection? = activeClientConnections[address]

    /**
     * Send [bytes] to [peerId] through the Noise session and BleRecord layer.
     * Application DATA is strictly forbidden unless both link connection and Noise session are READY.
     */
    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        require(bytes.size <= GATT_MTU) { "use the bulk plane for large payloads" }
        val address = PeerId.toAddress(peerId) ?: return false
        val conn = activeConnections[address] ?: return false

        // Invariant: Link must be cryptographically READY before sending application DATA
        if (conn.state != BleConnectionState.READY) return false

        val sealed = sessions?.seal(peerId, bytes) ?: return false

        // Fragment record through connection seam
        val fragments = conn.fragmentOutbound(BleRecordType.DATA, sealed)
        if (fragments.isEmpty()) return false

        val client = activeClientConnections[address]
        if (client != null && client.isConnected) {
            for (frag in fragments) {
                val ok = client.sendAttValue(frag)
                if (!ok) return false
            }
            return true
        }

        if (gattServer.isSubscribed(address)) {
            for (frag in fragments) {
                val ok = gattServer.sendNotification(address, frag)
                if (!ok) return false
            }
            return true
        }

        return false
    }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> = callbackFlow {
        val job = coroutineScope.launch {
            inboundRecordFlow.collect { (peerId, record) ->
                if (record.recordType == BleRecordType.DATA) {
                    val conn = activeConnections[PeerId.toAddress(peerId)]
                    if (conn?.state == BleConnectionState.READY) {
                        val unsealed = sessions?.open(peerId, record.payload)
                        if (unsealed != null) {
                            trySend(peerId to unsealed)
                        }
                    }
                }
            }
        }
        awaitClose { job.cancel() }
    }

    companion object {
        val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID
        val WRITE_CHAR_UUID: UUID = FrameV2.INBOX_UUID
        val LINK_INFO_CHAR_UUID: UUID = FrameV2.LINK_INFO_UUID

        const val MAX_DISCOVERED_PEERS = 64
        const val MAX_ACTIVE_CONNECTIONS = 7
        const val GATT_MTU = 512
    }
}
