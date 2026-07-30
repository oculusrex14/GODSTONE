package io.godstone.mesh

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

    private fun frame(
        id: String,
        ttl: Int = 8,
        dest: ByteArray = PEER_B,
        payload: ByteArray = ByteArray(32)
    ) = Frame(
        messageId = id.toByteArray().copyOf(16),
        destination = dest,
        ttl = ttl,
        payload = payload
    )

    @Test
    fun `duplicate message is not relayed twice`() {
        val router = Router(selfKey = PEER_A)
        val f = frame("msg-1")

        assertTrue(router.onReceive(f, from = PEER_C).shouldRelay)
        // Same id arriving from a different neighbour is the flood coming back
        // around. Relaying it again is how a mesh melts down.
        assertFalse(router.onReceive(f, from = PEER_D).shouldRelay)
    }

    @Test
    fun `ttl is decremented on relay`() {
        val router = Router(selfKey = PEER_A)
        val result = router.onReceive(frame("msg-2", ttl = 5), from = PEER_C)

        assertTrue(result.shouldRelay)
        assertEquals(4, result.frame!!.ttl)
    }

    @Test
    fun `frame with exhausted ttl is dropped`() {
        val router = Router(selfKey = PEER_A)
        assertFalse(router.onReceive(frame("msg-3", ttl = 0), from = PEER_C).shouldRelay)
    }

    @Test
    fun `frame addressed to self is delivered and not relayed`() {
        val router = Router(selfKey = PEER_A)
        val result = router.onReceive(frame("msg-4", dest = PEER_A), from = PEER_C)

        assertTrue(result.shouldDeliver)
        assertFalse(result.shouldRelay)
    }

    @Test
    fun `broadcast is both delivered and relayed`() {
        val router = Router(selfKey = PEER_A)
        val result = router.onReceive(frame("msg-5", dest = BROADCAST), from = PEER_C)

        assertTrue(result.shouldDeliver)
        assertTrue(result.shouldRelay)
    }

    @Test
    fun `seen cache evicts oldest entries and stays bounded`() {
        val router = Router(selfKey = PEER_A, seenCapacity = 4)

        repeat(6) { router.onReceive(frame("msg-cap-$it"), from = PEER_C) }

        // The two oldest have been evicted, so they look new again. That is
        // acceptable: a bounded cache is mandatory on a device with 3 GB of RAM,
        // and a rare re-relay is far cheaper than an unbounded set.
        assertTrue(router.onReceive(frame("msg-cap-0"), from = PEER_C).shouldRelay)
        assertFalse(router.onReceive(frame("msg-cap-5"), from = PEER_C).shouldRelay)
    }

    @Test
    fun `undeliverable message is queued for later`() {
        val router = Router(selfKey = PEER_A)
        router.send(frame("msg-6", dest = PEER_E))

        assertEquals(1, router.pendingCount)

        // PEER_E walks into range. Store-and-forward is the entire point of the
        // mesh: the two people are rarely in range at the same moment.
        val flushed = router.onPeerAvailable(PEER_E)
        assertEquals(1, flushed.size)
        assertEquals(0, router.pendingCount)
    }

    @Test
    fun `pending queue drops oldest when full rather than refusing new messages`() {
        val router = Router(selfKey = PEER_A, pendingCapacity = 3)

        repeat(5) { router.send(frame("msg-q-$it", dest = PEER_E)) }

        assertEquals(3, router.pendingCount)
        val flushed = router.onPeerAvailable(PEER_E)
        // The three most recent survive. Recent information is more useful than
        // stale information in an emergency.
        assertEquals(listOf("msg-q-2", "msg-q-3", "msg-q-4"),
                     flushed.map { String(it.messageId).trimEnd('\u0000') })
    }

    @Test
    fun `relay is suppressed when battery is critical`() {
        val router = Router(selfKey = PEER_A)
        router.onBatteryLevelChanged(0.04f, charging = false)

        // Constraint C4. Below 5 percent the node stops relaying other people's
        // traffic but still delivers its own and still receives - it becomes a
        // leaf, not a corpse.
        val result = router.onReceive(frame("msg-7"), from = PEER_C)
        assertFalse(result.shouldRelay)

        val mine = router.onReceive(frame("msg-8", dest = PEER_A), from = PEER_C)
        assertTrue(mine.shouldDeliver)
    }

    @Test
    fun `relay resumes when charging even at low battery`() {
        val router = Router(selfKey = PEER_A)
        router.onBatteryLevelChanged(0.04f, charging = true)

        assertTrue(router.onReceive(frame("msg-9"), from = PEER_C).shouldRelay)
    }

    private companion object {
        val PEER_A = ByteArray(32) { 0x0A }
        val PEER_B = ByteArray(32) { 0x0B }
        val PEER_C = ByteArray(32) { 0x0C }
        val PEER_D = ByteArray(32) { 0x0D }
        val PEER_E = ByteArray(32) { 0x0E }
        val BROADCAST = ByteArray(32) { 0xFF.toByte() }
    }
}
