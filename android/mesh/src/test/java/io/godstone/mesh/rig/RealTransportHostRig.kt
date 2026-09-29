package io.godstone.mesh.rig

import android.content.Context
import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.DirectDispatchResult
import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DurableAckPump
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.InboxCensus
import io.godstone.mesh.delivery.SqliteAckStore
import io.godstone.mesh.di.MeshModule
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.identity.WipeGatedAckObligationStore
import io.godstone.mesh.identity.WipeSensitiveUseGate
import io.godstone.mesh.store.DeliveryRow
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.store.StoreDb
import io.godstone.mesh.transport.AdvertiseInstruction
import io.godstone.mesh.transport.AdvertisingHooks
import io.godstone.mesh.transport.AdvertisingResult
import io.godstone.mesh.transport.BleAdvertiseSettings
import io.godstone.mesh.transport.BleCentralAction
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.BleLinkInfoCodec
import io.godstone.mesh.transport.BleLinkInfoV1
import io.godstone.mesh.transport.BleOutletHooks
import io.godstone.mesh.transport.BleRole
import io.godstone.mesh.transport.BleRoleElection
import io.godstone.mesh.transport.BleRoleElectionResult
import io.godstone.mesh.transport.BleServerAction
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.PeerId
import io.godstone.mesh.transport.ScanEvent
import io.godstone.mesh.transport.TransportResult
import io.godstone.mesh.transport.WriteCompletion
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.LogicalMessageIdentity
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.runBlocking

/**
 * *** GS-INTEGRATION-001 `real-adapters`, THE ANDROID ISLE: THE REAL-TRANSPORT HOST RIG. ***
 *
 * The iOS twin (`RealTransportHostRig.swift`) is the reference for WHAT this must be: a composition built by the
 * REAL production composition root over temp ON-DISK stores, with ONLY the OS/hardware facade substituted. This is
 * the Android mirror, hung upon the Android OS-facade seam.
 *
 * WHAT IS REAL:
 *   * every node is built by `MeshModule.provideMeshNode` -- THE PRODUCTION PROVIDER -- over a REAL on-disk SQLite
 *     engine (`JdbcStoreDb`, running the SAME `StoreSchema` SQL the SQLCipher production engine runs);
 *   * the transport is the production `BleTransport`, and the trust, ACK and dispatch owners are the module's OWN
 *     providers (`provideSessionManager`, `provideDeliveryTracker`, `provideAckStore`, `provideWipeGatedAckStore`,
 *     `provideAckDriver`, `provideAckPump`, `provideBoundRecipientKeyResolver`);
 *   * every byte that would reach the air re-enters the RECEIVING side's REAL OS facade door
 *     (`handleServerInboundWrite` / `handleCentralInboundNotification`);
 *   * the trusted handshake, the sealed key-confirmation round and the durable persistence all travel the
 *     production code paths.
 *
 * WHAT IS SUBSTITUTED (the OS facade ONLY):
 *   * the advertising/scan/connection manager: a recording, re-delivering fabric ([FabricOutlet], [FabricAdvertiser]);
 *   * the platform keystore: identities minted from key material through the frozen core (`Identity.fromKeyMaterial`);
 *   * the native SQLCipher link: the host JDBC engine, as every host harness on this isle already substitutes it.
 *
 * WHAT THIS RIG NEVER DOES (the assignment's own prohibitions):
 *   * it never constructs a synthetic `PeerEvent.Found` (the production `publishRelation` emits it);
 *   * it never calls `MeshNode.ingestInbound` directly -- frames enter through the transport's own doors;
 *   * it never pre-trusts a remote key by hand (the production handshake authority writes the trust rows);
 *   * it never fabricates a session;
 *   * it never uses `MeshNode.transportSendOverride` to bypass framing.
 */
