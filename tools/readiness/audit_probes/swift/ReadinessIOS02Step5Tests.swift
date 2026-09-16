// IOS-02 STEP 5 -- "MeshNode's route-eligible peers must be populated from that event [the matching
// confirmation], NOT physical duplex": the behavioural arm, PARKED, with the repair that proveth it.
//
// WHY PARKED: the arm is RED BY DESIGN on this tree, and the iOS lane must never be red -- the same rule
// the python and kotlin probes follow. WHEN THE RIG RECONCILIATION LANDETH, THIS ARM MOVES INTO
// `ios/Godstone/Tests/GodstoneMeshTests/ReadinessT24IntegrationTests.swift` (the canonical suite).
//
// WHAT WAS MEASURED IN ROUND 190 (nothing here is inferred):
//
//   * THE DEFECT IS REAL AND IN THE SEND PATH: `MeshNode.currentPeers()` -- which `ble.send(frame, to:)`
//     iterateth at three sites -- returneth `peers`, and `peers` was populated by `handlePeerConnect`,
//     which `transportDidConnect` (THE RADIO'S CALLBACK) calleth. SO A PEER THAT HAD AUTHENTICATED NOTHING
//     WAS HANDED FRAMES. The trusted event registered only a sync pump, never route eligibility.
//   * THE RED WAS TAKEN: the arm below, added to the canonical suite, FAILED with its own words --
//     "A MERELY PHYSICAL RELATION MUST NOT BE ROUTE-ELIGIBLE ... The route-eligible view still carrieth it:
//     [CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC]" -- in a suite of 4 tests where the other 3 stood green.
//   * THE REPAIR WAS WRITTEN AND PROVEN: `MeshNode` carrieth TWO views (route-eligible `peers`, physical
//     `presentPeers`); `handlePeerConnect` admitteth only to presence; `handlePeerDisconnect` withdraweth
//     from BOTH (a departed radio cannot route); `trustedPeerDidConnect(nodeId:peerId:)` admitteth to the
//     ROUTE, and `trustedPeerDidDisconnect(nodeId:peerId:)` withdraweth it; and `ComposedRuntime.link`
//     passeth the handle with the trust. WITH IT, the affected suites ran 40 tests, 0 failures -- the
//     completed arm and the re-framed presence arm among them.
//   * AND ITS BLAST RADIUS WAS MEASURED: the FULL iOS lane ran 1209 tests with 43 FAILURES, across FOUR
//     suites that model a peer as `transportDidConnect` alone -- ReadinessT39 16, MeshNodeDelivery 13,
//     ReadinessT43 11, MeshNodeSosDispatch 3. THE PRODUCTION LAW IS NOT BROKEN: THE RIGS MODEL THE OLD ONE
//     (presence = routable), so each must bring its relay up the REAL way: the handle, THEN the trust.
//   * THE WHOLE CHANGE IS PRESERVED AS A RE-APPLIABLE PATCH:
//     `.../REMEDIATION/IOS-02/round190-step-5-route-eligibility.patch` (sha256 92a5f898c78f4830...).
//
// THE RECONCILIATION FAILED THREE TIMES, AND EACH FAILURE IS NAMED SO THE NEXT ROUND NEED NOT REPEAT IT:
//   (a) a LINE-ANCHORED regex matched NOTHING in ReadinessT39, because its calls sit INLINE inside a loop
//       (`for i in 0..<peers { rig.node.transportDidConnect(peerId: UUID(uuidString: Self.peerUuid(i))!) }`);
//   (b) an assumed closing-brace anchor (`\n}\n`) did not fit the Delivery file, and the script ABORTED
//       BEFORE WRITING (which is why nothing was left half-patched);
//   (c) a BALANCED-PAREN scan reconciled 8 more sites but inserted a call INSIDE AN ARGUMENT LIST, and the
//       module then failed to compile: `MeshNodeSosDispatchTests.swift:185: expected ',' separator`.
//       THE LESSON: A MECHANICAL EDIT MUST KNOW WHERE A STATEMENT MAY BEGIN, not merely where its text is.
//   Nothing was left broken: the tree was REVERTED, the lane re-measured green, and the patch kept.
//
// THE ARM, EXACTLY AS IT RAN:

/*
    /// IOS-02, the card's fifth step: "MeshNode's route-eligible peers must be populated from that event
    /// [the matching confirmation], not physical duplex."
    ///
    /// THIS ASSERTION IS DELIBERATELY HALF THE LAW AT FIRST, AND IT COMPILES AGAINST THE TREE AS IT
    /// STANDETH: the other half -- that the TRUSTED event is what ADMITTETH a peer -- is added WITH the
    /// repair, because an arm that calleth an API which doth not yet exist cannot run, AND A RED MUST RUN.
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

    // AND THE ARM THAT ENCODED THE OLD LAW IS RE-FRAMED, NOT DELETED: its transitions are those of the
    // PRESENCE view, and the law it must not violate is stated beside them --
    //   func testThePresenceViewFollowethPresenceTransitionsByContent() throws { ... }
    //   XCTAssertTrue(node.knownPeersForTest().isEmpty,
    //                 "AND PRESENCE CONFERRETH NO ROUTE: the route-eligible view stayeth empty until the "
    //                 + "matching confirmation (IOS-02 step 5)")
*/
//
// THE PLAN FOR THE NEXT ROUND, IN ORDER: (1) apply the patch; (2) bring each relay-rig peer up the real way
// -- `transportDidConnect(peerId: h)` THEN `trustedPeerDidConnect(nodeId: Self.trustedNodeId(for: h),
// peerId: h)`, with the helper `static func trustedNodeId(for handle: UUID) -> Data {
// withUnsafeBytes(of: handle.uuid) { Data($0) } }` -- EDITING BY CONSTRUCTION SITE (per file, per helper)
// RATHER THAN BY TEXT PATTERN; (3) run the whole lane; (4) move this arm into the canonical suite.
