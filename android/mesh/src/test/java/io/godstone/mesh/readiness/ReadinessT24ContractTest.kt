package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T24 - the contract slice's unit witnesses. These exercise, in isolation and
// upon the pure host (no radio, no Android Context), that:
//   * a TrustedPeer requireth the frozen identity widths (16 / 32) and a
//     non-negative trust version, and is equalled by CONTENT (relation, node
//     id, public key, trust version) - never by a transport handle;
//   * the ReliablePeerEventChannel is bounded and RELIABLE: it answereth
//     Backpressure rather than a silent drop, refuseth a stale owner token
//     terminally, and once fail'd terminally carrieth no more.
// ---------------------------------------------------------------------------

import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.LinkEvent
import io.godstone.mesh.transport.OfferVerdict
import io.godstone.mesh.transport.ReliablePeerEventChannel
import io.godstone.mesh.transport.RelationKey
import io.godstone.mesh.transport.TrustedPeer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ReadinessT24ContractTest {

    private fun relation(generation: Long): RelationKey =
        RelationKey(BleDirection.INBOUND, "AA:BB:CC:DD:EE:FF", generation)

    private fun bytes(size: Int, fill: Int): ByteArray = ByteArray(size) { index -> fill.toByte() }

    private fun peer(
        generation: Long,
        nodeIdFill: Int = 7,
        pubFill: Int = 9,
        trust: Long = 1L,
    ): TrustedPeer =
        TrustedPeer(relation(generation), bytes(16, nodeIdFill), bytes(32, pubFill), trust)

    @Test
    fun testATrustedPeerRequirethTheFrozenIdentityWidths() {
        val good = peer(3L)
        assertEquals("the node id is sixteen bytes", 16, good.nodeId16.size)
        assertEquals("the identity public key is thirty-two bytes", 32, good.identityPub32.size)
        assertEquals("the defensive read of the node id matcheth", 16, good.copyNodeId().size)
        assertEquals("the defensive read of the public key matcheth", 32, good.copyIdentityPub().size)

        try {
            TrustedPeer(relation(1L), bytes(15, 1), bytes(32, 2), 0L)
            fail("a fifteen-byte node id must not stand")
        } catch (expected: IllegalArgumentException) {
            assertTrue("the refusal speaketh of the node id", expected.message!!.contains("node id"))
        }

        try {
            TrustedPeer(relation(1L), bytes(16, 1), bytes(31, 2), 0L)
            fail("a thirty-one-byte identity public key must not stand")
        } catch (expected: IllegalArgumentException) {
            assertTrue("the refusal speaketh of the public key", expected.message!!.contains("public key"))
        }

        try {
            TrustedPeer(relation(1L), bytes(16, 1), bytes(32, 2), -1L)
            fail("a negative trust version must not stand")
        } catch (expected: IllegalArgumentException) {
            assertTrue("the refusal speaketh of the trust version", expected.message!!.contains("trust version"))
        }
    }

    @Test
    fun testATrustedPeerEqualsByContentNotByTheTransportHandle() {
        val a = peer(5L, nodeIdFill = 11, pubFill = 22, trust = 3L)
        val b = peer(5L, nodeIdFill = 11, pubFill = 22, trust = 3L)
        assertEquals("content-identical peers are equal", a, b)
        assertTrue("content-identical peers share a hash", a.hashCode() == b.hashCode())

        assertFalse("a differing trust version is a different peer", a == peer(5L, 11, 22, 4L))
        assertFalse("a differing node id is a different peer", a == peer(5L, 12, 22, 3L))
        assertFalse("a differing public key is a different peer", a == peer(5L, 11, 23, 3L))
        val differRelation = TrustedPeer(relation(6L), bytes(16, 11), bytes(32, 22), 3L)
        assertFalse("a differing relation is a different peer", a == differRelation)
    }

    @Test
    fun testTheBoundedChannelAnswerethWithBackpressureNotWithSilentDrop() {
        val channel = ReliablePeerEventChannel(2)
        val p = peer(1L)
        val ready = LinkEvent.LinkReady(p)
        val auth = LinkEvent.Auth(p)
        val lost = LinkEvent.LinkLost(p)

        assertEquals("the first offer is carried", OfferVerdict.Accepted, channel.offer(ready, 1L))
        assertEquals("the second offer is carried", OfferVerdict.Accepted, channel.offer(auth, 1L))
        assertEquals("a full channel answereth with backpressure", OfferVerdict.Backpressure, channel.offer(lost, 1L))
        assertEquals("nothing is silently dropped: the bound abideth", 2, channel.size)

        assertNotNull("the head is delivered in order", channel.poll())
        assertEquals("after a drain, room is won again", OfferVerdict.Accepted, channel.offer(lost, 1L))
        assertEquals("two stand again", 2, channel.size)
    }

    @Test
    fun testTheStaleOwnerTokenIsRefusedTerminally() {
        val channel = ReliablePeerEventChannel(4)
        val p = peer(7L)
        assertEquals("a matching owner token is accepted", OfferVerdict.Accepted, channel.offer(LinkEvent.Auth(p), 7L))
        assertEquals("a stale owner token is a terminal failure", OfferVerdict.TerminalFailure, channel.offer(LinkEvent.Auth(p), 6L))
        assertEquals("the stale offer left no whit behind it", 1, channel.size)
    }

    @Test
    fun testTheTerminallyFaildChannelCarriethNoMore() {
        val channel = ReliablePeerEventChannel(4)
        val p = peer(2L)
        assertEquals("pre-failure an offer is carried", OfferVerdict.Accepted, channel.offer(LinkEvent.LinkReady(p), 2L))
        channel.failTerminally()
        assertTrue("the channel is terminal", channel.isTerminal)
        assertNull("a terminal channel yieldeth nothing", channel.poll())
        assertEquals("a terminal channel refuseth offers", OfferVerdict.TerminalFailure, channel.offer(LinkEvent.LinkLost(p), 2L))
        assertEquals("a terminal channel holdeth nothing", 0, channel.size)
    }
}
