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
import io.godstone.mesh.transport.AdapterCallbackSource
import io.godstone.mesh.transport.AdapterTraceEvent
import io.godstone.mesh.transport.AssemblyLease
import io.godstone.mesh.transport.BleConnection
import io.godstone.mesh.transport.BleCentralAction
import io.godstone.mesh.transport.BleConnectionState
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.BleGattServer
import io.godstone.mesh.transport.BleLinkInfoCodec
import io.godstone.mesh.transport.BleLinkInfoV1
import io.godstone.mesh.transport.BleOutletHooks
import io.godstone.mesh.transport.BleRecordFragmenter
import io.godstone.mesh.transport.BleRecordCodec
import io.godstone.mesh.transport.BleRecordType
import io.godstone.mesh.transport.BleServerAction
import io.godstone.mesh.transport.BleServerOrchestrationDriver
import io.godstone.mesh.transport.BleRole
import io.godstone.mesh.transport.RelationKey
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.GattClientConnection
import io.godstone.mesh.transport.InvariantLedger
import io.godstone.mesh.transport.PeerId
import io.godstone.mesh.transport.ScanEvent
import io.godstone.mesh.transport.TransportResult
import io.godstone.mesh.transport.AdmissionError
import io.godstone.mesh.transport.RecordWriter
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
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
class ReadinessT20Test {

    /** The instant the lifetime suites stand their clocks at. */
    private var rigNow: Long = 1_700_000_000L

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
        var a = makeIdentity()
        var b = makeIdentity()
        var draws = 0
        while (!hintAscending(a.nodeHint, b.nodeHint)) {
            a = makeIdentity()
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
            val cccdAck = driver.onCccdWriteAcknowledged(bobAddress, true, 1L, 1L)
            if (cccdAck is BleCentralAction.PublishFound) {
                // the platform's boundary posts the found event; the one
                // action dispatcher publishes the relation, as production
                alice.dispatchCentralActionForTest(bobAddress, cccdAck)
            }
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
            warmUpStream()
        }

