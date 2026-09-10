package io.godstone.mesh.readiness

import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.NoiseSession
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityStorage
import io.godstone.mesh.identity.LegacyIdentityMaterial
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.transport.BleCentralOrchestrationDriver
import io.godstone.mesh.transport.BleConnection
import io.godstone.mesh.transport.BleConnectionState
import io.godstone.mesh.transport.BleGattServer
import io.godstone.mesh.transport.BleLinkInfoCodec
import io.godstone.mesh.transport.BleLinkInfoV1
import io.godstone.mesh.transport.BleOutletHooks
import io.godstone.mesh.transport.BleRecordFragmenter
import io.godstone.mesh.transport.BleRecordType
import io.godstone.mesh.transport.BleServerAction
import io.godstone.mesh.transport.BleServerOrchestrationDriver
import io.godstone.mesh.transport.BleRole
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.GattClientConnection
import io.godstone.mesh.transport.PeerId
import io.godstone.mesh.transport.ScanEvent
import io.godstone.mesh.transport.TransportResult
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList

/**
 * T17: nothing ships unsealed, nothing lands unauthenticated - Android half.
 *
 * The transport answers its caller by value: admitted, backpressured,
 * rejected with the refused precondition named, or closed. The session
 * registry is a standing dependency consulted before any submit: without
 * it the transport cannot speak at all, and the old fallback that shipped
 * a frame in the clear whenever the registry was absent is gone from the
 * production types. The physical ready state (the duplex is up) and the
 * cryptographic ready state (the peer's slot is open) are distinct: the
 * latter is reached only through the handshake's own entries, and every
 * record refused at a gate is a bounded event on a collector that keeps
 * running - a malformed packet is never an escape through a platform
 * callback.
 *
 * The chain test walks the real ladder: scan admission carrying the
 * peer's advertised hint, the GATT happy path on the initiator side, the
 * client connection, the descriptor subscription and the link-info write
 * request with the role election on the responder side; then the
 * handshake records through the transport's own writers and deframers,
 * until both session registries report the peer ready and one frame
 * round-trips sealed into the received stream. The radio is represented
 * only by [BleOutletHooks], the seam the corpus already uses for the
 * advertising plane, so every octet that would reach the air is captured
 * verbatim.
 */
class ReadinessT17Test {

    // MARK: - fixtures

    private class InMemoryIdentityStorage : IdentityStorage {
        var v1State: ByteArray? = null
        var legacyMaterial: LegacyIdentityMaterial? = null
        var failWrites = false
        override fun readV1State(): ByteArray? = v1State?.copyOf()
        override fun readLegacyMaterial(): LegacyIdentityMaterial? = legacyMaterial
        override fun hasPartialLegacy(): Boolean = false
        override fun writeV1State(state: ByteArray): Boolean {
            if (failWrites) return false
            v1State = state.copyOf()
            return true
        }
        override fun migrateLegacyToV1(v1State: ByteArray): Boolean {
            if (failWrites) return false
            this.v1State = v1State.copyOf()
            this.legacyMaterial = null
            return true
        }
        override fun clear(): Boolean {
            v1State = null; legacyMaterial = null; return true
        }
    }

    /** The recording outlet: the writes of both directions, captured. */
    private class RecordingOutlet : BleOutletHooks {
        private val notified = CopyOnWriteArrayList<Pair<String, ByteArray>>()
        private val written = CopyOnWriteArrayList<Pair<String, ByteArray>>()
        var subscribed: String? = null
        var clientConnected: String? = null
        /** When set, the named address refuses every write: the window is full. */
        var floodingAddress: String? = null

        override fun isPeerSubscribed(address: String): Boolean = subscribed == address
        override suspend fun notifyPeer(address: String, value: ByteArray): Boolean {
            notified.add(address to value.copyOf())
            return floodingAddress != address
        }
        override fun isClientConnected(address: String): Boolean = clientConnected == address
        override suspend fun writePeer(address: String, value: ByteArray): Boolean {
            written.add(address to value.copyOf())
            return floodingAddress != address
        }
        fun clear() { notified.clear(); written.clear() }
        fun writesTo(address: String): List<ByteArray> =
            written.filter { it.first == address }.map { it.second }
        fun notificationsTo(address: String): List<ByteArray> =
            notified.filter { it.first == address }.map { it.second }
        fun airIsEmpty(): Boolean = notified.isEmpty() && written.isEmpty()
    }

