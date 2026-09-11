package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T24 - the integration core's boundary witnesses (android, pure host: no
// radio, no Android Context). These exercize the PeerEventPublisher against the
// cases the T24 card enumerateth, capturing the downstream side effect or its
// ABSENCE:
//   * an immediate callback during start is deliver'd to an already-listen'd sink;
//   * a stopp'd / replac'd consumer doth / doth-not receiv'e further events;
//   * a FULL channel answereth with an observ'd Backpressure verdict, is NOT
//     silently dropt, and doth NOT mark the relation publish'd (the "ignore
//     tryEmit failure" falsification);
//   * a mere handle / hint match doth NOT merge distinct relations (identity is by
//     the relation token, and a peer's identity is by its CONTENT);
//   * exactly one LinkReady and one LinkLost travel a lifecycle;
//   * a stale input cannot route under a new identity, and the forward'd peer is
//     the CAPTURED one even when a decoy handle-map is present (the "look up
//     current peer on delayed delivery" falsification).
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

class ReadinessT24PublicationTest {

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

    // The immediate callback: a sink inlistened BEFORE the first publish is
    // synchronously call'd, and receiveth the CAPTURED immutable peer.
    @Test
    fun testAnImmediateCallbackDuringStartIsDeliveredToTheInlistenSink() {
        val pub = publisher()
        val seen = mutableListOf<LinkEvent>()
        pub.addSink { event -> seen.add(event) }

        val captured = peer(1L)
        assertEquals("the offer is accepted", OfferVerdict.Accepted, pub.publishLinkReady(captured))
        assertEquals("the inlistened sink was call'd once", 1, seen.size)
        val only = seen.single()
        assertTrue("it is a LinkReady", only is LinkEvent.LinkReady)
        assertEquals("the deliver'd peer is the captured, immutable one", captured, (only as LinkEvent.LinkReady).peer)
    }

    // A stopp'd consumer receiveth no more; a replac'd (newly inlistened) one doth.
    @Test
    fun testAStoppedConsumerReceivethNoMoreAndAReplacedOneDoth() {
        val pub = publisher()
        val a = mutableListOf<LinkEvent>()
        val sinkA: (LinkEvent) -> Unit = { event -> a.add(event) }
        pub.addSink(sinkA)

        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(peer(1L)))
        assertEquals("the first sink saw the ready", 1, a.size)

