import XCTest
import Foundation
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T24 - the CANONICAL designated regression court (iOS), matching the task
// manifest's required_regression_paths (ios/.../Tests/GodstoneMeshTests/ReadinessT24Tests.swift)
// and the narrow command filter `--filter ReadinessT24Tests`. It carrieth the six
// required behavioural cases of the card, each with at least one EXECUTED
// assertion, at the authoritative publisher-core layer (the real-adapter lab
// composition is the nonshipping path reserved to T54, per the card):
//   1. immediate callback during start;   2. stopped / replaced consumer;
//   3. full channel (observed backpressure, never a silent drop);
//   4. identity-hint collision (a common handle never merges identity);
//   5. one found / one lost per lifecycle;  6. stale input cannot route under a
//   new identity (and the route forwards the CAPTURED peer, defying a decoy map).
// The suffixed courts (Contract / Integration / Publication / Capture) REMAIN as
// extended coverage; this canonical file is the one the verification filter and
// regression-path list point to. Idiom note: sinks are withdrawn by Int token
// (Swift closures lack reference equality); the observable law matches android.
// ---------------------------------------------------------------------------

final class ReadinessT24Tests: XCTestCase {

    private var baseUUID: UUID { UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")! }

    private func relation(_ generation: UInt64) -> RelationKey {
        RelationKey(direction: .inboundPeripheral, peerId: baseUUID, generation: generation)
    }

    private func bytes(_ size: Int, _ fill: Int) -> Data {
        Data([UInt8](repeating: UInt8(fill), count: size))
    }

    private func peer(_ generation: UInt64, nodeIdFill: Int = 7, pubFill: Int = 9, trust: Int = 1) -> TrustedPeer {
        TrustedPeer(relation: relation(generation), nodeId16: bytes(16, nodeIdFill), identityPub32: bytes(32, pubFill), trustVersion: trust)!
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

    // (1) immediate callback during start
    func testAnImmediateCallbackDuringStartIsDeliveredToTheInlistenSink() throws {
        let pub = publisher()
        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }
        let captured = peer(1)
        XCTAssertEqual(pub.publishLinkReady(captured), .accepted, "the offer is accepted")
        XCTAssertEqual(seen.count, 1, "the inlistened sink was called once")
        if case .linkReady(let p) = seen[0] {
            XCTAssertEqual(p, captured, "the delivered peer is the captured, immutable one")
        } else { XCTFail("the delivered event must be a LinkReady") }
    }

    // (2) stopped / replaced consumer
    func testAStoppedConsumerReceivethNoMoreAndAReplacedOneDoth() throws {
        let pub = publisher()
        var a: [LinkEvent] = []
        let tokenA = pub.addSink { event in a.append(event) }
        XCTAssertEqual(pub.publishLinkReady(peer(1)), .accepted)
        XCTAssertEqual(a.count, 1, "the first sink saw the ready")
        pub.removeSink(tokenA)
        var b: [LinkEvent] = []
        _ = pub.addSink { event in b.append(event) }
        XCTAssertEqual(pub.publishLinkReady(peer(2)), .accepted)
        XCTAssertEqual(a.count, 1, "the stopped consumer saw no more")
        XCTAssertEqual(b.count, 1, "the replaced consumer sees the new event")
    }

    // (3) full channel: observed verdict, never a silent drop, never a false mark
    func testAFullChannelAnswerethWithBackpressureAndIsNotSilentlyDropt() throws {
        let pub = publisher(capacity: 1)
        let first = peer(1)
        XCTAssertEqual(pub.publishLinkReady(first), .accepted, "the first offer findeth room")
        XCTAssertTrue(pub.isReadyPublishedForTest(first.relation), "the published relation is registered")
        let second = peer(2)
        XCTAssertEqual(pub.publishLinkReady(second), .backpressure, "a full channel answereth with backpressure")
        XCTAssertFalse(pub.isReadyPublishedForTest(second.relation), "a refused offer doth NOT mark its relation published")
        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }
        XCTAssertEqual(pub.publishLinkReady(peer(3)), .backpressure, "a further full offer is observed as backpressure")
        XCTAssertEqual(seen.count, 0, "no delivery was made upon the refused offers")
    }

