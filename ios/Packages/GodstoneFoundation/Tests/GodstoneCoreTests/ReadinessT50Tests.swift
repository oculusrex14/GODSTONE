import XCTest
import Foundation
import SQLite3
@testable import GodstoneCore

/* ============================================================================
 T50 (s17) -- the designated regression court for the completed iOS reading
 journey: the reader model wired at the root, the scene as the state owner
 (the isle twin of the sealed android BrowseViewModel, T49).

 Method, not magic: the fakes record WHAT REALLY HAPPENED -- every petition
 the engine actually saw is appended to a history the court inspecteth, and
 every fetch bumps a counter the court readeth. The concurrency witnesses
 follow the determinism law the T49 campaign taught: the elder is never
 released until the younger's tale hath landed, and a settle-window of
 yields drains the executor before the sample is taken.

 W12 walketh the REAL road: repository, library, model and scene over the
 FROZEN DDL executed verbatim -- the provenance columns, the unheard
 document answering nil, and the defaced bytes refusing the empty
 masquerade, on the true SQL stock. The WIP's Dynamic Type change was
 reviewed and kept (the reading size scaleth with the body category); the
 VoiceOver order and the 200% reflow are element- and device-side proofs
 deferred to T73-T75 under the card's own clause.

 The App lane (ArchiveView, AppContainer) is proven by the xcodebuild
 compile witness recorded in the milestones; this lane proveth all that
 the view rendereth, extracted into the scene.
 ============================================================================ */

private final class FakeReader: ArchiveReading, @unchecked Sendable {
    private let lock = NSLock()

    // the table: three documents, two passages under the first
    let guide = ArchiveDocument(id: 7, title: "Archive guide", domain: "reference",
                                isCritical: false, sourceId: "src-001", revision: "r7")
    let first = ArchivePassage(id: 11, documentId: 7, documentTitle: "Archive guide",
                               domain: "reference", section: "Search", text: "Read the full guide.")
    let second = ArchivePassage(id: 12, documentId: 7, documentTitle: "Archive guide",
                                domain: "reference", section: "Search", text: "Remaining context.")
    var sourceTable: [Int64: ArchiveSourceMetadata] = [
        7: ArchiveSourceMetadata(documentId: 7, title: "Archive guide", sourceId: "src-001",
                                 licence: "CC0-BY", revision: "r7", isCritical: false)
    ]

    var availability: ArchiveAvailability = .ready(origin: "fake://installed.bin | sqlite 3.")
    var failSearch = false
    var failList = false
    var failPassages = false
    var searchBlock: ((String) -> [ArchivePassage])? = nil

    // record what really happened -------------------------------------------
    private(set) var searched: [String] = []
    private(set) var searchCalls = 0
    private(set) var listCalls = 0
    private(set) var passageCalls = 0
    private(set) var metadataCalls = 0

    // the pause protocol: the elder han, the younger hui ---------------------
    private var waiting: [CheckedContinuation<ArchivePage, Error>] = []
    private var pausedPhrases: Set<String> = []

    func pause(on phrase: String) { lock.lock(); pausedPhrases.insert(phrase); lock.unlock() }

    func releaseAll(raise failure: Error? = nil) {
        lock.lock(); let queue = waiting; waiting.removeAll(); lock.unlock()
        let outcome: Result<ArchivePage, Error>
        if let failure { outcome = .failure(failure) } else { outcome = .success(.passages([])) }
        for k in queue { k.resume(with: outcome) }
    }

    private func isPaused(_ phrase: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return pausedPhrases.contains(phrase)
    }

