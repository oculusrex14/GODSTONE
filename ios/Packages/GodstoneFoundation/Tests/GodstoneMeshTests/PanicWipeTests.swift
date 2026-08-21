import XCTest
@testable import GodstoneMesh

/// Resumable cryptographic-erasure state machine (ADR-004 criterion 5,
/// GST-WIPE-001, Stage 3 Phase F).
///
/// These tests drive the PURE `PanicWipe` machine with in-memory fakes -- no
/// Keychain, no UserDefaults, no disk. A "crash" is modelled as the configured
/// `FakeArtifacts` method throwing on its first invocation (the call did not
/// complete, so the journal still reflects the last completed step); "resume" is
/// a fresh `PanicWipe` sharing the same journal + artifacts, which is exactly
/// the reboot-then-resumeIfPending path. The assertions prove:
///
///   - a no-crash wipe runs every step once, in the crypto-erasure-first order;
///   - a crash before ANY step resumes to full completion;
///   - the journal after each crash is the last COMPLETED step (so resume neither
///     skips nor double-runs a destroying step);
///   - resumeIfPending is a no-op when no wipe is pending, and completes a
///     pending one.
///
/// The platform glue (`UserDefaultsWipeJournal`, `KeychainWipeArtifacts`) is not
/// exercised here -- the Keychain item deletion is an on-device concern. What is
/// proven here is the coordination, ordering and resumability, which are the
/// bug-prone parts and the part that must not silently skip a destroying step.
final class PanicWipeTests: XCTestCase {

    // In-memory journal; mirrors UserDefaultsWipeJournal's idle-on-absent rule.
    private final class FakeJournal: WipeJournal {
        var state: WipeState = .idle
        var writes = 0
        var clears = 0
        func read() -> WipeState { state }
        func write(_ s: WipeState) { state = s; writes += 1 }
        func clear() { state = .idle; clears += 1 }
    }

    /// Records the order of completed step calls. `crashBefore` makes the NAMED
    /// step throw on its FIRST invocation only (the call does not complete and
    /// is NOT recorded); subsequent invocations succeed -- modelling "the crash
    /// happened, then the process restarted and re-runs the step successfully".
    private final class FakeArtifacts: WipeArtifacts {
        let crashBefore: String?
        init(_ crashBefore: String? = nil) { self.crashBefore = crashBefore }

        var calls: [String] = []
        private var crashed = Set<String>()

        private func step(_ name: String) throws {
            if crashBefore == name, !crashed.contains(name) {
                crashed.insert(name)
                throw CrashError(step: name)
            }
            calls.append(name)
        }

        func eraseKeys() throws { try step("eraseKeys") }
        func deleteArtifacts() throws { try step("deleteArtifacts") }
        func regenerateIdentity() throws { try step("regenerateIdentity") }
    }

    private struct CrashError: Error { let step: String }

    // --- no crash: full wipe, every step once, in order, journal cleared ---

    func testBeginWithNoCrashRunsEveryStepOnceInOrder() throws {
        let j = FakeJournal(); let a = FakeArtifacts()
        try PanicWipe(journal: j, artifacts: a).begin()
        XCTAssertEqual(j.state, .idle, "journal cleared back to idle")
        XCTAssertEqual(a.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
    }

    func testCryptoErasureHappensBeforeArtifactDeletion() throws {
        let a = FakeArtifacts()
        try PanicWipe(journal: FakeJournal(), artifacts: a).begin()
        let order = a.calls
        XCTAssertLessThan(order.firstIndex(of: "eraseKeys")!,
                          order.firstIndex(of: "deleteArtifacts")!,
                          "keys destroyed before containers deleted")
        XCTAssertLessThan(order.firstIndex(of: "deleteArtifacts")!,
                          order.firstIndex(of: "regenerateIdentity")!,
                          "containers deleted before a new identity is generated")
    }

    // --- crash before each step: journal reflects last COMPLETED step, resume completes ---

    func testResumesAfterCrashBeforeEraseKeys_requestedPersistedEraseKeysRunsOnce() {
        let j = FakeJournal(); let a = FakeArtifacts("eraseKeys")
        XCTAssertThrowsError(try PanicWipe(journal: j, artifacts: a).begin())
        XCTAssertEqual(j.state, .requested, "nothing destroyed yet -> requested")
        // Resume on a "fresh" coordinator sharing journal + artifacts.
        XCTAssertNoThrow(try PanicWipe(journal: j, artifacts: a).resumeIfPending())
        XCTAssertEqual(j.state, .idle)
        XCTAssertEqual(a.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
        // eraseKeys was NOT recorded on the crashed first attempt, so it appears
        // exactly once -- the destroying step was not double-run, just retried.
    }

    func testResumesAfterCrashBeforeDeleteArtifacts_keyErasedPersistedEraseKeysNotReRun() {
        let j = FakeJournal(); let a = FakeArtifacts("deleteArtifacts")
        XCTAssertThrowsError(try PanicWipe(journal: j, artifacts: a).begin())
        XCTAssertEqual(j.state, .keyErased,
            "keys destroyed and persisted -> keyErased (point of no return)")
        XCTAssertNoThrow(try PanicWipe(journal: j, artifacts: a).resumeIfPending())
        XCTAssertEqual(j.state, .idle)
        // eraseKeys ran once (before the crash) and is NOT re-run on resume,
        // because the journal says keyErased. The crypto-erasure step is not
        // re-attempted and the cleanup continues.
        XCTAssertEqual(a.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
    }

    func testResumesAfterCrashBeforeRegenerateIdentity_artifactsDeletedPersisted() {
        let j = FakeJournal(); let a = FakeArtifacts("regenerateIdentity")
        XCTAssertThrowsError(try PanicWipe(journal: j, artifacts: a).begin())
        XCTAssertEqual(j.state, .artifactsDeleted,
            "artifacts deleted and persisted -> artifactsDeleted")
        XCTAssertNoThrow(try PanicWipe(journal: j, artifacts: a).resumeIfPending())
        XCTAssertEqual(j.state, .idle)
        XCTAssertEqual(a.calls, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
    }

    // --- resumeIfPending contract ---

    func testResumeIfPendingIsNoOpWhenNoWipeIsPending() throws {
        let j = FakeJournal(); let a = FakeArtifacts()
        try PanicWipe(journal: j, artifacts: a).resumeIfPending()
        XCTAssertEqual(j.state, .idle)
        XCTAssertTrue(a.calls.isEmpty, "nothing destroyed with no pending wipe")
        XCTAssertEqual(j.clears, 0)
    }

    func testResumeIfPendingCompletesWipeInterruptedAtKeyErased() throws {
        let j = FakeJournal(); j.state = .keyErased
        let a = FakeArtifacts()
        try PanicWipe(journal: j, artifacts: a).resumeIfPending()
        XCTAssertEqual(j.state, .idle)
        // eraseKeys must NOT run -- the journal already says keys are gone.
        XCTAssertEqual(a.calls, ["deleteArtifacts", "regenerateIdentity"])
    }

    func testSqlitePeerIdentityStore_PanicWipe_DeletesMainAndSidecarsHostSide() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbUrl = tempDir.appendingPathComponent("peer.db")
        let walUrl = tempDir.appendingPathComponent("peer.db-wal")
        let shmUrl = tempDir.appendingPathComponent("peer.db-shm")
        let journalUrl = tempDir.appendingPathComponent("peer.db-journal")

        // Create main and sidecars
        try "db".write(to: dbUrl, atomically: true, encoding: .utf8)
        try "wal".write(to: walUrl, atomically: true, encoding: .utf8)
        try "shm".write(to: shmUrl, atomically: true, encoding: .utf8)
        try "journal".write(to: journalUrl, atomically: true, encoding: .utf8)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbUrl.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: walUrl.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shmUrl.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalUrl.path))

        let wiped = SqlitePeerIdentityStore.panicWipe(at: dbUrl)
        XCTAssertTrue(wiped)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dbUrl.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: walUrl.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shmUrl.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalUrl.path))