        pub.removeSink(sinkA) // stop the consumer
        val b = mutableListOf<LinkEvent>()
        pub.addSink { event -> b.add(event) } // a replac'd consumer

        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(peer(2L)))
        assertEquals("the stopp'd consumer saw no more", 1, a.size)
        assertEquals("the replac'd consumer seeth the new event", 1, b.size)
    }

    // A full channel answereth with an OBSERV'D backpressure verdict, is NOT
    // silently dropt, and doth NOT mark the relation publish'd.
    @Test
    fun testAFullChannelAnswerethWithBackpressureAndIsNotSilentlyDropt() {
        val pub = publisher(capacity = 1) // a one-deep reliable conduit
        val first = peer(1L)
        assertEquals("the first offer findeth room", OfferVerdict.Accepted, pub.publishLinkReady(first))
        assertTrue("the publish'd relation is registred", pub.isReadyPublishedForTest(first.relation))

        // The conduit is now full (the first event is unconsumed); a second
        // relation's offer must meet backpressure - and MUST NOT be swallow'd.
        val second = peer(2L)
        assertEquals("a full channel answereth with backpressure", OfferVerdict.Backpressure, pub.publishLinkReady(second))
        assertFalse("a refus'd offer doth NOT mark its relation publish'd", pub.isReadyPublishedForTest(second.relation))

        // And it deliver'd nothing further: a fresh sink seeth no phantom delivery.
        val seen = mutableListOf<LinkEvent>()
        pub.addSink { event -> seen.add(event) }
        assertEquals("a further full offer is observ'd as backpressure", OfferVerdict.Backpressure, pub.publishLinkReady(peer(3L)))
        assertEquals("no delivery was made upon the refus'd offers", 0, seen.size)
    }

    // A common handle / hint match doth NOT merge distinct relations: identity is
    // the relation token, and a peer's identity is by its CONTENT.
    @Test
    fun testACommonHandleMatchDothNotMergeDistinctRelations() {
        val pub = publisher()
        val seen = mutableListOf<LinkEvent>()
        pub.addSink { event -> seen.add(event) }

        // Two peers share the SELFsame handle string, differ onely in generation
        // (distinct relations) and in node id (distinct content).
        val p1 = TrustedPeer(relationAt(handle, 1L), bytes(16, 7), bytes(32, 9), 1L)
        val p2 = TrustedPeer(relationAt(handle, 2L), bytes(16, 8), bytes(32, 9), 1L)
        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(p1))
        assertEquals(OfferVerdict.Accepted, pub.publishLinkReady(p2))

        assertEquals("both distinct relations travelled; none was merge'd by the handle", 2, seen.readyCount())
        val first = seen.first { it is LinkEvent.LinkReady } as LinkEvent.LinkReady
        val other = seen.last { it is LinkEvent.LinkReady } as LinkEvent.LinkReady
        assertTrue("the two readies carry distinct captured peers (identity is by content)", first.peer != other.peer)
    }

    // Exactly one LinkReady and one LinkLost travel a relation's lifecycle.
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

        assertEquals("onely one LinkReady was deliver'd", 1, seen.readyCount())
        assertEquals("onely one LinkLost was deliver'd", 1, seen.lostCount())
    }

    // The two faces of the "look up current peer on delayed delivery" falsification,
    // plus the stale-rotation refusals under the section-13 token algorithm.
    @Test
    fun testStaleInputCannotRouteUnderANewIdentityAndRouteUsethTheCapturedPeer() {
        val captured = peer(5L) // relation generation 5
        val decoy = TrustedPeer(captured.relation, bytes(16, 0xEE), bytes(32, 0xFF), 99L) // a live peer at the same handle

        // (a) Fresh & current: forward'd once, with the CAPTURED peer, never the
        //     decoy the handle-map would have resolv'd.
        run {
            val current = 5L
            val pub = PeerEventPublisher(ReliablePeerEventChannel(8), ownerGeneration = { _ -> current })
            val forwarded = mutableListOf<TrustedPeer>()
            val outcome = pub.route(captured, bytes(4, 1), byHandle = { _ -> decoy }) { peer, _ -> forwarded.add(peer) }
            assertEquals("a whole, current token forwardeth", RouteOutcome.Forwarded, outcome)
            assertEquals("the captured peer was forward'd once", 1, forwarded.size)
            assertEquals("the forward'd peer is the CAPTURED one, not the handle's decoy", captured, forwarded[0])
            assertFalse("the handle's decoy was never us'd for identity", forwarded[0] == decoy)
        }

        // (b) Stale at entry: the relation was rotat'd beneath the token.
        run {
            val pub = PeerEventPublisher(ReliablePeerEventChannel(8), ownerGeneration = { _ -> 6L })
            val forwarded = mutableListOf<TrustedPeer>()
            val outcome = pub.route(captured, bytes(4, 1)) { peer, _ -> forwarded.add(peer) }
            assertEquals("a stale token is refus'd at the gate", RouteOutcome.RefusedStaleIdentity, outcome)
            assertEquals("naught was forward'd for the stale input", 0, forwarded.size)
        }

        // (c) The named owner knoweth the relation no longer.
        run {
            val pub = PeerEventPublisher(ReliablePeerEventChannel(8), ownerGeneration = { _ -> null })
            val forwarded = mutableListOf<TrustedPeer>()
            val outcome = pub.route(captured, bytes(4, 1)) { peer, _ -> forwarded.add(peer) }
            assertEquals("an unknown relation is refus'd", RouteOutcome.RefusedUnknownRelation, outcome)
            assertEquals("naught was forward'd for the unknown relation", 0, forwarded.size)
        }

        // (d) Rotation upon completion: the token was whole at entry yet the
        //     relation rotat'd ere delivery complete'd - the bounded effect is
        //     schedul'd exact once, then revalidation refuseth it as a stale routing
        //     (the prior state is kept, the event is not treated as freshly forward'd).
        run {
            var calls = 0
            val pub = PeerEventPublisher(
                ReliablePeerEventChannel(8),
                ownerGeneration = { _ -> calls++; if (calls == 1) 5L else 6L },
            )
            var forwardedCount = 0
            val outcome = pub.route(captured, bytes(4, 1)) { _, _ -> forwardedCount++ }
            assertEquals("revalidation upon completion refuseth the mid-flight rotation", RouteOutcome.RefusedStaleIdentity, outcome)
            assertEquals("the effect was schedul'd exact once", 1, forwardedCount)
        }
    }
}
