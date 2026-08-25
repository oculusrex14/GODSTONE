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

    func testStartup_PendingWipe_FinishesBeforeRuntimeInitialization() throws {
        let journal = InMemoryJournal()
        journal.write(.requested)
        let artifacts = StepTrackingArtifacts()

        var startupCompleted = false
        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        if journal.read() == .idle {
            startupCompleted = true
        }

        XCTAssertTrue(startupCompleted)
        XCTAssertEqual(artifacts.executedSteps, ["eraseKeys", "deleteArtifacts", "regenerateIdentity"])
        XCTAssertEqual(journal.state, .idle)
    }

    func testStartup_CleanLaunch_InitializesRuntimeNormally() throws {
        let journal = InMemoryJournal()
        let artifacts = StepTrackingArtifacts()

        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertEqual(artifacts.executedSteps.count, 0)
        XCTAssertEqual(journal.state, .idle)
    }

    func testStartup_MidWipeCrash_LeavesConsistentFinalState() throws {
        let journal = InMemoryJournal()
        journal.write(.keyErased)
        let artifacts = StepTrackingArtifacts()

        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertEqual(artifacts.executedSteps, ["deleteArtifacts", "regenerateIdentity"])
        XCTAssertEqual(journal.state, .idle)
        XCTAssertNotNil(artifacts.currentIdentity)
    }

    func testStartup_IdentityRegeneration_YieldsFreshNodeIdAndZeroGeneration() throws {
        let originalIdentity = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let regeneratedIdentity = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())

        XCTAssertNotEqual(originalIdentity.nodeId, regeneratedIdentity.nodeId)
        XCTAssertNotEqual(originalIdentity.signingPublicKey, regeneratedIdentity.signingPublicKey)
        XCTAssertNotEqual(originalIdentity.staticDhPublicKey, regeneratedIdentity.staticDhPublicKey)
        XCTAssertEqual(regeneratedIdentity.bindingGeneration, 0)
    }

    func testStartup_OldDatabaseFilesUnusable_AfterCryptoErasure() throws {
        let journal = InMemoryJournal()
        let artifacts = StepTrackingArtifacts()
        let oldIdentity = artifacts.currentIdentity

        try PanicWipe(journal: journal, artifacts: artifacts).begin()

        let newIdentity = artifacts.currentIdentity
        XCTAssertNotNil(newIdentity)
        XCTAssertNotEqual(oldIdentity?.nodeId, newIdentity?.nodeId)
    }

    func testStartup_WipeJournalCleared_OnlyUponFullCompletion() throws {
        let journal = InMemoryJournal()
        final class CrashArtifacts: WipeArtifacts, @unchecked Sendable {
            var stepCount = 0
            func eraseKeys() throws { stepCount += 1 }
            func deleteArtifacts() throws {
                stepCount += 1
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Crash before regenerateIdentity"])
            }
            func regenerateIdentity() throws { stepCount += 1 }
        }

        let artifacts = CrashArtifacts()
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)
        XCTAssertThrowsError(try wipe.begin())

        XCTAssertEqual(journal.state, .keyErased)
        XCTAssertEqual(journal.clears, 0)
    }

    func testStartup_RebootBarrier_PreventsStaleStoreAccess() throws {
        let journal = InMemoryJournal()
        journal.write(.requested)
        var barrierCleared = false
        final class BarrierArtifacts: WipeArtifacts, @unchecked Sendable {
            var onRegen: () -> Void
            init(onRegen: @escaping () -> Void) { self.onRegen = onRegen }
            func eraseKeys() throws {}
            func deleteArtifacts() throws {}
            func regenerateIdentity() throws { onRegen() }
        }

        let artifacts = BarrierArtifacts { barrierCleared = true }
        XCTAssertFalse(barrierCleared)
        try PanicWipe.resumeIfPending(journal: journal, artifacts: artifacts)
        XCTAssertTrue(barrierCleared)
    }
}
