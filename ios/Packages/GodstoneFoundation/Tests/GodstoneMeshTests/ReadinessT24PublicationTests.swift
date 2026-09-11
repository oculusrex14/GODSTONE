import XCTest
import Foundation
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T24 - the integration core's boundary witnesses (iOS), the symmetric twin of
// the android ReadinessT24PublicationTest. Pure host: no CoreBluetooth, no
// radio. These exercize the PeerEventPublisher against the cases the T24 card
// enumerateth, capturing the downstream side effect or its ABSENCE:
//   * an immediate callback during start is deliver'd to an already-listen'd sink;
//   * a stopp'd / replac'd consumer doth / doth-not receiv'e further events;
//   * a FULL channel answereth with an observ'd Backpressure verdict, is NOT
//     silently dropt, and doth NOT mark the relation publish'd (the "ignore
//     tryEmit failure" falsification);
//   * a common handle match doth NOT merge distinct relations (identity is by the
//     relation token, and a peer's identity is by its CONTENT);
//   * exactly one LinkReady and one LinkLost travel a lifecycle;
//   * a stale input cannot route under a new identity, and the forward'd peer is
//     the CAPTURED one even when a decoy handle-map is present (the "look up
//     current peer on delayed delivery" falsification).
//
// Idiom divergence from android (behaviour-equivalent): sinks are withdraw'n by an
// Int token (Swift closures have no reference equality), where android withdraweth
// by the same closure reference. The observable law and the six witness cases are
// the selfsame on both isles.
// ---------------------------------------------------------------------------

final class ReadinessT24PublicationTests: XCTestCase {

