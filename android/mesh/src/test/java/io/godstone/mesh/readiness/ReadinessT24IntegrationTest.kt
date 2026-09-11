package io.godstone.mesh

// ---------------------------------------------------------------------------
// T24 - the platform/integration slice's node-level witnesses, on a real
// MeshNode in pure JVM (no Android Context, no Robolectric). These witness the
// two things the "publish only relation-bound authenticated peers" contract
// hinge upon at the node:
//   * the start sequence registereth the authoritative consumers BEFORE the
//     radio adapters are opened (the section 6 "lose authoritative events"
//     defect) -- proved through the single decision point startInOrder that
//     both production and these witnesses funnel through;
//   * the extracted consumers' bodies are sound: the peer view followeth
//     Found/Lost by content, and an inbound clear is fail-closed (an
//     undecodable clear is dropped, never ingested).
// The positive inbound decode->ingest path is behaviour-preserving extraction
// of the former collector body and is already witnessed by
// [MeshNodeDeliveryIntegrationTest]'s C7 seams.
// ---------------------------------------------------------------------------

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.ClearResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRepository
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.transport.PeerEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom

class ReadinessT24IntegrationTest {

    private val rng = SecureRandom()

    private fun identity(): Identity {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        return Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }

    /** A repository that is never exercis'd by these witnesses; any call is a bug. */
    private val deadRepo = object : DeliveryRepository {
        override fun get(msgId: ByteArray): DeliveryLookup = throw NotImplementedError("unused by these witnesses")
        override fun enqueue(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): EnqueueResult =
            throw NotImplementedError("unused by these witnesses")
        override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult =
            throw NotImplementedError("unused by these witnesses")
        override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult =
            throw NotImplementedError("unused by these witnesses")
        override fun clear(msgId: ByteArray): ClearResult = throw NotImplementedError("unused by these witnesses")
    }

    private fun node(): MeshNode = MeshNode(
        ctx = null,
        identity = identity(),
        store = InMemoryMessageStore(),
        deliveryTracker = DeliveryTracker(deadRepo, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver)),
    )

    @Test
    fun testTheStartSequenceAttachethConsumersEreTheAdaptersBeOpened() {
        val order = mutableListOf<String>()
        node().startInOrder({ order.add("attach") }, { order.add("open") })
        assertEquals(
            "the consumers must be attach'd before the adapters are open'd",
            listOf("attach", "open"),
            order,
        )
    }

    @Test
    fun testThePeerStatusFollowethFoundAndLostByContent() {
        val n = node()
        val a = ByteArray(16) { 0x11 }
        val b = ByteArray(16) { 0x22 }
        assertEquals("no peer is known at the outset", 0, n.knownPeersForTest().size)

        n.handlePeerEvent(PeerEvent.Found(a, ByteArray(4), -50, false, false, ByteArray(6), 0))
        assertEquals("a found peer entereth the view", 1, n.knownPeersForTest().size)

        n.handlePeerEvent(PeerEvent.Found(b, ByteArray(4), -60, false, false, ByteArray(6), 0))
        assertEquals("a second, distinct peer entereth the view", 2, n.knownPeersForTest().size)

        n.handlePeerEvent(PeerEvent.Found(a, ByteArray(4), -70, true, true, ByteArray(6), 3))
        assertEquals("a re-presented peer by the selfsame id addeth no whit", 2, n.knownPeersForTest().size)

        n.handlePeerEvent(PeerEvent.Lost(a))
        assertEquals("the lost peer departeth the view", 1, n.knownPeersForTest().size)

        n.handlePeerEvent(PeerEvent.Lost(b))
        assertEquals("the view is empted when all depart", 0, n.knownPeersForTest().size)
    }

    @Test
    fun testTheInboundClearIsFailClosedUponUndecodableBytes() {
        val n = node()
        // The collector ingests onely when the decode gate yieldeth a frame; a null
        // decode is dropt. This witnesseth that gate directly (non-suspend).
        assertNull(
            "an undecodable clear yieldeth null, so naught is ingested",
            n.decodeInbound(ByteArray(3) { 0x7F }),
        )
        assertNull("empty clear bytes yield null", n.decodeInbound(ByteArray(0)))
        assertTrue("a dropt clear leaveth the peer view untouched", n.knownPeersForTest().isEmpty())
    }
}
