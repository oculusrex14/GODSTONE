import XCTest
import SQLite3
import CryptoKit
@testable import GodstoneMesh

final class BoundRecipientKeyResolverTests: XCTestCase {

    private let seedA = Data(repeating: 0x11, count: 32)
    private let staticPrivA = Data(repeating: 0x33, count: 32)
    private let staticPrivB = Data(repeating: 0x44, count: 32)

    private func tempDbUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bound_resolver_test_\(UUID().uuidString).db")
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

    func testBoundResolver_ActiveTofu_ReturnsSigningKey() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b0)

        let key = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.count, 32)
        XCTAssertEqual(key, b0.signingPublicKey)
        XCTAssertNotEqual(key, b0.staticDhPublicKey)
    }

    func testBoundResolver_UserVerified_ReturnsSigningKey() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b0)

        // Test SQL seam: promote to USER_VERIFIED (code 2)
        var db: OpaquePointer?
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(db, "UPDATE peer_identities SET trust_level = 2", nil, nil, nil)
        sqlite3_close_v2(db)

        let key = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNotNil(key)
        XCTAssertEqual(key, b0.signingPublicKey)
    }

    func testBoundResolver_Unseen_ReturnsNull() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let unseenNodeId = Data(repeating: 0x99, count: 16)
        let key = resolver.publicSigningKey(forNodeId: unseenNodeId)
        XCTAssertNil(key)

        let row = try store.readRaw(unseenNodeId)
        XCTAssertNil(row)
    }

    func testBoundResolver_Quarantined_ReturnsNull() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let b5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b0)
        _ = repo.applyValidatedBinding(b5)

        let key = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNil(key, "Quarantined peer must return null")
    }

    func testBoundResolver_OldAcceptedReplayWhilePending_ReturnsNull() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let b5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b0)
        _ = repo.applyValidatedBinding(b5)

        // Replay old accepted binding
        _ = repo.applyValidatedBinding(b0)

        let key = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNil(key, "Replay while pending must return null")
    }

    func testBoundResolver_ApprovalRestoresResolution() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let b5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b0)
        _ = repo.applyValidatedBinding(b5)

        XCTAssertNil(resolver.publicSigningKey(forNodeId: b0.nodeId))

        let approval = repo.approvePendingRotation(
            nodeId: b0.nodeId,
            expectedPendingGeneration: 5,
            expectedPendingStaticDhPublicKey: b5.staticDhPublicKey
        )
        guard case .approved = approval else {
            XCTFail("Expected .approved")
            return
        }

        let key = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNotNil(key)
        XCTAssertEqual(key, b0.signingPublicKey)
    }

    func testBoundResolver_Revoked_ReturnsNull() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b0)

        XCTAssertNotNil(resolver.publicSigningKey(forNodeId: b0.nodeId))

        _ = repo.revokePeer(b0.nodeId)
        XCTAssertNil(resolver.publicSigningKey(forNodeId: b0.nodeId))

        // Subsequent binding rejected
        let b5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b5)
        XCTAssertNil(resolver.publicSigningKey(forNodeId: b0.nodeId))
    }

    func testBoundResolver_InvalidNodeLength_NoLookup() {
        final class CountingLookupSource: PeerIdentityLookupSource, @unchecked Sendable {
            var lookupCalls = 0
            func lookup(_ nodeId: Data) -> PeerIdentityLookup {
                lookupCalls += 1
                return .notFound
            }
        }

        let source = CountingLookupSource()
        let resolver = BoundRecipientKeyResolver(source: source)

        XCTAssertNil(resolver.publicSigningKey(forNodeId: Data(repeating: 0x01, count: 15)))
        XCTAssertNil(resolver.publicSigningKey(forNodeId: Data(repeating: 0x01, count: 17)))
        XCTAssertNil(resolver.publicSigningKey(forNodeId: Data()))
        XCTAssertEqual(source.lookupCalls, 0)

        XCTAssertNil(resolver.publicSigningKey(forNodeId: Data(repeating: 0x01, count: 16)))
        XCTAssertEqual(source.lookupCalls, 1)
    }

    func testBoundResolver_Corrupt_ReturnsNull() {
        final class CorruptLookupSource: PeerIdentityLookupSource, @unchecked Sendable {
            func lookup(_ nodeId: Data) -> PeerIdentityLookup {
                .corrupt(.mutationReadbackMismatch("test corruption"))
            }
        }

        let resolver = BoundRecipientKeyResolver(source: CorruptLookupSource())
        XCTAssertNil(resolver.publicSigningKey(forNodeId: Data(repeating: 0x01, count: 16)))
    }

    func testBoundResolver_StorageFailure_ReturnsNull() {
        final class StorageFailureLookupSource: PeerIdentityLookupSource, @unchecked Sendable {
            func lookup(_ nodeId: Data) -> PeerIdentityLookup {
                .storageFailure
            }
        }

        let resolver = BoundRecipientKeyResolver(source: StorageFailureLookupSource())
        XCTAssertNil(resolver.publicSigningKey(forNodeId: Data(repeating: 0x01, count: 16)))
    }

    func testBoundResolver_NoCacheAcrossLifecycle() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let b5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)

        // Step A: Active TOFU
        _ = repo.applyValidatedBinding(b0)
        let keyA = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNotNil(keyA)

        // Step B: Quarantined
        _ = repo.applyValidatedBinding(b5)
        XCTAssertNil(resolver.publicSigningKey(forNodeId: b0.nodeId))

        // Step C: Approved
        _ = repo.approvePendingRotation(
            nodeId: b0.nodeId,
            expectedPendingGeneration: 5,
            expectedPendingStaticDhPublicKey: b5.staticDhPublicKey
        )
        let keyC = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNotNil(keyC)
        XCTAssertEqual(keyA, keyC)

        // Step D: Revoked
        _ = repo.revokePeer(b0.nodeId)
        XCTAssertNil(resolver.publicSigningKey(forNodeId: b0.nodeId))
    }

    func testBoundResolver_DefensiveCopy() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b0)

        let key1 = resolver.publicSigningKey(forNodeId: b0.nodeId)
        let key2 = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key1, b0.signingPublicKey)
    }

    func testBoundResolver_ConcurrentRevoke_NoStalePostCommitKey() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b0)

        let group = DispatchGroup()
        var r1: Data? = nil

        group.enter()
        DispatchQueue.global().async {
            r1 = resolver.publicSigningKey(forNodeId: b0.nodeId)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            _ = repo.revokePeer(b0.nodeId)
            group.leave()
        }

        group.wait()

        if let key = r1 {
            XCTAssertEqual(key, b0.signingPublicKey)
        }

        let postRevokeKey = resolver.publicSigningKey(forNodeId: b0.nodeId)
        XCTAssertNil(postRevokeKey, "Post-commit resolution must be null")
    }

    func testBoundResolver_AckIntegrationLifecycle() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let resolver = BoundRecipientKeyResolver(source: repo)
        let authenticator = Ed25519AckAuthenticator(resolver: resolver)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let b5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        let msgId = Data(repeating: 0x55, count: 16)
        let routingTag = Data(repeating: 0x12, count: 4)

        // Step A1: Active TOFU verified ACK succeeds
        _ = repo.applyValidatedBinding(b0)
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: seedA,
            recipientNodeId: b0.nodeId,
            routingTag: routingTag
        )
        XCTAssertTrue(authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: b0.nodeId, ackFrame: ackFrame))

        // Step A2: Quarantine blocks ACK verification
        _ = repo.applyValidatedBinding(b5)
        XCTAssertFalse(authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: b0.nodeId, ackFrame: ackFrame))

        // Step A3: Approval restores ACK verification
        _ = repo.approvePendingRotation(
            nodeId: b0.nodeId,
            expectedPendingGeneration: 5,
            expectedPendingStaticDhPublicKey: b5.staticDhPublicKey
        )
        XCTAssertTrue(authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: b0.nodeId, ackFrame: ackFrame))

        // Step A4: Revocation permanently blocks ACK verification
        _ = repo.revokePeer(b0.nodeId)
        XCTAssertFalse(authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: b0.nodeId, ackFrame: ackFrame))

        // Negative controls
        let wrongRecipient = Data(repeating: 0xAA, count: 16)
        let wrongMsgId = Data(repeating: 0xBB, count: 16)
        var tamperedPayload = ackFrame.payload
        tamperedPayload[0] ^= 0xFF
        let tamperedAck = FrameV2(
            type: .ack,
            msgId: msgId,
            routingTag: routingTag,
            ttl: 4,
            hopCount: 0,
            flags: 0,
            payload: tamperedPayload
        )

        XCTAssertFalse(authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: wrongRecipient, ackFrame: ackFrame))
        XCTAssertFalse(authenticator.verify(originalMsgId: wrongMsgId, expectedRecipientNodeId: b0.nodeId, ackFrame: ackFrame))
        XCTAssertFalse(authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: b0.nodeId, ackFrame: tamperedAck))
        XCTAssertFalse(authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: wrongRecipient, ackFrame: ackFrame))
    }

    func testBoundResolver_ReadOnlyAdapter_SingleLookupCall() {
        final class CountingLookupSource: PeerIdentityLookupSource, @unchecked Sendable {
            var lookupCount = 0
            func lookup(_ nodeId: Data) -> PeerIdentityLookup {
                lookupCount += 1
                return .notFound
            }
        }

        let source = CountingLookupSource()
        let resolver = BoundRecipientKeyResolver(source: source)

        let validNode = Data(repeating: 0x01, count: 16)
        let invalidNode = Data(repeating: 0x01, count: 10)

        XCTAssertEqual(source.lookupCount, 0)

        _ = resolver.publicSigningKey(forNodeId: validNode)
        XCTAssertEqual(source.lookupCount, 1)

        _ = resolver.publicSigningKey(forNodeId: invalidNode)
        XCTAssertEqual(source.lookupCount, 1) // No extra call
    }
}
