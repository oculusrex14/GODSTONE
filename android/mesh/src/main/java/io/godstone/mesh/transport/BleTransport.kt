package io.godstone.mesh.transport

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
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

/** T17: the typed outcome of one transport-level submit of a frame for sending.
 * Admission, backpressure, rejection with a reason and the closed terminal are
 * four distinct answers; the old Boolean conflated them and the nullable error
 * paths let failures escape. */
sealed class TransportResult {
    /** The sealed fragments were queued or written; the submit is admitted. */
    object Admitted : TransportResult()

    /** The link queue is full; retry when the window opens again. */
    object Backpressured : TransportResult()

    /** The submit is refused; the reason names the refused precondition. */
    data class Rejected(val reason: String) : TransportResult()

    /** The relation is terminated for this peer; no retry applies. */
    object Closed : TransportResult()
}

@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context? = null,
    val identity: Identity,
    private val digestProvider: (suspend () -> BloomDigest)? = null,
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null,
    private val store: MessageStore? = null,
    private val coroutineScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val advertisingHooks: AdvertisingHooks? = null
) : Transport {

    override val name = "BLE"
    override val isBulkCapable = false

    private val btManager = context?.getSystemService(BluetoothManager::class.java)
    private val adapter get() = btManager?.adapter

    private var powerState = PowerState.NORMAL
    private var scanCallback: ScanCallback? = null

    /**
     * T09: the canonical advertising adapter. Production reaches the radio via
     * [RealAdvertisingHooks]; tests inject [advertisingHooks] to inspect the
     * exact settings and instruction stream handed to the platform.
     */
    private val advertiser: BleAdvertiser by lazy {
        BleAdvertiser(advertisingHooks ?: RealAdvertisingHooks(adapter?.bluetoothLeAdvertiser))
    }

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

    private val discoveryIndex = BoundedDiscoveryIndex<BleDiscoveryRecord>(
        capacity = MAX_DISCOVERED_PEERS,
        isPinned = { address -> isRelationPinned(address) }
    )
    private val scanGateLock = Any()

    @Volatile
    private var scanEpoch: Long = 0L

    @Volatile
    private var scanIdentity: Long = 0L

    @Volatile
    private var activeScanContext: ScanContext? = null
    private val centralRemoteLinkInfo = ConcurrentHashMap<String, BleLinkInfoV1>()
    private val responderRemoteLinkInfo = ConcurrentHashMap<String, BleLinkInfoV1>()
    private val publishedRelations = ConcurrentHashMap.newKeySet<RelationKey>()

    private val activeClientConnections = ConcurrentHashMap<String, GattClientConnection>()
    private val provisionalJobs = ConcurrentHashMap<String, Job>()
    private val inboundJobs = ConcurrentHashMap<String, Job>()
    /**
     * T12: the generation each provisional inbound job was armed with. The
     * timeout ends the arming it names, matched against this stamp - the
     * job's own record - never against a re-read of the driver's slot.
     */
    private val inboundJobGenerations = ConcurrentHashMap<String, Long>()

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
            synchronized(scanGateLock) {
                val ctx = activeScanContext
                if (ctx != null) {
                    retireScanContext(ctx)
                }
                discoveryIndex.releaseAll()
            }
        }
        for ((_, job) in provisionalJobs) {
            job.cancel()
        }
        provisionalJobs.clear()

        for ((_, job) in inboundJobs) {
            job.cancel()
        }
        inboundJobs.clear()
        inboundJobGenerations.clear()

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

    private fun startAdvertising(): Boolean {
        return advertiser.start(
            settings = canonicalAdvertiseSettings(),
            payload = canonicalAdvertisingPayload(),
            ready = gattServer.isServiceReady
        )
    }

    private fun stopAdvertising(): Boolean = advertiser.stop()

    /**
     * T09: the mesh advertises exactly the canonical service UUID and the
     * required platform flags. No LinkInfo bytes, no service data, no
     * manufacturer data, no local name and no identity hint ever ride the
     * air; the full 13-octet LinkInfo record is served by GATT.
     */
    fun canonicalAdvertisingPayload(): BleAdvertisingPayload =
        BleAdvertisingPayload.canonical(SERVICE_UUID)

    /** The settings half of the canonical submission, mirrored as inspectable values. */
    fun canonicalAdvertiseSettings(): BleAdvertiseSettings = BleAdvertiseSettings(
        mode = AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY,
        txPowerLevel = AdvertiseSettings.ADVERTISE_TX_POWER_HIGH,
        connectable = true
    )

    /** The single service UUID the scanner filter and the advertisement share. */
    fun canonicalScanFilterServiceUuid(): UUID = SERVICE_UUID

    /** Submit the canonical advertisement now; the typed outcome is in [lastAdvertisingResult]. */
    fun startAdvertisingNow(): Boolean = startAdvertising()

    /** Withdraw the advertisement; a stop without an outstanding submission is a no-op. */
    fun stopAdvertisingNow(): Boolean = stopAdvertising()

    /** The last typed advertising outcome observed by this transport, or null if none yet. */
    val lastAdvertisingResult: AdvertisingResult?
        get() = advertiser.lastResult

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
                val meta = centralRemoteLinkInfo[address] ?: discoveryIndex.valueOf(address)?.metadata
                val gen = centralDriver.getConnectionGeneration(address)
                publishRelation(RelationKey(BleDirection.OUTBOUND, address, gen), meta)
            }
            is BleCentralAction.PublishLost -> {
                // T12: the effect carries its exact token; the publication of
                // the named relation comes down - never a re-read of
                // whatever the current registration happens to be.
                provisionalJobs.remove(address)?.cancel()
                unpublishRelation(RelationKey(BleDirection.OUTBOUND, address, action.generation))
            }
            is BleCentralAction.DisconnectGatt -> {
                // T12: reject, timeout and local cancel reach terminal here
                // without awaiting a callback a closed handle can no longer
                // deliver. The close targets exactly the captured handle of
                // the named generation; a late intent for a superseded
                // attempt closes nothing and removes nothing that belongs to
                // the successor.
                provisionalJobs.remove(address)?.cancel()
                val captured = activeClientConnections[address]
                if (captured != null && captured.relationGeneration == action.generation) {
                    captured.closeCapturedHandle()
                    if (activeClientConnections[address] === captured) {
                        activeClientConnections.remove(address)
                        centralRemoteLinkInfo.remove(address)
                    }
                }
                unpublishRelation(RelationKey(BleDirection.OUTBOUND, address, action.generation))
            }
            BleCentralAction.NoOp -> {}
        }
    }

    override fun peers(): Flow<PeerEvent> = callbackFlow {
        val peerJob = coroutineScope.launch {
            peerEventsFlow.collect { event -> trySend(event) }
        }
        // T11: the scan source context is created complete - epoch, callback
        // identity and lease - before the scanner is told to call anybody
        // back. The shim below only captures the source and forwards a
        // ScanEvent; every mutation of transport state happens in the
        // reducer, after the exact context has been consulted.
        val context = openScanContext()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val sd = result.scanRecord?.getServiceData(ParcelUuid(SERVICE_UUID))
                val bytes = if (sd != null && sd.size == BleLinkInfoConstants.LINK_INFO_BYTES) sd else null
                handleScanEvent(captureScanEvent(context, callbackType, result.device.address, result.rssi, bytes))
            }

            override fun onScanFailed(errorCode: Int) {
                handleScanFailure(ScanFailureEvent(context, errorCode))
            }
        }
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(canonicalScanFilterServiceUuid())).build()
        adapter?.bluetoothLeScanner?.startScan(listOf(filter), settings, cb)
        scanCallback = cb
        awaitClose {
            peerJob.cancel()
            retireScanContext(context)
            adapter?.bluetoothLeScanner?.stopScan(cb)
        }
    }

    /**
     * The capture step of the callback boundary. Source identity, signal
     * and any well-formed link info payload are snapshotted here, before
     * delivery: the event carries no platform object, so a late callback
     * can deliver only this immutable snapshot, never a live result.
     */
    fun captureScanEvent(
        context: ScanContext,
        callbackType: Int,
        address: String?,
        signal: Int?,
        linkInfoBytes: ByteArray?
    ): ScanEvent {
        val metadata = if (linkInfoBytes == null) {
            null
        } else if (linkInfoBytes.size == BleLinkInfoConstants.LINK_INFO_BYTES) {
            BleLinkInfoCodec.decode(linkInfoBytes)
        } else {
            null
        }
        return ScanEvent(context, callbackType, address, signal, metadata)
    }

    /** Open the next scan registration: a fresh epoch, identity and lease. */
    private fun openScanContext(): ScanContext = synchronized(scanGateLock) {
        scanEpoch += 1L
        scanIdentity += 1L
        val ctx = ScanContext(scanEpoch, scanIdentity, ScanLease())
        activeScanContext = ctx
        ctx
    }

    /** Terminate one registration; it never touches any other context. */
    private fun retireScanContext(context: ScanContext) {
        context.lease.release()
        if (activeScanContext === context) {
            activeScanContext = null
        }
    }

    /**
     * The scan reducer. The event must name the exact context that is still
     * the active registration of a started transport, in the currently open
     * epoch, with a live lease. Any other event is dropped where it stands
     * and mutates nothing: a late delivery of a retired or replaced
     * registration can never reach the newer state. The epoch is read at
     * arrival, never inferred from a current-state lookup afterwards.
     */
    fun handleScanEvent(event: ScanEvent): Boolean {
        val context = event.context
        if (!isStarted) {
            return false
        }
        if (context !== activeScanContext || !context.isCurrent(scanEpoch) || !context.isActive()) {
            return false
        }
        val address = event.address
        if (address == null) {
            return false
        }
        synchronized(scanGateLock) {
            if (context !== activeScanContext || !context.isCurrent(scanEpoch) || !context.isActive()) {
                return false
            }
            var record = discoveryIndex.valueOf(address)
            if (record == null) {
                record = BleDiscoveryRecord()
            }
            record.absorb(event.metadata, event.rssi)
            discoveryIndex.observe(address, record)
        }
        val action = centralDriver.onScanResult(address, event.rssi, event.metadata?.nodeHint)
        if (action is BleCentralAction.ConnectGatt) {
            synchronized(scanGateLock) {
                // Revalidate the token on completion: a stop or a newer
                // registration that began while the driver was consulted
                // denies this scheduling step.
                if (context !== activeScanContext || !context.isCurrent(scanEpoch) || !context.isActive()) {
                    return false
                }
                scheduleConnectFromScan(address, action)
            }
        }
        return true
    }

    /**
     * A scan failure terminates only its own context: the transport keeps
     * running, other state survives, and permission recovery is simply a
     * fresh registration through peers().
     */
    fun handleScanFailure(event: ScanFailureEvent): Boolean {
        val context = event.context
        if (context !== activeScanContext) {
            return false
        }
        if (!context.isActive()) {
            return false
        }
        retireScanContext(context)
        return true
    }

    /** Active relations are pinned: the discovery bound must not evict them. */
    private fun isRelationPinned(address: String): Boolean {
        if (activeClientConnections.containsKey(address)) {
            return true
        }
        if (centralDriver.getActiveConnection(address)?.isActive == true) {
            return true
        }
        return publishedRelations.any { it.peerAddress == address }
    }

    /** The scheduling half of a connect intent, carried verbatim from the former shim body. */
    private fun scheduleConnectFromScan(address: String, action: BleCentralAction.ConnectGatt) {
            val scheduledGen = centralDriver.getConnectionGeneration(address)
            val existing = activeClientConnections[address]
            if (existing != null && existing.relationGeneration != scheduledGen) {
                // T12: a stale entry from a dead attempt owns a handle of
                // the dead generation: close exactly that captured handle
                // before the successor's client is installed; the
                // successor's tokens are stamped at creation below.
                existing.closeCapturedHandle()
                if (activeClientConnections[address] === existing) {
                    activeClientConnections.remove(address)
                }
            }
            val client = activeClientConnections.getOrPut(address) {
                GattClientConnection(
                    context = context,
                    peerAddress = address,
                    relationGeneration = scheduledGen,
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
            val gen = centralDriver.getConnectionGeneration(address)
            provisionalJobs[address]?.cancel()
            provisionalJobs[address] = coroutineScope.launch {
                delay(PROVISIONAL_TIMEOUT_MS)
                if (centralDriver.getConnectionGeneration(address) == gen) {
                    val conn = centralDriver.getActiveConnection(address)
                    if (conn?.isHandshakeTransportReady != true) {
                        val timeoutAct = centralDriver.onProvisionalTimeout(address, gen)
                        processCentralAction(address, timeoutAct)
                    }
                }
            }
            processCentralAction(address, action)
    }

    /** Test seam: the currently active scan context, or null. */
    fun activeScanContextForTest(): ScanContext? = activeScanContext

    /** Test seam: advance the epoch, as a replacement registration would. */
    fun bumpScanEpochForTest() {
        synchronized(scanGateLock) {
            scanEpoch += 1L
        }
    }

    /** Test seam: the client stored for one address, or null. */
    fun activeClientForTest(address: String): GattClientConnection? = activeClientConnections[address]

    /** Test seam: the discovery surface size of the current run. */
    fun discoveredCountForTest(): Int = discoveryIndex.size

    /** Test seam: whether one address is currently discovered. */
    fun isPeerDiscoveredForTest(address: String): Boolean = discoveryIndex.contains(address)

    /** Test seam: the metadata of one discovered peer, or null. */
    fun discoveredMetadataForTest(address: String): BleLinkInfoV1? = discoveryIndex.valueOf(address)?.metadata

    /** Test seam: the signal of one discovered peer, or null. */
    fun rssiForTest(address: String): Int? = discoveryIndex.valueOf(address)?.rssi

    /** Test seam: open a registration without a radio, for reducer driving. */
    fun openScanContextForTest(): ScanContext = openScanContext()
    /** Test seam: the observation-ordered survivor list of the bounded surface. */
    fun discoveredAddressesForTest(): List<String> = discoveryIndex.addresses()

    /** Test seam: scheduled outbound client count, the platform action trace. */
    fun activeClientCountForTest(): Int = activeClientConnections.size

    /** Test seam: whether the provisional connect timeout job is pending. */
    fun hasProvisionalJobForTest(address: String): Boolean = provisionalJobs.containsKey(address)

    /** Test seam: whether the transport run is started. */
    fun isTransportStartedForTest(): Boolean = isStarted

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
                        rssi = discoveryIndex.valueOf(key.peerAddress)?.rssi,
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
        inboundJobGenerations[peerAddress] = generation
        val job = coroutineScope.launch {
            delay(PROVISIONAL_TIMEOUT_MS)
            handleInboundTimeout(peerAddress, generation)
        }
        inboundJobs[peerAddress] = job
    }

    fun hasInboundJob(peerAddress: String): Boolean = inboundJobs.containsKey(peerAddress)

    fun handleInboundTimeout(peerAddress: String, generation: Long) {
        // T12: the provisional job carries the exact generation it was
        // scheduled for; a timeout ends that registration only, never a
        // newer one that took its place.
        val armed = inboundJobGenerations[peerAddress]
        if (armed == null || armed != generation) {
            return
        }
        if (serverDriver.isPhysicalReady(peerAddress)) {
            return
        }
        val effectiveGen = generation
        serverDriver.onInboundTimeout(peerAddress, effectiveGen)
        inboundJobs.remove(peerAddress)?.cancel()
        inboundJobGenerations.remove(peerAddress)
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

    /**
     * Test seam: schedule a driver effect through the transport's one
     * action dispatcher, exactly as the platform callback boundary does.
     * The production call sites reach it through the captured hooks; the
     * determinism tests of the terminal effects drive it directly.
     */
    fun dispatchCentralActionForTest(address: String, action: BleCentralAction) {
        processCentralAction(address, action)
    }

    fun handleCentralInboundNotification(peerAddress: String, value: ByteArray) {
        val conn = centralDriver.getActiveConnection(peerAddress) ?: return
        if (!conn.isRoleBound) return
        val record = conn.ingestInboundAttValue(value).admittedRecord ?: return
        val peerId = conn.peerId
        inboundRecordFlow.tryEmit(peerId to record)
    }

    fun handleServerInboundWrite(peerAddress: String, value: ByteArray) {
        val conn = serverDriver.getInboundConnection(peerAddress) ?: return
        if (!conn.isRoleBound) return
        val record = conn.ingestInboundAttValue(value).admittedRecord ?: return
        val peerId = conn.peerId
        inboundRecordFlow.tryEmit(peerId to record)
    }

    fun handleCentralDisconnected(peerAddress: String, clientToken: Long, gattGen: Long) {
        // T12: the event must name the client registration it came from.
        // Validation first: an event that does not match the stored
        // client's tokens is dropped where it stands, and no current-state
        // lookup stands in for the missing identity. Only then does the
        // named relation terminate - through the driver's one authority,
        // by the generation this client was scheduled for.
        val client = activeClientConnections[peerAddress] ?: return
        if (client.clientToken != clientToken || client.gattGeneration != gattGen) {
            return
        }
        val relationGen = client.relationGeneration
        provisionalJobs.remove(peerAddress)?.cancel()
        val act = centralDriver.onDisconnected(peerAddress, relationGen)
        processCentralAction(peerAddress, act)
        if (activeClientConnections[peerAddress] === client) {
            activeClientConnections.remove(peerAddress)
            centralRemoteLinkInfo.remove(peerAddress)
        }
        unpublishRelation(RelationKey(BleDirection.OUTBOUND, peerAddress, relationGen))
    }

    fun handleServerDisconnected(peerAddress: String, generation: Long) {
        // T12: the event names the exact registration it terminates. An
        // event for another generation - a late terminal of a superseded
        // client, for one - is dropped where it stands and changes
        // nothing; the successor's slot, lease and publication stay intact.
        val currentGen = serverDriver.getClientGeneration(peerAddress)
        if (currentGen != generation) {
            return
        }
        inboundJobs.remove(peerAddress)?.cancel()
        val conn = serverDriver.getInboundConnection(peerAddress)
        conn?.markDisconnected()
        serverDriver.onClientDisconnected(peerAddress, generation)
        responderRemoteLinkInfo.remove(peerAddress)
        unpublishRelation(RelationKey(BleDirection.INBOUND, peerAddress, generation))
    }

    /**
     * The observable question, at all: is any relation of this direction
     * for this address published, whatever its generation. The exact
     * question isRelationPublished asks generation by generation remains
     * the primary one; this query serves lifecycle inspection and the
     * tests that assert a peer is not published at all.
     */
    fun isAnyRelationPublishedForAddress(direction: BleDirection, address: String): Boolean {
        return publishedRelations.any { it.direction == direction && it.peerAddress == address }
    }

    fun isRelationPublished(direction: BleDirection, address: String, generation: Long): Boolean {
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
        // T10: every GATT identifier is the generated wire-contract value.
        // The historical hand-rolled FD short-form characteristic constants
        // (0000fd01/0000fd02) are the non-shipping legacy profile: removed,
        // never dual-registered, and rejected by RequiredCharacteristicSet's
        // provisioning gate. Aliases keep their established names.
        val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID
        val WRITE_CHAR_UUID: UUID = FrameV2.INBOX_UUID
        val DIGEST_CHAR_UUID: UUID = FrameV2.DIGEST_UUID
        val LINK_INFO_CHAR_UUID: UUID = FrameV2.LINK_INFO_UUID

        const val MAX_DISCOVERED_PEERS = 64
        const val MAX_ACTIVE_CONNECTIONS = 7
        const val PROVISIONAL_TIMEOUT_MS = 10000L
        const val LINK_LAYER_READY = false
    }
}
