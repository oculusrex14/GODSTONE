package io.godstone.mesh.transport

// ---------------------------------------------------------------------------
// T24 - the integration core (android): the bounded, RELIABLE publication of
// relation-bound authenticated peers and their route under the section-13 event
// algorithm. It is the drop-in that the transport's application link-ready
// publication adopteth, SUPERSEDING the former seam that "emitted a peerId and
// ignor'd the tryEmit result":
//   * an offer's verdict is RETURNED and must be observ'd - backpressure or
//     terminal failure is never swallow'd, and a refus'd offer doth NOT mark the
//     relation publish'd nor deliver a whit (the "ignore tryEmit failure"
//     falsification);
//   * the peer that is deliver'd and route'd is the CAPTURED, immutable
//     TrustedPeer, never a handle re-look'd-up at delivery (the "look up
//     current peer on delayed delivery" falsification);
//   * exactly one LinkReady and one LinkLost travel a relation in its
//     lifecycle (a duplicate completion is an idempotent no-op).
//
// The frame-type-specific decode/bind of the received octets remaineth the
// transport's care; this boundary routeth the received thing WITH its immutable
// trusted peer, which is the law T24 fixeth here. It toucheth no frozen
// wire/LinkInfo/identity contract and observeth readiness=false.
// ---------------------------------------------------------------------------

/** The outcome of one route decision under the section-13 token algorithm. */
internal enum class RouteOutcome {
    /** The token was whole and current under the named owner; the frame was forward'd once. */
    Forwarded,

    /** The named owner knoweth the relation no longer (it is gone): refuse, prior state preserv'd. */
    RefusedUnknownRelation,

    /** The relation was rotated beneath the token (a stale input for a new identity): refuse. */
    RefusedStaleIdentity,
}

/**
 * The relation-scoped, driver-authority-gated publisher/router of authenticated
 * peer events.
 *
 * @param channel the bounded reliable conduit every publication passeth through;
 *        its verdicts are the caller's to observe, never ignor'd.
 * @param ownerGeneration the driver authority: the CURRENT generation a relation
 *        holdeth (null => the relation is gone). A real dependency seam, inject'd
 *        so a witness may simulate a mid-lifecycle rotation.
 */
internal class PeerEventPublisher(
    private val channel: ReliablePeerEventChannel,
    private val ownerGeneration: (RelationKey) -> Long? = { key -> key.generation },
) {
    private val lock = Any()
    private val sinks = mutableListOf<(LinkEvent) -> Unit>()
    // The relation identities already publish'd, so that exactly one LinkReady and
    // one LinkLost travel a relation through its lifecycle.
    private val readyPublished = mutableSetOf<RelationKey>()
    private val lostPublished = mutableSetOf<RelationKey>()

    /** Enrol a consumer sink. A sink add'd after an event is born heareth it not. */
    internal fun addSink(sink: (LinkEvent) -> Unit) = synchronized(lock) { sinks.add(sink) }

    /** Withdraw a consumer sink; a stopp'd/withdrawn sink receiveth no more. */
    internal fun removeSink(sink: (LinkEvent) -> Unit) = synchronized(lock) { sinks.remove(sink) }

    /** Witnesses only: the number of inlistened sinks. */
    internal fun sinkCountForTest(): Int = synchronized(lock) { sinks.size }

    /** Deliver to a SNAPSHOT of the sinks (the sink set is stable across delivery). */
    private fun deliver(event: LinkEvent) {
        val snapshot: List<(LinkEvent) -> Unit> = synchronized(lock) { sinks.toList() }
        for (sink in snapshot) sink(event)
    }

    /**
     * Publish exactly one LinkReady for the relation of [captured], and RETURN the
     * channel's offer verdict so the caller observeth backpressure / terminal
     * failure. A relation already publish'd once is a duplicate completion: it is
     * suppress'd idempotently (nothing is re-deliver'd). A REFUS'D offer doth NOT
     * mark the relation publish'd and delivereth nothing - the offer's failure is
     * observ'd, never swallow'd.
     */
    fun publishLinkReady(captured: TrustedPeer): OfferVerdict {
        val key = captured.relation
        val event = LinkEvent.LinkReady(captured)
        var shouldDeliver = false
        val verdict: OfferVerdict = synchronized(lock) {
            if (key in readyPublished) {
                OfferVerdict.Accepted // already publish'd once this lifecycle: idempotent no-op
            } else {
                val v = channel.offer(event, key.generation)
                if (v == OfferVerdict.Accepted) {
                    readyPublished.add(key)
                    shouldDeliver = true
                }
                v
            }
        }
        if (shouldDeliver) deliver(event)
        return verdict
    }

    /** Publish exactly one LinkLost for the relation of [captured], likewise observ'd. */
    fun publishLinkLost(captured: TrustedPeer): OfferVerdict {
        val key = captured.relation
        val event = LinkEvent.LinkLost(captured)
        var shouldDeliver = false
        val verdict: OfferVerdict = synchronized(lock) {
            if (key in lostPublished) {
                OfferVerdict.Accepted
            } else {
                val v = channel.offer(event, key.generation)
                if (v == OfferVerdict.Accepted) {
                    lostPublished.add(key)
                    shouldDeliver = true
                }
                v
            }
        }
        if (shouldDeliver) deliver(event)
        return verdict
    }

    /** Publish an Auth assertion for the relation of [captured], likewise observ'd. */
    fun publishAuth(captured: TrustedPeer): OfferVerdict {
        val key = captured.relation
        val event = LinkEvent.Auth(captured)
        var shouldDeliver = false
        val verdict: OfferVerdict = synchronized(lock) {
            val v = channel.offer(event, key.generation)
            if (v == OfferVerdict.Accepted) shouldDeliver = true
            v
        }
        if (shouldDeliver) deliver(event)
        return verdict
    }

    /**
     * Route one [received] thing with its CAPTURED, immutable [captured] peer,
     * under the section-13 algorithm: capture (done by the caller) -> validate the
     * token and the input under the named owner -> one explicit transition ->
     * schedule the bounded effect (the [forward] of the SAME captured peer) ->
     * revalidate the token upon completion.
     *
     * NO current-state lookup may stand in for the missing immutable callback
     * identity: the peer forward'd is the captured one, never [byHandle] re-look'd
     * up at delivery (that seam is accepted only to be DEFIED - the correct path
     * observeth the captured peer, and a witness install'd a decoy handle-map to
     * prove it). A relation rotated beneath the token - the owner's generation no
     * longer matcheth the captured one, at entry OR upon completion - is REFUS'D
     * and the prior state is preserv'd.
     */
    fun route(
        captured: TrustedPeer,
        received: ByteArray,
        byHandle: (RelationKey) -> TrustedPeer? = { _ -> null },
        forward: (TrustedPeer, ByteArray) -> Unit,
    ): RouteOutcome {
        val current = ownerGeneration(captured.relation) ?: return RouteOutcome.RefusedUnknownRelation
        if (current != captured.relation.generation) return RouteOutcome.RefusedStaleIdentity
        // The captured, immutable identity is forward'd - byHandle is NOT consult'd.
        forward(captured, received)
        val after = ownerGeneration(captured.relation)
        if (after != current) return RouteOutcome.RefusedStaleIdentity
        return RouteOutcome.Forwarded
    }

    /** Witnesses only: whether this relation's LinkReady hath been publish'd once. */
    internal fun isReadyPublishedForTest(relation: RelationKey): Boolean =
        synchronized(lock) { relation in readyPublished }
}
