import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class WipeLifecycleTests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class InMemoryJournal: WipeJournal, @unchecked Sendable {
        var state: WipeState = .idle
        func read() -> WipeState { state }
        func write(_ s: WipeState) { state = s }
        func clear() { state = .idle }
    }

    private final class RecordingArtifacts: WipeArtifacts, @unchecked Sendable {
        let crashBefore: String?
        var calls: [String] = []
        private var crashed = Set<String>()

        init(crashBefore: String? = nil) {
            self.crashBefore = crashBefore
        }

        private func step(_ name: String, block: () throws -> Void) throws {
            if crashBefore == name && !crashed.contains(name) {
                crashed.insert(name)
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated crash at \(name)"])
            }
            try block()
            calls.append(name)
        }

        func eraseKeys() throws { try step("eraseKeys") {} }
        func deleteArtifacts() throws { try step("deleteArtifacts") {} }
        func regenerateIdentity() throws { try step("regenerateIdentity") {} }
    }

    func testWipe_CleanIdle_NoOp() throws {
        let journal = InMemoryJournal()
        let artifacts = RecordingArtifacts()
        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertEqual(artifacts.calls.count, 0)
        XCTAssertEqual(journal.state, .idle)
    }

    func testWipe_FullExecution_ErasesKeysAndDeletesArtifactsAndRegeneratesIdentity() throws {
        let journal = InMemoryJournal()
        let artifacts = RecordingArtifacts()
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)
        try wipe.begin()

        XCTAssertEqual(artifacts.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
        XCTAssertEqual(journal.state, .idle)
    }

    func testWipe_InvalidatesRuntimeHandles_BeforeKeyErasure() throws {
        var events: [String] = []

        final class InvalidatorMock: RuntimeInvalidator, @unchecked Sendable {
            let onInvalidate: () -> Void
            init(onInvalidate: @escaping () -> Void) { self.onInvalidate = onInvalidate }
            func invalidateForWipe() { onInvalidate() }
        }

        final class DelegateMock: WipeArtifacts, @unchecked Sendable {
            let onCall: (String) -> Void
            init(onCall: @escaping (String) -> Void) { self.onCall = onCall }
            func eraseKeys() throws { onCall("eraseKeys") }
            func deleteArtifacts() throws { onCall("deleteArtifacts") }
            func regenerateIdentity() throws { onCall("regenerateIdentity") }
        }

        let invMock = InvalidatorMock { events.append("invalidated") }
        let delMock = DelegateMock { name in events.append(name) }
        let awareArtifacts = RuntimeAwareWipeArtifacts(invalidator: invMock, delegate: delMock)
        let journal = InMemoryJournal()
        let wipe = PanicWipe(journal: journal, artifacts: awareArtifacts)
        try wipe.begin()

        XCTAssertEqual(events, ["invalidated", "eraseKeys", "deleteArtifacts", "regenerateIdentity"])
    }

    func testWipe_SessionManagerInvalidated_RefusesAllOperations() throws {
        let identity = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let gate = DefaultRuntimeLifecycleGate()
        final class DummyTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
            func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult { .storageFailure }
        }
        let sm = SessionManager(identity: identity, trustAuthority: DummyTrustAuthority(), lifecycleGate: gate)
        let peer = UUID()
        let hs1 = sm.initiatorStart(peer, remoteHint: Data(count: 4))
        XCTAssertNotNil(hs1)

        gate.invalidateForWipe()
        XCTAssertTrue(sm.isInvalidated)
        XCTAssertFalse(sm.isActive)
        XCTAssertFalse(sm.isReady(peer))
        XCTAssertNil(sm.seal(peer, Data("data".utf8)))
        XCTAssertNil(sm.open(peer, Data("data".utf8)))
        XCTAssertNil(sm.initiatorStart(UUID(), remoteHint: Data(count: 4)))
    }

    func testWipe_ResolverReturnsNull_AfterInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wipe_res_\(UUID().uuidString).db")
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

        gate.invalidateForWipe()
        XCTAssertNil(resolver.publicSigningKey(forNodeId: nodeId))
    }

    func testWipe_TrustAuthorityReturnsStorageFailure_AfterInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wipe_trust_\(UUID().uuidString).db")
        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let gate = DefaultRuntimeLifecycleGate()
        let trustAuthority = RuntimeGatedPeerBindingTrustAuthority(
            delegate: RepositoryPeerBindingTrustAuthority(repository: repo),
            lifecycleGate: gate
        )

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

        gate.invalidateForWipe()
        let res = trustAuthority.applyValidatedBinding(validated)
        guard case .storageFailure = res else {
            XCTFail("Expected storageFailure")
            return
        }
    }

    func testWipe_PeerStoreClosed_AfterInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wipe_peer_store_\(UUID().uuidString).db")
        let store = try SqlitePeerIdentityStore(url: url)
        let gate = DefaultRuntimeLifecycleGate()
        let invalidator = MeshRuntimeInvalidator(lifecycleGate: gate, peerStore: store)

        invalidator.invalidateForWipe()
        XCTAssertTrue(gate.isInvalidated)
    }

    func testWipe_MessageStoreClosed_AfterInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wipe_msg_store_\(UUID().uuidString).db")
        let store = SqliteMessageStore(url: url, maxBytes: 4096)
        let gate = DefaultRuntimeLifecycleGate()
        let invalidator = MeshRuntimeInvalidator(lifecycleGate: gate, messageStore: store)

        invalidator.invalidateForWipe()
        XCTAssertTrue(gate.isInvalidated)
    }

    func testWipe_CrashAtRequested_ResumesWipeAndCompletes() throws {
        let journal = InMemoryJournal()
        let artifacts = RecordingArtifacts(crashBefore: "eraseKeys")
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)
        XCTAssertThrowsError(try wipe.begin())

        XCTAssertEqual(journal.state, .requested)
        XCTAssertEqual(artifacts.calls.count, 0)

        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertEqual(artifacts.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
        XCTAssertEqual(journal.state, .idle)
    }

    func testWipe_CrashAtKeyErased_ResumesWipeAndCompletes() throws {
        let journal = InMemoryJournal()
        let artifacts = RecordingArtifacts(crashBefore: "deleteArtifacts")
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)
        XCTAssertThrowsError(try wipe.begin())

        XCTAssertEqual(journal.state, .keyErased)
        XCTAssertEqual(artifacts.calls, ["eraseKeys"])

        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertEqual(artifacts.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
        XCTAssertEqual(journal.state, .idle)
    }

    func testWipe_CrashAtArtifactsDeleted_ResumesWipeAndCompletes() throws {
        let journal = InMemoryJournal()
        let artifacts = RecordingArtifacts(crashBefore: "regenerateIdentity")
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)
        XCTAssertThrowsError(try wipe.begin())

        XCTAssertEqual(journal.state, .artifactsDeleted)
        XCTAssertEqual(artifacts.calls, ["eraseKeys", "deleteArtifacts"])

        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertEqual(artifacts.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
        XCTAssertEqual(journal.state, .idle)
    }

    func testWipe_CrashAtNewIdentity_ResumesWipeAndCompletes() throws {
        let journal = InMemoryJournal()
        journal.write(.newIdentity)
        let artifacts = RecordingArtifacts()

        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertEqual(artifacts.calls.count, 0)
        XCTAssertEqual(journal.state, .idle)
    }

    func testWipe_OldRuntimeHandleRemainsInvalid_AfterWipeCompletes() throws {
        let gate = DefaultRuntimeLifecycleGate()
        let invalidator = MeshRuntimeInvalidator(lifecycleGate: gate)
        let delegate = RecordingArtifacts()
        let awareArtifacts = RuntimeAwareWipeArtifacts(invalidator: invalidator, delegate: delegate)
        let journal = InMemoryJournal()
        let wipe = PanicWipe(journal: journal, artifacts: awareArtifacts)
        try wipe.begin()

        XCTAssertTrue(gate.isInvalidated)
        XCTAssertFalse(gate.isActive)
    }

    func testWipe_FreshRuntimeInstance_AfterWipeWorksNormally() throws {
        let journal = InMemoryJournal()
        let artifacts = RecordingArtifacts()
        try PanicWipe(journal: journal, artifacts: artifacts).begin()

        let freshGate = DefaultRuntimeLifecycleGate()
        XCTAssertTrue(freshGate.isActive)
        XCTAssertFalse(freshGate.isInvalidated)
    }

    func testWipe_InvalidationException_PreventsKeyErasure() throws {
        final class FailingInvalidator: RuntimeInvalidator, @unchecked Sendable {
            func invalidateForWipe() throws {
                throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "Invalidator failure"])
            }
        }
        let delegateArtifacts = RecordingArtifacts()
        let awareArtifacts = RuntimeAwareWipeArtifacts(invalidator: FailingInvalidator(), delegate: delegateArtifacts)
        let journal = InMemoryJournal()
        let wipe = PanicWipe(journal: journal, artifacts: awareArtifacts)

        XCTAssertThrowsError(try wipe.begin())
        XCTAssertEqual(delegateArtifacts.calls.count, 0)
    }
}