internal class RealTransportHostRig(
    private val ctx: Context,
    /**
     * THE FIXTURE ROOT. When non-null the estate is CALLER-OWNED and [tearDown] deliberately leaveth it in place --
     * the crash / cross-process fixture's only construction road. When null an anonymous temp root is used and
     * DELETED at [tearDown].
     */
    fixtureRoot: File? = null,
) {
    // ============================================================================================
    // MARK: - the OS facade: the recording, re-delivering fabric
    // ============================================================================================

    /**
     * *** ONE ATTRIBUTED EGRESS RECORD: the destination address, the exact bytes, and the leg. ***
     *
     * *[direction] is [BleDirection.OUTBOUND] when the sender was the INITIATOR (its peripheral
     * `writePeerTyped` leg) and [BleDirection.INBOUND] when it was the RESPONDER (its manager `notifyPeerTyped`
     * leg) -- the two legs a real radio separates, and the two this rig keepeth apart.*
     */
    class Egress(val address: String, val bytes: ByteArray, val direction: BleDirection) {
        override fun equals(other: Any?): Boolean =
            other is Egress && address == other.address && direction == other.direction &&
                bytes.contentEquals(other.bytes)

        override fun hashCode(): Int = (address.hashCode() * 31 + direction.hashCode()) * 31 + bytes.contentHashCode()
    }

    /**
     * *** THE RECORDING OUTLET: THE SEAM THE CORPUS ALREADY USES FOR THE AIR. ***
     *
     * *Every fragment the transport would put on the wire arriveth at [writePeerTyped] (the initiator's peripheral
     * leg) or [notifyPeerTyped] (the responder's manager leg) and is captured VERBATIM.* **A foreign worker may
     * install its own [forward] to carry those exact bytes over IPC instead of (or beside) local re-delivery.**
     */
    class FabricOutlet(
        @Suppress("UNUSED_PARAMETER") label: String = "",
        /**
         * The foreign-consumer seam: (destinationAddress, exactBytes, direction) -> forwarded. Uninterpreted: the
         * rig never decodes what it forwards.
         */
        private val forward: ((address: String, bytes: ByteArray, direction: BleDirection) -> Unit)? = null,
    ) : BleOutletHooks {
        private val lock = Any()
        private val recorded = ArrayList<Egress>()

        /** The address the platform says is connected on the INITIATOR leg, or null. */
        @Volatile var clientConnected: String? = null

        /** The address the platform says is subscribed on the RESPONDER leg, or null. */
        @Volatile var subscribed: String? = null

        /** When set, the named address refuses every write: the window is full. */
        @Volatile var floodingAddress: String? = null

        /** When true the legs report a mid-write failure ([WriteCompletion.Failed]). */
        @Volatile var failing: Boolean = false

        /** The rig's own re-delivery into the peer's REAL ingress door (installed by [makeNode]). */
        @Volatile internal var deliver: ((address: String, bytes: ByteArray, direction: BleDirection) -> Unit)? = null

        override fun isPeerSubscribed(address: String): Boolean = subscribed == address
        override fun isClientConnected(address: String): Boolean = clientConnected == address

        // *** THE BOOLEAN LEGS CARRY THE BYTES TOO, EXACTLY AS THE TYPED ONES DO. ***
        //
        // *THE DEFECT THIS CLOSES, MEASURED: the handshake writers reach the outlet through its BOOLEAN voice --
        // `writeHandshakeRecordViaClient` -> `outlet.writePeer` (HS1/HS3) and `writeHandshakeRecordViaServer` ->
        // `outlet.notifyPeer` (HS2) -- and those two legs RECORDED but neither forwarded nor delivered, while only
        // the typed legs did.* **So a rig link could never complete its sealed handshake: the fragments were
        // recorded as if they had left and were handed to nobody** (the rig's own court timed out at
        // `both registries report the peer ready`, and a cross-process worker emitted no handshake record at all).
        // *Production's own binding answers identically on both voices -- the typed override is the same
        // `sendNotificationTyped`/`sendAttValueTyped` call the Boolean one makes -- so the two legs must carry the
        // same bytes, and no call site uses both for one record.*
        override suspend fun notifyPeer(address: String, value: ByteArray): Boolean {
            record(address, value, BleDirection.INBOUND)
            forward?.invoke(address, value, BleDirection.INBOUND)
            deliver?.invoke(address, value, BleDirection.INBOUND)
            return floodingAddress != address
        }

        override suspend fun writePeer(address: String, value: ByteArray): Boolean {
            record(address, value, BleDirection.OUTBOUND)
            forward?.invoke(address, value, BleDirection.OUTBOUND)
            deliver?.invoke(address, value, BleDirection.OUTBOUND)
            return floodingAddress != address
        }

        override suspend fun notifyPeerTyped(address: String, value: ByteArray): WriteCompletion {
            record(address, value, BleDirection.INBOUND)
            forward?.invoke(address, value, BleDirection.INBOUND)
            deliver?.invoke(address, value, BleDirection.INBOUND)
            return when {
                failing -> WriteCompletion.Failed
                floodingAddress == address -> WriteCompletion.QueueFull
                else -> WriteCompletion.Accepted
            }
        }

        override suspend fun writePeerTyped(address: String, value: ByteArray): WriteCompletion {
            record(address, value, BleDirection.OUTBOUND)
            forward?.invoke(address, value, BleDirection.OUTBOUND)
            deliver?.invoke(address, value, BleDirection.OUTBOUND)
            return when {
                failing -> WriteCompletion.Failed
                floodingAddress == address -> WriteCompletion.QueueFull
                else -> WriteCompletion.Accepted
            }
        }

        private fun record(address: String, value: ByteArray, direction: BleDirection) {
            synchronized(lock) { recorded.add(Egress(address, value.copyOf(), direction)) }
        }

        /** Every recorded egress, in order. */
        fun egress(): List<Egress> = synchronized(lock) { recorded.toList() }

        /** How many fragments have crossed this outlet. */
        fun recordCount(): Int = synchronized(lock) { recorded.size }

        /** The attributed OS egress in bytes -- the acceptance's "nonzero attributed OS egress". */
        fun bytes(): Int = synchronized(lock) { recorded.sumOf { it.bytes.size } }

        fun bytesTo(address: String): Int =
            synchronized(lock) { recorded.filter { it.address == address }.sumOf { it.bytes.size } }

        fun writesTo(address: String): List<ByteArray> = synchronized(lock) {
            recorded.filter { it.address == address && it.direction == BleDirection.OUTBOUND }.map { it.bytes }
        }

        fun notificationsTo(address: String): List<ByteArray> = synchronized(lock) {
            recorded.filter { it.address == address && it.direction == BleDirection.INBOUND }.map { it.bytes }
        }

        /** The mark/bytesSince window a dispatch attribution needeth. */
        fun mark(): Int = synchronized(lock) { recorded.size }

        fun bytesSince(mark: Int, to: String): Int =
            synchronized(lock) { recorded.drop(mark).filter { it.address == to }.sumOf { it.bytes.size } }

        fun clear() = synchronized(lock) { recorded.clear() }

        fun airIsEmpty(): Boolean = synchronized(lock) { recorded.isEmpty() }
    }

    /** The advertising facade: the platform advertiser, substituted and recorded. */
    class FabricAdvertiser : AdvertisingHooks {
        private val lock = Any()
        private val starts = ArrayList<BleAdvertiseSettings>()

        @Volatile private var last: AdvertisingResult? = null

        override val isAvailable: Boolean get() = true

        override fun dispatchStart(
            settings: BleAdvertiseSettings,
            instructions: List<AdvertiseInstruction>,
            callback: (AdvertisingResult) -> Unit,
        ): Boolean {
            synchronized(lock) { starts.add(settings) }
            val result = AdvertisingResult.Success
            last = result
            callback(result)
            return true
        }

        override fun dispatchStop(): Boolean = true

        fun startCount(): Int = synchronized(lock) { starts.size }
        fun lastResult(): AdvertisingResult? = last
    }

    // ============================================================================================
    // MARK: - one node of the rig
    // ============================================================================================

    /** One REAL node: the production provider's node, its own transport, its own on-disk estate. */
    class Node internal constructor(
        val label: String,
        val identity: Identity,
        val node: MeshNode,
        val messageStore: SqliteMessageStore,
        val peerStore: JdbcPeerIdentityStore,
        val outlet: FabricOutlet,
        val advertiser: FabricAdvertiser,
        /** The address this station heareth on the air (a deterministic function of its own node id). */
        val address: String,
        val engine: StoreDb,
        val ackStore: SqliteAckStore,
        val tracker: DeliveryTracker,
        val sessions: SessionManager,
        val gate: DefaultRuntimeLifecycleGate,
        val pump: DurableAckPump,
        /**
         * *** THE NODE'S OWN TRUST REPOSITORY -- the SAME authority the production handshake and the ACK road
         * consult, never a second `PeerIdentityRepository` over the same file.*** *A cross-process worker that
         * learneth a foreign binding over IPC pinneth it through [RealTransportHostRig.pinRemote].*
         */
        val peerRepository: PeerIdentityRepository,
        internal val scope: CoroutineScope,
    ) {
        internal var opened = false

        /** *** THE COMPOSITION'S OWN TRANSPORT OBJECT -- not a rig-built copy. *** */
        val transport: BleTransport get() = node.bleTransportForWipe
    }

    /**
     * One established relation, as BOTH sides name it. **On Android the HANDLE VOCABULARY IS THE PEER ADDRESS**
     * (the connection's own `peerId` is the address text) -- exactly as the platform's own ATT map is keyed.
     */
    class Link(
        val a: String,
        val b: String,
        /** The handle `a` nameth `b` by (the peer ADDRESS). */
        val aHandle: String,
        /** The handle `b` nameth `a` by. */
        val bHandle: String,
        /** Whether `a` opened the exchange (the PRODUCTION hint election's answer). */
        val aOpened: Boolean,
    )

    // ============================================================================================
    // MARK: - state
    // ============================================================================================

    private val root: File = (
        fixtureRoot ?: File.createTempFile("gs_rig_", "").let { it.delete(); it.mkdirs(); it }
        ).also { it.mkdirs() }
    private val ownsEstate: Boolean = fixtureRoot == null
    private val nodes = LinkedHashMap<String, Node>()
    private val links = ArrayList<Link>()
    private val rng = SecureRandom()
    private val egressByLabel = HashMap<String, HashMap<List<Byte>, Int>>()
    private val scopes = ArrayList<CoroutineScope>()

    /**
     * *** THE DELIVERY IS ASYNCHRONOUS, AND THAT IS A CORRECTNESS REQUIREMENT RATHER THAN A CONVENIENCE. ***
     *
     * *MEASURED CONSEQUENCE OF DELIVERING ON THE CALLER'S THREAD (the iOS twin's own record): the two transports'
     * non-reentrant writer pumps NEST -- a hop posted from inside the sender's `nextOut()` loop re-enters the
     * sender's own pump through the receiver's reply -- and the two cross. **A real radio cannot do this: the stack
     * delivereth on its own queues, never on the sender's call stack.** So every crossing is posted to ONE serial
     * delivery thread, and the arms wait on the ESTATE with bounded polling -- exactly how a court must observe an
     * asynchronous radio anyway.*
     */
    private val deliveryQueue: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "gs-rig-radio").also { it.isDaemon = true }
    }

    private var fabricEnabled = false

    /** The deterministic air address for a node id -- the T17 `macOf` formula, exposed for a foreign worker. */
    fun addressOf(nodeId: ByteArray, salt: Int): String {
        val six = ByteArray(6) { i -> if (i < 4) nodeId[i] else (salt + i).toByte() }
        return PeerId.toAddress(six) ?: error("the address could not be formed")
    }

    /** The estate root this rig owneth (or was handed). */
    fun estateRoot(): File = root

    /** The labels of the nodes currently held. */
    fun labels(): Set<String> = nodes.keys.toSet()

    // ============================================================================================
    // MARK: - construction (the production composition root, on disk)
    // ============================================================================================

    /**
     * *** BUILD ONE NODE THROUGH THE PRODUCTION PROVIDER, OVER ON-DISK STORES. ***
     *
     * *`MeshModule.provideMeshNode` IS the composition under test, so NOTHING here hand-builds a `MeshNode`.*
     * **The substituted pieces are exactly the ones the repo's own host harnesses substitute -- the platform
     * keystore and the native SQLCipher link.**
     *
     * @param hooks a foreign outlet to install instead of the rig's own recorder (a worker forwarding over IPC).
     * @param salt the address salt; a negative value deriveth one from the node's own ordinal.
     */
    fun makeNode(label: String, hooks: FabricOutlet? = null, salt: Int = -1): Node {
        require(!nodes.containsKey(label)) { "a node already standeth for $label" }
        val identity = mintIdentity(label)
        val resolvedSalt = if (salt < 0) nodes.size * 0x41 + 0x10 else salt
        val address = addressOf(identity.nodeId, resolvedSalt)

        val engine = JdbcStoreDb(estateFile("messages.db", label))
        val messageStore = SqliteMessageStore(engine, 1L shl 20, null)
        val peerStore = JdbcPeerIdentityStore(estateFile("peers.db", label))
        val repo = PeerIdentityRepository(peerStore)
        val gate = DefaultRuntimeLifecycleGate()
        val wipeGate = WipeSensitiveUseGate { gate.isActive }
        // *** ONE RESOLVER, BOUND BY THE MODULE'S OWN PROVIDER -- never a rival authority. ***
        val resolver = MeshModule.provideBoundRecipientKeyResolver(repo, gate, wipeGate)
        val tracker = MeshModule.provideDeliveryTracker(messageStore, resolver)
        val sessions = MeshModule.provideSessionManager(identity, repo, gate, wipeGate)
        val ackStore = MeshModule.provideAckStore(messageStore)
        val gatedAck: WipeGatedAckObligationStore = MeshModule.provideWipeGatedAckStore(ackStore, wipeGate)
        val authenticator: Ed25519AckAuthenticator = MeshModule.provideEd25519AckAuthenticator(resolver)
        val driver = MeshModule.provideAckDriver(gatedAck, identity, authenticator, resolver)
        val pump = MeshModule.provideAckPump(gatedAck, driver)

        val outlet = hooks ?: FabricOutlet(label)
        val advertiser = FabricAdvertiser()

        val node = MeshModule.provideMeshNode(
            ctx = ctx,
            identity = identity,
            store = messageStore,
            deliveryTracker = tracker,
            sessions = sessions,
            pump = pump,
            sqliteStore = messageStore,
            ackStore = ackStore,
            authenticator = authenticator,
            resolver = resolver,
            wipeGate = wipeGate,
        )
        // *** THE TRANSPORT'S OWN OS SEAMS, THREADED THROUGH THE NODE'S `ble`. ***
        //
        // `MeshNode` builds its transport with NO outlet hooks and with the platform `gattServer.start()`, and this
        // shipping tree FREEZES the readiness flag off (`LINK_LAYER_READY=false`), so a rig could neither capture an
        // ATT byte nor open a radio. These three internal seams are the assignment's OWN named requirement
        // ("constructor-injected `BleOutletHooks.notifyPeerTyped`/`writePeerTyped` and advertising hooks"); they
        // default to null, so PRODUCTION IS BYTE-IDENTICAL.
        node.outletHooksForRig = outlet
        node.advertisingHooksForRig = advertiser
        node.serverStartAttemptForRig = { true }

        // *** THE NODE'S OWN IDENTITY MUST BE PINNED INTO ITS OWN REPOSITORY, or the inbox refuseth the ACK it
        // must issue: `issueOrRestoreAck` requireth `resolver.publicSigningKey(ourNodeId) != null`. Same road as the
        // Swift twin (issue -> frozen validate -> apply).
        pinOwnIdentity(identity, repo)

        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scopes.add(scope)
        val n = Node(
            label = label, identity = identity, node = node, messageStore = messageStore,
            peerStore = peerStore, outlet = outlet, advertiser = advertiser, address = address,
            engine = engine, ackStore = ackStore, tracker = tracker, sessions = sessions,
            gate = gate, pump = pump, peerRepository = repo, scope = scope,
        )
        outlet.deliver = { dest, bytes, direction -> postDelivery(n.address, dest, bytes, direction) }
        nodes[label] = n
        return n
    }

    private fun estateFile(name: String, label: String): File = File(root, "${label}_$name")

    /**
     * *** THE PRODUCTION IDENTITY PROVISIONER: KEY MATERIAL THROUGH THE FROZEN CORE. ***
     *
     * *A caller-owned fixture root persisteth the material, so a later process reacheth the SAME identity* (the
     * estate is the evidence; minting afresh would destroy the very continuity a recovery child existeth to read).
     */
    private fun mintIdentity(label: String): Identity {
        val file = estateFile("identity.bin", label)
        if (!ownsEstate && file.isFile) {
            val raw = file.readBytes()
            if (raw.size == 128) {
                return Identity.fromKeyMaterial(
                    edPub = raw.copyOfRange(0, 32), edPriv = raw.copyOfRange(32, 64),
                    dhPub = raw.copyOfRange(64, 96), dhPriv = raw.copyOfRange(96, 128),
                )
            }
        }
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val identity = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        if (!ownsEstate) {
            file.writeBytes(
                identity.identityPub + identity.identityPriv + identity.staticDhPub + identity.staticDhPriv,
            )
        }
        return identity
    }

    /** Pin a node's own binding into its own repository through the FROZEN validator, as production doth. */
    private fun pinOwnIdentity(identity: Identity, repo: PeerIdentityRepository) = pinBinding(identity, repo)

    /**
     * *** PIN ONE REMOTE IDENTITY INTO A NODE'S OWN TRUST REPOSITORY -- through the SAME frozen validator. ***
     *
     * *A cross-process worker learneth the foreign platform's binding over IPC and must have it resolvable: the ACK
     * road and the recipient inbox verify the signed author through THIS node's repository.* **This pinneth into the
     * repository the node ALREADY carrieth, so no second authority is built over the same file.**
     *
     * *It is a TEST RIG door: in a two-sided `link()` the PRODUCTION handshake authority writeth the trust rows
     * itself, and nothing here is used. It exists only for the one-sided cross-process endpoints.*
     */
    fun pinRemote(label: String, identity: Identity) {
        pinBinding(identity, nodeOf(label).peerRepository)
    }

    private fun pinBinding(identity: Identity, repo: PeerIdentityRepository) {
        val validated = IdentityBindingValidator.validate(
            serialized = identity.issueIdentityBinding().encode(),
            authenticatedRemoteStaticKey = identity.staticDhPub,
            advertisedNodeHint = identity.nodeHint,
        )
        check(validated is IdentityBindingValidationResult.Valid) {
            "the rig could not validate the identity binding: $validated"
        }
        val binding: ValidatedPeerBinding = validated.binding
        val applied = repo.applyValidatedBinding(binding)
        check(applied is PeerTrustApplyResult.FirstSeenPinned || applied is PeerTrustApplyResult.Accepted) {
            "pinning the identity was refused: $applied"
        }
    }

    // ============================================================================================
    // MARK: - opening the radio (through the node, never a bare transport)
    // ============================================================================================

    /**
     * *** OPEN A NODE'S RADIO THROUGH ITS OWN NODE, WHICH INSTALLETH ITS CONSUMERS FIRST. ***
     *
     * *`MeshNode.start()` registereth the authoritative consumers BEFORE the adapters are opened -- the
     * `consume-before-open` law -- but this shipping tree FREEZETH the readiness flag off (`LINK_LAYER_READY=false`),
     * so `start()` returneth false BY CONSTRUCTION. **So the rig driveth the SAME two steps through the node's own
     * single ordering authority, `startInOrder(attach, open)`: nothing here is a parallel road, it is the production
     * sequence with a frozen gate bypassed BY THE RIG rather than by a change to production.***
     */
    fun open(label: String) {
        val n = nodes[label] ?: error("no node $label")
        if (n.opened) return
        n.node.startInOrder(
            { attachConsumers(n) },
            { n.transport.start() },
        )
        n.opened = true
        // *** THE COLLECTORS ARE COLD FLOWS, SO THE RIG WAITETH FOR THEM TO ATTACH BEFORE DRIVING ANY LADDER. ***
        //
        // *`peers()` and `received()` are `callbackFlow`s whose bodies run when collection STARTETH, and the
        // transport's events travel a replay-less `MutableSharedFlow` -- **so an event emitted before the collector
        // attachth is DROPPED, and a rig that drove a ladder immediately could lose the Found that maketh a peer
        // routable (and the sealed key-confirmation echo that maketh a link ready) through a scheduling race rather
        // than a defect.*** **THE SIGNAL IS THE TRANSPORT'S OWN: `peers()` openth a scan context in its body, so a
        // non-null `activeScanContextForTest` proveth the peer collector's body hath begun**, and a short settle
        // letteth the two INNER collector jobs attach. *This is the same bounded scheduling concession the T17/T23
        // fixtures make with their `warmUpStream` sentinel -- not a fabricated readiness.*
        check(waitUntil(200, pollMillis = 2L) { n.transport.activeScanContextForTest() != null }) {
            "the peer collector's body never began for $label"
        }
        Thread.sleep(COLLECTOR_SETTLE_MILLIS)
    }

    /** The node's OWN two collectors (the same ones `attachConsumers` registers), over the live transport. */
    private fun attachConsumers(n: Node) {
        n.transport.peers().onEach { event -> n.node.handlePeerEvent(event) }.launchIn(n.scope)
        n.transport.received().onEach { (peer, clear) ->
            // *** *** THE INGRESS SENDER IS THE AUTHENTICATED NODE ID, NOT THE PLATFORM ADDRESS. *** ***
            //
            // *THE GAP THIS CLOSES, MEASURED BY THE COURT AND BY THE LIVE COORDINATOR: this `Flow` carrieth the
            // connection's own `peerId` (the SEVENTEEN-octet ADDRESS TEXT on this isle), and
            // `MeshNode.handleInboundFrame(fromPeer, ...)` passeth it straight on -- so
            // `RecipientInboxRepository.acceptVerifiedAndRequireAck`'s GATE 0 refuseth it (`receivedFrom.size != 16`)
            // BEFORE ANY COUNTER MOVETH. The row still committeth through the ROUTER, which is why the recipient's
            // durable row was present while `acksIssued` stayed 0 and the sender never reached DELIVERED.* **The
            // identity is ALREADY IN HAND: the sealed handshake bound it to this relation, and
            // `SessionManager.authenticatedNodeIdOf` is the authority iOS production reads at its own ingress**
            // (`BleTransport.swift`'s `ingressSender` fallback, "the node id IS the trusted handshake's own record of
            // who this relation is"). *This is the Android twin of that line, resolved in the rig's consumer where the
            // rig already holds both owners -- no counter is read, no identity is invented, and a relation whose trust
            // was never marked FALLS BACK TO THE ADDRESS, exactly as the iOS fallback doth ("the six-octet relation
            // handle is only the fallback for a relation whose trust was never marked").*
            val from = n.sessions.authenticatedNodeIdOf(peer) ?: peer
            n.node.handleInboundFrame(from, clear)
        }.launchIn(n.scope)
    }

    // ============================================================================================
    // MARK: - the link (the real ladders, in the real order)
    // ============================================================================================

    /**
     * *** THE PRODUCTION ELECTION, NAMED RATHER THAN TRUSTED TO ARGUMENT ORDER. ***
     *
     * *Both handles, and who opened -- the pure shape of a link, WITHOUT driving anything.* **A court that must
     * observe "a NOT-ready link is not reported ready" buildeth one here and asks [isLinkReady].**
     */
    fun electLink(a: String, b: String): Link {
        val first = nodes[a] ?: error("no node $a")
        val second = nodes[b] ?: error("no node $b")
        val aAscendant = when (val election = BleRoleElection.elect(first.identity.nodeHint, second.identity.nodeHint)) {
            is BleRoleElectionResult.Elected -> election.role == BleRole.INITIATOR
            else -> error("the election refused these two hints: $election")
        }
        return Link(
            a = a, b = b,
            // *** EACH SIDE'S HANDLE IS ITS PEER'S ADDRESS -- UNCONDITIONALLY. ***
            //
            // *THE DEFECT THIS CLOSES, MEASURED BY THE COURT THAT TIMED OUT AFTER THE HANDSHAKE BEGAN TO COMPLETE:
            // the old mapping SWAPPED the two handles whenever `a` was not the elected opener, so a link whose
            // initiator was `b` described `b`'s handle as `b`'s OWN address and `isLinkReady` then looked for the
            // opener's own address in the opener's roster of its PEER -- `expectedHex=[…55:56]` against a roster
            // holding `…14:15`, both the same node's salt bytes.* **A handle is the name one side useth for the
            // other, which never dependeth on who opened: `a` nameth `b`'s address and `b` nameth `a`'s.**
            aHandle = second.address,
            bHandle = first.address,
            aOpened = aAscendant,
        )
    }

    /**
     * *** ESTABLISH `a`-`b` OVER THE FABRIC, DRIVEN BY THE OS FACADES ONLY. ***
     *
     * *The role is the PRODUCTION ELECTION'S, never the caller's. Both ladders then run through the transport's own
     * entries, and the trusted handshake -- including the sealed key-confirmation round -- proceedeth AUTOMATICALLY
     * through the started nodes' own consumers.*
     */
    fun link(a: String, b: String): Link {
        val link = electLink(a, b)
        val first = nodes[a]!!
        val second = nodes[b]!!
        val initiator = if (link.aOpened) first else second
        val responder = if (link.aOpened) second else first
        open(a)
        open(b)
        fabricEnabled = true
        bringUpResponderLadder(responder, initiator.address, initiator.identity.nodeHint)
        bringUpInitiatorLadder(initiator, responder.address, responder.identity.nodeHint)
        links.add(link)
        awaitUntil("both registries report the peer ready") {
            val iconn = initiator.transport.centralDriver.getActiveConnection(responder.address)
            val rconn = responder.transport.serverDriver.getInboundConnection(initiator.address)
            iconn != null && rconn != null &&
                initiator.sessions.isReady(iconn.peerId) && responder.sessions.isReady(rconn.peerId)
        }
        return link
    }

    /**
     * *** THE RESPONDER'S LADDER, ONE-SIDED: it needeth only the REMOTE address and hint, never a local Node. ***
     *
     * *A cross-process worker driveth this side alone; the initiator liveth in another process.*
     */
    fun seatResponder(label: String, remoteAddress: String, remoteHint: ByteArray) {
        val responder = nodes[label] ?: error("no node $label")
        open(label)
        bringUpResponderLadder(responder, remoteAddress, remoteHint)
    }

    /** The responder's ladder, through its own driver entries. */
    private fun bringUpResponderLadder(responder: Node, initiatorAddress: String, initiatorHint: ByteArray) {
        val srv = responder.transport.serverDriver
        val admitted = srv.onClientConnected(initiatorAddress, 1L)
        check(admitted is BleServerAction.AdmitConnection) { "the client connection was not admitted: $admitted" }
        responder.transport.handleInboundClientAdmitted(initiatorAddress, 1L)
        // *THE SUBSCRIPTION SEATS BEFORE THE LINK-INFO WRITE, AS PRODUCTION'S PLATFORM SEQUENCE DOTH* -- so the
        // responder's `isHandshakeTransportReady` is already TRUE at the link-info write and it publishes Found.
        responder.outlet.subscribed = initiatorAddress
        val descriptor = srv.onDescriptorWriteRequest(initiatorAddress, true)
        check(descriptor is BleServerAction.AcceptDescriptorWrite ||
            descriptor is BleServerAction.AcceptDescriptorWriteAndPublishFound) { "the subscription was refused: $descriptor" }
        val linkInfo = srv.onLinkInfoWriteRequest(initiatorAddress, linkInfoOf(initiatorHint))
        check(linkInfo is BleServerAction.AcceptWrite ||
            linkInfo is BleServerAction.AcceptWriteAndPublishFound) { "the link-info record was refused: $linkInfo" }
        srv.onMtuChanged(initiatorAddress, MTU)
        val conn = responder.transport.serverDriver.getInboundConnection(initiatorAddress)
            ?: error("the responder has no connection")
        check(conn.isHandshakeTransportReady) { "the responder's duplex is not up: state=${conn.state}" }
    }

    /**
     * *** THE INITIATOR'S LADDER, ONE-SIDED: it needeth only the REMOTE address and hint. ***
     *
     * *This is the entry a cross-process worker driveth when IT is the initiator; the real trusted handshake then
     * proceedeth automatically through the node's own consumers as the remote side's records arrive at this node's
     * ingress door (`handleCentralInboundNotification`).*
     */
    fun seatInitiator(label: String, remoteAddress: String, remoteHint: ByteArray) {
        val initiator = nodes[label] ?: error("no node $label")
        open(label)
        bringUpInitiatorLadder(initiator, remoteAddress, remoteHint)
    }

    /** The initiator's ladder, through its own driver entries (the T17/T23 idiom). */
    private fun bringUpInitiatorLadder(initiator: Node, remoteAddress: String, remoteHint: ByteArray) {
        val scan = initiator.transport.openScanContextForTest()
        check(initiator.transport.handleScanEvent(
            ScanEvent(scan, 1, remoteAddress, -55,
                BleLinkInfoV1(nodeHint = remoteHint, shortDigest = ByteArray(6))),
        )) { "the scan admission was refused" }
        val driver = initiator.transport.centralDriver
        driver.onGattConnected(remoteAddress, 1L, 1L)
        driver.onServicesDiscovered(remoteAddress, true, 1L, 1L)
        driver.onLinkInfoReadResult(remoteAddress, linkInfoOf(remoteHint), 1L, 1L)
        driver.onLinkInfoWriteAcknowledged(remoteAddress, true, remoteHint, 1L, 1L)
        // *THE OUTLET IS WIRED BEFORE THE PUBLICATION, AS PRODUCTION'S IS*: the CCCD ack's PublishFound dispatch
        // is where the transport's OWN door (`maybeBeginTrustedHandshake`) launches the begin coroutine, which
        // READETH this state.
        initiator.outlet.clientConnected = remoteAddress
        val cccdAck = driver.onCccdWriteAcknowledged(remoteAddress, true, 1L, 1L)
        if (cccdAck is BleCentralAction.PublishFound) {
            initiator.transport.dispatchCentralActionForTest(remoteAddress, cccdAck)
        }
        driver.onMtuChanged(remoteAddress, MTU)
        val conn = initiator.transport.centralDriver.getActiveConnection(remoteAddress)
            ?: error("the initiator has no connection")
        check(conn.localRole == BleRole.INITIATOR) { "the election made the initiator, was ${conn.localRole}" }
        check(conn.isHandshakeTransportReady) { "the initiator's duplex is not up: state=${conn.state}" }
    }

    // ============================================================================================
    // MARK: - readiness (the exact-handle contract, mirroring the Swift helper)
    // ============================================================================================

    /**
     * *** IS `link` READY ON THE SIDE PRODUCTION COULD EVER DELIVER TO -- THE OPENER'S, BY ITS EXACT HANDLE? ***
     *
     * *The contract mirrorreth the Swift twin's: a link is ready when BOTH of the opener's own views carry the
     * relation's EXACT handle -- the transport's APPLICATION LinkReady roster ([BleTransport.linkReadyPeersForTest],
     * published ONLY upon the sealed key-confirmation round) **and** the node's route-eligible view
     * ([MeshNode.knownPeersForTest]).* **The second is required because the publication registreth its own roster
     * before notifying the node, so a roster-only check could pass an instant before the peer became routable.**
     *
     * *** ANDROID'S TWO VIEWS SPEAK TWO REPRESENTATIONS, AND THE HELPER ACCEPTS EITHER FOR EACH.** *The transport's
     * roster carrieth the connection's own `peerId` (the 17-octet ADDRESS TEXT -- the same name the platform's ATT
     * map useth); the node's peer view carrieth the SIX-octet MAC identity `publishRelation` emitted.* **Requiring
     * the exact link's handle in BOTH is the law; the encoding is a translation, named here rather than hidden.**
     *
     * *Only the OPENER can be asked: production publisheth Application LinkReady solely inside the key-confirmation
     * RESPONSE branch, so the responder's roster legitimately stayeth empty. Unknown link or node -> false, never a
     * guess.*
     */
    fun isLinkReady(link: Link): Boolean {
        val openerLabel = if (link.aOpened) link.a else link.b
        val handle = if (link.aOpened) link.aHandle else link.bHandle
        val opener = nodes[openerLabel] ?: return false
        val addressBytes = handle.toByteArray()
        val macBytes = PeerId.fromAddress(handle)
        val rosterHit = opener.transport.linkReadyPeersForTest().any { peer ->
            peer.contentEquals(addressBytes) || (macBytes != null && peer.contentEquals(macBytes))
        }
        val viewHit = opener.node.knownPeersForTest().let { known ->
            known.contains(hex(addressBytes)) || (macBytes != null && known.contains(hex(macBytes)))
        }
        return rosterHit && viewHit
    }

    /** The failure detail an arm printeth -- the opener, its handle, both observations and the ring. */
    fun linkReadinessDetail(link: Link): String {
        val openerLabel = if (link.aOpened) link.a else link.b
        val handle = if (link.aOpened) link.aHandle else link.bHandle
        val opener = nodes[openerLabel] ?: return "no node $openerLabel"
        val macBytes = PeerId.fromAddress(handle)
        val hexes = buildList {
            add(hex(handle.toByteArray()))
            if (macBytes != null) add(hex(macBytes))
        }
        return "opener=$openerLabel handle=$handle " +
            "transportRoster=${opener.transport.linkReadyPeersForTest().map { hex(it) }} " +
            "routeEligible=${opener.node.knownPeersForTest()} expectedHex=$hexes " +
            "ring=${ring(openerLabel)}"
    }

    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    // ============================================================================================
    // MARK: - authoring and dispatch
    // ============================================================================================

    /**
     * *** AUTHOR ONE SEALED DIRECT FRAME AS `authorLabel`, FOR `recipientLabel`. ***
     *
     * *The sealed inner payload is the frozen `SignedMessageV1` container (the same road `LabRuntime` and
     * `SendDirectAuthority` travel): `SignedMessageV1.author` over the author's own key material, then
     * `Router.buildSealedMessage` under the RECIPIENT's static DH key, with ONE [LogicalMessageIdentity] whose
     * `createdAt` IS the container's (the two fields stand and fall together, by the frozen verifier's own law).*
     * **Nothing here dispatcheth, offereth or writeth -- so a scenario may present a frame to a door without first
     * running a radio.**
     */
    fun authorDirectFrame(authorLabel: String, recipientLabel: String, plaintext: ByteArray): FrameV2 {
        val a = nodes[authorLabel] ?: error("no node $authorLabel")
        val b = nodes[recipientLabel] ?: error("no node $recipientLabel")
        val nonce = ByteArray(16).also { rng.nextBytes(it) }
        val createdAt = System.currentTimeMillis() / 1000L
        val container = SignedMessageV1.author(
            senderIdentityPriv = a.identity.identityPriv,
            senderIdentityPub = a.identity.identityPub,
            senderNodeId = a.identity.nodeId,
            recipientNodeId = b.identity.nodeId,
            messageNonce = nonce,
            createdAtEpochSeconds = createdAt,
            priority = Priority.DIRECT,
            timeQuality = TimeQuality.USER_CONFIRMED,
            bodyUtf8 = plaintext,
        )
        return runBlocking {
            a.node.router.buildSealedMessage(
                plaintext = container,
                recipientNodeId = b.identity.nodeId,
                recipientStaticPub = b.identity.staticDhPub,
                identity = LogicalMessageIdentity.of(createdAt, nonce),
                priority = Priority.DIRECT,
            )
        }
    }

    /**
     * *** AUTHOR AND DISPATCH ONE DIRECT MESSAGE OVER THE REAL TRANSPORT, RECORDING THE SEND WINDOW. ***
     *
     * *The dispatch road is the node's own `dispatchDirect`, whose `send` closure is the PRODUCTION
     * `BleTransport.send` -- so the bytes leave through the transport's own reservation, seal, fragmenter and
     * writer, and cross the fabric's recording outlet.*
     *
     * **THE EGRESS WINDOW**: the outlet's counter is marked before and read after the dispatch, and the delta is
     * filed under the frame's msgId -- because the ciphertext carrieth no sixteen-octet id, a decode cannot
     * attribute it; the window can, and an arm that also proveth the RECIPIENT holdeth that exact msgId cannot be
     * satisfied by a silent no-op.
     */
    fun sendDirect(from: String, to: String, plaintext: ByteArray): Pair<FrameV2, DirectDispatchResult> {
        val a = nodes[from] ?: error("no node $from")
        val frame = authorDirectFrame(from, to, plaintext)
        val target = handleTowards(from, to)
        val mark = a.outlet.mark()
        val result = runBlocking {
            a.node.dispatchDirect(frame, expectedRecipient = nodes[to]!!.identity.nodeId) { peer, bytes ->
                // *** THE PEER HANDLE COMETH IN EITHER REPRESENTATION (the six wire octets, or the seventeen-octet
                // address text a station keepeh) -- exactly as the transport's own resolver accepteth both. The
                // closure therefore normaliseth to the ADDRESS and refuseth every other relation, so a relay is
                // never handed a frame meant for another peer. ***
                val address = PeerId.toAddress(peer) ?: peer.decodeToString()
                if (address != target) return@dispatchDirect false
                a.transport.send(peer, bytes) is TransportResult.Admitted
            }
        }
        egressByLabel.getOrPut(from) { HashMap() }[frame.msgId.toList()] = a.outlet.bytesSince(mark, target)
        return frame to result
    }

    /** The bytes this rig watched `label` write towards [to] for the frame it authored with [msgId]. */
    fun recordedEgressBytes(label: String, msgId: ByteArray): Int = egressByLabel[label]?.get(msgId.toList()) ?: 0

    /** *** THE DISPATCH DIAGNOSTIC AN ARM PRINTETH WHEN A SEND HANDETH NOTHING TO ANY RELAY. *** */
    fun dispatchDetail(from: String): String {
        val n = nodes[from] ?: return "no node $from"
        return "knownPeers=${n.node.knownPeersForTest()} ring=${ring(from)} " +
            "linkReady=${n.transport.linkReadyPeersForTest().map { hex(it) }}"
    }

    /** The peer ADDRESS `a` nameth `b` by -- order-insensitively, because BOTH directions are legitimate. */
    fun handleTowards(a: String, b: String): String {
        val link = links.firstOrNull { (it.a == a && it.b == b) || (it.a == b && it.b == a) }
            ?: error("no link between $a and $b")
        return if (link.a == a) link.aHandle else link.bHandle
    }

    /** Which side opened the exchange (the production hint election). */
    fun openerOf(a: String, b: String): String? =
        links.firstOrNull { (it.a == a && it.b == b) || (it.a == b && it.b == a) }
            ?.let { if (it.aOpened) it.a else it.b }

    // ============================================================================================
    // MARK: - carrying production-issued frames out over the real writer
    // ============================================================================================

    /**
     * *** CARRY ONE ALREADY-ISSUED FRAME OUT OVER THE REAL LINK WRITER. ***
     *
     * *This is the link writer's road (`BleTransport.send`), NOT a pump: it is how the recipient's own canonical
     * ACK leaveth once production hath issued it into the node's outbox.* **An arm that carried an ACK without ever
     * asking for it would be INVENTING the acknowledgement; this verb taketh the byte production actually issued.**
     */
    fun carryToWire(frame: FrameV2, from: String, to: String): TransportResult {
        val a = nodes[from] ?: return TransportResult.Rejected("unknown node")
        val handle = handleTowards(from, to)
        val peerId = PeerId.fromAddress(handle) ?: handle.toByteArray()
        val mark = a.outlet.mark()
        val verdict = runBlocking { a.transport.send(peerId, frame.encode()) }
        egressByLabel.getOrPut(from) { HashMap() }[frame.msgId.toList()] =
            (egressByLabel[from]?.get(frame.msgId.toList()) ?: 0) + a.outlet.bytesSince(mark, handle)
        return verdict
    }

    /** *** ONE CANONICAL ACK, AS PRODUCTION ISSUED IT -- taken from the node's own outbox, never minted. *** */
    fun drainOneAck(label: String): FrameV2? = nodes[label]?.node?.drainAckOutboxForLink(1)?.firstOrNull()

    // ============================================================================================
    // MARK: - the court's observation doors (every one readeth an OWNER, never a court counter)
    // ============================================================================================

    fun nodeOf(label: String): Node = nodes[label] ?: error("no node $label")

    /** The exact durable held rows this node carrieth (the real on-disk store). */
    fun heldMsgIds(label: String): List<ByteArray> = runBlocking { nodeOf(label).messageStore.allHeldMsgIds() }

    fun holdsMsg(label: String, msgId: ByteArray): Boolean = heldMsgIds(label).any { it.contentEquals(msgId) }

    /** This node's inbox census, read from its OWN owner. */
    fun inboxCensus(label: String): InboxCensus? = nodes[label]?.node?.recipientInbox?.census()

    /** The depth of the node's canonical recipient-ACK outbox. */
    fun ackOutboxDepth(label: String): Int = nodes[label]?.node?.ackOutboxDepthForTest() ?: -1

    /** The durable delivery row for [msgId] at [label], or null -- read from the ENGINE, the durable authority. */
    fun deliveryRow(label: String, msgId: ByteArray): DeliveryRow? = nodes[label]?.engine?.readDelivery(msgId)

    /** The durable delivery state for [msgId] at [label], or null. */
    fun deliveryState(label: String, msgId: ByteArray): DeliveryState? =
        deliveryRow(label, msgId)?.let { DeliveryState.fromCode(it.state) }

    /** The tracker's own view (the owner's lookup), for a court comparing the two. */
    fun trackerLookup(label: String, msgId: ByteArray): DeliveryLookup? = nodes[label]?.tracker?.lookup(msgId)

    /** The transport's own bounded rejection ring, rendered. */
    fun ring(label: String): String =
        nodes[label]?.transport?.rejectionRecordsForTest()
            ?.joinToString("; ") { it.site + "|" + it.reason } ?: "no node"

    /** Bounded wait (small poll) for a predicate over the real estate -- the Swift twin's `waitUntil` shape. */
    fun waitUntil(limit: Int = 400, pollMillis: Long = 5L, predicate: () -> Boolean): Boolean {
        for (i in 0 until limit) {
            if (predicate()) return true
            Thread.sleep(pollMillis)
        }
        return predicate()
    }

    fun awaitUntil(what: String, limit: Int = 400, predicate: () -> Boolean) {
        check(waitUntil(limit, predicate = predicate)) { "timed out: $what" }
    }

    // ============================================================================================
    // MARK: - the fabric's own crossing
    // ============================================================================================

    /**
     * *** THE CROSSING: EVERY RECORDED EGRESS ENTERETH THE RECEIVING SIDE'S REAL OS DOOR. ***
     *
     * *The initiator's write (OUTBOUND) arriveth at the RESPONDER's `handleServerInboundWrite`; the responder's
     * notification (INBOUND) arriveth at the INITIATOR's `handleCentralInboundNotification` -- each side useth its
     * OWN ingress, and the sender's own address is the hop token it heareth.* **Nothing here decodeth, re-frameth or
     * manufactureth a record.**
     */
    private fun postDelivery(senderAddress: String, destAddress: String, bytes: ByteArray, direction: BleDirection) {
        if (!fabricEnabled) return
        val copy = bytes.copyOf()
        deliveryQueue.execute {
            val receiver = nodes.values.firstOrNull { it.address == destAddress } ?: return@execute
            runCatching {
                when (direction) {
                    BleDirection.OUTBOUND -> receiver.transport.handleServerInboundWrite(senderAddress, copy)
                    BleDirection.INBOUND -> receiver.transport.handleCentralInboundNotification(senderAddress, copy)
                }
            }
        }
    }

    /** Drain the delivery queue with every producer already unhooked (the rig's own barrier). */
    private fun drainDeliveries() {
        runCatching { deliveryQueue.submit { }.get(10, TimeUnit.SECONDS) }
    }

    // ============================================================================================
    // MARK: - teardown (stop, quiesce, close, delete -- the iOS order)
    // ============================================================================================

    /**
     * *** TEAR DOWN IN THE iOS ORDER: STOP THE NODES, UNHOOK AND DRAIN, CLOSE THE STORES, DELETE THE ESTATE. ***
     *
     * *The full simulator lane must not carry a `database is unlinked while open` diagnostic, so the stores are
     * closed EXPLICITLY while their owners stand, and only THEN are the files removed.* **A caller-owned fixture
     * root is deliberately LEFT IN PLACE** -- deleting it would destroy exactly the durable evidence a recovery
     * process existeth to read.
     */
    fun tearDown() {
        // (1) STOP THE PRODUCERS: the fabric is unhooked FIRST, so no new hop can be posted.
        fabricEnabled = false
        for (n in nodes.values) {
            n.outlet.deliver = null
            if (n.opened) runCatching { n.transport.stop() }
            runCatching { n.node.stop() }
            n.opened = false
        }
        // (2) DRAIN WHAT IS ALREADY IN FLIGHT, with every producer stopped.
        drainDeliveries()
        for (scope in scopes) runCatching { scope.coroutineContext.cancelChildren() }
        // (3) CLOSE THE STORES AND THE FILES' OWNERS -- EXPLICITLY, WHILE THE OWNERS STAND.
        for (n in nodes.values) {
            runCatching { n.messageStore.close() }
            runCatching { n.peerStore.close() }
        }
        // (4) NOW THE ESTATE MAY GO -- unless a caller owneth it.
        if (ownsEstate) root.deleteRecursively()
        nodes.clear()
        links.clear()
        egressByLabel.clear()
        scopes.clear()
        runCatching { deliveryQueue.shutdownNow() }
    }

    private companion object {
        const val MTU = 247

        /**
         * How long the rig waiteth for the two INNER collector jobs of the cold `peers()`/`received()` flows to
         * attach before it driveth a ladder -- see [open]. Deterministic and small; not a fabricated readiness.
         */
        const val COLLECTOR_SETTLE_MILLIS = 50L

        fun linkInfoOf(nodeHint: ByteArray): ByteArray = BleLinkInfoCodec.encode(
            flags = 0.toByte(),
            nodeHint = nodeHint,
            shortDigest = ByteArray(6) { (it % 251).toByte() },
            queueDepth = 0,
        )
    }
}
