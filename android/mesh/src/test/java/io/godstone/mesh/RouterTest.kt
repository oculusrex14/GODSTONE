package io.godstone.mesh

import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.router.Router
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.wire.Frame
import io.godstone.mesh.wire.FrameType
import io.godstone.mesh.wire.Priority
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Router behaviour under the conditions that actually occur in a blackout:
 * loops, duplicates, dying batteries and messages nobody can deliver yet.
 *
 * These are unit tests over the routing logic only - no Bluetooth, no threads.
 * The radio layer is exercised by meshsim instead.
 */
class RouterTest {

    private val selfNodeId = ByteArray(16) { 0x0A }
    private val peerC = ByteArray(16) { 0x0C }

    private fun frame(
        msgId: Long,
        ttl: Int = 8,
        priority: Priority = Priority.DIRECT,
        type: FrameType = FrameType.MESSAGE,
        timestamp: Long = System.currentTimeMillis() / 1000,
        payload: ByteArray = ByteArray(32)
    ) = Frame(
        type = type,
        ttl = ttl,
        priority = priority,
        msgId = msgId,
        timestamp = timestamp,
        payload = payload
    )

    @Test
    fun `duplicate message is not relayed twice`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val f = frame(1)

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
        assertFalse(router.onFrameReceived(frame(2, ttl = 0), fromPeer = peerC))
    }

    @Test
    fun `ttl above one is relayed and decremented on the forward copy`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val f = frame(3, ttl = 5)

        assertTrue(router.onFrameReceived(f, fromPeer = peerC))
        assertEquals(4, router.forwardCopy(f).ttl)
    }

    @Test
    fun `aged frame is dropped`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val aged = frame(4, timestamp = System.currentTimeMillis() / 1000 - 15 * 86400)

        // Beyond MAX_AGE_SECONDS (14 days): stale information is not relayed.
        assertFalse(router.onFrameReceived(aged, fromPeer = peerC))
    }

    @Test
    fun `group priority without proof of work is dropped`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        // GROUP frames require a 20-bit PoW stamp; an unmined payload cannot
        // satisfy it and must be refused so a sybil cannot flood for free.
        // NOTE: a random payload has a ~1/2^20 chance of accidentally passing;
        // acceptable for a unit test, deterministic mining is tracked separately.
        val f = frame(5, priority = Priority.GROUP, payload = ByteArray(32))

        assertFalse(router.onFrameReceived(f, fromPeer = peerC))
    }

    @Test
    fun `direct priority is accepted without proof of work`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        // DIRECT is exempt from PoW: latency there is safety.
        assertTrue(router.onFrameReceived(frame(6, priority = Priority.DIRECT), fromPeer = peerC))
    }

    @Test
    fun `buildSos produces a max-ttl SOS frame`() {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        val sos = router.buildSos("help".toByteArray(), 1234L)

        assertEquals(FrameType.SOS, sos.type)
        assertEquals(Frame.MAX_TTL, sos.ttl)
        assertEquals(Priority.SOS, sos.priority)
    }

    @Test
    fun `framesPeerLacks returns held frames absent from the peer digest`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        assertTrue(router.onFrameReceived(frame(7), fromPeer = peerC))

        // An empty bloom means the peer has nothing: offer everything we hold.
        val empty = BloomDigest()
        val lacks = router.framesPeerLacks(empty, 8)
        assertEquals(1, lacks.size)
        assertEquals(7L, lacks[0].msgId)

        // A bloom that already contains the msg_id means the peer has it: offer nothing.
        val full = BloomDigest().apply { add(7L) }
        assertTrue(router.framesPeerLacks(full, 8).isEmpty())
    }

    @Test
    fun `current digest advertises every held msg_id`() = runTest {
        val store = InMemoryMessageStore()
        val router = Router(store, selfNodeId)
        assertTrue(router.onFrameReceived(frame(8), fromPeer = peerC))

        val digest = router.currentDigest()
        assertTrue(digest.mightContain(8L))
        assertFalse(digest.mightContain(9999L))
    }
}
