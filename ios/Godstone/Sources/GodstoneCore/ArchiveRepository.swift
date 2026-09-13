import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ArchiveDocument: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let title: String
    public let domain: String
    public let isCritical: Bool
    /* T50 (s17): the provenance projection of the frozen documents table --
     * defaulted, that every sealed four-argument construction remaineth
     * lawful (the android ArchiveDocument keepeth the same pace). */
    public let sourceId: String
    public let revision: String

    public init(id: Int64, title: String, domain: String, isCritical: Bool,
                sourceId: String = "", revision: String = "") {
        self.id = id
        self.title = title
        self.domain = domain
        self.isCritical = isCritical
        self.sourceId = sourceId
        self.revision = revision
    }
}

/// The provenance projection shown when a document is opened whole (T50:
/// 'source/revision display'). A separate projection, that the sealed
/// ArchiveDocument equality abideth undisturbed.
public struct ArchiveSourceMetadata: Sendable, Equatable {
    public let documentId: Int64
    public let title: String
    public let sourceId: String
    public let licence: String
    public let revision: String
    public let isCritical: Bool

    public init(documentId: Int64, title: String, sourceId: String, licence: String,
                revision: String, isCritical: Bool) {
        self.documentId = documentId
        self.title = title
        self.sourceId = sourceId
        self.licence = licence
        self.revision = revision
        self.isCritical = isCritical
    }
}

public struct ArchivePassage: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let documentId: Int64
    public let documentTitle: String
    public let domain: String
    public let section: String
    public let text: String
    public let score: Double

    public init(id: Int64, documentId: Int64, documentTitle: String,
                domain: String, section: String, text: String, score: Double = 0) {
        self.id = id
        self.documentId = documentId
        self.documentTitle = documentTitle
        self.domain = domain
        self.section = section
        self.text = text
        self.score = score
    }
}

/// Read-only handle to the immutable on-device Archive.
///
/// Browsing and FTS5 search never load llama.cpp or an embedding model. This is
/// the system's last surviving capability when inference and every radio fail.
///
/// T48 (s17): an opened file is NOT a usable archive, and an empty list is NOT
/// an error. The open performeth a full validation and the verdict is carried
/// in `availability`; every checked query face saith which of the woes it met,
/// where the old road returned []. The array-returning faces below are kept
/// for the sealed call sites (AppContainer's browse, the RAG retriever) and are
/// documented shims that collapse failures to [] exactly as before -- the lie
/// is preserved for them, not extended to the new road.
public final class ArchiveRepository: @unchecked Sendable {
    private let handle: OpaquePointer?
    private let lock = NSLock()
    private var closed = false

    /// The open-time verdict. A repository that is not `.ready` refuseth
    /// service and nameth its cause; it never serveth the empty lie.
    public let availability: ArchiveAvailability

    /// The schema this build understandeth, as archive_meta records it.
    public static let schemaVersion = "3"
    /// Tables the read road cannot walk without.
    public static let requiredTables = ["documents", "chunks", "chunks_fts", "archive_meta"]

    public init(databaseName: String, expectedTier: Tier? = nil) {
        let opened = Self.openAndValidate(databaseName: databaseName, expectedTier: expectedTier)
        self.handle = opened.handle
        self.availability = opened.availability
    }

    deinit {
        // The one close of the hand that opened, guarded against the explicit
        // close() so a released repository is never closed twice.
        if !closed, let db = handle { sqlite3_close_v2(db) }
    }

