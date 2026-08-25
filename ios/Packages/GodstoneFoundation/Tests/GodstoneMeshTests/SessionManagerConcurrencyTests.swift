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
            fatalError()
        }
        _ = repo.applyValidatedBinding(validated)
        XCTAssertNotNil(resolver.publicSigningKey(forNodeId: nodeId))

        let count = 8
        let exp = expectation(description: "rc01 concurrency")
        exp.expectedFulfillmentCount = count + 1

        for _ in 0..<count {
            DispatchQueue.global().async {
                for _ in 0..<50 {
                    _ = resolver.publicSigningKey(forNodeId: nodeId)
                }
                exp.fulfill()
            }
        }

        DispatchQueue.global().async {
            gate.invalidateForWipe()
            exp.fulfill()
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertTrue(gate.isInvalidated)
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

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        let readyB = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(readyB)
        XCTAssertTrue(smA.isReady(peerB))

        let count = 16
        let exp = expectation(description: "seal and invalidation")
        exp.expectedFulfillmentCount = count + 1

        for i in 0..<count {
            DispatchQueue.global().async {
                for j in 0..<50 {
                    _ = smA.seal(peerB, Data("payload \(i)-\(j)".utf8))
                }
                exp.fulfill()
            }
        }

        DispatchQueue.global().async {
            smA.invalidateForWipe()
            exp.fulfill()
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertTrue(smA.isInvalidated)
        XCTAssertFalse(smA.isActive)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("after wipe".utf8)))
        XCTAssertNil(smA.open(peerB, Data("after wipe".utf8)))
    }

    func testRC03_HandshakeProcessingVsInvalidation() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let hs1 = smA.initiatorStart(peerB, remoteHint: identityB.nodeHint)
        XCTAssertNotNil(hs1)

        let count = 4
        let exp = expectation(description: "bogus hs2 and wipe")
        exp.expectedFulfillmentCount = count + 1

        for _ in 0..<count {
            DispatchQueue.global().async {
                _ = smA.initiatorProcessHs2(peerB, hs2: Data(count: 229), advertisedRemoteHint: identityB.nodeHint)
                exp.fulfill()
            }
        }

        DispatchQueue.global().async {
            smA.invalidateForWipe()
            exp.fulfill()
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertTrue(smA.isInvalidated)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
    }

    func testConcurrency_SimultaneousInitiatorAndResponder_DoesNotCorrupt() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let count = 8
        let exp = expectation(description: "concurrent initiatorStart")
        exp.expectedFulfillmentCount = count

        var successes = 0
        let lock = NSLock()

        for _ in 0..<count {
            DispatchQueue.global().async {
                let hs1 = smA.initiatorStart(peerB, remoteHint: identityB.nodeHint)
                if hs1 != nil {
                    lock.lock()
                    successes += 1
                    lock.unlock()
                }
                exp.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertGreaterThanOrEqual(successes, 1)
        XCTAssertLessThanOrEqual(successes, count)
    }
}
