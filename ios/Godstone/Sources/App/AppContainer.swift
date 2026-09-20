import Foundation
import Combine
import GodstoneCore

/// Archive-only production composition root.
@MainActor
final class AppContainer: ObservableObject {
    let tier: Tier
    // T48 (s17): the pairing is sealed at the composition root -- the
    // repository will refuse the file that is not its tier's own.
    let archive: ArchiveRepository

    // T50 (s17): the reader model, seated at the root as the card
    // commandeth. One open serveth the road through the library; the scene
    // is the journey's state owner (the isle twin of the sealed android
    // BrowseViewModel); the provenance face readeth the same frozen columns
    // the android projection enriched. The archive handle abideth for the
    // provenance road alone -- both handles open the same read-only bytes,
    // which no road here wrieteth.
    let archiveLibrary: ArchiveLibrary
    let archiveModel: ArchiveReaderModel
    let scene: ArchiveSceneModel

    init() {
        // *** GS-ARCHIVE-005: THE TEST-ONLY FIXTURE INSTALL, WHICH ONLY THE APP CAN PERFORM. ***
        //
        // *A UI-TEST RUNNER CANNOT STAGE THIS: it executes in its OWN data container, so a file it writes is one the
        // APP never reads -- MEASURED. My first two staging attempts from the runner each "succeeded" and the app went
        // on reporting `Archive unavailable -- the archive is not installed (missing)`, which the app's own
        // accessibility tree showed.*
        //
        // **SO THE APP IS THE ONLY WRITER, AND ONLY WHEN TOLD TO BE.** The argument is read here, the fixture is copied
        // into THIS process's own application-support path -- the exact place `ArchiveRepository.resolveDatabasePath`
        // looks -- and **NOTHING HAPPENS WITHOUT THE ARGUMENT**, so shipping behavior is unchanged.*
        //
        // *THE PATH IS THE ONLY THING PASSED. The bytes come from the project's own builder, so the schema is the real
        // one; and the copy is deliberately fail-closed: a fixture that cannot be installed leaves the app reporting
        // its honest "missing", which the witness then fails on rather than passing vacuously.*
        #if DEBUG
        Self.installFixtureIfRequested()
        #endif

        tier = Tier.current
        archive = ArchiveRepository(databaseName: tier.archiveDatabaseName, expectedTier: tier)
        archiveLibrary = ArchiveLibrary(databaseName: tier.archiveDatabaseName, tier: tier)
        archiveModel = ArchiveReaderModel(library: archiveLibrary)
        scene = ArchiveSceneModel(reading: archiveLibrary, model: archiveModel)
    }

    /// Install a test fixture archive when the app is launched with `-gs-archive-fixture <path>`.
    ///
    /// *The path is read from the app's OWN `ProcessInfo.arguments` -- **NOT from the runner's environment**, which
    /// does not cross the process boundary. A copy that throws is swallowed on purpose: the app then reports its real
    /// availability, and the UI witness fails on the truth rather than on a staged lie.*
    #if DEBUG
    private static func installFixtureIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-gs-archive-fixture"),
              args.index(after: flag) < args.endIndex else { return }
        let source = URL(fileURLWithPath: args[args.index(after: flag)])
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("archives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("archive_light.db")
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: source, to: dest)
    }
    #endif
}
