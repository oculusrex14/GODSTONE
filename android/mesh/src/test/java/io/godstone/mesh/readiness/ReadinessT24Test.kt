package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T24 - the CANONICAL designated regression court (android), matching the task
// manifest's required_regression_paths (android/.../readiness/ReadinessT24Test.kt)
// and the narrow command filter `--tests *ReadinessT24Test*`. It carrieth the six
// required behavioural cases of the card, each with at least one EXECUTED
// assertion, run at the authoritative publisher-core layer (the real-adapter
// composition is the nonshipping lab path reserved to T54, per the card):
//   1. immediate callback during start;
//   2. stopped / replaced consumer;
//   3. full channel (explicit backpressure, never a silent drop);
//   4. identity-hint collision (a mere handle/hint match never merges identity);
//   5. one found / one lost per lifecycle;
//   6. stale input cannot route under a new identity (and the route forwardeth
//      the CAPTURED peer, defying a decoy handle-map).
// The suffixed courts (Contract / Integration / Publication / Capture) REMAIN as
// extended law/contract/capture coverage; this canonical file is the one the
// task's verification filter and regression-path list point to.
// ---------------------------------------------------------------------------

import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.LinkEvent
import io.godstone.mesh.transport.OfferVerdict
import io.godstone.mesh.transport.PeerEventPublisher
import io.godstone.mesh.transport.ReliablePeerEventChannel
import io.godstone.mesh.transport.RelationKey
import io.godstone.mesh.transport.RouteOutcome
import io.godstone.mesh.transport.TrustedPeer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT24Test {

    private val handle = "AA:BB:CC:DD:EE:FF"

    private fun relation(gen: Long): RelationKey = RelationKey(BleDirection.INBOUND, handle, gen)
    private fun relationAt(addr: String, gen: Long): RelationKey = RelationKey(BleDirection.INBOUND, addr, gen)
    private fun bytes(size: Int, fill: Int): ByteArray = ByteArray(size) { index -> fill.toByte() }

    private fun peer(gen: Long, nodeFill: Int = 7, pubFill: Int = 9, trust: Long = 1L): TrustedPeer =
        TrustedPeer(relation(gen), bytes(16, nodeFill), bytes(32, pubFill), trust)

    private fun publisher(capacity: Int = 64): PeerEventPublisher =
        PeerEventPublisher(ReliablePeerEventChannel(capacity))

    private inline fun List<LinkEvent>.readyCount(): Int = count { it is LinkEvent.LinkReady }
    private inline fun List<LinkEvent>.lostCount(): Int = count { it is LinkEvent.LinkLost }

    // (1) immediate callback during start
    @Test
    fun testAnImmediateCallbackDuringStartIsDeliveredToTheInlistenSink() {
        val pub = publisher()
        val seen = mutableListOf<LinkEvent>()
        pub.addSink { event -> seen.add(event) }
        val captured = peer(1L)
        assertEquals("the offer is accepted", OfferVerdict.Accepted, pub.publishLinkReady(captured))
        assertEquals("the inlistened sink was called once", 1, seen.size)
        val only = seen.single()
        assertTrue("it is a LinkReady", only is LinkEvent.LinkReady)
        assertEquals("the delivered peer is the captured, immutable one", captured, (only as LinkEvent.LinkReady).peer)
    }

    // (2) stopped / replaced consumer
    @Test
    fun testAStoppedConsumerReceivethNoMoreAndAReplacedOneDoth() {
        val pub = publisher()
        val a = mutableListOf<LinkEvent>()
        val sinkA: (LinkEvent) -> Unit = { event -> a.add(event) }
        pub.addSink(sinkA)
        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(peer(1L)))
        assertEquals("the first sink saw the ready", 1, a.size)
        pub.removeSink(sinkA)
        val b = mutableListOf<LinkEvent>()
        pub.addSink { event -> b.add(event) }
        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(peer(2L)))
        assertEquals("the stopped consumer saw no more", 1, a.size)
        assertEquals("the replaced consumer sees the new event", 1, b.size)
    }

    // (3) full channel: an observed verdict, never a silent drop, never a false mark
    @Test
    fun testAFullChannelAnswerethWithBackpressureAndIsNotSilentlyDropt() {
        val pub = publisher(capacity = 1)
        val first = peer(1L)
        assertEquals("the first offer findeth room", OfferVerdict.Accepted, pub.publishLinkReady(first))
        assertTrue("the published relation is registered", pub.isReadyPublishedForTest(first.relation))
        val second = peer(2L)
        assertEquals("a full channel answereth with backpressure", OfferVerdict.Backpressure, pub.publishLinkReady(second))
        assertFalse("a refused offer doth NOT mark its relation published", pub.isReadyPublishedForTest(second.relation))
        val seen = mutableListOf<LinkEvent>()
        pub.addSink { event -> seen.add(event) }
        assertEquals("a further full offer is observed as backpressure", OfferVerdict.Backpressure, pub.publishLinkReady(peer(3L)))
        assertEquals("no delivery was made upon the refused offers", 0, seen.size)
    }

    // (4) identity-hint collision: a common handle/hint never merges distinct identity
    @Test
    fun testACommonHandleMatchDothNotMergeDistinctRelations() {
        val pub = publisher()
        val seen = mutableListOf<LinkEvent>()
        pub.addSink { event -> seen.add(event) }
        val p1 = TrustedPeer(relationAt(handle, 1L), bytes(16, 7), bytes(32, 9), 1L)
        val p2 = TrustedPeer(relationAt(handle, 2L), bytes(16, 8), bytes(32, 9), 1L)
        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(p1))
        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(p2))
        assertEquals("both distinct relations travelled; none merged by the handle", 2, seen.readyCount())
        val first = seen.first { it is LinkEvent.LinkReady } as LinkEvent.LinkReady
        val other = seen.last { it is LinkEvent.LinkReady } as LinkEvent.LinkReady
        assertTrue("the two readies carry distinct captured peers (identity is by content)", first.peer != other.peer)
    }

    // (5) one found / one lost per lifecycle
    @Test
    fun testOneReadyAndOneLostTravelALifecycle() {
        val pub = publisher()
        val seen = mutableListOf<LinkEvent>()
        pub.addSink { event -> seen.add(event) }
        val r = 7L
        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(peer(r)))
        assertEquals("a duplicate ready is an idempotent no-op", OfferVerdict.Accepted, pub.publishLinkReady(peer(r)))
        assertEquals(OfferVerdict.Accepted, pub.publishLinkLost(peer(r)))
        assertEquals("a duplicate lost is an idempotent no-op", OfferVerdict.Accepted, pub.publishLinkLost(peer(r)))
        assertEquals("only one LinkReady was delivered", 1, seen.readyCount())
        assertEquals("only one LinkLost was delivered", 1, seen.lostCount())
    }

    // (6) stale input cannot route under a new identity; the route forwards the CAPTURED peer
    @Test
    fun testStaleInputCannotRouteUnderANewIdentityAndRouteUsethTheCapturedPeer() {
        val captured = peer(5L)
        val decoy = TrustedPeer(captured.relation, bytes(16, 0xEE), bytes(32, 0xFF), 99L)
        run {
            val current = 5L
            val pub = PeerEventPublisher(ReliablePeerEventChannel(8), ownerGeneration = { _ -> current })
            val forwarded = mutableListOf<TrustedPeer>()
            val outcome = pub.route(captured, bytes(4, 1), byHandle = { _ -> decoy }) { peer, _ -> forwarded.add(peer) }
            assertEquals("a whole, current token forwardeth", RouteOutcome.Forwarded, outcome)
            assertEquals("the captured peer was forwarded once", 1, forwarded.size)
            assertEquals("the forwarded peer is the CAPTURED one, not the handle's decoy", captured, forwarded[0])
            assertFalse("the handle's decoy was never used for identity", forwarded[0] == decoy)
        }
        run {
            val pub = PeerEventPublisher(ReliablePeerEventChannel(8), ownerGeneration = { _ -> 6L })
            val forwarded = mutableListOf<TrustedPeer>()
            val outcome = pub.route(captured, bytes(4, 1)) { peer, _ -> forwarded.add(peer) }
            assertEquals("a stale token is refused at the gate", RouteOutcome.RefusedStaleIdentity, outcome)
            assertEquals("naught was forwarded for the stale input", 0, forwarded.size)
        }
        run {
            val pub = PeerEventPublisher(ReliablePeerEventChannel(8), ownerGeneration = { _ -> null })
            val forwarded = mutableListOf<TrustedPeer>()
            val outcome = pub.route(captured, bytes(4, 1)) { peer, _ -> forwarded.add(peer) }
            assertEquals("an unknown relation is refused", RouteOutcome.RefusedUnknownRelation, outcome)
            assertEquals("naught was forwarded for the unknown relation", 0, forwarded.size)
        }
        run {
            var calls = 0
            val pub = PeerEventPublisher(ReliablePeerEventChannel(8), ownerGeneration = { _ -> calls++; if (calls == 1) 5L else 6L })
            var forwardedCount = 0
            val outcome = pub.route(captured, bytes(4, 1)) { _, _ -> forwardedCount++ }
            assertEquals("revalidation upon completion refuseth the mid-flight rotation", RouteOutcome.RefusedStaleIdentity, outcome)
            assertEquals("the effect was scheduled exact once", 1, forwardedCount)
        }
    }
}
