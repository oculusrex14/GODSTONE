package io.godstone.mesh.readiness

import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.NoiseSession
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityStorage
import io.godstone.mesh.identity.LegacyIdentityMaterial
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.PeerTrustRejectReason
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
class ReadinessT22Test {

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

    // ------------------------------------------------------------------ T21
    //
    // The trusted initiator upon the record path: HS1 emitted only from the
    // duplex witnessed and the hints ascending; HS2 admitted to its own
    // relation alone, bearing the full immutable advertised hint; trust
    // rejection withholds HS3 and closes the exact relation; HS3 precedes
    // every DATA; and the READY of the controller alone publishes nothing.

    private fun typeOfFragment(value: ByteArray): Int = value[1].toInt() and 0xFF

    private fun isType(value: ByteArray, type: BleRecordType): Boolean =
        typeOfFragment(value) == (type.typeCode.toInt() and 0xFF)

    private fun fragmentCountOf(value: ByteArray): Int = value[4].toInt() and 0xFF

    private fun seqOfFragment(value: ByteArray): Int = value[2].toInt() and 0xFF

    private fun payloadOfFragment(value: ByteArray): ByteArray = value.copyOfRange(8, value.size)

    private fun forge(type: BleRecordType, seq: Int, payload: ByteArray): List<ByteArray> =
        BleRecordFragmenter.fragment(type, seq, payload, 247)

    private fun census(rig: Rig, where: String) {
        println("CENSUS " + where +
            " init-state=" + runCatching { rig.initiatorConnection().state.toString() } +
            " resp-state=" + runCatching { rig.responderConnection().state.toString() } +
            " init-writes=" + rig.aliceOutlet.writesTo(rig.bobAddress).size +
            " kinds=" + runCatching { rig.aliceOutlet.writesTo(rig.bobAddress).map { typeOfFragment(it) } } +
            " resp-notes=" + rig.bobOutlet.notificationsTo(rig.aliceAddress).size +
            " ring-init=" + ringDump(rig.alice) +
            " ring-resp=" + ringDump(rig.bob))
    }

    private inline fun <R> runCatching(block: () -> R): String =
        try { block().toString() } catch (e: Throwable) { "gone(" + e.javaClass.simpleName + ")" }

    /** Stands the rig upon both ladders, short of the exchange itself. */
    private fun standDoor(): Rig {
        val rig = rig()
        rig.bringUpInitiatorLadder()
        rig.bringUpResponderLadder()
        return rig
    }

    private fun beginOn(rig: Rig, remoteHint: ByteArray): TransportResult =
        kotlinx.coroutines.runBlocking { rig.alice.beginTrustedHandshake(rig.peerIdTowardsBob(), remoteHint) }

    private fun awaitBothReady(rig: Rig) {
        awaitUntil("both registries must report the peer ready",
                   { rig.pair.smA.isReady(rig.initiatorConnection().peerId) &&
                     rig.pair.smB.isReady(rig.responderConnection().peerId) })
        awaitUntil("both connections must stand ready",
                   { rig.initiatorConnection().state == BleConnectionState.READY &&
                     rig.responderConnection().state == BleConnectionState.READY })
    }

