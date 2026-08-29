package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
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
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.wire.v2.FrameV2
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import java.util.Collections
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context? = null,
    val identity: Identity,
    private val digestProvider: (suspend () -> BloomDigest)? = null,
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null,
    private val store: MessageStore? = null,
    private val coroutineScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
) : Transport {

    override val name = "BLE"
    override val isBulkCapable = false

    private val btManager = context?.getSystemService(BluetoothManager::class.java)
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
        onClientDisconnected = { peerAddress, generation -> handleServerDisconnected(peerAddress, generation) },
        onSubscriptionChanged = { peerAddress, isSubscribed ->
            val conn = serverDriver.getInboundConnection(peerAddress)
            if (conn != null) {
                conn.isNotificationSubscribed = isSubscribed
                if (isSubscribed && conn.isHandshakeTransportReady) {
                    inboundJobs.remove(peerAddress)?.cancel()
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
        onClientAdmitted = { peerAddress, generation -> handleInboundClientAdmitted(peerAddress, generation) },
        orchestrationDriver = serverDriver
    )

    private val discoveredPeers = LinkedHashMap<String, BleDiscoveryMetadata>()
    private val peerRssi = ConcurrentHashMap<String, Int>()
    private val centralRemoteLinkInfo = ConcurrentHashMap<String, BleLinkInfoV1>()
    private val responderRemoteLinkInfo = ConcurrentHashMap<String, BleLinkInfoV1>()
    private val publishedRelations = ConcurrentHashMap.newKeySet<RelationKey>()

    private val activeClientConnections = ConcurrentHashMap<String, GattClientConnection>()
    private val provisionalJobs = ConcurrentHashMap<String, Job>()
    private val provisionalGenerations = ConcurrentHashMap<String, Long>()
    private val inboundJobs = ConcurrentHashMap<String, Job>()

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

    fun setPowerState(state: PowerState) {
        powerState = state
        if (isStarted) {
            stopAdvertising()
            startAdvertising()
        }
    }

    override fun start() {
        if (isStarted) return
        isStarted = true
        val serverStarted = gattServer.start()
        if (!serverStarted) return
        startAdvertising()
    }

    override fun stop() {
        val wasStarted = isStarted
        isStarted = false
        if (wasStarted) {
            stopAdvertising()
            scanCallback?.let {
                adapter?.bluetoothLeScanner?.stopScan(it)
                scanCallback = null
            }
        }
        for ((_, job) in provisionalJobs) {
            job.cancel()
        }
        provisionalJobs.clear()
        provisionalGenerations.clear()

        for ((_, job) in inboundJobs) {
            job.cancel()
        }
        inboundJobs.clear()

        for ((_, client) in activeClientConnections) {
            client.disconnect()
        }
        activeClientConnections.clear()

        centralDriver.reset()
        gattServer.stop()
        serverDriver.startNewServerEpoch()
        globalCapacity.reset()

        publishedRelations.clear()
        centralRemoteLinkInfo.clear()
        responderRemoteLinkInfo.clear()
    }

    private fun startAdvertising() {
        val adv = adapter?.bluetoothLeAdvertiser ?: return
        if (!gattServer.isServiceReady) return

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()

        val linkInfoBytes = getLocalLinkInfoBytes()
        val dataBuilder = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .setIncludeDeviceName(false)

        if (linkInfoBytes != null && linkInfoBytes.size == BleLinkInfoConstants.LINK_INFO_BYTES) {
            dataBuilder.addServiceData(ParcelUuid(SERVICE_UUID), linkInfoBytes)
        }

        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                advertiseCallback = null
            }
        }
        adv.startAdvertising(settings, dataBuilder.build(), cb)
        advertiseCallback = cb
    }

    private fun stopAdvertising() {
        advertiseCallback?.let {
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(it)
            advertiseCallback = null
        }
    }

    private fun processCentralAction(address: String, action: BleCentralAction) {
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
                val meta = centralRemoteLinkInfo[address] ?: discoveredPeers[address]
                val gen = centralDriver.getConnectionGeneration(address)
                publishRelation(RelationKey(BleDirection.OUTBOUND, address, gen), meta)
            }
            is BleCentralAction.PublishLost -> {
                provisionalJobs.remove(address)?.cancel()
                val gen = centralDriver.getConnectionGeneration(address)
                unpublishRelation(RelationKey(BleDirection.OUTBOUND, address, gen))
            }
            is BleCentralAction.DisconnectGatt -> {
                provisionalJobs.remove(address)?.cancel()
                client?.disconnect()
                activeClientConnections.remove(address)
                centralRemoteLinkInfo.remove(address)
                val gen = centralDriver.getConnectionGeneration(address)
                unpublishRelation(RelationKey(BleDirection.OUTBOUND, address, gen))
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
                                val res = centralDriver.onLinkInfoReadResult(address, bytes, gen, cur)
                                if (res is BleCentralAction.WriteLinkInfo && bytes != null) {
                                    BleLinkInfoCodec.decode(bytes)?.let { centralRemoteLinkInfo[address] = it }
                                }
                                processCentralAction(address, res)
                            },
                            onLinkInfoWriteAck = { suc, gen, cur ->
                                val hint = centralDriver.getElectionContext(address)?.remoteNodeHint ?: centralRemoteLinkInfo[address]?.nodeHint ?: ByteArray(4)
                                processCentralAction(address, centralDriver.onLinkInfoWriteAcknowledged(address, suc, hint, gen, cur))
                            },
                            onCccdWriteAck = { suc, gen, cur -> processCentralAction(address, centralDriver.onCccdWriteAcknowledged(address, suc, gen, cur)) },
                            onMtuChanged = { centralDriver.onMtuChanged(address, it) },
                            onDisconnected = { token, gen -> handleCentralDisconnected(address, token, gen) },
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

    private val publicationLock = Any()

    fun publishRelation(key: RelationKey, metadata: BleLinkInfoV1? = null): Boolean = synchronized(publicationLock) {
        val hadAny = publishedRelations.any { it.peerAddress == key.peerAddress }
        val added = publishedRelations.add(key)
        if (added) {
            if (!hadAny) {
                val peerMacBytes = PeerId.fromAddress(key.peerAddress) ?: key.peerAddress.toByteArray()
                val hint = metadata?.nodeHint ?: byteArrayOf()
                peerEventsFlow.tryEmit(
                    PeerEvent.Found(
                        peerId = peerMacBytes,
                        nodeHint = hint,
                        rssi = peerRssi[key.peerAddress],
                        sosFlag = metadata?.isSosPresent == true,
                        bulkCapable = metadata?.isBulkCapable == true,
                        shortDigest = metadata?.shortDigest ?: ByteArray(6),
                        queueDepth = metadata?.queueDepth ?: 0
                    )
                )
            }
            true
        } else {
            false
        }
    }

    fun unpublishRelation(key: RelationKey): Boolean = synchronized(publicationLock) {
        val hadAny = publishedRelations.any { it.peerAddress == key.peerAddress }
        val removed = publishedRelations.remove(key)
        if (removed) {
            if (hadAny) {
                val hasRemaining = publishedRelations.any { it.peerAddress == key.peerAddress }
                if (!hasRemaining) {
                    val peerMacBytes = PeerId.fromAddress(key.peerAddress) ?: key.peerAddress.toByteArray()
                    peerEventsFlow.tryEmit(PeerEvent.Lost(peerMacBytes))
                }
            }
            true
        } else {
            false
        }
    }

    fun handleInboundClientAdmitted(peerAddress: String, generation: Long) {
        inboundJobs.remove(peerAddress)?.cancel()
        val job = coroutineScope.launch {
            delay(PROVISIONAL_TIMEOUT_MS)
            handleInboundTimeout(peerAddress, generation)
        }
        inboundJobs[peerAddress] = job
    }

    fun hasInboundJob(peerAddress: String): Boolean = inboundJobs.containsKey(peerAddress)

    fun handleInboundTimeout(peerAddress: String, generation: Long = 0L) {
        val currentGen = serverDriver.getClientGeneration(peerAddress)
        if (generation != 0L && currentGen != 0L && currentGen != generation) {
            return
        }
        if (serverDriver.isPhysicalReady(peerAddress)) {
            return
        }
        val effectiveGen = if (generation != 0L) generation else currentGen
        serverDriver.onInboundTimeout(peerAddress, effectiveGen)
        inboundJobs.remove(peerAddress)?.cancel()
        responderRemoteLinkInfo.remove(peerAddress)
        gattServer.cancelConnection(peerAddress)
        unpublishRelation(RelationKey(BleDirection.INBOUND, peerAddress, effectiveGen))
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
        val gen = serverDriver.getClientGeneration(address)
        val key = RelationKey(BleDirection.INBOUND, address, gen)
        publishRelation(key, meta)
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

    fun handleCentralDisconnected(peerAddress: String, clientToken: Long = 0L, gattGen: Long = 0L) {
        val activeClient = activeClientConnections[peerAddress]
        if (clientToken != 0L && activeClient != null && activeClient.clientToken != clientToken) {
            return
        }
        provisionalJobs.remove(peerAddress)?.cancel()
        val conn = centralDriver.getActiveConnection(peerAddress)
        conn?.markDisconnected()
        val gen = centralDriver.getConnectionGeneration(peerAddress)
        val act = centralDriver.onDisconnected(peerAddress, gen)
        processCentralAction(peerAddress, act)
        activeClientConnections.remove(peerAddress)
        centralRemoteLinkInfo.remove(peerAddress)
        unpublishRelation(RelationKey(BleDirection.OUTBOUND, peerAddress, gen))
    }

    fun handleServerDisconnected(peerAddress: String, generation: Long = 0L) {
        val currentGen = serverDriver.getClientGeneration(peerAddress)
        if (generation != 0L && currentGen != 0L && currentGen != generation) {
            return
        }
        inboundJobs.remove(peerAddress)?.cancel()
        val effectiveGen = if (generation != 0L) generation else currentGen
        val conn = serverDriver.getInboundConnection(peerAddress)
        conn?.markDisconnected()
        serverDriver.onClientDisconnected(peerAddress, effectiveGen)
        responderRemoteLinkInfo.remove(peerAddress)
        unpublishRelation(RelationKey(BleDirection.INBOUND, peerAddress, effectiveGen))
    }

    fun isRelationPublished(direction: BleDirection, address: String, generation: Long = 0L): Boolean {
        return if (generation != 0L) {
            publishedRelations.contains(RelationKey(direction, address, generation))
        } else {
            publishedRelations.any { it.direction == direction && it.peerAddress == address }
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
                    val clear = sessions?.open(peerId, record.payload)
                    if (clear != null) {
                        trySend(peerId to clear)
                    }
                }
            }
        }
        awaitClose { job.cancel() }
    }

    companion object {
        val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID
        val WRITE_CHAR_UUID: UUID = UUID.fromString("0000fd01-0000-1000-8000-00805f9b34fb")
        val DIGEST_CHAR_UUID: UUID = UUID.fromString("0000fd02-0000-1000-8000-00805f9b34fb")
        val LINK_INFO_CHAR_UUID: UUID = FrameV2.LINK_INFO_UUID

        const val MAX_DISCOVERED_PEERS = 64
        const val MAX_ACTIVE_CONNECTIONS = 7
        const val PROVISIONAL_TIMEOUT_MS = 10000L
        const val LINK_LAYER_READY = false
    }
}
