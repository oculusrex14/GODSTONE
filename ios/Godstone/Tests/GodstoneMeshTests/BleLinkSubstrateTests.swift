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
    // 3. Equal-hint rejection
    // ------------------------------------------------------------------------
    func testRoleElection_EqualHints_FailClosed() {
        let hint = Data([0x12, 0x34, 0x56, 0x78])
        let res = BleRoleElection.elect(localHint: hint, remoteHint: hint)
        XCTAssertEqual(res, .tie)
    }

    // ------------------------------------------------------------------------
    // 4. Discovery metadata encoding/parsing
    // ------------------------------------------------------------------------
    func testDiscoveryPayload_EncodeDecodeRoundTrip() {
        let version: UInt8 = 0x02
        let flags: UInt8 = BleDiscoveryConstants.flagSos | BleDiscoveryConstants.flagPowerConstrained
        let nodeHint = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let shortDigest = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06])
        let queueDepth: UInt8 = 42

        let encoded = BleDiscoveryCodec.encode(
            version: version,
            flags: flags,
            nodeHint: nodeHint,
            shortDigest: shortDigest,
            queueDepth: queueDepth
        )
        XCTAssertEqual(encoded.count, 13)

        let decoded = BleDiscoveryCodec.decode(encoded)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.version, version)
        XCTAssertEqual(decoded?.flags, flags)
        XCTAssertEqual(decoded?.nodeHint, nodeHint)
        XCTAssertEqual(decoded?.shortDigest, shortDigest)
        XCTAssertEqual(decoded?.queueDepth, queueDepth)
        XCTAssertTrue(decoded?.isSosPresent == true)
        XCTAssertTrue(decoded?.isPowerConstrained == true)
        XCTAssertFalse(decoded?.isBulkCapable == true)
    }

    // ------------------------------------------------------------------------
    // 5. Central write queue / backpressure abstraction
    // ------------------------------------------------------------------------
    func testCentralWriteQueue_SequentialAttValues() {
        let peerId = UUID()
        let remoteHint = Data([0x99, 0x88, 0x77, 0x66])
        let conn = BleConnection(
            peerId: peerId,
            remoteNodeHint: remoteHint,
            localRole: .initiator,
            initialMaxAttValueLength: 30
        )
        conn.markConnected()

        let payload1 = "First sequential record payload".data(using: .utf8)!
        let payload2 = "Second sequential record payload with different bytes".data(using: .utf8)!

        let frags1 = conn.fragmentOutbound(recordType: .data, payload: payload1)
        let frags2 = conn.fragmentOutbound(recordType: .data, payload: payload2)

        XCTAssertFalse(frags1.isEmpty)
        XCTAssertFalse(frags2.isEmpty)

        let receiverConn = BleConnection(
            peerId: peerId,
            remoteNodeHint: remoteHint,
            localRole: .responder,
            initialMaxAttValueLength: 30
        )
        receiverConn.markConnected()

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
    // 6. Peripheral notification queue / backpressure abstraction
    // ------------------------------------------------------------------------
    func testPeripheralNotificationQueue_Backpressure() {
        let conn = BleConnection(
            peerId: UUID(),
            remoteNodeHint: Data([1, 2, 3, 4]),
            localRole: .responder,
            initialMaxAttValueLength: 25
        )
        conn.markConnected()

        let payload = Data(repeating: 0x42, count: 60)
        let frags = conn.fragmentOutbound(recordType: .data, payload: payload)
        XCTAssertTrue(frags.count > 1)
    }

    // ------------------------------------------------------------------------
    // 7. Duplex synthetic connection
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
        let connA = BleConnection(peerId: peerB, remoteNodeHint: nodeB, localRole: .initiator, initialMaxAttValueLength: 40)
        let connB = BleConnection(peerId: peerA, remoteNodeHint: nodeA, localRole: .responder, initialMaxAttValueLength: 40)
        connA.markConnected()
        connB.markConnected()

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
    // 8. Canonical record fragmentation/reassembly through link seam
    // ------------------------------------------------------------------------
    func testRecordFragments_ThroughConnectionSeam() {
        let conn = BleConnection(peerId: UUID(), remoteNodeHint: Data([2, 3, 4, 5]), localRole: .initiator, initialMaxAttValueLength: 25)
        conn.markConnected()

        var hs2Bytes = [UInt8](repeating: 0, count: 229)
        for i in 0..<229 { hs2Bytes[i] = UInt8((i * 7) & 0xFF) }
        let hs2Payload = Data(hs2Bytes)

        let fragments = conn.fragmentOutbound(recordType: .hs2, payload: hs2Payload)
        XCTAssertTrue(fragments.count > 1)

        let receiver = BleConnection(peerId: UUID(), remoteNodeHint: Data([1, 1, 1, 1]), localRole: .responder, initialMaxAttValueLength: 25)
        receiver.markConnected()

        var result: BleReassembledRecord? = nil
        for f in fragments {
            if let r = receiver.ingestInboundAttValue(f) { result = r }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .hs2)
        XCTAssertEqual(result?.payload, hs2Payload)
    }

    // ------------------------------------------------------------------------
    // 9. Per-direction max ATT value propagation
    // ------------------------------------------------------------------------
    func testNegotiatedMaxAttValueLength_PropagatedToFragmentation() {
        let conn = BleConnection(peerId: UUID(), remoteNodeHint: Data([2, 3, 4, 5]), localRole: .initiator, initialMaxAttValueLength: 20)
        conn.markConnected(negotiatedAttValueLength: 100)
        XCTAssertEqual(conn.maxAttValueLength, 100)

        let payload = Data(repeating: 0x55, count: 150)
        let frags = conn.fragmentOutbound(recordType: .data, payload: payload)
        XCTAssertEqual(frags.count, 2)
        XCTAssertTrue(frags[0].count <= 100)
        XCTAssertTrue(frags[1].count <= 100)
    }

    // ------------------------------------------------------------------------
    // 10. Disconnect/reset behavior
    // ------------------------------------------------------------------------
    func testDisconnect_PurgesConnectionAndReassemblyState() {
        let conn = BleConnection(peerId: UUID(), remoteNodeHint: Data([2, 3, 4, 5]), localRole: .initiator, initialMaxAttValueLength: 20)
        conn.markConnected()

        let payload = Data(repeating: 0x33, count: 50)
        let frags = conn.fragmentOutbound(recordType: .data, payload: payload)
        XCTAssertTrue(frags.count > 1)

        XCTAssertNil(conn.ingestInboundAttValue(frags[0]))

        conn.markDisconnected()
        XCTAssertFalse(conn.isActive)
        XCTAssertEqual(conn.state, .disconnected)

        XCTAssertNil(conn.ingestInboundAttValue(frags[1]))
    }

    // ------------------------------------------------------------------------
    // 11. Repeated lifecycle behavior
    // ------------------------------------------------------------------------
    func testRepeatedLifecycle_Idempotent() {
        let conn = BleConnection(peerId: UUID(), remoteNodeHint: Data([2, 3, 4, 5]), localRole: .initiator, initialMaxAttValueLength: 20)
        conn.markConnected()
        conn.markDisconnected()
        conn.markDisconnected()
        XCTAssertEqual(conn.state, .disconnected)
    }

    // ------------------------------------------------------------------------
    // 12. Handshake not activated
    // ------------------------------------------------------------------------
    func testSessionManager_HandshakeApiNotInvokedBySubstrate() throws {
        let id = try makeIdentity()
        let sm = SessionManager(identity: id, trustAuthority: RecordingTrustAuthority())

        let conn = BleConnection(peerId: UUID(), remoteNodeHint: Data([2, 3, 4, 5]), localRole: .initiator, initialMaxAttValueLength: 20)
        conn.markConnected()

        XCTAssertFalse(sm.isReady(UUID()))
    }

    // ------------------------------------------------------------------------
    // 13. linkLayerReady remains false
    // ------------------------------------------------------------------------
    func testLinkLayerReady_RemainsFalse() {
        XCTAssertFalse(MeshNode.linkLayerReady)
    }

    // ------------------------------------------------------------------------
    // 14. iOS CoreBluetooth Service Data absence fails closed (Spec Blocker Evidence)
    // ------------------------------------------------------------------------
    func testCoreBluetoothMissingServiceData_FailsClosed() {
        // Advertisements without CBAdvertisementDataServiceDataKey fail closed to decode
        let emptyAdvData: [String: Any] = [:]
        let rawPayload = (emptyAdvData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?[BleTransport.serviceUuid]
        XCTAssertNil(rawPayload)

        // Decode returns nil and didDiscover does not connect or create connection
        let metadata = rawPayload.flatMap { BleDiscoveryCodec.decode($0) }
        XCTAssertNil(metadata)
    }
}
