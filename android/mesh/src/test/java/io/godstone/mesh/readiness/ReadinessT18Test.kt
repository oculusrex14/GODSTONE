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
import io.godstone.mesh.transport.AdmissionError
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.RecordWriter
import io.godstone.mesh.transport.RelationKey
import io.godstone.mesh.transport.ReservationAnswer
import io.godstone.mesh.transport.SealAnswer
import io.godstone.mesh.transport.WriteCompletion
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
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
 * T18: the whole-record writer of the outbound path - Android half.
 *
 * Every check that can refuse a whole record refuses it at the
 * reservation, before the seal burns a nonce or the connection
 * consumes a sequence number. The seal happens exactly once, the
 * fragmentation exactly once, the staging at most sixteen values,
 * the flight at most one value, the admitted records at most four.
 * The pump advances only on real completions; a queue-full refusal
 * re-hands the very same fragment; a mid-write failure closes the
 * relation and leaves the durable store untouched.
 */
class ReadinessT18Test {

    // MARK: - the rig, harvested from the T17 witness and parameterised

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
        /** T18: when set, the scripts speak for the legs; the call index
         * lets a case refuse the queue on cue or fail one write midway. */
        var writeScript: ((address: String, value: ByteArray, index: Int) -> WriteCompletion)? = null
        var notifyScript: ((address: String, value: ByteArray, index: Int) -> WriteCompletion)? = null
        private var writeCalls: Int = 0
        private var notifyCalls: Int = 0
        override suspend fun writePeerTyped(address: String, value: ByteArray): WriteCompletion {
            val index = writeCalls++
            written.add(address to value.copyOf())
            val script = writeScript
            if (script != null) return script(address, value, index)
            return if (floodingAddress != address) WriteCompletion.Accepted else WriteCompletion.QueueFull
        }
        override suspend fun notifyPeerTyped(address: String, value: ByteArray): WriteCompletion {
            val index = notifyCalls++
            notified.add(address to value.copyOf())
            val script = notifyScript
            if (script != null) return script(address, value, index)
            return if (floodingAddress != address) WriteCompletion.Accepted else WriteCompletion.QueueFull
        }
        fun writeCount(): Int = writeCalls
        fun notifyCount(): Int = notifyCalls

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
        var mtu: Int = 247,
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
            driver.onMtuChanged(bobAddress, mtu)
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
            conn.maxAttValueLength = mtu
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

    private fun msgIdOf(seed: Byte): ByteArray = ByteArray(16) { (it + seed).toByte() }

    private fun durableFrame(seed: Byte): FrameV2 = FrameV2(
        type = TypeV2.MESSAGE,
        msgId = msgIdOf(seed),
        routingTag = ByteArray(4) { it.toByte() },
        ttl = 12,
        hopCount = 0,
        flags = Priority.toFlags(Priority.BULK),
        payload = ByteArray(64) { seed },
    )

    // MARK: - the required cases of the whole-record law

