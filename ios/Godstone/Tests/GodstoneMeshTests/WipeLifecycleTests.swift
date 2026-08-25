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

    private func makeTestFrame(_ msgIdHex: String = "0102030405060708090a0b0c0d0e0f10") -> FrameV2 {
        let msgId = Data((0..<16).map { UInt8($0) })
        return FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(count: 4),
            ttl: 3,
            hopCount: 0,
            flags: 0,
            payload: Data("payload".utf8)
        )
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

    func testWipe_DeterministicOrdering_GateSessionsPeerMessageKeys() throws {
        var order: [String] = []

        let gate = DefaultRuntimeLifecycleGate()
        let identity = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        final class DummyTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
            func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult { .storageFailure }
        }
        let sm = SessionManager(identity: identity, trustAuthority: DummyTrustAuthority(), lifecycleGate: gate)

        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("order_peer_\(UUID().uuidString).db")
        let peerStore = try SqlitePeerIdentityStore(url: peerUrl)
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("order_msg_\(UUID().uuidString).db")
        let msgStore = SqliteMessageStore(url: msgUrl, maxBytes: 4096)

        final class OrderInvalidator: RuntimeInvalidator, @unchecked Sendable {
            let gate: DefaultRuntimeLifecycleGate
            let sm: SessionManager
            let peerStore: SqlitePeerIdentityStore
            let msgStore: SqliteMessageStore
            let onStep: (String) -> Void

            init(gate: DefaultRuntimeLifecycleGate, sm: SessionManager, peerStore: SqlitePeerIdentityStore, msgStore: SqliteMessageStore, onStep: @escaping (String) -> Void) {
                self.gate = gate
                self.sm = sm
                self.peerStore = peerStore
                self.msgStore = msgStore
                self.onStep = onStep
            }

            func invalidateForWipe() {
                onStep("gateInvalidated")
                gate.invalidateForWipe()
                onStep("sessionsInvalidated")
                sm.invalidateForWipe()
                onStep("peerStoreClosed")
                peerStore.close()
                onStep("messageStoreClosed")
                msgStore.close()
            }
        }

        final class OrderDelegate: WipeArtifacts, @unchecked Sendable {
            let onStep: (String) -> Void
            init(onStep: @escaping (String) -> Void) { self.onStep = onStep }
            func eraseKeys() throws { onStep("platformEraseKeys") }
            func deleteArtifacts() throws { onStep("deleteArtifacts") }
            func regenerateIdentity() throws { onStep("regenerateIdentity") }
        }

        let invalidator = OrderInvalidator(gate: gate, sm: sm, peerStore: peerStore, msgStore: msgStore) { order.append($0) }
        let delegate = OrderDelegate { order.append($0) }
        let wipe = PanicWipe(journal: InMemoryJournal(), artifacts: RuntimeAwareWipeArtifacts(invalidator: invalidator, delegate: delegate))
        try wipe.begin()

        XCTAssertEqual(
            order,
            [
                "gateInvalidated",
                "sessionsInvalidated",
                "peerStoreClosed",
                "messageStoreClosed",
                "platformEraseKeys",
                "deleteArtifacts",
                "regenerateIdentity"
            ]
        )
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

    func testWipe_W04_PeerStoreClosed_AfterInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wipe_peer_store_\(UUID().uuidString).db")
        let store = try SqlitePeerIdentityStore(url: url)
        let gate = DefaultRuntimeLifecycleGate()

        // 1. Verify store functions normally before invalidation
        let nodeId = Data(count: 16)
        let record = try store.readRaw(nodeId)
        XCTAssertNil(record)

        // 2. Invalidate via MeshRuntimeInvalidator
        let invalidator = MeshRuntimeInvalidator(lifecycleGate: gate, peerStore: store)
        invalidator.invalidateForWipe()
        XCTAssertTrue(gate.isInvalidated)

        // 3. Post-invalidation: operations fail closed because handle is nil
        XCTAssertThrowsError(try store.readRaw(nodeId))
    }

    func testWipe_W05_MessageStoreClosed_AfterInvalidation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wipe_msg_store_\(UUID().uuidString).db")
        let store = SqliteMessageStore(url: url, maxBytes: 4096)
        let gate = DefaultRuntimeLifecycleGate()

        // 1. Verify store functions normally before invalidation
        let frame = makeTestFrame()
        let res1 = store.persist(frame, receivedFrom: Data(count: 16))
        XCTAssertEqual(res1, .heldNew)

        // 2. Invalidate via MeshRuntimeInvalidator
        let invalidator = MeshRuntimeInvalidator(lifecycleGate: gate, messageStore: store)
        invalidator.invalidateForWipe()
        XCTAssertTrue(gate.isInvalidated)

        // 3. Post-invalidation: operations return .failedStorage
        let res2 = store.persist(frame, receivedFrom: Data(count: 16))
        XCTAssertEqual(res2, .failedStorage)
    }

    func testWipe_W06_InvalidatorFailure_PreventsKeyErasure_PreservesRequestedState() throws {
        final class FailingInvalidator: RuntimeInvalidator, @unchecked Sendable {
            let gate: DefaultRuntimeLifecycleGate
            init(gate: DefaultRuntimeLifecycleGate) { self.gate = gate }
            func invalidateForWipe() throws {
                gate.invalidateForWipe()
                throw NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "Database close failed"])
            }
        }

        let gate = DefaultRuntimeLifecycleGate()
        let delegate = RecordingArtifacts()
        let aware = RuntimeAwareWipeArtifacts(invalidator: FailingInvalidator(gate: gate), delegate: delegate)
        let journal = InMemoryJournal()
        let wipe = PanicWipe(journal: journal, artifacts: aware)

        XCTAssertThrowsError(try wipe.begin())

        // Platform eraseKeys MUST NOT have been called
        XCTAssertEqual(delegate.calls.count, 0)
        // Journal MUST remain in requested state
        XCTAssertEqual(journal.state, .requested)
        // Old runtime gate remains permanently invalidated
        XCTAssertTrue(gate.isInvalidated)
        XCTAssertFalse(gate.isActive)
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

    func testWipe_W15_RealDatabaseArtifactsAndSidecars_DeletedAfterClosure() throws {
        let msgUrl = FileManager.default.temporaryDirectory.appendingPathComponent("msg_w15_\(UUID().uuidString).db")
        let msgWal = URL(fileURLWithPath: msgUrl.path + "-wal")
        let msgShm = URL(fileURLWithPath: msgUrl.path + "-shm")
        let msgJournal = URL(fileURLWithPath: msgUrl.path + "-journal")
        try Data("wal".utf8).write(to: msgWal)
        try Data("shm".utf8).write(to: msgShm)
        try Data("journal".utf8).write(to: msgJournal)

        let peerUrl = FileManager.default.temporaryDirectory.appendingPathComponent("peer_w15_\(UUID().uuidString).db")
        let peerWal = URL(fileURLWithPath: peerUrl.path + "-wal")
        let peerShm = URL(fileURLWithPath: peerUrl.path + "-shm")
        let peerJournal = URL(fileURLWithPath: peerUrl.path + "-journal")
        try Data("wal".utf8).write(to: peerWal)
        try Data("shm".utf8).write(to: peerShm)
        try Data("journal".utf8).write(to: peerJournal)

        let allUrls = [msgUrl, msgWal, msgShm, msgJournal, peerUrl, peerWal, peerShm, peerJournal]

        let msgStore = SqliteMessageStore(url: msgUrl, maxBytes: 4096)
        let peerStore = try SqlitePeerIdentityStore(url: peerUrl)
        let gate = DefaultRuntimeLifecycleGate()

        // Verify stores work normally before invalidation
        let frame = makeTestFrame()
        let res1 = msgStore.persist(frame, receivedFrom: Data(count: 16))
        XCTAssertEqual(res1, .heldNew)
        XCTAssertNil(try peerStore.readRaw(Data(count: 16)))

        let invalidator = MeshRuntimeInvalidator(
            lifecycleGate: gate,
            peerStore: peerStore,
            messageStore: msgStore
        )

        final class FileDeleteDelegate: WipeArtifacts, @unchecked Sendable {
            let urls: [URL]
            init(urls: [URL]) {
                self.urls = urls
            }
            func eraseKeys() throws {}
            func deleteArtifacts() throws {
                for u in urls {
                    try? FileManager.default.removeItem(at: u)
                }
            }
            func regenerateIdentity() throws {}
        }

        let delegate = FileDeleteDelegate(urls: allUrls)
        let aware = RuntimeAwareWipeArtifacts(invalidator: invalidator, delegate: delegate)
        let journal = InMemoryJournal()
        try PanicWipe(journal: journal, artifacts: aware).begin()

        // Gate invalidated and stores closed
        XCTAssertTrue(gate.isInvalidated)
        let res2 = msgStore.persist(frame, receivedFrom: Data(count: 16))
        XCTAssertEqual(res2, .failedStorage)
        XCTAssertThrowsError(try peerStore.readRaw(Data(count: 16)))

        // All physical DB artifacts and sidecars are deleted
        for u in allUrls {
            XCTAssertFalse(FileManager.default.fileExists(atPath: u.path), "Expected \(u.path) to be deleted")
        }
    }
}