    private class FailClosedTrustAuthority : PeerBindingTrustAuthority {
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
            PeerTrustApplyResult.StorageFailure()
    }

    /** One generator, shared by every draw: fresh instances seeded in the
     * same clock tick would otherwise repeat one another's stream. */
    private val identityRng = SecureRandom()

    private fun makeIdentity(): Identity =
        Identity.loadOrCreate(InMemoryIdentityStorage(), identityRng)

    private fun hintAscending(x: ByteArray, y: ByteArray): Boolean {
        for (i in 0 until 4) {
            val a = x[i].toInt() and 0xFF
            val b = y[i].toInt() and 0xFF
            if (a != b) return a < b
        }
        return false
    }

    private class TrustedPair(
        val alice: Identity,
        val bob: Identity,
        val aliceStore: InMemoryMessageStore,
        val bobStore: InMemoryMessageStore,
        val smA: SessionManager,
        val smB: SessionManager,
    )

    /** A standing pair whose hints elect the first as initiator. */
    private fun makeTrustedPair(): TrustedPair {
        val a = makeIdentity()
        var b = makeIdentity()
        var draws = 0
        while (!hintAscending(a.nodeHint, b.nodeHint)) {
            b = makeIdentity()
            draws += 1
            if (draws > 64) fail("no ascending hint pair within 64 draws")
        }
        val accepted = PeerTrustApplyResult.Accepted
        val trustA = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult = accepted
        }
        val trustB = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult = accepted
        }
        return TrustedPair(a, b, InMemoryMessageStore(), InMemoryMessageStore(),
                           SessionManager(a, trustA), SessionManager(b, trustB))
    }

    /** A stable air address for a peer identity: the test stands for the radio. */
    private fun macOf(nodeId: ByteArray, salt: Int): String {
        val six = ByteArray(6) { i -> if (i < 4) nodeId[i] else (salt + i).toByte() }
        return PeerId.toAddress(six) ?: error("the address could not be formed")
    }

    private fun linkInfoOf(peer: Identity): ByteArray =
        BleLinkInfoCodec.encode(
            flags = 0.toByte(),
            nodeHint = peer.nodeHint,
            shortDigest = ByteArray(6) { (it % 251).toByte() },
            queueDepth = 0
        )

    /** A DATA record framed as the platform frames it: one fragment each. */
    private fun frameData(seq: Int, payload: ByteArray): List<ByteArray> =
        BleRecordFragmenter.fragment(BleRecordType.DATA, seq, payload, 247)

    // MARK: - the rig: two transports, one trusted pair, recording outlets

    private inner class Rig(
        val pair: TrustedPair,
        val aliceAddress: String,
        val bobAddress: String,
        val aliceOutlet: RecordingOutlet,
        val bobOutlet: RecordingOutlet,
        val alice: BleTransport,
        val bob: BleTransport,
        val scope: CoroutineScope,
    ) {
        /** What the received stream yielded so far. */
        val collected = CopyOnWriteArrayList<Pair<ByteArray, ByteArray>>()
        /** The handshake-ready announcements of the responder's driver. */
        val handshakeSeen = CopyOnWriteArrayList<ByteArray>()
        private val subscriptions = ArrayList<Job>()

        init {
            subscriptions.add(bob.received()
                .onEach { (peerId, clear) -> collected.add(peerId to clear) }
                .launchIn(scope))
            subscriptions.add(bob.handshakeReady()
                .onEach { peerId -> handshakeSeen.add(peerId) }
                .launchIn(scope))
        }

        /** A's view of the peer: B, the six-byte id the station keeps. */
        fun peerIdTowardsBob(): ByteArray = PeerId.fromAddress(bobAddress) ?: error("no B id")
        /** B's station keys its inbound relation by the address it heard. */
        fun keyAtResponder(): ByteArray = aliceAddress.toByteArray()

        fun initiatorConnection(): BleConnection =
            alice.centralDriver.getActiveConnection(bobAddress) ?: error("the initiator has no connection")
        fun responderConnection(): BleConnection =
            bob.serverDriver.getInboundConnection(aliceAddress) ?: error("the responder has no connection")

        /** The happy path of the initiator, through the transport's own entries. */
        fun bringUpInitiatorLadder() {
            val ctx = alice.openScanContextForTest()
            assertTrue("the scan admission is accepted",
                       alice.handleScanEvent(ScanEvent(ctx, 1, bobAddress, -55,
                                                      BleLinkInfoV1(nodeHint = pair.bob.nodeHint,
                                                                    shortDigest = ByteArray(6)))))
            val driver = alice.centralDriver
            driver.onGattConnected(bobAddress, 1L, 1L)
            driver.onServicesDiscovered(bobAddress, true, 1L, 1L)
            driver.onLinkInfoReadResult(bobAddress, linkInfoOf(pair.bob), 1L, 1L)
            driver.onLinkInfoWriteAcknowledged(bobAddress, true, pair.bob.nodeHint, 1L, 1L)
            driver.onCccdWriteAcknowledged(bobAddress, true, 1L, 1L)
            driver.onMtuChanged(bobAddress, 247)
            aliceOutlet.clientConnected = bobAddress
            val conn = initiatorConnection()
            assertEquals("the initiator stands role bound", BleConnectionState.ROLE_BOUND, conn.state)
            assertEquals("the election made the initiator", BleRole.INITIATOR, conn.localRole)
            assertTrue("the duplex is up", conn.isHandshakeTransportReady)
        }

        /** The happy path of the responder, through the transport's own entries. */
        fun bringUpResponderLadder() {
            val srv = bob.serverDriver
            assertTrue("the client connection is admitted",
                       srv.onClientConnected(aliceAddress, 1L) is BleServerAction.AdmitConnection)
            bob.handleInboundClientAdmitted(aliceAddress, 1L)
            val descriptor = srv.onDescriptorWriteRequest(aliceAddress, true)
            assertTrue("the subscription is accepted",
                       descriptor is BleServerAction.AcceptDescriptorWrite ||
                       descriptor is BleServerAction.AcceptDescriptorWriteAndPublishFound)
            val linkInfo = srv.onLinkInfoWriteRequest(aliceAddress, linkInfoOf(pair.alice))
            assertTrue("the link-info record is accepted",
                       linkInfo is BleServerAction.AcceptWrite ||
                       linkInfo is BleServerAction.AcceptWriteAndPublishFound)
            bobOutlet.subscribed = aliceAddress
            val conn = responderConnection()
            assertEquals("the responder stands role bound", BleConnectionState.ROLE_BOUND, conn.state)
            assertEquals("the election made the responder", BleRole.RESPONDER, conn.localRole)
            // the platform's MTU exchange reaches the connection through the
            // transport's own callback; the test stands for the platform
            conn.maxAttValueLength = 247
            assertTrue("the duplex is up", conn.isHandshakeTransportReady)
        }

        fun pushToResponder(fragments: List<ByteArray>) {
            for (f in fragments) bob.handleServerInboundWrite(aliceAddress, f)
        }
        fun pushToInitiator(fragments: List<ByteArray>) {
            for (f in fragments) alice.handleCentralInboundNotification(bobAddress, f)
        }

        /** The handshake proper, once both ladders stand. */
        fun completeHandshake() {
            val begin = kotlinx.coroutines.runBlocking { alice.beginTrustedHandshake(peerIdTowardsBob(), pair.bob.nodeHint) }
            assertEquals("the begin must stand; the ring says: " + ringDump(alice),
                         TransportResult.Admitted, begin)
            val hs1 = awaitNonEmpty("hs1 at the initiator outlet; ring: " + ringDump(alice)) { aliceOutlet.writesTo(bobAddress) }
            aliceOutlet.clear()
            pushToResponder(hs1)
            val hs2 = awaitNonEmpty("hs2 at the responder outlet; ring: " + ringDump(bob)) { bobOutlet.notificationsTo(aliceAddress) }
            bobOutlet.clear()
            pushToInitiator(hs2)
            val hs3 = awaitNonEmpty("hs3 stall - census: state=" + initiatorConnection().state +
                " ready=" + initiatorConnection().isHandshakeTransportReady +
                " subscribed=" + initiatorConnection().isNotificationSubscribed +
                " mtu=" + initiatorConnection().maxAttValueLength +
                " hintBound=" + (initiatorConnection().remoteNodeHint != null) +
                " role=" + initiatorConnection().localRole +
                " ring: " + ringDump(alice)) { aliceOutlet.writesTo(bobAddress) }
            aliceOutlet.clear()
            pushToResponder(hs3)
            awaitUntil("both registries report the peer ready",
                       { pair.smA.isReady(initiatorConnection().peerId) &&
                         pair.smB.isReady(responderConnection().peerId) })
            awaitUntil("both connections stand in the ready state",
                       { initiatorConnection().state == BleConnectionState.READY &&
                         responderConnection().state == BleConnectionState.READY })
        }

        /** The ladders and the handshake together. */
        fun completeTrust() {
            bringUpInitiatorLadder()
            bringUpResponderLadder()
            completeHandshake()
        }

        fun stop() {
            for (j in subscriptions) j.cancel()
            kotlinx.coroutines.runBlocking { alice.stop() }
            kotlinx.coroutines.runBlocking { bob.stop() }
        }
    }

    private fun rig(): Rig {
        val pair = makeTrustedPair()
        val aliceAddress = macOf(pair.alice.nodeId, 0x10)
        val bobAddress = macOf(pair.bob.nodeId, 0x90)
        assertTrue("the peers hold distinct addresses", aliceAddress != bobAddress)
        val aliceOutlet = RecordingOutlet()
        val bobOutlet = RecordingOutlet()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val alice = BleTransport(
            identity = pair.alice, store = pair.aliceStore,
            sessions = pair.smA, outletHooks = aliceOutlet)
        val bob = BleTransport(
            identity = pair.bob, store = pair.bobStore,
            sessions = pair.smB, outletHooks = bobOutlet)
        kotlinx.coroutines.runBlocking { alice.start() }
        kotlinx.coroutines.runBlocking { bob.start() }
        return Rig(pair, aliceAddress, bobAddress, aliceOutlet, bobOutlet, alice, bob, scope)
    }

    private fun <T> awaitNonEmpty(what: String = "the stream stayed silent",
                                  observe: () -> List<T>): List<T> {
        for (attempt in 0 until 200) {
            val seen = observe()
            if (seen.isNotEmpty()) return seen
            Thread.sleep(10)
        }
        return error(what)
    }

    private fun ringDump(transport: BleTransport): String =
        transport.rejectionRecordsForTest()
            .joinToString(separator = "; ") { it.site + "|" + it.reason }

    private fun awaitUntil(what: String, predicate: () -> Boolean) {
        for (attempt in 0 until 200) {
            if (predicate()) return
            Thread.sleep(10)
        }
        fail(what)
    }

    // MARK: - the four required cases and their companions

    /**
     * Required case: a transport without a trusted registry refuses to
     * ship anything. The registry is consulted before any relation; the
     * answer names the refused precondition, the collector records it,
     * and the air stays empty - the plaintext fallback is gone from the
     * types.
     */
    @Test
    fun testTransportWithoutRegistryRefusesToShipAnything() {
        val pair = makeTrustedPair()
        val outlet = RecordingOutlet()
        val bare = BleTransport(
            identity = pair.alice, store = InMemoryMessageStore(), outletHooks = outlet)
        kotlinx.coroutines.runBlocking { bare.start() }
        try {
            val peer = PeerId.fromAddress(macOf(pair.bob.nodeId, 0x90)) ?: error("no peer id")
            val verdict = kotlinx.coroutines.runBlocking { bare.send(peer, ByteArray(40) { (it % 251).toByte() }) }
            assertTrue("a transport without a registry rejects by value",
                       verdict is TransportResult.Rejected)
            assertEquals("the answer names the refused precondition",
                         "no trusted session registry", (verdict as TransportResult.Rejected).reason)
            assertTrue("the refusal is a bounded event on the collector",
                       bare.rejectionRecordsForTest().any {
                           it.site == "send" && it.reason == "no trusted session registry"
                       })
            assertTrue("the air stayed empty", outlet.airIsEmpty())
        } finally {
            kotlinx.coroutines.runBlocking { bare.stop() }
        }
    }

    /**
     * Required case: a fail-closed registry ships nothing either. With
     * every binding application meeting storage failure the handshake
     * cannot even begin, and a submit over a relation that has not
     * reached the ready state is told by its own reason - never a silent
     * true, never a frame in the clear.
     */
    @Test
    fun testFailClosedRegistryShipsNothingEither() {
        val pair = makeTrustedPair()
        val outlet = RecordingOutlet()
        val closed = SessionManager(pair.alice, FailClosedTrustAuthority())
        val carol = BleTransport(
            identity = pair.alice, store = InMemoryMessageStore(),
            sessions = closed, outletHooks = outlet)
        kotlinx.coroutines.runBlocking { carol.start() }
        try {
            val address = macOf(pair.bob.nodeId, 0x90)
            val peer = PeerId.fromAddress(address) ?: error("no peer id")
            val driver = carol.centralDriver
            driver.onScanResult(address, -55, pair.bob.nodeHint)
            driver.onGattConnected(address, 1L, 1L)
            driver.onServicesDiscovered(address, true, 1L, 1L)
            driver.onLinkInfoReadResult(address, linkInfoOf(pair.bob), 1L, 1L)
            driver.onLinkInfoWriteAcknowledged(address, true, pair.bob.nodeHint, 1L, 1L)
            driver.onCccdWriteAcknowledged(address, true, 1L, 1L)
            driver.onMtuChanged(address, 247)
            outlet.clientConnected = address

            val begin = kotlinx.coroutines.runBlocking { carol.beginTrustedHandshake(peer, pair.bob.nodeHint) }
            assertEquals("the handshake may proceed; it is the data plane the fail-closed registry fences",
                         TransportResult.Admitted, begin)
            assertTrue("the first record travelled as handshake bytes",
                       outlet.writesTo(address).isNotEmpty())
            val data = ByteArray(30) { (it % 251).toByte() }
            val submit = kotlinx.coroutines.runBlocking { carol.send(peer, data) }
            assertTrue("nothing is sealed over a relation that never reached the ready state",
                       submit is TransportResult.Rejected)
            assertEquals("the standing relation is told apart from the absent one",
                         "connection not ready", (submit as TransportResult.Rejected).reason)
            assertTrue("the refusal reaches the collector; ring: " + ringDump(carol),
                       carol.rejectionRecordsForTest().any {
                           it.site == "send" && it.reason == "connection not ready" })
            val connKey = carol.centralDriver.getActiveConnection(address)
                ?: error("the ladder left no connection")
            assertFalse("no slot opens under a fail-closed authority",
                        closed.isReady(connKey.peerId))
            assertTrue("the air carried the handshake alone, never the data",
                       outlet.writesTo(address).none { it.contentEquals(data) })
        } finally {
            kotlinx.coroutines.runBlocking { carol.stop() }
        }
    }

    /**
     * Companion case: a pretrust data record is rejected and the
     * collector survives. Records that arrive before the trust is made
     * are told by the unexpected stage, each with the record's type
     * named in the reason; the transport is unharmed - once the trust
     * proceeds through the real entries a fresh record is delivered as
     * if nothing had happened.
     */
    @Test
    fun testPretrustDataFrameIsRejectedAndTheCollectorSurvives() {
        val rig = rig()
        try {
            rig.bringUpResponderLadder()
            for (k in 0 until 3) {
                rig.pushToResponder(frameData(k, ByteArray(21 + k) { ((it + k) % 251).toByte() }))
            }
            val events = rig.bob.rejectionRecordsForTest()
            assertEquals("every record refused at the gate is told", 3, events.size)
            assertTrue("the events name the stage that was not reached",
                       events.all { it.site == "ingest.write" && it.reason.contains("unexpected stage") })
            assertTrue("nothing was delivered while the trust was missing", rig.collected.isEmpty())
            // the transport survived: the same station, now trusted, delivers
            rig.bringUpInitiatorLadder()
            rig.completeHandshake()
            val frame = ByteArray(9) { (it * 5 % 251).toByte() }
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), frame) }
            assertEquals("the submit is admitted", TransportResult.Admitted, verdict)
            val fragments = awaitNonEmpty("the data record at the initiator outlet; ring: " + ringDump(rig.alice)) {
                rig.aliceOutlet.writesTo(rig.bobAddress)
            }
            rig.pushToResponder(fragments)
            awaitUntil("the clear arrived at the received stream",
                       { rig.collected.any { it.second.contentEquals(frame) } })
        } finally { rig.stop() }
    }

    /**
     * Required case: authentication failure, then valid input succeeds.
     * A forged frame over a trusted relation opens to nothing and is
     * told as unauthenticated; the collector keeps running; the next
     * record, sealed by the peer's true registry, yields its clear.
     */
    @Test
    fun testAuthenticationFailureThenValidInputSucceeds() {
        val rig = rig()
        try {
            rig.completeTrust()
            // an alien record: bytes that never passed the peer's seal
            rig.pushToResponder(frameData(200, ByteArray(30) { (it * 7 % 251).toByte() }))
            awaitUntil("the forgery is told as unauthenticated",
                       { rig.bob.rejectionRecordsForTest().any {
                             it.site == "receive" && it.reason == "unauthenticated payload" } })
            assertTrue("nothing was delivered for the forgery", rig.collected.isEmpty())
            // the true input over the same station, same collector
            val frame = ByteArray(12) { (it * 3 % 251).toByte() }
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), frame) }
            assertEquals("the submit is admitted", TransportResult.Admitted, verdict)
            val fragments = awaitNonEmpty("the data record at the initiator outlet; ring: " + ringDump(rig.alice)) {
                rig.aliceOutlet.writesTo(rig.bobAddress)
            }
            rig.pushToResponder(fragments)
            awaitUntil("the clear arrived after the failure",
                       { rig.collected.any { it.second.contentEquals(frame) } })
            assertTrue("the collector ran through the failure unbroken",
                       rig.collected.isNotEmpty())
        } finally { rig.stop() }
    }

    /**
     * Companion case: the release symbols carry no test factories. The
     * demotions are told by the mangling the compiler applies to
     * module-internal members; no member whose plain name offers a test
     * seam stands exported from the transport, the connection, the
     * drivers, the gatt peers, the node or the registries.
     */
    @Test
    fun testReleaseSymbolsCarryNoTestFactories() {
        val offenders = ArrayList<String>()
        for (type in listOf(BleTransport::class.java, BleConnection::class.java,
                            SessionManager::class.java, NoiseSession::class.java,
                            BleCentralOrchestrationDriver::class.java,
                            BleServerOrchestrationDriver::class.java,
                            BleGattServer::class.java, GattClientConnection::class.java,
                            MeshNode::class.java)) {
            for (member in type.declaredMethods) {
                val name = member.name
                if ((name.contains("ForTest") || name.contains("ForTesting") ||
                     name.contains("makeDummy") || name.contains("dummy")) &&
                    !name.contains('$')) {
                    offenders.add(type.simpleName + "#" + name)
                }
            }
        }
        assertTrue("exported test seams found: " + offenders, offenders.isEmpty())
    }

    /**
     * Required case (the integration scenario): the whole chain through
     * real entries - the link-info to ROLE_BOUND, the handshake records
     * through the transport's own writers and deframers, the session
     * slots open, the authenticated events arrive. The physical ready
     * state and the cryptographic ready state stay distinct until the
     * driver itself brings the latter, on both sides.
     */
    @Test
    fun testTheWholeChainRunsThroughRealEntries() {
        val rig = rig()
        try {
            rig.bringUpInitiatorLadder()
            rig.bringUpResponderLadder()
            val bobConn = rig.responderConnection()
            assertEquals("role bound is not the trust yet", BleConnectionState.ROLE_BOUND, bobConn.state)
            assertFalse("the duplex being up is not the trust",
                        rig.pair.smB.isReady(rig.responderConnection().peerId))

            val begin = kotlinx.coroutines.runBlocking { rig.alice.beginTrustedHandshake(rig.peerIdTowardsBob(), rig.pair.bob.nodeHint) }
            assertEquals("the begin must stand; the ring says: " + ringDump(rig.alice),
                         TransportResult.Admitted, begin)
            val hs1 = awaitNonEmpty { rig.aliceOutlet.writesTo(rig.bobAddress) }
            assertTrue("the first record left the initiator", hs1.isNotEmpty())
            rig.aliceOutlet.clear()
            rig.pushToResponder(hs1)
            val hs2 = awaitNonEmpty { rig.bobOutlet.notificationsTo(rig.aliceAddress) }
            assertTrue("the responder answered through its own outlet", hs2.isNotEmpty())
            rig.bobOutlet.clear()
            rig.pushToInitiator(hs2)
            val hs3 = awaitNonEmpty { rig.aliceOutlet.writesTo(rig.bobAddress) }
            assertTrue("the initiator completed through its own outlet", hs3.isNotEmpty())
            rig.aliceOutlet.clear()
            rig.pushToResponder(hs3)

            awaitUntil("the registries both report the peer ready",
                       { rig.pair.smA.isReady(rig.initiatorConnection().peerId) &&
                         rig.pair.smB.isReady(rig.responderConnection().peerId) })
            awaitUntil("the responder's connection entered the ready state",
                       { bobConn.state == BleConnectionState.READY })
            awaitUntil("the handshake-ready event was announced",
                       { rig.handshakeSeen.isNotEmpty() })
            assertTrue("the event names the trusted peer",
                       rig.handshakeSeen.any { it.contentEquals(rig.keyAtResponder()) })

            val frame = ByteArray(6) { (it * 11 % 251).toByte() }
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), frame) }
            assertEquals("the frame is admitted for sealing", TransportResult.Admitted, verdict)
            val captures = awaitNonEmpty { rig.aliceOutlet.writesTo(rig.bobAddress) }
            assertTrue("what travelled the air was sealed, not the frame",
                       captures.all { !it.contentEquals(frame) })
            rig.pushToResponder(captures)
            awaitUntil("the clear reached the received stream",
                       { rig.collected.any { it.first.contentEquals(rig.keyAtResponder()) &&
                                             it.second.contentEquals(frame) } })
        } finally { rig.stop() }
    }

    /**
     * Companion case: the sealed ready state requires the trusted
     * handle. The connection's own doors refuse the ready state from
     * every other stage, and preserve the state the connection had.
     */
    @Test
    fun testSealedReadyRequiresTrustedHandle() {
        val conn = BleConnection(peerId = ByteArray(6) { (0x20 + it).toByte() },
                                initialMaxAttValueLength = 247)
        assertEquals("a fresh connection stands provisional",
                     BleConnectionState.PROVISIONAL_CONNECTING, conn.state)
        assertFalse("from the provisional state the handshake door is shut", conn.beginHandshake())
        assertFalse("and the ready door is shut", conn.markTrustedReady())
        assertEquals("the state stands where it stood",
                     BleConnectionState.PROVISIONAL_CONNECTING, conn.state)
        assertTrue(conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED))
        assertTrue(conn.bindResponderFromAcceptedIncomingLinkInfo(byteArrayOf(9, 0, 0, 1)))
        assertEquals(BleConnectionState.ROLE_BOUND, conn.state)
        assertFalse("while the physical gates are closed the handshake door resists",
                    conn.beginHandshake())
        conn.isNotificationSubscribed = true
        assertTrue("with the duplex up the handshake opens through its own door",
                   conn.beginHandshake())
        assertEquals(BleConnectionState.HANDSHAKE_IN_PROGRESS, conn.state)
        assertFalse("the generic entrance stays shut for the reserved states",
                    conn.transitionTo(BleConnectionState.READY))
        assertEquals("the reservation preserves the state",
                     BleConnectionState.HANDSHAKE_IN_PROGRESS, conn.state)
        assertTrue("only from the handshake does the trust admit the ready state",
                   conn.markTrustedReady())
        assertEquals(BleConnectionState.READY, conn.state)
    }

    /**
     * Companion case: to begin the trusted handshake needs a standing
     * relation. Without one the answer names the missing relation, the
     * collector holds the event, and no fragment goes out.
     */
    @Test
    fun testBeginTrustedHandshakeNeedsAStandingRelation() {
        val rig = rig()
        try {
            val verdict = kotlinx.coroutines.runBlocking {
                rig.alice.beginTrustedHandshake(rig.peerIdTowardsBob(), rig.pair.bob.nodeHint)
            }
            assertTrue("without a relation the begin is refused",
                       verdict is TransportResult.Rejected)
            assertEquals("no such connection", (verdict as TransportResult.Rejected).reason)
            assertTrue("the refusal is recorded",
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "hs.begin" && it.reason == "no such connection" })
            assertTrue("no fragment went out", rig.aliceOutlet.airIsEmpty())
            // the hint is validated before the registry is even consulted
            val bad = kotlinx.coroutines.runBlocking {
                rig.alice.beginTrustedHandshake(rig.peerIdTowardsBob(), byteArrayOf(1, 2, 3))
            }
            assertTrue(bad is TransportResult.Rejected)
            assertEquals("malformed remote hint", (bad as TransportResult.Rejected).reason)
        } finally { rig.stop() }
    }

    /**
     * Companion case: backpressure is reported, not silently dropped.
     * When the outlet refuses a fragment the submit answers
     * backpressured with the queue named as full - and the relation
     * survives: when the window opens again the very same submit is
     * admitted.
     */
    @Test
    fun testBackpressureIsReportedNotSilentlyDropped() {
        val rig = rig()
        try {
            rig.completeTrust()
            rig.aliceOutlet.floodingAddress = rig.bobAddress
            val frame = ByteArray(8) { (it * 13 % 251).toByte() }
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), frame) }
            assertEquals("a full window is an answer of its own",
                         TransportResult.Backpressured, verdict)
            assertTrue("the queue full is a bounded event",
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "send.initiator" && it.reason == "queue full" })
            rig.aliceOutlet.floodingAddress = null
            val again = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), frame) }
            assertEquals("with the window open again the submit is admitted",
                         TransportResult.Admitted, again)
        } finally { rig.stop() }
    }

    /**
     * Companion case: the unexpected stage is typed and bounded. Every
     * record refused at a gate names its stage, and the collector has a
     * capacity: past it the eldest records make way and the overflow is
     * counted, so a flood of malformed packets cannot grow any store
     * beyond bound.
     */
    @Test
    fun testUnexpectedStageIsTypedAndBounded() {
        val rig = rig()
        try {
            rig.bringUpResponderLadder()
            rig.bob.clearRejectionRecordsForTest()
            assertEquals("the collector starts clear", 0, rig.bob.rejectionRecordsForTest().size)
            for (k in 1 until 140) {
                rig.pushToResponder(frameData(k, ByteArray(5 + k % 5) { ((it + k) % 251).toByte() }))
            }
            val held = rig.bob.rejectionRecordsForTest()
            assertEquals("the collector keeps its capacity", rig.bob.rejectionRecordCapacity, held.size)
            assertTrue("every record refused at the gate named the stage",
                       held.all { it.site == "ingest.write" && it.reason.contains("unexpected stage") })
            assertEquals("the eldest made way and the overflow is counted",
                         139 - rig.bob.rejectionRecordCapacity, rig.bob.rejectionOverflowCountForTest())
        } finally { rig.stop() }
    }
}
