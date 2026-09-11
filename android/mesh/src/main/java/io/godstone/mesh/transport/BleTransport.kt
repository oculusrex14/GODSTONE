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
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import java.util.Collections
import java.util.LinkedHashMap
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap


/**
 * T17: the transport's two GATT outlets behind one seam, as the advertising
 * plane is behind [AdvertisingHooks]. Production binds the platform server
 * and the client connections; suites inject a recording fake to observe the
 * exact fragment stream the transport would put on the wire.
 */
interface BleOutletHooks {
    fun isPeerSubscribed(address: String): Boolean
    suspend fun notifyPeer(address: String, value: ByteArray): Boolean
    fun isClientConnected(address: String): Boolean
    suspend fun writePeer(address: String, value: ByteArray): Boolean

    /** T18: the typed voice of each leg; the Boolean voices stay for
     * their existing callers. A leg that answers only true or false is
     * read as accepted or queue-full - the conservative reading: a
     * refusal to write is retried, a relation is never closed on an
     * ambiguity. A leg that knows better, as the production bindings
     * do, overrides. */
    suspend fun notifyPeerTyped(address: String, value: ByteArray): WriteCompletion =
        if (notifyPeer(address, value)) WriteCompletion.Accepted else WriteCompletion.QueueFull

    suspend fun writePeerTyped(address: String, value: ByteArray): WriteCompletion =
        if (writePeer(address, value)) WriteCompletion.Accepted else WriteCompletion.QueueFull
}

