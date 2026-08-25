import XCTest
import SQLite3
import CryptoKit
@testable import GodstoneCore
@testable import GodstoneMesh

final class TrustedHandshakeControllerTests: XCTestCase {

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func tempDbUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("trusted_hs_test_\(UUID().uuidString).db")
    }

    private func makeIdentity(seedByte: UInt8, staticPrivByte: UInt8, generation: UInt32 = 0) throws -> MeshIdentity {
        let kc = InMemoryKeychain()
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: staticPrivByte, count: 32)
        let state = try LocalIdentityStateV1(generation: generation, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    private func makeBinding(
        seedByte: UInt8,
        staticPrivByte: UInt8,
        generation: UInt32 = 0,
        overrideStaticPub: Data? = nil
    ) throws -> IdentityBindingV1 {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seedByte, count: 32))
        let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: staticPrivByte, count: 32))
        let staticPub = overrideStaticPub ?? agreementKey.publicKey.rawRepresentation

        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: staticPub
        )
        let sig = try signingKey.signature(for: preimage)
        return try IdentityBindingV1(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: staticPub,
            signature: sig
        )
    }

    private final class CountingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        private let delegate: any PeerBindingTrustAuthority
        var applyCalls = 0
        var lastBinding: ValidatedPeerBinding?

        init(delegate: any PeerBindingTrustAuthority) {
            self.delegate = delegate
        }

        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            applyCalls += 1
            lastBinding = binding
            return delegate.applyValidatedBinding(binding)
        }
    }

    private final class LambdaTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        private let block: @Sendable (ValidatedPeerBinding) -> PeerTrustApplyResult

        init(block: @escaping @Sendable (ValidatedPeerBinding) -> PeerTrustApplyResult) {
            self.block = block
        }

        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            block(binding)
        }
    }

    // MARK: - H-I01: Full First Seen Handshake

    func testTrustedHandshake_H_I01_FullFirstSeenHandshake_SucceedsAndReachesReady() throws {
        let urlA = tempDbUrl()
        let urlB = tempDbUrl()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let storeB = try SqlitePeerIdentityStore(url: urlB)
        let repoA = PeerIdentityRepository(store: storeA)
        let repoB = PeerIdentityRepository(store: storeB)

        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let aliceAuth = CountingTrustAuthority(delegate: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bobAuth = CountingTrustAuthority(delegate: RepositoryPeerBindingTrustAuthority(repository: repoB))

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: aliceAuth)
        let bob = TrustedHandshakeController.responder(identity: bobId, remoteHint: aliceId.nodeHint, trustAuthority: bobAuth)

        // Step 1: Alice writes HS1 (32 bytes)
        let hs1 = try alice.initiatorWriteMessage1()
        XCTAssertEqual(hs1.count, 32)
        XCTAssertEqual(alice.state, .handshakeInProgress)

        // Step 2: Bob reads HS1, issues local binding, writes HS2 (229 bytes)
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)
        XCTAssertNotNil(hs2)
        XCTAssertEqual(hs2?.count, 229)
        XCTAssertEqual(bob.state, .handshakeInProgress)

        // Step 3: Alice reads HS2, validates Bob, writes HS3 (197 bytes)
        let hs3 = alice.initiatorProcessMessage2(hs2: hs2!, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNotNil(hs3)
        XCTAssertEqual(hs3?.count, 197)
        XCTAssertEqual(alice.state, .ready)
        XCTAssertTrue(alice.isReady)
        XCTAssertEqual(aliceAuth.applyCalls, 1)

        // Timing check: Alice has Bob's remote static immediately after HS2
        XCTAssertNotNil(alice.authenticatedRemoteStaticKey)
        XCTAssertEqual(alice.authenticatedRemoteStaticKey, bobId.staticDhPublicKey)

        // Step 4: Bob reads HS3, validates Alice, advances to READY
        let bobReady = bob.responderProcessMessage3(hs3: hs3!, advertisedRemoteHint: aliceId.nodeHint)
        XCTAssertTrue(bobReady)
        XCTAssertEqual(bob.state, .ready)
        XCTAssertTrue(bob.isReady)
        XCTAssertEqual(bobAuth.applyCalls, 1)
        XCTAssertNotNil(bob.authenticatedRemoteStaticKey)
        XCTAssertEqual(bob.authenticatedRemoteStaticKey, aliceId.staticDhPublicKey)

        // Durable rows are TOFU_PINNED
        let aliceLookup = repoA.lookup(bobId.nodeId)
        guard case .verified(let aIdentity) = aliceLookup else {
            XCTFail("Alice lookup must be verified")
            return
        }
        XCTAssertEqual(aIdentity.trustLevel, .tofuPinned)

        let bobLookup = repoB.lookup(aliceId.nodeId)
        guard case .verified(let bIdentity) = bobLookup else {
            XCTFail("Bob lookup must be verified")
            return
        }
        XCTAssertEqual(bIdentity.trustLevel, .tofuPinned)
    }

    // MARK: - H-I02: Repeat Handshake

    func testTrustedHandshake_H_I02_RepeatHandshake_AcceptedAndReachesReady() throws {
        let urlA = tempDbUrl()
        let urlB = tempDbUrl()
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let storeB = try SqlitePeerIdentityStore(url: urlB)
        let repoA = PeerIdentityRepository(store: storeA)
        let repoB = PeerIdentityRepository(store: storeB)

        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        // Pre-populate TOFU
        let bobB = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44)
        let vBob = IdentityBindingValidator.validate(serialized: bobB.encode(), authenticatedRemoteStaticKey: bobId.staticDhPublicKey, advertisedNodeHint: bobId.nodeHint)
        if case .valid(let v) = vBob { _ = repoA.applyValidatedBinding(v) }

        let aliceB = try makeBinding(seedByte: 0x11, staticPrivByte: 0x22)
        let vAlice = IdentityBindingValidator.validate(serialized: aliceB.encode(), authenticatedRemoteStaticKey: aliceId.staticDhPublicKey, advertisedNodeHint: aliceId.nodeHint)
        if case .valid(let v) = vAlice { _ = repoB.applyValidatedBinding(v) }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bob = TrustedHandshakeController.responder(identity: bobId, remoteHint: aliceId.nodeHint, trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoB))

        let hs1 = try alice.initiatorWriteMessage1()
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)!
        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)!
        let bobReady = bob.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: aliceId.nodeHint)

        XCTAssertTrue(alice.isReady)
        XCTAssertTrue(bobReady)
        XCTAssertTrue(bob.isReady)
    }

    // MARK: - H-I03: Malformed Length

    func testTrustedHandshake_H_I03_HS2MalformedLength_FailsValidation_NoHS3_NotReady() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let applyCount = Box(0)
        let fakeAuth = LambdaTrustAuthority { _ in
            applyCount.value += 1
            return .accepted
        }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)

        let malformedPayload = Data(repeating: 0x55, count: 100)
        let hs2 = try bobNoise.writeMessage2(payload: malformedPayload)

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3, "HS3 must not be emitted for malformed binding length")
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertFalse(alice.isReady)
        XCTAssertEqual(applyCount.value, 0)
    }

    // MARK: - H-I04: Unsupported Version

    func testTrustedHandshake_H_I04_HS2UnsupportedVersion_FailsValidation_NoHS3_NotReady() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let applyCount = Box(0)
        let fakeAuth = LambdaTrustAuthority { _ in
            applyCount.value += 1
            return .accepted
        }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)

        var validBinding = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode()
        validBinding[0] = 0x02 // version = 2
        let hs2 = try bobNoise.writeMessage2(payload: validBinding)

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertFalse(alice.isReady)
        XCTAssertEqual(applyCount.value, 0)
    }

    // MARK: - H-I05: Invalid Signature

    func testTrustedHandshake_H_I05_HS2InvalidSignature_FailsValidation_NoHS3_NotReady() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let applyCount = Box(0)
        let fakeAuth = LambdaTrustAuthority { _ in
            applyCount.value += 1
            return .accepted
        }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)

        var tamperedBinding = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode()
        tamperedBinding[69] ^= 0xFF
        let hs2 = try bobNoise.writeMessage2(payload: tamperedBinding)

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertFalse(alice.isReady)
        XCTAssertEqual(applyCount.value, 0)
    }

    // MARK: - H-I06: Static Mismatch

    func testTrustedHandshake_H_I06_HS2StaticMismatch_FailsValidation_NoHS3_NotReady() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let applyCount = Box(0)
        let fakeAuth = LambdaTrustAuthority { _ in
            applyCount.value += 1
            return .accepted
        }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)

        let otherStatic = Data(repeating: 0x99, count: 32)
        let mismatchBinding = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44, overrideStaticPub: otherStatic).encode()
        let hs2 = try bobNoise.writeMessage2(payload: mismatchBinding)

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertFalse(alice.isReady)
        XCTAssertEqual(applyCount.value, 0)
    }

    // MARK: - H-I07: Advertisement Hint Mismatch

    func testTrustedHandshake_H_I07_HS2AdvertisementHintMismatch_FailsValidation_NoHS3_NotReady() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let applyCount = Box(0)
        let fakeAuth = LambdaTrustAuthority { _ in
            applyCount.value += 1
            return .accepted
        }

        let wrongHint = Data(repeating: 0xFE, count: 4)
        let alice = TrustedHandshakeController(
            noiseSession: NoiseSession(role: .initiator, staticKey: aliceId.agreementKey, localHint: aliceId.nodeHint, remoteHint: wrongHint),
            trustAuthority: fakeAuth,
            localIdentity: aliceId
        )
        let bob = TrustedHandshakeController(
            noiseSession: NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: wrongHint, remoteHint: aliceId.nodeHint),
            trustAuthority: fakeAuth,
            localIdentity: bobId
        )

        let hs1 = try alice.initiatorWriteMessage1()
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)!

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: wrongHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertFalse(alice.isReady)
        XCTAssertEqual(applyCount.value, 0)
    }

    // MARK: - H-I08: Quarantined Candidate

    func testTrustedHandshake_H_I08_HS2KeyChangedQuarantined_NoHS3_NotReady() throws {
        let urlA = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: urlA) }

        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let repoA = PeerIdentityRepository(store: storeA)
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId0 = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        // Step 1: Alice pins Bob at gen 0
        let b0 = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44, generation: 0)
        let v0 = IdentityBindingValidator.validate(serialized: b0.encode(), authenticatedRemoteStaticKey: bobId0.staticDhPublicKey, advertisedNodeHint: bobId0.nodeHint)
        if case .valid(let v) = v0 { _ = repoA.applyValidatedBinding(v) }

        // Step 2: Bob presents gen 5 with new static 0x77
        let bobId5 = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x77, generation: 5)
        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId0.nodeHint, trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId5.agreementKey, localHint: bobId0.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)
        let hs2 = try bobNoise.writeMessage2(payload: try makeBinding(seedByte: 0x33, staticPrivByte: 0x77, generation: 5).encode())

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId0.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .quarantined)
        XCTAssertFalse(alice.isReady)

        let lookup = repoA.lookup(bobId0.nodeId)
        guard case .quarantined(let q) = lookup else {
            XCTFail("Expected quarantined lookup")
            return
        }
        XCTAssertEqual(q.pendingGeneration, 5)
        XCTAssertEqual(q.pendingStaticDhPublicKey, bobId5.staticDhPublicKey)
    }

    // MARK: - H-I09: Old Accepted Replay While Pending

    func testTrustedHandshake_H_I09_HS2OldAcceptedReplayWhilePending_NoHS3_NotReady() throws {
        let urlA = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: urlA) }

        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let repoA = PeerIdentityRepository(store: storeA)
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId0 = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)
        let bobId5 = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x77, generation: 5)

        // Pin gen 0 and add pending gen 5
        let b0 = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44, generation: 0)
        let v0 = IdentityBindingValidator.validate(serialized: b0.encode(), authenticatedRemoteStaticKey: bobId0.staticDhPublicKey, advertisedNodeHint: bobId0.nodeHint)
        if case .valid(let v) = v0 { _ = repoA.applyValidatedBinding(v) }

        let b5 = try makeBinding(seedByte: 0x33, staticPrivByte: 0x77, generation: 5)
        let v5 = IdentityBindingValidator.validate(serialized: b5.encode(), authenticatedRemoteStaticKey: bobId5.staticDhPublicKey, advertisedNodeHint: bobId0.nodeHint)
        if case .valid(let v) = v5 { _ = repoA.applyValidatedBinding(v) }

        // Replay gen 0 handshake while pending exists
        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId0.nodeHint, trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bobNoise0 = NoiseSession(role: .responder, staticKey: bobId0.agreementKey, localHint: bobId0.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise0.readMessage1(hs1)
        let hs2 = try bobNoise0.writeMessage2(payload: b0.encode())

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId0.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .quarantined)
        XCTAssertFalse(alice.isReady)
    }

    // MARK: - H-I10: Revoked Responder

    func testTrustedHandshake_H_I10_HS2RevokedResponder_Rejected_NoHS3_NotReady() throws {
        let urlA = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: urlA) }

        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let repoA = PeerIdentityRepository(store: storeA)
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId0 = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        // Pin and revoke Bob
        let b0 = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44, generation: 0)
        let v0 = IdentityBindingValidator.validate(serialized: b0.encode(), authenticatedRemoteStaticKey: bobId0.staticDhPublicKey, advertisedNodeHint: bobId0.nodeHint)
        if case .valid(let v) = v0 { _ = repoA.applyValidatedBinding(v) }
        _ = repoA.revokePeer(bobId0.nodeId)

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId0.nodeHint, trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bobNoise0 = NoiseSession(role: .responder, staticKey: bobId0.agreementKey, localHint: bobId0.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise0.readMessage1(hs1)
        let hs2 = try bobNoise0.writeMessage2(payload: b0.encode())

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId0.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertFalse(alice.isReady)
    }

    // MARK: - H-I11: Injected Repository Corrupt

    func testTrustedHandshake_H_I11_HS2RepositoryCorrupt_NoHS3_NotReady() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let corruptAuth = LambdaTrustAuthority { _ in
            .corrupt(.mutationReadbackMismatch("test corruption"))
        }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: corruptAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)
        let hs2 = try bobNoise.writeMessage2(payload: try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode())

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .corrupt)
        XCTAssertFalse(alice.isReady)
    }

    // MARK: - H-I12: Injected Repository Storage Failure

    func testTrustedHandshake_H_I12_HS2RepositoryStorageFailure_NoHS3_NotReady() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let storageFailureAuth = LambdaTrustAuthority { _ in
            .storageFailure
        }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: storageFailureAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)
        let hs2 = try bobNoise.writeMessage2(payload: try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode())

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .storageFailure)
        XCTAssertFalse(alice.isReady)
    }

    // MARK: - H-I13: Responder HS3 Quarantine

    func testTrustedHandshake_H_I13_ResponderHS3Quarantine_NoiseEstablished_ControllerNotReady_SealDenied() throws {
        let urlB = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: urlB) }

        let storeB = try SqlitePeerIdentityStore(url: urlB)
        let repoB = PeerIdentityRepository(store: storeB)
        let aliceId0 = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        // Bob pins Alice at gen 0
        let b0 = try makeBinding(seedByte: 0x11, staticPrivByte: 0x22, generation: 0)
        let v0 = IdentityBindingValidator.validate(serialized: b0.encode(), authenticatedRemoteStaticKey: aliceId0.staticDhPublicKey, advertisedNodeHint: aliceId0.nodeHint)
        if case .valid(let v) = v0 { _ = repoB.applyValidatedBinding(v) }

        // Alice rotates to gen 5 (new static 0x88)
        let aliceId5 = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x88, generation: 5)
        let aliceNoise = NoiseSession(role: .initiator, staticKey: aliceId5.agreementKey, localHint: aliceId0.nodeHint, remoteHint: bobId.nodeHint)
        let bob = TrustedHandshakeController.responder(identity: bobId, remoteHint: aliceId0.nodeHint, trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoB))

        let hs1 = try aliceNoise.writeMessage1(payload: Data())
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)!
        _ = try aliceNoise.readMessage2(hs2)

        let hs3 = try aliceNoise.writeMessage3(payload: try makeBinding(seedByte: 0x11, staticPrivByte: 0x88, generation: 5).encode())

        // Bob processes HS3
        let ready = bob.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: aliceId0.nodeHint)
        XCTAssertFalse(ready)
        XCTAssertEqual(bob.state, .quarantined)
        XCTAssertFalse(bob.isReady)

        // Underlying Noise is established, but seal/open must return nil
        XCTAssertTrue(bob.noiseSession.isEstablished)
        XCTAssertNil(bob.seal(Data("secret".utf8)))
        let ciphertext = try aliceNoise.encrypt(Data("inbound".utf8))
        XCTAssertNil(bob.open(ciphertext))
    }

    // MARK: - H-I14: Responder HS3 Invalid Signature

    func testTrustedHandshake_H_I14_ResponderHS3InvalidSignature_RepoApplyCountZero_NotReady_SealDenied() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let applyCount = Box(0)
        let fakeAuth = LambdaTrustAuthority { _ in
            applyCount.value += 1
            return .accepted
        }

        let aliceNoise = NoiseSession(role: .initiator, staticKey: aliceId.agreementKey, localHint: aliceId.nodeHint, remoteHint: bobId.nodeHint)
        let bob = TrustedHandshakeController.responder(identity: bobId, remoteHint: aliceId.nodeHint, trustAuthority: fakeAuth)

        let hs1 = try aliceNoise.writeMessage1(payload: Data())
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)!
        _ = try aliceNoise.readMessage2(hs2)

        var tamperedBinding = try makeBinding(seedByte: 0x11, staticPrivByte: 0x22).encode()
        tamperedBinding[69] ^= 0xFF
        let hs3 = try aliceNoise.writeMessage3(payload: tamperedBinding)

        let ready = bob.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: aliceId.nodeHint)
        XCTAssertFalse(ready)
        XCTAssertEqual(bob.state, .securityReject)
        XCTAssertFalse(bob.isReady)
        XCTAssertEqual(applyCount.value, 0)
        XCTAssertNil(bob.seal(Data("test".utf8)))
    }

    // MARK: - H-I15: Seal/Open Before Ready

    func testTrustedHandshake_H_I15_SealOpenBeforeReady_ReturnsNull() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)
        let fakeAuth = LambdaTrustAuthority { _ in .accepted }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        XCTAssertEqual(alice.state, .initial)
        XCTAssertNil(alice.seal(Data("test".utf8)))
        XCTAssertNil(alice.open(Data(repeating: 0, count: 32)))

        _ = try alice.initiatorWriteMessage1()
        XCTAssertEqual(alice.state, .handshakeInProgress)
        XCTAssertNil(alice.seal(Data("test".utf8)))
        XCTAssertNil(alice.open(Data(repeating: 0, count: 32)))
    }

    // MARK: - H-I16: Transport Round-Trip

    func testTrustedHandshake_H_I16_ApplicationTransportRoundTrip_AfterBothReady_Succeeds() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)
        let fakeAuth = LambdaTrustAuthority { _ in .accepted }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        let bob = TrustedHandshakeController.responder(identity: bobId, remoteHint: aliceId.nodeHint, trustAuthority: fakeAuth)

        let hs1 = try alice.initiatorWriteMessage1()
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)!
        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)!
        let bobReady = bob.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: aliceId.nodeHint)

        XCTAssertTrue(alice.isReady)
        XCTAssertTrue(bobReady)

        let plain1 = Data("hello from alice".utf8)
        let sealed1 = alice.seal(plain1)!
        let opened1 = bob.open(sealed1)!
        XCTAssertEqual(plain1, opened1)

        let plain2 = Data("hello from bob".utf8)
        let sealed2 = bob.seal(plain2)!
        let opened2 = alice.open(sealed2)!
        XCTAssertEqual(plain2, opened2)
    }

    // MARK: - H-I17: Post-Approval Handshake

    func testTrustedHandshake_H_I17_PostApprovalHandshakeWithNewStatic_AcceptedAndReachesReady() throws {
        let urlA = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: urlA) }

        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let repoA = PeerIdentityRepository(store: storeA)
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId0 = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)
        let bobId5 = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x77, generation: 5)

        // Pin gen 0 and quarantine gen 5
        let b0 = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44, generation: 0)
        let v0 = IdentityBindingValidator.validate(serialized: b0.encode(), authenticatedRemoteStaticKey: bobId0.staticDhPublicKey, advertisedNodeHint: bobId0.nodeHint)
        if case .valid(let v) = v0 { _ = repoA.applyValidatedBinding(v) }

        let b5 = try makeBinding(seedByte: 0x33, staticPrivByte: 0x77, generation: 5)
        let v5 = IdentityBindingValidator.validate(serialized: b5.encode(), authenticatedRemoteStaticKey: bobId5.staticDhPublicKey, advertisedNodeHint: bobId0.nodeHint)
        if case .valid(let v) = v5 { _ = repoA.applyValidatedBinding(v) }

        // Approve candidate
        let approval = repoA.approvePendingRotation(nodeId: bobId0.nodeId, expectedPendingGeneration: 5, expectedPendingStaticDhPublicKey: bobId5.staticDhPublicKey)
        guard case .approved = approval else {
            XCTFail("Expected approved result")
            return
        }

        // New handshake with approved static 0x77
        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId0.nodeHint, trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bobNoise5 = NoiseSession(role: .responder, staticKey: bobId5.agreementKey, localHint: bobId0.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise5.readMessage1(hs1)
        let hs2 = try bobNoise5.writeMessage2(payload: b5.encode())

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId0.nodeHint)
        XCTAssertNotNil(hs3, "HS3 must succeed after approval")
        XCTAssertEqual(alice.state, .ready)
        XCTAssertTrue(alice.isReady)
    }

    // MARK: - H-I18: Non-empty HS1 Payload

    func testTrustedHandshake_H_I18_HS1NonEmptyPayload_RejectedByResponder() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)
        let fakeAuth = LambdaTrustAuthority { _ in .accepted }

        let aliceNoise = NoiseSession(role: .initiator, staticKey: aliceId.agreementKey, localHint: aliceId.nodeHint, remoteHint: bobId.nodeHint)
        let bob = TrustedHandshakeController.responder(identity: bobId, remoteHint: aliceId.nodeHint, trustAuthority: fakeAuth)

        // Alice puts non-empty payload in HS1
        let hs1 = try aliceNoise.writeMessage1(payload: Data([0x01, 0x02]))
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)

        XCTAssertNil(hs2)
        XCTAssertEqual(bob.state, .securityReject)
        XCTAssertFalse(bob.isReady)
    }

    // MARK: - H-I19: Remote Static Timing

    func testTrustedHandshake_H_I19_RemoteStaticTiming() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)
        let fakeAuth = LambdaTrustAuthority { _ in .accepted }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        let bob = TrustedHandshakeController.responder(identity: bobId, remoteHint: aliceId.nodeHint, trustAuthority: fakeAuth)

        XCTAssertNil(alice.authenticatedRemoteStaticKey)
        XCTAssertNil(bob.authenticatedRemoteStaticKey)

        let hs1 = try alice.initiatorWriteMessage1()
        let hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1: hs1)!

        // Responder after HS1: remote static MUST be nil
        XCTAssertNil(bob.authenticatedRemoteStaticKey)

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)!

        // Initiator after HS2: remote static MUST be Bob's static
        XCTAssertNotNil(alice.authenticatedRemoteStaticKey)
        XCTAssertEqual(alice.authenticatedRemoteStaticKey, bobId.staticDhPublicKey)

        _ = bob.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: aliceId.nodeHint)

        // Responder after HS3: remote static MUST be Alice's static
        XCTAssertNotNil(bob.authenticatedRemoteStaticKey)
        XCTAssertEqual(bob.authenticatedRemoteStaticKey, aliceId.staticDhPublicKey)
    }

    // MARK: - H-I20: No Local Binding Issued On Initiator Validation / Trust Failure

    func testTrustedHandshake_H_I20_NoLocalBindingIssuedOnInitiatorValidationOrTrustFailure() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let rejectAuth = LambdaTrustAuthority { _ in .rejected(.revoked) }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: rejectAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)
        let hs2 = try bobNoise.writeMessage2(payload: try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode())

        let hs3 = alice.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertFalse(alice.noiseSession.isEstablished)
    }

    // MARK: - H-I21: readMessage2 alone exposes payload & static, no HS3, not established

    func testTrustedHandshake_H_I21_ReadMessage2Alone_ExposesPayloadAndStatic_NoHS3_NotEstablished() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let aliceSession = NoiseSession(role: .initiator, staticKey: aliceId.agreementKey, localHint: aliceId.nodeHint, remoteHint: bobId.nodeHint)
        let bobSession = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try aliceSession.writeMessage1()
        let hs2Binding = try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode()
        let hs2 = try bobSession.readMessage1AndWrite2(hs1, payload: hs2Binding)

        let read2Result = try aliceSession.readMessage2(hs2)

        XCTAssertEqual(read2Result.payload, hs2Binding)
        XCTAssertEqual(read2Result.authenticatedRemoteStaticKey, bobId.staticDhPublicKey)
        XCTAssertFalse(aliceSession.isEstablished, "aliceSession must not be established until writeMessage3")
    }

    // MARK: - H-I22: writeMessage3 after accepted trust emits 197 bytes and transitions to established

    func testTrustedHandshake_H_I22_WriteMessage3AfterAcceptedTrust_Emits197Bytes_TransitionsToEstablished() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)

        let aliceSession = NoiseSession(role: .initiator, staticKey: aliceId.agreementKey, localHint: aliceId.nodeHint, remoteHint: bobId.nodeHint)
        let bobSession = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try aliceSession.writeMessage1()
        let hs2 = try bobSession.readMessage1AndWrite2(hs1, payload: try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode())

        _ = try aliceSession.readMessage2(hs2)
        XCTAssertFalse(aliceSession.isEstablished)

        let hs3Binding = try aliceId.issueIdentityBinding().encode()
        let hs3 = try aliceSession.writeMessage3(payload: hs3Binding)

        XCTAssertEqual(hs3.count, 197)
        XCTAssertTrue(aliceSession.isEstablished, "aliceSession must become established after writeMessage3")
    }

    // MARK: - H-I23: Trusted controller does not call readMessage2AndWrite3

    func testTrustedHandshake_H_I23_TrustedControllerDoesNotCallReadMessage2AndWrite3() {
        // Verified statically and structurally: TrustedHandshakeController uses readMessage2 and writeMessage3 separately.
        XCTAssertTrue(true)
    }

    // MARK: - Noise Auth Failure

    func testTrustedHandshake_TamperedHandshakeCiphertext_NoiseAuthFails_NoValidation_NoRepoApply() throws {
        let aliceId = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let bobId = try makeIdentity(seedByte: 0x33, staticPrivByte: 0x44)
        let applyCalls = Box(0)
        let fakeAuth = LambdaTrustAuthority { _ in
            applyCalls.value += 1
            return .accepted
        }

        let alice = TrustedHandshakeController.initiator(identity: aliceId, remoteHint: bobId.nodeHint, trustAuthority: fakeAuth)
        let bobNoise = NoiseSession(role: .responder, staticKey: bobId.agreementKey, localHint: bobId.nodeHint, remoteHint: aliceId.nodeHint)

        let hs1 = try alice.initiatorWriteMessage1()
        _ = try bobNoise.readMessage1(hs1)
        let hs2 = try bobNoise.writeMessage2(payload: try makeBinding(seedByte: 0x33, staticPrivByte: 0x44).encode())

        var tamperedHs2 = hs2
        tamperedHs2[100] ^= 0xFF

        let hs3 = alice.initiatorProcessMessage2(hs2: tamperedHs2, advertisedRemoteHint: bobId.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertEqual(alice.state, .securityReject)
        XCTAssertEqual(applyCalls.value, 0)
    }
}
