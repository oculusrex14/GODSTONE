import XCTest
import Foundation
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

// ---------------------------------------------------------------------------
// T24 - the platform/integration slice's iOS node-level witnesses (mirror of
// the android ReadinessT24IntegrationTest). Pure host, no CoreBluetooth. These
// witness the two things the "publish only relation-bound authenticated peers"
// contract hinge upon at the node:
//   * the start sequence registereth the authoritative consumers BEFORE the radio
//     adapter is open'd (the section 6 "lose authoritative events" defect) --
//     proved through the single startInOrder decision point that both production
//     and these witnesses funnel through;
//   * the extract'd consumers' bodies are sound: the peer view followeth
//     connect / disconnect / re-present by content, and an inbound clear is
//     fail-closed (an undecodable clear is dropt, never ingested).
//
// The positive inbound decode->ingest path is behaviour-preserving extraction of
// the former delegate body and is already witness'd by
// MeshNodeDeliveryIntegrationTests' C7 seams; here only the fail-closed gate is
// witness'd, as on the android twin. The `receivedFrom` (the immutable
// TrustedPeer's authenticated node id) is NOT yet carri'd into routing -- that is
// the INTEGRATION child commit; until then an empty receivedFrom recordeth
// "sender not yet identified", honest while linkLayerReady is false.
// ---------------------------------------------------------------------------

final class ReadinessT24IntegrationTests: XCTestCase {

    /// A delivery repository that is never exercis'd by these witnesses; any call
    /// is a bug. The witnesses touch onely the peer view, the sessions' drop, and
    /// the pure decode gate -- none of which reacheth this repository.
    private final class UnexercisedDeliveryRepository: DeliveryRepository {
        func get(_ msgId: Data) -> DeliveryLookup { fatalError("unused by these witnesses") }
        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult { fatalError("unused by these witnesses") }
        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult { fatalError("unused by these witnesses") }
        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult { fatalError("unused by these witnesses") }
        func clear(_ msgId: Data) -> ClearResult { fatalError("unused by these witnesses") }
    }

    private func makeNode() -> MeshNode {
        let identity = try! MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let store = InMemoryMessageStore()
        let tracker = DeliveryTracker(
            repo: UnexercisedDeliveryRepository(),
            authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver())
        )
        return MeshNode(identity: identity, store: store, deliveryTracker: tracker)
    }

    // MARK: - the start order: attach consumers, then open the adapter

    func testTheStartSequenceAttachethConsumersEreTheAdapterBeOpened() throws {
        let node = makeNode()
        var order: [String] = []
        node.startInOrder(
            attach: { order.append("attach") },
            open: { order.append("open") }
        )
        XCTAssertEqual(order, ["attach", "open"], "the consumers must be attach'd before the adapter is open'd")
    }

    // MARK: - the peer view followeth connect / disconnect / re-present by content

    func testThePeerStatusFollowethConnectDisconnectAndRePresentByContent() throws {
        let node = makeNode()
        let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        XCTAssertEqual(node.knownPeersForTest().count, 0, "no peer is known at the outset")

        _ = node.handlePeerConnect(a)
        XCTAssertEqual(node.knownPeersForTest().count, 1, "a connect'd peer entereth the view")

        _ = node.handlePeerConnect(a)
        XCTAssertEqual(node.knownPeersForTest().count, 1, "a re-presented peer by the selfsame id addeth no whit")

        _ = node.handlePeerConnect(b)
        XCTAssertEqual(node.knownPeersForTest().count, 2, "a second, distinct peer entereth the view")

        _ = node.handlePeerDisconnect(a)
        XCTAssertEqual(node.knownPeersForTest().count, 1, "the disconnect'd peer departeth the view")

        _ = node.handlePeerDisconnect(b)
        XCTAssertEqual(node.knownPeersForTest().count, 0, "the view is empted when all depart")
    }

    // MARK: - the inbound clear is fail-closed upon undecodable bytes

    func testTheInboundClearIsFailClosedUponUndecodableBytes() throws {
        let node = makeNode()
        // The consumer ingests onely when the decode gate yieldeth a frame; a nil
        // decode is dropt. This witnesseth that gate directly (pure, no radio).
        XCTAssertNil(node.decodeInbound(Data([UInt8](repeating: 0x7F, count: 3))), "an undecodable clear yieldeth nil, so naught is ingested")
        XCTAssertNil(node.decodeInbound(Data()), "empty clear bytes yield nil")
        // a dropt clear must not conjure a peer into the view either
        XCTAssertTrue(node.knownPeersForTest().isEmpty, "a dropt clear leaveth the peer view untouched")
    }
}
