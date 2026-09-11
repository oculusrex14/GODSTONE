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
import io.godstone.mesh.transport.BleReassembledRecord
import io.godstone.mesh.transport.HandshakeDispatchViolation
import io.godstone.mesh.transport.KeyConfirmationControl
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
     * T23: the cross-platform handshake POLICY of section thirteen - Android half.
     *
     * The deadline is armed from the role binding and the owners hand reapeth
     * a stalled, half-spoken exchange only when nothing is in flight, so an
     * idle seat and a travelling reassembly are left to the lease that owns
     * them. No counsel is retransmitted in place: the exact frame is hearkened
     * not, the fresh sequence at a spent stage perisheth. The trusted hour
     * publisheth no application readiness; the sealed key-confirmation round,
     * riding the DATA channel of an established relation, is the gate to the
     * single LinkReady. Reflection, forgery, staleness, misshapen frames, the
     * unanswered hour and the wayward record are all observed and fallen.
     */
class ReadinessT23Test {

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
        /** What the initiators received() stream yielded: the court grafted ear. */
        val collectedIn = CopyOnWriteArrayList<Pair<ByteArray, ByteArray>>()
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
            subscriptions.add(alice.received()
                .onEach { (peerId, clear) -> collectedIn.add(peerId to clear) }
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

    // ================================================================ T23 ====
    //
    // The handshake policy of section thirteen, upon the record path. The
    // clock is armed at the role binding; the owners hand reapeth a stalled,
    // half-spoken exchange - engaged, past the ten-second hour, with nothing
    // in flight - while leaving an idle seat and a travelling reassembly to
    // the lease that already governs them. No counsel is retransmitted in
    // place: a byte-for-byte, sequence-for-sequence re-presenting is hearkened
    // not and the controller runneth not twice, while a fresh sequence at a
    // spent stage is a conflicting counsel and perisheth. The trusted hour
    // publisheth no application readiness; only the sealed key-confirmation
    // round - a challenge and its echoing answer upon the DATA channel of an
    // established relation - carrieth the peer to KEY_CONFIRMED and thence to
    // the single application LinkReady. A reflection, a forged echo, an old
    // relation's echo, a timeout of the confirming hour, a misshapen control,
    // and a wayward record at the gate are all observed, and the exact
    // relation falleth with the wayward among them.

    // MARK: - the small measures the court keeps itself

    private fun kindOf(type: BleRecordType): Int = type.typeCode.toInt() and 0xFF

    private fun ringHas(transport: BleTransport, needle: String): Boolean =
        transport.rejectionRecordsForTest().any {
            it.site.contains(needle) || it.reason.contains(needle)
        }

    private fun violationSeen(transport: BleTransport, kind: HandshakeDispatchViolation): Boolean =
        transport.dispatchViolationsForTest().any { it.kind == kind }

    // MARK: - the initiators ear, grafted onto the rig

    /** Attach the initiators received() stream to the rig, so that an
     *  inbound, sealed key-confirmation control may be opened and consumed
     *  by D2 at the initiators hand - and so that the court may witness
     *  that a control is NEVER forwarded to the application. The warm-up
     *  proves the ear is awake before any count of what it heareth. */
    private fun warmAliceStream(rig: Rig) {
        val sentinel = ByteArray(1) { 0x77 }
        for (attempt in 0 until 400) {
            val before = rig.collectedIn.size
            val verdict = kotlinx.coroutines.runBlocking {
                rig.bob.send(rig.keyAtResponder(), sentinel)
            }
            if (verdict == TransportResult.Admitted) {
                val captured = awaitUntilCount("the sentinel found no responders outlet") {
                    rig.bobOutlet.notificationsTo(rig.aliceAddress)
                }
                rig.pushToInitiator(captured)
                if (awaitShort { rig.collectedIn.size > before }) {
                    rig.collectedIn.clear()
                    rig.bobOutlet.clear()
                    return
                }
            }
            Thread.sleep(5)
        }
        error("the initiators received() stream never woke for the sentinel")
    }

    // MARK: - case the first: the half-spoken exchange falleth at the hour

    @Test
    fun testTheHalfSpokenExchangeFallethAtTheTenSecondHour() {
        val rig = standDoor()
        assertEquals("the begin must stand", TransportResult.Admitted,
                     beginOn(rig, rig.pair.bob.nodeHint))
        val base = rigNow
        rigNow = base + 11
        rig.pushToInitiator(listOf(ByteArray(8) { 0 }))       // an idle breath at the gate
        awaitUntil("the stalled, half-spoken exchange must perish") {
            rig.alice.centralDriver.getActiveConnection(rig.bobAddress) == null
        }
        assertTrue("the owners hand must mark the hour as spent",
                   violationSeen(rig.alice, HandshakeDispatchViolation.HANDSHAKE_DEADLINE_LAPSED))
        assertTrue("the fall must ring its reason",
                   ringHas(rig.alice, "handshake deadline lapsed"))
        assertNotNull("the responders seat is none the wiser for the fall",
                      rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        rig.stop()
    }

    // MARK: - case the second: an idle, unspoken seat abideth the hour

    @Test
    fun testAnUnspokenSeatAbidethTheHourUnmoved() {
        val rig = standDoor()                                  // responder at ROLE_BOUND, never engaged
        val conn = rig.responderConnection()
        assertFalse("a seat that heareth no counsel is not half-spoken", conn.handshakeEngaged)
        val base = rigNow
        rigNow = base + 11
        rig.pushToResponder(frameData(7, ByteArray(8) { 0x33 }))   // a benign breath at the gate
        assertNotNull("an idle seat is not a half-spoken exchange; it abideth",
                      rig.bob.serverDriver.getInboundConnection(rig.aliceAddress))
        assertFalse("the deadline may not fire upon an unengaged seat",
                    violationSeen(rig.bob, HandshakeDispatchViolation.HANDSHAKE_DEADLINE_LAPSED))
        assertFalse("the hour was never mark'd spent upon a silent gate",
                    conn.handshakeDeadline.hasFiredForTest())
        rig.stop()
    }

    // MARK: - case the third: a travelling reassembly is left to the lease

    @Test
    fun testATravellingReassemblyIsLeftUntoTheLeaseNotReapedByTheHour() {
        val rig = standDoor()
        assertEquals("the begin must stand", TransportResult.Admitted,
                     beginOn(rig, rig.pair.bob.nodeHint))
        val hs1 = awaitUntilCount("hs1 must reach the outlet") {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        rig.aliceOutlet.clear()
        rig.pushToResponder(hs1)
        awaitUntil("the responder must be half-spoken") {
            rig.responderConnection().state == BleConnectionState.HANDSHAKE_IN_PROGRESS
        }
        val stalled = rig.responderConnection()               // held: it outliveth its own removal
        // begin a counsel of the third that shall travel apace, past the hour
        val faring = forge(BleRecordType.HS3, 33, ByteArray(300) { (it % 251).toByte() })
        rig.pushToResponder(listOf(faring[0]))                // the first fragment: afoot
        assertEquals("a counsel must be in flight", 1, stalled.leaseCountForTest())
        val base = rigNow
        rigNow = base + 11                                      // past the ten-second hour...
        rig.pushToResponder(listOf(faring[1]))                // ...yet the second fragment cometh home
        assertFalse("the hour may not reap a reassembly the lease doth govern",
                    violationSeen(rig.bob, HandshakeDispatchViolation.HANDSHAKE_DEADLINE_LAPSED))
        assertFalse("the hour was never mark'd spent while a counsel travelled",
                    stalled.handshakeDeadline.hasFiredForTest())
        rig.stop()
    }

    // MARK: - case the fourth: the second counsel rehearsed runneth not the gate

    @Test
    fun testTheDuplicateSecondTaleRunnethNotTheControllerTwice() {
        val rig = standDoor()
        val hs2 = driveToReady(rig)                            // initiator READY, the second remembred
        val conn = rig.initiatorConnection()
        assertEquals("the initiator standeth ready", BleConnectionState.READY, conn.state)
        val secondSeq = seqOfFragment(hs2[0])
        val secondTale = payloadOfFragment(hs2[0])
        val writesBefore = rig.aliceOutlet.writesTo(rig.bobAddress).size
        val heardBefore = conn.transcript.heardCountForTest(kindOf(BleRecordType.HS2))
        // the selfsame frame, byte for byte and sequence for sequence, again
        rig.alice.feedInitiatorHandshakeRecordForTest(
            rig.bobAddress, BleReassembledRecord(BleRecordType.HS2, secondSeq, secondTale))
        assertEquals("an idle re-presenting is hearkened not; the gate standeth ready",
                     BleConnectionState.READY, conn.state)
        assertEquals("no second third goeth forth for a tale twice told",
                     writesBefore, rig.aliceOutlet.writesTo(rig.bobAddress).size)
        assertEquals("the tale was but once remembred",
                     heardBefore, conn.transcript.heardCountForTest(kindOf(BleRecordType.HS2)))
        assertTrue("the door rang that the duplicate was hearkened",
                   ringHas(rig.alice, "hs2 duplicate hearkened not"))
        rig.stop()
    }

    // MARK: - case the fifth: the exact duplicate is spared, the fresh sequence perisheth

    @Test
    fun testTheExactDuplicateIsSparedTheFreshSequencePerisheth() {
        val rig = standDoor()
        assertEquals("the begin must stand", TransportResult.Admitted,
                     beginOn(rig, rig.pair.bob.nodeHint))
        val hs1 = awaitUntilCount("hs1 must reach the outlet") {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        rig.aliceOutlet.clear()
        rig.pushToResponder(hs1)
        awaitUntil("the responder must be half-spoken") {
            rig.responderConnection().state == BleConnectionState.HANDSHAKE_IN_PROGRESS
        }
        val firstSeq = seqOfFragment(hs1[0])
        val firstTale = payloadOfFragment(hs1[0])
        val conn = rig.responderConnection()
        // (a) the selfsame first counsel, byte and sequence alike, is hearkened not
        rig.bob.feedResponderHandshakeRecordForTest(
            rig.aliceAddress, BleReassembledRecord(BleRecordType.HS1, firstSeq, firstTale))
        assertEquals("the exact duplicate is hearkened not; the half-spoken stand remaineth",
                     BleConnectionState.HANDSHAKE_IN_PROGRESS, conn.state)
        assertEquals("the tale was but once remembred",
                     1, conn.transcript.heardCountForTest(kindOf(BleRecordType.HS1)))
        assertTrue("the door rang that the duplicate was hearkened",
                   ringHas(rig.bob, "hs1 duplicate hearkened not"))
        // (b) a fresh sequence bearing the selfsame tale is a conflicting counsel
        rig.bob.feedResponderHandshakeRecordForTest(
            rig.aliceAddress, BleReassembledRecord(BleRecordType.HS1, (firstSeq + 1) and 0xFF, firstTale))
        awaitUntil("the fresh-sequence re-telling must be fated") {
            rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null
        }
        assertTrue("the gate rang the stage at which the counsel was too late",
                   ringHas(rig.bob, "hs1 at stage"))
        rig.stop()
    }

    // MARK: - case the sixth: the trusted hour alone publisheth no readiness

    @Test
    fun testTheTrustedHourAlonePublishethNoApplicationReadiness() {
        val rig = standDoor()
        driveToReady(rig)                                      // both sides at trusted crypto READY
        assertEquals("the initiators crypto must be ready",
                     BleConnectionState.READY, rig.initiatorConnection().state)
        assertFalse("the trusted hour is not yet the key confirmed",
                    rig.initiatorConnection().isKeyConfirmed)
        assertTrue("no application readiness may be published before the sealed round",
                   rig.alice.linkReadyPeersForTest().isEmpty())
        assertTrue("nor at the responder may it be published",
                   rig.bob.linkReadyPeersForTest().isEmpty())
        rig.stop()
    }

    // MARK: - case the seventh: the sealed round carrieth to readiness

    @Test
    fun testTheSealedRoundCarriethToApplicationReadinessOnce() {
        val rig = standDoor()
        driveToReady(rig)
        warmAliceStream(rig)                                   // attach the initiators ear for control
        val challenge = ByteArray(16) { (it + 0x31).toByte() }
        rig.aliceOutlet.clear()
        assertEquals("the challenge must go forth", TransportResult.Admitted,
                     rig.alice.beginKeyConfirmation(rig.peerIdTowardsBob(), challenge))
        val ping = awaitUntilCount("the challenge must reach the responders ear") {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        rig.aliceOutlet.clear()
        rig.pushToResponder(ping)                              // the responder heareth, and answereth
        val echo = awaitUntilCount("the answer must reach the initiators ear") {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.bobOutlet.clear()
        rig.pushToInitiator(echo)                              // the initiators D2 heareth the echo
        val conn = rig.initiatorConnection()
        awaitUntil("the key must be confirmed upon the matching echo") { conn.isKeyConfirmed }
        awaitUntil("application readiness must be published once") {
            rig.alice.linkReadyPeersForTest().isNotEmpty()
        }
        assertEquals("the application must not be told of the control itself",
                     0, rig.collectedIn.size)                 // the control is never forwarded
        rig.stop()
    }

    // MARK: - case the eighth: the publication is idempotent

    @Test
    fun testThePublicationIsIdempotentAndTheEchoSingleShotten() {
        val rig = standDoor()
        driveToReady(rig)
        warmAliceStream(rig)
        val challenge = ByteArray(16) { (it + 0x11).toByte() }
        rig.aliceOutlet.clear()
        assertEquals("the challenge must go forth", TransportResult.Admitted,
                     rig.alice.beginKeyConfirmation(rig.peerIdTowardsBob(), challenge))
        val ping = awaitUntilCount("the challenge must reach the responders ear") {
            rig.aliceOutlet.writesTo(rig.bobAddress)
        }
        rig.aliceOutlet.clear()
        rig.pushToResponder(ping)
        val echo = awaitUntilCount("the answer must reach the initiators ear") {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.bobOutlet.clear()
        rig.pushToInitiator(echo)
        val conn = rig.initiatorConnection()
        awaitUntil("the key must be confirmed") { conn.isKeyConfirmed }
        awaitUntil("readiness must be published") { rig.alice.linkReadyPeersForTest().isNotEmpty() }
        assertEquals("published but once", 1, rig.alice.linkReadyPeersForTest().size)
        // the selfsame echo, flung again at a confirmed gate, addeth nothing
        rig.pushToInitiator(echo)
        Thread.sleep(40)
        assertEquals("the gate publisheth readiness once and once only",
                     1, rig.alice.linkReadyPeersForTest().size)
        rig.stop()
    }

    // MARK: - case the ninth: a forged echo is refused

    @Test
    fun testAForgedEchoIsRefusedAndPublishethNothing() {
        val rig = standDoor()
        driveToReady(rig)
        warmAliceStream(rig)
        val challenge = ByteArray(16) { (it + 0x51).toByte() }
        assertEquals("the challenge must go forth", TransportResult.Admitted,
                     rig.alice.beginKeyConfirmation(rig.peerIdTowardsBob(), challenge))
        // a forged answer, bearing a tale that was never the challenge
        val forged = ByteArray(16) { (it + 0x51 + 7).toByte() }
        val frame = KeyConfirmationControl.encodeResponse(forged)
        assertEquals("the forged frame must go forth upon the wire", TransportResult.Admitted,
                     rig.bob.transmitKeyConfirmationControlForTest(rig.keyAtResponder(), frame))
        val inbound = awaitUntilCount("the forged echo must reach the initiators ear") {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.bobOutlet.clear()
        rig.pushToInitiator(inbound)
        Thread.sleep(50)
        assertFalse("a forged echo confirmeth nothing", rig.initiatorConnection().isKeyConfirmed)
        assertTrue("a forged echo must be observed as a wayward record",
                   violationSeen(rig.alice, HandshakeDispatchViolation.FORGED_OR_STALE_ECHO))
        assertTrue("no readiness may follow a forged echo",
                   rig.alice.linkReadyPeersForTest().isEmpty())
        assertEquals("the application must not be told of the forged control",
                     0, rig.collectedIn.size)
        rig.stop()
    }

    // MARK: - case the tenth: a reflected challenge is not answered

    @Test
    fun testAReflectedChallengeIsNotEchoedAgain() {
        val rig = standDoor()
        driveToReady(rig)
        warmAliceStream(rig)
        val challenge = ByteArray(16) { (it + 0x21).toByte() }
        assertEquals("the challenge must go forth", TransportResult.Admitted,
                     rig.alice.beginKeyConfirmation(rig.peerIdTowardsBob(), challenge))
        // the network reflecteth the very challenge back as a challenge
        val reflected = KeyConfirmationControl.encodeChallenge(challenge)
        assertEquals("the reflection must go forth upon the wire", TransportResult.Admitted,
                     rig.bob.transmitKeyConfirmationControlForTest(rig.keyAtResponder(), reflected))
        val inbound = awaitUntilCount("the reflection must reach the initiators ear") {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.bobOutlet.clear()
        rig.pushToInitiator(inbound)
        Thread.sleep(50)
        assertFalse("a reflection confirmeth nothing", rig.initiatorConnection().isKeyConfirmed)
        assertTrue("a reflection must be observed as a wayward record",
                   violationSeen(rig.alice, HandshakeDispatchViolation.REFLECTED_CHALLENGE))
        assertTrue("no readiness may follow a reflection",
                   rig.alice.linkReadyPeersForTest().isEmpty())
        rig.stop()
    }

    // MARK: - case the eleventh: a wayward counsel at the gate is observed and closed

    @Test
    fun testAWaywardCounselAtTheGateIsObservedAndClosed() {
        val rig = standDoor()
        driveToReady(rig)                                      // responder at trusted READY
        val waywardPeer = rig.responderConnection().peerId     // the peers id, for the slot query
        // a first counsel, quite out of season, flung at the ready gate
        rig.pushToResponder(forge(BleRecordType.HS1, 41, ByteArray(32) { 0x11 }))
        awaitUntil("the ready gate must fate the wayward counsel") {
            rig.bob.serverDriver.getInboundConnection(rig.aliceAddress) == null
        }
        assertTrue("the wayward counsel must be observed as a wayward record",
                   violationSeen(rig.bob, HandshakeDispatchViolation.UNSOLICITED_HS_AFTER_READY))
        assertTrue("the gate rang its reason",
                   ringHas(rig.bob, "unexpected stage") || ringHas(rig.bob, "at stage"))
        assertFalse("the responder slot must not be left standing ready",
                    rig.pair.smB.isReady(waywardPeer))
        rig.stop()
    }

    // MARK: - case the twelfth: a misshapen control is taken for ordinary matter

    @Test
    fun testAMisshapenControlIsTakenForOrdinaryMatter() {
        val rig = standDoor()
        driveToReady(rig)
        warmAliceStream(rig)
        val conn = rig.initiatorConnection()
        // a frame that looketh near a control yet fail its strict shape (17 octets, not 18)
        val misshapen = ByteArray(17) { (it + 3).toByte() }
        assertEquals("the misshapen frame must go forth upon the wire", TransportResult.Admitted,
                     rig.bob.transmitKeyConfirmationControlForTest(rig.keyAtResponder(), misshapen))
        val inbound = awaitUntilCount("the misshapen frame must reach the initiators ear") {
            rig.bobOutlet.notificationsTo(rig.aliceAddress)
        }
        rig.bobOutlet.clear()
        rig.pushToInitiator(inbound)
        awaitUntil("the misshapen frame must be taken for ordinary matter") { rig.collectedIn.isNotEmpty() }
        assertFalse("a misshapen control confirmeth nothing", conn.isKeyConfirmed)
        assertTrue("no readiness may follow a misshapen control",
                   rig.alice.linkReadyPeersForTest().isEmpty())
        rig.stop()
    }

    // MARK: - case the thirteenth: the confirming hour runneth out unanswered

    @Test
    fun testTheConfirmingHourUnansweredFellethTheRelation() {
        val rig = standDoor()
        driveToReady(rig)
        val challenge = ByteArray(16) { (it + 0x61).toByte() }
        assertEquals("the challenge must go forth", TransportResult.Admitted,
                     rig.alice.beginKeyConfirmation(rig.peerIdTowardsBob(), challenge))
        assertTrue("the round must await its echo",
                   rig.initiatorConnection().keyConfirmation.isAwaitingEcho())
        val base = rigNow
        rigNow = base + 31                                     // past the half-minute confirming hour
        rig.pushToInitiator(listOf(ByteArray(8) { 0 }))       // an idle breath at the gate
        awaitUntil("the unanswered round must fate the relation") {
            rig.alice.centralDriver.getActiveConnection(rig.bobAddress) == null
        }
        assertTrue("the timeout of the confirming hour must be observed",
                   violationSeen(rig.alice, HandshakeDispatchViolation.KEY_CONFIRMATION_DEADLINE_LAPSED))
        assertTrue("no readiness may be published upon an unanswered round",
                   rig.alice.linkReadyPeersForTest().isEmpty())
        rig.stop()
    }

    // MARK: - case the fourteenth: one-sided readiness publisheth nothing

    @Test
    fun testOneSidedReadinessPublishethNoMatter() {
        val rig = standDoor()
        rig.aliceOutlet.clear(); rig.bobOutlet.clear()
        assertEquals("the begin must stand", TransportResult.Admitted,
                     beginOn(rig, rig.pair.bob.nodeHint))
        val hs1 = awaitUntilCount("hs1") { rig.aliceOutlet.writesTo(rig.bobAddress) }
        rig.aliceOutlet.clear()
        rig.pushToResponder(hs1)
        val hs2 = awaitUntilCount("hs2") { rig.bobOutlet.notificationsTo(rig.aliceAddress) }
        rig.bobOutlet.clear()
        rig.pushToInitiator(hs2)                               // the initiator heareth the second...
        val hs3 = awaitUntilCount("hs3") { rig.aliceOutlet.writesTo(rig.bobAddress) }
        rig.aliceOutlet.clear()
        // ...but the third is withholden from the responder: a one-sided hour
        awaitUntil("the initiator standeth ready upon its own third") {
            rig.initiatorConnection().state == BleConnectionState.READY
        }
        assertEquals("the responder is not yet come to its hour",
                     BleConnectionState.HANDSHAKE_IN_PROGRESS, rig.responderConnection().state)
        assertTrue("neither side may publish readiness of the others trust",
                   rig.alice.linkReadyPeersForTest().isEmpty() && rig.bob.linkReadyPeersForTest().isEmpty())
        assertTrue("no application matter may be inferred from a one-sided hour",
                   rig.collectedIn.isEmpty())
        // now let the third come home, and the hour be whole
        rig.pushToResponder(hs3)
        awaitBothReady(rig)
        rig.stop()
    }

    // MARK: - case the fifteenth: a fresh course, with fresh keys

    @Test
    fun testAFreshCourseWithFreshKeysReestablishethTrust() {
        val fallen = standDoor()
        assertEquals("the begin must stand", TransportResult.Admitted,
                     beginOn(fallen, fallen.pair.bob.nodeHint))
        val base = rigNow
        rigNow = base + 11
        fallen.pushToInitiator(listOf(ByteArray(8) { 0 }))    // the half-spoken perisheth at the hour
        awaitUntil("the first course must perish") {
            fallen.alice.centralDriver.getActiveConnection(fallen.bobAddress) == null
        }
        fallen.stop()
        // a fresh course, a fresh pair, fresh keys
        val risen = rig()
        risen.bringUpInitiatorLadder()
        risen.bringUpResponderLadder()
        val freshInitiator = risen.initiatorConnection()
        assertTrue("a fresh relation beginneth with an empty memory",
                   freshInitiator.transcript.isEmptyForTest())
        assertFalse("a fresh relation beginneth unengaged", freshInitiator.handshakeEngaged)
        assertTrue("a fresh relation beginneth with an unissued challenge",
                   freshInitiator.keyConfirmation.outstanding() == null)
        risen.completeHandshake()
        awaitBothReady(risen)
        assertTrue("the fresh keys must establish the peers trust",
                   risen.pair.smA.isReady(risen.initiatorConnection().peerId) &&
                   risen.pair.smB.isReady(risen.responderConnection().peerId))
        assertTrue("the fresh course must re-member the counsel it heareth",
                   risen.initiatorConnection().transcript.heardCountForTest(kindOf(BleRecordType.HS2)) >= 1)
        risen.stop()
    }
}