    // (4) identity-hint collision: a common handle never merges distinct identity
    func testACommonHandleMatchDothNotMergeDistinctRelations() throws {
        let pub = publisher()
        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }
        let p1 = TrustedPeer(relation: relation(1), nodeId16: bytes(16, 7), identityPub32: bytes(32, 9), trustVersion: 1)!
        let p2 = TrustedPeer(relation: relation(2), nodeId16: bytes(16, 8), identityPub32: bytes(32, 9), trustVersion: 1)!
        XCTAssertEqual(pub.publishLinkReady(p1), .accepted)
        XCTAssertEqual(pub.publishLinkReady(p2), .accepted)
        XCTAssertEqual(countReady(seen), 2, "both distinct relations travelled; none merged by the handle")
    }

    // (5) one found / one lost per lifecycle
    func testOneReadyAndOneLostTravelALifecycle() throws {
        let pub = publisher()
        var seen: [LinkEvent] = []
        _ = pub.addSink { event in seen.append(event) }
        let r: UInt64 = 7
        XCTAssertEqual(pub.publishLinkReady(peer(r)), .accepted)
        XCTAssertEqual(pub.publishLinkReady(peer(r)), .accepted, "a duplicate ready is an idempotent no-op")
        XCTAssertEqual(pub.publishLinkLost(peer(r)), .accepted)
        XCTAssertEqual(pub.publishLinkLost(peer(r)), .accepted, "a duplicate lost is an idempotent no-op")
        XCTAssertEqual(countReady(seen), 1, "only one LinkReady was delivered")
        XCTAssertEqual(countLost(seen), 1, "only one LinkLost was delivered")
    }

    // (6) stale input cannot route under a new identity; route forwards the CAPTURED peer
    func testStaleInputCannotRouteUnderANewIdentityAndRouteUsethTheCapturedPeer() throws {
        let captured = peer(5)
        let decoy = TrustedPeer(relation: captured.relation, nodeId16: bytes(16, 0xEE), identityPub32: bytes(32, 0xFF), trustVersion: 99)!
        do {
            let current: UInt64 = 5
            let pub = PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: 8), ownerGeneration: { _ in current })
            var forwarded: [TrustedPeer] = []
            let outcome = pub.route(captured, bytes(4, 1), byHandle: { _ in decoy }, forward: { peer, _ in forwarded.append(peer) })
            XCTAssertEqual(outcome, .forwarded, "a whole, current token forwardeth")
            XCTAssertEqual(forwarded.count, 1, "the captured peer was forwarded once")
            XCTAssertEqual(forwarded[0], captured, "the forwarded peer is the CAPTURED one, not the handle's decoy")
            XCTAssertNotEqual(forwarded[0], decoy, "the handle's decoy was never used for identity")
        }
        do {
            let pub = PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: 8), ownerGeneration: { _ in 6 })
            var forwarded: [TrustedPeer] = []
            let outcome = pub.route(captured, bytes(4, 1), forward: { peer, _ in forwarded.append(peer) })
            XCTAssertEqual(outcome, .refusedStaleIdentity, "a stale token is refused at the gate")
            XCTAssertEqual(forwarded.count, 0, "naught was forwarded for the stale input")
        }
        do {
            let pub = PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: 8), ownerGeneration: { _ in nil })
            var forwarded: [TrustedPeer] = []
            let outcome = pub.route(captured, bytes(4, 1), forward: { peer, _ in forwarded.append(peer) })
            XCTAssertEqual(outcome, .refusedUnknownRelation, "an unknown relation is refused")
            XCTAssertEqual(forwarded.count, 0, "naught was forwarded for the unknown relation")
        }
        do {
            var calls = 0
            let pub = PeerEventPublisher(channel: ReliablePeerEventChannel(capacity: 8), ownerGeneration: { _ in calls += 1; return calls == 1 ? 5 : 6 })
            var forwardedCount = 0
            let outcome = pub.route(captured, bytes(4, 1), forward: { _, _ in forwardedCount += 1 })
            XCTAssertEqual(outcome, .refusedStaleIdentity, "revalidation upon completion refuseth the mid-flight rotation")
            XCTAssertEqual(forwardedCount, 1, "the effect was scheduled exact once")
        }
    }
}
