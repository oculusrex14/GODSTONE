import XCTest
import Foundation
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T24 - the capture-at-the-authenticated-moment primitive's iOS witnesses
// (mirror of the android ReadinessT24CaptureTest). Pure host, no radio.
//
// The routing-carriage integration will construct a peer's immutable identity
// ONELY from the authenticated identity public key the transport learned when the
// relation was seal'd. The failable init accepteth any sixteen-octet node id; this
// witness proveth TrustedPeer.capture FORCETH the frozen identity law (node_id =
// BLAKE2s-128(identityPub)) upon the capture, so a captured peer can never
// disagree with its own identity, and that it refuseth a malformed capture.
//
// Asymmetry note (faithful, not a slip): the android twin additionally repair'd a
// by-reference aliasing defect in its constructor (Kotlin ByteArray is a
// reference); iOS TrustedPeer storeth Data, a VALUE type copied on assignment, so
// no such repair is need'd here - witness 3 confirms that immutability by value.
// ---------------------------------------------------------------------------

/// A stable relation identity builder: fixed direction and peer UUID, varied
/// generation, so two captures built alike carry EQUAL relations.
final class ReadinessT24CaptureTests: XCTestCase {

    private var baseUUID: UUID { UUID(uuidString: "00000000-0000-0000-0000-00000000000B")! }

    private func relation(_ generation: UInt64) -> RelationKey {
        RelationKey(direction: .inboundPeripheral, peerId: baseUUID, generation: generation)
    }

    private func bytes(_ size: Int, _ fill: Int) -> Data {
        Data([UInt8](repeating: UInt8(fill), count: size))
    }

    /// A deterministick, well-form'd 32-octet authenticated identity public key.
    private func identityPub(_ seed: Int) -> Data {
        Data((0..<32).map { index in UInt8((((index &* 7) &+ seed)) & 0xFF) })
    }

    // The heart of the law: capture DERIVETH the node id from the identity, so it
    // cannot be coaxed into carrying an inconsistent one.
    func testCaptureDerivetheTheNodeIdFromTheAuthenticatedIdentity() throws {
        let pub = identityPub(11)
        let canonical = IdentityBindingV1.deriveNodeId(signingPublicKey: pub)
        XCTAssertEqual(canonical.count, 16, "the canonical derivation is sixteene octets")

        guard let captured = TrustedPeer.capture(relation: relation(1), authenticatedIdentityPub32: pub, trustVersion: 3) else {
            return XCTFail("a well-form'd capture must succeed")
        }
        XCTAssertEqual(captured.nodeId16, canonical, "capture defereth to the canonical authority")
        XCTAssertEqual(captured.nodeId16.count, 16)
        XCTAssertEqual(captured.identityPub32, pub, "the identity is carri'd verbatim")
        XCTAssertEqual(captured.identityPub32.count, 32)
        XCTAssertEqual(captured.trustVersion, 3, "the trust version is kept")
    }

    // A peer built by hand with a node id that DOETH NOT match its identity is the
    // very inconsistency capture must forbid; capture, given the same identity,
    // yieldeth the true derivation and none other.
    func testCaptureRefusethToCarryAnInconsistentHandMadeNodeId() throws {
        let pub = identityPub(23)
        let wrong = bytes(16, 0x5A)                       // a plausible-width but WRONG node id
        guard let byHand = TrustedPeer(relation: relation(1), nodeId16: wrong, identityPub32: pub, trustVersion: 3) else {
            return XCTFail("the raw door admitteh a well-widthed, if inconsistent, peer")
        }
        let canonical = IdentityBindingV1.deriveNodeId(signingPublicKey: pub)
        guard let captured = TrustedPeer.capture(relation: relation(1), authenticatedIdentityPub32: pub, trustVersion: 3) else {
            return XCTFail("a well-form'd capture must succeed")
        }
        XCTAssertNotEqual(byHand.nodeId16, canonical, "the hand-made identity is inconsistent with its node id")
        XCTAssertEqual(captured.nodeId16, canonical, "capture deriveth the true node id, not the hand-made one")
        XCTAssertNotEqual(captured, byHand, "a captured peer is not the inconsistent hand-made peer")
    }

    // The capture defendeth its identity: a later mutation of the caller's buffer
    // leaveth the captured copy whole (Data is a value type, copied on store).
    func testCaptureCopiethTheAuthenticatedIdentityDefensively() throws {
        var pub = identityPub(31)
        let snapshot = pub
        guard let captured = TrustedPeer.capture(relation: relation(1), authenticatedIdentityPub32: pub, trustVersion: 2) else {
            return XCTFail("a well-form'd capture must succeed")
        }
        pub[0] = 0
        pub[31] = 0xFF
        XCTAssertEqual(captured.identityPub32, snapshot, "the captured identity is a value copy, whole against the mutation")
    }

    // A malformed authenticated identity (a wrong-width public key) is refus'd at
    // the gate, before any derivation.
    func testAwrongWidthIdentityIsRefusedEreDerivation() throws {
        XCTAssertNil(TrustedPeer.capture(relation: relation(1), authenticatedIdentityPub32: bytes(31, 0x11), trustVersion: 1),
                    "a thirty-one-octet identity is refus'd")
        XCTAssertNil(TrustedPeer.capture(relation: relation(1), authenticatedIdentityPub32: bytes(33, 0x22), trustVersion: 1),
                     "a thirty-three-octet identity is refus'd")
    }

    // A trust version must be a non-negative count.
    func testAnegativeTrustVersionIsRefusedAtTheGate() throws {
        XCTAssertNil(TrustedPeer.capture(relation: relation(1), authenticatedIdentityPub32: identityPub(7), trustVersion: -1),
                    "a negative trust version is refus'd")
    }

    // Two captures of the selfsame authenticated relation and identity are one peer.
    func testTwoCapturesOfTheSelfsameRelationAreOnePeer() throws {
        let a = TrustedPeer.capture(relation: relation(9), authenticatedIdentityPub32: identityPub(3), trustVersion: 5)
        let b = TrustedPeer.capture(relation: relation(9), authenticatedIdentityPub32: identityPub(3), trustVersion: 5)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertEqual(a, b, "the captures agree by content")
        XCTAssertEqual(a?.hashValue, b?.hashValue, "and agree in hash")
    }
}
