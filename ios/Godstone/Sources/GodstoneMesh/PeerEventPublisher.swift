import Foundation

// ---------------------------------------------------------------------------
// T24 - the integration core (iOS), the symmetric twin of the android
// PeerEventPublisher.kt. Additively bringeth to the Swift isle the bounded,
// RELIABLE publication of relation-bound authenticated peers and their route
// under the section-13 event algorithm, built upon the already-committed
// TrustedPeer / LinkEvent / OfferVerdict / ReliablePeerEventChannel contract.
//
//   * an offer's verdict is RETURNED for the caller to OBSERVE - backpressure or
//     terminal failure is never swallow'd, and a refus'd offer neither marketh
//     the relation publish'd nor delivereth a whit (the "ignore tryEmit failure"
//     falsification);
//   * the peer that is deliver'd and route'd is the CAPTURED, immutable
//     TrustedPeer, never a handle re-look'd-up at delivery: route forwardeth the
//     captured peer and DEFIEth an inject'd decoy handle-map (the "look up
//     current peer on delayed delivery" falsification);
//   * a relation rotat'd beneath the token - at entry OR upon completion - is
//     REFUS'D (refusedStaleIdentity) and the prior state is kept, per the
//     section-13 capture / validate / one-transition / revalidate law;
//   * exactly one LinkReady and one LinkLost travel a relation's lifecycle (a
//     duplicate completion is an idempotent no-op); identity is the relation
//     token and a peer's identity is by CONTENT, so a common handle/hint
//     match merge'th not distinct relations.
//
// Idiom divergences from android (behaviour-equivalent, record'd): the peer
// class is a plain reference type (not @unchecked Sendable), as the android
// class is not @internal Sendable; consumers are remov'd by an Int TOKEN
// (Swift closures have no reference equality), whereas android removeth by the
// same closure reference. The observable law and the witness cases are the
// selfsame on both isles.
// ---------------------------------------------------------------------------

/// The outcome of one route decision under the section-13 token algorithm.
enum RouteOutcome: Equatable {
    /// The token was whole and current under the named owner; the frame was forward'd once.
    case forwarded
    /// The named owner knoweth the relation no longer (it is gone): refuse, prior state kept.
    case refusedUnknownRelation
    /// The relation was rotat'd beneath the token (a stale input for a new identity): refuse.
    case refusedStaleIdentity
}

/// The relation-scoped, driver-authority-gated publisher/router of authenticated
/// peer events. Additive: nothing in the shipp'd transport path calleth it yet.
final class PeerEventPublisher {
    private let channel: ReliablePeerEventChannel
    /// The driver authority: the CURRENT generation a relation holdeth (nil => gone).
    /// A real dependency seam, inject'd so a witness may simulate a mid-lifecycle rotation.
    private let ownerGeneration: (RelationKey) -> UInt64?
    private let lock = NSLock()
    private var sinks: [(token: Int, call: (LinkEvent) -> Void)] = []
    private var nextToken: Int = 1
    // The relation identities already publish'd, so that exactly one LinkReady and
    // one LinkLost travel a relation through its lifecycle.
    private var readyPublished: Set<RelationKey> = []
    private var lostPublished: Set<RelationKey> = []