    /** Drives the exchange step by step, asserting the passage at every
     *  door, and brings the pair to the trusted READY. The HS2 fragments
     *  as they travelled are handed back for the trials that reuse them. */
    private fun driveToReady(rig: Rig): List<ByteArray> {
        rig.aliceOutlet.clear()
        rig.bobOutlet.clear()
        assertEquals("the begin must stand upon the witnessed duplex; ring: " + ringDump(rig.alice),
                     TransportResult.Admitted, beginOn(rig, rig.pair.bob.nodeHint))
        val hs1 = awaitNonEmpty("the HS1 must reach the initiator outlet; ring: " + ringDump(rig.alice)) {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        rig.aliceOutlet.clear()
        rig.pushToResponder(hs1.toList())
        val hs2 = awaitNonEmpty("the HS2 must answer at the responder outlet; ring: " + ringDump(rig.bob)) {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.bobOutlet.clear()
        rig.pushToInitiator(hs2.toList())
        val hs3 = awaitNonEmpty("the HS3 must answer the true HS2 at the initiator outlet; ring: " + ringDump(rig.alice)) {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        rig.pushToResponder(hs3.toList())
        awaitBothReady(rig)
        return hs2.toList()
    }

    // ---------------------------------------------------------------- T22
    //
    // The trusted responder upon the record path. After ROLE_BOUND with the
    // remote below the local hint, the door accepteth exactly the expected
    // first counsel; the second is queued by the writers hand and its verdict
    // heard; the third alone, trusted through the registry, installeth the
    // session. Every refusal ringeth its reason in the collector and the
    // exact relation perisheth with its slot; the own voice come again, the
    // duplicate, the late, the out of order, the false size and the foreign
    // seal are all refused, and no trust is inferred from subscription.

    // MARK: - the answer and its government

    @Test
    fun testTheResponderAnswerethTheExpectedFirstWithTheQueuedSecond() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val hs1 = rig.pair.smA.beginInitiator(rig.initiatorConnection().peerId, rig.pair.bob.nodeHint)
        assertNotNull("the controllers first counsel must be formable", hs1)
        rig.bobOutlet.clear()
        rig.pushToResponder(forge(BleRecordType.HS1, 0, hs1!!))
        val answer = awaitNonEmpty("the second must be queued upon the writers hand; ring: " + ringDump(rig.bob)) {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        val hs2 = answer.first()
        assertTrue("the answer must be of the second form; ring: " + ringDump(rig.bob),
                   isType(hs2, BleRecordType.HS2))
        assertEquals("the second counsel beareth two hundred twenty-nine octets",
                     229, payloadOfFragment(hs2).size)
        assertEquals("the responder must stand mid the handshake",
                     BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.responderConnection().state)
        assertFalse("the second maketh no trusted session", rig.pair.smB.isReady(bPeer))
        assertTrue("no announcement may precede the third", rig.handshakeSeen.isEmpty())
        rig.stop()
    }

    @Test
    fun testTheResponderIsNotTrustedByTheFirstNorTheSecondAloneAndNoDATARidesTheStream() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val hs1 = rig.pair.smA.beginInitiator(rig.initiatorConnection().peerId, rig.pair.bob.nodeHint)
        assertNotNull("the controllers first counsel must be formable", hs1)
        rig.pushToResponder(forge(BleRecordType.HS1, 0, hs1!!))
        awaitNonEmpty("the second must be queued; ring: " + ringDump(rig.bob)) {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        // the untrusted hour: a forged DATA record comes to the gate
        rig.pushToResponder(frameData(9, clearOf(411, 120)))
        awaitUntil("the gate must ring the bounded refusal",
                   { ringDump(rig.bob).contains("unexpected stage") })
        assertNotNull("the bounded refusal slayeth not the relation",
                      rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        assertEquals("the relation abideth mid the handshake",
                     BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.responderConnection().state)
        assertTrue("no application stream may ride the untrusted hour", rig.collected.isEmpty())
        assertFalse("the session standeth untrusted yet", rig.pair.smB.isReady(bPeer))
        rig.stop()
    }

    // MARK: - the refusals and their exact falls

    @Test
    fun testTheTamperedThirdPerishethTheRelationExactly() {
        // the responder weigheth the seal at the third, not at the first:
        // the first passeth the gate by its shape alone; the binding and the
        // static key are proved when the third is opened
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val hs1 = rig.pair.smA.beginInitiator(rig.initiatorConnection().peerId, rig.pair.bob.nodeHint)
        assertNotNull("the controllers first counsel must be formable", hs1)
        rig.pushToResponder(forge(BleRecordType.HS1, 0, hs1!!))
        val answer = awaitNonEmpty("the second must be queued; ring: " + ringDump(rig.bob)) {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.pushToInitiator(answer.toList())
        val third = awaitNonEmpty("the third must come forth; ring: " + ringDump(rig.alice)) {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        val tampered = payloadOfFragment(third.first()).copyOf()
        tampered[tampered.size / 2] = (tampered[tampered.size / 2].toInt() xor 0x5A).toByte()
        rig.pushToResponder(forge(BleRecordType.HS3, seqOfFragment(third.first()), tampered))
        awaitUntil("the false seal must be refused; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("hs3 rejected") })
        awaitUntil("the relation must perish with the refusal",
                   { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
        assertNull("the relation perished with the refusal",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        assertNull("the slot perished with the relation", rig.pair.smB.slotForTest(bPeer))
        assertFalse("no session may stand trusted of a refused counsel", rig.pair.smB.isReady(bPeer))
        rig.stop()
    }

    @Test
    fun testTheSecondSpokenAtTheRespondersGateIsAConflictingSequence() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val hs2 = driveToReady(rig)
        assertTrue("the exchange must have trusted the pair", rig.pair.smB.isReady(bPeer))
        val liars = forge(BleRecordType.HS2, 0x3F, payloadOfFragment(hs2.first()).copyOf())
        rig.pushToResponder(liars)
        awaitUntil("the own voice come again must be refused; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("unexpected") })
        awaitUntil("the exact relation must fall upon the stranger (awaited)",
                   { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
        assertNull("the exact relation must fall upon the stranger",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        awaitUntil("the slot must perish with it (awaited)",
                   { rig.pair.smB.slotForTest(bPeer) == null })
        assertNull("the slot must perish with it", rig.pair.smB.slotForTest(bPeer))
        assertNotNull("the initiator must yet stand whole",
                      rig.alice.centralDriver.getActiveConnection(rig.bobAddress))
        assertEquals("the fall is of the responders side alone",
                     BleConnectionState.READY, rig.initiatorConnection().state)
        rig.stop()
    }

    @Test
    fun testTheThirdRecordBeforeTheFirstIsRefusedAndTheRelationFalleth() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        rig.pushToResponder(forge(BleRecordType.HS3, 7, clearOf(99, 197)))
        awaitUntil("the third before the first must be refused; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("hs3 at stage ROLE_BOUND") })
        assertNull("the out of order counsel felleth the relation",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        assertNull("and the slot with it", rig.pair.smB.slotForTest(bPeer))
        rig.stop()
    }

    @Test
    fun testTheDuplicateFirstMessageInHandPerishethTheRelation() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val hs1 = rig.pair.smA.beginInitiator(rig.initiatorConnection().peerId, rig.pair.bob.nodeHint)
        assertNotNull("the controllers first counsel must be formable", hs1)
        val trueHs1 = hs1!!.copyOf()
        rig.pushToResponder(forge(BleRecordType.HS1, 0, trueHs1))
        awaitNonEmpty("the first answer must be queued; ring: " + ringDump(rig.bob)) {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        // a fresh sequence beareth the selfsame counsel: past the window, a
        // duplicate at the hand - the stage is spent, the relation perisheth
        rig.pushToResponder(forge(BleRecordType.HS1, 1, trueHs1))
        awaitUntil("the duplicate in hand must be refused; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("hs1 at stage HANDSHAKE_IN_PROGRESS") })
        awaitUntil("the duplicate felleth the relation (awaited)",
                   { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
        assertNull("the duplicate felleth the relation",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        awaitUntil("and the slot with it (awaited)",
                   { rig.pair.smB.slotForTest(bPeer) == null })
        assertNull("and the slot with it", rig.pair.smB.slotForTest(bPeer))
        assertEquals("but one answer ever travelled the outlet",
                     1, rig.bobOutlet.notificationsTo(rig.aliceAddress).count {
                         isType(it, BleRecordType.HS2) })
        rig.stop()
    }

    @Test
    fun testTheLateFirstMessageAfterTheTrustClosethTheRelationExactly() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        driveToReady(rig)
        assertTrue("the pair must stand trusted before the trial", rig.pair.smB.isReady(bPeer))
        // a fresh counsel of another pairing: the stage is spent, the gate
        // refuseth by the stage alone, ere the seal is weighed
        val alien = makeTrustedPair()
        val alienHs1 = alien.smA.beginInitiator(rig.peerIdTowardsBob().copyOf(), alien.alice.nodeHint)
        assertNotNull("an alien first counsel must be formable for the trial", alienHs1)
        rig.pushToResponder(forge(BleRecordType.HS1, 0x2C, alienHs1!!))
        awaitUntil("the late first must be refused; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("unexpected") })
        awaitUntil("the late counsel felleth the relation",
                   { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
        assertNull("the late counsel felleth the relation",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        assertFalse("and the session with it", rig.pair.smB.isReady(bPeer))
        assertNotNull("the initiators relation must yet abide",
                      rig.alice.centralDriver.getActiveConnection(rig.bobAddress))
        assertEquals("the fall is exact, one side alone",
                     BleConnectionState.READY, rig.initiatorConnection().state)
        rig.stop()
    }

    @Test
    fun testTheResponderHearkentheVerdictOfTheQueuedSecond() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val hs1 = rig.pair.smA.beginInitiator(rig.initiatorConnection().peerId, rig.pair.bob.nodeHint)
        assertNotNull("the controllers first counsel must be formable", hs1)
        // the leg is flooded: the answer can not be staged, the writers verdict
        // must reach the door and the relation must fall upon it
        rig.bobOutlet.floodingAddress = rig.aliceAddress
        rig.pushToResponder(forge(BleRecordType.HS1, 0, hs1!!))
        awaitUntil("the refused reservation must ring at the door; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("hs2 reservation refused") })
        assertTrue("the writer must tell its own tale; ring: " + ringDump(rig.bob),
                   ringDump(rig.bob).contains("queue full"))
        awaitUntil("the relation must perish upon the refused verdict",
                   { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
        assertNull("the relation perished upon the refused verdict",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        awaitUntil("the slot must perish with it",
                   { rig.pair.smB.slotForTest(bPeer) == null })
        assertNull("the slot perished with it", rig.pair.smB.slotForTest(bPeer))
        assertFalse("the responder never reached the ready hour", rig.pair.smB.isReady(bPeer))
        assertTrue("no announcement may rise from a refused reservation", rig.handshakeSeen.isEmpty())
        rig.bobOutlet.floodingAddress = null
        rig.stop()
    }

    // MARK: - the seal, the size, and the bound remembrance

    @Test
    fun testThePublicShapeAdmittethTheAlienSealDenieth() {
        // the discovery field is public and serveth the gate: a first
        // counsel of another pairing, of the right shape, is ANSWERED (the
        // responder trusteth not the seal at the first). The authenticated
        // field is separate: when the alien third is opened, the binder of
        // the responder proveth the static key against its own remembrance,
        // findeth it other, and casteth the relation out
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        // an alien first counsel, of the public shape alone, from a fresh pairing
        val alienA = standDoor()
        val alienHs1 = alienA.pair.smA.beginInitiator(alienA.initiatorConnection().peerId, alienA.pair.bob.nodeHint)
        assertNotNull("the alien first counsel must be formable", alienHs1)
        rig.pushToResponder(forge(BleRecordType.HS1, 0, alienHs1!!))
        val answered = awaitNonEmpty("the alien shape must be answered; ring: " + ringDump(rig.bob)) {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        assertTrue("the answer beareth the second form", isType(answered.first(), BleRecordType.HS2))
        assertTrue("the shape alone may not slay the relation",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) != null)
        alienA.stop()
        // an alien third, authentic to its OWN pairing, drawn from a second full exchange
        val alienB = standDoor()
        driveToReady(alienB)
        val alienThird = payloadOfFragment(alienB.aliceOutlet.writesTo(alienB.bobAddress).last()).copyOf()
        assertEquals("the alien third beareth the authentic length", 197, alienThird.size)
        rig.pushToResponder(forge(BleRecordType.HS3, 9, alienThird))
        awaitUntil("the alien seal must be refused at the third; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("hs3 rejected") })
        awaitUntil("the alien seal felleth the relation",
                   { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
        assertNull("the alien seal felleth the relation",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        assertNull("and the slot with it", rig.pair.smB.slotForTest(bPeer))
        assertFalse("no session was ever installed", rig.pair.smB.isReady(bPeer))
        alienB.stop()
        rig.stop()
        // the remembrance is bound one-way: a later, lesser advertisement moveth it not
        val rig2 = standDoor()
        val stranger = ByteArray(4) { i -> ((i * 37) + 11).toByte() }
        rig2.bob.serverDriver.onLinkInfoWriteRequest(rig2.aliceAddress,
            BleLinkInfoCodec.encode(flags = 0.toByte(), nodeHint = stranger, shortDigest = ByteArray(6), queueDepth = 0))
        val hs1b = rig2.pair.smA.beginInitiator(rig2.initiatorConnection().peerId, rig2.pair.bob.nodeHint)
        assertNotNull("the counsel must be formable", hs1b)
        rig2.bobOutlet.clear()
        rig2.pushToResponder(forge(BleRecordType.HS1, 0, hs1b!!))
        val answer = awaitNonEmpty("the bound remembrance must answer yet; ring: " + ringDump(rig2.bob)) {
            rig2.bobOutlet.notificationsTo(rig2.aliceAddress)
        }
        assertTrue("the answer must be the second form", isType(answer.first(), BleRecordType.HS2))
        rig2.stop()
    }

    @Test
    fun testTheWrongSizedRecordsAreRefusedAndTheTruthPreserved() {
        val rigA = standDoor()
        val peerA = rigA.responderConnection().peerId.copyOf()
        rigA.pushToResponder(forge(BleRecordType.HS1, 0, clearOf(616, 24)))
        awaitUntil("the stunted first must be refused; ring: " + ringDump(rigA.bob),
                   { ringDump(rigA.bob).contains("hs1 rejected") })
        awaitUntil("the stunted counsel felleth the relation (awaited)",
                   { rigA.bob.serverDriver.getInboundConnection(rigA.aliceAddress) == null })
        assertNull("the stunted counsel felleth the relation",
                   rigA.bob.serverDriver.getInboundConnection(rigA.aliceAddress))
        awaitUntil("and the slot with it (awaited)",
                   { rigA.pair.smB.slotForTest(peerA) == null })
        assertNull("and the slot with it", rigA.pair.smB.slotForTest(peerA))
        rigA.stop()
        val rigB = standDoor()
        val peerB = rigB.responderConnection().peerId.copyOf()
        val hs1 = rigB.pair.smA.beginInitiator(rigB.initiatorConnection().peerId, rigB.pair.bob.nodeHint)
        assertNotNull("the controllers first counsel must be formable", hs1)
        rigB.pushToResponder(forge(BleRecordType.HS1, 0, hs1!!))
        awaitNonEmpty("the answer must be queued; ring: " + ringDump(rigB.bob)) {
            rigB.bobOutlet.notificationsTo(rigB.aliceAddress)
        }
        rigB.pushToResponder(forge(BleRecordType.HS3, 3, clearOf(5, 120)))
        awaitUntil("the stunted third must be refused; ring: " + ringDump(rigB.bob),
                   { ringDump(rigB.bob).contains("hs3 rejected") })
        awaitUntil("the stunted third felleth the relation (awaited)",
                   { rigB.bob.serverDriver.getInboundConnection(rigB.aliceAddress) == null })
        assertNull("the stunted third felleth the relation",
                   rigB.bob.serverDriver.getInboundConnection(rigB.aliceAddress))
        awaitUntil("and the slot with it (awaited)",
                   { rigB.pair.smB.slotForTest(peerB) == null })
        assertNull("and the slot with it", rigB.pair.smB.slotForTest(peerB))
        rigB.stop()
    }

    @Test
    fun testTheRejectedAndRevokedBindingsPerishTheRelationAtTheThirdCounsel() {
        for (reason in listOf(PeerTrustRejectReason.Revoked, PeerTrustRejectReason.Rollback)) {
            val rig = rigWith(makeDenyingPair(reason))
            rig.bringUpInitiatorLadder()
            rig.bringUpResponderLadder()
            val bPeer = rig.responderConnection().peerId.copyOf()
            // the ladders rose and the subscriptions came, yet the trust is
            // not inferred therefrom: the authority denieth the binding
            val hs1 = rig.pair.smA.beginInitiator(rig.initiatorConnection().peerId, rig.pair.bob.nodeHint)
            assertNotNull("the controllers first counsel must be formable", hs1)
            rig.pushToResponder(forge(BleRecordType.HS1, 0, hs1!!))
            val answer = awaitNonEmpty("the shape must be answered ere the seal is weighed; ring: " + ringDump(rig.bob)) {
                rig.bobOutlet.notificationsTo(rig.aliceAddress)
            }
            rig.pushToInitiator(answer.toList())
            val third = awaitNonEmpty("the third must come forth; ring: " + ringDump(rig.alice)) {
                rig.aliceOutlet.writesTo(rig.bobAddress)
            }
            // the hour of decision: the responder openeth the third, consulteth
            // the authority upon the binding, is denied, and casteth forth
            rig.pushToResponder(third.toList())
            awaitUntil("the denied binding must refuse the seal; ring: " + ringDump(rig.bob),
                       { ringDump(rig.bob).contains("hs3 rejected") })
            awaitUntil("the denied binding felleth the relation",
                       { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
            assertNull("the denied binding felleth the relation",
                       rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
            awaitUntil("the slot must perish with it",
                       { rig.pair.smB.slotForTest(bPeer) == null })
            assertNull("and the slot with it", rig.pair.smB.slotForTest(bPeer))
            assertFalse("no session may stand of a denied binding", rig.pair.smB.isReady(bPeer))
            assertTrue("no announcement may rise from a denied binding", rig.handshakeSeen.isEmpty())
            rig.stop()
        }
    }

    @Test
    fun testTheResponderPublishethNoughtTillTheThirdIsTrusted() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val publishedAtDoor = rig.bob.publishedRelationsForTest().size
        driveToReady(rig)
        assertEquals("the third alone publisheth no link-ready relation",
                     publishedAtDoor, rig.bob.publishedRelationsForTest().size)
        awaitUntil("the announcement must have reached the peers", { rig.handshakeSeen.size == 1 })
        assertTrue("the announcement beareth the peers own id",
                   rig.handshakeSeen.first().contentEquals(bPeer))
        // the positive control upon the selfsame ledger: an enrollment of the
        // owners hand is seen by the census forth
        val genLive = rig.bob.serverDriver.getClientGeneration(rig.aliceAddress) ?: -1L
        assertTrue("the hand-standing enrollment must be listed",
                   rig.bob.publishRelation(RelationKey(BleDirection.INBOUND, rig.aliceAddress, genLive), null))
        assertEquals("the census must see the one enrollment",
                     publishedAtDoor + 1, rig.bob.publishedRelationsForTest().size)
        rig.stop()
    }

    @Test
    fun testTheThirdSpokenAgainAfterTheTrustIsAConflictingSequence() {
        val rig = standDoor()
        val bPeer = rig.responderConnection().peerId.copyOf()
        val hs1 = rig.pair.smA.beginInitiator(rig.initiatorConnection().peerId, rig.pair.bob.nodeHint)
        assertNotNull("the controllers first counsel must be formable", hs1)
        rig.pushToResponder(forge(BleRecordType.HS1, 0, hs1!!))
        val answer = awaitNonEmpty("the second must be queued; ring: " + ringDump(rig.bob)) {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.pushToInitiator(answer.toList())
        val third = awaitNonEmpty("the third must come forth; ring: " + ringDump(rig.alice)) {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        val thirdPayload = payloadOfFragment(third.first()).copyOf()
        val thirdSeq = seqOfFragment(third.first())
        rig.pushToResponder(third.toList())
        awaitUntil("the pair must stand trusted", { rig.pair.smB.isReady(bPeer) })
        // the selfsame counsel again, with a fresh sequence: the stage is
        // spent, the record is late - the exact relation falleth
        rig.pushToResponder(forge(BleRecordType.HS3, (thirdSeq + 7) and 0xFF, thirdPayload))
        awaitUntil("the third again must be refused; ring: " + ringDump(rig.bob),
                   { ringDump(rig.bob).contains("unexpected") })
        awaitUntil("the late third felleth the relation (awaited)",
                   { rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null })
        assertNull("the late third felleth the relation",
                   rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        awaitUntil("and the slot with it (awaited)",
                   { rig.pair.smB.slotForTest(bPeer) == null })
        assertNull("and the slot with it", rig.pair.smB.slotForTest(bPeer))
        assertNotNull("the initiators relation yet standeth",
                      rig.alice.centralDriver.getActiveConnection(rig.bobAddress))
        assertEquals("the fall is exact, one side alone",
                     BleConnectionState.READY, rig.initiatorConnection().state)
        rig.stop()
    }

    // MARK: - the two bespoke builders, of the files own stuff

    private fun makeDenyingPair(reason: PeerTrustRejectReason): TrustedPair {
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
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Rejected(reason)
        }
        return TrustedPair(a, b, InMemoryMessageStore(), InMemoryMessageStore(),
                           SessionManager(a, trustA), SessionManager(b, trustB))
    }


    private fun rigWith(pairIn: TrustedPair): Rig {
        val pair = pairIn
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

}
