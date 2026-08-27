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
 * Persistent duplex BLE control-plane substrate (ADR-002, Phase C8.4D1-A1/R2).
 *
 * Implements:
 * - UUID-only discovery baseline and provisional GATT connections
 * - Connect-First / Elect-Before-Handshake role binding via [BleRoleBindingCoordinator]
 * - Canonical 13-byte LinkInfo GATT characteristic exchange
 * - Asynchronous GATT service readiness gating before advertising
 * - Persistent bidirectional GATT client/server links
 * - Connection-local [BleRecord] fragmentation/reassembly seam
 * - Strict gating against application DATA transmission before cryptographic READY
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
        onRoleBound: (role: BleRole, remoteHint: ByteArray) -> Unit,
        onMtuUpdated: (Int) -> Unit
    ) -> GattClientConnection = { ctx, addr, linkInfoProv, coord, onInbound, onDisc, onBound, onMtu ->
        GattClientConnection(
            context = ctx,
            peerAddress = addr,
            localLinkInfoProvider = linkInfoProv,
            coordinator = coord,
            onInboundNotification = onInbound,
            onDisconnected = onDisc,
            onRoleBound = onBound,
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

    @Volatile
    private var cachedLinkInfoSnapshot: BleLinkInfoV1? = null

    @Volatile
    private var cachedLinkInfoBytes: ByteArray? = null

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
            activeConnections[peerAddress]?.isNotificationSubscribed = isSubscribed
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

    // Discovered peer cache (bounded to MAX_DISCOVERED_PEERS)
    private val discoveryLock = Any()
    private val discoveredPeers = LinkedHashMap<String, BleDiscoveryMetadata>()

    // Active persistent connections (bounded to MAX_ACTIVE_CONNECTIONS)
    private val activeConnections = ConcurrentHashMap<String, BleConnection>()
    private val activeClientConnections = ConcurrentHashMap<String, GattClientConnection>()

    // Inbound raw record events
    private val inboundRecordFlow = MutableSharedFlow<Pair<ByteArray, BleReassembledRecord>>(extraBufferCapacity = 64)

    @Volatile
    private var isStarted = false

    val isRunning: Boolean
        get() = isStarted && gattServer.isRunning

    init {
        // Initial real snapshot derivation
        refreshLocalLinkInfoSnapshotSync()
    }

    fun getLocalLinkInfoBytes(): ByteArray? {
        if (cachedLinkInfoBytes == null) {
            refreshLocalLinkInfoSnapshotSync()
        }
        return cachedLinkInfoBytes
    }

    fun refreshLocalLinkInfoSnapshotSync(): BleLinkInfoV1 {
        val snap = snapshotProvider?.invoke()
        val shortDigest: ByteArray
        val queueDepth: Int
        var flags = 0

        if (snap != null) {
            shortDigest = snap.shortDigest.copyOf(BleLinkInfoConstants.SHORT_DIGEST_BYTES)
            queueDepth = snap.queueDepth.coerceIn(0, 255)
            if (snap.sosPresent) flags = flags or BleLinkInfoConstants.FLAG_SOS_PRESENT
            if (snap.clockUntrusted) flags = flags or BleLinkInfoConstants.FLAG_CLOCK_UNTRUSTED
        } else {
            // Sourced from real identity and empty/initial state
            shortDigest = ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES)
            queueDepth = 0
        }

        if (powerState == PowerState.CRITICAL) flags = flags or BleLinkInfoConstants.FLAG_POWER_CONSTRAINED
        if (powerState == PowerState.SOS_ACTIVE) flags = flags or BleLinkInfoConstants.FLAG_SOS_PRESENT

        val info = BleLinkInfoV1(
            version = BleLinkInfoConstants.PROTOCOL_VERSION,
            flags = flags.toByte(),
            nodeHint = identity.nodeHint.copyOf(),
            shortDigest = shortDigest,
            queueDepth = queueDepth
        )
        cachedLinkInfoSnapshot = info
        cachedLinkInfoBytes = BleLinkInfoCodec.encode(
            version = info.version,
            flags = info.flags,
            nodeHint = info.nodeHint,
            shortDigest = info.shortDigest,
            queueDepth = info.queueDepth
        )
        return info
    }

    suspend fun refreshLocalLinkInfoSnapshot(): BleLinkInfoV1 {
        var count = 0
        val bloom = BloomDigest()
        if (store != null) {
            store.forEachHeldMsgId { msgId ->
                count++
                bloom.add(msgId)
                true
            }
        }
        val shortDigest = bloom.toBytes().copyOf(BleLinkInfoConstants.SHORT_DIGEST_BYTES)
        val queueDepth = minOf(count, 255)
        var flags = 0
        if (powerState == PowerState.CRITICAL) flags = flags or BleLinkInfoConstants.FLAG_POWER_CONSTRAINED
        if (powerState == PowerState.SOS_ACTIVE) flags = flags or BleLinkInfoConstants.FLAG_SOS_PRESENT

        val info = BleLinkInfoV1(
            version = BleLinkInfoConstants.PROTOCOL_VERSION,
            flags = flags.toByte(),
            nodeHint = identity.nodeHint.copyOf(),
            shortDigest = shortDigest,
            queueDepth = queueDepth
        )
        cachedLinkInfoSnapshot = info
        cachedLinkInfoBytes = BleLinkInfoCodec.encode(
            version = info.version,
            flags = info.flags,
            nodeHint = info.nodeHint,
            shortDigest = info.shortDigest,
            queueDepth = info.queueDepth
        )
        return info
    }

    override fun start() {
        if (isStarted) return
        isStarted = true

        // 1. Open GATT server. Advertising will begin only when onServiceAdded confirms readiness.
        val serverInitiated = gattServer.start()
        if (!serverInitiated) {
            isStarted = false
            return
        }

        if (gattServer.isServiceReady) {
            startAdvertising()
        }
    }

    override fun stop() {
        if (!isStarted) return
        isStarted = false

        advertiseCallback?.let { adapter?.bluetoothLeAdvertiser?.stopAdvertising(it) }
        scanCallback?.let { adapter?.bluetoothLeScanner?.stopScan(it) }
        advertiseCallback = null
        scanCallback = null

        for ((_, client) in activeClientConnections) {
            client.disconnect()
        }
        activeClientConnections.clear()

        for ((_, conn) in activeConnections) {
            conn.markDisconnected()
        }
        activeConnections.clear()

        gattServer.stop()

        synchronized(discoveryLock) {
            discoveredPeers.clear()
        }
    }

    fun setPowerState(state: PowerState) {
        if (state == powerState) return
        powerState = state
        refreshLocalLinkInfoSnapshotSync()
        if (isStarted) {
            stop()
            start()
        }
    }

    /**
     * Build the 13-byte scan-response payload from current discovery snapshot authority (ADR-002 §2).
     */
    fun buildScanResponsePayload(
        digest: ByteArray,
        queueDepth: Int,
        sosPresent: Boolean,
        clockUntrusted: Boolean = false
    ): ByteArray {
        require(digest.size >= 6) { "short digest requires at least 6 bytes" }
        var flags = 0
        if (sosPresent) flags = flags or BleLinkInfoConstants.FLAG_SOS_PRESENT
        if (powerState == PowerState.CRITICAL) flags = flags or BleLinkInfoConstants.FLAG_POWER_CONSTRAINED
        if (clockUntrusted) flags = flags or BleLinkInfoConstants.FLAG_CLOCK_UNTRUSTED

        return BleLinkInfoCodec.encode(
            version = FrameV2.VERSION,
            flags = flags.toByte(),
            nodeHint = identity.nodeHint,
            shortDigest = digest.copyOfRange(0, 6),
            queueDepth = queueDepth
        )
    }

    private fun startAdvertising() {
        val adv = adapter?.bluetoothLeAdvertiser ?: return
        if (!gattServer.isServiceReady) return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(
                when (powerState) {
                    PowerState.SOS_ACTIVE -> AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY
                    PowerState.NORMAL -> AdvertiseSettings.ADVERTISE_MODE_BALANCED
                    else -> AdvertiseSettings.ADVERTISE_MODE_LOW_POWER
                }
            )
            .setTxPowerLevel(
                if (powerState == PowerState.CRITICAL)
                    AdvertiseSettings.ADVERTISE_TX_POWER_LOW
                else
                    AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM
            )
            .setConnectable(true)
            .build()

        // Primary Advertisement: Service UUID only (18 bytes)
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()

        // Optional Android Scan Response: 13-byte LinkInfo payload
        val localBytes = getLocalLinkInfoBytes()
        val scanResponse = if (localBytes != null && localBytes.size == BleLinkInfoConstants.LINK_INFO_BYTES) {
            AdvertiseData.Builder()
                .setIncludeDeviceName(false)
                .addServiceData(ParcelUuid(SERVICE_UUID), localBytes)
                .build()
        } else {
            null
        }

        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {}
        }
        advertiseCallback = cb
        if (scanResponse != null) {
            adv.startAdvertising(settings, data, scanResponse, cb)
        } else {
            adv.startAdvertising(settings, data, cb)
        }
    }

    override fun peers(): Flow<PeerEvent> = callbackFlow {
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device.address ?: return
                val peerMacBytes = PeerId.fromAddress(address) ?: return

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

                    trySend(
                        PeerEvent.Found(
                            peerId = peerMacBytes,
                            nodeHint = metadata.nodeHint,
                            rssi = result.rssi,
                            sosFlag = metadata.isSosPresent,
                            bulkCapable = metadata.isBulkCapable,
                            shortDigest = metadata.shortDigest,
                            queueDepth = metadata.queueDepth
                        )
                    )
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

        awaitClose { adapter?.bluetoothLeScanner?.stopScan(cb) }
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
            { role, remoteHint ->
                conn.bindRole(remoteHint, role)
            },
            { maxAttLen ->
                conn.maxAttValueLength = maxAttLen
                conn.markConnected(maxAttLen)
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
        val action = roleCoordinator.processPeripheralLinkInfoWrite(peerAddress, value)
        return when (action) {
            is BleRoleBindingAction.AcceptIncomingWrite -> {
                val peerMacBytes = PeerId.fromAddress(peerAddress) ?: peerAddress.toByteArray()
                var conn = activeConnections[peerAddress]
                if (conn == null || !conn.isActive) {
                    conn = BleConnection(peerId = peerMacBytes)
                    activeConnections[peerAddress] = conn
                }
                if (!conn.isRoleBound) {
                    conn.bindRole(action.remoteHint, BleRole.RESPONDER)
                }
                true
            }
            else -> false
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

        for (frag in fragments) {
            val success = if (conn.localRole == BleRole.INITIATOR) {
                val client = activeClientConnections[address] ?: return false
                client.sendAttValue(frag)
            } else {
                gattServer.sendNotification(address, frag)
            }
            if (!success) return false
        }
        return true
    }

    /** Decrypted inbound frames. Strictly requires link state READY and successful session decryption. */
    fun receivedPlaintext(): Flow<Pair<ByteArray, ByteArray>> =
        kotlinx.coroutines.flow.flow {
            inboundRecordFlow.collect { (peer, record) ->
                val address = PeerId.toAddress(peer) ?: return@collect
                val conn = activeConnections[address] ?: return@collect

                if (record.recordType == BleRecordType.DATA && conn.state == BleConnectionState.READY) {
                    val clear = try {
                        sessions?.open(peer, record.payload)
                    } catch (_: Exception) {
                        null
                    }
                    if (clear != null) emit(peer to clear)
                }
            }
        }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> =
        kotlinx.coroutines.flow.flow {
            inboundRecordFlow.collect { (peer, record) ->
                val address = PeerId.toAddress(peer) ?: return@collect
                val conn = activeConnections[address] ?: return@collect

                if (record.recordType == BleRecordType.DATA && conn.state == BleConnectionState.READY) {
                    emit(peer to record.payload)
                }
            }
        }

    companion object {
        val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID
        val WRITE_CHAR_UUID: UUID = FrameV2.INBOX_UUID
        val NOTIFY_CHAR_UUID: UUID = FrameV2.DIGEST_UUID
        val LINK_INFO_CHAR_UUID: UUID = FrameV2.LINK_INFO_UUID

        const val GATT_MTU = 512
        const val SCAN_RESPONSE_BYTES = 13

        const val MAX_DISCOVERED_PEERS = 64
        const val MAX_ACTIVE_CONNECTIONS = 7
    }
}
