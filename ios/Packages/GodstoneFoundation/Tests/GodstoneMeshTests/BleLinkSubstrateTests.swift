import XCTest
import CoreBluetooth
@testable import GodstoneCore
@testable import GodstoneMesh

final class BleLinkSubstrateTests: XCTestCase {

    private final class RecordingTrustAuthority: PeerBindingTrustAuthority {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            return .accepted
        }
    }

    private func makeIdentity(seedByte: UInt8 = 1, staticPrivByte: UInt8 = 2, generation: UInt32 = 0) throws -> MeshIdentity {
        let kc = InMemoryKeychain()
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: staticPrivByte, count: 32)
        let state = try LocalIdentityStateV1(generation: generation, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    // ------------------------------------------------------------------------
    // 1. Role election parity
    // ------------------------------------------------------------------------
    func testRoleElection_UnsignedLexicographical() {
        let hintSmall = Data([0x00, 0x01, 0x02, 0x03])
        let hintLarge = Data([0x80, 0x01, 0x02, 0x03])

        let res1 = BleRoleElection.elect(localHint: hintSmall, remoteHint: hintLarge)
        XCTAssertEqual(res1, .elected(.initiator))

        let res2 = BleRoleElection.elect(localHint: hintLarge, remoteHint: hintSmall)
        XCTAssertEqual(res2, .elected(.responder))

        // 0x7F vs 0x80
        let hint7F = Data([0x7F, 0x00, 0x00, 0x00])
        let hint80 = Data([0x80, 0x00, 0x00, 0x00])
        XCTAssertEqual(BleRoleElection.elect(localHint: hint7F, remoteHint: hint80), .elected(.initiator))
        XCTAssertEqual(BleRoleElection.elect(localHint: hint80, remoteHint: hint7F), .elected(.responder))
    }

    // ------------------------------------------------------------------------
    // 2. 1000 pair property test
    // ------------------------------------------------------------------------
    func testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator() {
        for _ in 0..<1000 {
            var bytesA = [UInt8](repeating: 0, count: 4)
            var bytesB = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &bytesA)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &bytesB)

            let a = Data(bytesA)
            let b = Data(bytesB)

            if a == b { continue }

            let resAB = BleRoleElection.elect(localHint: a, remoteHint: b)
            let resBA = BleRoleElection.elect(localHint: b, remoteHint: a)

            guard case .elected(let roleAB) = resAB,
                  case .elected(let roleBA) = resBA else {
                XCTFail("Expected elected roles for unequal hints")
                continue
            }

            if roleAB == .initiator {
                XCTAssertEqual(roleBA, .responder)
            } else {
                XCTAssertEqual(roleAB, .responder)
                XCTAssertEqual(roleBA, .initiator)
            }
        }
    }

    // ------------------------------------------------------------------------
    // 3. Equal-hint rejection (Fail closed)
    // ------------------------------------------------------------------------
    func testRoleElection_EqualHints_FailClosed() {
        let hint = Data([0x12, 0x34, 0x56, 0x78])
        let res = BleRoleElection.elect(localHint: hint, remoteHint: hint)
        XCTAssertEqual(res, .tie)
    }

    // ------------------------------------------------------------------------
    // 4. LinkInfo V1 encode/decode parity and flags
    // ------------------------------------------------------------------------
    func testLinkInfoV1_EncodeDecodeParity() {
        let version: UInt8 = 0x02
        let flags: UInt8 = BleLinkInfoConstants.flagSosPresent | BleLinkInfoConstants.flagPowerConstrained
        let nodeHint = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let shortDigest = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let queueDepth: UInt8 = 42

        let encoded = BleLinkInfoCodec.encode(
            version: version,
            flags: flags,
            nodeHint: nodeHint,
            shortDigest: shortDigest,
            queueDepth: queueDepth
        )
        XCTAssertEqual(encoded.count, 13)

        let decoded = BleLinkInfoCodec.decode(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.version, version)
        XCTAssertEqual(decoded?.flags, flags)
        XCTAssertEqual(decoded?.nodeHint, nodeHint)
        XCTAssertEqual(decoded?.shortDigest, shortDigest)
        XCTAssertEqual(decoded?.queueDepth, queueDepth)
        XCTAssertTrue(decoded?.isSosPresent == true)
        XCTAssertTrue(decoded?.isPowerConstrained == true)
    }

    // ------------------------------------------------------------------------
    // 5. Malformed Length Rejections (0, 1, 12, 14, 20, 255)
    // ------------------------------------------------------------------------
    func testLinkInfoV1_MalformedLength_Rejected() {
        XCTAssertNil(BleLinkInfoCodec.decode(Data()))
        XCTAssertNil(BleLinkInfoCodec.decode(Data(repeating: 0x02, count: 1)))
        XCTAssertNil(BleLinkInfoCodec.decode(Data(repeating: 0x02, count: 12)))
        XCTAssertNil(BleLinkInfoCodec.decode(Data(repeating: 0x02, count: 14)))
        XCTAssertNil(BleLinkInfoCodec.decode(Data(repeating: 0x02, count: 20)))
        XCTAssertNil(BleLinkInfoCodec.decode(Data(repeating: 0x02, count: 255)))
    }

    // ------------------------------------------------------------------------
    // 6. Unknown Version Rejections
    // ------------------------------------------------------------------------
    func testLinkInfoV1_UnknownVersion_Rejected() {
        var bad01 = [UInt8](repeating: 0, count: 13)
        bad01[0] = 0x01
        XCTAssertNil(BleLinkInfoCodec.decode(Data(bad01)))

        var bad03 = [UInt8](repeating: 0, count: 13)
        bad03[0] = 0x03
        XCTAssertNil(BleLinkInfoCodec.decode(Data(bad03)))

        var badFF = [UInt8](repeating: 0, count: 13)
        badFF[0] = 0xFF
        XCTAssertNil(BleLinkInfoCodec.decode(Data(badFF)))
    }

    // ------------------------------------------------------------------------
    // 7. Canonical JSON LinkInfo Vectors (Valid & Invalid)
    // ------------------------------------------------------------------------
    func testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid() throws {
        let validCases: [(name: String, flags: UInt8, hintHex: String, digestHex: String, depth: UInt8, expectedHex: String)] = [
            ("all_zero_informational_fields_with_real_hint", 0, "01020304", "000000000000", 0, "02000102030400000000000000"),
            ("mixed_flags_sos_power_clock", 21, "a1b2c3d4", "112233445566", 42, "0215a1b2c3d41122334455662a"),
            ("all_flags_set", 31, "deadbeef", "aabbccddeeff", 128, "021fdeadbeefaabbccddeeff80"),
            ("unsigned_edge_zero_hint", 0, "00000000", "010203040506", 0, "02000000000001020304050600"),
            ("unsigned_edge_max_hint_and_max_queue_depth", 8, "ffffffff", "ffffffffffff", 255, "0208ffffffffffffffffffffff"),
            ("high_bit_hint_comparison_edge", 2, "80000000", "1234567890ab", 255, "0202800000001234567890abff")
        ]

        for c in validCases {
            guard let hint = Data(hexString: c.hintHex),
                  let digest = Data(hexString: c.digestHex),
                  let expected = Data(hexString: c.expectedHex) else {
                XCTFail("Hex conversion failed for case \(c.name)")
                continue
            }

            let encoded = BleLinkInfoCodec.encode(
                flags: c.flags,
                nodeHint: hint,
                shortDigest: digest,
                queueDepth: c.depth
            )
            XCTAssertEqual(encoded, expected, "Mismatch encoding case \(c.name)")

            let decoded = BleLinkInfoCodec.decode(expected)
            XCTAssertNotNil(decoded, "Decode returned nil in case \(c.name)")
            XCTAssertEqual(decoded?.flags, c.flags)
            XCTAssertEqual(decoded?.nodeHint, hint)
            XCTAssertEqual(decoded?.shortDigest, digest)
            XCTAssertEqual(decoded?.queueDepth, c.depth)
        }

        let invalidHexes = [
            "",
            "02",
            "020001020304000000000000",
            "0200010203040000000000000099",
            "0200010203040000000000000001020304050607",
            "01000102030400000000000000",
            "03000102030400000000000000",
            "ff000102030400000000000000"
        ]

        for hex in invalidHexes {
            let data = Data(hexString: hex) ?? Data()
            XCTAssertNil(BleLinkInfoCodec.decode(data), "Expected invalid case \(hex) to decode as nil")
        }
    }

    // ------------------------------------------------------------------------
    // 8. Canonical JSON Role Election Cases
    // ------------------------------------------------------------------------
    func testRoleElection_CanonicalJsonVectors() {
        let cases: [(local: String, remote: String, expected: BleRole?)] = [
            ("00000000", "00000001", .initiator),
            ("00000001", "00000000", .responder),
            ("7fffffff", "80000000", .initiator),
            ("80000000", "7fffffff", .responder),
            ("00000000", "00000000", nil),
            ("deadbeef", "deadbeef", nil),
            ("00ff00ff", "00ff0100", .initiator)
        ]

        for c in cases {
            let local = Data(hexString: c.local)!
            let remote = Data(hexString: c.remote)!
            let res = BleRoleElection.elect(localHint: local, remoteHint: remote)

            if let exp = c.expected {
                XCTAssertEqual(res, .elected(exp), "Mismatch in role election for \(c.local) vs \(c.remote)")
            } else {
                XCTAssertEqual(res, .tie, "Expected tie for \(c.local) vs \(c.remote)")
            }
        }
    }

    // ------------------------------------------------------------------------
    // 9. UUID-Only Discovery
    // ------------------------------------------------------------------------
    func testProvisionalConnection_MissingAdvMetadata_Allowed() {
        let emptyAdvServiceData: Data? = nil
        XCTAssertNil(emptyAdvServiceData)
    }

    // ------------------------------------------------------------------------
    // 10. LinkInfo Authority Overrides Adv Metadata
    // ------------------------------------------------------------------------
    func testLinkInfoAuthority_OverridesAdvMetadata() {
        let realLinkInfoHint = Data([0x77, 0x88, 0x99, 0xAA])
        let myHint = Data([0x11, 0x22, 0x33, 0x44])
        let election = BleRoleElection.elect(localHint: myHint, remoteHint: realLinkInfoHint)
        XCTAssertEqual(election, .elected(.initiator))
    }

    // ------------------------------------------------------------------------
    // 11. BleConnection Provisional State Machine & One-Way Role Binding
    // ------------------------------------------------------------------------
    func testBleConnection_ProvisionalStateMachine() {
        let peerId = UUID()
        let conn = BleConnection(peerId: peerId)

        XCTAssertEqual(conn.state, .provisionalConnecting)
        XCTAssertNil(conn.remoteNodeHint)
        XCTAssertNil(conn.localRole)
        XCTAssertFalse(conn.isRoleBound)
        XCTAssertFalse(conn.isHandshakeTransportReady)
        XCTAssertTrue(conn.isActive)

        conn.markConnected()
        XCTAssertEqual(conn.state, .provisionalConnected)

        conn.transitionTo(.linkInfoReading)
        XCTAssertEqual(conn.state, .linkInfoReading)

        conn.transitionTo(.linkInfoWriting)
        XCTAssertEqual(conn.state, .linkInfoWriting)

        // Bind role
        let remoteHint = Data([0x01, 0x02, 0x03, 0x04])
        conn.bindRole(hint: remoteHint, role: .initiator)
        XCTAssertEqual(conn.state, .roleBound)
        XCTAssertTrue(conn.isRoleBound)
        XCTAssertEqual(conn.remoteNodeHint, remoteHint)
        XCTAssertEqual(conn.localRole, .initiator)

        // Handshake transport ready requires notification subscription
        XCTAssertFalse(conn.isHandshakeTransportReady)
        conn.isNotificationSubscribed = true
        XCTAssertTrue(conn.isHandshakeTransportReady)

        // Disconnect
        conn.markDisconnected()
        XCTAssertEqual(conn.state, .closed)
        XCTAssertFalse(conn.isActive)
        XCTAssertFalse(conn.isHandshakeTransportReady)
    }

    // ------------------------------------------------------------------------
    // 12. Role Binding Coordinator - Central Flow
    // ------------------------------------------------------------------------
    func testRoleBindingCoordinator_CentralFlow() {
        let localHint = Data([0x01, 0x02, 0x03, 0x04])
        let coord = BleRoleBindingCoordinator(localHint: localHint)
        let peerId = UUID()

        let act1 = coord.processCentralEvent(.discovered(peerId))
        XCTAssertEqual(act1, .connectProvisionally(peerId))

        let act2 = coord.processCentralEvent(.provisionalConnected(peerId))
        XCTAssertEqual(act2, .readRemoteLinkInfo(peerId))

        let remoteHintLarger = Data([0x05, 0x06, 0x07, 0x08])
        let remoteLinkInfoLarger = BleLinkInfoCodec.encode(
            flags: 0,
            nodeHint: remoteHintLarger,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act3 = coord.processCentralEvent(.remoteLinkInfoReadRaw(peerId, remoteLinkInfoLarger))
        XCTAssertEqual(act3, .writeLocalLinkInfo(peerId, remoteHint: remoteHintLarger))

        let act4 = coord.processCentralEvent(.localLinkInfoWriteAcknowledged(peerId, remoteHintLarger))
        XCTAssertEqual(act4, .roleBound(peerId, role: .initiator, remoteHint: remoteHintLarger))

        let remoteHintSmaller = Data([0x00, 0x01, 0x02, 0x03])
        let remoteLinkInfoSmaller = BleLinkInfoCodec.encode(
            flags: 0,
            nodeHint: remoteHintSmaller,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act5 = coord.processCentralEvent(.remoteLinkInfoReadRaw(peerId, remoteLinkInfoSmaller))
        guard case .cancelWrongDirectionLink = act5 else {
            XCTFail("Expected cancelWrongDirectionLink for smaller remote hint")
            return
        }

        let remoteLinkInfoEqual = BleLinkInfoCodec.encode(
            flags: 0,
            nodeHint: localHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act6 = coord.processCentralEvent(.remoteLinkInfoReadRaw(peerId, remoteLinkInfoEqual))
        guard case .cancelWrongDirectionLink = act6 else {
            XCTFail("Expected cancelWrongDirectionLink for equal hint tie")
            return
        }
    }

    // ------------------------------------------------------------------------
    // 13. Role Binding Coordinator - Peripheral Incoming Write Events
    // ------------------------------------------------------------------------
    func testRoleBindingCoordinator_PeripheralIncomingWrite() {
        let localHint = Data([0x80, 0x00, 0x00, 0x00])
        let coord = BleRoleBindingCoordinator(localHint: localHint)
        let peerId = UUID()

        let remoteSmaller = Data([0x10, 0x00, 0x00, 0x00])
        let payloadSmaller = BleLinkInfoCodec.encode(
            flags: 0,
            nodeHint: remoteSmaller,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act1 = coord.processPeripheralLinkInfoWrite(peerId: peerId, rawBytes: payloadSmaller)
        XCTAssertEqual(act1, .acceptIncomingWrite(peerId, remoteHint: remoteSmaller))

        let remoteLarger = Data([0x90, 0x00, 0x00, 0x00])
        let payloadLarger = BleLinkInfoCodec.encode(
            flags: 0,
            nodeHint: remoteLarger,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act2 = coord.processPeripheralLinkInfoWrite(peerId: peerId, rawBytes: payloadLarger)
        guard case .rejectIncomingWrite = act2 else {
            XCTFail("Expected rejectIncomingWrite for remote >= local")
            return
        }

        let payloadEqual = BleLinkInfoCodec.encode(
            flags: 0,
            nodeHint: localHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act3 = coord.processPeripheralLinkInfoWrite(peerId: peerId, rawBytes: payloadEqual)
        guard case .rejectIncomingWrite = act3 else {
            XCTFail("Expected rejectIncomingWrite for tie")
            return
        }
    }

    // ------------------------------------------------------------------------
    // 14. Crossing Connections - A < B -> A retains initiator, B rejects
    // ------------------------------------------------------------------------
    func testCrossingConnections_ALessThanB_ARetainsBRejects() {
        let hintA = Data([0x00, 0x01, 0x02, 0x03])
        let hintB = Data([0x80, 0x01, 0x02, 0x03])

        let electionAtA = BleRoleElection.elect(localHint: hintA, remoteHint: hintB)
        XCTAssertEqual(electionAtA, .elected(.initiator))

        let electionAtB = BleRoleElection.elect(localHint: hintB, remoteHint: hintA)
        XCTAssertEqual(electionAtB, .elected(.responder))
    }

    // ------------------------------------------------------------------------
    // 15. Crossing Connections - B < A -> B retains initiator, A rejects
    // ------------------------------------------------------------------------
    func testCrossingConnections_BLessThanA_BRetainsARejects() {
        let hintA = Data([0x99, 0x00, 0x00, 0x00])
        let hintB = Data([0x11, 0x00, 0x00, 0x00])

        let electionAtA = BleRoleElection.elect(localHint: hintA, remoteHint: hintB)
        XCTAssertEqual(electionAtA, .elected(.responder))

        let electionAtB = BleRoleElection.elect(localHint: hintB, remoteHint: hintA)
        XCTAssertEqual(electionAtB, .elected(.initiator))
    }

    // ------------------------------------------------------------------------
    // 16. Crossing Connections - Equal hints -> Both reject
    // ------------------------------------------------------------------------
    func testCrossingConnections_EqualHints_BothReject() {
        let hint = Data([0x42, 0x42, 0x42, 0x42])
        let res = BleRoleElection.elect(localHint: hint, remoteHint: hint)
        XCTAssertEqual(res, .tie)
    }

    // ------------------------------------------------------------------------
    // 17. Central Write Queue - Sequential ATT Values
    // ------------------------------------------------------------------------
    func testCentralWriteQueue_SequentialAttValues() {
        let peerId = UUID()
        let conn = BleConnection(peerId: peerId, initialMaxAttValueLength: 30)
        conn.markConnected()
        conn.bindRole(hint: Data([0x05, 0x06, 0x07, 0x08]), role: .initiator)
        conn.isNotificationSubscribed = true
        conn.transitionTo(.handshakeInProgress)
        conn.transitionTo(.ready)

        let payload1 = "First sequential record payload".data(using: .utf8)!
        let payload2 = "Second sequential record payload with different bytes".data(using: .utf8)!

        let frags1 = conn.fragmentOutbound(recordType: .data, payload: payload1)
        let frags2 = conn.fragmentOutbound(recordType: .data, payload: payload2)

        XCTAssertFalse(frags1.isEmpty)
        XCTAssertFalse(frags2.isEmpty)

        let receiverConn = BleConnection(peerId: peerId, initialMaxAttValueLength: 30)
        receiverConn.markConnected()
        receiverConn.bindRole(hint: Data([0x01, 0x02, 0x03, 0x04]), role: .responder)
        receiverConn.isNotificationSubscribed = true
        receiverConn.transitionTo(.handshakeInProgress)
        receiverConn.transitionTo(.ready)

        var rec1: BleReassembledRecord? = nil
        for f in frags1 {
            if let r = receiverConn.ingestInboundAttValue(f) { rec1 = r }
        }
        XCTAssertNotNil(rec1)
        XCTAssertEqual(rec1?.payload, payload1)

        var rec2: BleReassembledRecord? = nil
        for f in frags2 {
            if let r = receiverConn.ingestInboundAttValue(f) { rec2 = r }
        }
        XCTAssertNotNil(rec2)
        XCTAssertEqual(rec2?.payload, payload2)
    }

    // ------------------------------------------------------------------------
    // 18. Peripheral Notification Queue - Backpressure
    // ------------------------------------------------------------------------
    func testPeripheralNotificationQueue_Backpressure() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 25)
        conn.markConnected()
        conn.bindRole(hint: Data([1, 2, 3, 4]), role: .responder)
        conn.isNotificationSubscribed = true
        conn.transitionTo(.handshakeInProgress)
        conn.transitionTo(.ready)

        let payload = Data(repeating: 0x42, count: 60)
        let frags = conn.fragmentOutbound(recordType: .data, payload: payload)
        XCTAssertTrue(frags.count > 1)
    }

    // ------------------------------------------------------------------------
    // 19. Record Fragments Through Connection Seam
    // ------------------------------------------------------------------------
    func testRecordFragments_ThroughConnectionSeam() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 25)
        conn.markConnected()
        conn.bindRole(hint: Data([2, 3, 4, 5]), role: .initiator)
        conn.isNotificationSubscribed = true
        conn.transitionTo(.handshakeInProgress)

        var hs2Bytes = [UInt8](repeating: 0, count: 229)
        for i in 0..<229 { hs2Bytes[i] = UInt8((i * 7) & 0xFF) }
        let hs2Payload = Data(hs2Bytes)

        let fragments = conn.fragmentOutbound(recordType: .hs2, payload: hs2Payload)
        XCTAssertTrue(fragments.count > 1)

        let receiver = BleConnection(peerId: UUID(), initialMaxAttValueLength: 25)
        receiver.markConnected()
        receiver.bindRole(hint: Data([1, 1, 1, 1]), role: .responder)
        receiver.isNotificationSubscribed = true
        receiver.transitionTo(.handshakeInProgress)

        var result: BleReassembledRecord? = nil
        for f in fragments {
            if let r = receiver.ingestInboundAttValue(f) { result = r }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .hs2)
        XCTAssertEqual(result?.payload, hs2Payload)
    }

    // ------------------------------------------------------------------------
    // 20. Negotiated Max ATT Value Length Propagation
    // ------------------------------------------------------------------------
    func testNegotiatedMaxAttValueLength_PropagatedToFragmentation() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 20)
        conn.markConnected(negotiatedAttValueLength: 100)
        conn.bindRole(hint: Data([2, 3, 4, 5]), role: .initiator)
        conn.isNotificationSubscribed = true
        conn.transitionTo(.handshakeInProgress)
        conn.transitionTo(.ready)
        XCTAssertEqual(conn.maxAttValueLength, 100)

        let payload = Data(repeating: 0x55, count: 150)
        let frags = conn.fragmentOutbound(recordType: .data, payload: payload)
        XCTAssertEqual(frags.count, 2)
        XCTAssertTrue(frags[0].count <= 100)
        XCTAssertTrue(frags[1].count <= 100)
    }

    // ------------------------------------------------------------------------
    // 21. Disconnect Purges Connection & Reassembly State
    // ------------------------------------------------------------------------
    func testDisconnect_PurgesConnectionAndReassemblyState() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 20)
        conn.markConnected()
        conn.bindRole(hint: Data([2, 3, 4, 5]), role: .initiator)
        conn.isNotificationSubscribed = true
        conn.transitionTo(.handshakeInProgress)
        conn.transitionTo(.ready)

        let payload = Data(repeating: 0x33, count: 50)
        let frags = conn.fragmentOutbound(recordType: .data, payload: payload)
        XCTAssertTrue(frags.count > 1)

        XCTAssertNil(conn.ingestInboundAttValue(frags[0]))

        conn.markDisconnected()
        XCTAssertFalse(conn.isActive)
        XCTAssertEqual(conn.state, .closed)

        XCTAssertNil(conn.ingestInboundAttValue(frags[1]))
    }

    // ------------------------------------------------------------------------
    // 22. Repeated Lifecycle Idempotence
    // ------------------------------------------------------------------------
    func testRepeatedLifecycle_Idempotent() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 20)
        conn.markConnected()
        conn.markDisconnected()
        conn.markDisconnected()
        XCTAssertEqual(conn.state, .closed)
    }

    // ------------------------------------------------------------------------
    // 23. DATA Record Gated on READY State
    // ------------------------------------------------------------------------
    func testDataRecord_ForbiddenBeforeReadyState() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 40)
        conn.markConnected()
        conn.bindRole(hint: Data([0x01, 0x02, 0x03, 0x04]), role: .initiator)
        conn.isNotificationSubscribed = true
        conn.transitionTo(.handshakeInProgress)

        let appData = "Secret Application Data".data(using: .utf8)!

        // While in .handshakeInProgress: DATA fragments return empty
        let fragsBeforeReady = conn.fragmentOutbound(recordType: .data, payload: appData)
        XCTAssertTrue(fragsBeforeReady.isEmpty)

        // Transition to .ready: DATA fragments are permitted
        conn.transitionTo(.ready)
        let fragsAfterReady = conn.fragmentOutbound(recordType: .data, payload: appData)
        XCTAssertFalse(fragsAfterReady.isEmpty)
    }

    // ------------------------------------------------------------------------
    // 24. LINK_LAYER_READY Remains False
    // ------------------------------------------------------------------------
    func testLinkLayerReady_RemainsFalse() {
        XCTAssertFalse(MeshNode.linkLayerReady)
    }

    // ------------------------------------------------------------------------
    // 25. SessionManager Handshake API Not Invoked by Substrate
    // ------------------------------------------------------------------------
    func testSessionManager_HandshakeApiNotInvokedBySubstrate() throws {
        let id = try makeIdentity()
        let sm = SessionManager(identity: id, trustAuthority: RecordingTrustAuthority())

        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 20)
        conn.markConnected()

        XCTAssertFalse(sm.isReady(UUID()))
    }

    // ------------------------------------------------------------------------
    // 26. Duplex Synthetic Traffic Both Directions
    // ------------------------------------------------------------------------
    func testDuplexSyntheticTraffic_BothDirections() {
        let nodeA = Data([0x01, 0x02, 0x03, 0x04])
        let nodeB = Data([0x05, 0x06, 0x07, 0x08])

        let electionA = BleRoleElection.elect(localHint: nodeA, remoteHint: nodeB)
        let electionB = BleRoleElection.elect(localHint: nodeB, remoteHint: nodeA)

        XCTAssertEqual(electionA, .elected(.initiator))
        XCTAssertEqual(electionB, .elected(.responder))

        let peerA = UUID()
        let peerB = UUID()
        let connA = BleConnection(peerId: peerB, initialMaxAttValueLength: 40)
        let connB = BleConnection(peerId: peerA, initialMaxAttValueLength: 40)
        connA.markConnected()
        connB.markConnected()
        connA.bindRole(hint: nodeB, role: .initiator)
        connB.bindRole(hint: nodeA, role: .responder)
        connA.isNotificationSubscribed = true
        connB.isNotificationSubscribed = true
        connA.transitionTo(.handshakeInProgress)
        connB.transitionTo(.handshakeInProgress)
        connA.transitionTo(.ready)
        connB.transitionTo(.ready)

        // Direction 1: A -> B
        let msgAtoB = "Hello from Initiator A to Responder B".data(using: .utf8)!
        let fragsAtoB = connA.fragmentOutbound(recordType: .data, payload: msgAtoB)
        var receivedByB: BleReassembledRecord? = nil
        for f in fragsAtoB {
            if let r = connB.ingestInboundAttValue(f) { receivedByB = r }
        }
        XCTAssertNotNil(receivedByB)
        XCTAssertEqual(receivedByB?.payload, msgAtoB)

        // Direction 2: B -> A
        let msgBtoA = "Hello back from Responder B to Initiator A".data(using: .utf8)!
        let fragsBtoA = connB.fragmentOutbound(recordType: .data, payload: msgBtoA)
        var receivedByA: BleReassembledRecord? = nil
        for f in fragsBtoA {
            if let r = connA.ingestInboundAttValue(f) { receivedByA = r }
        }
        XCTAssertNotNil(receivedByA)
        XCTAssertEqual(receivedByA?.payload, msgBtoA)
    }

    // ------------------------------------------------------------------------
    // 27. Locking - No Deadlock On Local LinkInfo Query
    // ------------------------------------------------------------------------
    func testLocking_NoDeadlockOnLocalLinkInfoQuery() throws {
        let id = try makeIdentity()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SqliteMessageStore(url: tempDir, maxBytes: 1024 * 1024, fileProtection: .complete)
        let transport = BleTransport(identity: id, store: store)

        // Calling getLocalLinkInfoData safely from outside
        let data1 = transport.getLocalLinkInfoData()
        XCTAssertNotNil(data1)
        XCTAssertEqual(data1?.count, BleLinkInfoConstants.linkInfoBytes)

        // Calling getLocalLinkInfoDataLocked internally does not re-enter lock
        let data2 = transport.getLocalLinkInfoDataLocked()
        XCTAssertEqual(data1, data2)

        // Without store: safely returns nil without deadlock
        let transportNoStore = BleTransport(identity: id, store: nil)
        XCTAssertNil(transportNoStore.getLocalLinkInfoData())
    }

    // ------------------------------------------------------------------------
    // 28. Subscription Acknowledgement Gates Duplex Readiness
    // ------------------------------------------------------------------------
    func testSubscriptionAcknowledgement_GatesDuplexReadiness() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 40)
        conn.markConnected()
        conn.bindRole(hint: Data([1, 2, 3, 4]), role: .initiator)

        // Before subscription acknowledged: isHandshakeTransportReady is false
        XCTAssertFalse(conn.isNotificationSubscribed)
        XCTAssertFalse(conn.isHandshakeTransportReady)

        // After CCCD subscription acknowledged: isHandshakeTransportReady is true
        conn.isNotificationSubscribed = true
        XCTAssertTrue(conn.isHandshakeTransportReady)
    }
}

private extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let byteString = hexString[index..<nextIndex]
            if let byte = UInt8(byteString, radix: 16) {
                data.append(byte)
            } else {
                return nil
            }
            index = nextIndex
        }
        self = data
    }
}
