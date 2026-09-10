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
class ReadinessT21Test {

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

    @Test
    fun testTheInitiatorEmitsHS1UponTheDuplexWitnessedInAscendantOrder() {
        val rig = standDoor()
        try {
            rig.aliceOutlet.clear()
            val verdict = beginOn(rig, rig.pair.bob.nodeHint)
            assertEquals("the begin must be admitted upon the witnessed duplex; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, verdict)
            val captured = awaitNonEmpty("the HS1 must reach the outlet; ring: " + ringDump(rig.alice)) {
                rig.aliceOutlet.writesTo(rig.bobAddress)
            }
            assertTrue("the first record of the trusted exchange must be HS1",
                       isType(captured[0], BleRecordType.HS1))
            assertEquals("the HS1 must travel whole in one fraction of the agreed space",
                         1, fragmentCountOf(captured[0]))
            assertEquals("the HS1 message is thirty-two octets of the canonical profile",
                         32, payloadOfFragment(captured[0]).size)
            assertEquals("the state must progress to the handshake in progress",
                         BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.initiatorConnection().state)
            assertNotNull("the relation must stand admitted with its session slot",
                          rig.pair.smA.slotForTest(rig.initiatorConnection().peerId))
            // no second begin while the exchange lives: the slot already bears a controller
            val again = beginOn(rig, rig.pair.bob.nodeHint)
            assertTrue("a second begin upon the living exchange must be refused",
                       again is TransportResult.Rejected)
            assertTrue("the ring must name the second refusal",
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "hs.begin" && it.reason.contains("begin initiator refused")
                       })
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheBeginIsRefusedWhileTheDuplexLiesUnwitnessed() {
        val rig = standDoor()
        try {
            rig.initiatorConnection().maxAttValueLength = 10  // below the floor of twenty the witness fails
            rig.aliceOutlet.clear()
            val verdict = beginOn(rig, rig.pair.bob.nodeHint)
            assertTrue("an unwitnessed duplex must refuse the begin", verdict is TransportResult.Rejected)
            assertTrue("the ring must name the missing witness",
                       rig.alice.rejectionRecordsForTest().any {
                           it.site == "hs.begin" && it.reason.contains("physical duplex not witnessed")
                       })
            assertTrue("no record may travel an unwitnessed duplex",
                       rig.aliceOutlet.writesTo(rig.bobAddress).isEmpty())
            assertNull("no session slot may be born of a refused begin",
                       rig.pair.smA.slotForTest(rig.initiatorConnection().peerId))
            assertEquals("the state must stand where it stood",
                         BleConnectionState.ROLE_BOUND, rig.initiatorConnection().state)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheBeginIsRefusedWhenTheHintsDescendOrMeet() {
        val rig = standDoor()
        try {
            val equal = beginOn(rig, rig.pair.alice.nodeHint)
            assertTrue("equal hints know no ascendant seat", equal is TransportResult.Rejected)
            val descending = beginOn(rig, ByteArray(4))
            assertTrue("descending hints must refuse the begin", descending is TransportResult.Rejected)
            assertEquals("both refusals must ring at the begin door, twice for the order",
                         2, rig.alice.rejectionRecordsForTest().count {
                             it.site == "hs.begin" && it.reason.contains("hint order not ascendant")
                         })
            assertTrue("no HS1 may travel upon a disordered order",
                       rig.aliceOutlet.writesTo(rig.bobAddress).isEmpty())
            assertNull("no slot may be born of disordered counsel",
                       rig.pair.smA.slotForTest(rig.initiatorConnection().peerId))
            assertEquals("the state must keep its prior truth",
                         BleConnectionState.ROLE_BOUND, rig.initiatorConnection().state)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheComparatorOrdersAsTheLawStates() {
        val rig = rig()
        try {
            assertTrue("the ascendant pair reads lesser",
                       rig.alice.hintOrder(byteArrayOf(1, 2, 3, 4), byteArrayOf(1, 2, 3, 5)) < 0)
            assertTrue("equal hints meet at zero",
                       rig.alice.hintOrder(byteArrayOf(9, 9, 9, 9), byteArrayOf(9, 9, 9, 9)) == 0)
            assertTrue("the unsigned reading rules above the sign",
                       rig.alice.hintOrder(byteArrayOf(0xFF.toByte(), 0, 0, 0), byteArrayOf(1, 0, 0, 0)) > 0)
            assertTrue("the shorter prefix is the lesser",
                       rig.alice.hintOrder(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 3, 0)) < 0)
            assertTrue("the empty key is the least of all",
                       rig.alice.hintOrder(ByteArray(0), byteArrayOf(0)) < 0)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheHS2TravelsToItsOwnRelationAloneAndBearsTheImmutableHint() {
        val rig = standDoor()
        try {
            rig.aliceOutlet.clear()
            rig.bobOutlet.clear()
            assertEquals("the begin must stand; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, beginOn(rig, rig.pair.bob.nodeHint))
            val hs1 = awaitNonEmpty("the HS1 must be taken; ring: " + ringDump(rig.alice)) {
                rig.aliceOutlet.writesTo(rig.bobAddress)
            }
            rig.aliceOutlet.clear()
            rig.pushToResponder(hs1.toList())
            // the HS2 belongs to the initiator's door alone: it must not appear
            // as a write upon the initiator's own outlet, nor stir the responder's
            // writer towards the peer
            val hs2 = awaitNonEmpty("the HS2 must answer at the responder outlet; ring: " + ringDump(rig.bob)) {
                rig.bobOutlet.notificationsTo(rig.aliceAddress)
            }
            assertTrue("the HS2 must not be written upon the initiator outlet",
                       rig.aliceOutlet.writesTo(rig.bobAddress).isEmpty())
            assertTrue("the HS2 record must be of its proper type",
                       isType(hs2[0], BleRecordType.HS2))
            assertEquals("the HS2 message is two hundred twenty-nine octets of the canonical profile",
                         229, payloadOfFragment(hs2[0]).size)
            rig.bobOutlet.clear()
            rig.pushToInitiator(hs2.toList())
            val hs3 = awaitNonEmpty("the HS3 must answer at the initiator outlet; ring: " + ringDump(rig.alice)) {
                rig.aliceOutlet.writesTo(rig.bobAddress)
            }
            assertTrue("the answer must be HS3", isType(hs3[0], BleRecordType.HS3))
            assertEquals("the HS3 message is one hundred ninety-seven octets of the canonical profile",
                         197, payloadOfFragment(hs3[0]).size)
            assertEquals("the responder must still await its own leg of the exchange",
                         BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.responderConnection().state)
            assertNotNull("the initiator relation must stand with its slot until the HS3 is carried",
                          rig.pair.smA.slotForTest(rig.initiatorConnection().peerId))
            rig.pushToResponder(hs3.toList())
            awaitBothReady(rig)
            assertNotNull("the trusted session must remain while the relation stands",
                          rig.pair.smA.slotForTest(rig.initiatorConnection().peerId))
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheTrustRejectionWithholdsHS3AndClosesTheRelationExactly() {
        val rig = standDoor()
        try {
            rig.aliceOutlet.clear()
            rig.bobOutlet.clear()
            assertEquals("the begin must stand; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, beginOn(rig, rig.pair.bob.nodeHint))
            val hs1 = awaitNonEmpty("the HS1 must be taken") { rig.aliceOutlet.writesTo(rig.bobAddress) }
            rig.aliceOutlet.clear()
            rig.pushToResponder(hs1.toList())
            val hs2 = awaitNonEmpty("the HS2 must be taken") { rig.bobOutlet.notificationsTo(rig.aliceAddress) }
            rig.bobOutlet.clear()
            val peer = rig.initiatorConnection().peerId.copyOf()
            // the villain: one octet of the sealed span falsified - the seal
            // will not serve and the controller must refuse the counsel
            val villain = hs2[0].copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 0x5A).toByte() }
            val forged = forge(BleRecordType.HS2, seqOfFragment(hs2[0]), payloadOfFragment(villain))
            rig.pushToInitiator(forged)
            awaitUntil("the forged HS2 must fall to the trust", {
                rig.alice.rejectionRecordsForTest().any {
                    it.site == "hs.read.initiator" && it.reason.contains("hs2 rejected")
                }
            })
            assertTrue("the HS3 must be withheld from a rejected trust",
                       rig.aliceOutlet.writesTo(rig.bobAddress).none { isType(it, BleRecordType.HS3) })
            assertNull("the slot must perish with the rejected relation",
                       rig.pair.smA.slotForTest(peer))
            awaitUntil("the relation must close exactly where the trust fell",
                       { rig.alice.centralDriver.getActiveConnection(rig.bobAddress) == null })
            assertTrue("no application record may ride the fallen trust", rig.collected.isEmpty())
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheBadBindingAndBadStaticKeyAndBadHintEachWithholdAllApplicationData() {
        for (villainy in listOf("binding", "static", "hint")) {
            val rig = standDoor()
            try {
                rig.aliceOutlet.clear()
                rig.bobOutlet.clear()
                // the hint villain taints the sealed expectation at the begin
                // itself: the responder shall answer with his true advertised
                // counsel and the controller must refuse the mismatch
                val wrongHint = rig.pair.bob.nodeHint.copyOf()
                val lastOctet = wrongHint[wrongHint.size - 1].toInt() and 0xFF
                wrongHint[wrongHint.size - 1] = (((lastOctet + 3) % 250) + 1).toByte()
                val hintUsed = if (villainy == "hint") wrongHint else rig.pair.bob.nodeHint
                assertEquals("the begin must stand for the $villainy trial; ring: " + ringDump(rig.alice),
                             TransportResult.Admitted, beginOn(rig, hintUsed))
                val hs1 = awaitNonEmpty("the HS1 must be taken for the $villainy trial") {
                    rig.aliceOutlet.writesTo(rig.bobAddress)
                }
                rig.aliceOutlet.clear()
                rig.pushToResponder(hs1.toList())
                val hs2 = awaitNonEmpty("the HS2 must be taken for the $villainy trial") {
                    rig.bobOutlet.notificationsTo(rig.aliceAddress)
                }
                rig.bobOutlet.clear()
                val peer = rig.initiatorConnection().peerId.copyOf()
                when (villainy) {
                    "binding", "static" -> {
                        // the tamper rides within the sealed payload: the
                        // header and its check stay true, so the fragment
                        // passes the gate and the controller must refuse it
                        val payload = payloadOfFragment(hs2[0]).copyOf()
                        val deep = if (villainy == "binding") payload.size / 8 else payload.size / 2
                        payload[deep] = (payload[deep].toInt() xor 0xA5).toByte()
                        rig.pushToInitiator(forge(BleRecordType.HS2, seqOfFragment(hs2[0]), payload))
                    }
                    else -> {
                        // the counsel is true in itself yet meets a tainted
                        // expectation: the sealed remote hint binds another
                        // tale and the controller must detect the mismatch
                        rig.pushToInitiator(hs2.toList())
                    }
                }
                census(rig, "villainy-" + villainy + "-after-push")
                awaitUntil("the villain must be refused at the door; ring: " + ringDump(rig.alice), {
                    rig.alice.rejectionRecordsForTest().any {
                        it.reason.contains("hs2 rejected") || it.reason.contains("unexpected") ||
                        it.reason.contains("malformed") || it.reason.contains("conflicting")
                    }
                })
                assertTrue("the villain must have his HS3 withheld",
                           rig.aliceOutlet.writesTo(rig.bobAddress).none { isType(it, BleRecordType.HS3) })
                assertNull("the villain slot must perish with the relation",
                           rig.pair.smA.slotForTest(peer))
                awaitUntil("the villain relation must close exactly",
                           { rig.alice.centralDriver.getActiveConnection(rig.bobAddress) == null })
                assertTrue("the villain must produce no application DATA", rig.collected.isEmpty())
            } finally {
                rig.stop()
            }
        }
    }


    @Test
    fun testAnUnexpectedRecordAfterTheTrustClosesTheRelationExactly() {
        val rig = standDoor()
        try {
            val hs2 = driveToReady(rig)
            val peer = rig.initiatorConnection().peerId.copyOf()
            // a fresh sequence number, an HS2 shape: after the trust no HS2 is
            // expected at all - the section thirteen law closes the relation
            val fresh = forge(BleRecordType.HS2, (seqOfFragment(hs2[0]) + 7) and 0xFF,
                              payloadOfFragment(hs2[0]))
            rig.pushToInitiator(fresh)
            census(rig, "late-record-after-push")
            awaitUntil("the unexpected HS2 must be refused at the gate; ring: " + ringDump(rig.alice), {
                rig.alice.rejectionRecordsForTest().any {
                    it.site == "ingest.notify" && it.reason.contains("unexpected stage")
                }
            })
            awaitUntil("the relation must close exactly before the unexpected counsel",
                       { rig.alice.centralDriver.getActiveConnection(rig.bobAddress) == null })
            assertNull("no slot may outlive the relation it served",
                       rig.pair.smA.slotForTest(peer))
            assertTrue("no application record may ride the fallen relation", rig.collected.isEmpty())
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheHS3PrecedesEveryDATAInTheWriterOrder() {
        val rig = standDoor()
        try {
            driveToReady(rig)
            // the outlet holds the HS3 as the last writing of the exchange
            val beforeData = rig.aliceOutlet.writesTo(rig.bobAddress)
            assertTrue("the HS3 must stand among the writings",
                       beforeData.any { isType(it, BleRecordType.HS3) })
            assertEquals("the last writing of the exchange must be the HS3",
                         true, isType(beforeData.last(), BleRecordType.HS3))
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), clearOf(771, 120)) }
            census(rig, "sendsite-" + verdict::class.simpleName)
            assertEquals("the application must be admitted after the trust",
                         TransportResult.Admitted, verdict)
            val afterData = awaitUntilCount("the DATA must follow the trust") {
                rig.aliceOutlet.writesTo(rig.bobAddress).filter { isType(it, BleRecordType.DATA) }
            }
            val full = rig.aliceOutlet.writesTo(rig.bobAddress)
            val lastHs3 = full.indexOfLast { isType(it, BleRecordType.HS3) }
            val firstData = full.indexOfFirst { isType(it, BleRecordType.DATA) }
            assertTrue("the full writings must keep the HS3 before the DATA",
                       lastHs3 >= 0 && firstData >= 0 && lastHs3 < firstData)
            // and the DATA must ride to the peer complete and authentic
            rig.pushToResponder(full.drop(firstData).toList())
            awaitUntil("the DATA must ride the responder door",
                       { rig.collected.isNotEmpty() })
            assertTrue("the DATA must reach the collector whole", rig.collected.isNotEmpty())
            assertEquals("the clear must alight unchanged where the peer put it",
                         120, rig.collected[0].second.size)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testNoApplicationDATAProceedsBeforeTheTrustedCryptographicReady() {
        val rig = standDoor()
        try {
            assertEquals("the begin must stand", TransportResult.Admitted,
                         beginOn(rig, rig.pair.bob.nodeHint))
            awaitNonEmpty("the HS1 must be taken") { rig.aliceOutlet.writesTo(rig.bobAddress) }
            // the exchange stands in progress: the trust is not yet made
            assertEquals("the relation must stand in the handshake",
                         BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.initiatorConnection().state)
            val verdict = kotlinx.coroutines.runBlocking { rig.alice.send(rig.peerIdTowardsBob(), clearOf(301, 120)) }
            assertTrue("DATA before the trusted READY must not be admitted",
                       verdict !is TransportResult.Admitted)
            assertTrue("no DATA may travel before the trust",
                       rig.aliceOutlet.writesTo(rig.bobAddress).none { isType(it, BleRecordType.DATA) })
            assertTrue("the responder must collect nothing of the untrusted hour",
                       rig.collected.isEmpty())
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheControllerReadyAlonePublishesNoLinkReady() {
        val rig = standDoor()
        try {
            val publishedAtLadderA = rig.alice.publishedRelationsForTest().size
            val publishedAtLadderB = rig.bob.publishedRelationsForTest().size
            driveToReady(rig)
            awaitUntil("the completion hook must note the trusted passage",
                       { rig.handshakeSeen.isNotEmpty() })
            assertTrue("the completion hook must have noted the trusted passage",
                       rig.handshakeSeen.isNotEmpty())
            assertEquals("the trusted exchange must add no publication to the initiator",
                         publishedAtLadderA, rig.alice.publishedRelationsForTest().size)
            assertEquals("the trusted exchange must add no publication to the responder",
                         publishedAtLadderB, rig.bob.publishedRelationsForTest().size)
            // the positive control upon the same census: the hand-standing
            // publication is seen - the emptiness above is the absence of any
            // announcement by the controller, not the blindness of the census
            val genLiveB = rig.bob.serverDriver.getClientGeneration(rig.aliceAddress) ?: -1L
            assertTrue("the hand-standing publication must be enrolled",
                       rig.bob.publishRelation(RelationKey(BleDirection.INBOUND, rig.aliceAddress, genLiveB), null))
            assertEquals("the census must see the one enrollment",
                         publishedAtLadderB + 1, rig.bob.publishedRelationsForTest().size)
        } finally {
            rig.stop()
        }
    }

    @Test
    fun testTheHS3ReservationFailureClosesTheRelationExactly() {
        val rig = standDoor()
        try {
            rig.aliceOutlet.clear()
            rig.bobOutlet.clear()
            assertEquals("the begin must stand; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, beginOn(rig, rig.pair.bob.nodeHint))
            val hs1 = awaitNonEmpty("the HS1 must be taken") { rig.aliceOutlet.writesTo(rig.bobAddress) }
            rig.aliceOutlet.clear()
            rig.pushToResponder(hs1.toList())
            val hs2 = awaitNonEmpty("the HS2 must be taken") { rig.bobOutlet.notificationsTo(rig.aliceAddress) }
            rig.bobOutlet.clear()
            val peer = rig.initiatorConnection().peerId.copyOf()
            // between the accepted counsel and the reservation: the outlet
            // refuses the queue, the reservation fails, the law closes it
            rig.aliceOutlet.floodingAddress = rig.bobAddress
            rig.pushToInitiator(hs2.toList())
            awaitUntil("the refused reservation must ring; ring: " + ringDump(rig.alice), {
                rig.alice.rejectionRecordsForTest().any {
                    it.site == "hs.read.initiator" && it.reason.contains("hs3 reservation refused")
                }
            })
            // the outlet records what was attempted; the truth the flood
            // protects is that nothing reached the responder toward the door
            census(rig, "flooding-verdict")
            assertEquals("the responder must never be trusted by a flooded reservation",
                         BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.responderConnection().state)
            assertTrue("no announcement may rise from a flooded reservation",
                       rig.handshakeSeen.isEmpty())
            assertNull("the slot must perish with the closed relation",
                       rig.pair.smA.slotForTest(peer))
            awaitUntil("the relation must close exactly at the refusal",
                       { rig.alice.centralDriver.getActiveConnection(rig.bobAddress) == null })
            assertTrue("no application record may ride the closed relation", rig.collected.isEmpty())
        } finally {
            rig.aliceOutlet.floodingAddress = null
            rig.stop()
        }
    }

    @Test
    fun testTheStorageFailureKeepsThePriorTruthUnmutated() {
        val rig = standDoor()
        try {
            rig.aliceOutlet.clear()
            rig.bobOutlet.clear()
            assertEquals("the begin must stand; ring: " + ringDump(rig.alice),
                         TransportResult.Admitted, beginOn(rig, rig.pair.bob.nodeHint))
            val hs1 = awaitNonEmpty("the HS1 must be taken") { rig.aliceOutlet.writesTo(rig.bobAddress) }
            rig.aliceOutlet.clear()
            rig.pushToResponder(hs1.toList())
            val hs2 = awaitNonEmpty("the HS2 must be taken") { rig.bobOutlet.notificationsTo(rig.aliceAddress) }
            rig.bobOutlet.clear()
            // the storage of the seal is struck: the door must not mutate any
            // authoritative state upon a failed validation
            rig.pair.smA.testOperationHook = { step ->
                if (step == "initiatorProcessHs2") error("injected storage failure")
            }
            var thrown = false
            try {
                rig.pushToInitiator(hs2.toList())
            } catch (e: IllegalStateException) {
                thrown = e.message?.contains("injected storage failure") == true
            }
            rig.pair.smA.testOperationHook = null
            assertTrue("the injected failure must surface at the door", thrown)
            assertNotNull("the relation must stand unmutated upon the failed stroke",
                          rig.alice.centralDriver.getActiveConnection(rig.bobAddress))
            assertEquals("the state must keep its prior truth",
                         BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.initiatorConnection().state)
            assertTrue("no HS3 may be ordered upon the failed storage",
                       rig.aliceOutlet.writesTo(rig.bobAddress).none { isType(it, BleRecordType.HS3) })
            assertTrue("no application DATA may proceed upon the failed storage",
                       rig.collected.isEmpty())
        } finally {
            rig.pair.smA.testOperationHook = null
            rig.stop()
        }
    }

}