@SuppressLint("MissingPermission")
class BleTransport(
    private val context: Context? = null,
    val identity: Identity,
    private val digestProvider: (suspend () -> BloomDigest)? = null,
    private val sessions: io.godstone.mesh.crypto.SessionManager? = null,
    private val store: MessageStore? = null,
    private val coroutineScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val advertisingHooks: AdvertisingHooks? = null,
    private val outletHooks: BleOutletHooks? = null
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
    internal fun activeScanContextForTest(): ScanContext? = activeScanContext

    /** Test seam: advance the epoch, as a replacement registration would. */
    internal fun bumpScanEpochForTest() {
        synchronized(scanGateLock) {
            scanEpoch += 1L
        }
    }

    /** Test seam: the client stored for one address, or null. */
    internal fun activeClientForTest(address: String): GattClientConnection? = activeClientConnections[address]

    /** Test seam: the discovery surface size of the current run. */
    internal fun discoveredCountForTest(): Int = discoveryIndex.size

    /** Test seam: whether one address is currently discovered. */
    internal fun isPeerDiscoveredForTest(address: String): Boolean = discoveryIndex.contains(address)

    /** Test seam: the metadata of one discovered peer, or null. */
    internal fun discoveredMetadataForTest(address: String): BleLinkInfoV1? = discoveryIndex.valueOf(address)?.metadata

    /** Test seam: the signal of one discovered peer, or null. */
    internal fun rssiForTest(address: String): Int? = discoveryIndex.valueOf(address)?.rssi

    /** Test seam: open a registration without a radio, for reducer driving. */
    internal fun openScanContextForTest(): ScanContext = openScanContext()
    /** Test seam: the observation-ordered survivor list of the bounded surface. */
    internal fun discoveredAddressesForTest(): List<String> = discoveryIndex.addresses()

    /** Test seam: scheduled outbound client count, the platform action trace. */
    internal fun activeClientCountForTest(): Int = activeClientConnections.size

    /** Test seam: whether the provisional connect timeout job is pending. */
    internal fun hasProvisionalJobForTest(address: String): Boolean = provisionalJobs.containsKey(address)

    /** Test seam: whether the transport run is started. */
    internal fun isTransportStartedForTest(): Boolean = isStarted

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
    internal fun dispatchCentralActionForTest(address: String, action: BleCentralAction) {
        processCentralAction(address, action)
    }

    fun handleCentralInboundNotification(peerAddress: String, value: ByteArray) {
        val conn = centralDriver.getActiveConnection(peerAddress) ?: return
        if (!conn.isRoleBound) return
        activeClientConnections[peerAddress]?.let { client ->
            val boundGen = client.relationGeneration
            conn.relationKeyProvider = { RelationKey(BleDirection.OUTBOUND, peerAddress, boundGen) }
        }
        val ingested = conn.ingestInboundAttValue(value)
        if (conn.takeLeaseExpiryNotice() != null) {
            // T20: the absolute term of a whole-record assembly lapsed on
            // this ingress. The reassembler has released its buffers; only
            // the owner closes the relation, and it does so through the
            // very arm the platform own disconnect travels.
            val client = activeClientConnections[peerAddress]
            if (client != null) {
                handleCentralDisconnected(peerAddress, client.clientToken, client.gattGeneration)
            }
            centralWriters.remove(peerAddress)
            return
        }
        val record = ingested.admittedRecord
        if (record == null) {
            // T17: a rejected record is a bounded event, never a silent
            // fall-through; an in-flight one is pending, not a failure.
            if (ingested is BleRecordIngestResult.Rejected) {
                recordRejection(conn.peerId, "ingest.notify", describeRejection(ingested.reason))
                // T21 (section 13): an out-of-order HANDSHAKE sequence is a
                // conflicting record - the exact relation closes, never
                // drifts. A DATA record at an unready stage remains the T17
                // bounded refusal: typed, one event, the relation stands; and
                // a quarantined relation awaits its rotation, slain by none.
                if (ingested.reason == BleRecordRejection.UNEXPECTED_STAGE &&
                    conn.state != BleConnectionState.QUARANTINED &&
                    namesHandshakeRecord(value)) {
                    closeInitiatorRelation(peerAddress)
                }
            }
            return
        }
        when (record.recordType) {
            BleRecordType.DATA -> inboundRecordFlow.tryEmit(conn.peerId to record)
            BleRecordType.HS2 -> handleInitiatorHandshakeRecord(peerAddress, conn, record)
            else -> recordRejection(conn.peerId, "hs.read.initiator", "unexpected direction")
        }
    }

    fun handleServerInboundWrite(peerAddress: String, value: ByteArray) {
        val conn = serverDriver.getInboundConnection(peerAddress) ?: return
        if (!conn.isRoleBound) return
        serverDriver.getClientGeneration(peerAddress)?.let { gen ->
            conn.relationKeyProvider = { RelationKey(BleDirection.INBOUND, peerAddress, gen) }
        }
        val ingested = conn.ingestInboundAttValue(value)
        if (conn.takeLeaseExpiryNotice() != null) {
            // T20: the absolute term lapsed on this ingress; the owner
            // closes through the server own disconnect arm, generation
            // validated as ever, and the direction writer retires with the
            // relation it served.
            handleServerDisconnected(peerAddress, serverDriver.getClientGeneration(peerAddress) ?: return)
            serverWriters.remove(peerAddress)
            return
        }
        val record = ingested.admittedRecord
        if (record == null) {
            if (ingested is BleRecordIngestResult.Rejected) {
                recordRejection(conn.peerId, "ingest.write", describeRejection(ingested.reason))
                // T21 (section 13): the out-of-order HANDSHAKE sequence closes
                // the exact relation through the server arm, generation and
                // all; DATA at an unready stage and a quarantined relation
                // both abide, as T17 and T16 rule.
                if (ingested.reason == BleRecordRejection.UNEXPECTED_STAGE &&
                    conn.state != BleConnectionState.QUARANTINED &&
                    namesHandshakeRecord(value)) {
                    handleServerDisconnected(peerAddress,
                        serverDriver.getClientGeneration(peerAddress) ?: return)
                    serverWriters.remove(peerAddress)
                }
            }
            return
        }
        when (record.recordType) {
            BleRecordType.DATA -> inboundRecordFlow.tryEmit(conn.peerId to record)
            BleRecordType.HS1, BleRecordType.HS3 -> handleResponderHandshakeRecord(peerAddress, conn, record)
            else -> {
                // T22: the responders own voice come again is a conflicting
                // sequence; the exact relation falleth. The farewell record
                // (CLOSE) is spared here - its policy is T23s charge.
                recordRejection(conn.peerId, "hs.read.responder", "unexpected direction")
                if (namesHandshakeRecord(value)) {
                    closeResponderRelation(peerAddress)
                }
            }
        }
    }

    /**
     * T20: the heartbeat of the absolute lease. The reassembler sweeps at
     * every ingress as matter; this sweeps the relations whose peers have
     * gone silent altogether, so a stalled dribble cannot pin a slot and a
     * buffer until some unrelated event happens to arrive. Each lapsed
     * lease is released and reported by the connection's own sweep, and
     * the affected relation is closed through the very arms the platform's
     * terminals travel - nothing here invents a terminal the platform did
     * not deliver.
     */
    /** T21: the census of publications, for the suites' sight. Observation
     *  only: nothing here alters what the publication door keeps. */
    internal fun publishedRelationsForTest(): List<RelationKey> =
        synchronized(publicationLock) { publishedRelations.toList() }

    fun sweepInboundLeases() {
        for ((address, conn) in centralDriver.allActiveConnectionsForTest()) {
            if (conn.sweepLeases()) {
                val client = activeClientConnections[address]
                if (client != null) {
                    handleCentralDisconnected(address, client.clientToken, client.gattGeneration)
                }
                centralWriters.remove(address)
            }
        }
        for ((address, conn) in serverDriver.allInboundConnectionsForTest()) {
            if (conn.sweepLeases()) {
                handleServerDisconnected(address, serverDriver.getClientGeneration(address))
                serverWriters.remove(address)
            }
        }
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
        // T21 (section 13, D2): the validated terminal ruins the session
        // slot with the relation - once, on this path, whatever follows.
        val peerForRuin = centralDriver.getActiveConnection(peerAddress)?.peerId?.copyOf()
        provisionalJobs.remove(peerAddress)?.cancel()
        val act = centralDriver.onDisconnected(peerAddress, relationGen)
        processCentralAction(peerAddress, act)
        if (activeClientConnections[peerAddress] === client) {
            activeClientConnections.remove(peerAddress)
            centralRemoteLinkInfo.remove(peerAddress)
        }
        unpublishRelation(RelationKey(BleDirection.OUTBOUND, peerAddress, relationGen))
        if (peerForRuin != null) sessions?.destroyFor(peerForRuin)
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
        // T21 (section 13, D2): the exact session slot perishes with the
        // exact relation, once the generation has matched the event.
        val peerForRuin = conn?.peerId?.copyOf()
        conn?.markDisconnected()
        serverDriver.onClientDisconnected(peerAddress, generation)
        responderRemoteLinkInfo.remove(peerAddress)
        unpublishRelation(RelationKey(BleDirection.INBOUND, peerAddress, generation))
        if (peerForRuin != null) sessions?.destroyFor(peerForRuin)
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

    override suspend fun send(peerId: ByteArray, bytes: ByteArray): TransportResult {
        // T18: nothing is sealed and no sequence number is taken before the
        // whole record stands reserved. The fixed five hundred twelve octet
        // gate is gone: the ceiling is computed from the agreed attribute
        // space, so a full digest travels where the old gate refused.
        val registry = sessions ?: run {
            recordRejection(peerId, "send", "no trusted session registry")
            return TransportResult.Rejected("no trusted session registry")
        }
        val address = resolvePeerAddress(peerId) ?: run {
            recordRejection(peerId, "send", "malformed peer address")
            return TransportResult.Rejected("malformed peer address")
        }
        val centralConn = centralDriver.getActiveConnection(address)
        val serverConn = serverDriver.getInboundConnection(address)
        val terminal = setOf(BleConnectionState.CLOSING, BleConnectionState.CLOSED,
                             BleConnectionState.QUARANTINED)

        if (centralConn?.state == BleConnectionState.READY) {
            if (!outlet.isClientConnected(address)) {
                recordRejection(peerId, "send.initiator", "no outlet: client absent or disconnected")
                return TransportResult.Rejected("no outlet: client absent or disconnected")
            }
            val writer = centralWriterFor(address, centralConn)
            return sendThrough(writer, peerId, bytes, registry, centralConn.peerId,
                address, initiator = true)
        }
        if (centralConn != null && centralConn.state in terminal) {
            centralWriterShutdown(address)
            return TransportResult.Closed
        }

        if (serverConn?.state == BleConnectionState.READY) {
            if (!outlet.isPeerSubscribed(address)) {
                recordRejection(peerId, "send.responder", "no subscription towards the peer")
                return TransportResult.Rejected("no subscription towards the peer")
            }
            val writer = serverWriterFor(address, serverConn)
            return sendThrough(writer, peerId, bytes, registry, serverConn.peerId,
                address, initiator = false)
        }
        if (serverConn != null && serverConn.state in terminal) {
            serverWriterShutdown(address)
            return TransportResult.Closed
        }
        if (centralConn != null || serverConn != null) {
            // T17: a standing relation that has not reached the ready state is
            // a distinct answer from an absent one, as on the other side.
            recordRejection(peerId, "send", "connection not ready")
            return TransportResult.Rejected("connection not ready")
        }
        centralWriterShutdown(address)
        serverWriterShutdown(address)
        recordRejection(peerId, "send", "no such connection")
        return TransportResult.Rejected("no such connection")
    }

    private suspend fun sendThrough(writer: RecordWriter, peerId: ByteArray, bytes: ByteArray,
                                    registry: io.godstone.mesh.crypto.SessionManager,
                                    key: ByteArray, address: String,
                                    initiator: Boolean): TransportResult {
        val site = if (initiator) "send.initiator" else "send.responder"
        when (val answer = writer.reserve(BleRecordType.DATA, bytes.size)) {
            is ReservationAnswer.Refused -> {
                val why = describeAdmission(answer.error)
                val eventSite = if (answer.error is AdmissionError.NotEnoughCapacity)
                    "send.capacity" else site
                recordRejection(peerId, eventSite, why)
                return when (answer.error) {
                    is AdmissionError.TooManyStaged, AdmissionError.BusyInFlight ->
                        TransportResult.Backpressured
                    AdmissionError.Inactive -> TransportResult.Closed
                    else -> TransportResult.Rejected(why)
                }
            }
            is ReservationAnswer.Admitted -> {
                when (val seal = answer.reservation.sealAndQueue(bytes) { clear ->
                        registry.seal(key, clear)
                    }) {
                    is SealAnswer.Refused -> {
                        // The refusals of the seal are told in the voices the
                        // recorded expectations know: the seal itself, the
                        // fragmentation, the station of the relation.
                        val reason = seal.reason
                        val (eventSite, eventReason, answerReason) = when (reason) {
                            "the seal refused" -> Triple("seal", "authentication refused", "seal refused")
                            "the fragmenter refused the record" ->
                                Triple("send.fragment", "fragmentation refused", "fragmentation refused")
                            "the seal lied about the envelope" ->
                                Triple("seal", reason, "seal refused")
                            "the sealed record outgrew the ceiling" ->
                                Triple("send.fragment", reason, "fragmentation refused")
                            "the payload drifted from the reservation" ->
                                Triple(site, reason, reason)
                            "the staging filled before the seal" ->
                                Triple(site, reason, reason)
                            else -> Triple(site, reason, reason)
                        }
                        recordRejection(peerId, eventSite, eventReason)
                        return when (reason) {
                            "the relation fell before the seal" -> TransportResult.Closed
                            "the staging filled before the seal" -> TransportResult.Backpressured
                            else -> TransportResult.Rejected(answerReason)
                        }
                    }
                    is SealAnswer.Queued ->
                        // The window may stand full with the record's rest
                        // yet to enter: that fullness is told, once, truly.
                        if (writer.stagingSaturatedForTest()) {
                            recordRejection(peerId, site, "the staging is full")
                        }
                }
            }
        }
        // The pump: at most one value in flight, advanced only by real
        // completions; a queue-full refusal re-hands the very same fragment
        // on the next send, a mid-write failure closes the relation.
        while (true) {
            val out = writer.nextOut() ?: break
            val completion = if (initiator) outlet.writePeerTyped(address, out.bytes)
                else outlet.notifyPeerTyped(address, out.bytes)
            when (completion) {
                WriteCompletion.Accepted -> writer.completed(out.operation)
                WriteCompletion.QueueFull -> {
                    writer.rewindInFlight(out.operation)
                    recordRejection(peerId, site, "queue full")
                    return TransportResult.Backpressured
                }
                WriteCompletion.Failed -> {
                    writer.failed(out.operation)
                    recordRejection(peerId, site, "a write failed midway; the relation is closed")
                    if (initiator) {
                        centralWriters.remove(address)
                        centralDriver.getActiveConnection(address)?.markDisconnected()
                    } else {
                        serverWriters.remove(address)
                        serverDriver.getInboundConnection(address)?.markDisconnected()
                    }
                    return TransportResult.Closed
                }
            }
        }
        return TransportResult.Admitted
    }

    override fun received(): Flow<Pair<ByteArray, ByteArray>> = callbackFlow {
        val job = coroutineScope.launch {
            inboundRecordFlow.collect { (peerId, record) ->
                if (record.recordType == BleRecordType.DATA) {
                    // T17: the open answers by result now, and an
                    // unauthenticated frame is a bounded event - the
                    // collector keeps running either way.
                    val registry = sessions
                    // T17: the collector is total: whatever the registry's
                    // answer - by result or by exception - becomes a bounded
                    // event, and the collect loop runs on regardless.
                    val outcome = try {
                        registry?.openWithResult(peerId, record.payload) ?: io.godstone.mesh.crypto.NoiseSession.CryptoOpenResult.Rejected
                    } catch (_: Throwable) {
                        io.godstone.mesh.crypto.NoiseSession.CryptoOpenResult.Rejected
                    }
                    when (outcome) {
                        is io.godstone.mesh.crypto.NoiseSession.CryptoOpenResult.Authenticated ->
                            trySend(peerId to outcome.plaintext)
                        is io.godstone.mesh.crypto.NoiseSession.CryptoOpenResult.Rejected ->
                            recordRejection(peerId, "receive", "unauthenticated payload")
                        is io.godstone.mesh.crypto.NoiseSession.CryptoOpenResult.Expired ->
                            recordRejection(peerId, "receive", "replay window")
                    }
                }
            }
        }
        awaitClose { job.cancel() }
    }

    // MARK: - T17 bounded rejection events and the trusted handshake driver

    /** The collector of rejection events is bounded: the eldest record
     *  makes way and the overflow is counted, so continuity of the stream
     *  survives any number of malformed packets. */
    internal val rejectionRecordCapacity: Int get() = REJECTION_RECORD_CAPACITY

    data class RejectionRecord(val peerId: ByteArray, val site: String, val reason: String)

    private val rejectionLock = Any()
    private val rejectionRecords = ArrayDeque<RejectionRecord>()
    private var rejectionOverflow = 0

    private fun recordRejection(peerId: ByteArray, site: String, reason: String) =
        synchronized(rejectionLock) {
            if (rejectionRecords.size >= REJECTION_RECORD_CAPACITY) {
                rejectionRecords.removeFirst()
                rejectionOverflow += 1
            }
            rejectionRecords.addLast(RejectionRecord(peerId.copyOf(), site, reason))
        }

    internal fun rejectionRecordsForTest(): List<RejectionRecord> =
        synchronized(rejectionLock) { rejectionRecords.toList() }

    internal fun rejectionOverflowCountForTest(): Int =
        synchronized(rejectionLock) { rejectionOverflow }

    internal fun clearRejectionRecordsForTest() = synchronized(rejectionLock) {
        rejectionRecords.clear()
        rejectionOverflow = 0
    }

    /** T17: a peer id reaches the air address by either representation -
     *  the six octets on the wire or the colonned string a station keeps
     *  in its records. Neither form is the registry key; the connection's
     *  own peerId is, so both forms only locate. */
    private fun resolvePeerAddress(peerId: ByteArray): String? {
        PeerId.toAddress(peerId)?.let { return it }
        if (peerId.isEmpty() || peerId.size > 17) return null
        val text = peerId.decodeToString()
        return if (text.matches(Regex("^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"))) text else null
    }

    private fun describeRejection(reason: BleRecordRejection): String = when (reason) {
        BleRecordRejection.INACTIVE -> "inactive connection"
        BleRecordRejection.MALFORMED_RECORD -> "malformed record"
        BleRecordRejection.UNEXPECTED_STAGE -> "unexpected stage"
    }

    private val outlet: BleOutletHooks by lazy {
        outletHooks ?: object : BleOutletHooks {
            override fun isPeerSubscribed(address: String): Boolean = gattServer.isSubscribed(address)
            override suspend fun notifyPeer(address: String, value: ByteArray): Boolean =
                gattServer.sendNotification(address, value)
            override fun isClientConnected(address: String): Boolean =
                activeClientConnections[address]?.isConnected == true
            override suspend fun writePeer(address: String, value: ByteArray): Boolean =
                activeClientConnections[address]?.sendAttValue(value) ?: false
            override suspend fun notifyPeerTyped(address: String, value: ByteArray): WriteCompletion =
                gattServer.sendNotificationTyped(address, value)
            override suspend fun writePeerTyped(address: String, value: ByteArray): WriteCompletion =
                activeClientConnections[address]?.sendAttValueTyped(value) ?: WriteCompletion.Failed
        }
    }

    // T18: one whole-record writer per direction of a relation; the
    // two arms of the transport speak over these two writers.
    private val centralWriters = HashMap<String, RecordWriter>()
    private val serverWriters = HashMap<String, RecordWriter>()

    private fun centralWriterFor(address: String, connection: BleConnection): RecordWriter =
        synchronized(centralWriters) {
            val standing = centralWriters[address]
            if (standing != null && standing.connection === connection) standing
            else {
                // A fresh session brings fresh writers: what stood under the
                // old connection is released, the durable store is not touched.
                standing?.shutdown()
                val fresh = RecordWriter(connection, RelationKey(BleDirection.OUTBOUND, address, 0L))
                centralWriters[address] = fresh
                fresh
            }
        }

    private fun serverWriterFor(address: String, connection: BleConnection): RecordWriter =
        synchronized(serverWriters) {
            val standing = serverWriters[address]
            if (standing != null && standing.connection === connection) standing
            else {
                standing?.shutdown()
                val fresh = RecordWriter(connection, RelationKey(BleDirection.INBOUND, address, 0L))
                serverWriters[address] = fresh
                fresh
            }
        }

    private fun centralWriterShutdown(address: String) {
        synchronized(centralWriters) { centralWriters.remove(address)?.shutdown() }
    }

    private fun serverWriterShutdown(address: String) {
        synchronized(serverWriters) { serverWriters.remove(address)?.shutdown() }
    }

    internal fun centralWriterForTest(address: String): RecordWriter? =
        synchronized(centralWriters) { centralWriters[address] }

    internal fun serverWriterForTest(address: String): RecordWriter? =
        synchronized(serverWriters) { serverWriters[address] }

    private fun describeAdmission(error: AdmissionError): String = when (error) {
        is AdmissionError.NotEnoughCapacity ->
            "frame exceeds the payload ceiling: sealed " + error.sealedLength +
                " octets against " + error.ceiling + " in " + error.fragmentCount + " fragments"
        is AdmissionError.TooManyAdmitted -> "too many admitted records on the relation"
        is AdmissionError.TooManyStaged -> "the staging is full"
        AdmissionError.BusyInFlight -> "an operation stands in flight"
        AdmissionError.Inactive -> "the relation has fallen"
    }

    private val handshakeReadyFlow = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64)

    /** The composition listens for the driver's proof that a peer's slot
     *  reached the cryptographic ready state. */
    fun handshakeReady(): Flow<ByteArray> = callbackFlow {
        val job = coroutineScope.launch {
            handshakeReadyFlow.collect { peerId -> trySend(peerId) }
        }
        awaitClose { job.cancel() }
    }

    private fun handleResponderHandshakeRecord(peerAddress: String, conn: BleConnection,
                                                  record: BleReassembledRecord) {
        val registry = sessions ?: run {
            recordRejection(conn.peerId, "hs.read.responder", "no trusted session registry")
            closeResponderRelation(peerAddress)
            return
        }
        val hint = conn.remoteNodeHint ?: run {
            recordRejection(conn.peerId, "hs.read.responder", "no remembered link-info hint")
            closeResponderRelation(peerAddress)
            return
        }
        if (!BleConnection.canBindRemoteHint(hint)) {
            recordRejection(conn.peerId, "hs.read.responder", "malformed remembered hint")
            closeResponderRelation(peerAddress)
            return
        }
        if (conn.localRole != BleRole.RESPONDER) {
            // T22 (section 13): the door is the responders, by the assigndment
            // of the LinkInfo exchange; a record that comes to the wrong gate
            // is a conflicting sequence, and the relation of that peer
            // perisheth by the hand that ruleth its side of the link.
            recordRejection(conn.peerId, "hs.read.responder", "unexpected direction")
            if (conn.localRole == BleRole.INITIATOR) {
                closeInitiatorRelation(peerAddress)
            } else {
                closeResponderRelation(peerAddress)
            }
            return
        }
        when (record.recordType) {
            BleRecordType.HS1 -> {
                if (conn.state != BleConnectionState.ROLE_BOUND) {
                    // exactly the expected first is accepted: a message twice
                    // told in hand, or one that comes after the trust, is a
                    // conflicting sequence - the relation closes, it drifts not
                    recordRejection(conn.peerId, "hs.read.responder",
                                    "hs1 at stage " + conn.state.name)
                    closeResponderRelation(peerAddress)
                    return
                }
                val hs2 = registry.responderProcessHs1(conn.peerId, hint, record.payload) ?: run {
                    // trust refused: the counsel is not true; the relation
                    // becometh nothing, and the slot perisheth with it
                    recordRejection(conn.peerId, "hs.read.responder", "hs1 rejected")
                    closeResponderRelation(peerAddress)
                    return
                }
                conn.beginHandshake()
                // T17: the record is written in the handlers own course, as
                // the iOS twin does; the ready marking that follows can then
                // observe a connection whose fragments have really travelled.
                // T22: and the verdict of that writing is hearkened for.
                val verdict = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
                    writeHandshakeRecordViaServer(peerAddress, conn, BleRecordType.HS2, hs2)
                }
                if (verdict !is TransportResult.Admitted) {
                    recordRejection(conn.peerId, "hs.read.responder", "hs2 reservation refused")
                    closeResponderRelation(peerAddress)
                    return
                }
            }
            BleRecordType.HS3 -> {
                if (conn.state != BleConnectionState.HANDSHAKE_IN_PROGRESS) {
                    // the third before the first is out of order; the third
                    // again after the trust is a late counsel: either way
                    // the relation falleth
                    recordRejection(conn.peerId, "hs.read.responder",
                                   "hs3 at stage " + conn.state.name)
                    closeResponderRelation(peerAddress)
                    return
                }
                if (!registry.responderProcessHs3(conn.peerId, record.payload, hint)) {
                    recordRejection(conn.peerId, "hs.read.responder", "hs3 rejected")
                    closeResponderRelation(peerAddress)
                    return
                }
                if (!conn.markTrustedReady()) {
                    // only the trusted third installes a usable session; a
                    // mark that can not be set is a trust failure, and the
                    // relation closes with it
                    recordRejection(conn.peerId, "hs.read.responder",
                                   "trusted ready refused from " + conn.state)
                    closeResponderRelation(peerAddress)
                    return
                }
                handshakeReadyFlow.tryEmit(conn.peerId.copyOf())
            }
            else -> recordRejection(conn.peerId, "hs.read.responder", "unexpected direction")
        }
    }

    private fun handleInitiatorHandshakeRecord(peerAddress: String, conn: BleConnection,
                                                  record: BleReassembledRecord) {
        val registry = sessions ?: run {
            recordRejection(conn.peerId, "hs.read.initiator", "no trusted session registry")
            closeInitiatorRelation(peerAddress)
            return
        }
        if (record.recordType != BleRecordType.HS2) {
            recordRejection(conn.peerId, "hs.read.initiator", "unexpected direction")
            closeInitiatorRelation(peerAddress)
            return
        }
        val advertised = discoveryIndexMetadataHint(peerAddress) ?: run {
            // the full immutable advertised hint is an item of the relation's
            // trust: without it the exchange can not proceed
            recordRejection(conn.peerId, "hs.read.initiator", "no remembered discovery hint")
            closeInitiatorRelation(peerAddress)
            return
        }
        val hs3 = registry.initiatorProcessHs2(conn.peerId, record.payload, advertised) ?: run {
            // trust rejected: HS3 is withheld and the exact relation closes
            recordRejection(conn.peerId, "hs.read.initiator", "hs2 rejected")
            closeInitiatorRelation(peerAddress)
            return
        }
        conn.beginHandshake()
        val verdict = runBlocking(kotlinx.coroutines.Dispatchers.IO) {
            writeHandshakeRecordViaClient(peerAddress, conn, BleRecordType.HS3, hs3)
        }
        if (verdict !is TransportResult.Admitted) {
            // the reservation failed or the queue fell Closed: no HS3 is
            // ordered, no capability is marked, the exact relation closes -
            // the writer named its reason in the collector
            recordRejection(conn.peerId, "hs.read.initiator", "hs3 reservation refused")
            closeInitiatorRelation(peerAddress)
            return
        }
        if (!conn.markTrustedReady()) {
            // the trusted capability could not be marked: a trust failure
            // closes the relation; READY of the controller alone is no
            // publication, and none was made
            recordRejection(conn.peerId, "hs.read.initiator", "trusted ready refused from " + conn.state)
            closeInitiatorRelation(peerAddress)
            return
        }
        handshakeReadyFlow.tryEmit(conn.peerId.copyOf())
    }

    /** T21 (section 13): a refusal at the initiator's record door closes
     *  the exact relation through the platform's own arm - the tokens are
     *  the ones the registration itself carries, never a fresh lookup - and
     *  the direction's writer retires with the relation it served. No HS
     *  is retransmitted within the same session; application retries
     *  survive in storage and travel by a fresh handshake hereafter. */
    /** T21 (section 13): the refusal at the responder's record door closes
     *  the exact relation through the platform's own arm - the generation is
     *  the one the registration carries - and the direction's writer retires
     *  with the relation it served. */
    private fun closeResponderRelation(peerAddress: String) {
        val gen = serverDriver.getClientGeneration(peerAddress) ?: return
        handleServerDisconnected(peerAddress, gen)
        serverWriters.remove(peerAddress)
    }

    /** T21: does the refused fragment name a handshake record? The type
     *  octet rides on every fragment of the header, so the door may judge
     *  the counsel by it alone, ere the reassembler speaks. */
    private fun namesHandshakeRecord(value: ByteArray): Boolean {
        if (value.size < BleRecordConstants.HEADER_BYTES) return false
        return when (value[1]) {
            BleRecordType.HS1.typeCode, BleRecordType.HS2.typeCode,
            BleRecordType.HS3.typeCode -> true
            else -> false
        }
    }

    private fun closeInitiatorRelation(peerAddress: String) {
        val client = activeClientConnections[peerAddress] ?: return
        handleCentralDisconnected(peerAddress, client.clientToken, client.gattGeneration)
        centralWriters.remove(peerAddress)
    }

    private fun discoveryIndexMetadataHint(peerAddress: String): ByteArray? =
        discoveredMetadataForTest(peerAddress)?.nodeHint?.copyOf()

    /** The responder's record writer: handshake fragments travel to the
     *  subscribed peer over the server's notification outlet. */
    private suspend fun writeHandshakeRecordViaServer(address: String, conn: BleConnection,
                                              type: BleRecordType,
                                              payload: ByteArray): TransportResult {
        if (!outlet.isPeerSubscribed(address)) {
            recordRejection(conn.peerId, "hs.write.responder", "no subscription towards the peer")
            return TransportResult.Rejected("no subscription towards the peer")
        }
        val fragments = conn.fragmentOutbound(type, payload)
        if (fragments.isEmpty()) {
            recordRejection(conn.peerId, "hs.write.responder", "the gate refused the record")
            return TransportResult.Rejected("the gate refused the record")
        }
        for (frag in fragments) {
            if (!outlet.notifyPeer(address, frag)) {
                recordRejection(conn.peerId, "hs.write.responder", "queue full")
                return TransportResult.Backpressured
            }
        }
        return TransportResult.Admitted
    }

    /** The initiator's record writer: handshake fragments travel to the
     *  connected peer over the client's write outlet. */
    private suspend fun writeHandshakeRecordViaClient(address: String, conn: BleConnection,
                                              type: BleRecordType,
                                              payload: ByteArray): TransportResult {
        val fragments = conn.fragmentOutbound(type, payload)
        if (fragments.isEmpty()) {
            recordRejection(conn.peerId, "hs.write.initiator", "the gate refused the record")
            return TransportResult.Rejected("the gate refused the record")
        }
        if (!outlet.isClientConnected(address)) {
            recordRejection(conn.peerId, "hs.write.initiator", "no outlet: client absent or disconnected")
            return TransportResult.Rejected("no outlet: client absent or disconnected")
        }
        for (frag in fragments) {
            if (!outlet.writePeer(address, frag)) {
                recordRejection(conn.peerId, "hs.write.initiator", "queue full")
                return TransportResult.Backpressured
            }
        }
        return TransportResult.Admitted
    }

    /** T21: lexicographic order of the canonical node hints, unsigned
     *  octet by octet; the shorter prefix is the lesser. The initiator
     *  speaks only from the ascendant seat (section 13: localHint shall
     *  be less than remoteHint at the begin of the trusted exchange). */
    internal fun hintOrder(local: ByteArray, remote: ByteArray): Int {
        val n = minOf(local.size, remote.size)
        for (i in 0 until n) {
            val a = local[i].toInt() and 0xFF
            val b = remote[i].toInt() and 0xFF
            if (a != b) return a - b
        }
        return local.size - remote.size
    }

    /** The initiator's entrance: begin the trusted handshake with the
     *  remote hint learned from discovery. The first record travels over
     *  the outlet towards the connected peer; the exchange completes when
     *  the notifications bring the responder's answer back.
     *
     *  T21 (section 13): the entrance requires the physical duplex of the
     *  ADR-002 predicate witnessed upon the connection, and the hints in
     *  their ascendant order - local less than remote. No SessionSlot is
     *  created, and no HS1 reserved, before both counsels are kept. */
    suspend fun beginTrustedHandshake(peerId: ByteArray, remoteHint: ByteArray): TransportResult {
        if (!BleConnection.canBindRemoteHint(remoteHint)) {
            recordRejection(peerId, "hs.begin", "malformed remote hint")
            return TransportResult.Rejected("malformed remote hint")
        }
        val registry = sessions ?: run {
            recordRejection(peerId, "hs.begin", "no trusted session registry")
            return TransportResult.Rejected("no trusted session registry")
        }
        val address = resolvePeerAddress(peerId) ?: run {
            recordRejection(peerId, "hs.begin", "malformed peer address")
            return TransportResult.Rejected("malformed peer address")
        }
        val conn = centralDriver.getActiveConnection(address) ?: run {
            recordRejection(peerId, "hs.begin", "no such connection")
            return TransportResult.Rejected("no such connection")
        }
        if (conn.state != BleConnectionState.ROLE_BOUND &&
            conn.state != BleConnectionState.HANDSHAKE_IN_PROGRESS) {
            recordRejection(peerId, "hs.begin", "cannot begin from " + conn.state)
            return TransportResult.Rejected("cannot begin from " + conn.state)
        }
        if (!conn.isHandshakeTransportReady) {
            recordRejection(peerId, "hs.begin", "physical duplex not witnessed")
            return TransportResult.Rejected("physical duplex not witnessed")
        }
        if (hintOrder(identity.nodeHint, remoteHint) >= 0) {
            recordRejection(peerId, "hs.begin", "hint order not ascendant")
            return TransportResult.Rejected("hint order not ascendant")
        }
        val hs1 = registry.beginInitiator(conn.peerId, remoteHint) ?: run {
            recordRejection(peerId, "hs.begin", "begin initiator refused")
            return TransportResult.Rejected("begin initiator refused")
        }
        conn.beginHandshake()
        return writeHandshakeRecordViaClient(address, conn, BleRecordType.HS1, hs1)
    }

    companion object {
        const val REJECTION_RECORD_CAPACITY = 64

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