    init(channel: ReliablePeerEventChannel,
         ownerGeneration: @escaping (RelationKey) -> UInt64? = { key in key.generation }) {
        self.channel = channel
        self.ownerGeneration = ownerGeneration
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Enrol a consumer sink; returneth its token. A sink inlistened after an event
    /// is born heareth it not.
    @discardableResult
    func addSink(_ call: @escaping (LinkEvent) -> Void) -> Int {
        locked {
            let token = nextToken
            nextToken += 1
            sinks.append((token, call))
            return token
        }
    }

    /// Withdraw a consumer sink by its token; a stopp'd sink receiveth no more.
    func removeSink(_ token: Int) {
        locked { sinks.removeAll { $0.token == token } }
    }

    /// Witnesses only: the number of inlistened sinks.
    func sinkCountForTest() -> Int { locked { sinks.count } }

    /// Deliver to a SNAPSHOT of the sinks (the sink set is stable across delivery).
    private func deliver(_ event: LinkEvent) {
        let snapshot: [(LinkEvent) -> Void] = locked { sinks.map { $0.call } }
        for call in snapshot { call(event) }
    }

    /// Publish exactly one LinkReady for the relation of [captured], RETURNING the
    /// channel's offer verdict so the caller observeth backpressure / terminal
    /// failure. A relation already publish'd once is a duplicate completion: an
    /// idempotent no-op. A REFUS'D offer neither marketh the relation publish'd nor
    /// delivereth a whit.
    @discardableResult
    func publishLinkReady(_ captured: TrustedPeer) -> OfferVerdict {
        let key = captured.relation
        let event = LinkEvent.linkReady(captured)
        let (verdict, shouldDeliver): (OfferVerdict, Bool) = locked {
            if readyPublished.contains(key) { return (.accepted, false) }
            let v = channel.offer(event, ownerGeneration: key.generation)
            if v == .accepted {
                readyPublished.insert(key)
                return (.accepted, true)
            }
            return (v, false)
        }
        if shouldDeliver { deliver(event) }
        return verdict
    }

    /// Publish exactly one LinkLost for the relation of [captured], likewise observ'd.
    @discardableResult
    func publishLinkLost(_ captured: TrustedPeer) -> OfferVerdict {
        let key = captured.relation
        let event = LinkEvent.linkLost(captured)
        let (verdict, shouldDeliver): (OfferVerdict, Bool) = locked {
            if lostPublished.contains(key) { return (.accepted, false) }
            let v = channel.offer(event, ownerGeneration: key.generation)
            if v == .accepted {
                lostPublished.insert(key)
                return (.accepted, true)
            }
            return (v, false)
        }
        if shouldDeliver { deliver(event) }
        return verdict
    }

    /// Publish an Auth assertion for the relation of [captured], likewise observ'd.
    @discardableResult
    func publishAuth(_ captured: TrustedPeer) -> OfferVerdict {
        let key = captured.relation
        let event = LinkEvent.auth(captured)
        let (verdict, shouldDeliver): (OfferVerdict, Bool) = locked {
            let v = channel.offer(event, ownerGeneration: key.generation)
            return (v, v == .accepted)
        }
        if shouldDeliver { deliver(event) }
        return verdict
    }

    /// Route one [received] thing with its CAPTURED, immutable [captured] peer,
    /// under the section-13 algorithm: capture (done by the caller) -> validate the
    /// token and the input under the named owner -> one explicit transition ->
    /// schedule the bounded effect (the forward of the SAME captured peer) ->
    /// revalidate the token upon completion. NO current-state lookup may stand in
    /// for the missing immutable callback identity: the peer forward'd is the
    /// captured one, never [byHandle] re-look'd-up at delivery (that seam is
    /// accepted onely to be DEFIED). A relation rotat'd beneath the token - at
    /// entry OR upon completion - is REFUS'D and the prior state is kept.
    func route(_ captured: TrustedPeer,
               _ received: Data,
               byHandle: (RelationKey) -> TrustedPeer? = { _ in nil },
               forward: (TrustedPeer, Data) -> Void) -> RouteOutcome {
        guard let current = ownerGeneration(captured.relation) else { return .refusedUnknownRelation }
        if current != captured.relation.generation { return .refusedStaleIdentity }
        // The captured, immutable identity is forward'd - byHandle is NOT consult'd.
        forward(captured, received)
        let after = ownerGeneration(captured.relation)
        if after != current { return .refusedStaleIdentity }
        return .forwarded
    }

    /// Witnesses only: whether this relation's LinkReady hath been publish'd once.
    func isReadyPublishedForTest(_ relation: RelationKey) -> Bool {
        locked { readyPublished.contains(relation) }
    }
}
