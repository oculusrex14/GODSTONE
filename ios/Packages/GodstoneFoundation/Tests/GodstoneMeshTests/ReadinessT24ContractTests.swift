import XCTest
import Foundation
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T24 - the peer-event contract's iOS unit witnesses (mirror of the android
// ReadinessT24ContractTest). Pure host, no radio, no CoreBluetooth. These prove
// that:
//   * a TrustedPeer requireth the frozen identity widths (16 / 32) and a
//     non-negative trust version - a malformed peer is REFUS'D (nil), never
//     constructured; and it is equalled by CONTENT (relation, node id, public
//     key, trust version), never by a transport handle;
//   * the ReliablePeerEventChannel is bounded and RELIABLE: it answereth
//     backpressure rather than a silent drop, refuseth a stale owner token
//     terminally, and once fail'd terminally carrieth no more.
//
// The one idiom divergence from android: Swift value semantics refuse a bad
// width via a FAILABLE init (nil) rather than by throwing, and Data compareth
// bytewise as a value type (no defensive-copy accessors are need'd).
// ---------------------------------------------------------------------------

/// A stable relation identity builder: fixed direction and peer UUID, varied
/// generation, so two peers built alike carry EQUAL relations (a random UUID
/// would shatter content-equality).
final class ReadinessT24ContractTests: XCTestCase {

    private var baseUUID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }

    private func relation(_ generation: UInt64) -> RelationKey {
        RelationKey(direction: .inboundPeripheral, peerId: baseUUID, generation: generation)
    }

    private func bytes(_ size: Int, _ fill: Int) -> Data {
        Data([UInt8](repeating: UInt8(fill), count: size))
    }

    /// Build a well-formed peer (widths 16 / 32, trust >= 0); the force-unwrap
    /// is safe precisely because every argument here is a valid width.
    private func peer(_ generation: UInt64, nodeIdFill: Int = 7, pubFill: Int = 9, trust: Int = 1) -> TrustedPeer {
        TrustedPeer(
            relation: relation(generation),
            nodeId16: bytes(16, nodeIdFill),
            identityPub32: bytes(32, pubFill),
            trustVersion: trust,
        )!
    }

    // MARK: - the frozen identity widths

    func testATrustedPeerRequirethTheFrozenIdentityWidths() throws {
        let good = peer(3)
        XCTAssertEqual(good.nodeId16.count, 16, "the node id is sixteen octets")
        XCTAssertEqual(good.identityPub32.count, 32, "the identity public key is thirty-two octets")
        // value semantics: a stored read IS the frozen content, byte for byte
        XCTAssertEqual(good.nodeId16, Data([UInt8](repeating: 7, count: 16)), "the node id is the content given")

        XCTAssertNil(
            TrustedPeer(relation: relation(1), nodeId16: bytes(15, 1), identityPub32: bytes(32, 2), trustVersion: 0),
            "a fifteen-octet node id must not stand",
        )
        XCTAssertNil(
            TrustedPeer(relation: relation(1), nodeId16: bytes(16, 1), identityPub32: bytes(31, 2), trustVersion: 0),
            "a thirty-one-octet identity public key must not stand",
        )
        XCTAssertNil(
            TrustedPeer(relation: relation(1), nodeId16: bytes(16, 1), identityPub32: bytes(32, 2), trustVersion: -1),
            "a negative trust version must not stand",
        )
    }

    // MARK: - content equality, not the transport handle

    func testATrustedPeerEqualsByContentNotByTheTransportHandle() throws {
        let a = peer(5, nodeIdFill: 11, pubFill: 22, trust: 3)
        let b = peer(5, nodeIdFill: 11, pubFill: 22, trust: 3)
        XCTAssertEqual(a, b, "content-identical peers are equal")
        XCTAssertEqual(a.hashValue, b.hashValue, "content-identical peers share a hash")

        XCTAssertNotEqual(a, peer(5, nodeIdFill: 11, pubFill: 22, trust: 4), "a differing trust version is a different peer")
        XCTAssertNotEqual(a, peer(5, nodeIdFill: 12, pubFill: 22, trust: 3), "a differing node id is a different peer")
        XCTAssertNotEqual(a, peer(5, nodeIdFill: 11, pubFill: 23, trust: 3), "a differing public key is a different peer")
        XCTAssertNotEqual(a, peer(6, nodeIdFill: 11, pubFill: 22, trust: 3), "a differing relation is a different peer")
    }

    // MARK: - the bounded reliable channel

    func testTheBoundedChannelAnswerethWithBackpressureNotWithSilentDrop() throws {
        let channel = ReliablePeerEventChannel(capacity: 2)
        let p = peer(1)
        let ready = LinkEvent.linkReady(p)
        let auth = LinkEvent.auth(p)
        let lost = LinkEvent.linkLost(p)

        XCTAssertEqual(channel.offer(ready, ownerGeneration: 1), .accepted, "the first offer is carri'd")
        XCTAssertEqual(channel.offer(auth, ownerGeneration: 1), .accepted, "the second offer is carri'd")
        XCTAssertEqual(channel.offer(lost, ownerGeneration: 1), .backpressure, "a full channel answereth with backpressure")
        XCTAssertEqual(channel.size, 2, "nothing is silently dropt: the bound abideth")

        XCTAssertNotNil(channel.poll(), "the head is deliver'd in order")
        XCTAssertEqual(channel.offer(lost, ownerGeneration: 1), .accepted, "after a drain, room is won again")
        XCTAssertEqual(channel.size, 2, "two stand again")
    }

    func testTheStaleOwnerTokenIsRefusedTerminally() throws {
        let channel = ReliablePeerEventChannel(capacity: 4)
        let p = peer(7)
        XCTAssertEqual(channel.offer(.auth(p), ownerGeneration: 7), .accepted, "a matching owner token is accepted")
        XCTAssertEqual(channel.offer(.auth(p), ownerGeneration: 6), .terminalFailure, "a stale owner token is a terminal failure")
        XCTAssertEqual(channel.size, 1, "the stale offer left no whit behind it")
    }

    func testTheTerminallyFaildChannelCarriethNoMore() throws {
        let channel = ReliablePeerEventChannel(capacity: 4)
        let p = peer(2)
        XCTAssertEqual(channel.offer(.linkReady(p), ownerGeneration: 2), .accepted, "pre-failure an offer is carri'd")
        channel.failTerminally()
        XCTAssertTrue(channel.isTerminal, "the channel is terminal")
        XCTAssertNil(channel.poll(), "a terminal channel yieldeth nothing")
        XCTAssertEqual(channel.offer(.linkLost(p), ownerGeneration: 2), .terminalFailure, "a terminal channel refuseth offers")
        XCTAssertEqual(channel.size, 0, "a terminal channel holdeth nothing")
    }
}
