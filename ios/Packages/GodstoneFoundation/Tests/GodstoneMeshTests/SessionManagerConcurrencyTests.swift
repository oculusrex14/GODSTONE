import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class SessionManagerConcurrencyTests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class RecordingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            .accepted
        }
    }

    func testRC01_ResolverLookupVsInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rc01_\(UUID().uuidString).db")
        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let gate = DefaultRuntimeLifecycleGate()
        let lookup = RuntimeGatedPeerIdentityLookupSource(delegate: repo, lifecycleGate: gate)
        let resolver = BoundRecipientKeyResolver(source: lookup)

        let signingKey = Curve25519.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let nodeId = Blake2s.hash(signingKey.publicKey.rawRepresentation, digestLength: 16)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: 0,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let sig = try signingKey.signature(for: preimage)
        let binding = IdentityBindingV1(
            generation: 0,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: sig
        )
        guard case .valid(let validated) = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: nodeId.prefix(4)
        ) else {
            XCTFail("Failed to create valid test binding")
            return
        }
        _ = repo.applyValidatedBinding(validated)

        // 1. Before invalidation: lookup returns verified non-null key
        XCTAssertNotNil(resolver.publicSigningKey(forNodeId: nodeId))

        // 2. Perform invalidation
        gate.invalidateForWipe()
        XCTAssertTrue(gate.isInvalidated)

        // 3. After invalidation boundary: concurrent readers all deterministically receive nil
        let count = 8
        let exp = expectation(description: "rc01 post-invalidation readers")
        exp.expectedFulfillmentCount = count

        for _ in 0..<count {
            DispatchQueue.global().async {
                for _ in 0..<50 {
                    let key = resolver.publicSigningKey(forNodeId: nodeId)
                    XCTAssertNil(key)
                }
                exp.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertNil(resolver.publicSigningKey(forNodeId: nodeId))
    }

    func testRC02_ReadySealVsInvalidation() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let gate = DefaultRuntimeLifecycleGate()
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority(), lifecycleGate: gate)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        // 1. Establish full cryptographic handshake to READY state
        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        let readyB = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(readyB)
        XCTAssertTrue(smA.isReady(peerB))

        // 2. Linearization test: in-flight seal holds read lock; invalidation write lock must wait
        let enteredReadAuthority = DispatchSemaphore(value: 0)
        let releaseThreadA = DispatchSemaphore(value: 0)
        let threadAFinished = expectation(description: "Thread A seal finished")
        let invalidationFinished = expectation(description: "Invalidation finished")
        var sealResult: Data?

        smA.testOperationHook = { op in
            if op == "seal" {
                enteredReadAuthority.signal()
                _ = releaseThreadA.wait(timeout: .now() + 5.0)
            }
        }

        // Thread A: enters seal under read lock and pauses
        DispatchQueue.global().async {
            sealResult = smA.seal(peerB, Data("linearized payload".utf8))
            threadAFinished.fulfill()
        }

        // Wait for Thread A to enter read authority
        _ = enteredReadAuthority.wait(timeout: .now() + 5.0)

        // Thread B: calls invalidateForWipe() which requires exclusive write lock
        DispatchQueue.global().async {
            smA.invalidateForWipe()
            invalidationFinished.fulfill()
        }

        // Give Thread B time to attempt write lock acquisition
        Thread.sleep(forTimeInterval: 0.01)

        // Release Thread A
        releaseThreadA.signal()

        // Wait for both operations to complete
        wait(for: [threadAFinished, invalidationFinished], timeout: 5.0)

        // Thread A succeeded
        XCTAssertNotNil(sealResult)

        // Invalidation completed, all subsequent operations are denied
        XCTAssertTrue(smA.isInvalidated)
        XCTAssertFalse(smA.isActive)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("after wipe".utf8)))
        XCTAssertNil(smA.open(peerB, Data("after wipe".utf8)))
        XCTAssertNil(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
    }

    func testRC03_HandshakeProcessingVsInvalidation() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        // 1. Generate real valid handshake messages
        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))

        let enteredHsReadAuthority = DispatchSemaphore(value: 0)
        let releaseHsThread = DispatchSemaphore(value: 0)
        let hsThreadFinished = expectation(description: "HS thread finished")
        let invalidationFinished = expectation(description: "Invalidation finished")
        var hs3Result: Data?

        smA.testOperationHook = { op in
            if op == "initiatorProcessHs2" {
                enteredHsReadAuthority.signal()
                _ = releaseHsThread.wait(timeout: .now() + 5.0)
            }
        }

        // Thread A: processes valid HS2 and pauses in read lock
        DispatchQueue.global().async {
            hs3Result = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
            hsThreadFinished.fulfill()
        }

        // Wait for Thread A to enter read authority
        _ = enteredHsReadAuthority.wait(timeout: .now() + 5.0)

        // Thread B: calls invalidateForWipe() which requires exclusive write lock
        DispatchQueue.global().async {
            smA.invalidateForWipe()
            invalidationFinished.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.01)

        // Release Thread A
        releaseHsThread.signal()

        // Wait for both operations to complete
        wait(for: [hsThreadFinished, invalidationFinished], timeout: 5.0)

        // After invalidation completes: no controller survives, no READY state, fresh operations denied
        XCTAssertTrue(smA.isInvalidated)
        XCTAssertFalse(smA.isActive)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        XCTAssertNil(smA.seal(peerB, Data("test".utf8)))
    }
}
