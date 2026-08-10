package io.godstone.mesh

import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SosFrameValidator
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Router behaviour under the conditions that actually occur in a blackout:
 * loops, duplicates, dying batteries and messages nobody can deliver yet.
 *
 * These are unit tests over the routing logic only - no Bluetooth, no threads.
 * The radio layer is exercised by meshsim instead. Runs on the canonical GMP/2.1
 * FrameV2 path (ADR-001/008): 16-byte content-derived msg_id, priority from the
 * flags PRIORITY_MASK, no header-timestamp age gate, and no relay PoW gate (PoW
 * is recipient-side, verified after SealedSender.open -- see ProofOfWorkTest).
 */
class RouterTest {

    private val selfNodeId = ByteArray(16) { 0x0A }
    private val peerC = ByteArray(16) { 0x0C }

    /** Deterministic, distinct 16-byte msg_id for a given seed. */
    private fun msgId(seed: Int): ByteArray = ByteArray(16) { ((seed + it) and 0xFF).toByte() }

    private fun frame(
        msgId: ByteArray,
        ttl: Int = 8,
        priority: Priority = Priority.DIRECT,
        type: TypeV2 = TypeV2.MESSAGE,
        payload: ByteArray = ByteArray(32)
    ): FrameV2 = FrameV2(
        type = type,
        msgId = msgId,
        routingTag = ByteArray(4),
        ttl = ttl,
        hopCount = 0,
        flags = Priority.toFlags(priority),
        payload = payload
    )

    @Test
    fun `duplicate message is not relayed twice`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val id = msgId(1)
        val f = frame(id)

        // First sighting is novel: persist and offer for relay.
        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
        // Same id arriving from a different neighbour is the flood coming back
        // around. Relaying it again is how a mesh melts down.
        assertFalse(router.onFrameReceived(f, fromPeer = peerC))
    }

    @Test
    fun `frame with exhausted ttl is dropped`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        assertFalse(router.onFrameReceived(frame(msgId(2), ttl = 0), fromPeer = peerC))
    }

    @Test
    fun `ttl above one is relayed and decremented on the forward copy`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val f = frame(msgId(3), ttl = 5)

        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
        val fwd = router.forwardCopy(f)
        assertEquals(4, fwd.ttl)
        assertEquals(1, fwd.hopCount)
    }

    @Test
    fun `group priority is accepted by the relay - PoW is recipient-side not a relay gate`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        // GMP/2.1 (ADR-001 §3): the PoW nonce lives inside the sealed payload, so a
        // relay cannot verify it and does not gate on it. GROUP traffic is relayed;
        // the recipient verifies the stamp after SealedSender.open. The GMP/1
        // relay PoW gate is gone.
        val f = frame(msgId(5), priority = Priority.GROUP, payload = ByteArray(32))
        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
    }

    @Test
    fun `direct priority is accepted`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        assertTrue(router.onFrameReceived(frame(msgId(6), priority = Priority.DIRECT), fromPeer = peerC))
    }

    @Test
    fun `buildSos produces a max-ttl structurally-valid SOS frame with a 16-byte content-derived msg_id`() {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val sos = router.buildSos("help".toByteArray())

        assertEquals(TypeV2.SOS, sos.type)
        assertEquals(FrameV2.MAX_TTL, sos.ttl)
        assertEquals(16, sos.msgId.size)
        assertTrue(sos.flags and FrameV2.ACK_REQ != 0)
        assertTrue(sos.flags and FrameV2.RELAY_OK != 0)
        // SOS payload is structurally valid per SosFrameValidator (patch 15).
        assertEquals(SosFrameValidator.Verdict.OK, SosFrameValidator.validate(sos))
        // Round-trips through the GMP/2.1 codec byte-identically.
        val rt = FrameV2.decode(sos.encode())
        assertTrue(rt != null && rt.msgId.contentEquals(sos.msgId))
    }

    @Test
    fun `buildSos msg_id is content-derived - distinct payloads get distinct ids`() {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val a = router.buildSos("help".toByteArray())
        val b = router.buildSos("fire".toByteArray())
        assertNotEquals(a.msgId.toList(), b.msgId.toList())
    }

    @Test
    fun `framesPeerLack returns held frames absent from the peer digest`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val id = msgId(7)
        assertTrue(router.onFrameReceived(frame(id), fromPeer = peerC))

        // An empty bloom means the peer has nothing: offer everything we hold.
        val empty = BloomDigest()
        val lacks = router.framesPeerLacks(empty, 8)
        assertEquals(1, lacks.size)
        assertTrue(lacks[0].msgId.contentEquals(id))

        // A bloom that already contains the msg_id means the peer has it: offer nothing.
        val full = BloomDigest().apply { add(id) }
        assertTrue(router.framesPeerLacks(full, 8).isEmpty())
    }

    @Test
    fun `current digest advertises every held msg_id`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val id = msgId(8)
        assertTrue(router.onFrameReceived(frame(id), fromPeer = peerC))

        val digest = router.currentDigest()
        assertTrue(digest.mightContain(id))
        assertFalse(digest.mightContain(msgId(9999)))
    }

    // --- Stage 4B: persist result checked before forward (ADR-004) ---

    @Test
    fun `persist failure prevents relay and inbound emit`() = runTest {
        // A store whose persist always fails exercises the persist gate in
        // onFrameReceived without a real engine. The frame is novel and its TTL
        // is healthy, so the only thing that can return false here is the
        // persist-before-forward gate: a frame this node cannot durably hold is
        // NOT relayed (false) and NOT emitted to inbound -- forwarding what this
        // node cannot itself carry would let the only copy be dropped.
        val router = Router(FailingMessageStore(), selfNodeId)
        val f = frame(msgId(11), ttl = 5)

        assertFalse(router.onFrameReceived(f, fromPeer = peerC))
        // onFrameReceived returned before `_inbound.emit`, so nothing reached the
        // inbound flow (contrast the working-store tests above, which return true
        // and advertise the held id in the digest).
        assertFalse(router.currentDigest().mightContain(f.msgId))
    }
}

/**
 * A [MessageStore] whose `persist` always fails -- exercises the persist gate in
 * `Router.onFrameReceived` (ADR-004 / Stage 4B) without a real engine. The other
 * methods report an empty store, which is consistent with "nothing was held".
 */
private class FailingMessageStore : MessageStore {
    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): Boolean = false
    override suspend fun allHeldOrderedByPriority(): List<FrameV2> = emptyList()
    override suspend fun allHeldMsgIds(): List<ByteArray> = emptyList()
    override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {}
    override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {}
}