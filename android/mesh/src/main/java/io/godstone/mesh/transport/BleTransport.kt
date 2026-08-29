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
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

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

@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context,
    private val identity: Identity,
    private val digestProvider: (suspend () -> BloomDigest)? = null,
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null,
    private val snapshotProvider: (() -> BleDiscoverySnapshot)? = null,
    private val store: MessageStore? = null,
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

    val globalCapacity = BleGlobalCapacityAuthority()

    val serverDriver = BleServerOrchestrationDriver(
        localHint = identity.nodeHint,
        localLinkInfoProvider = { getLocalLinkInfoBytes() },
        globalCapacity = globalCapacity
    )

    val centralDriver = BleCentralOrchestrationDriver(
        localHint = identity.nodeHint,
        localLinkInfoProvider = { getLocalLinkInfoBytes() },
        globalCapacity = globalCapacity
    )

    val gattServer: BleGattServer = BleGattServer(
        context = context,
        serviceUuid = SERVICE_UUID,
        inboxCharUuid = WRITE_CHAR_UUID,
        linkInfoCharUuid = LINK_INFO_CHAR_UUID,
        linkInfoProvider = { getLocalLinkInfoBytes() },
        onLinkInfoWrite = { peerAddress, value -> handleIncomingLinkInfoWrite(peerAddress, value) },
        isRoleBoundPredicate = { peerAddress -> serverDriver.getInboundConnection(peerAddress)?.isRoleBound == true },
        onInboundWrite = { peerAddress, value -> handleServerInboundWrite(peerAddress, value) },
        onClientDisconnected = { peerAddress -> handleServerDisconnected(peerAddress) },
        onSubscriptionChanged = { peerAddress, isSubscribed ->
            val conn = serverDriver.getInboundConnection(peerAddress)
            if (conn != null) {
                conn.isNotificationSubscribed = isSubscribed
                if (isSubscribed && conn.isHandshakeTransportReady) {
                    val peerMacBytes = PeerId.fromAddress(peerAddress) ?: peerAddress.toByteArray()
                    emitResponderFoundIfDuplexReady(peerAddress, peerMacBytes, conn)
                }
            }
        },
        onMtuChanged = { peerAddress, maxAttLen ->
            serverDriver.getInboundConnection(peerAddress)?.let { conn ->
                conn.maxAttValueLength = maxAttLen
                conn.markConnected(maxAttLen)
            }
        },
        onServiceStatusChanged = { isReady ->
            if (isReady && isStarted) {
                startAdvertising()
            }
        },
        orchestrationDriver = serverDriver
    )

    private val discoveredPeers = LinkedHashMap<String, BleDiscoveryMetadata>()
    private val peerRssi = ConcurrentHashMap<String, Int>()
    private val centralRemoteLinkInfo = ConcurrentHashMap<String, BleLinkInfoV1>()
    private val responderRemoteLinkInfo = ConcurrentHashMap<String, BleLinkInfoV1>()
    private val publishedPeers = ConcurrentHashMap<String, Boolean>()

    private val activeClientConnections = ConcurrentHashMap<String, GattClientConnection>()
    private val provisionalJobs = ConcurrentHashMap<String, Job>()
    private val provisionalGenerations = ConcurrentHashMap<String, Long>()

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
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
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

        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {}
            override fun onStartFailure(errorCode: Int) {}
        }

        advertiser.startAdvertising(settings, advData, respBuilder.build(), cb)
        advertiseCallback = cb
    }

    override fun stop() {
        if (!isStarted) return
        isStarted = false

        if (advertiseCallback != null) {
            try { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
            advertiseCallback = null
        }
        if (scanCallback != null) {
            try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) {}
            scanCallback = null
        }
        provisionalJobs.values.forEach { it.cancel() }
        provisionalJobs.clear()
        provisionalGenerations.clear()

        centralDriver.reset()
        gattServer.stop()
        activeClientConnections.values.forEach { it.disconnect() }
        activeClientConnections.clear()
        globalCapacity.reset()

        centralRemoteLinkInfo.clear()
        responderRemoteLinkInfo.clear()
        publishedPeers.clear()
        peerRssi.clear()
    }

    fun setPowerState(state: PowerState) {
        if (powerState == state) return
        powerState = state
        snapshotAuthority.refresh()
        if (isStarted && advertiseCallback != null) {
            try { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
            advertiseCallback = null
            startAdvertising()
        }
    }

    fun processCentralAction(address: String, action: BleCentralAction) {
        val client = activeClientConnections[address]
        when (action) {
            is BleCentralAction.ConnectGatt -> {
                client?.connectGatt()
            }
            is BleCentralAction.DiscoverServices -> {
                client?.discoverServices()
            }
            is BleCentralAction.ReadLinkInfo -> {
                client?.readLinkInfo()
            }
            is BleCentralAction.WriteLinkInfo -> {
                client?.writeLinkInfo(action.localBytes)
            }
            is BleCentralAction.SubscribeCccd -> {
                client?.subscribeCccd()
            }
            is BleCentralAction.PublishFound -> {
                provisionalJobs.remove(address)?.cancel()
                val peerMacBytes = PeerId.fromAddress(address) ?: address.toByteArray()
                val meta = centralRemoteLinkInfo[address]
                if (meta != null && publishedPeers.putIfAbsent(address, true) == null) {
                    peerEventsFlow.tryEmit(
                        PeerEvent.Found(
                            peerId = peerMacBytes,
                            nodeHint = meta.nodeHint,
                            rssi = action.rssi,
                            sosFlag = meta.isSosPresent,
                            bulkCapable = meta.isBulkCapable,
                            shortDigest = meta.shortDigest,
                            queueDepth = meta.queueDepth
                        )
                    )
                }
            }
            is BleCentralAction.PublishLost -> {
                provisionalJobs.remove(address)?.cancel()
                val peerMacBytes = PeerId.fromAddress(address) ?: address.toByteArray()
                peerEventsFlow.tryEmit(PeerEvent.Lost(peerMacBytes))
            }
            is BleCentralAction.DisconnectGatt -> {
                provisionalJobs.remove(address)?.cancel()
                client?.disconnect()
                activeClientConnections.remove(address)
                centralRemoteLinkInfo.remove(address)
            }
            BleCentralAction.NoOp -> {}
        }
    }

    override fun peers(): Flow<PeerEvent> = callbackFlow {
        val peerJob = coroutineScope.launch {
            peerEventsFlow.collect { event -> trySend(event) }
        }
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val address = result.device.address ?: return
                peerRssi[address] = result.rssi
                val sd = result.scanRecord?.getServiceData(ParcelUuid(SERVICE_UUID))
                val metadata = if (sd != null && sd.size == BleLinkInfoConstants.LINK_INFO_BYTES) BleLinkInfoCodec.decode(sd) else null
                if (metadata != null) {
                    discoveredPeers[address] = metadata
                }
                val optionalHint = metadata?.nodeHint
                val action = centralDriver.onScanResult(address, result.rssi, optionalHint)
                if (action is BleCentralAction.ConnectGatt) {
                    val client = activeClientConnections.getOrPut(address) {
                        GattClientConnection(
                            context = context,
                            peerAddress = address,
                            onGattConnected = { gen, cur -> processCentralAction(address, centralDriver.onGattConnected(address, gen, cur)) },
                            onServicesDiscovered = { suc, gen, cur -> processCentralAction(address, centralDriver.onServicesDiscovered(address, suc, gen, cur)) },
                            onLinkInfoReadResult = { bytes, gen, cur ->
                                if (bytes != null) BleLinkInfoCodec.decode(bytes)?.let { centralRemoteLinkInfo[address] = it }
                                processCentralAction(address, centralDriver.onLinkInfoReadResult(address, bytes, gen, cur))
                            },
                            onLinkInfoWriteAck = { suc, gen, cur ->
                                val hint = centralRemoteLinkInfo[address]?.nodeHint ?: ByteArray(4)
                                processCentralAction(address, centralDriver.onLinkInfoWriteAcknowledged(address, suc, hint, gen, cur))
                            },
                            onCccdWriteAck = { suc, gen, cur -> processCentralAction(address, centralDriver.onCccdWriteAcknowledged(address, suc, gen, cur)) },
                            onMtuChanged = { centralDriver.onMtuChanged(address, it) },
                            onDisconnected = { handleCentralDisconnected(address) },
                            onInboundNotification = { handleCentralInboundNotification(address, it) }
                        )
                    }
                    activeClientConnections[address] = client
                    val gen = (provisionalGenerations[address] ?: 0L) + 1L
                    provisionalGenerations[address] = gen
                    provisionalJobs[address]?.cancel()
                    provisionalJobs[address] = coroutineScope.launch {
                        delay(PROVISIONAL_TIMEOUT_MS)
                        if (provisionalGenerations[address] == gen) {
                            val conn = centralDriver.getActiveConnection(address)
                            if (conn?.isHandshakeTransportReady != true) {
                                val timeoutAct = centralDriver.onProvisionalTimeout(address, gen)
                                processCentralAction(address, timeoutAct)
                            }
                        }
                    }
                    processCentralAction(address, action)
                }
            }
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build()
        adapter?.bluetoothLeScanner?.startScan(listOf(filter), settings, cb)
        scanCallback = cb
        awaitClose {
            peerJob.cancel()
            adapter?.bluetoothLeScanner?.stopScan(cb)
        }
    }

    private fun handleIncomingLinkInfoWrite(peerAddress: String, value: ByteArray): Boolean {
        if (value.size != BleLinkInfoConstants.LINK_INFO_BYTES) return false
        val decoded = BleLinkInfoCodec.decode(value) ?: return false
        responderRemoteLinkInfo[peerAddress] = decoded
        return true
    }

    private fun emitResponderFoundIfDuplexReady(address: String, peerMacBytes: ByteArray, conn: BleConnection) {
        if (!conn.isHandshakeTransportReady) return
        val meta = responderRemoteLinkInfo[address] ?: serverDriver.getAcceptedRemoteLinkInfo(address)
        if (meta != null && publishedPeers.putIfAbsent(address, true) == null) {
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

    fun handleCentralInboundNotification(peerAddress: String, value: ByteArray) {
        val conn = centralDriver.getActiveConnection(peerAddress) ?: return
        if (!conn.isRoleBound) return
        val record = conn.ingestInboundAttValue(value) ?: return
        val peerId = conn.peerId
        inboundRecordFlow.tryEmit(peerId to record)
    }

    fun handleServerInboundWrite(peerAddress: String, value: ByteArray) {
        val conn = serverDriver.getInboundConnection(peerAddress) ?: return
        if (!conn.isRoleBound) return
        val record = conn.ingestInboundAttValue(value) ?: return
        val peerId = conn.peerId
        inboundRecordFlow.tryEmit(peerId to record)
    }

    fun handleCentralDisconnected(peerAddress: String) {
        provisionalJobs.remove(peerAddress)?.cancel()
        val conn = centralDriver.getActiveConnection(peerAddress)
        conn?.markDisconnected()
        val act = centralDriver.onDisconnected(peerAddress)
        processCentralAction(peerAddress, act)
        activeClientConnections.remove(peerAddress)
        centralRemoteLinkInfo.remove(peerAddress)
        val wasPublished = publishedPeers.remove(peerAddress) == true
        if (wasPublished) {
            val peerMacBytes = PeerId.fromAddress(peerAddress) ?: peerAddress.toByteArray()
            peerEventsFlow.tryEmit(PeerEvent.Lost(peerMacBytes))
        }
    }

    fun handleServerDisconnected(peerAddress: String) {
        val conn = serverDriver.getInboundConnection(peerAddress)
        conn?.markDisconnected()
        serverDriver.onClientDisconnected(peerAddress)
        responderRemoteLinkInfo.remove(peerAddress)
        val wasPublished = publishedPeers.remove(peerAddress) == true
        if (wasPublished) {
            val peerMacBytes = PeerId.fromAddress(peerAddress) ?: peerAddress.toByteArray()
            peerEventsFlow.tryEmit(PeerEvent.Lost(peerMacBytes))
        }
    }

    override suspend fun send(peerId: ByteArray, bytes: ByteArray): Boolean {
        require(bytes.size <= 512)
        val address = PeerId.toAddress(peerId) ?: return false
        val centralConn = centralDriver.getActiveConnection(address)
        val serverConn = serverDriver.getInboundConnection(address)

        if (centralConn?.state == BleConnectionState.READY) {
            val sealed = sessions?.seal(peerId, bytes) ?: return false
            val fragments = centralConn.fragmentOutbound(BleRecordType.DATA, sealed)
            if (fragments.isEmpty()) return false
            val client = activeClientConnections[address] ?: return false
            if (!client.isConnected) return false
            for (frag in fragments) {
                val ok = client.sendAttValue(frag)
                if (!ok) return false
            }
            return true
        }

        if (serverConn?.state == BleConnectionState.READY) {
            val sealed = sessions?.seal(peerId, bytes) ?: return false
            val fragments = serverConn.fragmentOutbound(BleRecordType.DATA, sealed)
            if (fragments.isEmpty()) return false
            if (!gattServer.isSubscribed(address)) return false
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
                    val address = PeerId.toAddress(peerId)
                    val conn = if (address != null) centralDriver.getActiveConnection(address) ?: serverDriver.getInboundConnection(address) else null
                    if (conn?.state == BleConnectionState.READY) {
                        val unsealed = sessions?.open(peerId, record.payload)
                        if (unsealed != null) trySend(peerId to unsealed)
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
        const val PROVISIONAL_TIMEOUT_MS = 10_000L
        const val LINK_LAYER_READY = false
    }
}
