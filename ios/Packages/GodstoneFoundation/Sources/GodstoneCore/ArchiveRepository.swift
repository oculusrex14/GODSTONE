import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ArchiveDocument: Identifiable, Sendable, Hashable {
    public let id: Int64
    public let title: String
    public let domain: String
    public let isCritical: Bool

    public init(id: Int64, title: String, domain: String, isCritical: Bool) {
        self.id = id
        self.title = title
        self.domain = domain
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
public final class ArchiveRepository: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    public init(databaseName: String) {
        handle = Self.openReadOnly(databaseName: databaseName)
        if let db = handle {
            sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil)
        }
    }

    deinit {
        if let db = handle { sqlite3_close_v2(db) }
    }

    public var isAvailable: Bool { handle != nil }

    public func listDocuments(domain: String? = nil) -> [ArchiveDocument] {
        withDatabase { db in
            var sql = "SELECT document_id, title, domain, is_critical FROM documents"
            if domain != nil { sql += " WHERE domain = ?" }
            sql += " ORDER BY is_critical DESC, domain, title"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            if let domain {
                domain.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
            }
            var out: [ArchiveDocument] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ArchiveDocument(
                    id: sqlite3_column_int64(stmt, 0),
                    title: columnString(stmt, 1),
                    domain: columnString(stmt, 2),
                    isCritical: sqlite3_column_int(stmt, 3) != 0
                ))
            }
            return out
        } ?? []
    }

    public func listDomains() -> [String] {
        withDatabase { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                    "SELECT DISTINCT domain FROM documents ORDER BY domain",
                    -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(columnString(stmt, 0)) }
            return out
        } ?? []
    }

    public func passages(documentId: Int64) -> [ArchivePassage] {
        withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                WHERE c.document_id = ? ORDER BY c.ordinal
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, documentId)
            var out: [ArchivePassage] = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(passage(stmt)) }
            return out
        } ?? []
    }

    public func search(_ query: String, limit: Int = 40) -> [ArchivePassage] {
        let fts = sanitiseFts(query)
        guard !fts.isEmpty else { return [] }
        return withDatabase { db in
            let sql = """
                SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text,
                       bm25(chunks_fts) AS rank
                FROM chunks_fts
                JOIN chunks c ON c.chunk_id = chunks_fts.rowid
                JOIN documents d ON d.document_id = c.document_id
                WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt); return []
            }
            defer { sqlite3_finalize(stmt) }
            fts.withCString { sqlite3_bind_text(stmt, 1, $0, -1, sqliteTransient) }
            sqlite3_bind_int64(stmt, 2, Int64(limit))
            var out: [ArchivePassage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(passage(stmt, score: -sqlite3_column_double(stmt, 6)))
            }
            return out
        } ?? []
    }

    // MARK: - RAG-facing operations

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

    private func sanitiseFts(_ value: String) -> String {
        let stripped = value.map { "\"*():^-".contains($0) ? " " : String($0) }.joined()
        return stripped.split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }

    private static func openReadOnly(databaseName: String) -> OpaquePointer? {
        guard let path = resolveDatabasePath(databaseName: databaseName) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close_v2(db); return nil
        }
        return db
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
