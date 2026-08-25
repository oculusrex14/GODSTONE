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
        XCTAssertEqual(journal.state, .idle)
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
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr05_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        let runtime1 = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )
        let oldNodeId = runtime1.identity.nodeId

        try runtime1.beginPanicWipe(keychain: keychain)
        XCTAssertTrue(runtime1.lifecycleGate.isInvalidated)
        XCTAssertFalse(runtime1.sessionManager.isActive)

        // Construct runtime2 with the SAME store URLs
        let runtime2 = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        XCTAssertNotEqual(oldNodeId, runtime2.identity.nodeId)
        XCTAssertEqual(runtime2.identity.bindingGeneration, 0)
        XCTAssertTrue(runtime2.lifecycleGate.isActive)
        XCTAssertTrue(runtime1.lifecycleGate.isInvalidated)
    }

    func testSR06_FreshPeerStore_ContainsNoPriorPeerRecords() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr06_msg_\(UUID().uuidString).db")
        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sr06_peer_\(UUID().uuidString).db")
        let journal = InMemoryJournal()
        let keychain = InMemoryKeychain()

        // 1. Create runtime1 using messageStoreUrl and peerStoreUrl
        let runtime1 = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        // 2. Construct a VALID peer binding and apply it through runtime1.peerRepository
        let signingKey = Curve25519.Signing.PrivateKey()
        let agreementKey = Curve25519.KeyAgreement.PrivateKey()
        let peerNodeId = Blake2s.hash(signingKey.publicKey.rawRepresentation, digestLength: 16)
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
            advertisedNodeHint: peerNodeId.prefix(4)
        ) else {
            XCTFail("Failed to create valid test binding")
            return
        }

        let applyRes = runtime1.peerRepository.applyValidatedBinding(validated)
        XCTAssertTrue(applyRes == .firstSeenPinned || applyRes == .accepted)

        // 3. Prove lookup is Verified before wipe
        let lookup1 = runtime1.peerRepository.lookup(peerNodeId)
        guard case .verified = lookup1 else {
            XCTFail("Expected peer to be verified before wipe")
            return
        }
        XCTAssertNotNil(try runtime1.peerIdentityStore.readRaw(peerNodeId))
        XCTAssertNotNil(runtime1.recipientKeyResolver.publicSigningKey(forNodeId: peerNodeId))

        // 4. Begin active panic wipe
        try runtime1.beginPanicWipe(keychain: keychain)
        XCTAssertTrue(runtime1.lifecycleGate.isInvalidated)

        // 5. Create runtime2 using the SAME messageStoreUrl and SAME peerStoreUrl
        let runtime2 = try MeshRuntime.create(
            messageStoreUrl: msgUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain
        )

        // 6. Prove old peer is completely absent: raw row absent, lookup NotFound, resolver nil
        let raw2 = try runtime2.peerIdentityStore.readRaw(peerNodeId)
        XCTAssertNil(raw2)

        let lookup2 = runtime2.peerRepository.lookup(peerNodeId)
        guard case .notFound = lookup2 else {
            XCTFail("Expected peer to be notFound in fresh runtime store")
            return
        }

        let key2 = runtime2.recipientKeyResolver.publicSigningKey(forNodeId: peerNodeId)
        XCTAssertNil(key2)
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
