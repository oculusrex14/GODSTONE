import XCTest
import SQLite3
import CryptoKit
@testable import GodstoneMesh

final class PeerIdentityRepositoryTests: XCTestCase {

    private let seedA = Data(repeating: 0x11, count: 32)
    private let seedB = Data(repeating: 0x22, count: 32)

    private let staticPrivA = Data(repeating: 0x33, count: 32)
    private let staticPrivB = Data(repeating: 0x44, count: 32)
    private let staticPrivC = Data(repeating: 0x55, count: 32)
    private let staticPrivD = Data(repeating: 0x66, count: 32)

    private func tempDbUrl() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peer_repo_test_\(UUID().uuidString).db")
    }

    private func makeBinding(
        seed: Data,
        generation: UInt32,
        staticDhPriv: Data
    ) -> ValidatedPeerBinding {
        let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let agreementKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticDhPriv)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let sig = try! signingKey.signature(for: preimage)
        let binding = try! IdentityBindingV1(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: sig
        )
        let res = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: IdentityBindingV1.deriveNodeHint(
                nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signingKey.publicKey.rawRepresentation)
            )
        )
        guard case .valid(let validated) = res else {
            fatalError("Validation failed")
        }
        return validated
    }

    // =========================================================================
    // 1. FIRST SEEN & RECONNECT TESTS
    // =========================================================================

    func testFirstSeenGenerationZero() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)

        let result = repo.applyValidatedBinding(binding)
        XCTAssertEqual(result, .firstSeenPinned)

        let lookup = repo.lookup(binding.nodeId)
        guard case .verified(let verified) = lookup else {
            XCTFail("Expected verified lookup, got \(lookup)")
            return
        }
        XCTAssertEqual(verified.acceptedGeneration, 0)
        XCTAssertEqual(verified.trustLevel, .tofuPinned)
    }

    func testFirstSeenGenerationSeven() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 7, staticDhPriv: staticPrivA)

        let result = repo.applyValidatedBinding(binding)
        XCTAssertEqual(result, .firstSeenPinned)

        let lookup = repo.lookup(binding.nodeId)
        guard case .verified(let verified) = lookup else {
            XCTFail("Expected verified lookup")
            return
        }
        XCTAssertEqual(verified.acceptedGeneration, 7)
    }

    func testFirstSeenGenerationUint32Max() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: UInt32.max, staticDhPriv: staticPrivA)

        let result = repo.applyValidatedBinding(binding)
        XCTAssertEqual(result, .firstSeenPinned)

        let res2 = repo.applyValidatedBinding(binding)
        XCTAssertEqual(res2, .accepted)
    }

    func testExactReconnectAccepted() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let binding = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(binding)

        let res2 = repo.applyValidatedBinding(binding)
        XCTAssertEqual(res2, .accepted)
    }

    // =========================================================================
    // 2. ROTATION & QUARANTINE PROGRESSION
    // =========================================================================

    func testInitialPendingCandidate() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        let res = repo.applyValidatedBinding(b2)
        XCTAssertEqual(res, .keyChangedQuarantined)

        let lookup = repo.lookup(b1.nodeId)
        guard case .quarantined(let quarantined) = lookup else {
            XCTFail("Expected quarantined lookup")
            return
        }
        XCTAssertEqual(quarantined.acceptedGeneration, 5)
        XCTAssertEqual(quarantined.pendingGeneration, 6)
    }

    func testAdvancePendingCandidateHighWater() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        let b3 = makeBinding(seed: seedA, generation: 8, staticDhPriv: staticPrivC)
        let res = repo.applyValidatedBinding(b3)
        XCTAssertEqual(res, .keyChangedQuarantined)

        let lookup = repo.lookup(b1.nodeId)
        guard case .quarantined(let quarantined) = lookup else {
            XCTFail("Expected quarantined lookup")
            return
        }
        XCTAssertEqual(quarantined.acceptedGeneration, 5)
        XCTAssertEqual(quarantined.pendingGeneration, 8)
    }

    func testPendingDuplicateKeepsQuarantined() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        let res = repo.applyValidatedBinding(b2)
        XCTAssertEqual(res, .keyChangedQuarantined)
    }

    func testOldAcceptedDuringQuarantineKeepsQuarantined() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        let res = repo.applyValidatedBinding(b1)
        XCTAssertEqual(res, .keyChangedQuarantined)
    }

    // =========================================================================
    // 3. REJECTION TESTS
    // =========================================================================

    func testRollbackRejectedWithoutMutation() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        let bLower = makeBinding(seed: seedA, generation: 4, staticDhPriv: staticPrivA)
        let res = repo.applyValidatedBinding(bLower)
        XCTAssertEqual(res, .rejected(.rollback))

        let row = try store.readRaw(b1.nodeId)
        XCTAssertEqual(row?.acceptedGenerationRaw, 5)
    }

    // =========================================================================
    // 4. LOOKUP CLASSIFICATION (L1 - L10)
    // =========================================================================

    func testLookupClassifications() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)

        // L1: Absent
        XCTAssertEqual(repo.lookup(Data(repeating: 0x99, count: 16)), .notFound)

        // L10: Invalid length
        guard case .invalidArgument = repo.lookup(Data(repeating: 0x99, count: 15)) else {
            XCTFail("Expected invalidArgument")
            return
        }

        // L2: Valid TOFU
        let b1 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)
        guard case .verified = repo.lookup(b1.nodeId) else {
            XCTFail("Expected verified")
            return
        }

        // L4: Quarantined
        let b2 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)
        guard case .quarantined = repo.lookup(b1.nodeId) else {
            XCTFail("Expected quarantined")
            return
        }
    }

    // =========================================================================
    // =========================================================================
    // 5. CORRUPT ROW DETECTION & TRANSACTION ABORT ROLLBACK
    // =========================================================================

    func testCorruptRowDetectionFailsClosed() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        // Initialize store
        _ = try SqlitePeerIdentityStore(url: url)

        let binding = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let signingKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let signPub = signingKey.publicKey.rawRepresentation
        let agreementKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let staticPub = agreementKey.publicKey.rawRepresentation

        // Bypass CHECK constraints directly via SQLite C API in test fixture
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        sqlite3_exec(db, "PRAGMA ignore_check_constraints = ON", nil, nil, nil)
        var stmt: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_prepare_v2(db, PeerIdentitySchema.insertFirstSeenSql, -1, &stmt, nil)
        _ = binding.nodeId.withUnsafeBytes { sqlite3_bind_blob(stmt, 1, $0.baseAddress, 16, transient) }
        _ = signPub.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, 32, transient) }
        _ = staticPub.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, 32, transient) }
        sqlite3_bind_int64(stmt, 4, 0)
        sqlite3_bind_int(stmt, 5, 99) // Invalid trust level
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        sqlite3_close_v2(db)

        let store = try SqlitePeerIdentityStore(url: url)
        let repo = PeerIdentityRepository(store: store)

        let applyRes = repo.applyValidatedBinding(binding)
        guard case .corrupt(let reason) = applyRes,
              case .unknownTrustLevelCode(let code) = reason else {
            XCTFail("Expected corrupt with unknownTrustLevelCode, got \(applyRes)")
            return
        }
        XCTAssertEqual(code, 99)

        let lookupRes = repo.lookup(binding.nodeId)
        guard case .corrupt = lookupRes else {
            XCTFail("Expected corrupt lookup")
            return
        }
    }

    /// Proxy store for intercepting store operations to test readback corruptions, faults, and cardinality.
    private final class HookablePeerIdentityStore: PeerIdentityStore {
        private let delegate: PeerIdentityStore
        var hookReadRaw: ((Data) throws -> PeerIdentityRow?)?
        var hookInsertFirstSeen: ((Data, Data, Data, Int64, Int32) throws -> Int)?
        var hookSetInitialPending: ((Data, Data, Data, Int64, Int32, Data, Int64) throws -> Int)?
        var hookAdvancePending: ((Data, Data, Data, Int64, Int32, Data, Int64, Data, Int64) throws -> Int)?
        var hookInTx: (((PeerIdentityStore) throws -> Any) throws -> Any)?

        var faultAfterInsert: Bool = false
        var faultAfterInitialPending: Bool = false
        var faultAfterAdvancePending: Bool = false

        init(delegate: PeerIdentityStore) {
            self.delegate = delegate
        }

        func inImmediateTransaction<T>(_ block: (PeerIdentityStore) throws -> T) throws -> T {
            if let hook = hookInTx {
                return try hook { try block($0) } as! T
            }
            return try delegate.inImmediateTransaction { tx in
                let txHookStore = HookablePeerIdentityStore(delegate: tx)
                txHookStore.hookReadRaw = self.hookReadRaw
                txHookStore.hookInsertFirstSeen = self.hookInsertFirstSeen
                txHookStore.hookSetInitialPending = self.hookSetInitialPending
                txHookStore.hookAdvancePending = self.hookAdvancePending
                txHookStore.faultAfterInsert = self.faultAfterInsert
                txHookStore.faultAfterInitialPending = self.faultAfterInitialPending
                txHookStore.faultAfterAdvancePending = self.faultAfterAdvancePending
                return try block(txHookStore)
            }
        }

        func readRaw(_ nodeId: Data) throws -> PeerIdentityRow? {
            if let hook = hookReadRaw { return try hook(nodeId) }
            return try delegate.readRaw(nodeId)
        }

        func insertFirstSeen(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            trustCode: Int32
        ) throws -> Int {
            let affected: Int
            if let hook = hookInsertFirstSeen {
                affected = try hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustCode)
            } else {
                affected = try delegate.insertFirstSeen(
                    nodeId: nodeId,
                    signingPub: signingPub,
                    acceptedStatic: acceptedStatic,
                    acceptedGeneration: acceptedGeneration,
                    trustCode: trustCode
                )
            }
            if faultAfterInsert {
                XCTAssertEqual(affected, 1)
                throw InjectedStorageFault()
            }
            return affected
        }

        func setInitialPendingGuarded(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            trustLevel: Int32,
            newPendingStatic: Data,
            newPendingGeneration: Int64
        ) throws -> Int {
            let affected: Int
            if let hook = hookSetInitialPending {
                affected = try hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, newPendingStatic, newPendingGeneration)
            } else {
                affected = try delegate.setInitialPendingGuarded(
                    nodeId: nodeId,
                    signingPub: signingPub,
                    acceptedStatic: acceptedStatic,
                    acceptedGeneration: acceptedGeneration,
                    trustLevel: trustLevel,
                    newPendingStatic: newPendingStatic,
                    newPendingGeneration: newPendingGeneration
                )
            }
            if faultAfterInitialPending {
                XCTAssertEqual(affected, 1)
                throw InjectedStorageFault()
            }
            return affected
        }

        func advancePendingGuarded(
            nodeId: Data,
            signingPub: Data,
            acceptedStatic: Data,
            acceptedGeneration: Int64,
            trustLevel: Int32,
            oldPendingStatic: Data,
            oldPendingGeneration: Int64,
            newPendingStatic: Data,
            newPendingGeneration: Int64
        ) throws -> Int {
            let affected: Int
            if let hook = hookAdvancePending {
                affected = try hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, oldPendingStatic, oldPendingGeneration, newPendingStatic, newPendingGeneration)
            } else {
                affected = try delegate.advancePendingGuarded(
                    nodeId: nodeId,
                    signingPub: signingPub,
                    acceptedStatic: acceptedStatic,
                    acceptedGeneration: acceptedGeneration,
                    trustLevel: trustLevel,
                    oldPendingStatic: oldPendingStatic,
                    oldPendingGeneration: oldPendingGeneration,
                    newPendingStatic: newPendingStatic,
                    newPendingGeneration: newPendingGeneration
                )
            }
            if faultAfterAdvancePending {
                XCTAssertEqual(affected, 1)
                throw InjectedStorageFault()
            }
            return affected
        }
    }

    func testFirstSeenReadbackCorruptionRollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)
        let b = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)

        var readCount = 0
        hookStore.hookReadRaw = { nodeId in
            readCount += 1
            if readCount == 1 {
                return nil
            } else {
                return PeerIdentityRow(
                    nodeIdRaw: nodeId,
                    signingPublicKeyRaw: b.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw: b.staticDhPublicKey,
                    acceptedGenerationRaw: Int64(b.generation),
                    trustCodeRaw: 999, // Corrupt!
                    pendingStaticDhPublicKeyRaw: nil,
                    pendingGenerationRaw: nil
                )
            }
        }

        let res = repo.applyValidatedBinding(b)
        guard case .corrupt(let reason) = res,
              case .unknownTrustLevelCode(let code) = reason else {
            XCTFail("Expected corrupt with unknownTrustLevelCode, got \(res)")
            return
        }
        XCTAssertEqual(code, 999)

        // Verify transaction was aborted and database has NO row
        hookStore.hookReadRaw = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        XCTAssertNil(try freshStore.readRaw(b.nodeId))
    }

    func testInitialPendingReadbackCorruptionRollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        XCTAssertEqual(repo.applyValidatedBinding(b1), .firstSeenPinned)

        let b2 = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivB)
        var readCount = 0
        hookStore.hookReadRaw = { nodeId in
            readCount += 1
            if readCount == 1 {
                return PeerIdentityRow(
                    nodeIdRaw: b1.nodeId,
                    signingPublicKeyRaw: b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw: b1.staticDhPublicKey,
                    acceptedGenerationRaw: Int64(b1.generation),
                    trustCodeRaw: Int32(PeerTrustLevel.tofuPinned.persistedCode),
                    pendingStaticDhPublicKeyRaw: nil,
                    pendingGenerationRaw: nil
                )
            } else {
                // Post-mutation readback: corrupt out-of-range pending generation
                return PeerIdentityRow(
                    nodeIdRaw: b1.nodeId,
                    signingPublicKeyRaw: b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw: b1.staticDhPublicKey,
                    acceptedGenerationRaw: Int64(b1.generation),
                    trustCodeRaw: Int32(PeerTrustLevel.tofuPinned.persistedCode),
                    pendingStaticDhPublicKeyRaw: b2.staticDhPublicKey,
                    pendingGenerationRaw: 5000000000 // Corrupt > UINT32_MAX!
                )
            }
        }

        let res = repo.applyValidatedBinding(b2)
        guard case .corrupt(let reason) = res,
              case .pendingGenerationOutOfRange = reason else {
            XCTFail("Expected corrupt with pendingGenerationOutOfRange, got \(res)")
            return
        }

        // Verify transaction was aborted: row remains b1 with no pending
        hookStore.hookReadRaw = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let restored = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(restored)
        XCTAssertNil(restored?.pendingStaticDhPublicKeyRaw)
        XCTAssertNil(restored?.pendingGenerationRaw)
    }

    func testAdvancePendingReadbackCorruptionRollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)
        let b2 = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        let b3 = makeBinding(seed: seedA, generation: 2, staticDhPriv: staticPrivC)
        var readCount = 0
        hookStore.hookReadRaw = { nodeId in
            readCount += 1
            if readCount == 1 {
                return PeerIdentityRow(
                    nodeIdRaw: b1.nodeId,
                    signingPublicKeyRaw: b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw: b1.staticDhPublicKey,
                    acceptedGenerationRaw: Int64(b1.generation),
                    trustCodeRaw: Int32(PeerTrustLevel.tofuPinned.persistedCode),
                    pendingStaticDhPublicKeyRaw: b2.staticDhPublicKey,
                    pendingGenerationRaw: Int64(b2.generation)
                )
            } else {
                return PeerIdentityRow(
                    nodeIdRaw: b1.nodeId,
                    signingPublicKeyRaw: b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw: b1.staticDhPublicKey,
                    acceptedGenerationRaw: Int64(b1.generation),
                    trustCodeRaw: Int32(PeerTrustLevel.tofuPinned.persistedCode),
                    pendingStaticDhPublicKeyRaw: b2.staticDhPublicKey, // Valid (differs from accepted), but does NOT match b3!
                    pendingGenerationRaw: 99
                )
            }
        }

        let res = repo.applyValidatedBinding(b3)
        guard case .corrupt(let reason) = res,
              case .mutationReadbackMismatch = reason else {
            XCTFail("Expected corrupt with mutationReadbackMismatch, got \(res)")
            return
        }

        // Verify transaction was aborted: row retains b2 pending
        hookStore.hookReadRaw = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let restored = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.pendingGenerationRaw, 1)
        XCTAssertEqual(restored?.pendingStaticDhPublicKeyRaw, b2.staticDhPublicKey)
    }

    // =========================================================================
    // 6. MUTATION CARDINALITY MATRIX (0 and 2 affected rows)
    // =========================================================================

    func testCardinalityMatrix_InitialPending_ZeroAffected_RollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        hookStore.hookSetInitialPending = { _, _, _, _, _, _, _ in 0 }
        let b2 = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivB)
        let res = repo.applyValidatedBinding(b2)
        guard case .corrupt(let reason) = res,
              case .mutationCardinality(let exp, let act) = reason else {
            XCTFail("Expected mutationCardinality, got \(res)")
            return
        }
        XCTAssertEqual(exp, 1)
        XCTAssertEqual(act, 0)

        hookStore.hookSetInitialPending = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b1.staticDhPublicKey)
        XCTAssertNil(row?.pendingGenerationRaw)
        XCTAssertNil(row?.pendingStaticDhPublicKeyRaw)
    }

    func testCardinalityMatrix_InitialPending_TwoAffected_RollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        hookStore.hookSetInitialPending = { _, _, _, _, _, _, _ in 2 }
        let b2 = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivB)
        let res = repo.applyValidatedBinding(b2)
        guard case .corrupt(let reason) = res,
              case .mutationCardinality(let exp, let act) = reason else {
            XCTFail("Expected mutationCardinality, got \(res)")
            return
        }
        XCTAssertEqual(exp, 1)
        XCTAssertEqual(act, 2)

        hookStore.hookSetInitialPending = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b1.staticDhPublicKey)
        XCTAssertNil(row?.pendingGenerationRaw)
        XCTAssertNil(row?.pendingStaticDhPublicKeyRaw)
    }

    func testCardinalityMatrix_AdvancePending_ZeroAffected_RollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)
        let b2 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        hookStore.hookAdvancePending = { _, _, _, _, _, _, _, _, _ in 0 }
        let b3 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivC)
        let res = repo.applyValidatedBinding(b3)
        guard case .corrupt(let reason) = res,
              case .mutationCardinality(let exp, let act) = reason else {
            XCTFail("Expected mutationCardinality, got \(res)")
            return
        }
        XCTAssertEqual(exp, 1)
        XCTAssertEqual(act, 0)

        hookStore.hookAdvancePending = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b1.staticDhPublicKey)
        XCTAssertEqual(row?.pendingGenerationRaw, 5)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, b2.staticDhPublicKey)
    }

    func testCardinalityMatrix_AdvancePending_TwoAffected_RollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)
        let b2 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        hookStore.hookAdvancePending = { _, _, _, _, _, _, _, _, _ in 2 }
        let b3 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivC)
        let res = repo.applyValidatedBinding(b3)
        guard case .corrupt(let reason) = res,
              case .mutationCardinality(let exp, let act) = reason else {
            XCTFail("Expected mutationCardinality, got \(res)")
            return
        }
        XCTAssertEqual(exp, 1)
        XCTAssertEqual(act, 2)

        hookStore.hookAdvancePending = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b1.staticDhPublicKey)
        XCTAssertEqual(row?.pendingGenerationRaw, 5)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, b2.staticDhPublicKey)
    }

    // =========================================================================
    // 7. STORAGE FAULT ROLLBACK TESTS (F1, F2, F3, Commit Failure)
    // =========================================================================

    struct InjectedStorageFault: Error {}

    func testStorageFaultF1_FirstSeenFailure_RollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        hookStore.faultAfterInsert = true

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let res = repo.applyValidatedBinding(b1)
        XCTAssertEqual(res, .storageFailure)

        hookStore.faultAfterInsert = false
        let freshStore = try SqlitePeerIdentityStore(url: url)
        XCTAssertNil(try freshStore.readRaw(b1.nodeId))
    }

    func testStorageFaultF2_InitialPendingFailure_RollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)

        hookStore.faultAfterInitialPending = true

        let b2 = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivB)
        let res = repo.applyValidatedBinding(b2)
        XCTAssertEqual(res, .storageFailure)

        hookStore.faultAfterInitialPending = false
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b1.staticDhPublicKey)
        XCTAssertNil(row?.pendingGenerationRaw)
        XCTAssertNil(row?.pendingStaticDhPublicKeyRaw)
    }

    func testStorageFaultF3_AdvancePendingFailure_RollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo.applyValidatedBinding(b1)
        let b2 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo.applyValidatedBinding(b2)

        hookStore.faultAfterAdvancePending = true

        let b3 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivC)
        let res = repo.applyValidatedBinding(b3)
        XCTAssertEqual(res, .storageFailure)

        hookStore.faultAfterAdvancePending = false
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b1.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b1.staticDhPublicKey)
        XCTAssertEqual(row?.pendingGenerationRaw, 5)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, b2.staticDhPublicKey)
    }

    func testSimulatedCommitFailureAfterSuccessfulBodyRollsBack() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let rawStore = try SqlitePeerIdentityStore(url: url)
        let hookStore = HookablePeerIdentityStore(delegate: rawStore)
        let repo = PeerIdentityRepository(store: hookStore)

        hookStore.hookInTx = { block in
            try rawStore.inImmediateTransaction { tx in
                _ = try block(tx)
                // Simulated commit failure after transaction body success
                throw InjectedStorageFault()
            }
        }

        let b1 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let res = repo.applyValidatedBinding(b1)
        XCTAssertEqual(res, .storageFailure)

        hookStore.hookInTx = nil
        let freshStore = try SqlitePeerIdentityStore(url: url)
        XCTAssertNil(try freshStore.readRaw(b1.nodeId))
    }

    // =========================================================================
    // 8. CROSS-CONNECTION CONCURRENCY TESTS (C1, C2, C3, C4, Supplemental)
    // =========================================================================

    func testConcurrencyC1IdenticalFirstSeen() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        let binding = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)

        let group = DispatchGroup()
        var res1: PeerTrustApplyResult?
        var res2: PeerTrustApplyResult?

        group.enter()
        DispatchQueue.global().async {
            res1 = repo1.applyValidatedBinding(binding)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            res2 = repo2.applyValidatedBinding(binding)
            group.leave()
        }

        group.wait()

        let results = [res1, res2]
        XCTAssertTrue(results.contains(.firstSeenPinned))
        XCTAssertTrue(results.contains(.accepted))

        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(binding.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 5)
        XCTAssertNil(row?.pendingGenerationRaw)
    }

    func testConcurrencyC2Gen5Gen6HighWater() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        // Baseline: Gen 0 / Static A
        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo1.applyValidatedBinding(b0)

        let bGen5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        let bGen6 = makeBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivC)

        var r1: PeerTrustApplyResult?
        var r2: PeerTrustApplyResult?

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            r1 = repo1.applyValidatedBinding(bGen5)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            r2 = repo2.applyValidatedBinding(bGen6)
            group.leave()
        }

        group.wait()

        // Legal outcome taxonomy for C2:
        // Option 1: Gen 5 serializes first: { KeyChangedQuarantined, KeyChangedQuarantined }
        // Option 2: Gen 6 serializes first: { KeyChangedQuarantined, Rejected(StaleRelativeToPending) }
        let isOption1 = (r1 == .keyChangedQuarantined && r2 == .keyChangedQuarantined)
        let isOption2 = (r1 == .rejected(.staleRelativeToPending) && r2 == .keyChangedQuarantined) ||
                        (r1 == .keyChangedQuarantined && r2 == .rejected(.staleRelativeToPending))

        XCTAssertTrue(r1 == .keyChangedQuarantined || r1 == .rejected(.staleRelativeToPending), "r1 must be legal result: \(String(describing: r1))")
        XCTAssertTrue(r2 == .keyChangedQuarantined || r2 == .rejected(.staleRelativeToPending), "r2 must be legal result: \(String(describing: r2))")
        XCTAssertTrue(isOption1 || isOption2, "Outcome must match legal taxonomy: r1=\(String(describing: r1)), r2=\(String(describing: r2))")

        // Final state MUST be accepted 0 / static A, pendingGeneration == 6 / static C
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b0.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b0.staticDhPublicKey)
        XCTAssertEqual(row?.pendingGenerationRaw, 6)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, bGen6.staticDhPublicKey)
    }

    func testConcurrencyC3ExactPendingReplayKeepsQuarantined() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        // Setup on connection 1: accepted A (gen 0, static A), pending P (gen 5, static B)
        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo1.applyValidatedBinding(b0)
        let bGen5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo1.applyValidatedBinding(bGen5)

        // Verify precondition
        let preRow = try store1.readRaw(b0.nodeId)
        XCTAssertEqual(preRow?.acceptedGenerationRaw, 0)
        XCTAssertEqual(preRow?.acceptedStaticDhPublicKeyRaw, b0.staticDhPublicKey)
        XCTAssertEqual(preRow?.pendingGenerationRaw, 5)
        XCTAssertEqual(preRow?.pendingStaticDhPublicKeyRaw, bGen5.staticDhPublicKey)

        var r1: PeerTrustApplyResult?
        var r2: PeerTrustApplyResult?

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            r1 = repo1.applyValidatedBinding(bGen5)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            r2 = repo2.applyValidatedBinding(bGen5)
            group.leave()
        }

        group.wait()

        XCTAssertEqual(r1, .keyChangedQuarantined)
        XCTAssertEqual(r2, .keyChangedQuarantined)

        // Final durable row must be exact: accepted unchanged, pending generation 5, pending static B, trust unchanged
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b0.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b0.staticDhPublicKey)
        XCTAssertEqual(row?.pendingGenerationRaw, 5)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, bGen5.staticDhPublicKey)
        XCTAssertEqual(row?.trustCodeRaw, Int32(PeerTrustLevel.tofuPinned.persistedCode))
    }

    func testConcurrencyC4OldAcceptedReplayKeepsQuarantined() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        // Setup: accepted A (gen 0, static A), pending P (gen 5, static B)
        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo1.applyValidatedBinding(b0)
        let bGen5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo1.applyValidatedBinding(bGen5)

        // Verify precondition
        let preRow = try store1.readRaw(b0.nodeId)
        XCTAssertEqual(preRow?.acceptedGenerationRaw, 0)
        XCTAssertEqual(preRow?.acceptedStaticDhPublicKeyRaw, b0.staticDhPublicKey)
        XCTAssertEqual(preRow?.pendingGenerationRaw, 5)
        XCTAssertEqual(preRow?.pendingStaticDhPublicKeyRaw, bGen5.staticDhPublicKey)

        var r1: PeerTrustApplyResult?
        var r2: PeerTrustApplyResult?

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            r1 = repo1.applyValidatedBinding(b0)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            r2 = repo2.applyValidatedBinding(b0)
            group.leave()
        }

        group.wait()

        XCTAssertEqual(r1, .keyChangedQuarantined)
        XCTAssertEqual(r2, .keyChangedQuarantined)

        // Final durable row must be exact: pending candidate MUST NOT be cleared
        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b0.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.acceptedStaticDhPublicKeyRaw, b0.staticDhPublicKey)
        XCTAssertEqual(row?.pendingGenerationRaw, 5)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, bGen5.staticDhPublicKey)
        XCTAssertEqual(row?.trustCodeRaw, Int32(PeerTrustLevel.tofuPinned.persistedCode))
    }

    func testConcurrencySupplementalAdvancePendingHighWater() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        let b0 = makeBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        _ = repo1.applyValidatedBinding(b0)
        let bGen5 = makeBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        _ = repo1.applyValidatedBinding(bGen5)

        let bGen7 = makeBinding(seed: seedA, generation: 7, staticDhPriv: staticPrivC)
        let bGen8 = makeBinding(seed: seedA, generation: 8, staticDhPriv: staticPrivD)

        var r1: PeerTrustApplyResult?
        var r2: PeerTrustApplyResult?

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            r1 = repo1.applyValidatedBinding(bGen7)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            r2 = repo2.applyValidatedBinding(bGen8)
            group.leave()
        }

        group.wait()

        let isOption1 = (r1 == .keyChangedQuarantined && r2 == .keyChangedQuarantined)
        let isOption2 = (r1 == .rejected(.staleRelativeToPending) && r2 == .keyChangedQuarantined)

        XCTAssertTrue(isOption1 || isOption2, "Outcome must match legal taxonomy: r1=\(String(describing: r1)), r2=\(String(describing: r2))")

        let freshStore = try SqlitePeerIdentityStore(url: url)
        let row = try freshStore.readRaw(b0.nodeId)
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.acceptedGenerationRaw, 0)
        XCTAssertEqual(row?.pendingGenerationRaw, 8)
        XCTAssertEqual(row?.pendingStaticDhPublicKeyRaw, bGen8.staticDhPublicKey)
    }

    func testConcurrencySupplementalIndependentNodes() throws {
        let url = tempDbUrl()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = try SqlitePeerIdentityStore(url: url)
        let store2 = try SqlitePeerIdentityStore(url: url)

        let repo1 = PeerIdentityRepository(store: store1)
        let repo2 = PeerIdentityRepository(store: store2)

        let bNodeA = makeBinding(seed: seedA, generation: 1, staticDhPriv: staticPrivA)
        let bNodeB = makeBinding(seed: seedB, generation: 1, staticDhPriv: staticPrivB)

        var r1: PeerTrustApplyResult?
        var r2: PeerTrustApplyResult?

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            r1 = repo1.applyValidatedBinding(bNodeA)
            group.leave()
        }

        group.enter()
        DispatchQueue.global().async {
            r2 = repo2.applyValidatedBinding(bNodeB)
            group.leave()
        }

        group.wait()

        XCTAssertEqual(r1, .firstSeenPinned)
        XCTAssertEqual(r2, .firstSeenPinned)

        let freshStore = try SqlitePeerIdentityStore(url: url)
        let rowA = try freshStore.readRaw(bNodeA.nodeId)
        let rowB = try freshStore.readRaw(bNodeB.nodeId)
        XCTAssertNotNil(rowA)
        XCTAssertNotNil(rowB)
        XCTAssertEqual(rowA?.acceptedGenerationRaw, 1)
        XCTAssertEqual(rowB?.acceptedGenerationRaw, 1)
    }
}
