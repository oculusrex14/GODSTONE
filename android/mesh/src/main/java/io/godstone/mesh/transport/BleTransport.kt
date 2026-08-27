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
 * Persistent duplex BLE control-plane substrate (ADR-002, Phase C8.4D1).
 *
 * Implements:
 * - Deterministic role election via [BleRoleElection]
 * - 13-byte scan-response discovery metadata plumbing via [BleDiscoveryCodec]
 * - Persistent bidirectional GATT client/server links
 * - Connection-local [BleRecord] fragmentation/reassembly seam
 * - Bounded peer and connection resource management
 */
@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context,
    private val identity: Identity,
    private val digestProvider: suspend () -> BloomDigest,
    /** Noise sessions. Without this the transport cannot send at all -- by design. */
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null,
    private val snapshotProvider: (() -> BleDiscoverySnapshot)? = null,
    private val clientFactory: (
        context: Context,
        address: String,
        onInboundNotification: (ByteArray) -> Unit,
        onDisconnected: () -> Unit,
        onMtuUpdated: (Int) -> Unit
    ) -> GattClientConnection = { ctx, addr, onInbound, onDisc, onMtu ->
        GattClientConnection(ctx, addr, onInbound, onDisc, onMtu)
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

    // Owned peripheral GATT server
    private val gattServer: BleGattServer = BleGattServer(
        context = context,
        serviceUuid = SERVICE_UUID,
        inboxCharUuid = WRITE_CHAR_UUID,
        onInboundWrite = { peerAddress, value -> handleInboundAttValue(peerAddress, value) },
        onClientDisconnected = { peerAddress -> handlePeerDisconnected(peerAddress) },
        onMtuChanged = { peerAddress, maxAttLen ->
            activeConnections[peerAddress]?.let { conn ->
                conn.maxAttValueLength = maxAttLen
                conn.markConnected(maxAttLen)
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

    override fun start() {
        if (isStarted) return

        // Logical startup order (ADR-002 §7):
        // 1. Open GATT server. If server open fails, fail-closed without advertising!
        val serverStarted = gattServer.start()
        if (!serverStarted) {
            isStarted = false
            return
        }

        isStarted = true

        // 2. Establish inbound plumbing & begin advertising
        startAdvertising()
    }

    override fun stop() {
        if (!isStarted) return
        isStarted = false

        // Stop advertising and scanning
        advertiseCallback?.let { adapter?.bluetoothLeAdvertiser?.stopAdvertising(it) }
        scanCallback?.let { adapter?.bluetoothLeScanner?.stopScan(it) }
        advertiseCallback = null
        scanCallback = null

        // Disconnect and purge active client links
        for ((_, client) in activeClientConnections) {
            client.disconnect()
        }
        activeClientConnections.clear()

        // Reset and purge connections
        for ((_, conn) in activeConnections) {
            conn.markDisconnected()
        }
        activeConnections.clear()

        // Close server
        gattServer.stop()

        synchronized(discoveryLock) {
            discoveredPeers.clear()
        }
    }

    fun setPowerState(state: PowerState) {
        if (state == powerState) return
        powerState = state
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
        if (sosPresent) flags = flags or FLAG_SOS
        if (powerState == PowerState.CRITICAL) flags = flags or FLAG_POWER_CONSTRAINED
        if (clockUntrusted) flags = flags or FLAG_CLOCK_UNTRUSTED

        return BleDiscoveryCodec.encode(
            version = FrameV2.VERSION,
            flags = flags.toByte(),
            nodeHint = identity.nodeHint,
            shortDigest = digest.copyOfRange(0, 6),
            queueDepth = queueDepth
        )
    }

    private fun getCurrentDiscoverySnapshot(): BleDiscoverySnapshot {
        snapshotProvider?.let { return it() }
        // Default real snapshot derived from node identity and state
        return BleDiscoverySnapshot(
            shortDigest = identity.nodeHint.copyOf(6),
            queueDepth = 0,
            sosPresent = false,
            clockUntrusted = false
        )
    }

    private fun startAdvertising() {
        val adv = adapter?.bluetoothLeAdvertiser ?: return

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

        // Scan Response: Service Data with 13-byte discovery payload sourced from real snapshot authority
        val snapshot = getCurrentDiscoverySnapshot()
        val scanResponsePayload = buildScanResponsePayload(
            digest = snapshot.shortDigest,
            queueDepth = snapshot.queueDepth,
            sosPresent = snapshot.sosPresent,
            clockUntrusted = snapshot.clockUntrusted
        )
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceData(ParcelUuid(SERVICE_UUID), scanResponsePayload)
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {}
        }
        advertiseCallback = cb
        adv.startAdvertising(settings, data, scanResponse, cb)
    }

    override fun peers(): Flow<PeerEvent> = callbackFlow {
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device.address ?: return
                val peerMacBytes = PeerId.fromAddress(address) ?: return

                val sd = result.scanRecord?.getServiceData(ParcelUuid(SERVICE_UUID))
                val metadata = if (sd != null && sd.size >= BleDiscoveryConstants.DISCOVERY_PAYLOAD_BYTES) {
                    BleDiscoveryCodec.decode(sd)
                } else {
                    null
                }

                if (metadata != null) {
                    // Update discovery cache with full metadata
                    synchronized(discoveryLock) {
                        if (discoveredPeers.size >= MAX_DISCOVERED_PEERS && !discoveredPeers.containsKey(address)) {
                            val oldest = discoveredPeers.keys.firstOrNull()
                            if (oldest != null) discoveredPeers.remove(oldest)
                        }
                        discoveredPeers[address] = metadata
                    }

                    // Role election evaluation (ADR-002 §3)
                    val election = BleRoleElection.elect(identity.nodeHint, metadata.nodeHint)
                    if (election is BleRoleElectionResult.Elected) {
                        handleElectedPeer(peerMacBytes, address, metadata.nodeHint, election.role)
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
                } else {
                    // Tolerates adv arrival before scan response: retain cached metadata if previously seen
                    val cached = synchronized(discoveryLock) { discoveredPeers[address] }
                    if (cached != null) {
                        trySend(
                            PeerEvent.Found(
                                peerId = peerMacBytes,
                                nodeHint = cached.nodeHint,
                                rssi = result.rssi,
                                sosFlag = cached.isSosPresent,
                                bulkCapable = cached.isBulkCapable,
                                shortDigest = cached.shortDigest,
                                queueDepth = cached.queueDepth
                            )
                        )
                    }
                }
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

    private fun handleElectedPeer(
        peerMacBytes: ByteArray,
        address: String,
        remoteHint: ByteArray,
        role: BleRole
    ) {
        val existing = activeConnections[address]
        if (existing != null && existing.isActive) return

        if (activeConnections.size >= MAX_ACTIVE_CONNECTIONS && !activeConnections.containsKey(address)) {
            return // Capacity exceeded
        }

        val conn = BleConnection(
            peerId = peerMacBytes,
            remoteNodeHint = remoteHint,
            localRole = role
        )
        activeConnections[address] = conn

        // Role Authority: INITIATOR creates and initiates persistent client connection; RESPONDER waits
        if (role == BleRole.INITIATOR) {
            val client = clientFactory(
                context,
                address,
                { value -> handleInboundAttValue(address, value) },
                { handlePeerDisconnected(address) },
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
    }

    private fun handleInboundAttValue(peerAddress: String, value: ByteArray) {
        val conn = activeConnections[peerAddress] ?: return
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
     */
    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        require(bytes.size <= GATT_MTU) { "use the bulk plane for large payloads" }
        val address = PeerId.toAddress(peerId) ?: return false
        val conn = activeConnections[address] ?: return false
        if (!conn.isActive) return false

        val sealed = sessions?.seal(peerId, bytes) ?: return false

        // Fragment record through connection seam
        val fragments = conn.fragmentOutbound(BleRecordType.DATA, sealed)
        if (fragments.isEmpty()) return false

        // Send all fragments over the persistent duplex link
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

    /** Decrypted inbound frames. Anything that fails authentication is dropped. */
    fun receivedPlaintext(): Flow<Pair<ByteArray, ByteArray>> =
        kotlinx.coroutines.flow.flow {
            inboundRecordFlow.collect { (peer, record) ->
                if (record.recordType == BleRecordType.DATA) {
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
                if (record.recordType == BleRecordType.DATA) {
                    emit(peer to record.payload)
                }
            }
        }

    companion object {
        val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID
        val WRITE_CHAR_UUID: UUID = FrameV2.INBOX_UUID
        val NOTIFY_CHAR_UUID: UUID = FrameV2.DIGEST_UUID

        const val GATT_MTU = 512
        const val SCAN_RESPONSE_BYTES = 13

        const val MAX_DISCOVERED_PEERS = 64
        const val MAX_ACTIVE_CONNECTIONS = 7

        const val FLAG_SOS = 0x01
        const val FLAG_BULK_CAPABLE = 0x02
        const val FLAG_POWER_CONSTRAINED = 0x04
        const val FLAG_VERIFIED_ONLY = 0x08
        const val FLAG_CLOCK_UNTRUSTED = 0x10
    }
}