    /// Release the native handle now, not whenever the pool fancy of ARC
    /// decideth. Idempotent; after a close the checked faces refuse service
    /// (as they do for any unready road) and the bytes on disk abide whole.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        if let db = handle { sqlite3_close_v2(db) }
        closed = true
    }

    public var isAvailable: Bool { availability.isReady }

    /// The provenance line of a ready archive; the verdict's own tale otherwise.
    public var originDescription: String {
        switch availability {
        case .ready(let origin): return origin
        default: return availability.reasonForDisplay
        }
    }

    // MARK: - checked faces (the T48 road: failures are told, not swallowed)

    public func listDocumentsChecked(domain: String? = nil) throws -> [ArchiveDocument] {
        // T50 (s17): the projection carriageth the frozen source_id and
        // revision columns whole -- the display shall speak provenance.
        var sql = "SELECT document_id, title, domain, is_critical, source_id, revision FROM documents"
        if domain != nil { sql += " WHERE domain = ?" }
        sql += " ORDER BY is_critical DESC, domain, title"
        let filter = domain
        return try run(sql, binds: filter.map { d in
            { stmt in
                d.withCString { ptr in
                    _ = sqlite3_bind_text(stmt, 1, ptr, -1, sqliteTransient)
                }
            }
        }) { stmt in
            ArchiveDocument(
                id: sqlite3_column_int64(stmt, 0),
                title: columnString(stmt, 1),
                domain: columnString(stmt, 2),
                isCritical: sqlite3_column_int(stmt, 3) != 0,
                sourceId: columnString(stmt, 4),
                revision: columnString(stmt, 5)
            )
        }
    }

    /// T50 (s17): the whole provenance projection of one document, or nil
    /// when the document is unheard of. Failures are told, not swallowed.
    public func sourceMetadataChecked(documentId: Int64) throws -> ArchiveSourceMetadata? {
        let sql = "SELECT document_id, title, source_id, licence, revision, is_critical "
            + "FROM documents WHERE document_id = ?"
        let rows = try run(sql, binds: { stmt in sqlite3_bind_int64(stmt, 1, documentId) }) { stmt in
            ArchiveSourceMetadata(
                documentId: sqlite3_column_int64(stmt, 0),
                title: columnString(stmt, 1),
                sourceId: columnString(stmt, 2),
                licence: columnString(stmt, 3),
                revision: columnString(stmt, 4),
                isCritical: sqlite3_column_int(stmt, 5) != 0
            )
        }
        return rows.first
    }

    /// The compat shim: the checked face's woe collapseth to nil, as the old
    /// roads taught. The scene useth this; the court proveth the checked.
    public func sourceMetadata(documentId: Int64) -> ArchiveSourceMetadata? {
        (try? sourceMetadataChecked(documentId: documentId)) ?? nil
    }

    public func listDomainsChecked() throws -> [String] {
        try run("SELECT DISTINCT domain FROM documents ORDER BY domain") { stmt in
            columnString(stmt, 0)
        }
    }

    public func documentTitlesChecked(criticalOnly: Bool = false) throws -> [String] {
        let sql = "SELECT title FROM documents"
            + (criticalOnly ? " WHERE is_critical = 1" : "")
            + " ORDER BY is_critical DESC, domain, title"
        return try run(sql) { stmt in columnString(stmt, 0) }
    }

    public func passagesChecked(documentId: Int64) throws -> [ArchivePassage] {
        let sql = """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text
            FROM chunks c JOIN documents d ON d.document_id = c.document_id
            WHERE c.document_id = ? ORDER BY c.ordinal
            """
        return try run(sql, binds: { stmt in sqlite3_bind_int64(stmt, 1, documentId) }) { stmt in
            passage(stmt)
        }
    }

    /// The bounded, quarantined search. A refused or empty build matcheth
    /// nothing and crieth nothing: it returneth [] without approaching the
    /// index. A genuine SQL woe raiseth ArchiveError.queryFailed naming the
    /// errno and the errmsg -- never the silent empty list of the old road.
    public func searchChecked(_ query: String, limit: Int = 40) throws -> [ArchivePassage] {
        switch ArchiveSearchQuery.build(query) {
        case .empty, .refused:
            return []
        case .ready(let match, _):
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text,
                       bm25(chunks_fts) AS rank
                FROM chunks_fts
                JOIN chunks c ON c.chunk_id = chunks_fts.rowid
                JOIN documents d ON d.document_id = c.document_id
                WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?
                """
            let bound = Int64(ArchiveSearchQuery.bound(limit))
            return try run(sql, binds: { stmt in
                match.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
                sqlite3_bind_int64(stmt, 2, bound)
            }) { stmt in
                passage(stmt, score: -sqlite3_column_double(stmt, 6))
            }
        }
    }

    /// The integrity of the opened archive, in the engine's own words.
    public func integrityReport() throws -> String {
        try run("PRAGMA integrity_check") { stmt in columnString(stmt, 0) }
            .first ?? "no answer"
    }

    /// The version of the very stock the handle walketh upon.
    public func versionString() throws -> String {
        try run("SELECT sqlite_version()") { stmt in columnString(stmt, 0) }
            .first ?? (String(cString: sqlite3_libversion()) ?? "unknown")
    }

    // MARK: - compat shims (sealed call sites; the old collapse preserved verbatim)

    public func listDocuments(domain: String? = nil) -> [ArchiveDocument] {
        (try? listDocumentsChecked(domain: domain)) ?? []
    }

    public func listDomains() -> [String] {
        (try? listDomainsChecked()) ?? []
    }

    public func passages(documentId: Int64) -> [ArchivePassage] {
        (try? passagesChecked(documentId: documentId)) ?? []
    }

    public func search(_ query: String, limit: Int = 40) -> [ArchivePassage] {
        (try? searchChecked(query, limit: limit)) ?? []
    }

    // MARK: - RAG-facing operations (unchanged road; internal to the isle)

    func searchLexical(_ query: String, limit: Int) -> [RetrievedChunk] {
        search(query, limit: limit).map {
            RetrievedChunk(chunkId: $0.id, documentId: $0.documentId,
                           documentTitle: $0.documentTitle, section: $0.section,
                           domain: $0.domain, text: $0.text, score: $0.score)
        }
    }

    func searchSemantic(vector query: [Float], limit: Int) -> [RetrievedChunk] {
        var scored: [(Int64, Double)] = []
        for (id, blob) in allVectors() { scored.append((id, cosineInt8(query, blob))) }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).compactMap { loadChunk(id: $0.0, score: $0.1) }
    }

    func allChunks() -> [RetrievedChunk] {
        withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, c.section, d.domain, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            var out: [RetrievedChunk] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(RetrievedChunk(
                    chunkId: sqlite3_column_int64(stmt, 0),
                    documentId: sqlite3_column_int64(stmt, 1),
                    documentTitle: columnString(stmt, 2),
                    section: columnString(stmt, 3),
                    domain: columnString(stmt, 4),
                    text: columnString(stmt, 5),
                    score: 0
                ))
            }
            return out
        } ?? []
    }

    func loadChunk(id: Int64, score: Double) -> RetrievedChunk? {
        withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, c.section, d.domain, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                WHERE c.chunk_id = ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return nil
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return RetrievedChunk(
                chunkId: sqlite3_column_int64(stmt, 0),
                documentId: sqlite3_column_int64(stmt, 1),
                documentTitle: columnString(stmt, 2),
                section: columnString(stmt, 3),
                domain: columnString(stmt, 4),
                text: columnString(stmt, 5),
                score: score
            )
        } ?? nil
    }

    private func allVectors() -> [(Int64, Data)] {
        withDatabase { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT chunk_id, vec FROM vectors", -1,
                                     &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            var out: [(Int64, Data)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(stmt, 1))
                if let bytes = sqlite3_column_blob(stmt, 1), count > 0 {
                    out.append((sqlite3_column_int64(stmt, 0), Data(bytes: bytes, count: count)))
                }
            }
            return out
        } ?? []
    }

    private func cosineInt8(_ query: [Float], _ blob: Data) -> Double {
        guard !query.isEmpty, query.count == blob.count else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in query.indices {
            let a = Double(query[i])
            let b = Double(Int8(bitPattern: blob[i])) / 127.0
            dot += a * b; normA += a * a; normB += b * b
        }
        let denom = (normA * normB).squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    // MARK: - the one true runner (single finalize; step AND finalize watched)

    /// Prepare, bind, step, finalize -- exactly once each. The step rc is
    /// kept, the finalize rc is kept: the probe of the host stock proved the
    /// error of a refused write walketh out through the FINALIZE return, not
    /// the step, so both must be watched or the woe goeth untold.
    private func run<T>(_ sql: String,
                        binds: ((OpaquePointer?) -> Void)? = nil,
                        row: (OpaquePointer?) -> T?) throws -> [T] {
        guard availability.isReady, !closed, let db = handle else { throw availability.asArchiveError() }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let why = Self.describe(db)
            sqlite3_finalize(stmt)
            throw ArchiveError.queryFailed("\(why) [prepare \(Self.ellipsis(sql))]")
        }
        binds?(stmt)
        var out: [T] = []
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            if let value = row(stmt) { out.append(value) }
            step = sqlite3_step(stmt)
        }
        let fin = sqlite3_finalize(stmt)
        if step != SQLITE_DONE {
            throw ArchiveError.queryFailed("\(Self.describe(db)) [step \(step) \(Self.ellipsis(sql))]")
        }
        if fin != SQLITE_OK {
            throw ArchiveError.queryFailed("\(Self.describe(db)) [finalize \(fin) \(Self.ellipsis(sql))]")
        }
        return out
    }

    private func withDatabase<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let db = handle else { return nil }
        return body(db)
    }

    private func passage(_ stmt: OpaquePointer?, score: Double = 0) -> ArchivePassage {
        ArchivePassage(
            id: sqlite3_column_int64(stmt, 0),
            documentId: sqlite3_column_int64(stmt, 1),
            documentTitle: columnString(stmt, 2),
            domain: columnString(stmt, 3),
            section: columnString(stmt, 4),
            text: columnString(stmt, 5),
            score: score
        )
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: value)
    }

    // MARK: - the open that dareth not speak its name falsely

    private static func openAndValidate(databaseName: String,
                                        expectedTier: Tier?) -> (handle: OpaquePointer?,
                                                                  availability: ArchiveAvailability) {
        func refuse(_ db: OpaquePointer?, _ why: ArchiveAvailability) -> (OpaquePointer?, ArchiveAvailability) {
            if let db { sqlite3_close_v2(db) }
            return (nil, why)
        }
        guard let path = resolveDatabasePath(databaseName: databaseName) else {
            return refuse(nil, .missing("no archive named \(databaseName) was found in the bundle nor in the application-support archives directory"))
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let why = db.map { String(cString: sqlite3_errmsg($0)) ?? "?" } ?? "open refused"
            return refuse(db, .corrupt("the file at \(path) could not be opened read-only: \(why)"))
        }
        guard let handle = db else {
            return refuse(nil, .readFailure("the open answered with a null handle"))
        }
        // The seals of the read-only road. Both must answer, or the way is
        // blocked and no claim of soundness may be made.
        for pragma in ["PRAGMA query_only = ON", "PRAGMA mmap_size = 268435456"] {
            let rc = sqlite3_exec(handle, pragma, nil, nil, nil)
            if rc != SQLITE_OK {
                let why = String(cString: sqlite3_errmsg(handle)) ?? "rc \(rc)"
                return refuse(handle, .readFailure("the seal \(pragma) would not seat: \(why)"))
            }
        }
        // The required tables.
        for name in requiredTables {
            if !hasTable(handle, name) {
                return refuse(handle, .incompatible(ArchiveError.noSuchTable(name).localizedDescription))
            }
        }
        // The schema covenant.
        let schema = scalarOne(handle, "SELECT value FROM archive_meta WHERE key = 'schema_version'")
        guard let schema else {
            return refuse(handle, .incompatible(ArchiveError.schemaVersion(
                "archive_meta beareth no schema_version key").localizedDescription))
        }
        guard schema == schemaVersion else {
            return refuse(handle, .incompatible(ArchiveError.schemaVersion(
                "found \(schema); this build understandeth \(schemaVersion)").localizedDescription))
        }
        // The tier pairing: the file named must be the file the tier owns.
        if let expectedTier, databaseName != expectedTier.archiveDatabaseName {
            return refuse(handle, .incompatible(
                "the file \(databaseName) is not the database of tier "
                + "\(String(describing: expectedTier)) (\(expectedTier.archiveDatabaseName) was named)"))
        }
        // The counts: a husk with no rows is a corrupt archive, whatever
        // well-shaped tables it carrieth.
        if countScalar(handle, "SELECT COUNT(*) FROM documents") == 0 {
            return refuse(handle, .corrupt("the archive holdeth no documents"))
        }
        if countScalar(handle, "SELECT COUNT(*) FROM chunks") == 0 {
            return refuse(handle, .corrupt("the archive holdeth no chunks"))
        }
        // The engine's own cry.
        let report = scalarOne(handle, "PRAGMA integrity_check") ?? "no answer"
        if report != "ok" {
            return refuse(handle, .corrupt(ArchiveError.integrity(report).localizedDescription))
        }
        // The FTS5 canary, sung on a fresh :memory: road of the very same
        // stock -- an honest probe need not defile the thing it proveth.
        if let fault = ftsCanaryFault() {
            return refuse(handle, .incompatible(ArchiveError.ftsUnavailable(fault).localizedDescription))
        }
        let stock = String(cString: sqlite3_libversion()) ?? "unknown"
        return (handle, .ready(origin: "file \(path) | sqlite \(stock) | read-only"))
    }

    private static func hasTable(_ db: OpaquePointer, _ name: String) -> Bool {
        scalarOne(db, "SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name = ?",
                  bind: name) != nil
    }

    private static func scalarOne(_ db: OpaquePointer, _ sql: String, bind: String? = nil) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return nil
        }
        if let bind { bind.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) } }
        var out: String?
        if sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) {
            out = String(cString: value)
        }
        sqlite3_finalize(stmt)
        return out
    }

    private static func countScalar(_ db: OpaquePointer, _ sql: String) -> Int {
        scalarOne(db, sql).flatMap { Int($0) } ?? -1
    }

    /// The canary singeth the frozen tokenizer string verbatim, as the
    /// builder writeth it into content/db/schema.sql.
    private static func ftsCanaryFault() -> String? {
        var mem: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &mem, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            return "the :memory: road could not be opened"
        }
        defer { if let mem { sqlite3_close_v2(mem) } }
        guard let mem else { return "the :memory: road answered with a null handle" }
        let verses = [
            "CREATE VIRTUAL TABLE t48_canary USING fts5(body, tokenize=\"porter unicode61 remove_diacritics 2\", prefix=\"2 3 4\")",
            "INSERT INTO t48_canary VALUES('generated generators generate electricity')",
        ]
        for verse in verses {
            if sqlite3_exec(mem, verse, nil, nil, nil) != SQLITE_OK {
                let why = String(cString: sqlite3_errmsg(mem)) ?? "?"
                return "\(ellipsis(verse)) cried: \(why)"
            }
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(mem, "SELECT rowid FROM t48_canary WHERE t48_canary MATCH 'generate'",
                                 -1, &stmt, nil) == SQLITE_OK else {
            let why = String(cString: sqlite3_errmsg(mem)) ?? "?"
            sqlite3_finalize(stmt)
            return "the stem match would not prepare: \(why)"
        }
        let sang = sqlite3_step(stmt) == SQLITE_ROW
        let fin = sqlite3_finalize(stmt)
        if sang == false || fin != SQLITE_OK {
            return "the stem match 'generate' found nobody"
        }
        return nil
    }

    private static func describe(_ db: OpaquePointer?) -> String {
        guard let db else { return "no handle" }
        let code = sqlite3_errcode(db)
        let msg = String(cString: sqlite3_errmsg(db)) ?? "?"
        return "errno \(code) errmsg \(msg)"
    }

    private static func ellipsis(_ text: String) -> String {
        text.count > 64 ? String(text.prefix(64)) + "..." : text
    }

    private static func resolveDatabasePath(databaseName: String) -> String? {
        let ns = databaseName as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension.isEmpty ? "db" : ns.pathExtension
        if let bundled = Bundle.main.path(forResource: base, ofType: ext) { return bundled }
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first {
            let url = dir.appendingPathComponent("archives").appendingPathComponent(databaseName)
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
        }
        return Bundle.main.path(forResource: databaseName, ofType: nil)
    }
}
