import XCTest
import Foundation
import SQLite3
@testable import GodstoneCore

/* ============================================================================
 T48 (s17) -- the designated regression court for the iOS Archive read road.

 The fixtures are REAL archives, built by executing the FROZEN
 content/db/schema.sql and content/db/indexes.sql VERBATIM through the very
 SQLite3 module the production handle links -- court and builder share one
 truth about the shape of the data. The splitter of the script is quote- and
 comment-literate: the frozen DDL hideth a semicolon in prose ("people in bad
 light; the ingester warns above 9") and another within the tokenizer string;
 a naive split is the lie the sealed Android twin already caught (T47), so
 this court is born literate.

 The host leg proves the road over the same SQL stock the device links
 (measured: 3.51.0); the instrumented device leg remaineth open for
 T73-T75 -- no CoreBluetooth or Data Protection behaviour is claimed here.
 ============================================================================ */

@MainActor
final class ReadinessT48Tests: XCTestCase {
    private static let tierName = Tier.light.archiveDatabaseName   // archive_light.db

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

    // MARK: - finding the frozen DDL (walk upward from the test run's cwd)

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

    private enum TestError: Error { case fixtureNotFound(String), noSupportDirectory }

    // MARK: - the literate splitter (T47's lesson, Swifted)

    /// Split a SQL script on semicolons that lie outside single-quoted,
    /// double-quoted, line-comment and block-comment regions; '' within a
    /// string is an escape and hideth no boundary.
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
            case (.singleQuote, "'") where peek == "'":   // '' is an escaped quote
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

    // MARK: - the fixture: one real archive, knobs for the wounded variants

    private struct FixtureKnobs {
        var withRows = true
        var schemaVersion: String? = "3"
        var dropFts = false            // the index never was built
        var ftsAsPlainTable = false    // the index is a lie: a plain table of the name
        var poisonBodyPages = false    // sound header, 0xFF from page 2 onward
        var reservoir = false          // 250 searchable chunks for the page bound
        var greatPassage = false       // one ~200k-character chunk, whole
    }