    private var baseUUID: UUID { UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")! }

    private func relation(_ generation: UInt64) -> RelationKey {
        RelationKey(direction: .inboundPeripheral, peerId: baseUUID, generation: generation)
    }

    private func bytes(_ size: Int, _ fill: Int) -> Data {
        Data([UInt8](repeating: UInt8(fill), count: size))
    }

    /// A well-form'd peer (widths 16 / 32, trust >= 0); the force-unwrap is safe
    /// because every argument here is a valid width.
    private func peer(_ generation: UInt64, nodeIdFill: UInt8 = 7, pubFill: UInt8 = 9, trust: Int = 1) -> TrustedPeer {
        TrustedPeer(
            relation: relation(generation),
            nodeId16: bytes(16, Int(nodeIdFill)),
            identityPub32: bytes(32, Int(pubFill)),
            trustVersion: trust,
        )!
    }

    private func publisher(capacity: Int = 64) -> PeerEventPublisher {
        PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: capacity))
    }

    private func countReady(_ events: [LinkEvent]) -> Int {
        var n = 0; for e in events { if case .linkReady = e { n += 1 } }; return n
    }

    private func countLost(_ events: [LinkEvent]) -> Int {
        var n = 0; for e in events { if case .linkLost = e { n += 1 } }; return n
    }

    // The immediate callback: a sink inlistened BEFORE the first publish is
    // synchronously call'd, and receiveth the CAPTURED immutable peer.
    func testAnImmediateCallbackDuringStartIsDeliveredToTheInlistenSink() throws {
        let pub = publisher()
        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }

        let captured = peer(1)
        XCTAssertEqual(pub.publishLinkReady(captured), .accepted, "the offer is accepted")
        XCTAssertEqual(seen.count, 1, "the inlistened sink was call'd once")
        if case .linkReady(let p) = seen[0] {
            XCTAssertEqual(p, captured, "the deliver'd peer is the captured, immutable one")
        } else {
            XCTFail("the deliver'd event must be a LinkReady")
        }
    }

    // A stopp'd consumer receiveth no more; a replac'd (newly inlistened) one doth.
    func testAStoppedConsumerReceivethNoMoreAndAReplacedOneDoth() throws {
        let pub = publisher()
        var a: [LinkEvent] = []
        let tokenA = pub.addSink { event in a.append(event) }

        XCTAssertEqual(pub.publishLinkReady(peer(1)), .accepted)
        XCTAssertEqual(a.count, 1, "the first sink saw the ready")

        pub.removeSink(tokenA) // stop the consumer
        var b: [LinkEvent] = []
        _ = pub.addSink { event in b.append(event) } // a replac'd consumer

        XCTAssertEqual(pub.publishLinkReady(peer(2)), .accepted)
        XCTAssertEqual(a.count, 1, "the stopp'd consumer saw no more")
        XCTAssertEqual(b.count, 1, "the replac'd consumer seeth the new event")
    }

    // A full channel answereth with an OBSERV'D backpressure verdict, is NOT
    // silently dropt, and doth NOT mark the relation publish'd.
    func testAFullChannelAnswerethWithBackpressureAndIsNotSilentlyDropt() throws {
        let pub = publisher(capacity: 1) // a one-deep reliable conduit
        let first = peer(1)
        XCTAssertEqual(pub.publishLinkReady(first), .accepted, "the first offer findeth room")
        XCTAssertTrue(pub.isReadyPublishedForTest(first.relation), "the publish'd relation is registred")

        let second = peer(2)
        XCTAssertEqual(pub.publishLinkReady(second), .backpressure, "a full channel answereth with backpressure")
        XCTAssertFalse(pub.isReadyPublishedForTest(second.relation), "a refus'd offer doth NOT mark its relation publish'd")

        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }
        XCTAssertEqual(pub.publishLinkReady(peer(3)), .backpressure, "a further full offer is observ'd as backpressure")
        XCTAssertEqual(seen.count, 0, "no delivery was made upon the refus'd offers")
    }

    // A common handle match doth NOT merge distinct relations: identity is the
    // relation token, and a peer's identity is by CONTENT.
    func testACommonHandleMatchDothNotMergeDistinctRelations() throws {
        let pub = publisher()
        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }

        // Two peers share the SELFsame handle UUID, differ onely in generation
        // (distinct relations) and in node id (distinct content).
        let handle = baseUUID
        let p1 = TrustedPeer(relation: RelationKey(direction: .inboundPeripheral, peerId: handle, generation: 1), nodeId16: bytes(16, 7), identityPub32: bytes(32, 9), trustVersion: 1)!
        let p2 = TrustedPeer(relation: RelationKey(direction: .inboundPeripheral, peerId: handle, generation: 2), nodeId16: bytes(16, 8), identityPub32: bytes(32, 9), trustVersion: 1)!
        XCTAssertEqual(pub.publishLinkReady(p1), .accepted)
        XCTAssertEqual(pub.publishLinkReady(p2), .accepted)

        XCTAssertEqual(countReady(seen), 2, "both distinct relations travail'd; none was merge'd by the handle")
    }

    // Exactly one LinkReady and one LinkLost travel a relation's lifecycle.
    func testOneReadyAndOneLostTravelALifecycle() throws {
        let pub = publisher()
        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }

        let r: UInt64 = 7
        XCTAssertEqual(pub.publishLinkReady(peer(r)), .accepted)
        XCTAssertEqual(pub.publishLinkReady(peer(r)), .accepted, "a duplicate ready is an idempotent no-op")
        XCTAssertEqual(pub.publishLinkLost(peer(r)), .accepted)
        XCTAssertEqual(pub.publishLinkLost(peer(r)), .accepted, "a duplicate lost is an idempotent no-op")

        XCTAssertEqual(countReady(seen), 1, "onely one LinkReady was deliver'd")
        XCTAssertEqual(countLost(seen), 1, "onely one LinkLost was deliver'd")
    }

    // The two faces of the "look up current peer on delayed delivery" falsification,
    // plus the stale-rotation refusals under the section-13 token algorithm.
    func testStaleInputCannotRouteUnderANewIdentityAndRouteUsethTheCapturedPeer() throws {
        let captured = peer(5) // relation generation 5
        let decoy = TrustedPeer(relation: captured.relation, nodeId16: bytes(16, 0xEE), identityPub32: bytes(32, 0xFF), trustVersion: 99)!

        // (a) Fresh & current: forward'd once, with the CAPTURED peer, never the
        //     decoy the handle-map would have resolv'd.
        do {
            let current: UInt64 = 5
            let pub = PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: 8), ownerGeneration: { _ in current })
            var forwarded: [TrustedPeer] = []
            let outcome = pub.route(captured, bytes(4, 1), byHandle: { _ in decoy }, forward: { peer, _ in forwarded.append(peer) })
            XCTAssertEqual(outcome, .forwarded, "a whole, current token forwardeth")
            XCTAssertEqual(forwarded.count, 1, "the captured peer was forward'd once")
            XCTAssertEqual(forwarded[0], captured, "the forward'd peer is the CAPTURED one, not the handle's decoy")
            XCTAssertNotEqual(forwarded[0], decoy, "the handle's decoy was never us'd for identity")
        }

        // (b) Stale at entry: the relation was rotat'd beneath the token.
        do {
            let pub = PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: 8), ownerGeneration: { _ in 6 })
            var forwarded: [TrustedPeer] = []
            let outcome = pub.route(captured, bytes(4, 1), forward: { peer, _ in forwarded.append(peer) })
            XCTAssertEqual(outcome, .refusedStaleIdentity, "a stale token is refus'd at the gate")
            XCTAssertEqual(forwarded.count, 0, "naught was forward'd for the stale input")
        }

        // (c) The named owner knoweth the relation no longer.
        do {
            let pub = PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: 8), ownerGeneration: { _ in nil })
            var forwarded: [TrustedPeer] = []
            let outcome = pub.route(captured, bytes(4, 1), forward: { peer, _ in forwarded.append(peer) })
            XCTAssertEqual(outcome, .refusedUnknownRelation, "an unknown relation is refus'd")
            XCTAssertEqual(forwarded.count, 0, "naught was forward'd for the unknown relation")
        }

        // (d) Rotation upon completion: the token was whole at entry yet the
        //     relation rotat'd ere delivery complete'd - the effect is schedul'd once,
        //     then revalidation refuseth it as a stale routing (the prior state is
        //     kept; the event is not treated as freshly forward'd).
        do {
            var calls = 0
            let pub = PeerEventPublisher(
                channel: ReliablePeerEventChannel(capacity: 8),
                ownerGeneration: { _ in calls += 1; return calls == 1 ? 5 : 6 }
            )
            var forwardedCount = 0
            let outcome = pub.route(captured, bytes(4, 1), forward: { _, _ in forwardedCount += 1 })
            XCTAssertEqual(outcome, .refusedStaleIdentity, "revalidation upon completion refuseth the mid-flight rotation")
            XCTAssertEqual(forwardedCount, 1, "the effect was schedul'd exact once")
        }
    }
}