    /** Required case: the full digest at the agreed attribute space of
     * twenty: fifty six sealed octets travel in five values of no more
     * than twenty octets each, and the peer reassembles the digest whole. */
    @Test
    fun testAttestTwentyTwentyCarriesTheFullDigest() {
        val rig = rig()
        try {
            rig.mtu = 20
            rig.completeTrust()
            val maxAtt = rig.initiatorConnection().maxAttValueLength
            val capacity = maxAtt - 8   // the eight octet header of the record
            val digest = ByteArray(32) { (it + 7).toByte() }
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), digest) }
            assertEquals("the full digest must travel; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, verdict)
            val fragments = rig.aliceOutlet.writesTo(rig.bobAddress)
            assertEquals("the sealed fifty six octets in values of " + capacity + " octets",
                         (56 + capacity - 1) / capacity, fragments.size)
            assertTrue("no value outruns the agreed space", fragments.all { it.size <= maxAtt })
            rig.pushToResponder(fragments)
            awaitUntil("the digest reaches the received stream") {
                rig.collected.any { it.second.contentEquals(digest) }
            }
        } finally {
            rig.stop()
        }
    }

    /** Required case: a record of sixty four whole fractions is admitted
     * and delivered; the flight never exceeds one value and the record
     * retires whole. */
    @Test
    fun testSixtyFourWholeFractionsAreAdmitted() {
        val rig = rig()
        try {
            rig.completeTrust()
            val capacity = rig.initiatorConnection().maxAttValueLength - 8
            val clear = ByteArray(capacity * 64 - 24) { ((it * 7 + 13) % 251).toByte() }
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), clear) }
            assertEquals("a full-ceiling record must be admitted; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, verdict)
            val fragments = rig.aliceOutlet.writesTo(rig.bobAddress)
            assertEquals("sixty four fractions travel", 64, fragments.size)
            assertTrue("each value fits the attribute space",
                       fragments.all { it.size <= rig.initiatorConnection().maxAttValueLength })
            val writer = rig.alice.centralWriterForTest(rig.bobAddress)
                ?: error("the writer must stand for the relation")
            assertEquals("the record retires when fully completed", 0, writer.admittedCountForTest())
            assertEquals("the staging is drained", 0, writer.stagedValuesForTest())
            assertTrue("nothing flies uncompleted", writer.inFlightForTest() == null)
            rig.pushToResponder(fragments)
            awaitUntil("the long record reaches the received stream") {
                rig.collected.any { it.second.contentEquals(clear) }
            }
        } finally {
            rig.stop()
        }
    }

    /** Required case: the sixty fifth fraction is refused before the
     * seal: no nonce is burnt, no sequence number consumed, and the ring
     * tells the capacity by name and number. */
    @Test
    fun testTheSixtyFifthFractionIsRefusedBeforeTheSeal() {
        val rig = rig()
        try {
            rig.completeTrust()
            val seals = CopyOnWriteArrayList<String>()
            rig.pair.smA.testOperationHook = { name -> seals.add(name) }
            val seqBefore = rig.initiatorConnection().peekOutboundSequenceForTest()
            val capacity = rig.initiatorConnection().maxAttValueLength - 8
            val clear = ByteArray(capacity * 64 - 24 + 1) { ((it * 7 + 13) % 251).toByte() }
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), clear) }
            assertTrue("the sixty fifth fraction must be refused",
                       verdict is TransportResult.Rejected)
            val why = (verdict as TransportResult.Rejected).reason
            assertTrue("the refusal names the ceiling and the count: " + why,
                       why.contains("in 65 fragments") &&
                       why.contains((capacity * 64 + 1).toString()))
            assertEquals("no seal was asked", 0, seals.count { it == "seal" })
            assertEquals("the sequence number stands where it stood",
                         seqBefore, rig.initiatorConnection().peekOutboundSequenceForTest())
            assertTrue("the ring tells the capacity by name; ring: " + ringDump(rig.alice),
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "send.capacity" && it.reason.contains("in 65 fragments")
                       })
        } finally {
            rig.stop()
        }
    }

    /** Required case: the queue full. A refusal at the outlet re-hands
     * the very same fragment on the next send; the staging keeps what it
     * holds, an overflowing reservation is told, and the next send drains
     * everything in order. */
    @Test
    fun testTheStagingIsFullAndTheSendIsBackpressured() {
        val rig = rig()
        try {
            rig.completeTrust()
            rig.aliceOutlet.writeScript = { _, _, _ -> WriteCompletion.QueueFull }
            val capacity = rig.initiatorConnection().maxAttValueLength - 8
            val first = ByteArray(capacity * 12 - 24) { (it % 251).toByte() }   // twelve values
            val v1 = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), first) }
            assertEquals("the first send is backpressured; ring: " + ringDump(rig.alice),
                         TransportResult.Backpressured, v1)
            val writer = rig.alice.centralWriterForTest(rig.bobAddress)
                ?: error("the writer must stand for the relation")
            assertEquals("the whole record stays staged", 12, writer.stagedValuesForTest())
            assertTrue("the refusal is told at the ring; ring: " + ringDump(rig.alice),
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "send.initiator" && it.reason == "queue full"
                       })
            val second = ByteArray(capacity * 5 - 24) { (it % 251).toByte() }  // five values
            val v2 = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), second) }
            assertEquals("the overflowing reservation is backpressured; ring: " + ringDump(rig.alice),
                         TransportResult.Backpressured, v2)
            assertTrue("the staging tells its fullness; ring: " + ringDump(rig.alice),
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "send.initiator" && it.reason == "the staging is full"
                       })
            rig.aliceOutlet.writeScript = null   // the legs answer freely again
            val third = ByteArray(capacity - 24) { (it % 251).toByte() }   // one value
            val v3 = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), third) }
            assertEquals("the third send drains everything; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, v3)
            // Eighteen values travel; two attempts were refused and stand
            // recorded beside them, their bytes duplicates of the eventual
            // values - the peer's deframer strikes them as one.
            assertEquals("eighteen values and two refused attempts",
                         20, rig.aliceOutlet.writeCount())
            val fragments = rig.aliceOutlet.writesTo(rig.bobAddress)
            assertEquals("twenty entries went forth in order", 20, fragments.size)
            rig.pushToResponder(fragments)
            awaitUntil("all three records reach the received stream") {
                rig.collected.count { it.second.contentEquals(first) } == 1 &&
                rig.collected.count { it.second.contentEquals(second) } == 1 &&
                rig.collected.count { it.second.contentEquals(third) } == 1
            }
        } finally {
            rig.stop()
        }
    }

    /** Required case: completions lost and duplicated change nothing the
     * pump did not already know: one value only ever flies, a duplicate is
     * told as stale, and the pump stands still until the real one comes. */
    @Test
    fun testCallbacksLostAndDuplicatesChangeNothing() {
        val rig = rig()
        try {
            rig.completeTrust()
            val conn = rig.initiatorConnection()
            val writer = RecordWriter(conn, RelationKey(BleDirection.OUTBOUND, rig.bobAddress, 0L))
            val capacity = conn.maxAttValueLength - 8
            val clear = ByteArray(capacity * 2 - 24) { (it % 251).toByte() }   // two values
            val answer = writer.reserve(BleRecordType.DATA, clear.size)
            assertTrue("the reservation must stand", answer is ReservationAnswer.Admitted)
            val reservation = (answer as ReservationAnswer.Admitted).reservation
            val seal = reservation.sealAndQueue(clear) { payload -> rig.pair.smA.seal(conn.peerId, payload) }
            assertTrue("the seal must hold", seal is SealAnswer.Queued)
            val first = writer.nextOut() ?: error("the pump must hand a value")
            assertTrue("the first completion travels", writer.completed(first.operation))
            assertFalse("a duplicate completion changes nothing", writer.completed(first.operation))
            assertEquals("the duplicate is told as stale", 1L, writer.staleCompletionsForTest())
            val second = writer.nextOut() ?: error("the second value must be handed")
            assertTrue("at most one value flies", writer.nextOut() == null)
            // The card's own defect: acknowledging a stale write into the
            // new operation. A token naming the already travelled fragment
            // arrives while the second value stands in flight.
            assertFalse("a stale token naming the travelled fragment is told",
                        writer.completed(first.operation))
            assertEquals("the loss invented nothing", 2L, writer.staleCompletionsForTest())
            assertTrue("the real completion travels at last", writer.completed(second.operation))
            assertTrue("the record retires whole", writer.nextOut() == null)
            assertEquals("nothing remains admitted", 0, writer.admittedCountForTest())
        } finally {
            rig.stop()
        }
    }

    /** Required case: a write that fails midway closes the relation and
     * releases the staging; the durable application data is not the
     * writer's to touch, and a fresh session may store anew. */
    @Test
    fun testFailedMidwayClosesTheRelationAndPreservesTheStore() {
        val rig = rig()
        try {
            rig.completeTrust()
            val durable = durableFrame(3)
            assertEquals("the store must take the frame", PersistResult.HELD_NEW,
                         kotlinx.coroutines.runBlocking { rig.pair.aliceStore.persist(durable, rig.aliceAddress.toByteArray()) })
            rig.aliceOutlet.writeScript = { _, _, index ->
                if (index < 2) WriteCompletion.Accepted else WriteCompletion.Failed
            }
            val clear = ByteArray(1171) { (it % 251).toByte() }   // 1195 sealed: five values
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), clear) }
            assertEquals("a mid-write failure closes the relation", TransportResult.Closed, verdict)
            assertEquals("the connection is closed", BleConnectionState.CLOSED,
                         rig.initiatorConnection().state)
            assertTrue("the writer retired with the relation",
                       rig.alice.centralWriterForTest(rig.bobAddress) == null)
            assertTrue("the ring tells the failure; ring: " + ringDump(rig.alice),
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "send.initiator" &&
                           it.reason == "a write failed midway; the relation is closed"
                       })
            assertEquals("the fallen relation keeps what it held", PersistResult.HELD_DUPLICATE,
                         kotlinx.coroutines.runBlocking { rig.pair.aliceStore.persist(durable, rig.aliceAddress.toByteArray()) })
            assertEquals("a fresh session may store anew", PersistResult.HELD_NEW,
                         kotlinx.coroutines.runBlocking { rig.pair.aliceStore.persist(durableFrame(4), rig.aliceAddress.toByteArray()) })
        } finally {
            rig.stop()
        }
    }

    /** Required case: the seal happens exactly once per record and the
     * nonce is never consumed again: a re-hand after a queue-full refusal
     * carries the very same bytes, and two records tell two nonces. */
    @Test
    fun testTheNonceIsBurnedOnceAndNeverAgain() {
        val rig = rig()
        try {
            rig.completeTrust()
            val seals = CopyOnWriteArrayList<String>()
            rig.pair.smA.testOperationHook = { name -> seals.add(name) }
            rig.aliceOutlet.writeScript = { _, _, index ->
                if (index == 0) WriteCompletion.QueueFull else WriteCompletion.Accepted
            }
            val clear = ByteArray(300) { (it % 251).toByte() }   // 324 sealed: two values
            val v1 = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), clear) }
            assertEquals("the refusal stands back; ring: " + ringDump(rig.alice),
                         TransportResult.Backpressured, v1)
            val handed = rig.aliceOutlet.writesTo(rig.bobAddress)
            assertEquals("one attempt was made", 1, handed.size)
            val attempted = handed[0].copyOf()
            assertEquals("the refusal burnt no nonce", 1, seals.count { it == "seal" })
            rig.aliceOutlet.writeScript = null
            val v2 = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), clear) }
            assertEquals("the resend must go through; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, v2)
            // The resend is a fresh submission: it seals afresh and tells its
            // own nonce. The re-hand of the first record's fragment, on the
            // other hand, carried the very bytes first attempted.
            assertEquals("one seal per submission", 2, seals.count { it == "seal" })
            val other = ByteArray(299) { ((it * 3 + 1) % 251).toByte() }
            assertEquals("the next record goes through", TransportResult.Admitted,
                         kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), other) })
            assertEquals("each submission seals of its own accord", 3, seals.count { it == "seal" })
            val all = rig.aliceOutlet.writesTo(rig.bobAddress)
            // attempt0, its re-hand, the first record's last, then the fresh
            // submission's two.
            // The attempt, its re-hand, the first record's last, then the
            // fresh submission's two and the next record's two.
            assertEquals("one attempt, one re-hand, then two, two and two", 7, all.size)
            assertTrue("the re-handed fragment is the very same", all[0].contentEquals(all[1]))
            val nonceFirstRecord = all[1].copyOfRange(8, 16)   // past the eight octet header
            val nonceSecondRecord = all[3].copyOfRange(8, 16)
            assertTrue("two submissions tell two nonces",
                       !nonceFirstRecord.contentEquals(nonceSecondRecord))
            assertTrue("the next record tells a third",
                       !all[3].copyOfRange(8, 16).contentEquals(all[5].copyOfRange(8, 16)))
        } finally {
            rig.stop()
        }
    }

    /** Negative case: a payload that drifts from its reservation is
     * refused before the seal: the sealer is never spoken to, the sequence
     * number stands, and the refusal is told by name. */
    @Test
    fun testTheWrongSizedPayloadIsRefusedBeforeTheSeal() {
        val conn = BleConnection("AA:BB:CC:DD:EE:FF".toByteArray())
        conn.maxAttValueLength = 247
        val writer = RecordWriter(conn, RelationKey(BleDirection.OUTBOUND, "AA:BB:CC:DD:EE:FF", 0L))
        val answer = writer.reserve(BleRecordType.DATA, 100)
        assertTrue("the reservation must stand", answer is ReservationAnswer.Admitted)
        val reservation = (answer as ReservationAnswer.Admitted).reservation
        var sealerSpoken = 0
        val seal = reservation.sealAndQueue(ByteArray(99)) { _ -> sealerSpoken += 1; null }
        assertTrue("the drifted payload must be refused", seal is SealAnswer.Refused)
        assertEquals("the refusal names the drift", "the payload drifted from the reservation",
                     (seal as SealAnswer.Refused).reason)
        assertEquals("the sealer was never spoken to", 0, sealerSpoken)
        assertEquals("the sequence number stands", 0, conn.peekOutboundSequenceForTest())
        assertTrue("the writer keeps the station reserved", !writer.isClosedForTest())
    }
}