        /**
         * The shared flow's buffer is finite and tryEmit drops what it
         * cannot hold: a collector launched with the rig has to take its
         * first scheduling hop before it attaches. One sentinel record,
         * awaited on the stream, proves the attachment before any case
         * counts arrivals - the sentinel's text is never mistaken for
         * real traffic because every case marks its clears distinctively.
         */
        fun warmUpStream() {
            val sentinel = ByteArray(1) { 0x5A }
            for (attempt in 0 until 400) {
                val before = collected.size
                val verdict = kotlinx.coroutines.runBlocking {
                    alice.send(peerIdTowardsBob(), sentinel)
                }
                if (verdict == TransportResult.Admitted) {
                    val captured = awaitUntilCount("the sentinel found no outlet") {
                        aliceOutlet.writesTo(bobAddress)
                    }
                    pushToResponder(captured)
                    if (awaitShort { collected.size > before }) {
                        // the sentinel has proved the attachment and is
                        // struck from the record: the cases count only
                        // their own traffic from here on
                        collected.clear()
                        return
                    }
                }
                Thread.sleep(5)
            }
            error("the received() stream never woke for the sentinel")
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
        alice.centralDriver.connectionClockForTest = { rigNow }
        bob.serverDriver.connectionClockForTest = { rigNow }
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

    // MARK: - the trace fixture and the frame maker

    /**
     * The adapter-facing trace fixture. It keeps the ledger of the manager
     * identities the factory injected and delivers trace events through the
     * very production entries the platform"s own callbacks travel. Every
     * argument is one the real callback passes; the fixture invents
     * nothing. An event naming a manager identity that was never injected,
     * or an address other than the one the identity was injected with, is
     * refused at the fixture and makes no delivery at all.
     */
    private class AdapterTraceFixture {
        private val injected = HashMap<Long, String>()
        val deliveries = ArrayList<String>()

        fun inject(managerIdentity: Long, address: String) {
            injected[managerIdentity] = address
        }

        fun canDeliver(source: AdapterCallbackSource): Boolean = when (source) {
            AdapterCallbackSource.ON_CONNECTION_STATE_CHANGE,
            AdapterCallbackSource.ON_SERVICES_DISCOVERED,
            AdapterCallbackSource.ON_MTU_CHANGED,
            AdapterCallbackSource.ON_NOTIFY,
            AdapterCallbackSource.ON_CHARACTERISTIC_WRITE -> true
            else -> false
        }

        /** Delivers one trace; returns how many production entries it reached. */
        fun deliver(trace: AdapterTraceEvent, into: BleTransport): Int {
            val address = injected[trace.managerIdentity] ?: return 0
            if (trace.deviceAddress != null && trace.deviceAddress != address) return 0
            when (trace.source) {
                AdapterCallbackSource.ON_CONNECTION_STATE_CHANGE -> {
                    val token = trace.clientToken ?: return 0
                    val gen = trace.gattGeneration ?: return 0
                    into.handleCentralDisconnected(address, token, gen)
                }
                AdapterCallbackSource.ON_SERVICES_DISCOVERED -> {
                    val ok = trace.propertyValue ?: return 0
                    val token = trace.clientToken ?: return 0
                    val gen = trace.gattGeneration ?: return 0
                    into.centralDriver.onServicesDiscovered(address, ok == 8, token, gen)
                }
                AdapterCallbackSource.ON_MTU_CHANGED -> {
                    val mtu = trace.propertyValue ?: return 0
                    into.centralDriver.onMtuChanged(address, mtu)
                }
                AdapterCallbackSource.ON_NOTIFY -> {
                    val bytes = trace.payload ?: return 0
                    into.handleCentralInboundNotification(address, bytes)
                }
                AdapterCallbackSource.ON_CHARACTERISTIC_WRITE -> {
                    val bytes = trace.payload ?: return 0
                    into.handleServerInboundWrite(address, bytes)
                }
                else -> return 0
            }
            deliveries.add(trace.source.name + "@" + address)
            return 1
        }
    }

    /**
     * Carves a whole record into exactly fragCount fragments the way the
     * frozen reassembler computes them, and encodes every header verbatim.
     * The payload of the record is the deterministic pattern
     * seed + index, so any receiver can re-derive what arrived.
     */
    private fun inboundFrames(totalLen: Int, fragCount: Int, seq: Int, seed: Byte): List<ByteArray> {
        val stride = (totalLen + fragCount - 1) / fragCount
        return (0 until fragCount).map { i ->
            val start = i * stride
            val end = if (start + stride < totalLen) start + stride else totalLen
            val payload = ByteArray(end - start) { j -> (seed + start + j).toByte() }
            val header = BleRecordCodec.encodeHeader(BleRecordType.DATA, seq, i, fragCount, totalLen)
            header + payload
        }
    }

    private fun wholeText(totalLen: Int, seed: Byte): ByteArray =
        ByteArray(totalLen) { j -> (seed + j).toByte() }

    // MARK: - the lifetime schedules

    /**
     * Seals one whole record at the initiator's writer and brings back the
     * fragments as the outlet captured them, together with the sequence the
     * wire carried. The clear follows the deterministic pattern below, so
     * any case can re-derive the text the peer must deliver.
     */
    private fun clearOf(marker: Int, len: Int): ByteArray =
        ByteArray(len) { i ->
            when (i) {
                0 -> (marker and 0xFF).toByte()
                1 -> ((marker shr 8) and 0xFF).toByte()
                else -> ((i * 7 + 13 + marker) % 251).toByte()
            }
        }

    private fun sealFromInitiator(rig: Rig, marker: Int, clearLen: Int): Pair<Int, List<ByteArray>> {
        rig.aliceOutlet.clear()
        val verdict = kotlinx.coroutines.runBlocking {
            rig.alice.send(rig.peerIdTowardsBob(), clearOf(marker, clearLen))
        }
        assertEquals("the writer must admit the whole record; ring: " + ringDump(rig.alice),
                     TransportResult.Admitted, verdict)
        val captured = awaitUntilCount("the fragments of the sealed record did not all arrive") {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        val seq = captured[0][2].toInt() and 0xFF
        return seq to captured.toList()
    }

    private fun awaitShort(limit: Int = 400, predicate: () -> Boolean): Boolean {
        for (attempt in 0 until limit) {
            if (predicate()) return true
            Thread.sleep(5)
        }
        return false
    }

    private fun awaitUntilCount(what: String, observe: () -> List<ByteArray>): List<ByteArray> {
        for (attempt in 0 until 400) {
            val seen = observe()
            if (seen.isNotEmpty()) {
                val n = seen[0][4].toInt() and 0xFF
                if (seen.size == n) return seen
            }
            Thread.sleep(5)
        }
        return error(what)
    }

    @Test
    fun testTheAbsoluteTermExpiresTheDribbledAssemblyThoughTheSlidingWindowIsRefreshed() {
        val rig = rig()
        try {
            rig.completeTrust()
            rigNow = 1_700_000_000L
            val base = rigNow
            val (seq, frags) = sealFromInitiator(rig, 1, 1888)
            assertTrue("the record was cut into enough fractions to outlive its term",
                       frags.size >= 6)
            for (i in 0 until frags.size - 1) {
                rig.pushToResponder(listOf(frags[i]))
                rigNow = base + 4L * i              // every gap sits well under the sliding term
            }
            val conn = rig.responderConnection()
            val first = conn.activeLeaseOf(seq) ?: error("the admission left no lease standing")
            assertEquals("the lease names the sequence it governs", seq, first.seq)
            assertEquals("the term is absolute: thirty seconds from the admission",
                         base + 30L, first.deadlineMono)
            assertTrue("the sliding window is what kept it alive, not the term",
                       rigNow < first.deadlineMono)
            val token = first.admissionId
            // the last fraction arrives at the very instant the term has passed:
            // the sweep every ingress runs strikes first, releases the buffers,
            // and the owner closes the relation through the server's own arm.
            rigNow = base + 35L
            rig.pushToResponder(listOf(frags[frags.size - 1]))
            assertNull("the relation fell when the absolute term passed",
                       rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
            assertEquals("nothing of the dribbled record reached the stream", 0, rig.collected.size)
            // the owner's close purges the connection's registers whole:
            // neither the lapsed assembly nor the fragment the same ingress
            // processed survives it - late fragments can pin no buffer,
            // and the shut door keeps all later traffic out entirely
            assertNull("the close purged the registers whole", conn.activeLeaseOf(seq))
            rig.pushToResponder(listOf(frags[0]))
            assertNull("the shut door admits no later traffic", conn.activeLeaseOf(seq))
            assertEquals("and the stream received nothing more", 0, rig.collected.size)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testFourWholeRecordsArePinnedAndTheFifthIsRefusedItsSlot() {
        val rig = rig()
        try {
            rig.completeTrust()
            rigNow = 1_700_000_000L
            val parts = (1..5).map { sealFromInitiator(rig, it, 600) }
            val conn = rig.responderConnection()
            for ((seq, frags) in parts.take(4)) {
                rig.pushToResponder(listOf(frags.first()))
                assertNotNull("the assembly for the sequence stands on its lease",
                              conn.activeLeaseOf(seq))
            }
            assertEquals("four leases stand pinned", 4, conn.leaseCountForTest())
            val (fifthSeq, fifthFrags) = parts[4]
            rig.pushToResponder(listOf(fifthFrags.first()))
            assertEquals("the fifth concurrent assembly is refused its slot",
                         4, conn.leaseCountForTest())
            assertNull("the refused admission left no lease behind", conn.activeLeaseOf(fifthSeq))
            assertNotNull("the fourth still stands", conn.activeLeaseOf(parts[3].first))
            assertNotNull("the relation did not fall on the refusal",
                          rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
            assertEquals("the refusal is silent on the stream", 0, rig.collected.size)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheSequenceWrapsAtTwoHundredFiftySixWholeRecordsAndTheDuplicateIsRefused() {
        val rig = rig()
        try {
            rig.completeTrust()
            rigNow = 1_700_000_000L
            val observed = ArrayList<Int>()
            val firsts = ArrayList<ByteArray>()
            for (i in 0 until 257) {
                val (seq, frags) = sealFromInitiator(rig, 1000 + i, 1)
                assertEquals("a minimal record travels in one fraction", 1, frags.size)
                rig.pushToResponder(frags)
                observed.add(seq)
                firsts.add(frags[0])
            }
            if (!awaitShort(limit = 800) { rig.collected.size == 257 }) {
                println("WRAP RING DUMP:")
                for (r in rig.bob.rejectionRecordsForTest()) println("  " + r.site + " | " + r.reason)
            }
            assertEquals("two hundred fifty seven whole records arrived across the wrap",
                         257, rig.collected.size)
            for (i in 1 until observed.size) {
                assertEquals("the carried sequence advances by one across the wrap, bit by bit",
                             (observed[i - 1] + 1) % 256, observed[i])
            }
            assertTrue("the wrap itself was witnessed at the crossing of two hundred fifty five",
                       observed.windowed(2).any { (a, b) -> a == 255 && b == 0 })
            // the very first fraction, delivered again: the completed
            // fingerprint refuses the duplicate change
            rig.pushToResponder(listOf(firsts[0]))
            assertEquals("a completed record delivered twice changes nothing",
                         257, rig.collected.size)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheStaleStragglerAtTheWrapFailsClosedAndTheRetransmissionCompletes() {
        val rig = rig()
        try {
            rig.completeTrust()
            rigNow = 1_700_000_000L
            val (seq, frags) = sealFromInitiator(rig, 4242, 600)
            val conn = rig.responderConnection()
            rig.pushToResponder(frags.take(frags.size - 1))
            assertNotNull("the assembly stands mid-way on its lease", conn.activeLeaseOf(seq))
            // a straggler of the elder epoch: same sequence, another shape
            val head = frags[0].copyOfRange(0, 8)
            head[3] = 0.toByte()
            head[4] = (frags.size + 1).toByte()
            head[5] = ((600 + 24 + 101) shr 8).toByte()
            head[6] = ((600 + 24 + 101) and 0xFF).toByte()
            val straggler = head + ByteArray(60) { it.toByte() }
            val ringBefore = rig.bob.rejectionRecordsForTest().size
            rig.pushToResponder(listOf(straggler))
            assertNotNull("the gate refused the stranger; the assembly stands unharmed",
                          conn.activeLeaseOf(seq))
            assertEquals("the refused straggler admitted nothing", 0, rig.collected.size)
            assertTrue("the rejection ring names the stranger at the write door",
                       rig.bob.rejectionRecordsForTest().size > ringBefore)
            // the true fractions, retransmitted in order, complete whole
            rig.pushToResponder(frags)
            if (!awaitShort(limit = 400) { rig.collected.size == 1 }) {
                println("STRAGGLER RING DUMP:")
                for (r in rig.bob.rejectionRecordsForTest()) println("  " + r.site + " | " + r.reason)
            }
            assertEquals("the record arrived whole after the straggler", 1, rig.collected.size)
            assertEquals("and it is the true record",
                         true, rig.collected.last().second.contentEquals(clearOf(4242, 600)))
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheIdempotentDuplicateStandsAndTheConflictingDuplicateFailsClosed() {
        val rig = rig()
        try {
            rig.completeTrust()
            rigNow = 1_700_000_000L
            val (seq, frags) = sealFromInitiator(rig, 77, 600)
            val conn = rig.responderConnection()
            rig.pushToResponder(listOf(frags[0]))
            rig.pushToResponder(listOf(frags[0]))          // the selfsame bytes again
            assertNotNull("the idempotent duplicate left the assembly standing",
                          conn.activeLeaseOf(seq))
            assertEquals("the duplicate admitted nothing new", 0, rig.collected.size)
            val conflicting = frags[0].copyOfRange(0, 8) +
                ByteArray(frags[0].size - 8) { (it + 99).toByte() }
            rig.pushToResponder(listOf(conflicting))        // same index, other bytes
            assertNull("the conflicting duplicate failed closed", conn.activeLeaseOf(seq))
            assertEquals("the conflict admitted nothing", 0, rig.collected.size)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheCrossedTraceFromAForeignManagerIsRefusedAndTheWrongTokenDiscarded() {
        val rig = rig()
        try {
            rig.completeTrust()
            val client = rig.alice.activeClientForTest(rig.bobAddress)
                ?: error("the initiator has no client registration")
            awaitUntil("the relation of the initiator is not published after the ladders") {
                rig.alice.isRelationPublished(BleDirection.OUTBOUND, rig.bobAddress,
                                              client.relationGeneration)
            }
            assertTrue("the relation stands published",
                       rig.alice.isRelationPublished(BleDirection.OUTBOUND, rig.bobAddress,
                                                     client.relationGeneration))
            val stoodBefore = rig.alice.centralDriver.getActiveConnectionCount()
            val fixture = AdapterTraceFixture()
            fixture.inject(1L, rig.bobAddress)               // the identity the factory injected
            val crossed = AdapterTraceEvent(
                source = AdapterCallbackSource.ON_CONNECTION_STATE_CHANGE,
                deviceAddress = rig.bobAddress,
                propertyValue = 0,
                payload = null,
                managerIdentity = 99L,                       // a foreign manager: never injected
                epochAtDelivery = 0L,
                clientToken = client.clientToken,
                gattGeneration = client.gattGeneration,
            )
            assertEquals("a trace from an uninjected manager makes no delivery",
                         0, fixture.deliver(crossed, rig.alice))
            assertEquals("the registry stands where it stood",
                         stoodBefore, rig.alice.centralDriver.getActiveConnectionCount())
            // and the production entry itself discards the misdocumented terminal
            rig.alice.handleCentralDisconnected(rig.bobAddress, client.clientToken + 7L,
                                               client.gattGeneration)
            assertNotNull("a terminal naming the wrong client is discarded",
                          rig.alice.centralDriver.getActiveConnection(rig.bobAddress))
            assertTrue("the publication of the relation stands",
                       rig.alice.isRelationPublished(BleDirection.OUTBOUND, rig.bobAddress,
                                                     client.relationGeneration))
            // the true trace, through the injected identity, reaches its entry
            val trueTrace = AdapterTraceEvent(
                source = AdapterCallbackSource.ON_MTU_CHANGED,
                deviceAddress = rig.bobAddress,
                propertyValue = 247,
                payload = null,
                managerIdentity = 1L,
                epochAtDelivery = 0L,
            )
            assertEquals("the trace of the injected manager reaches the production entry",
                         1, fixture.deliver(trueTrace, rig.alice))
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheMisdatedTerminalFromThePastChangesNothing() {
        val rig = rig()
        try {
            rig.completeTrust()
            val gen = rig.bob.serverDriver.getClientGeneration(rig.aliceAddress)
            // the subscription's found-event belongs to the device gates
            // (T73-T77); the host stands the publication up by hand through
            // the transport's own public door - the T12 precedent - so the
            // misdated terminal has a publication to leave untouched
            rig.bob.publishRelation(RelationKey(BleDirection.INBOUND, rig.aliceAddress, gen), null)
            assertTrue("the responder relation stands published",
                       rig.bob.isRelationPublished(BleDirection.INBOUND, rig.aliceAddress, gen))
            rig.bob.handleServerDisconnected(rig.aliceAddress, gen + 1L)
            assertNotNull("a terminal for another generation changes nothing",
                          rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
            assertTrue("the publication stands",
                       rig.bob.isRelationPublished(BleDirection.INBOUND, rig.aliceAddress, gen))
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheSilentPeerFallsToTheHeartbeatAlone() {
        val rig = rig()
        try {
            rig.completeTrust()
            rigNow = 1_700_000_000L
            val gen = rig.bob.serverDriver.getClientGeneration(rig.aliceAddress)
            rig.bob.publishRelation(RelationKey(BleDirection.INBOUND, rig.aliceAddress, gen), null)
            val (seq, frags) = sealFromInitiator(rig, 909, 600)
            rig.pushToResponder(frags.take(2))
            val conn = rig.responderConnection()
            val lease = conn.activeLeaseOf(seq) ?: error("the admission left no lease")
            assertTrue("the hand-standing publication is witnessed",
                       rig.bob.isRelationPublished(BleDirection.INBOUND, rig.aliceAddress, gen))
            // the peer falls silent altogether: no delivery ever arrives again
            rigNow = lease.deadlineMono
            rig.bob.sweepInboundLeases()                     // the owner's heartbeat asks each relation
            assertNull("the silent relation fell through the heartbeat alone",
                       rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
            assertFalse("the publication was withdrawn with it",
                        rig.bob.isRelationPublished(BleDirection.INBOUND, rig.aliceAddress, gen))
            assertEquals("nothing was admitted of the silent dribble", 0, rig.collected.size)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheRaceAtTheDeadlineInstantSettlesTheSameBothWays() {
        val rig = rig()
        try {
            rig.completeTrust()
            rigNow = 1_700_000_000L
            val (seqA, fragsA) = sealFromInitiator(rig, 31, 600)
            val conn = rig.responderConnection()
            // (a) the sweep one instant short of the term finds nothing lapsed
            rig.pushToResponder(listOf(fragsA.first()))
            val lease = conn.activeLeaseOf(seqA) ?: error("no lease for the half-open record")
            conn.sweepLeasesForTest(lease.deadlineMono - 1L)
            assertNotNull("one instant short of the term the assembly stands",
                          conn.activeLeaseOf(seqA))
            assertNotNull("and the relation stands with it",
                          rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
            // (b) at the very instant the term passes, the sweep takes the lapsed lease
            conn.sweepLeasesForTest(lease.deadlineMono)
            assertNull("at the term itself the lease is released", conn.activeLeaseOf(seqA))
            assertNotNull("the sweep at the term raised the notice for its owner alone",
                          conn.takeLeaseExpiryNotice())
            // (c) a record that completed before its term leaves nothing to lapse
            val (seqB, fragsB) = sealFromInitiator(rig, 32, 1)
            rig.pushToResponder(fragsB)
            if (!awaitShort(limit = 400) { rig.collected.size == 1 }) {
                println("RACE RING DUMP:")
                for (r in rig.bob.rejectionRecordsForTest()) println("  " + r.site + " | " + r.reason)
            }
            assertEquals("the record completed while its term still ran", 1, rig.collected.size)
            val connAgain = rig.bob.serverDriver.getInboundConnection(rig.aliceAddress)
                ?: error("the relation departed before the completed record")
            connAgain.sweepLeasesForTest(lease.deadlineMono + 40L)
            assertNull("the completed record left no lease behind", connAgain.activeLeaseOf(seqB))
            assertNotNull("the relation of a completed record does not fall",
                          rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheLedgerOfInvariantsStandsWholeAndReportsEveryCheck() {
        val ledger = InvariantLedger("T20 android identical schedules")
        // schedule A: the dribbled assembly to its fall, upon one rig
        val rigA = rig()
        try {
            rigA.completeTrust()
            rigNow = 1_700_000_000L
            val base = rigNow
            val connA = rigA.responderConnection()
            val genA = rigA.bob.serverDriver.getClientGeneration(rigA.aliceAddress)
            // the responder's publication, stood up by hand through the
            // transport's own public door - the T12 precedent - so that the
            // heartbeat's withdrawal has a witness to undo
            rigA.bob.publishRelation(RelationKey(BleDirection.INBOUND, rigA.aliceAddress, genA), null)
            assertTrue("the hand-standing publication is witnessed",
                       rigA.bob.isRelationPublished(BleDirection.INBOUND, rigA.aliceAddress, genA))
            val (seqA, fragsA) = sealFromInitiator(rigA, 501, 1888)
            for (i in 0 until fragsA.size - 1) {
                rigA.pushToResponder(listOf(fragsA[i]))
                rigNow = base + 4L * i
            }
            val leaseA = connA.activeLeaseOf(seqA) ?: error("the admission left no lease")
            ledger.check("LEASE-ABSOLUTE", "dribble",
                         "the term is absolute from the admission",
                         leaseA.deadlineMono == base + 30L)
            ledger.check("REFRESH-IMMOBILE", "dribble",
                         "no arrival moved the deadline", rigNow < leaseA.deadlineMono)
            // the first fall, upon the living connection: its own sweep at
            // the term purges the register and raises the notice for the
            // owner to take
            connA.sweepLeasesForTest(leaseA.deadlineMono)
            ledger.check("REGISTERS-PURGED", "double fall",
                         "the sweep at the term purged the register whole",
                         connA.activeLeaseOf(seqA) == null)
            ledger.check("NOTICE-RAISED", "double fall",
                         "the sweep raised the notice for its owner to take",
                         connA.takeLeaseExpiryNotice() != null)
            // re-admission afresh upon the same living connection, twice, and
            // never is an admission identity borne a second time
            connA.ingestInboundAttValue(fragsA[0])
            val t1 = connA.activeLeaseOf(seqA)?.admissionId
            connA.sweepLeasesForTest(leaseA.deadlineMono + 31L)
            connA.ingestInboundAttValue(fragsA[0])
            val t2Time = rigNow
            val t2 = connA.activeLeaseOf(seqA)?.admissionId
            ledger.check("DIFFERENT-ADMISSION", "double fall",
                         "no admission identity is ever borne twice (observed t1=" + t1 +
                         " t2=" + t2 + ")",
                         t1 != null && t2 != null && t1 != t2)
            // the transport's own fall, reserved for the last act: the final
            // fraction past the second term, the notice taken by the
            // handler, the owner closing the relation through its arm alone
            // the final fraction arrives at the very instant of the second
            // re-admission's own term: the absolute strikes first, the
            // sliding courtesy has not yet earned its silence
            rigNow = t2Time + 30L
            val noticeBefore = connA.peekLeaseExpiryNoticeForTest()?.admissionId
            val aliveBefore = rigA.bob.serverDriver.getInboundConnection(rigA.aliceAddress) != null
            rigA.pushToResponder(listOf(fragsA[fragsA.size - 1]))
            ledger.check("OWNER-CLOSES", "dribble fall",
                         "the relation fell through the owner arm alone (aliveBefore=" + aliveBefore +
                         " noticeBefore=" + noticeBefore +
                         " standingNow=" + (connA.peekLeaseExpiryNoticeForTest()?.admissionId ?: "none") +
                         " state=" + connA.state + ")",
                         rigA.bob.serverDriver.getInboundConnection(rigA.aliceAddress) == null)
            ledger.check("PUBLICATION-WITHDRAWN", "dribble fall",
                         "the fall brought the publication down again",
                         !rigA.bob.isRelationPublished(BleDirection.INBOUND, rigA.aliceAddress, genA))
            ledger.check("NOTHING-FROM-THE-DRIBBLE", "dribble fall",
                         "no part arrived on the stream", rigA.collected.isEmpty())
        } finally {
            rigA.stop()
        }
        // schedule B: the wrap of two hundred fifty six, upon a fresh rig
        val rigB = rig()
        try {
            rigB.completeTrust()
            rigNow = 1_700_000_000L
            val observed = ArrayList<Int>()
            var pushes = 0
            for (k in 0 until 257) {
                val (seq, frags) = sealFromInitiator(rigB, 1500 + k, 1)
                rigB.pushToResponder(frags)
                observed.add(seq)
                pushes += 1
                if (pushes % 32 == 0) {
                    awaitShort(limit = 800) { rigB.collected.size >= pushes }
                }
            }
            val connB = rigB.responderConnection()
            if (!awaitShort(limit = 2000) { rigB.collected.size == 257 }) {
                println("LEDGER B RING DUMP:")
                for (r in rigB.bob.rejectionRecordsForTest()) println("  " + r.site + " | " + r.reason)
            }
            ledger.check("WRAP-COMPLETE", "wrap",
                         "every whole record arrived across the wrap",
                         rigB.collected.size == 257)
            ledger.check("WRAP-FRAMING", "wrap",
                         "the uint8 framing was not altered for the wrap",
                         observed.size == 257 && observed.windowed(2).all { (a, b) ->
                             b == (a + 1) % 256
                         })
            ledger.check("SLOTS-RECYCLED", "wrap",
                         "the register never grew beyond its concurrent bound",
                         connB.leaseCountForTest() <= 4)
        } finally {
            rigB.stop()
        }
        assertEquals("the ledger records no broken invariant; broken: " +
                     ledger.broken().joinToString("; ") { it.invariantId + "@" + it.scenario + " [" + it.statement + "]" },
                     0, ledger.broken().size)
        assertTrue("the ledger names every check it made", ledger.report().contains("HELD"))
        assertTrue("the schedule weighed at least nine checks", ledger.entriesCount() >= 9)
        println(ledger.report())
    }

    @Test
    fun testEverySourceOfTheCallbackSurfaceIsDeliveredOrNamedForTheRecord() {
        val fixture = AdapterTraceFixture()
        val ledger = InvariantLedger("T20 callback inventory")
        for (source in AdapterCallbackSource.values()) {
            if (fixture.canDeliver(source)) {
                ledger.check("INVENTORY", source.name,
                             "deliverable through a production entry", true)
            } else {
                ledger.skip("INVENTORY", source.name,
                            "awaiting the device gates",
                            "the host harness carries no real callback for this source")
            }
        }
        assertEquals("every source of the surface was accounted for",
                     AdapterCallbackSource.values().size, ledger.entriesCount())
        assertEquals("no inventory check was broken", 0, ledger.broken().size)
        assertTrue("the inventory report speaks", ledger.report().isNotEmpty())
    }
}
