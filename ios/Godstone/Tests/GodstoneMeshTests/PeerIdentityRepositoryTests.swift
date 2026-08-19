import XCTest
import SQLite3
import CryptoKit
@testable import GodstoneMesh

final class PeerIdentityRepositoryTests: XCTestCase {

    private let seedA = Data(repeating: 0x11, count: 32)
    private let seedB = Data(repeating: 0x22, count: 32)

    private let staticPrivA = Data(repeating: 0x33, count: 32)
    private let staticPrivB = Data(repeating: 0x44, count: 32)
    private let staticPrivC = Data(repeating: 0x55, count: 32)

    private func tempDbUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peer_repo_test_\(UUID().uuidString).db")
    }

    private func makeBinding(
        seed: Data,
        generation: UInt32,
        staticDhPriv: Data
    ) -> ValidatedPeerBinding {
        let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let agreementKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticDhPriv)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let sig = try! signingKey.signature(for: preimage)
        let binding = try! IdentityBindingV1(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: sig
        )
        let res = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: IdentityBindingV1.deriveNodeHint(
                nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signingKey.publicKey.rawRepresentation)
            )
        )
        guard case .valid(let validated) = res else {
            fatalError("Validation failed")
        }
        return validated
    }

    // =========================================================================
    // 1. FIRST SEEN & RECONNECT TESTS
    // =========================================================================

    func testFirstSeenGenerationZero() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)

        let result = repo.applyValidatedBinding(binding)
        XCTAssertEqual(result, .firstSeenPinned)

        let lookup = repo.lookup(binding.nodeId)
        guard case .verified(let verified) = lookup else {
            XCTFail("Expected verified lookup, got \(lookup)")
            return
        }
        XCTAssertEqual(verified.acceptedGeneration, 0)
        XCTAssertEqual(verified.trustLevel, .tofuPinned)
    }

    func testFirstSeenGenerationSeven() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 7, staticDhPriv: staticPrivA)

        let result = repo.applyValidatedBinding(binding)
        XCTAssertEqual(result, .firstSeenPinned)

        let lookup = repo.lookup(binding.nodeId)
        guard case .verified(let verified) = lookup else {
            XCTFail("Expected verified lookup")
            return
        }
        XCTAssertEqual(verified.acceptedGeneration, 7)
    }

    func testFirstSeenGenerationUint32Max() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: UInt32.max, staticDhPriv: staticPrivA)

        let result = repo.applyValidatedBinding(binding)
        XCTAssertEqual(result, .firstSeenPinned)

        let res2 = repo.applyValidatedBinding(binding)
        XCTAssertEqual(res2, .accepted)
    }

    func testExactReconnectAccepted() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(binding)

        let res2 = repo.applyValidatedBinding(binding)
        XCTAssertEqual(res2, .accepted)
    }

    // =========================================================================
    // 2. ROTATION & QUARANTINE PROGRESSION
    // =========================================================================

    func testInitialPendingCandidate() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        let res = repo.applyValidatedBinding(b2)
        XCTAssertEqual(res, .keyChangedQuarantined)

        let lookup = repo.lookup(b1.nodeId)
        guard case .quarantined(let quarantined) = lookup else {
            XCTFail("Expected quarantined lookup")
            return
        }
        XCTAssertEqual(quarantined.acceptedGeneration, 5)
        XCTAssertEqual(quarantined.pendingGeneration, 6)
    }

    func testAdvancePendingCandidateHighWater() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        let b3 = makeBinding(seed: seedA, generation: 8, staticDhPriv: staticPrivC)
        let res = repo.applyValidatedBinding(b3)
        XCTAssertEqual(res, .keyChangedQuarantined)

        let lookup = repo.lookup(b1.nodeId)
        guard case .quarantined(let quarantined) = lookup else {
            XCTFail("Expected quarantined lookup")
            return
        }
        XCTAssertEqual(quarantined.acceptedGeneration, 5)
        XCTAssertEqual(quarantined.pendingGeneration, 8)
    }

    func testPendingDuplicateKeepsQuarantined() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        let res = repo.applyValidatedBinding(b2)
        XCTAssertEqual(res, .keyChangedQuarantined)
    }

    func testOldAcceptedDuringQuarantineKeepsQuarantined() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        let res = repo.applyValidatedBinding(b1)
        XCTAssertEqual(res, .keyChangedQuarantined)
    }

    // =========================================================================
    // 3. REJECTION TESTS
    // =========================================================================

    func testRollbackRejectedWithoutMutation() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let bLower = makeBinding(seed: seedA, generation: 4, staticDhPriv: staticPrivA)
        let res = repo.applyValidatedBinding(bLower)
        XCTAssertEqual(res, .rejected(.rollback))

        let row = try store.readRaw(b1.nodeId)
        XCTAssertEqual(row?.acceptedGenerationRaw, 5)
    }

    // =========================================================================
    // 4. LOOKUP CLASSIFICATION (L1 - L10)
    // =========================================================================

    func testLookupClassifications() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)

        // L1: Absent
        XCTAssertEqual(repo.lookup(Data(repeating: 0x99, count: 16)), .notFound)

        // L10: Invalid length
        guard case .invalidArgument = repo.lookup(Data(repeating: 0x99, count: 15)) else {
            XCTFail("Expected invalidArgument")
            return
        }

        // L2: Valid TOFU
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)
        guard case .verified = repo.lookup(b1.nodeId) else {
            XCTFail("Expected verified")
            return
        }

        // L4: Quarantined
        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)
        guard case .quarantined = repo.lookup(b1.nodeId) else {
            XCTFail("Expected quarantined")
            return
        }
    }

    // =========================================================================
    // 5. CORRUPT ROW DETECTION (R-C1 to R-C9)
    // =========================================================================

    func testCorruptRowDetectionFailsClosed() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)

        let binding = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let signPub = signingKey.publicKey.rawRepresentation
        let agreementKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let staticPub = agreementKey.publicKey.rawRepresentation

        // Bypass check with test seam
        try store.execRawSql("PRAGMA ignore_check_constraints = ON")
        _ = try store.insertFirstSeen(
            nodeId: binding.nodeId,
            signingPub: signPub,
            acceptedStatic: staticPub,
            acceptedGeneration: 0,
            trustCode: 99
        )

        let applyRes = repo.applyValidatedBinding(binding)
        guard case .corrupt(let reason) = applyRes,
              case .unknownTrustLevelCode(let code) = reason else {
            XCTFail("Expected corrupt with unknownTrustLevelCode, got \(applyRes)")
            return
        }
        XCTAssertEqual(code, 99)

        let lookupRes = repo.lookup(binding.nodeId)
        guard case .corrupt = lookupRes else {
            XCTFail("Expected corrupt lookup")
            return
        }
    }

    // =========================================================================
    // 6. CROSS-CONNECTION CONCURRENCY TESTS (C1, C2)
    // =========================================================================

    func testConcurrencyC1IdenticalFirstSeen() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        let binding = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)

        let group = DispatchGroup()
        var res1: PeerTrustApplyResult?
        var res2: PeerTrustApplyResult?

        group.enter()
        DispatchQueue.global().async {
            res1 = repo1.applyValidatedBinding(binding)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            res2 = repo2.applyValidatedBinding(binding)
            group.leave()
        }

        group.wait()

        let results = [res1, res2]
        XCTAssertTrue(results.contains(.firstSeenPinned))
        XCTAssertTrue(results.contains(.accepted))

        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(binding.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 5)
        XCTAssertNil(row?.pendingGenerationRaw)
    }

    func testConcurrencyC2Gen5Gen6HighWater() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo1.applyValidatedBinding(b0)

        let bGen5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        let bGen6 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivC)

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = repo1.applyValidatedBinding(bGen5)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            _ = repo2.applyValidatedBinding(bGen6)
            group.leave()
        }

        group.wait()

        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b0.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.pendingGenerationRaw, 6)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, bGen6.staticDhPublicKey)
    }
}
