import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class CompositionResolverAckTests: XCTestCase {

    private func tempDbUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("comp_resolver_ack_\(UUID().uuidString).db")
    }

    private func random16() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) })
    }

    private func makePeer(seed: Data, staticDhPriv: Data, generation: UInt32 = 0) -> (ValidatedPeerBinding, Data, Data, Curve25519.Signing.PrivateKey, Curve25519.KeyAgreement.PrivateKey) {
        let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let agreementKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticDhPriv)
        let nodeId = Blake2s.hash(signingKey.publicKey.rawRepresentation, digestLength: 16)
        let nodeHint = nodeId.prefix(4)

        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let sig = try! signingKey.signature(for: preimage)
        let binding = IdentityBindingV1(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: sig
        )
        let res = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: nodeHint
        )
        guard case .valid(let validated) = res else {
            fatalError("Validation failed")
        }
        return (validated, nodeId, signingKey.publicKey.rawRepresentation, signingKey, agreementKey)
    }

    private func setupRepository() throws -> (PeerIdentityRepository, BoundRecipientKeyResolver, SqlitePeerIdentityStore) {
        let store = try SqlitePeerIdentityStore(url: tempDbUrl())
        let repo = PeerIdentityRepository(store: store)
        let gate = DefaultRuntimeLifecycleGate()
        let lookup = RuntimeGatedPeerIdentityLookupSource(delegate: repo, lifecycleGate: gate)
        let resolver = BoundRecipientKeyResolver(source: lookup)
        return (repo, resolver, store)
    }

    func testComposition_ActiveTofuPeer_ResolvesSigningKey_AndValidAckSucceeds() throws {
        let (repo, resolver, _) = try setupRepository()
        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv = Data(repeating: 0x22, count: 32)
        let (binding, nodeId, signingPub, signingKey, _) = makePeer(seed: seed, staticDhPriv: staticPriv)

        let applyResult = repo.applyValidatedBinding(binding)
        guard case .firstSeenPinned = applyResult else {
            XCTFail("Expected firstSeenPinned")
            return
        }

        let resolvedPub = resolver.publicSigningKey(forNodeId: nodeId)
        XCTAssertEqual(resolvedPub, signingPub)

        let msgId = random16()
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: signingKey.rawRepresentation,
            recipientNodeId: nodeId,
            routingTag: nodeId.prefix(4)
        )

        let auth = Ed25519AckAuthenticator(resolver: resolver)
        XCTAssertTrue(auth.verify(originalMsgId: msgId, expectedRecipientNodeId: nodeId, ackFrame: ackFrame))
    }

    func testComposition_UserVerifiedPeer_ResolvesSigningKey_AndValidAckSucceeds() throws {
        let (repo, resolver, _) = try setupRepository()
        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv1 = Data(repeating: 0x22, count: 32)
        let (binding1, nodeId, signingPub, signingKey, _) = makePeer(seed: seed, staticDhPriv: staticPriv1, generation: 0)
        _ = repo.applyValidatedBinding(binding1)

        let staticPriv2 = Data(repeating: 0x33, count: 32)
        let (binding2, _, _, _, agreement2) = makePeer(seed: seed, staticDhPriv: staticPriv2, generation: 1)
        _ = repo.applyValidatedBinding(binding2)

        let approveResult = repo.approvePendingRotation(
            nodeId: nodeId,
            expectedPendingGeneration: 1,
            expectedPendingStaticDhPublicKey: agreement2.publicKey.rawRepresentation
        )
        guard case .approved(let view) = approveResult else {
            XCTFail("Expected approved")
            return
        }
        XCTAssertEqual(view.trustLevel, .tofuPinned)

        let resolvedPub = resolver.publicSigningKey(forNodeId: nodeId)
        XCTAssertEqual(resolvedPub, signingPub)

        let msgId = random16()
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: signingKey.rawRepresentation,
            recipientNodeId: nodeId,
            routingTag: nodeId.prefix(4)
        )

        let auth = Ed25519AckAuthenticator(resolver: resolver)
        XCTAssertTrue(auth.verify(originalMsgId: msgId, expectedRecipientNodeId: nodeId, ackFrame: ackFrame))
    }

    func testComposition_QuarantinedPeer_ResolverReturnsNull_AndAckFails() throws {
        let (repo, resolver, _) = try setupRepository()
        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv1 = Data(repeating: 0x22, count: 32)
        let (binding1, nodeId, _, signingKey, _) = makePeer(seed: seed, staticDhPriv: staticPriv1, generation: 0)
        _ = repo.applyValidatedBinding(binding1)

        let staticPriv2 = Data(repeating: 0x33, count: 32)
        let (binding2, _, _, _, _) = makePeer(seed: seed, staticDhPriv: staticPriv2, generation: 1)
        let applyResult = repo.applyValidatedBinding(binding2)
        guard case .keyChangedQuarantined = applyResult else {
            XCTFail("Expected keyChangedQuarantined")
            return
        }

        XCTAssertNil(resolver.publicSigningKey(forNodeId: nodeId))

        let msgId = random16()
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: signingKey.rawRepresentation,
            recipientNodeId: nodeId,
            routingTag: nodeId.prefix(4)
        )

        let auth = Ed25519AckAuthenticator(resolver: resolver)
        XCTAssertFalse(auth.verify(originalMsgId: msgId, expectedRecipientNodeId: nodeId, ackFrame: ackFrame))
    }

    func testComposition_RevokedPeer_ResolverReturnsNull_AndAckFails() throws {
        let (repo, resolver, _) = try setupRepository()
        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv = Data(repeating: 0x22, count: 32)
        let (binding, nodeId, _, signingKey, _) = makePeer(seed: seed, staticDhPriv: staticPriv)
        _ = repo.applyValidatedBinding(binding)
        _ = repo.revokePeer(nodeId)

        XCTAssertNil(resolver.publicSigningKey(forNodeId: nodeId))

        let msgId = random16()
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: signingKey.rawRepresentation,
            recipientNodeId: nodeId,
            routingTag: nodeId.prefix(4)
        )

        let auth = Ed25519AckAuthenticator(resolver: resolver)
        XCTAssertFalse(auth.verify(originalMsgId: msgId, expectedRecipientNodeId: nodeId, ackFrame: ackFrame))
    }

    func testComposition_UnseenPeer_ResolverReturnsNull_AndAckFails() throws {
        let (_, resolver, _) = try setupRepository()
        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv = Data(repeating: 0x22, count: 32)
        let (_, nodeId, _, signingKey, _) = makePeer(seed: seed, staticDhPriv: staticPriv)

        XCTAssertNil(resolver.publicSigningKey(forNodeId: nodeId))

        let msgId = random16()
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: signingKey.rawRepresentation,
            recipientNodeId: nodeId,
            routingTag: nodeId.prefix(4)
        )

        let auth = Ed25519AckAuthenticator(resolver: resolver)
        XCTAssertFalse(auth.verify(originalMsgId: msgId, expectedRecipientNodeId: nodeId, ackFrame: ackFrame))
    }

    func testComposition_ApprovedPendingRotation_RestoresAckResolution() throws {
        let (repo, resolver, _) = try setupRepository()
        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv1 = Data(repeating: 0x22, count: 32)
        let (binding1, nodeId, signingPub, signingKey, _) = makePeer(seed: seed, staticDhPriv: staticPriv1, generation: 0)
        _ = repo.applyValidatedBinding(binding1)

        let staticPriv2 = Data(repeating: 0x33, count: 32)
        let (binding2, _, _, _, agreement2) = makePeer(seed: seed, staticDhPriv: staticPriv2, generation: 1)
        _ = repo.applyValidatedBinding(binding2)

        XCTAssertNil(resolver.publicSigningKey(forNodeId: nodeId))

        let approveResult = repo.approvePendingRotation(
            nodeId: nodeId,
            expectedPendingGeneration: 1,
            expectedPendingStaticDhPublicKey: agreement2.publicKey.rawRepresentation
        )
        guard case .approved = approveResult else {
            XCTFail("Expected approved")
            return
        }

        XCTAssertEqual(resolver.publicSigningKey(forNodeId: nodeId), signingPub)

        let msgId = random16()
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: signingKey.rawRepresentation,
            recipientNodeId: nodeId,
            routingTag: nodeId.prefix(4)
        )

        let auth = Ed25519AckAuthenticator(resolver: resolver)
        XCTAssertTrue(auth.verify(originalMsgId: msgId, expectedRecipientNodeId: nodeId, ackFrame: ackFrame))
    }

    func testComposition_TamperedAckSignature_FailsVerification() throws {
        let (repo, resolver, _) = try setupRepository()
        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv = Data(repeating: 0x22, count: 32)
        let (binding, nodeId, _, signingKey, _) = makePeer(seed: seed, staticDhPriv: staticPriv)
        _ = repo.applyValidatedBinding(binding)

        let msgId = random16()
        let ackFrame = try AckFrame.build(
            msgId: msgId,
            recipientSigningPrivKey: signingKey.rawRepresentation,
            recipientNodeId: nodeId,
            routingTag: nodeId.prefix(4)
        )

        var tamperedPayload = ackFrame.payload
        tamperedPayload[0] ^= 0xFF

        let tamperedFrame = FrameV2(
            type: ackFrame.type,
            msgId: ackFrame.msgId,
            routingTag: ackFrame.routingTag,
            ttl: ackFrame.ttl,
            hopCount: ackFrame.hopCount,
            flags: ackFrame.flags,
            payload: tamperedPayload
        )

        let auth = Ed25519AckAuthenticator(resolver: resolver)
        XCTAssertFalse(auth.verify(originalMsgId: msgId, expectedRecipientNodeId: nodeId, ackFrame: tamperedFrame))
    }

    func testComposition_SameRepositoryBacksResolverAndTrustAuthority() throws {
        let store = try SqlitePeerIdentityStore(url: tempDbUrl())
        let repo = PeerIdentityRepository(store: store)
        let gate = DefaultRuntimeLifecycleGate()
        let lookup = RuntimeGatedPeerIdentityLookupSource(delegate: repo, lifecycleGate: gate)
        let resolver = BoundRecipientKeyResolver(source: lookup)
        let trustAuthority = RuntimeGatedPeerBindingTrustAuthority(
            delegate: RepositoryPeerBindingTrustAuthority(repository: repo),
            lifecycleGate: gate
        )

        let seed = Data(repeating: 0x11, count: 32)
        let staticPriv = Data(repeating: 0x22, count: 32)
        let (binding, nodeId, signingPub, _, _) = makePeer(seed: seed, staticDhPriv: staticPriv)

        let applyResult = trustAuthority.applyValidatedBinding(binding)
        guard case .firstSeenPinned = applyResult else {
            XCTFail("Expected firstSeenPinned")
            return
        }

        let resolvedPub = resolver.publicSigningKey(forNodeId: nodeId)
        XCTAssertEqual(resolvedPub, signingPub)
    }
}