    /// Build (or rebuild) the tier's archive under the application-support
    /// archives directory, where the production resolver looketh.
    private func makeArchive(named name: String = ReadinessT48Tests.tierName,
                              _ shape: (inout FixtureKnobs) -> Void = { _ in }) throws -> URL {
        var knobs = FixtureKnobs()
        shape(&knobs)
        let url = (try fixturesDirectory).appendingPathComponent(name, isDirectory: false)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(atPath: url.path)
            if fm.fileExists(atPath: url.path) {
                // A sibling's repository still holdeth the file busy (ARC's
                // timing is not a schedule). Rename it out of the road --
                // renaming a held file is lawful -- and best-effort remove.
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

        var schemaStatements = splitStatements(schema)
        if knobs.dropFts || knobs.ftsAsPlainTable {
            // the wounded variants never let the true index be built at all
            schemaStatements = schemaStatements.filter {
                $0.uppercased().contains("VIRTUAL TABLE CHUNKS_FTS") == false
            }
        }
        execScript(db, schemaStatements.joined(separator: "; "), from: "schema.sql")

        if knobs.withRows {
            insert(db, "INSERT INTO documents (document_id, title, domain, source_id, licence, revision, tier_min, reading_level, is_critical) VALUES (1, 'Water purification in the field', 'water', 'src-a', 'CC0', 'r1', 'LIGHT', 8, 1)")
            insert(db, "INSERT INTO documents (document_id, title, domain, source_id, licence, revision, tier_min, reading_level, is_critical) VALUES (2, 'Power grid outage response', 'power', 'src-b', 'CC0', 'r1', 'LIGHT', 8, 0)")
            insert(db, "INSERT INTO documents (document_id, title, domain, source_id, licence, revision, tier_min, reading_level, is_critical) VALUES (3, 'Wildlife identification', 'wildlife', 'src-c', 'CC0', 'r1', 'LIGHT', 8, 0)")
            insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (11, 1, 1, 'Boiling', 'Bring water to a rolling boil for one full minute to purify it safely', 14)")
            insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (12, 1, 2, 'Chemical', 'Two drops of bleach per litre of clear water rest thirty minutes', 12)")
            insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (21, 2, 1, 'Isolation', 'Cut the mains power before touching any fallen line apparatus', 11)")
            if knobs.reservoir {
                for n in 0..<250 {
                    insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (\(100 + n), 2, \(2 + n), 'Reservoir \(n)', 'reservoir marker station \(n) power grid telemetry reading', 8)")
                }
            }
            if knobs.greatPassage {
                let verse = "quartz drizzle forecast "
                let text = String(repeating: verse, count: 200_000 / verse.count + 1)
                insert(db, "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) VALUES (900, 3, 1, 'The Great Passage', '\(text)', 40000)")
                greatPassageLength = text.count
            }
        }
        if let schemaVersion = knobs.schemaVersion {
            insert(db, "INSERT INTO archive_meta (key, value) VALUES ('schema_version', '\(schemaVersion)')")
            insert(db, "INSERT INTO archive_meta (key, value) VALUES ('built_by', 't48-court')")
        }
        if knobs.ftsAsPlainTable {
            // The index is a lie: the name is there, the engine is not.
            execScript(db, "CREATE TABLE chunks_fts (rowid_hack INTEGER)", from: "knob")
        } else if knobs.dropFts == false {
            var indexStatements = splitStatements(indexes)
            if knobs.withRows == false || knobs.ftsAsPlainTable {
                // no true index means no rebuild, no merge: those commands
                // address the virtual table and would cry over the plain one
                indexStatements = indexStatements.filter {
                    let upper = $0.uppercased()
                    return upper.contains("CHUNKS_FTS") == false
                }
            }
            execScript(db, indexStatements.joined(separator: "; "), from: "indexes.sql")
        }
        if knobs.poisonBodyPages {
            // A sound header and a sound master page; every page from page 2
            // on is defaced -- the tables probe (which readeth sqlite_master,
            // page 1) and the counts passe; only the integrity walk can cry.
            // (the defer above performeth the one close of this handle)
            let bytes = try Data(contentsOf: url)
            var poisoned = bytes
            let pageSize = 4096
            if poisoned.count > pageSize * 2 {
                for j in (pageSize * 2)..<min(poisoned.count, pageSize * 2 + 8) {
                    poisoned[j] = 0xFF
                }
            }
            try poisoned.write(to: url, options: Data.WritingOptions.atomic)
            return url    // already closed
        }
        return url
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

    private func openRepository(_ name: String? = nil, expectedTier: Tier? = .light) -> ArchiveRepository {
        ArchiveRepository(databaseName: name ?? ReadinessT48Tests.tierName,
                          expectedTier: expectedTier)
    }

    private var greatPassageLength: Int = 0

    // MARK: - witnesses

    /// W1 -- the probe that maith a real archive ready, in the engine's own words.
    func testTheProbedRealArchiveIsReadyInOwnWords() throws {
        _ = try makeArchive()
        let repository = openRepository()
        defer { repository.close() }
        XCTAssertTrue(repository.isAvailable, "a sound archive must be available, got \(repository.availability.reasonForDisplay)")
        guard case .ready(let origin) = repository.availability else {
            return XCTFail("a sound archive must be .ready, got \(repository.availability.reasonForDisplay)")
        }
        XCTAssertTrue(origin.contains("archive_light.db"), "the origin must name the file, got \(origin)")
        XCTAssertTrue(origin.contains("sqlite 3."), "the origin must name the stock, got \(origin)")
        let version = try repository.versionString()
        XCTAssertTrue(version.hasPrefix("3."), "the stock must be of the 3.x line, got \(version)")
        XCTAssertEqual(try repository.integrityReport(), "ok", "integrity must answer ok")
        let home = try repository.listDocumentsChecked()
        XCTAssertEqual(home.count, 3, "all three documents must come home")
    }

    /// W2 -- THE defect falsified: a file that openeth is not thereby usable.
    /// A sound 100-byte header over defaced pages; the raw open succeedeth
    /// (the old road would have cried 'available' upon the handle alone),
    /// yet the validated repository refuseth and nameth its cause.
    func testRandomBytesUnderASoundHeaderAreNotAnArchive() throws {
        let url = try makeArchive { $0.poisonBodyPages = true }
        // prove the raw open alone would have called this usable
        var raw: OpaquePointer?
        let rawRc = sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        if rawRc == SQLITE_OK, let raw { sqlite3_close_v2(raw) }   // the old face: handle != nil
        let repository = openRepository()
        defer { repository.close() }
        XCTAssertFalse(repository.isAvailable, "a defaced body under a sound header must NOT be served as available")
        guard case .corrupt(let why) = repository.availability else {
            return XCTFail("a defaced body must be cried corrupt, got \(repository.availability.reasonForDisplay)")
        }
        XCTAssertFalse(why.isEmpty, "the cry must carry a cause")
    }

    /// W3 -- the missing asset is named, not guessed.
    func testTheMissingAssetIsNamedNotGuessed() throws {
        let repository = openRepository("t48_never_written_at_all.db", expectedTier: nil)
        defer { repository.close() }
        XCTAssertFalse(repository.isAvailable)
        guard case .missing(let why) = repository.availability else {
            return XCTFail("a file nowhere to be found must be .missing, got \(repository.availability.reasonForDisplay)")
        }
        XCTAssertTrue(why.contains("t48_never_written_at_all.db"), "the reason must name the want, got \(why)")
    }

    /// W4 -- the schema covenant refuseth by two roads: the wrong version,
    /// and the absent key. Plus the table that never was.
    func testTheSchemaCovenantRefusethByTwoRoads() throws {
        _ = try makeArchive { knobs in knobs.schemaVersion = "2" }
        let wrongVersion = openRepository()
        defer { wrongVersion.close() }
        guard case .incompatible(let why) = wrongVersion.availability else {
            return XCTFail("schema_version 2 must be refused as incompatible, got \(wrongVersion.availability.reasonForDisplay)")
        }
        XCTAssertTrue(why.contains("2") && why.contains("3"), "the refusal must tell found from understood, got \(why)")
        wrongVersion.close()

        _ = try makeArchive { knobs in knobs.schemaVersion = nil }
        let absentKey = openRepository()
        defer { absentKey.close() }
        XCTAssertTrue(absentKey.availability.reasonForDisplay.contains("schema_version"),
                      "the absent key must be named, got \(absentKey.availability.reasonForDisplay)")
        absentKey.close()

        _ = try makeArchive { knobs in knobs.dropFts = true }
        let missingIndex = openRepository()
        defer { missingIndex.close() }
        XCTAssertTrue(missingIndex.availability.reasonForDisplay.contains("chunks_fts"),
                      "the missing index must be named, got \(missingIndex.availability.reasonForDisplay)")
        missingIndex.close()
    }

    /// W5 -- the tier and the file must pair, or the pairing is refused.
    func testTheTierAndTheFileMustPair() throws {
        _ = try makeArchive()   // written as archive_light.db...
        let repository = openRepository(expectedTier: .medium)   // ...but medium was named
        defer { repository.close() }
        XCTAssertFalse(repository.isAvailable)
        guard case .incompatible(let why) = repository.availability else {
            return XCTFail("the wrong tier's file must be incompatible, got \(repository.availability.reasonForDisplay)")
        }
        XCTAssertTrue(why.contains("tier"), "the refusal must speak of the tier, got \(why)")
        XCTAssertTrue(why.contains("archive_medium.db"), "the refusal must name the file the tier owns, got \(why)")
    }

    /// W6 -- THE second defect falsified: a query that faileth is told from
    /// a query that findeth nothing. An absent word is an honest empty
    /// list; a lying index raiseth queryFailed, naming the missing engine.
    func testQueryFailureIsNotNoResults() throws {
        // (a) the healthy archive: an absent word is emptiness, not a woe
        _ = try makeArchive()
        let healthy = openRepository()
        defer { healthy.close() }
        let found = try healthy.searchChecked("quuxnotawordinthefrozenway")
        XCTAssertEqual(found.count, 0, "a word nowhere in the index must return the honest empty list")
        healthy.close()   // before the rebuild below, lest the road be held busy

        // (b) the lying index: the name is there, the engine is not
        _ = try makeArchive { knobs in knobs.ftsAsPlainTable = true }
        let wounded = openRepository()
        defer { wounded.close() }
        let browse = try wounded.listDocumentsChecked()   // whole tables answer still
        XCTAssertEqual(browse.count, 3, "browse must still answer while the index lieth")
        do {
            _ = try wounded.searchChecked("power")
            XCTFail("a lying index must raise, not return the empty lie")
        } catch let error as ArchiveError {
            guard case .queryFailed(let why) = error else {
                return XCTFail("the failure must be queryFailed, got \(error)")
            }
            let tale = why.lowercased()
            XCTAssertTrue(tale.contains("chunks") || tale.contains("match") || tale.contains("bm25"),
                        "the cry must name the wounded road, got \(why)")
        }
    }

    /// W7 -- the empty husk: well-shaped tables carrying no rows at all
    /// is a corrupt archive, not a servable one.
    func testTheEmptyHuskIsCorruptNotServable() throws {
        _ = try makeArchive { knobs in knobs.withRows = false }
        let repository = openRepository()
        defer { repository.close() }
        XCTAssertFalse(repository.isAvailable, "a husk with no documents is not an archive")
        XCTAssertTrue(repository.availability.reasonForDisplay.contains("documents"),
                      "the cry must name what is wanting, got \(repository.availability.reasonForDisplay)")
    }

    // MARK: - the token discipline, ported from the WIP and proven

    private actor PausedLibrary: ArchiveReading {
        let started: XCTestExpectation
        private var waiting: [CheckedContinuation<ArchivePage, Error>] = []
        init(started: XCTestExpectation) { self.started = started }
        func read(_ request: ArchiveRequest) async throws -> ArchivePage {
            if request == ArchiveRequest.browse { return ArchivePage.documents([]) }
            return try await withCheckedThrowingContinuation { continuation in
                if self.waiting.isEmpty { self.started.fulfill() }
                self.waiting.append(continuation)
            }
        }
        func arrivedCount() -> Int { waiting.count }
        func complete(_ result: Result<ArchivePage, Error>) {
            guard !waiting.isEmpty else { return }
            let next = waiting.removeFirst()
            next.resume(with: result)
        }
        func releaseAll(_ result: Result<ArchivePage, Error>) {
            let all = waiting
            waiting.removeAll()
            for one in all { one.resume(with: result) }
        }
    }

    /// W8 -- a stale search may not supplant a fresh browse (the WIP's
    /// generation-token discipline, kept verbatim in spirit).
    func testOlderSearchCannotReplaceNewBrowseResult() async throws {
        let started = expectation(description: "search started")
        let library = PausedLibrary(started: started)
        let model = ArchiveReaderModel(library: library)
        let old = Task { await model.load(.search("water")) }
        await fulfillment(of: [started], timeout: 2)
        await model.load(.browse)
        await library.complete(.success(.passages([])))
        _ = await old.value
        XCTAssertEqual(model.state, .loaded(.documents([])),
                       "the superseded search's completion must find the token rotated and publish nothing")
    }

    /// W8b -- nor may a stale FAILURE supplant a fresh success.
    func testOlderSearchFailureCannotReplaceNewBrowseResult() async throws {
        let started = expectation(description: "search started")
        let library = PausedLibrary(started: started)
        let model = ArchiveReaderModel(library: library)
        let old = Task { await model.load(.search("water")) }
        await fulfillment(of: [started], timeout: 2)
        await model.load(.browse)
        await library.complete(.failure(ArchiveError.queryFailed("too late")))
        _ = await old.value
        XCTAssertEqual(model.state, .loaded(.documents([])),
                       "a stale failure must be swallowed by the token, as the stale success is")
    }

    /// W9 -- a cancelled view publisheth nothing, good nor evil.
    func testCancelledViewCannotPublishLateResult() async throws {
        let started = expectation(description: "search started")
        let library = PausedLibrary(started: started)
        let model = ArchiveReaderModel(library: library)
        let work = Task { await model.load(.search("water")) }
        await fulfillment(of: [started], timeout: 2)
        work.cancel()
        await library.complete(.success(.passages([])))
        _ = await work.value
        XCTAssertEqual(model.state, .loading, "after cancellation the state must stay as the load left it")
    }

    // MARK: - bounds

    /// W10 -- the 512/32/200 bounds, each enforced, each reported.
    func testBoundsOfPhraseTermAndPageAreEachEnforcedAndReported() throws {
        switch ArchiveSearchQuery.build(String(repeating: "q", count: 600)) {
        case .refused(let reason):
            XCTAssertTrue(reason.contains("512"), "the phrase refusal must name the bound, got \(reason)")
        default: XCTFail("a 600-character petition must be refused")
        }
        switch ArchiveSearchQuery.build(String(repeating: "w", count: 512) + "x") {
        case .refused(let reason):
            XCTAssertTrue(reason.contains("512"), "just over the bound must still be refused, got \(reason)")
        default: XCTFail("513 characters must be refused")
        }
        guard case .ready(let match, let termCount) = ArchiveSearchQuery.build(
            (1...32).map { "term\($0)" }.joined(separator: " ")) else {
            return XCTFail("exactly 32 terms must pass")
        }
        XCTAssertEqual(termCount, 32)
        XCTAssertTrue(match.hasPrefix("\"term1\""), "the first term must be quarantined, got \(match)")
        XCTAssertTrue(match.hasSuffix("\"term32\""), "the last term must be quarantined, got \(match)")
        switch ArchiveSearchQuery.build((1...33).map { "term\($0)" }.joined(separator: " ")) {
        case .refused(let reason):
            XCTAssertTrue(reason.contains("32"), "the term refusal must name the bound, got \(reason)")
        default: XCTFail("33 terms must be refused")
        }
        XCTAssertEqual(ArchiveSearchQuery.bound(-7), 1, "the floor must hold")
        XCTAssertEqual(ArchiveSearchQuery.bound(9999), 200, "the ceiling must hold")

        _ = try makeArchive { knobs in knobs.reservoir = true }
        let repository = openRepository()
        defer { repository.close() }
        let flood = try repository.searchChecked("power", limit: 9999)
        XCTAssertEqual(flood.count, 200, "a petition of 9999 must be bounded to 200")
        let trickle = try repository.searchChecked("power", limit: 40)
        XCTAssertEqual(trickle.count, 40, "a common petition must be answered in full")
    }

    /// W11 -- the great passage is carried whole: nothing truncates, nothing fabricates.
    func testTheGreatPassageIsCarriedWhole() throws {
        _ = try makeArchive { knobs in knobs.greatPassage = true }
        let repository = openRepository()
        defer { repository.close() }
        let passages = try repository.passagesChecked(documentId: 3)
        XCTAssertEqual(passages.count, 1, "the great passage must come home")
        XCTAssertEqual(passages[0].text.count, greatPassageLength, "nothing may truncate the great passage")
        XCTAssertTrue(passages[0].text.hasPrefix("quartz drizzle forecast "), "the head must be whole")
        XCTAssertTrue(passages[0].text.hasSuffix("quartz drizzle forecast "), "the tail must be whole")
    }

    /// W12 -- fifty dispatches upon a blocked library must not strain the
    /// main actor: the read road runneth on the executor, away from the UI.
    func testMainResponsivenessUnderBlockedLibrary() async throws {
        let started = expectation(description: "first load reached")
        let library = PausedLibrary(started: started)
        let model = ArchiveReaderModel(library: library)
        let began = Date()
        var works: [Task<Void, Never>] = []
        for _ in 0..<50 {
            works.append(Task { await model.load(ArchiveRequest.search("water")) })
        }
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertLessThan(elapsed, 2.0, "fifty dispatches upon a blocked road must not strain the main actor")
        await fulfillment(of: [started], timeout: 5)
        // the cooperative drain: every dispatched petition must find its turn
        var arrived = await library.arrivedCount()
        for _ in 0..<500 where arrived < 50 {
            await Task.yield()
            arrived = await library.arrivedCount()
        }
        XCTAssertEqual(arrived, 50, "every petition must reach the library in its own turn")
        await library.releaseAll(Result<ArchivePage, Error>.success(ArchivePage.passages([])))
        for work in works { _ = await work.value }
    }

    /// W13 -- the typed states report themselves at the library face and
    /// are published unchanged by the reader model.
    func testTypedStatesReportThemelvesAtTheLibraryAndModel() async throws {
        // (a) the missing asset
        var library = ArchiveLibrary(databaseName: "t48_absent_here.db", tier: .light)
        do { _ = try await library.read(.browse); XCTFail("a missing archive must throw") }
        catch let error as ArchiveError {
            guard case .missing(let why) = error else { return XCTFail("must be .missing, got \(error)") }
            XCTAssertTrue(why.contains("t48_absent_here.db"), "the cause must name the file, got \(why)")
        }
        await library.close()
        // (b) a wrong-tier pairing
        _ = try makeArchive()
        library = ArchiveLibrary(databaseName: ReadinessT48Tests.tierName, tier: .medium)
        let model = ArchiveReaderModel(library: library)
        await model.load(ArchiveRequest.browse)
        guard case .failed(let error) = model.state else {
            return XCTFail("the model must publish the failure, got \(model.state)")
        }
        guard case .incompatible(let why) = error else {
            return XCTFail("the published error must be .incompatible, got \(error)")
        }
        XCTAssertTrue(why.contains("tier"), "the publication must speak of the tier, got \(why)")
        await library.close()
    }

    /// W14 -- search results are ranked: the best hit standeth first.
    func testSearchResultsAreRankedBestFirst() throws {
        _ = try makeArchive { knobs in knobs.reservoir = true }
        let repository = openRepository()
        defer { repository.close() }
        let found = try repository.searchChecked("power", limit: 20)
        XCTAssertFalse(found.isEmpty, "the index must answer for 'power'")
        XCTAssertEqual(found.count, 20, "the limit must be kept")
        for a in 1..<found.count {
            XCTAssertGreaterThanOrEqual(found[a - 1].score, found[a].score,
                                        "scores must descend: the best hit standeth first")
        }
        // every score is finite:
        for passage in found { XCTAssertTrue(passage.score.isFinite, "a score must be finite") }
    }

    /// W15 -- the compat shims keep the old collapse verbatim for their
    /// sealed call sites, while the checked faces tell the truth.
    func testCompatShimsPreserveTheOldCollapseVerbatim() throws {
        _ = try makeArchive { knobs in knobs.ftsAsPlainTable = true }
        let wounded = openRepository()
        defer { wounded.close() }
        XCTAssertEqual(wounded.search("power").count, 0,
                       "the sealed array-face must still collapse the woe to [] (documented lie)")
        XCTAssertFalse(wounded.listDocuments().isEmpty, "the sound tables must still answer the old way")
        // and the checked face over the same bytes must cry:
        do {
            _ = try wounded.searchChecked("power")
            XCTFail("the checked face must raise over the lying index, not return the empty lie")
        } catch is ArchiveError {
            // the truth, told at last
        } catch {
            XCTFail("the raised kind must be ArchiveError, got \(error)")
        }
    }
}