    func read(_ request: ArchiveRequest) async throws -> ArchivePage {
        switch request {
        case .browse:
            lock.lock(); listCalls += 1; lock.unlock()
            if failList { throw ArchiveError.queryFailed("no such table: documents") }
            return .documents([guide])
        case .search(let phrase):
            lock.lock(); searchCalls += 1; searched.append(phrase); lock.unlock()
            if isPaused(phrase) {
                return try await withCheckedThrowingContinuation { (k: CheckedContinuation<ArchivePage, Error>) in
                    lock.lock(); waiting.append(k); lock.unlock()
                }
                // resumed by the court; the halt-and-catch below is the elder's fate
                if failSearch {
                    throw ArchiveError.queryFailed(
                        "SELECT private FROM tables WHERE hidden = 1: prepare 'x' returned 8")
                }
            }
            if failSearch { throw ArchiveError.queryFailed("the road gave way") }
            return .passages(searchBlock?(phrase) ?? [first])
        case .document(let id):
            lock.lock(); passageCalls += 1; lock.unlock()
            if failPassages { throw ArchiveError.queryFailed("prepare: no such column: c.text") }
            if id != 7 { return .passages([]) }
            return .passages([first, second])
        }
    }

    func sourceMetadata(documentId: Int64) -> ArchiveSourceMetadata? {
        lock.lock(); metadataCalls += 1; lock.unlock()
        return sourceTable[documentId]
    }
}

private struct MinimalReader: ArchiveReading {
    func read(_ request: ArchiveRequest) async throws -> ArchivePage { .documents([]) }
}

@MainActor
final class ReadinessT50Tests: XCTestCase {
    private static let tierName = Tier.light.archiveDatabaseName   // archive_light.db

    private enum TestError: Error { case fixtureNotFound(String), noSupportDirectory }

    // MARK: - the fixture: the FROZEN DDL executed verbatim (the T48 idiom, reseeded)

