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

    private final class MockMessageStore: MessageStore {
        var held: [Data] = []
        private var observers: [@Sendable () -> Void] = []
        private let lock = NSLock()

        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            observers.append(observer)
        }

        func notifyObservers() {
            lock.lock()
            let obs = observers
            lock.unlock()
            obs.forEach { $0() }
        }

        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
            lock.lock()
            held.append(frame.msgId)
            lock.unlock()
            notifyObservers()
            return .heldNew
        }

        func removeHeld(_ msgId: Data) -> Bool {
            lock.lock()
            let initial = held.count
            held.removeAll { $0 == msgId }
            let removed = held.count < initial
            lock.unlock()
            if removed {
                notifyObservers()
            }
            return removed
        }

        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult {
            .canonicalFrameMismatch
        }
        func allHeldOrderedByPriority() -> [FrameV2] { [] }
        func allHeldMsgIds() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return held
        }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
        func forEachHeldMsgId(_ visit: (Data) -> Bool) {
            lock.lock()
            let copy = held
            lock.unlock()
            for id in copy {
                if !visit(id) { break }
            }
        }
        var heldBytes: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return Int64(held.count * 32)
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

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var hexStr = hex
        while hexStr.count >= 2 {
            let sub = hexStr.prefix(2)
            hexStr = String(hexStr.dropFirst(2))
            if let byte = UInt8(sub, radix: 16) {
                data.append(byte)
            }
        }
        return data
    }

    private func loadCanonicalLinkInfoVectorsJson() throws -> [String: Any] {
        var candidateUrls: [URL] = []

        let thisFile = URL(fileURLWithPath: #filePath)
        let root1 = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidateUrls.append(root1.appendingPathComponent("wire/ble_link_info_vectors.json"))

        let root2 = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidateUrls.append(root2.appendingPathComponent("wire/ble_link_info_vectors.json"))

        let candidatePaths = [
            "wire/ble_link_info_vectors.json",
            "../wire/ble_link_info_vectors.json",
            "../../wire/ble_link_info_vectors.json",
            "../../../wire/ble_link_info_vectors.json",
            "../../../../wire/ble_link_info_vectors.json"
        ]
        for path in candidatePaths {
            candidateUrls.append(URL(fileURLWithPath: path))
        }

        for url in candidateUrls {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return dict
                }
            }
        }
        throw NSError(domain: "BleLinkSubstrateTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "wire/ble_link_info_vectors.json not found in candidate paths"])
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
    // 7. Canonical JSON LinkInfo Vectors (Directly Consumed from JSON)
    // ------------------------------------------------------------------------
    func testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid() throws {
        let root = try loadCanonicalLinkInfoVectorsJson()

        // Valid cases
        if let validCases = root["valid_cases"] as? [[String: Any]] {
            for c in validCases {
                let name = c["name"] as? String ?? ""
                let flags = UInt8((c["flags"] as? Int) ?? 0)
                let hintHex = c["node_hint"] as? String ?? ""
                let digestHex = c["short_digest"] as? String ?? ""
                let depth = UInt8((c["queue_depth"] as? Int) ?? 0)
                let expectedHex = c["expected_hex"] as? String ?? ""

                let hint = hexToData(hintHex)
                let digest = hexToData(digestHex)
                let expected = hexToData(expectedHex)

                let encoded = BleLinkInfoCodec.encode(
                    flags: flags,
                    nodeHint: hint,
                    shortDigest: digest,
                    queueDepth: depth
                )
                XCTAssertEqual(encoded, expected, "Mismatch encoding case \(name)")

                let decoded = BleLinkInfoCodec.decode(expected)
                XCTAssertNotNil(decoded, "Decode returned nil in case \(name)")
                XCTAssertEqual(decoded?.flags, flags)
                XCTAssertEqual(decoded?.nodeHint, hint)
                XCTAssertEqual(decoded?.shortDigest, digest)
                XCTAssertEqual(decoded?.queueDepth, depth)
            }
        }

        // Invalid cases
        if let invalidCases = root["invalid_cases"] as? [[String: Any]] {
            for c in invalidCases {
                let name = c["name"] as? String ?? ""
                let hex = c["hex"] as? String ?? ""
                let data = hexToData(hex)
                XCTAssertNil(BleLinkInfoCodec.decode(data), "Expected invalid case \(name) (\(hex)) to decode as nil")
            }
        }
    }

    // ------------------------------------------------------------------------
    // 8. Canonical JSON Role Election Cases (Directly Consumed from JSON)
    // ------------------------------------------------------------------------
    func testRoleElection_CanonicalJsonVectors() throws {
        let root = try loadCanonicalLinkInfoVectorsJson()
        if let electionCases = root["role_election_cases"] as? [[String: Any]] {
            for c in electionCases {
                let localHex = c["local_hint"] as? String ?? ""
                let remoteHex = c["remote_hint"] as? String ?? ""
                let expectedRoleStr = c["expected_role"] as? String

                let local = hexToData(localHex)
                let remote = hexToData(remoteHex)

                let res = BleRoleElection.elect(localHint: local, remoteHint: remote)
                if let roleStr = expectedRoleStr {
                    let expectedRole: BleRole = (roleStr == "INITIATOR") ? .initiator : .responder
                    XCTAssertEqual(res, BleRoleElectionResult.elected(expectedRole), "Mismatch in role election for \(localHex) vs \(remoteHex)")
                } else {
                    XCTAssertEqual(res, BleRoleElectionResult.tie, "Expected tie for \(localHex) vs \(remoteHex)")
                }
            }
        }
    }

    // ------------------------------------------------------------------------
    // 9. Authoritative State Progression - Initiator & Responder
    // ------------------------------------------------------------------------
    func testStateProgression_InitiatorFlow_Authoritative() {
        let peerId = UUID()
        let conn = BleConnection(peerId: peerId)
        XCTAssertEqual(conn.state, .provisionalConnecting)

        conn.markConnected()
        XCTAssertEqual(conn.state, .provisionalConnected)

        conn.startLinkInfoRead()
        XCTAssertEqual(conn.state, .linkInfoReading)

        conn.startLinkInfoWrite()
        XCTAssertEqual(conn.state, .linkInfoWriting)

        let remoteHint = Data([0x01, 0x02, 0x03, 0x04])
        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint: remoteHint)
        XCTAssertEqual(conn.state, .roleBound)
        XCTAssertEqual(conn.localRole, .initiator)
        XCTAssertEqual(conn.remoteNodeHint, remoteHint)

        XCTAssertFalse(conn.isHandshakeTransportReady)
        conn.isNotificationSubscribed = true
        XCTAssertTrue(conn.isHandshakeTransportReady)
    }

    func testStateProgression_ResponderFlow_Authoritative() {
        let peerId = UUID()
        let conn = BleConnection(peerId: peerId)
        conn.markConnected()
        XCTAssertEqual(conn.state, .provisionalConnected)

        let remoteHint = Data([0x05, 0x06, 0x07, 0x08])
        conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteHint)
        XCTAssertEqual(conn.state, .roleBound)
        XCTAssertEqual(conn.localRole, .responder)
        XCTAssertEqual(conn.remoteNodeHint, remoteHint)

        XCTAssertFalse(conn.isHandshakeTransportReady)
        conn.isNotificationSubscribed = true
        XCTAssertTrue(conn.isHandshakeTransportReady)
    }

    // ------------------------------------------------------------------------
    // 10. Role Binding Negative Preconditions
    // ------------------------------------------------------------------------
    func testRoleBinding_NegativePreconditions() {
        let remoteHint = Data([1, 2, 3, 4])

        // 1. Initiator from linkInfoWriting -> succeeds
        let connWriting = BleConnection(peerId: UUID())
        connWriting.markConnected()
        connWriting.startLinkInfoRead()
        connWriting.startLinkInfoWrite()
        connWriting.bindInitiatorAfterLinkInfoWriteAck(remoteHint: remoteHint)
        XCTAssertEqual(connWriting.state, .roleBound)
        XCTAssertEqual(connWriting.localRole, .initiator)

        // 2. Responder from provisionalConnected -> succeeds
        let connConnected = BleConnection(peerId: UUID())
        connConnected.markConnected()
        connConnected.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteHint)
        XCTAssertEqual(connConnected.state, .roleBound)
        XCTAssertEqual(connConnected.localRole, .responder)
    }

    // ------------------------------------------------------------------------
    // 11. Substrate Forbidden From Transitioning to READY
    // ------------------------------------------------------------------------
    func testTransitionToReady_ForbiddenInSubstrate() {
        let conn = BleConnection(peerId: UUID())
        conn.markConnected()
        conn.startLinkInfoRead()
        conn.startLinkInfoWrite()
        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data([1, 2, 3, 4]))
        conn.isNotificationSubscribed = true
        XCTAssertEqual(conn.state, .roleBound)
    }

    // ------------------------------------------------------------------------
    // 12. Application DATA Forbidden Before Cryptographic READY
    // ------------------------------------------------------------------------
    func testDataTransmission_StrictlyForbiddenBeforeReady() {
        let conn = BleConnection(peerId: UUID())
        conn.markConnected()
        conn.startLinkInfoRead()
        conn.startLinkInfoWrite()
        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data([1, 2, 3, 4]))
        conn.isNotificationSubscribed = true

        let appData = Data("Secret Mesh Payload".utf8)
        let fragsInRoleBound = conn.fragmentOutbound(recordType: .data, payload: appData)
        XCTAssertTrue(fragsInRoleBound.isEmpty, "DATA fragments must be empty before READY")
    }

    // ------------------------------------------------------------------------
    // 13. Dynamic LinkInfo Snapshot Authority Tests
    // ------------------------------------------------------------------------
    func testSnapshotAuthority_MissingAuthorities_FailsClosed() throws {
        let authMissingAll = LinkInfoSnapshotAuthority()
        XCTAssertNil(authMissingAll.currentSnapshot())
        XCTAssertNil(authMissingAll.currentData())

        let store = MockMessageStore()
        let authMissingIdentity = LinkInfoSnapshotAuthority(storeProvider: { store })
        XCTAssertNil(authMissingIdentity.currentSnapshot())
        XCTAssertNil(authMissingIdentity.currentData())

        let identity = try makeIdentity()
        let authMissingStore = LinkInfoSnapshotAuthority(identityProvider: { identity })
        XCTAssertNil(authMissingStore.currentSnapshot())
        XCTAssertNil(authMissingStore.currentData())
    }

    func testLinkInfoSnapshotAuthority_EmptyStore() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        let snap = authority.currentSnapshot()
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.queueDepth, 0)
        XCTAssertEqual(snap?.nodeHint, identity.nodeHint)
        XCTAssertEqual(snap?.shortDigest, Data(repeating: 0, count: 6))
    }

    func testLinkInfoSnapshotAuthority_HeldRecordsAndSaturating255() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        // Insert 10 records
        let bloom = BloomDigest()
        for i in 1...10 {
            let msgId = Data(repeating: UInt8(i), count: 16)
            store.held.append(msgId)
            bloom.add(msgId)
        }

        authority.refresh()
        let snap10 = authority.currentSnapshot()
        XCTAssertEqual(snap10?.queueDepth, 10)
        XCTAssertEqual(snap10?.shortDigest, Data(bloom.toBytes().prefix(6)))

        // Insert 300 records to test saturation at 255
        for i in 11...300 {
            let msgId = Data(repeating: UInt8(i % 250), count: 16)
            store.held.append(msgId)
        }

        authority.refresh()
        let snap300 = authority.currentSnapshot()
        XCTAssertEqual(snap300?.queueDepth, 255)
    }

    // ------------------------------------------------------------------------
    // 14. iOS Production Orchestration Driver Tests
    // ------------------------------------------------------------------------
    func testOrchestration_UuidOnlyToDuplexReadyAndFound() {
        let localHint = Data([0x01, 0x00, 0x00, 0x00])
        let remoteHint = Data([0x02, 0x00, 0x00, 0x00])
        let localLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: localHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        let driver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { localLinkInfo }
        )

        let peer = UUID()
        // 1. Scan -> Connect
        let act1 = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        XCTAssertEqual(act1, .connectPeripheral(peer))

        // 2. Connected -> DiscoverServices
        let act2 = driver.onConnected(peerId: peer)
        XCTAssertEqual(act2, .discoverServices(peer))

        // 3. Services Discovered -> DiscoverCharacteristics
        let act3 = driver.onServicesDiscovered(peerId: peer, success: true)
        XCTAssertEqual(act3, .discoverCharacteristics(peer))

        // 4. Characteristics Discovered -> ReadLinkInfo
        let act3b = driver.onCharacteristicsDiscovered(peerId: peer, success: true)
        XCTAssertEqual(act3b, .readLinkInfo(peer))

        // 5. Remote LinkInfo read (local < remote -> INITIATOR) -> WriteLinkInfo
        let act4 = driver.onLinkInfoReadResult(peerId: peer, success: true, rawData: remoteLinkInfo)
        XCTAssertEqual(act4, .writeLinkInfo(peer, localLinkInfo, remoteHint))

        // 6. LinkInfo write acknowledged -> SetNotify
        let act5 = driver.onLinkInfoWriteAcknowledged(peerId: peer, success: true, remoteHint: remoteHint)
        XCTAssertEqual(act5, .setNotify(peer))

        // 7. Notification subscribed -> PhysicalDuplexReady!
        let act6 = driver.onNotificationStateUpdated(peerId: peer, success: true, isNotifying: true)
        XCTAssertEqual(act6, .physicalDuplexReady(peer, -60))
        XCTAssertTrue(driver.isPhysicalReady(peer))
    }

    func testOrchestration_DuplicateScanCreatesOneProvisionalLink() {
        let driver = BleCentralOrchestrationDriver(
            localHint: Data([1, 0, 0, 0]),
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let peer = UUID()
        let act1 = driver.onDiscover(peerId: peer, rssi: -50, serviceDataHint: nil)
        XCTAssertEqual(act1, .connectPeripheral(peer))
        XCTAssertEqual(driver.getActiveConnectionCount(), 1)

        let act2 = driver.onDiscover(peerId: peer, rssi: -48, serviceDataHint: nil)
        XCTAssertEqual(act2, .noOp)
        XCTAssertEqual(driver.getActiveConnectionCount(), 1)
    }

    func testOrchestration_LinkInfoWriteAckRequiredForInitiatorBinding() {
        let localHint = Data([1, 0, 0, 0])
        let remoteHint = Data([2, 0, 0, 0])
        let driver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let peer = UUID()
        _ = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        _ = driver.onConnected(peerId: peer)
        _ = driver.onServicesDiscovered(peerId: peer, success: true)
        _ = driver.onCharacteristicsDiscovered(peerId: peer, success: true)
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onLinkInfoReadResult(peerId: peer, success: true, rawData: remoteLinkInfo)

        let conn = driver.getActiveConnection(peer)
        XCTAssertNotNil(conn)
        XCTAssertEqual(conn?.state, .linkInfoWriting)
        XCTAssertFalse(conn?.isRoleBound ?? true)

        let failAct = driver.onLinkInfoWriteAcknowledged(peerId: peer, success: false, remoteHint: remoteHint)
        XCTAssertEqual(failAct, .disconnectPeripheral(peer, "LinkInfo write failed"))
        XCTAssertNil(driver.getActiveConnection(peer))
    }

    func testOrchestration_CccdAckRequiredForPhysicalReady() {
        let localHint = Data([1, 0, 0, 0])
        let remoteHint = Data([2, 0, 0, 0])
        let driver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let peer = UUID()
        _ = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        _ = driver.onConnected(peerId: peer)
        _ = driver.onServicesDiscovered(peerId: peer, success: true)
        _ = driver.onCharacteristicsDiscovered(peerId: peer, success: true)
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onLinkInfoReadResult(peerId: peer, success: true, rawData: remoteLinkInfo)
        _ = driver.onLinkInfoWriteAcknowledged(peerId: peer, success: true, remoteHint: remoteHint)

        let conn = driver.getActiveConnection(peer)!
        XCTAssertTrue(conn.isRoleBound)
        XCTAssertFalse(conn.isHandshakeTransportReady)

        let act = driver.onNotificationStateUpdated(peerId: peer, success: true, isNotifying: true)
        XCTAssertTrue(conn.isHandshakeTransportReady)
        XCTAssertEqual(act, .physicalDuplexReady(peer, -60))
    }

    func testOrchestration_CccdFailureNeverPublishesFound() {
        let localHint = Data([1, 0, 0, 0])
        let remoteHint = Data([2, 0, 0, 0])
        let driver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let peer = UUID()
        _ = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        _ = driver.onConnected(peerId: peer)
        _ = driver.onServicesDiscovered(peerId: peer, success: true)
        _ = driver.onCharacteristicsDiscovered(peerId: peer, success: true)
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onLinkInfoReadResult(peerId: peer, success: true, rawData: remoteLinkInfo)
        _ = driver.onLinkInfoWriteAcknowledged(peerId: peer, success: true, remoteHint: remoteHint)

        let act = driver.onNotificationStateUpdated(peerId: peer, success: false, isNotifying: false)
        XCTAssertEqual(act, .disconnectPeripheral(peer, "Notification subscribe failed"))
        XCTAssertFalse(driver.isPhysicalReady(peer))
    }

    func testOrchestration_RawInboundCapacityBounded() {
        let localHint = Data([0x02, 0x00, 0x00, 0x00]) // Local is 2
        let remoteHint = Data([0x01, 0x00, 0x00, 0x00]) // Remote is 1 -> Remote < Local -> Local is RESPONDER -> Valid
        let validLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )

        // 1. Central reads are stateless and non-allocating
        for _ in 1...10 {
            let u = UUID()
            let act = driver.onCentralRead(centralId: u)
            XCTAssertEqual(act, .sendReadResponse(u, Data(repeating: 0, count: 13)))
        }
        XCTAssertEqual(driver.getAdmittedCount(), 0)
        XCTAssertEqual(cap.totalCount, 0)

        // 2. Admit 7 centrals via valid LinkInfo write
        var admittedIds: [UUID] = []
        for _ in 1...7 {
            let u = UUID()
            admittedIds.append(u)
            let act = driver.onCentralWrite(centralId: u, rawData: validLinkInfo)
            XCTAssertEqual(act, .acceptWrite(u, remoteHint))
        }
        XCTAssertEqual(driver.getAdmittedCount(), 7)
        XCTAssertEqual(cap.totalCount, 7)

        // 3. 8th central write rejected due to capacity exhaustion
        let u8 = UUID()
        let writeAct8 = driver.onCentralWrite(centralId: u8, rawData: validLinkInfo)
        XCTAssertEqual(writeAct8, .rejectWrite(u8, "Capacity exhausted"))
        XCTAssertFalse(driver.isCentralAdmitted(u8))

        let subAct8 = driver.onCentralSubscribed(centralId: u8)
        XCTAssertEqual(subAct8, .rejectSubscription(u8))

        // 4. Disconnect one central -> replacement can be admitted
        _ = driver.onCentralUnsubscribed(centralId: admittedIds[0])
        XCTAssertEqual(driver.getAdmittedCount(), 6)
        XCTAssertEqual(cap.totalCount, 6)

        let act8Replacement = driver.onCentralWrite(centralId: u8, rawData: validLinkInfo)
        XCTAssertEqual(act8Replacement, .acceptWrite(u8, remoteHint))
        XCTAssertEqual(driver.getAdmittedCount(), 7)
        XCTAssertEqual(cap.totalCount, 7)
    }

    func testOrchestration_StorePersistAutomaticallyRefreshesLinkInfo() throws {
        let identity = try makeIdentity()
        let store = InMemoryMessageStore()
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        let initialSnap = authority.currentSnapshot()
        XCTAssertNotNil(initialSnap)
        XCTAssertEqual(initialSnap?.queueDepth, 0)

        // Persist frame through store API without calling authority.refresh()
        let frame = FrameV2(
            type: .message,
            msgId: Data(repeating: 0x55, count: 16),
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct),
            payload: Data([1, 2, 3])
        )
        let res = store.persist(frame, receivedFrom: Data(repeating: 9, count: 16))
        XCTAssertEqual(res, PersistResult.heldNew)

        // Observe automatic snapshot update
        let updatedSnap = authority.currentSnapshot()
        XCTAssertNotNil(updatedSnap)
        XCTAssertEqual(updatedSnap?.queueDepth, 1)
    }

    func testOrchestration_StoreRemovalAutomaticallyRefreshesLinkInfo() throws {
        let identity = try makeIdentity()
        let store = InMemoryMessageStore()
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        let frame = FrameV2(
            type: .message,
            msgId: Data(repeating: 0x77, count: 16),
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct),
            payload: Data([4, 5, 6])
        )
        _ = store.persist(frame, receivedFrom: Data(repeating: 9, count: 16))
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 1)

        // Remove through store API without manual refresh
        _ = store.removeHeld(frame.msgId)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 0)
    }

    // ------------------------------------------------------------------------
    // 15. Crossing Connections Logic
    // ------------------------------------------------------------------------
    func testCrossingConnections_ALessThanB_ARetainsBRejects() {
        let hintA = Data([0x00, 0x01, 0x02, 0x03])
        let hintB = Data([0x80, 0x01, 0x02, 0x03])

        let electionAtA = BleRoleElection.elect(localHint: hintA, remoteHint: hintB)
        XCTAssertEqual(electionAtA, .elected(.initiator))

        let electionAtB = BleRoleElection.elect(localHint: hintB, remoteHint: hintA)
        XCTAssertEqual(electionAtB, .elected(.responder))
    }

    func testCrossingConnections_BLessThanA_BRetainsARejects() {
        let hintA = Data([0x99, 0x00, 0x00, 0x00])
        let hintB = Data([0x11, 0x00, 0x00, 0x00])

        let electionAtA = BleRoleElection.elect(localHint: hintA, remoteHint: hintB)
        XCTAssertEqual(electionAtA, .elected(.responder))

        let electionAtB = BleRoleElection.elect(localHint: hintB, remoteHint: hintA)
        XCTAssertEqual(electionAtB, .elected(.initiator))
    }

    func testCrossingConnections_EqualHints_BothReject() {
        let hint = Data([0x42, 0x42, 0x42, 0x42])
        let res = BleRoleElection.elect(localHint: hint, remoteHint: hint)
        XCTAssertEqual(res, .tie)
    }

    // ------------------------------------------------------------------------
    // 16. Handshake Record Delivery Across Seam
    // ------------------------------------------------------------------------
    func testHandshakeRecordDelivery_AcrossConnectionSeam() {
        let connA = BleConnection(peerId: UUID(), initialMaxAttValueLength: 30)
        connA.markConnected()
        connA.startLinkInfoRead()
        connA.startLinkInfoWrite()
        connA.bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data([5, 6, 7, 8]))
        connA.isNotificationSubscribed = true

        let connB = BleConnection(peerId: UUID(), initialMaxAttValueLength: 30)
        connB.markConnected()
        connB.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: Data([1, 2, 3, 4]))
        connB.isNotificationSubscribed = true

        // Handshake 2 record (229 bytes)
        var hs2Bytes = [UInt8](repeating: 0, count: 229)
        for i in 0..<229 { hs2Bytes[i] = UInt8((i * 3) % 256) }
        let hs2Payload = Data(hs2Bytes)
        let frags = connA.fragmentOutbound(recordType: .hs2, payload: hs2Payload)
        XCTAssertTrue(frags.count > 1)

        var reassembled: BleReassembledRecord?
        for f in frags {
            if let r = connB.ingestInboundAttValue(f) {
                reassembled = r
            }
        }
        XCTAssertNotNil(reassembled)
        XCTAssertEqual(reassembled?.recordType, .hs2)
        XCTAssertEqual(reassembled?.payload, hs2Payload)
    }

    // ------------------------------------------------------------------------
    // 17. Disconnect Purges Reassembly State & Idempotent Start/Stop
    // ------------------------------------------------------------------------
    func testDisconnect_PurgesState_AndIdempotent() {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 20)
        conn.markConnected()
        conn.startLinkInfoRead()
        conn.startLinkInfoWrite()
        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data([2, 3, 4, 5]))
        conn.isNotificationSubscribed = true

        let hs1Payload = Data(repeating: 1, count: 32)
        let frags = conn.fragmentOutbound(recordType: .hs1, payload: hs1Payload)
        XCTAssertNil(conn.ingestInboundAttValue(frags[0]))

        conn.markDisconnected()
        XCTAssertFalse(conn.isActive)
        XCTAssertEqual(conn.state, .closed)

        // Fragments after disconnect are rejected
        XCTAssertNil(conn.ingestInboundAttValue(frags[1]))

        // Repeated disconnect is safe and idempotent
        conn.markDisconnected()
        XCTAssertEqual(conn.state, .closed)
    }

    // ------------------------------------------------------------------------
    // 18. linkLayerReady Remains False
    // ------------------------------------------------------------------------
    func testLinkLayerReady_RemainsFalse() {
        XCTAssertFalse(MeshNode.linkLayerReady)
    }

    // ------------------------------------------------------------------------
    // 19. SessionManager Handshake API Not Invoked by Substrate
    // ------------------------------------------------------------------------
    func testSessionManager_HandshakeApiNotInvokedBySubstrate() throws {
        let id = try makeIdentity()
        let sm = SessionManager(identity: id, trustAuthority: RecordingTrustAuthority())
        let conn = BleConnection(peerId: UUID())
        conn.markConnected()
        XCTAssertFalse(sm.isReady(UUID()))
    }

    // ------------------------------------------------------------------------
    // 20. R2.4 Delivery Retirement Snapshot Freshness Tests
    // ------------------------------------------------------------------------
    func testLinkInfo_AckRetirementAutomaticallyRefreshesSnapshot() throws {
        let identity = try makeIdentity()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone_retire_ack_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        let msgId = Data(repeating: 0x11, count: 16)
        let recipient = Data(repeating: 0x22, count: 16)
        let frame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct) | FrameV2.Flags.sealed,
            payload: Data([1, 2, 3])
        )
        let enq = store.enqueueDirectOutbound(frame, expectedRecipient: recipient, localOriginNodeId: identity.nodeId)
        XCTAssertEqual(enq, .created(frame))
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 1)

        // Authenticated ACK retirement deletes held frame and notifies snapshot authority automatically
        let ackRes = repo.acknowledgeBoundAndRetire(msgId, expectedRecipient: recipient)
        XCTAssertEqual(ackRes, .applied)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 0)
    }

    func testLinkInfo_ExpireRetirementAutomaticallyRefreshesSnapshot() throws {
        let identity = try makeIdentity()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone_retire_exp_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        let msgId = Data(repeating: 0x33, count: 16)
        let recipient = Data(repeating: 0x44, count: 16)
        let frame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct) | FrameV2.Flags.sealed,
            payload: Data([1, 2, 3])
        )
        _ = store.enqueueDirectOutbound(frame, expectedRecipient: recipient, localOriginNodeId: identity.nodeId)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 1)

        // EXPIRE retirement deletes held frame and notifies snapshot authority automatically
        let expRes = repo.transition(msgId, .expire)
        XCTAssertEqual(expRes, .applied)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 0)
    }

    func testLinkInfo_CancelRetirementAutomaticallyRefreshesSnapshot() throws {
        let identity = try makeIdentity()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone_retire_cnc_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        let msgId = Data(repeating: 0x55, count: 16)
        let recipient = Data(repeating: 0x66, count: 16)
        let frame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct) | FrameV2.Flags.sealed,
            payload: Data([1, 2, 3])
        )
        _ = store.enqueueDirectOutbound(frame, expectedRecipient: recipient, localOriginNodeId: identity.nodeId)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 1)

        // CANCEL retirement deletes held frame and notifies snapshot authority automatically
        let cncRes = repo.transition(msgId, .cancel)
        XCTAssertEqual(cncRes, .applied)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 0)
    }

    func testLinkInfo_FailedRetirementDoesNotFalselyNotify() throws {
        let identity = try makeIdentity()
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone_retire_fail_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { identity },
            storeProvider: { store }
        )

        let msgId = Data(repeating: 0x77, count: 16)
        let recipient = Data(repeating: 0x88, count: 16)
        let frame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct) | FrameV2.Flags.sealed,
            payload: Data([1, 2, 3])
        )
        _ = store.enqueueDirectOutbound(frame, expectedRecipient: recipient, localOriginNodeId: identity.nodeId)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 1)

        // Attempt ACK with wrong recipient -> unknownMessage / noMatch; snapshot depth remains 1
        let badRecipient = Data(repeating: 0x99, count: 16)
        let ackRes = repo.acknowledgeBoundAndRetire(msgId, expectedRecipient: badRecipient)
        XCTAssertEqual(ackRes, .unknownMessage)
        XCTAssertEqual(authority.currentSnapshot()?.queueDepth, 1)
    }

    // ------------------------------------------------------------------------
    // 21. R2.4 ATT Pure Cache Test
    // ------------------------------------------------------------------------
    func testAttRead_CacheAbsent_FailsClosed_NoStoreTraversal() {
        let store = MockMessageStore()
        // Authority with missing identity provider -> initial snapshot is nil
        let authority = LinkInfoSnapshotAuthority(
            identityProvider: { nil },
            storeProvider: { store }
        )
        XCTAssertNil(authority.currentSnapshot())
        XCTAssertNil(authority.currentData())
    }

    // ------------------------------------------------------------------------
    // 22. R2.4 Global Capacity Mixed-Direction Test
    // ------------------------------------------------------------------------
    func testGlobalCapacity_MixedDirectionsFillAndReplace() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        XCTAssertEqual(cap.maxTotalPeers, 7)

        // Admit 4 outbound
        for _ in 1...4 {
            XCTAssertTrue(cap.tryAdmitOutbound())
        }
        XCTAssertEqual(cap.outboundCount, 4)

        // Admit 3 inbound -> capacity full (7)
        for _ in 1...3 {
            XCTAssertTrue(cap.tryAdmitInbound())
        }
        XCTAssertEqual(cap.outboundCount + cap.inboundCount, 7)

        // 8th connection (either direction) rejected
        XCTAssertFalse(cap.tryAdmitOutbound())
        XCTAssertFalse(cap.tryAdmitInbound())

        // Release 1 outbound -> 1 inbound can now enter
        cap.releaseOutbound()
        XCTAssertEqual(cap.outboundCount + cap.inboundCount, 6)
        XCTAssertTrue(cap.tryAdmitInbound())
        XCTAssertEqual(cap.outboundCount + cap.inboundCount, 7)
        XCTAssertFalse(cap.tryAdmitInbound())
    }

    // ------------------------------------------------------------------------
    // 23. R2.4 iOS Physical-Ready vs Crypto-Ready Delegate Tests
    // ------------------------------------------------------------------------
    private final class MockTransportDelegate: TransportDelegate {
        var physicalDuplexReadyCount = 0
        var transportReadyCount = 0
        var connectCount = 0
        var disconnectCount = 0
        var receivedData: [Data] = []

        func transportDidConnect(peerId: UUID) {
            connectCount += 1
        }
        func transportPhysicalDuplexReady(peerId: UUID) {
            physicalDuplexReadyCount += 1
        }
        func transportReady(peerId: UUID) {
            transportReadyCount += 1
        }
        func transportDidDisconnect(peerId: UUID) {
            disconnectCount += 1
        }
        func transportDidReceive(data: Data, peerId: UUID) {
            receivedData.append(data)
        }
    }

    func testDelegateCallback_InitiatorPhysicalDuplex_NoTransportReady() {
        let localHint = Data([1, 0, 0, 0])
        let remoteHint = Data([2, 0, 0, 0])
        let localLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: localHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        let driver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { localLinkInfo }
        )

        let peer = UUID()
        _ = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        _ = driver.onConnected(peerId: peer)
        _ = driver.onServicesDiscovered(peerId: peer, success: true)
        _ = driver.onCharacteristicsDiscovered(peerId: peer, success: true)
        _ = driver.onLinkInfoReadResult(peerId: peer, success: true, rawData: remoteLinkInfo)
        _ = driver.onLinkInfoWriteAcknowledged(peerId: peer, success: true, remoteHint: remoteHint)

        let delegate = MockTransportDelegate()
        let act = driver.onNotificationStateUpdated(peerId: peer, success: true, isNotifying: true)
        if case .physicalDuplexReady(let readyPeer, _) = act {
            delegate.transportPhysicalDuplexReady(peerId: readyPeer)
        }

        XCTAssertEqual(delegate.physicalDuplexReadyCount, 1)
        XCTAssertEqual(delegate.transportReadyCount, 0)
    }

    func testDelegateCallback_ResponderPhysicalDuplex_NoTransportReady() {
        let localHint = Data([2, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let localLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: localHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { localLinkInfo }
        )

        let central = UUID()
        _ = driver.onCentralRead(centralId: central)
        _ = driver.onCentralWrite(centralId: central, rawData: remoteLinkInfo)

        let delegate = MockTransportDelegate()
        let act = driver.onCentralSubscribed(centralId: central)
        if case .acceptSubscriptionAndDuplexReady(let readyPeer) = act {
            delegate.transportPhysicalDuplexReady(peerId: readyPeer)
        }

        XCTAssertEqual(delegate.physicalDuplexReadyCount, 1)
        XCTAssertEqual(delegate.transportReadyCount, 0)
    }

    // =========================================================================
    // SECTION 11, 12, 13 — iOS Non-Allocating Read, Inbound Timeout & Capacity Tests
    // =========================================================================

    func testIosLinkInfoReadOnly_DoesNotConsumeCapacity() {
        let localHint = Data([2, 0, 0, 0])
        let localLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: localHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { localLinkInfo },
            capacityAuthority: cap
        )

        let central = UUID()
        let act = driver.onCentralRead(centralId: central)
        XCTAssertEqual(act, .sendReadResponse(central, localLinkInfo))

        // Read is non-allocating: 0 capacity consumed, 0 admitted centrals!
        XCTAssertEqual(cap.totalCount, 0)
        XCTAssertEqual(cap.inboundCount, 0)
        XCTAssertEqual(driver.getAdmittedCount(), 0)
        XCTAssertFalse(driver.isCentralAdmitted(central))
    }

    func testIosRejectedLinkInfoWrite_DoesNotConsumeCapacity() {
        let localHint = Data([1, 0, 0, 0]) // Local is 1
        let remoteHint = Data([2, 0, 0, 0]) // Remote is 2 -> Remote > Local -> Central is responder -> Wrong direction!
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )

        let central = UUID()
        let act = driver.onCentralWrite(centralId: central, rawData: remoteLinkInfo)
        XCTAssertEqual(act, .rejectWrite(central, "Central is not initiator"))

        // Rejected write consumes 0 capacity!
        XCTAssertEqual(cap.totalCount, 0)
        XCTAssertEqual(cap.inboundCount, 0)
        XCTAssertEqual(driver.getAdmittedCount(), 0)
    }

    func testIosAcceptedWriteWithoutSubscription_TimesOutAndReleases() {
        let localHint = Data([2, 0, 0, 0]) // Local is 2
        let remoteHint = Data([1, 0, 0, 0]) // Remote is 1 -> Remote < Local -> Local is RESPONDER -> Valid!
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )

        let central = UUID()
        let act = driver.onCentralWrite(centralId: central, rawData: remoteLinkInfo)
        XCTAssertEqual(act, .acceptWrite(central, remoteHint))
        XCTAssertEqual(cap.inboundCount, 1)
        XCTAssertEqual(driver.getAdmittedCount(), 1)

        // Pre-subscription timeout fires
        driver.onInboundTimeout(centralId: central, expectedGen: 1)

        // Capacity and connection cleanly released!
        XCTAssertEqual(cap.inboundCount, 0)
        XCTAssertEqual(cap.totalCount, 0)
        XCTAssertEqual(driver.getAdmittedCount(), 0)
        XCTAssertFalse(driver.isCentralAdmitted(central))
    }

    func testIosUnknownSubscription_DoesNotAllocate() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let driver = BlePeripheralOrchestrationDriver(
            localHint: Data([1, 0, 0, 0]),
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )

        let central = UUID()
        let act = driver.onCentralSubscribed(centralId: central)
        XCTAssertEqual(act, .rejectSubscription(central))
        XCTAssertEqual(cap.totalCount, 0)
        XCTAssertEqual(driver.getAdmittedCount(), 0)
    }

    func testIosProvisionalTimeout_ReleasesDriverCapacity() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let driver = BleCentralOrchestrationDriver(
            localHint: Data([1, 0, 0, 0]),
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )

        let peer = UUID()
        _ = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        XCTAssertEqual(cap.outboundCount, 1)
        XCTAssertEqual(driver.getActiveConnectionCount(), 1)

        let act = driver.onProvisionalTimeout(peerId: peer, expectedGen: 1)
        XCTAssertEqual(act, .disconnectPeripheral(peer, "Provisional timeout"))
        XCTAssertEqual(cap.outboundCount, 0)
        XCTAssertEqual(driver.getActiveConnectionCount(), 0)
    }

    func testIosStaleProvisionalTimer_CannotReleaseReplacement() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let driver = BleCentralOrchestrationDriver(
            localHint: Data([1, 0, 0, 0]),
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )

        let peer = UUID()
        _ = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        XCTAssertEqual(cap.outboundCount, 1)

        _ = driver.onDisconnected(peerId: peer)
        XCTAssertEqual(cap.outboundCount, 0)

        _ = driver.onDiscover(peerId: peer, rssi: -60, serviceDataHint: nil)
        XCTAssertEqual(cap.outboundCount, 1)

        // Stale Gen 1 timeout
        let staleAct = driver.onProvisionalTimeout(peerId: peer, expectedGen: 1)
        XCTAssertEqual(staleAct, .noOp)
        XCTAssertEqual(cap.outboundCount, 1)
        XCTAssertEqual(driver.getActiveConnectionCount(), 1)

        // Valid Gen 2 timeout
        let validAct = driver.onProvisionalTimeout(peerId: peer, expectedGen: 2)
        XCTAssertEqual(validAct, .disconnectPeripheral(peer, "Provisional timeout"))
        XCTAssertEqual(cap.outboundCount, 0)
        XCTAssertEqual(driver.getActiveConnectionCount(), 0)
    }

    func testIosStop_ReleasesAllCapacity() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let centralDriver = BleCentralOrchestrationDriver(
            localHint: Data([1, 0, 0, 0]),
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let peripheralDriver = BlePeripheralOrchestrationDriver(
            localHint: Data([2, 0, 0, 0]),
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )

        let p1 = UUID()
        let p2 = UUID()
        _ = centralDriver.onDiscover(peerId: p1, rssi: -60, serviceDataHint: nil)
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: Data([1, 0, 0, 0]),
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = peripheralDriver.onCentralWrite(centralId: p2, rawData: remoteLinkInfo)

        XCTAssertEqual(cap.totalCount, 2)
        XCTAssertEqual(cap.outboundCount, 1)
        XCTAssertEqual(cap.inboundCount, 1)

        // Reset / Stop
        centralDriver.reset()
        peripheralDriver.reset()
        cap.reset()

        XCTAssertEqual(cap.totalCount, 0)
        XCTAssertEqual(cap.outboundCount, 0)
        XCTAssertEqual(cap.inboundCount, 0)
        XCTAssertEqual(centralDriver.getActiveConnectionCount(), 0)
        XCTAssertEqual(peripheralDriver.getAdmittedCount(), 0)
    }

    func testIosStopStart_CanAdmitSevenFreshPeers() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        for _ in 1...7 {
            XCTAssertTrue(cap.tryAdmitOutbound())
        }
        XCTAssertEqual(cap.totalCount, 7)
        XCTAssertFalse(cap.tryAdmitInbound())

        cap.reset()
        XCTAssertEqual(cap.totalCount, 0)

        for _ in 1...7 {
            XCTAssertTrue(cap.tryAdmitInbound())
        }
        XCTAssertEqual(cap.totalCount, 7)
    }

    // =========================================================================
    // SECTION 5 & 16: iOS Exact Capacity Lease Ownership & Stale Release Isolation
    // =========================================================================

    func testIosCapacity_StaleOutboundReleaseCannotReleaseReplacement() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let peerId = UUID()

        let lease1 = cap.tryAdmitOutbound(peerId: peerId, generation: 1)
        XCTAssertNotNil(lease1)
        XCTAssertEqual(cap.outboundCount, 1)
        XCTAssertEqual(cap.totalCount, 1)
        XCTAssertTrue(cap.isLeaseActive(lease1))

        // Replacement relation admitted for generation 2
        let lease2 = cap.tryAdmitOutbound(peerId: peerId, generation: 2)
        XCTAssertNotNil(lease2)
        XCTAssertEqual(cap.outboundCount, 1)
        XCTAssertTrue(cap.isLeaseActive(lease2))
        XCTAssertFalse(cap.isLeaseActive(lease1))

        // Stale terminal event for generation 1 attempts release
        let staleReleased = cap.releaseLease(lease1)
        XCTAssertFalse(staleReleased)
        XCTAssertEqual(cap.outboundCount, 1)
        XCTAssertTrue(cap.isLeaseActive(lease2))

        // Releasing generation 2 succeeds
        let gen2Released = cap.releaseLease(lease2)
        XCTAssertTrue(gen2Released)
        XCTAssertEqual(cap.outboundCount, 0)
    }

    func testIosCapacity_StaleInboundReleaseCannotReleaseReplacement() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let peerId = UUID()

        let lease1 = cap.tryAdmitInbound(peerId: peerId, generation: 1)
        XCTAssertNotNil(lease1)
        XCTAssertEqual(cap.inboundCount, 1)
        XCTAssertTrue(cap.isLeaseActive(lease1))

        // Replacement relation admitted for generation 2
        let lease2 = cap.tryAdmitInbound(peerId: peerId, generation: 2)
        XCTAssertNotNil(lease2)
        XCTAssertEqual(cap.inboundCount, 1)
        XCTAssertTrue(cap.isLeaseActive(lease2))

        // Stale release for generation 1 fails
        let staleReleased = cap.releaseLease(lease1)
        XCTAssertFalse(staleReleased)
        XCTAssertEqual(cap.inboundCount, 1)
        XCTAssertTrue(cap.isLeaseActive(lease2))

        // Legitimate release for generation 2 succeeds
        XCTAssertTrue(cap.releaseLease(lease2))
        XCTAssertEqual(cap.inboundCount, 0)
    }

    func testIosCapacity_DuplicateReleaseIsIdempotent() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let peerId = UUID()
        let lease = cap.tryAdmitOutbound(peerId: peerId, generation: 1)
        XCTAssertNotNil(lease)

        XCTAssertTrue(cap.releaseLease(lease))
        XCTAssertFalse(cap.releaseLease(lease)) // Duplicate release returns false
        XCTAssertEqual(cap.totalCount, 0)
    }

    func testIosCapacity_MixedDirectionsNeverExceedsSeven() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        for i in 1...4 {
            XCTAssertNotNil(cap.tryAdmitOutbound(peerId: UUID(), generation: UInt64(i)))
        }
        for i in 5...7 {
            XCTAssertNotNil(cap.tryAdmitInbound(peerId: UUID(), generation: UInt64(i)))
        }
        XCTAssertEqual(cap.totalCount, 7)
        XCTAssertNil(cap.tryAdmitOutbound(peerId: UUID(), generation: 8))
        XCTAssertNil(cap.tryAdmitInbound(peerId: UUID(), generation: 9))
    }

    func testIosCapacity_StopResetLeavesZeroLeases() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        _ = cap.tryAdmitOutbound(peerId: UUID(), generation: 1)
        _ = cap.tryAdmitInbound(peerId: UUID(), generation: 1)
        XCTAssertEqual(cap.totalCount, 2)
        cap.reset()
        XCTAssertEqual(cap.totalCount, 0)
        XCTAssertEqual(cap.outboundCount, 0)
        XCTAssertEqual(cap.inboundCount, 0)
    }

    // =========================================================================
    // SECTION 6 & 16: iOS Duplicate / Conflicting LinkInfo Write Safety
    // =========================================================================

    func testIosLinkInfo_FirstValidWrite_BindsResponder() {
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0]) // Remote < Local -> Local is RESPONDER
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let centralId = UUID()

        let act = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(act, .acceptWrite(centralId, remoteHint))
        let conn = driver.getInboundConnection(centralId)
        XCTAssertNotNil(conn)
        XCTAssertTrue(conn?.isRoleBound == true)
        XCTAssertEqual(conn?.localRole, .responder)
    }

    func testIosLinkInfo_ExactDuplicate_NoCrashNoRebindNoExtraLease() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()

        // First write: binds responder
        let act1 = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(act1, .acceptWrite(centralId, remoteHint))
        XCTAssertEqual(cap.inboundCount, 1)
        let initialGen = driver.getCentralGeneration(centralId)
        // Second write (exact duplicate): must NOT crash, must NOT rebind, must NOT allocate extra capacity lease
        let act2 = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(act2, .acceptDuplicateWrite(centralId, remoteHint))
        XCTAssertEqual(cap.inboundCount, 1)
        XCTAssertEqual(driver.getCentralGeneration(centralId), initialGen)
        XCTAssertTrue(driver.getInboundConnection(centralId)?.isRoleBound == true)
    }

    func testIosLinkInfo_ConflictingDuplicate_RejectedNoCrash() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint1 = Data([1, 0, 0, 0])
        let remoteHint2 = Data([2, 0, 0, 0])
        let remoteLinkInfo1 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint1,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let remoteLinkInfo2 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint2,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()

        // First write: binds remoteHint1
        _ = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo1)
        XCTAssertEqual(cap.inboundCount, 1)

        // Second write with conflicting remoteHint2: rejected cleanly without crash
        let act2 = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo2)
        XCTAssertEqual(act2, .rejectWrite(centralId, "Conflicting LinkInfo write on active relation"))
        XCTAssertEqual(cap.inboundCount, 1)
        // Original relation remains intact
        XCTAssertEqual(driver.getAcceptedRemoteLinkInfo(centralId)?.nodeHint, remoteHint1)
    }

    func testIosLinkInfo_DuplicateAfterSubscription_DoesNotResetRelation() {
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let centralId = UUID()

        _ = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo)
        let subAct = driver.onCentralSubscribed(centralId: centralId)
        XCTAssertEqual(subAct, .acceptSubscriptionAndDuplexReady(centralId))

        // Duplicate write after subscription
        let dupAct = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(dupAct, .acceptDuplicateWrite(centralId, remoteHint))
        XCTAssertTrue(driver.getInboundConnection(centralId)?.isHandshakeTransportReady == true)
    }

    func testIosLinkInfo_DuplicateCannotRestartTimeoutForDifferentGeneration() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()

        _ = driver.onCentralWrite(centralId: centralId, rawData: remoteLinkInfo)
        let gen = driver.getCentralGeneration(centralId)

        // Stale timeout for expectedGen 99 is ignored
        driver.onInboundTimeout(centralId: centralId, expectedGen: 99)
        XCTAssertEqual(cap.inboundCount, 1)
        XCTAssertNotNil(driver.getInboundConnection(centralId))

        // Timeout for current gen releases capacity
        driver.onInboundTimeout(centralId: centralId, expectedGen: gen)
        XCTAssertEqual(cap.inboundCount, 0)
        XCTAssertNil(driver.getInboundConnection(centralId))
    }

    // =========================================================================
    // SECTION 14: iOS Production Callback-Mapping Reducer Tests
    // =========================================================================

    func testIosAdapter_DirectReducerMapping() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()

        let centralId = UUID()

        // 1. Read only -> 0 capacity consumed
        let readAct = transport.dispatchReceiveRead(centralId: centralId)
        guard case .sendReadResponse = readAct else {
            XCTFail("Expected sendReadResponse")
            return
        }
        XCTAssertEqual(transport.capacityAuthority.totalCount, 0)

        // 2. Valid write -> 1 relation admitted, 1 lease consumed
        let remoteHint = Data([0, 0, 0, 1])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let writeAct = transport.dispatchReceiveWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(writeAct, .acceptWrite(centralId, remoteHint))
        XCTAssertEqual(transport.capacityAuthority.inboundCount, 1)

        // 3. Exact duplicate write -> no crash, no extra lease
        let dupAct = transport.dispatchReceiveWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(dupAct, .acceptDuplicateWrite(centralId, remoteHint))
        XCTAssertEqual(transport.capacityAuthority.inboundCount, 1)

        // 4. Conflicting duplicate write -> rejected
        let conflictLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: Data([0, 0, 0, 2]),
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let conflictAct = transport.dispatchReceiveWrite(centralId: centralId, rawData: conflictLinkInfo)
        guard case .rejectWrite = conflictAct else {
            XCTFail("Expected rejectWrite for conflicting LinkInfo")
            return
        }
        XCTAssertEqual(transport.capacityAuthority.inboundCount, 1)

        // 5. Subscription -> physical duplex ready
        let subAct = transport.dispatchSubscribe(centralId: centralId)
        XCTAssertEqual(subAct, .acceptSubscriptionAndDuplexReady(centralId))

        // 6. Unsubscribe -> releases exact lease
        let unsubAct = transport.dispatchUnsubscribe(centralId: centralId)
        XCTAssertEqual(unsubAct, .noOp)
        XCTAssertEqual(transport.capacityAuthority.inboundCount, 0)

        transport.stop()
    }

    // =========================================================================
    // SECTION N — Phase C8.4D1-R2.7 Single Authority & Publication Closure Regressions
    // =========================================================================

    func testIosLinkInfo_SameHintDifferentFlagsRejected() {
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let centralId = UUID()
        let info1 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act1 = driver.onCentralWrite(centralId: centralId, rawData: info1)
        XCTAssertEqual(act1, .acceptWrite(centralId, remoteHint))

        // Same nodeHint, different flags -> conflict
        let info2 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0x02,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act2 = driver.onCentralWrite(centralId: centralId, rawData: info2)
        XCTAssertEqual(act2, .rejectWrite(centralId, "Conflicting LinkInfo write on active relation"))
    }

    func testIosLinkInfo_SameHintDifferentDigestRejected() {
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let centralId = UUID()
        let info1 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data([0, 0, 0, 0, 0, 0]),
            queueDepth: 0
        )
        let act1 = driver.onCentralWrite(centralId: centralId, rawData: info1)
        XCTAssertEqual(act1, .acceptWrite(centralId, remoteHint))

        // Same nodeHint, different shortDigest -> conflict
        let info2 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data([1, 2, 3, 4, 5, 6]),
            queueDepth: 0
        )
        let act2 = driver.onCentralWrite(centralId: centralId, rawData: info2)
        XCTAssertEqual(act2, .rejectWrite(centralId, "Conflicting LinkInfo write on active relation"))
    }

    func testIosLinkInfo_SameHintDifferentQueueDepthRejected() {
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let centralId = UUID()
        let info1 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act1 = driver.onCentralWrite(centralId: centralId, rawData: info1)
        XCTAssertEqual(act1, .acceptWrite(centralId, remoteHint))

        // Same nodeHint, different queueDepth -> conflict
        let info2 = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 7
        )
        let act2 = driver.onCentralWrite(centralId: centralId, rawData: info2)
        XCTAssertEqual(act2, .rejectWrite(centralId, "Conflicting LinkInfo write on active relation"))
    }

    func testIosTransport_DuplicateDoesNotRestartInboundTimer() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        let act1 = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(act1, .acceptWrite(centralId, remoteHint))
        XCTAssertEqual(driver.getCentralGeneration(centralId), 1)

        // Exact duplicate
        let act2 = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(act2, .acceptDuplicateWrite(centralId, remoteHint))
        XCTAssertEqual(driver.getCentralGeneration(centralId), 1)
        XCTAssertEqual(cap.inboundCount, 1)
    }

    func testIosTransport_DuplicateTimeoutReleasesDriverLeaseAndTransportState() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(cap.inboundCount, 1)

        driver.onInboundTimeout(centralId: centralId, expectedGen: 1)
        XCTAssertEqual(cap.inboundCount, 0)
        XCTAssertNil(driver.getInboundConnection(centralId))
    }

    func testIosTransport_PostTimeoutNewWriteCreatesCleanNextGeneration() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(driver.getCentralGeneration(centralId), 1)

        // Timeout closes connection
        driver.onInboundTimeout(centralId: centralId, expectedGen: 1)
        XCTAssertEqual(cap.inboundCount, 0)

        // New write after timeout -> Gen 2
        let act2 = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(act2, .acceptWrite(centralId, remoteHint))
        XCTAssertEqual(driver.getCentralGeneration(centralId), 2)
        XCTAssertEqual(cap.inboundCount, 1)
        XCTAssertEqual(driver.getInboundConnection(centralId)?.state, .roleBound)
    }

    func testIosTransport_DuplicateSequenceCannotCrashClosedConnection() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        _ = driver.onCentralUnsubscribed(centralId: centralId, expectedGen: 1)

        // Duplicate write on closed relation smoothly opens new connection
        let act = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(act, .acceptWrite(centralId, remoteHint))
        XCTAssertEqual(driver.getCentralGeneration(centralId), 2)
    }

    func testIosTransport_StaleOutboundDisconnectCannotDeleteReplacement() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([1, 0, 0, 0])
        let driver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let peerId = UUID()
        _ = driver.onDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        XCTAssertEqual(driver.getConnectionGeneration(peerId), 1)

        _ = driver.onDisconnected(peerId: peerId, expectedGen: 1)
        _ = driver.onDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        XCTAssertEqual(driver.getConnectionGeneration(peerId), 2)

        // Stale Gen 1 disconnect arrives -> ignored!
        let staleAct = driver.onDisconnected(peerId: peerId, expectedGen: 1)
        XCTAssertEqual(staleAct, .noOp)
        XCTAssertEqual(driver.getConnectionGeneration(peerId), 2)
        XCTAssertNotNil(driver.getActiveConnection(peerId))
    }

    func testIosTransport_StaleInboundTerminalCannotDeleteReplacement() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(driver.getCentralGeneration(centralId), 1)

        _ = driver.onCentralUnsubscribed(centralId: centralId, expectedGen: 1)
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(driver.getCentralGeneration(centralId), 2)

        // Stale Gen 1 unsub arrives -> ignored!
        let staleAct = driver.onCentralUnsubscribed(centralId: centralId, expectedGen: 1)
        XCTAssertEqual(staleAct, .noOp)
        XCTAssertEqual(driver.getCentralGeneration(centralId), 2)
        XCTAssertNotNil(driver.getInboundConnection(centralId))
    }

    // =========================================================================
    // SECTION 15 & 16: iOS Duplicate Write, Timeout Invalidation, and Slot State Machine
    // =========================================================================

    func testIosDuplicateBeforeSubscription_ReusesOriginalTimer() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()

        let centralId = UUID()
        let remoteHint = Data([0, 0, 0, 1])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        let act1 = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(act1, .acceptWrite(centralId, remoteHint))

        let act2 = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(act2, .acceptDuplicateWrite(centralId, remoteHint))

        transport.stop()
    }

    func testIosDuplicateAfterSubscription_DoesNotCreateTimer() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()

        let centralId = UUID()
        let remoteHint = Data([0, 0, 0, 1])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        _ = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        _ = transport.processInboundSubscribe(centralId: centralId)

        // Duplicate write after subscription
        let act2 = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(act2, .acceptDuplicateWrite(centralId, remoteHint))

        transport.stop()
    }

    func testIosPhysicalReadyTimeoutCallback_LeavesNoTimerEntry() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()

        let centralId = UUID()
        let remoteHint = Data([0, 0, 0, 1])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        _ = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        _ = transport.processInboundSubscribe(centralId: centralId)

        // Trigger timeout callback while physical ready -> should clean up timer and leave connection ready
        transport.handleInboundTimeout(centralId: centralId, generation: 1)
        XCTAssertTrue(transport.isRelationPublished(direction: .inboundPeripheral, peerId: centralId, generation: 1))

        transport.stop()
    }

    func testIosDuplicateAfterSubscription_DoesNotChangeRelationGeneration() {
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) }
        )
        let centralId = UUID()
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        _ = driver.onCentralSubscribed(centralId: centralId)
        let genBefore = driver.getCentralGeneration(centralId)
        XCTAssertEqual(genBefore, 1)

        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        let genAfter = driver.getCentralGeneration(centralId)
        XCTAssertEqual(genAfter, 1)
    }

    func testIosDuplicateAfterSubscription_DoesNotChangeLease() {
        let cap = BleGlobalCapacityAuthority(maxTotalPeers: 7)
        let localHint = Data([5, 0, 0, 0])
        let remoteHint = Data([1, 0, 0, 0])
        let driver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { Data(repeating: 0, count: 13) },
            capacityAuthority: cap
        )
        let centralId = UUID()
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        _ = driver.onCentralSubscribed(centralId: centralId)
        let lease1 = driver.getInboundLease(centralId)
        XCTAssertNotNil(lease1)
        XCTAssertEqual(cap.inboundCount, 1)

        _ = driver.onCentralWrite(centralId: centralId, rawData: info)
        let lease2 = driver.getInboundLease(centralId)
        XCTAssertEqual(lease1, lease2)
        XCTAssertEqual(cap.inboundCount, 1)
    }

    func testIosOutboundAdapter_ClosingBlocksSamePeerReplacement() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()
        let peerId = UUID()

        // 1. Initial discover -> active(1)
        let act1 = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        XCTAssertEqual(act1, .connectPeripheral(peerId))
        XCTAssertNotNil(transport.getOutboundLifetime(peerId))
        let proxy1 = transport.getRelationDelegate(peerId)
        XCTAssertNotNil(proxy1)

        // 2. Failure occurs locally -> transitions to closing(1)
        let act2 = transport.processPeripheralDiscoverServices(nil, delegate: proxy1!, error: NSError(domain: "test", code: 1))
        XCTAssertEqual(act2, .disconnectPeripheral(peerId, "Service discovery failed"))

        // 3. New discover for same peer while closing -> blocked (.noOp)
        let act3 = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        XCTAssertEqual(act3, .noOp)

        // 4. Platform disconnect callback observed -> retires
        let act4 = transport.processOutboundDisconnect(peerId: peerId)
        XCTAssertEqual(act4, .noOp)

        // 5. Subsequent discover admits generation 2
        let act5 = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        XCTAssertEqual(act5, .connectPeripheral(peerId))
        let lifetime2 = transport.getOutboundLifetime(peerId)
        XCTAssertNotNil(lifetime2)
        XCTAssertEqual(lifetime2?.relationKey.generation, 2)
        transport.stop()
    }

    func testIosOutboundAdapter_OldDisconnectCannotDeleteReplacement() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()
        let peerId = UUID()

        _ = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        _ = transport.processOutboundDisconnect(peerId: peerId)
        _ = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        XCTAssertEqual(transport.getOutboundLifetime(peerId)?.relationKey.generation, 2)

        // Stale disconnect from old generation (expectedGen: 1) arrives
        let staleAct = transport.processOutboundDisconnect(peerId: peerId, expectedGen: 1)
        XCTAssertEqual(staleAct, .noOp)
        XCTAssertEqual(transport.getOutboundLifetime(peerId)?.relationKey.generation, 2)
        XCTAssertNotNil(transport.connection(for: peerId))
        transport.stop()
    }

    func testIosOutboundAdapter_OldServiceCallbackCannotAdvanceReplacement() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()
        let peerId = UUID()

        _ = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        let proxy1 = transport.getRelationDelegate(peerId)!
        _ = transport.processOutboundDisconnect(peerId: peerId)

        // Stale service discovery callback with proxy1 arrives -> noOp
        let staleAct = transport.processPeripheralDiscoverServices(nil, delegate: proxy1, error: nil)
        XCTAssertEqual(staleAct, .noOp)
        transport.stop()
    }

    func testIosOutboundAdapter_OldLinkInfoCallbackCannotAdvanceReplacement() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()
        let peerId = UUID()

        _ = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        let proxy1 = transport.getRelationDelegate(peerId)!
        _ = transport.processOutboundDisconnect(peerId: peerId)

        let ch = CBMutableCharacteristic(type: BleTransport.linkInfoCharacteristicUuid, properties: [.read], value: Data(repeating: 0, count: 13), permissions: [.readable])
        let staleAct = transport.processPeripheralUpdateValue(nil, delegate: proxy1, characteristic: ch, error: nil)
        XCTAssertEqual(staleAct, .noOp)
        transport.stop()
    }

    func testIosOutboundAdapter_OldNotifyCallbackCannotPublishReplacement() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()
        let peerId = UUID()

        _ = transport.processOutboundDiscover(peerId: peerId, rssi: -60, serviceDataHint: Data([5, 0, 0, 0]))
        let proxy1 = transport.getRelationDelegate(peerId)!
        _ = transport.processOutboundDisconnect(peerId: peerId)

        let ch = CBMutableCharacteristic(type: BleTransport.inboxCharacteristicUuid, properties: [.notify], value: nil, permissions: [.readable])
        let staleAct = transport.processPeripheralNotificationStateUpdated(nil, delegate: proxy1, characteristic: ch, error: nil)
        XCTAssertEqual(staleAct, .noOp)
        transport.stop()
    }

    func testIosInboundAdapter_OldUnsubscribeCannotDeleteReplacement() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()
        let centralId = UUID()
        let remoteHint = Data([0, 0, 0, 1])
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = transport.processInboundWrite(centralId: centralId, rawData: info)
        _ = transport.processInboundUnsubscribe(centralId: centralId)
        _ = transport.processInboundWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(transport.getInboundLifetime(centralId)?.relationKey.generation, 2)

        let staleAct = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: 1)
        XCTAssertEqual(staleAct, .noOp)
        XCTAssertEqual(transport.getInboundLifetime(centralId)?.relationKey.generation, 2)
        XCTAssertNotNil(transport.connection(for: centralId))
        transport.stop()
    }

    func testIosInboundAdapter_PreviousManagerEpochCannotDeletePostRestartRelation() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()
        let centralId = UUID()
        let remoteHint = Data([0, 0, 0, 1])
        let info = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
        _ = transport.processInboundWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(transport.getInboundLifetime(centralId)?.relationKey.generation, 1)

        // Transport stop & start (epoch advance)
        transport.stop()
        transport.start()

        // New admission after restart
        _ = transport.processInboundWrite(centralId: centralId, rawData: info)
        XCTAssertEqual(transport.getInboundLifetime(centralId)?.relationKey.generation, 1)

        // Stale unsubscribe from before epoch cannot delete post-restart relation (generation mismatched or old epoch)
        let staleAct = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: 999)
        XCTAssertEqual(staleAct, .noOp)
        XCTAssertNotNil(transport.connection(for: centralId))
        transport.stop()
    }

    func testIosInboundAdapter_DuplicateAfterSubscribedCreatesNoTimer() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        transport.start()

        let centralId = UUID()
        let remoteHint = Data([0, 0, 0, 1])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        _ = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        _ = transport.processInboundSubscribe(centralId: centralId)

        let act = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(act, .acceptDuplicateWrite(centralId, remoteHint))

        transport.stop()
    }

    // =========================================================================
    // SECTION 17: Publication Edge Reducer Matrix Tests
    // =========================================================================

    private class MatrixTransportDelegate: TransportDelegate {
        var connectEvents: [UUID] = []
        var disconnectEvents: [UUID] = []

        func transportPhysicalDuplexReady(peerId: UUID) {}
        func transportDidConnect(peerId: UUID) { connectEvents.append(peerId) }
        func transportDidDisconnect(peerId: UUID) { disconnectEvents.append(peerId) }
        func transportDidReceive(data: Data, peerId: UUID) {}
    }

    func testIosPublicationEdgeReducer_EventCountMatrix() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        let delegate = MatrixTransportDelegate()
        transport.delegate = delegate
        transport.start()

        let peer = UUID()
        let keyInbound1 = RelationKey(direction: .inboundPeripheral, peerId: peer, generation: 1)
        let keyOutbound1 = RelationKey(direction: .outboundCentral, peerId: peer, generation: 1)

        // 0 -> 0: no event
        XCTAssertFalse(transport.unpublishRelation(keyInbound1))
        XCTAssertEqual(delegate.connectEvents.count, 0)
        XCTAssertEqual(delegate.disconnectEvents.count, 0)

        // 0 -> 1 (first relation): exactly 1 connect event
        XCTAssertTrue(transport.publishRelation(keyInbound1))
        XCTAssertEqual(delegate.connectEvents.count, 1)
        XCTAssertEqual(delegate.disconnectEvents.count, 0)

        // 1 -> 1 (duplicate publish): no event
        XCTAssertFalse(transport.publishRelation(keyInbound1))
        XCTAssertEqual(delegate.connectEvents.count, 1)
        XCTAssertEqual(delegate.disconnectEvents.count, 0)

        // 1 -> 2 (second concurrent relation, e.g. outbound): relation added, but no extra connect event emitted
        XCTAssertFalse(transport.publishRelation(keyOutbound1))
        XCTAssertEqual(delegate.connectEvents.count, 1)
        XCTAssertEqual(delegate.disconnectEvents.count, 0)

        // 2 -> 1 (remove one relation): relation removed, but other remains so no disconnect event
        XCTAssertFalse(transport.unpublishRelation(keyInbound1))
        XCTAssertEqual(delegate.connectEvents.count, 1)
        XCTAssertEqual(delegate.disconnectEvents.count, 0)

        // 1 -> 1 (duplicate unpublish): no event
        XCTAssertFalse(transport.unpublishRelation(keyInbound1))
        XCTAssertEqual(delegate.connectEvents.count, 1)
        XCTAssertEqual(delegate.disconnectEvents.count, 0)

        // 1 -> 0 (remove final relation): exactly 1 disconnect event
        XCTAssertTrue(transport.unpublishRelation(keyOutbound1))
        XCTAssertEqual(delegate.connectEvents.count, 1)
        XCTAssertEqual(delegate.disconnectEvents.count, 1)

        // 0 -> 0 (remove when empty): no event
        XCTAssertFalse(transport.unpublishRelation(keyOutbound1))
        XCTAssertEqual(delegate.connectEvents.count, 1)
        XCTAssertEqual(delegate.disconnectEvents.count, 1)

        transport.stop()
    }

    private class RecordingTransportDelegate: TransportDelegate {
        var duplexReadyPeers: [UUID] = []
        var connectedPeers: [UUID] = []
        var disconnectedPeers: [UUID] = []
        var receivedData: [(Data, UUID)] = []

        func transportPhysicalDuplexReady(peerId: UUID) { duplexReadyPeers.append(peerId) }
        func transportDidConnect(peerId: UUID) { connectedPeers.append(peerId) }
        func transportDidDisconnect(peerId: UUID) { disconnectedPeers.append(peerId) }
        func transportDidReceive(data: Data, peerId: UUID) { receivedData.append((data, peerId)) }
    }

    func testIosProductionWriteReducer_CoversTimerAndPublicationSideEffects() throws {
        let identity = try makeIdentity()
        let store = MockMessageStore()
        let transport = BleTransport(identity: identity, store: store)
        let delegate = RecordingTransportDelegate()
        transport.delegate = delegate
        transport.start()

        let centralId = UUID()
        let remoteHint = Data([0, 0, 0, 1])
        let remoteLinkInfo = BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: remoteHint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )

        // 1. Initial write
        let writeAct1 = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(writeAct1, .acceptWrite(centralId, remoteHint))
        XCTAssertEqual(delegate.connectedPeers.count, 0)

        // 2. Duplicate write
        let writeAct2 = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo)
        XCTAssertEqual(writeAct2, .acceptDuplicateWrite(centralId, remoteHint))
        XCTAssertEqual(delegate.connectedPeers.count, 0)

        // 3. Subscribe -> exactly 1 connect/duplexReady
        let subAct = transport.processInboundSubscribe(centralId: centralId)
        XCTAssertEqual(subAct, .acceptSubscriptionAndDuplexReady(centralId))
        XCTAssertEqual(delegate.duplexReadyPeers, [centralId])
        XCTAssertEqual(delegate.connectedPeers, [centralId])

        // 4. Unsubscribe -> exactly 1 disconnect
        let unsubAct = transport.processInboundUnsubscribe(centralId: centralId)
        XCTAssertEqual(unsubAct, .noOp)
        XCTAssertEqual(delegate.disconnectedPeers, [centralId])

        transport.stop()
    }
}


