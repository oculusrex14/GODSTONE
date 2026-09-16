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

    func testTheStartSequenceAttachethConsumersEreTheAdaptersBeOpened() throws {
        let node = makeNode()
        var order: [String] = []
        node.startInOrder(
            attach: { order.append("attach") },
            open: { order.append("open") }
        )
        XCTAssertEqual(order, ["attach", "open"], "the consumers must be attach'd before the adapter is open'd")
    }

    // MARK: - the peer view followeth connect / disconnect / re-present by content

    /// IOS-02 step 5 RE-FRAMED THIS ARM, AND IT SAYETH SO: the transitions it witnesseth are those of the
    /// **PRESENCE** view. Its audited form asserted them against `knownPeersForTest()` -- THE ROUTE-ELIGIBLE
    /// VIEW -- which is what made a merely physical relation routable. Presence is still watched, count for
    /// count, and the law it must NOT violate is stated beside it.
    func testThePresenceViewFollowethPresenceTransitionsByContent() throws {
        let node = makeNode()
        let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

        XCTAssertEqual(node.presentPeersForTest().count, 0, "no peer is present at the outset")

        _ = node.handlePeerConnect(a)
        XCTAssertEqual(node.presentPeersForTest().count, 1, "a connect'd peer entereth the presence view")
        XCTAssertTrue(node.knownPeersForTest().isEmpty,
                      "AND PRESENCE CONFERRETH NO ROUTE: the route-eligible view stayeth empty until the "
                      + "matching confirmation (IOS-02 step 5)")

        _ = node.handlePeerConnect(a)
        XCTAssertEqual(node.presentPeersForTest().count, 1, "a re-presented peer by the selfsame id addeth no whit")

        _ = node.handlePeerConnect(b)
        XCTAssertEqual(node.presentPeersForTest().count, 2, "a second, distinct peer entereth the presence view")

        _ = node.handlePeerDisconnect(a)
        XCTAssertEqual(node.presentPeersForTest().count, 1, "the disconnect'd peer departeth the presence view")

        _ = node.handlePeerDisconnect(b)
        XCTAssertEqual(node.presentPeersForTest().count, 0, "the presence view is empted when all depart")
        XCTAssertTrue(node.knownPeersForTest().isEmpty, "and the route-eligible view never saw any of them")
    }

    // MARK: - IOS-02 step 5: the ROUTE-ELIGIBLE view cometh from the TRUSTED event, not from the radio

    /// IOS-02 step 5, THE SHIPPING WIRING: the transport's OWN callback -- not the composition's hand-wiring --
    /// must populate the route-eligible view. This arm calleth the delegate method the transport maketh when it
    /// publisheth application readiness, and requireth that the node admit the peer it nameth.
    func testTheTransportsOwnReadinessCallbackAdmittethTheRoute() throws {
        let node = makeNode()
        let handle = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let nodeId = Data(repeating: 0x7C, count: 16)
        XCTAssertTrue(node.knownPeersForTest().isEmpty, "no route standeth at the outset")

        node.transportApplicationLinkReady(peerId: handle, receivedFrom: nodeId)

        XCTAssertEqual(node.knownPeersForTest(), [handle],
                       "IOS-02 step 5: THE TRANSPORT'S OWN READINESS CALLBACK MUST POPULATE THE ROUTE-ELIGIBLE "
                       + "VIEW -- the law held in the harness only while this wiring was absent")
    }

    /// IOS-02, the card's fifth step: **"MeshNode's route-eligible peers must be populated from that event
    /// [the matching confirmation], not physical duplex."**
    ///
    /// MEASURED BEFORE THE REPAIR: `MeshNode.transportDidConnect` calleth `handlePeerConnect`, and that
    /// INSERTETH INTO THE VERY SET THAT FEEDETH THE SEND PATHS -- `currentPeers()` is what
    /// `ble.send(frame, to:)` iterateth -- SO A PEER THAT IS MERELY PHYSICALLY PRESENT (no authenticated
    /// relation, no sealed key confirmation) IS ROUTE-ELIGIBLE, and the router would hand it frames whose
    /// sender it cannot authenticate. This arm asketh for the law instead.
    ///
    /// THE RED WAS TAKEN WITH ITS FIRST HALF ALONE (measured before the repair: 'The route-eligible view
    /// still carrieth it: [CCCCCCCC-...]'), because an arm that calleth an API which doth not yet exist
    /// cannot run -- AND THIS PROGRAMME'S RED MUST RUN. The second half landeth WITH the repair.
    func testAPurelyPhysicalRelationIsNotRouteEligible() throws {
        let node = makeNode()
        let handle = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let nodeId = Data(repeating: 0x5A, count: 16)

        _ = node.handlePeerConnect(handle)
        XCTAssertTrue(node.knownPeersForTest().isEmpty,
                      "A MERELY PHYSICAL RELATION MUST NOT BE ROUTE-ELIGIBLE: the radio carrieth a handle, "
                      + "and only the matching key confirmation proveth whose identity standeth behind it "
                      + "(IOS-02 step 5). The route-eligible view still carrieth it: "
                      + String(describing: node.knownPeersForTest()))
        XCTAssertEqual(node.presentPeersForTest(), [handle], "though it IS present")

        _ = node.trustedPeerDidConnect(nodeId: nodeId, peerId: handle)
        XCTAssertEqual(node.knownPeersForTest(), [handle],
                       "THE TRUSTED EVENT IS WHAT ADMITTETH A PEER TO THE ROUTE")

        _ = node.trustedPeerDidDisconnect(nodeId: nodeId, peerId: handle)
        XCTAssertTrue(node.knownPeersForTest().isEmpty, "and the trusted farewell withdraweth it")
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