    private var fixturesDirectory: URL {
        get throws {
            guard let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw TestError.noSupportDirectory
            }
            let dir = base.appendingPathComponent("archives", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    private func repoFile(named relative: String) throws -> String {
        var dir = FileManager.default.currentDirectoryPath
        for _ in 0..<8 {
            let candidate = dir + "/" + relative
            if FileManager.default.fileExists(atPath: candidate) {
                return try String(contentsOfFile: candidate, encoding: .utf8)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty || parent == "/" { break }
            dir = parent
        }
        XCTFail("the frozen DDL \(relative) could not be found above \(dir)")
        throw TestError.fixtureNotFound(relative)
    }

    /// Split on semicolons that lie outside quoted and comment regions; the
    /// frozen DDL hideth semicolons in prose and in the tokenizer string.
    private func splitStatements(_ script: String) -> [String] {
        enum Region { case plain, lineComment, blockComment, singleQuote, doubleQuote }
        var region = Region.plain
        var statements: [String] = []
        var current = ""
        let chars = Array(script)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let peek: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            switch (region, ch) {
            case (.plain, "'"):
                region = .singleQuote; current.append(ch)
            case (.plain, "\""):
                region = .doubleQuote; current.append(ch)
            case (.plain, "-") where peek == "-":
                region = .lineComment; current.append(ch)
            case (.plain, "/") where peek == "*":
                region = .blockComment; current.append("/*"); i += 1
            case (.plain, ";"):
                statements.append(current); current = ""
            case (.singleQuote, "'") where peek == "'":
                current.append("''"); i += 1
            case (.singleQuote, "'"):
                region = .plain; current.append(ch)
            case (.doubleQuote, "\"") where peek == "\"":
                current.append("\"\""); i += 1
            case (.doubleQuote, "\""):
                region = .plain; current.append(ch)
            case (.lineComment, "\n"):
                region = .plain; current.append(ch)
            case (.blockComment, "*") where peek == "/":
                region = .plain; current.append("*/"); i += 1
            default:
                current.append(ch)
            }
            i += 1
        }
        statements.append(current)
        return statements
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func execScript(_ db: OpaquePointer?, _ script: String, from origin: String) {
        for statement in splitStatements(script) {
            var err: UnsafeMutablePointer<Int8>?
            let rc = sqlite3_exec(db, statement, nil, nil, &err)
            if rc != SQLITE_OK {
                let why = err.map { String(cString: $0) ?? "?" } ?? "rc \(rc)"
                if let e = err { sqlite3_free(e) }
                XCTFail("fixture DDL from \(origin) cried on \"\(String(statement.prefix(72)))…\": \(why)")
                return
            }
        }
    }

    private func insert(_ db: OpaquePointer?, _ sql: String) {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let why = err.map { String(cString: $0) ?? "?" } ?? "rc \(rc)"
            if let e = err { sqlite3_free(e) }
            XCTFail("fixture insert cried: \(why) on \(String(sql.prefix(72)))…")
        }
    }

    private struct FixtureKnobs {
        var schemaVersion: String? = "3"
        var poisonBodyPages = false
    }

    /// Build (or rebuild) the tier's archive under the resolver's eye.
    private func makeArchive(named name: String = ReadinessT50Tests.tierName,
                             _ shape: (inout FixtureKnobs) -> Void = { _ in }) throws -> URL {
        var knobs = FixtureKnobs()
        shape(&knobs)
        let url = (try fixturesDirectory).appendingPathComponent(name, isDirectory: false)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(atPath: url.path)
            if fm.fileExists(atPath: url.path) {
                let witness = url.path + ".stale-" + String(UUID().uuidString.prefix(8))
                try fm.moveItem(atPath: url.path, toPath: witness)
                try? fm.removeItem(atPath: witness)
            }
        }
        var db: OpaquePointer?
        let openRc = sqlite3_open_v2(url.path, &db,
                                     SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openRc == SQLITE_OK, let db else {
            XCTFail("the fixture could not be opened for building: rc \(openRc)")
            throw TestError.fixtureNotFound(name)
        }
        defer { sqlite3_close_v2(db) }   // the one close of the hand that opened

        let schema = try repoFile(named: "content/db/schema.sql")
        let indexes = try repoFile(named: "content/db/indexes.sql")
        execScript(db, splitStatements(schema).joined(separator: "; "), from: "schema.sql")

        insert(db, "INSERT INTO documents (document_id, title, domain, source_id, licence, revision, tier_min, reading_level, is_critical) VALUES (1, 'Water purification in the field', 'water', 'src-a', 'CC0', 'r1', 'LIGHT', 8, 1)")
        insert(db, "INSERT INTO documents (document_id, title, domain, source_id, licence, revision, tier_min, reading_level, is_critical) VALUES (2, 'Power grid outage response', 'power', 'src-b', 'CC0', 'r2', 'LIGHT', 8, 0)")
        insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (11, 1, 1, 'Boiling', 'Bring water to a rolling boil for one full minute to purify it safely', 14)")
        insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (12, 1, 2, 'Chemical', 'Two drops of bleach per litre of clear water rest thirty minutes', 12)")
        insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (21, 2, 1, 'Isolation', 'Cut the mains power before touching any fallen line apparatus', 11)")
        if let schemaVersion = knobs.schemaVersion {
            insert(db, "INSERT INTO archive_meta (key, value) VALUES ('schema_version', '\(schemaVersion)')")
            insert(db, "INSERT INTO archive_meta (key, value) VALUES ('built_by', 't50-court')")
        }
        execScript(db, splitStatements(indexes).joined(separator: "; "), from: "indexes.sql")

        if knobs.poisonBodyPages {
            // sound header and master page; the body pages defaced -- only the
            // integrity walk can feel it (the T47/T48 lesson, kept whole)
            let bytes = try Data(contentsOf: url)
            var poisoned = bytes
            let pageSize = 4096
            if poisoned.count > pageSize * 2 {
                for j in (pageSize * 2)..<min(poisoned.count, pageSize * 2 + 8) {
                    poisoned[j] = 0xFF
                }
            }
            try poisoned.write(to: url, options: Data.WritingOptions.atomic)
        }
        return url
    }

    private func openRepository(_ name: String? = nil, expectedTier: Tier? = .light) -> ArchiveRepository {
        ArchiveRepository(databaseName: name ?? ReadinessT50Tests.tierName, expectedTier: expectedTier)
    }

    /// The composition as AppContainer doth compose it (composition parity,
    /// line for line with the sealed root), save that the tier is named.
    private func composeTrio() -> (ArchiveRepository, ArchiveLibrary, ArchiveReaderModel, ArchiveSceneModel) {
        let archive = openRepository()
        let library = ArchiveLibrary(databaseName: ReadinessT50Tests.tierName, tier: .light)
        let model = ArchiveReaderModel(library: library)
        let scene = ArchiveSceneModel(reading: library, model: model)
        return (archive, library, model, scene)
    }

    private func seat(_ scene: ArchiveSceneModel) async {
        // drain the executor until the scene's published tale settles
        for _ in 0..<500 {
            await Task.yield()
            if !scene.phase.isUnavailable, scene.phase != .loading { return }
        }
    }

    // MARK: - witnesses

    /// W1 -- the initial browse resteth ready; the hand-built trio standeth
    /// where the container standeth (composition parity).
    func testInitialBrowseRestethReadyAndTheTrioStandeth() async throws {
        _ = try makeArchive()
        let (archive, library, _, scene) = composeTrio()
        defer { archive.close() }
        await scene.loadDocuments()
        await seat(scene)
        XCTAssertEqual(scene.phase, .ready, "the first browse must come home ready")
        XCTAssertEqual(scene.mode, .documents, "and at the root")
        XCTAssertEqual(scene.documents.count, 2, "the two fixture documents come home over the frozen DDL")
        XCTAssertNil(scene.error, "no woe, no tale")
        XCTAssertFalse(scene.canRetry, "nothing to retry yet")
        await library.close()
    }

    /// W2 -- the search openeth the WHOLE document; back restoreth the scene
    /// untouched, the road not ridden again.
    func testSearchOpensTheWholeDocumentAndBackRestorethTheScene() async throws {
        let fake = FakeReader()
        let model = ArchiveReaderModel(library: fake)
        let scene = ArchiveSceneModel(reading: fake, model: model)
        await scene.loadDocuments()
        scene.onQueryChanged("  water  ")
        await scene.search()
        await seat(scene)
        XCTAssertEqual(scene.searchedQuery, "water", "the published identity, trimmed")
        XCTAssertEqual(scene.query, "water", "the field telleth what standeth published")
        XCTAssertEqual(scene.mode, .search)
        let hit = scene.passages.first ?? fake.first
        await scene.openPassage(hit)
        await seat(scene)
        XCTAssertEqual(scene.mode, .document, "the whole document openeth")
        XCTAssertEqual(scene.passages.count, 2, "whole: every passage in ordinal order")
        XCTAssertEqual(scene.openedTitle, "Archive guide")
        XCTAssertEqual(scene.openedSource, fake.sourceTable[7], "with its provenance")
        scene.back()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(scene.mode, .search, "back restoreth the search scene")
        XCTAssertEqual(scene.query, "water", "the query preserved, not cleared")
        XCTAssertEqual(scene.searchedQuery, "water", "the identity preserved")
        XCTAssertEqual(scene.passages.count, 1, "the very hits stand again")
        scene.back()
        await Task.yield(); await Task.yield()
        XCTAssertEqual(scene.mode, .documents, "one back further, the documents")
        XCTAssertEqual(fake.searchCalls, 1, "the road was walked, not ridden again")
        XCTAssertEqual(fake.passageCalls, 1, "and the document read once")
    }

    /// W3 -- THE CARD'S FALSIFIER: two readers both answer NOTHING; the
    /// ready one saith noResults, the absent one saith unavailable naming
    /// its cause. The tales must not be confounded.
    func testTheHonestEmptyAndTheAbsentAreTalesToldApart() async throws {
        let honest = FakeReader()
        honest.searchBlock = { _ in [] }
        let readyScene = ArchiveSceneModel(reading: honest, model: ArchiveReaderModel(library: honest))
        await readyScene.loadDocuments()
        readyScene.onQueryChanged("gold")
        await readyScene.search()
        await seat(readyScene)
        XCTAssertEqual(readyScene.phase, .noResults, "the honest empty is noResults")

        let absent = FakeReader()
        absent.availability = .missing("no archive installed; the bundle carrieth none")
        absent.searchBlock = { _ in [] }
        let absentScene = ArchiveSceneModel(reading: absent, model: ArchiveReaderModel(library: absent))
        await absentScene.loadDocuments()
        await seat(absentScene)
        XCTAssertTrue(absentScene.phase.isUnavailable,
                      "the absent archive is unavailable, never an empty list, got \(absentScene.phase)")
        if case .unavailable(let reason, let recoverable) = absentScene.phase {
            XCTAssertTrue(reason.contains("no archive installed"), "the cause nameth, got \(reason)")
            XCTAssertFalse(recoverable, "an absent archive is the installer's to mend, not the reader's")
        }
        XCTAssertFalse(absentScene.canRetry, "no retry knocketh upon an absent wall")
        absentScene.onQueryChanged("gold")
        await absentScene.search()
        await seat(absentScene)
        XCTAssertTrue(absentScene.phase.isUnavailable,
                      "the search upon the absent abideth unavailable, got \(absentScene.phase)")
    }

    /// W4 -- the banner carrieth no SQL whispers; the log may speak freely.
    func testTheBannerCarriethNoSQLWhispers() async throws {
        let fake = FakeReader()
        fake.failSearch = true
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        scene.onQueryChanged("water")
        await scene.search()
        await seat(scene)
        XCTAssertEqual(scene.error, "the search could not be completed",
                       "the shown tale is the fixed one")
        XCTAssertFalse(scene.error?.contains("SELECT") ?? false,
                       "the cause's own words never travel to the banner, got \(scene.error ?? "nil")")
        XCTAssertFalse(scene.error?.contains("prepare") ?? false)
        if case .unavailable(let reason, let recoverable) = scene.phase {
            XCTAssertTrue(reason.contains("query-failed"), "the kind of the woe is named, got \(reason)")
            XCTAssertFalse(reason.contains("SELECT private"), "and the hidden table is not, got \(reason)")
            XCTAssertTrue(recoverable, "a failed request may be retried")
        } else {
            XCTFail("a failed search must stand unavailable, got \(scene.phase)")
        }
        XCTAssertTrue(ArchiveUserMessage.diagnostic(
            for: .queryFailed("SELECT private FROM tables WHERE hidden = 1")).contains("SELECT"),
            "the diagnostic keepeth the tale for the log")
    }

    /// W5 -- editing the field never reladleth submitted results.
    func testEditingTheFieldNeverReladlethSubmittedResults() async throws {
        let fake = FakeReader()
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        scene.onQueryChanged("water")
        await scene.search()
        await seat(scene)
        scene.onQueryChanged("water two")
        XCTAssertEqual(scene.query, "water two", "the field may change")
        XCTAssertEqual(scene.searchedQuery, "water", "the published identity may not")
        XCTAssertEqual(scene.passages.count, 1, "the published results stand unrelabelled")
    }

    /// W6 -- the blank petition is a return, not a petition; and the field
    /// is bounded at the gate the engine commandeth (512).
    func testTheBlankPetitionIsAReturnAndTheFieldIsBounded() async throws {
        let fake = FakeReader()
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        scene.onQueryChanged(String(repeating: " ", count: 10_000))
        await scene.search()
        await seat(scene)
        XCTAssertEqual(scene.mode, .documents, "a blank petition is a return")
        XCTAssertEqual(scene.documents.count, 1, "with the documents present")
        scene.onQueryChanged(String(repeating: "x", count: 10_000))
        XCTAssertEqual(scene.query.count, 512, "the field is bounded at the gate")
    }

    /// W7 -- the gate BEFORE the road: a superseded petition is struck out
    /// before it ever toucheth the reading. The history proveth it.
    func testTheGateBeforeTheRoadStoppetheTheSupersededPetition() async throws {
        let fake = FakeReader()
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        await seat(scene)
        scene.onQueryChanged("obsolete")
        // the petition is BORN before the supersession: the dispatch runneth
        // now (token taken, pre-arm published), the travel is in the task
        let elderPetition = scene.dispatchSearch()
        let elder = Task { if let elderPetition { await scene.travel(elderPetition) } }
        scene.backToDocuments()                       // the navigation superseded it
        for _ in 0..<80 { await Task.yield() }        // let the elder's body begin its run
        await elder.value
        await seat(scene)
        XCTAssertEqual(fake.searched, [], "the superseded petition never toucheth the road")
        XCTAssertEqual(scene.mode, .documents, "and the navigation standeth")
        XCTAssertEqual(scene.phase, .ready,
                       "a superseded petition leaveth not even its loading mark -- the gates precede every publication")
        XCTAssertNil(scene.error, "and no woe is told by the stricken petition")
    }

    /// W8 -- the gate AFTER the road: an obsolete FAILURE, wakened only
    /// after the younger's tale hath landed, publisheth nothing over the
    /// present one (the determinism law, T49's legacy, kept whole).
    func testAnObsoleteFailureCannotOverwriteNewerResults() async throws {
        let fake = FakeReader()
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        await seat(scene)
        fake.pause(on: "slow")
        scene.onQueryChanged("slow")
        let elderPetition = scene.dispatchSearch()
        let elder = Task { if let elderPetition { await scene.travel(elderPetition) } }
        for _ in 0..<80 { await Task.yield() }        // the elder arriveth and blocketh
        scene.onQueryChanged("latest")
        let youngerPetition = scene.dispatchSearch()
        let younger = Task { if let youngerPetition { await scene.travel(youngerPetition) } }
        for _ in 0..<500 {                            // the younger runneth home first
            await Task.yield()
            if scene.searchedQuery == "latest" { break }
        }
        XCTAssertEqual(scene.searchedQuery, "latest", "the younger's tale is told")
        fake.releaseAll()                              // only now is the elder wakened
        _ = await elder.value
        _ = await younger.value
        for _ in 0..<300 { await Task.yield() }       // the settle window
        XCTAssertNil(scene.error, "the obsolete failure may not show")
        XCTAssertEqual(scene.phase, .ready, "the newer tale abideth")
        XCTAssertEqual(scene.passages.count, 1, "the younger's hits stand")
        XCTAssertEqual(scene.searchedQuery, "latest",
                       "the elder's stale tale, late wakened, may not supplant the younger's published truth")
        XCTAssertEqual(scene.query, "latest", "nor relabel the field behind")
        XCTAssertEqual(fake.searched, ["slow", "latest"],
                       "yet the engine saw them both -- the record proveth the road was walked twice and gated once")
    }

    /// W9 -- retry is earned only where the road may mend.
    func testRetryIsEarnedOnlyWhereTheRoadMayMend() async throws {
        let fake = FakeReader()
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        await seat(scene)
        let afterOpen = fake.listCalls
        await scene.retry()                            // unearned: no road ridden again
        await seat(scene)
        XCTAssertEqual(fake.listCalls, afterOpen, "without an earned retry the road is not ridden again")
        fake.failList = true
        await scene.loadDocuments()
        await seat(scene)
        XCTAssertTrue(scene.canRetry, "a failed request earneth the retry")
        fake.failList = false
        await scene.retry()
        await seat(scene)
        XCTAssertEqual(scene.documents.count, 1, "the earned retry replieth the very request")
        XCTAssertEqual(scene.phase, .ready, "and mendeth the tale")
        XCTAssertFalse(scene.canRetry, "the retry is spent")
    }

    /// W10 -- process recreation: the journey's place, the query and the
    /// opened document identity travel a property-list handle and stand again.
    func testProcessRecreationRestorethTheSameJourney() async throws {
        let fake = FakeReader()
        let first = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await first.loadDocuments()
        await seat(first)
        first.onQueryChanged("water")
        await first.search()
        await seat(first)
        await first.openPassage(fake.first)
        await seat(first)
        var handle: [String: Any] = [:]
        first.snapshot(into: &handle)

        let second = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await second.restore(from: handle)
        await seat(second)
        XCTAssertEqual(second.mode, .document, "the scene standeth again")
        XCTAssertEqual(second.openedDocumentId, 7, "the same document identity")
        XCTAssertEqual(second.openedTitle, "Archive guide")
        XCTAssertEqual(second.passages.count, 2, "the same passages")
        XCTAssertEqual(second.openedSource, fake.sourceTable[7], "the same provenance")

        var searchHandle: [String: Any] = [:]
        let third = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await third.loadDocuments()
        third.onQueryChanged("water")
        await third.search()
        await seat(third)
        third.snapshot(into: &searchHandle)
        let fourth = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await fourth.restore(from: searchHandle)
        await seat(fourth)
        XCTAssertEqual(fourth.searchedQuery, "water", "the search scene recreateth its identity")
        XCTAssertEqual(fourth.passages.count, 1, "and its results")
    }

    /// W11 -- the scroll anchor is noted and remembered through recreation.
    func testTheScrollAnchorIsNoteAndRemembered() async throws {
        let fake = FakeReader()
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        scene.noteScroll(documentId: 7, passageId: 12)
        var handle: [String: Any] = [:]
        scene.snapshot(into: &handle)
        let restored = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await restored.restore(from: handle)
        await seat(restored)
        XCTAssertEqual(restored.scrollAnchor, ArchiveScrollAnchor(documentId: 7, passageId: 12),
                       "where the reader stood is carried through recreation")
    }

    /// W12 -- THE REAL ROAD: repository, library, model and scene over the
    /// FROZEN DDL executed verbatim. The provenance columns travel the
    /// projection; the unheard answereth nil; the defaced bytes refuse the
    /// empty masquerade -- the card's falsifier end to end upon the true
    /// engine, beyond the reach of any fake.
    func testTheRealRoadProjectethProvenanceFromTheFrozenColumns() async throws {
        _ = try makeArchive()
        let (archive, library, model, scene) = composeTrio()
        await scene.loadDocuments()
        await seat(scene)
        XCTAssertEqual(scene.phase, .ready, "the real road armeth ready")
        let top = scene.documents.first
        XCTAssertEqual(top?.title, "Water purification in the field", "critical first")
        XCTAssertEqual(top?.sourceId, "src-a", "the source travelleth from the frozen column")
        XCTAssertEqual(top?.revision, "r1", "the revision likewise")
        await scene.open(document: scene.documents[0])
        await seat(scene)
        XCTAssertEqual(scene.openedSource,
                       ArchiveSourceMetadata(documentId: 1, title: "Water purification in the field",
                                             sourceId: "src-a", licence: "CC0", revision: "r1",
                                             isCritical: true),
                       "the whole provenance projection, from the real SELECT")
        let unheard = try archive.sourceMetadataChecked(documentId: 404)
        XCTAssertNil(unheard, "an unheard document nameth no provenance")
        archive.close()
        await library.close()

        // the defaced twin: sound header, defaced body -- the fresh trio must
        // tell Unavailable, and the scene must refuse the empty masquerade
        _ = try makeArchive { $0.poisonBodyPages = true }
        let (archive2, library2, model2, scene2) = composeTrio()
        await scene2.loadDocuments()
        await seat(scene2)
        guard case .unavailable(let cause, let recoverable) = scene2.phase else {
            XCTFail("the defaced archive must be told unavailable, got \(scene2.phase)")
            archive2.close(); await library2.close(); return
        }
        XCTAssertFalse(recoverable, "no retry knocketh upon a defaced wall")
        XCTAssertFalse(cause.isEmpty, "the cause must be named")
        scene2.onQueryChanged("water")
        await scene2.search()
        await seat(scene2)
        XCTAssertTrue(scene2.phase.isUnavailable,
                     "the search upon the defaced abideth unavailable -- the falsifier end to end, got \(scene2.phase)")
        archive2.close()
        await library2.close()
    }

    /// W13 -- dismissal striketh out the in-flight petition; the late
    /// arrival publisheth nothing at all.
    func testDismissalStrikethOutTheInFlightPetition() async throws {
        let fake = FakeReader()
        let scene = ArchiveSceneModel(reading: fake, model: ArchiveReaderModel(library: fake))
        await scene.loadDocuments()
        await seat(scene)
        XCTAssertEqual(scene.phase, .ready, "the browse came home first")
        fake.pause(on: "water")
        scene.onQueryChanged("water")
        let wanderer = Task { await scene.search() }
        for _ in 0..<80 { await Task.yield() }
        scene.dismiss()                                // the view goeth away mid-flight
        fake.releaseAll(raise: nil)
        _ = await wanderer.value
        for _ in 0..<300 { await Task.yield() }
        XCTAssertEqual(scene.phase, .loading,
                       "the dismissed road publisheth nothing; the view standeth as the search left it")
        XCTAssertNil(scene.error, "and no woe is told of the stricken petition")
    }

    /// W14 -- the typed phases report themselves at the scene, and the
    /// reason of the absent nameth the file that is not there.
    func testTypedPhasesReportThemselvesAtTheScene() async throws {
        let absent = FakeReader()
        absent.availability = .missing("the file archive_missing.db is not there")
        let scene = ArchiveSceneModel(reading: absent, model: ArchiveReaderModel(library: absent))
        await scene.loadDocuments()
        await seat(scene)
        if case .unavailable(let reason, _) = scene.phase {
            XCTAssertTrue(reason.contains("archive_missing.db"),
                          "the banner nameth the file that is not there, got \(reason)")
        } else {
            XCTFail("expected unavailable, got \(scene.phase)")
        }
        let ready = FakeReader()
        let readyScene = ArchiveSceneModel(reading: ready, model: ArchiveReaderModel(library: ready))
        XCTAssertEqual(readyScene.phase, .loading, "the fresh scene standeth at loading")
        await readyScene.loadDocuments()
        await seat(readyScene)
        XCTAssertEqual(readyScene.phase, .ready, "and resteth ready")
    }

    /// W15 -- the sealed fakes compile with the availability default: a
    /// minimal conformer, asked of the stock, reporteth ready.
    func testTheSealedFakesCompileWithTheAvailabilityDefault() async throws {
        let minimal = MinimalReader()
        XCTAssertTrue(minimal.availability.isReady,
                      "the extension default reporteth ready, that sealed conformations move on")
        let scene = ArchiveSceneModel(reading: minimal, model: ArchiveReaderModel(library: minimal))
        await scene.loadDocuments()
        await seat(scene)
        XCTAssertTrue(scene.phase == .noResults || scene.phase == .ready,
                      "the minimal road answereth an honest tale, got \(scene.phase)")
    }

    // GS-ARCHIVE-005 -- THE RED ARM (corrected): the RESTORED door must carry the search identity
    // into the road it returneth to. THE HANDLE MUST CARRY `openedDocumentId`, or `restore` falls
    // back to `loadDocuments()` and `back()` never entereth the `returnScene` road at all -- the
    // first version of this arm omitted it and proved nothing (it was green on BOTH revisions).
    func testRestoreIntoAnOpenDocumentCarriethTheSearchIdentityIntoTheReturnRoad() async throws {
        let fake = FakeReader()
        let model = ArchiveReaderModel(library: fake)
        let scene = ArchiveSceneModel(reading: fake, model: model)
        let searched = "water"
        let handle: [String: Any] = ["mode": "document", "query": searched,
                                     "searchedQuery": searched,
                                     "openedDocumentId": Int64(7),
                                     "openedTitle": "Archive guide",
                                     "anchorDocument": Int64(7), "anchorPassage": Int64(11)]
        await scene.restore(from: handle)
        XCTAssertEqual(scene.mode, .document,
                       "the arm must restore INTO an open document, or it testeth another road")
        scene.back()
        XCTAssertEqual(scene.query, searched,
                       "a reader returning from a RESTORED document must find its query: the old "
                       + "restore built an EMPTY return scene (GS-ARCHIVE-005)")
        XCTAssertEqual(scene.searchedQuery, searched,
                       "and the published identity of the search it returned to")
    }

}
