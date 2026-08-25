import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class SessionManagerTests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private func randomPeerId() -> UUID {
        UUID()
    }

    private final class RecordingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        var resultToReturn: PeerTrustApplyResult
        var applyCount = 0
        var lastBinding: ValidatedPeerBinding?
        private let lock = NSLock()

        init(resultToReturn: PeerTrustApplyResult = .accepted) {
            self.resultToReturn = resultToReturn
        }

        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            lock.lock()
            defer { lock.unlock() }
            applyCount += 1
            lastBinding = binding
            return resultToReturn
        }
    }

    func testSessionManager_InitiatorStart_Returns32ByteHs1() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let peerB = UUID()

        let hs1 = smA.initiatorStart(peerB, remoteHint: identityB.nodeHint)
        XCTAssertNotNil(hs1)
        XCTAssertEqual(hs1?.count, 32)
        XCTAssertFalse(smA.isReady(peerB))
    }

    func testSessionManager_ResponderProcessHs1_Returns229ByteHs2() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1)

        XCTAssertNotNil(hs2)
        XCTAssertEqual(hs2?.count, 229)
        XCTAssertFalse(smB.isReady(peerA))
    }

    func testSessionManager_InitiatorProcessHs2_Emits197ByteHs3_AndReachesReady() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority()
        let trustB = RecordingTrustAuthority()
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: trustB)

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))

        let hs3 = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertNotNil(hs3)
        XCTAssertEqual(hs3?.count, 197)
        XCTAssertTrue(smA.isReady(peerB))
        XCTAssertEqual(trustA.applyCount, 1)
    }

    func testSessionManager_ResponderProcessHs3_ReachesReady() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority()
        let trustB = RecordingTrustAuthority()
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: trustB)

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))

        let ready = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(ready)
        XCTAssertTrue(smB.isReady(peerA))
        XCTAssertEqual(trustB.applyCount, 1)
    }

    func testSessionManager_SealAndOpen_RoundTripSucceedsOnlyWhenReady() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        let okB = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(okB)

        let payload = Data("Hello secure mesh runtime on iOS".utf8)
        let cipherAtoB = try XCTUnwrap(smA.seal(peerB, payload))

        let plainB = try XCTUnwrap(smB.open(peerA, cipherAtoB))
        XCTAssertEqual(plainB, payload)

        let reply = Data("Reply from B on iOS".utf8)
        let cipherBtoA = try XCTUnwrap(smB.seal(peerA, reply))

        let plainA = try XCTUnwrap(smA.open(peerB, cipherBtoA))
        XCTAssertEqual(plainA, reply)
    }

    func testSessionManager_SealBeforeReady_ReturnsNull() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let peerB = randomPeerId()

        XCTAssertNil(smA.seal(peerB, Data("cleartext".utf8)))
    }

    func testSessionManager_OpenBeforeReady_ReturnsNull() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let peerB = randomPeerId()

        XCTAssertNil(smA.open(peerB, Data("ciphertext".utf8)))
    }

    func testSessionManager_QuarantinedHandshake_NeverReachesReady_SealFails() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority(resultToReturn: .keyChangedQuarantined)
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))

        let hs3 = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
    }

    func testSessionManager_RejectedHandshake_NeverReachesReady_SealFails() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority(resultToReturn: .rejected(.rollback))
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))

        let hs3 = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
    }

    func testSessionManager_DropPeer_CleansUpController_SealFails() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        _ = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)

        XCTAssertTrue(smA.isReady(peerB))
        smA.drop(peerB)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
    }

    func testSessionManager_DestroyAll_DestroysAllControllers() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        _ = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)

        XCTAssertTrue(smA.isReady(peerB))
        smA.destroyAll()
        XCTAssertFalse(smA.isReady(peerB))
    }

    func testSessionManager_InvalidateForWipe_PermanentlyRefusesNewAndExistingSessions() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let gate = DefaultRuntimeLifecycleGate()
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority(), lifecycleGate: gate)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        _ = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertTrue(smA.isReady(peerB))

        smA.invalidateForWipe()
        XCTAssertTrue(smA.isInvalidated)
        XCTAssertFalse(smA.isActive)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
        XCTAssertNil(smA.open(peerB, Data("data".utf8)))

        // Refuses new sessions
        XCTAssertNil(smA.initiatorStart(randomPeerId(), remoteHint: Data(count: 4)))
        XCTAssertNil(smA.responderProcessHs1(randomPeerId(), remoteHint: Data(count: 4), hs1: Data(count: 32)))
    }
}