        // Idempotent: deleting when absent returns true
        XCTAssertTrue(SqlitePeerIdentityStore.panicWipe(at: dbUrl))
    }

    func testKeychainWipeArtifacts_PeerStoreDeletionFailureThrows_AndLeavesJournalAtKeyErased() throws {
        let j = FakeJournal()
        let keychain = ObservableLocalIdentityKeychain()

        let artifacts = KeychainWipeArtifacts(
            keychain: keychain,
            peerStoreUrl: URL(fileURLWithPath: "/tmp/peer.db"),
            peerStoreWiper: { _ in false } // Injected wipe failure
        )

        let wiper = PanicWipe(journal: j, artifacts: artifacts)
        XCTAssertThrowsError(try wiper.begin())
        XCTAssertEqual(j.state, .keyErased, "Journal must halt at keyErased on delete failure")
        XCTAssertEqual(keychain.addCount, 0, "Identity must not be regenerated if deletion fails")

        // Resume with succeeding wipe proves regeneration runs exactly once
        let resumeArtifacts = KeychainWipeArtifacts(
            keychain: keychain,
            peerStoreUrl: URL(fileURLWithPath: "/tmp/peer.db"),
            peerStoreWiper: { _ in true }
        )
        let resumeWiper = PanicWipe(journal: j, artifacts: resumeArtifacts)
        XCTAssertNoThrow(try resumeWiper.resumeIfPending())
        XCTAssertEqual(j.state, .idle)
        XCTAssertEqual(keychain.addCount, 1, "Identity regenerated exactly once on resume")
    }

    func testKeychainWipeArtifacts_MessageStoreDeletionFailureThrows_AndLeavesJournalAtKeyErased() throws {
        let j = FakeJournal()
        let keychain = ObservableLocalIdentityKeychain()

        let artifacts = KeychainWipeArtifacts(
            keychain: keychain,
            storeUrl: URL(fileURLWithPath: "/tmp/message.db"),
            messageStoreWiper: { _ in false } // Injected message wipe failure
        )

        let wiper = PanicWipe(journal: j, artifacts: artifacts)
        XCTAssertThrowsError(try wiper.begin())
        XCTAssertEqual(j.state, .keyErased, "Journal must halt at keyErased on message store delete failure")
        XCTAssertEqual(keychain.addCount, 0, "Identity must not be regenerated if message deletion fails")

        // Resume with succeeding wipe proves regeneration runs exactly once
        let resumeArtifacts = KeychainWipeArtifacts(
            keychain: keychain,
            storeUrl: URL(fileURLWithPath: "/tmp/message.db"),
            messageStoreWiper: { _ in true }
        )
        let resumeWiper = PanicWipe(journal: j, artifacts: resumeArtifacts)
        XCTAssertNoThrow(try resumeWiper.resumeIfPending())
        XCTAssertEqual(j.state, .idle)
        XCTAssertEqual(keychain.addCount, 1, "Identity regenerated exactly once on resume after message store fix")
    }
}

internal final class ObservableLocalIdentityKeychain: LocalIdentityKeychain, @unchecked Sendable {
    private let lock = NSLock()
    var addCount = 0
    var deleteCount = 0
    var storage: [String: Data] = [:]

    func read(tag: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[tag]
    }

    func add(tag: String, data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        addCount += 1
        storage[tag] = data
    }

    func delete(tag: String) throws {
        lock.lock()
        defer { lock.unlock() }
        deleteCount += 1
        storage.removeValue(forKey: tag)
    }
}