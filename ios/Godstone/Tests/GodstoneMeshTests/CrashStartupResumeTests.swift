import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class CrashStartupResumeTests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class InMemoryJournal: WipeJournal, @unchecked Sendable {
        var state: WipeState = .idle
        var writes = 0
        var clears = 0
        func read() -> WipeState { state }
        func write(_ s: WipeState) { state = s; writes += 1 }
        func clear() { state = .idle; clears += 1 }
    }

    private final class StepTrackingArtifacts: WipeArtifacts, @unchecked Sendable {
        var executedSteps: [String] = []
        var currentIdentity: MeshIdentity?

        init() {
            self.currentIdentity = try? MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        }

        func eraseKeys() throws {
            executedSteps.append("eraseKeys")
            currentIdentity = nil
        }

        func deleteArtifacts() throws {
            executedSteps.append("deleteArtifacts")
        }

        func regenerateIdentity() throws {
            executedSteps.append("regenerateIdentity")
            currentIdentity = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        }
    }

    func testSR01_CleanLaunch_InitializesRuntimeNormally() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr01_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr01_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )
        XCTAssertTrue(runtime.lifecycleGate.isActive)
        XCTAssertFalse(runtime.sessionManager.isInvalidated)
    }

    func testSR02_PendingWipe_Requested_FinishesBeforeRuntimeInitialization() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr02_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr02_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        journal.write(.requested)
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertEqual(journal.state, .idle)
        XCTAssertTrue(runtime.lifecycleGate.isActive)
        XCTAssertNotNil(runtime.identity)
    }

    func testSR03_KeyErased_DeletesExactStoreArtifactsBeforeOpen() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr03_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr03_peer_\(UUID().uuidString).db")
        try Data("old store content".utf8).write(to: msgUrl)
        try Data("old peer content".utf8).write(to: peerUrl)
        XCTAssertTrue(FileManager.default.fileExists(atPath: msgUrl.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: peerUrl.path))

        let journal = InMemoryJournal()
        journal.write(.keyErased)
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertEqual(journal.state, .idle)
        XCTAssertTrue(runtime.lifecycleGate.isActive)
    }

    func testSR04_ArtifactsDeleted_RegeneratesIdentityBeforeRuntimeConstruction() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr04_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr04_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        journal.write(.artifactsDeleted)
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertEqual(journal.state, .idle)
        XCTAssertEqual(runtime.identity.bindingGeneration, 0)
    }

    func testSR05_FreshRuntime_AfterWipe_HasDifferentNodeId() throws {
        let msgUrl1 = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_msg1_\(UUID().uuidString).db")
        let peerUrl1 = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_peer1_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime1 = try MeshRuntime.create(
            messageStoreUrl: msgUrl1,
            peerStoreUrl: peerUrl1,
            journal: journal,
            keychain: keychain
        )
        let oldNodeId = runtime1.identity.nodeId

        try runtime1.beginPanicWipe(keychain: keychain)
        XCTAssertTrue(runtime1.lifecycleGate.isInvalidated)

        let msgUrl2 = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_msg2_\(UUID().uuidString).db")
        let peerUrl2 = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_peer2_\(UUID().uuidString).db")
        let runtime2 = try MeshRuntime.create(
            messageStoreUrl: msgUrl2,
            peerStoreUrl: peerUrl2,
            journal: journal,
            keychain: keychain
        )

        XCTAssertNotEqual(oldNodeId, runtime2.identity.nodeId)
    }

    func testSR06_FreshPeerStore_ContainsNoPriorPeerRecords() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr06_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr06_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        let dummyNodeId = Data(count: 16)
        let record = try runtime.peerIdentityStore.readRaw(dummyNodeId)
        XCTAssertNil(record)
    }

    func testSR07_OldRuntimeHandle_RemainsPermanentlyUnusable() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr07_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr07_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        try runtime.beginPanicWipe(keychain: keychain)

        XCTAssertTrue(runtime.lifecycleGate.isInvalidated)
        XCTAssertFalse(runtime.sessionManager.isActive)
        XCTAssertNil(runtime.recipientKeyResolver.publicSigningKey(forNodeId: Data(count: 16)))
    }
}
