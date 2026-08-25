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

    func testConcurrency_SimultaneousSealAndInvalidation_FailsSafely() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let gate = DefaultRuntimeLifecycleGate()
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority(), lifecycleGate: gate)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        _ = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))

        let count = 16
        let exp = expectation(description: "seal and invalidation")
        exp.expectedFulfillmentCount = count

        for i in 0..<count {
            DispatchQueue.global().async {
                if i == 0 {
                    smA.invalidateForWipe()
                } else {
                    _ = smA.seal(peerB, Data("test payload".utf8))
                }
                exp.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertTrue(smA.isInvalidated)
        XCTAssertFalse(smA.isReady(peerB))
    }

    func testConcurrency_ConcurrentHandshakeCompletions_SerializedPerPeer() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let hs1 = smA.initiatorStart(peerB, remoteHint: identityB.nodeHint)
        XCTAssertNotNil(hs1)

        let count = 4
        let exp = expectation(description: "bogus hs2")
        exp.expectedFulfillmentCount = count

        for _ in 0..<count {
            DispatchQueue.global().async {
                _ = smA.initiatorProcessHs2(peerB, hs2: Data(count: 229), advertisedRemoteHint: identityB.nodeHint)
                exp.fulfill()
            }
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertFalse(smA.isReady(peerB))
    }
}
