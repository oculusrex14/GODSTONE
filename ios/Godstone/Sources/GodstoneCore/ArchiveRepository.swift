// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation
import SQLite3

/// Read-only handle to the bundled Archive SQLite database.
///
/// Mirrors `io.godstone.llm.rag.Retriever` (Android): the same schema
/// (`chunks`, `chunks_fts`, `documents`, `vectors`) and the same query shapes
/// -- FTS5 MATCH with `bm25()` ranking for lexical search, brute-force int8
/// cosine similarity for semantic search. Brute force is deliberate: at LARGE
/// tier it is ~400k int8 dot products over 768 dims, well inside budget, and it
/// removes an entire class of index-corruption failures.
///
/// The database is opened read-only from the app bundle, falling back to
/// Application Support for the LARGE-tier downloaded pack.
public final class ArchiveRepository {

    private var handle: OpaquePointer?

    public init(databaseName: String) {
        self.handle = openReadOnly(databaseName: databaseName)
        if let db = handle {
            sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA mmap_size = 268435456", nil, nil, nil)
        }
    }

    deinit {
        if let db = handle {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Lexical (FTS5 + BM25)

    /// FTS5 MATCH with `bm25(chunks_fts)` ranking, weakest relevance first
    /// (bm25 returns negative values, lower is better -- score is negated so
    /// higher means more relevant, matching the Android convention).
    func searchLexical(_ query: String, limit: Int) -> [RetrievedChunk] {
        guard let db = handle else { return [] }
        let sql = """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text,
                   bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.chunk_id = chunks_fts.rowid
            JOIN documents d ON d.document_id = c.document_id
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let ftsQuery = sanitiseFts(query)
        sqlite3_bind_text(stmt, 1, ftsQuery, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        return collectChunks(from: stmt, scoreColumnIndex: 5, negateScore: true)
    }

    // MARK: - Semantic (int8 cosine)

    /// All (chunk_id, vec) pairs in the archive, for brute-force vector scan.
    func allVectors() -> [(id: Int64, blob: Data)] {
        guard let db = handle else { return [] }
        let sql = "SELECT chunk_id, vec FROM vectors"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var out: [(id: Int64, blob: Data)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let bytes = sqlite3_column_blob(stmt, 1)
            let count = Int(sqlite3_column_bytes(stmt, 1))
            if let bytes, count > 0 {
                out.append((id, Data(bytes: bytes, count: count)))
            }
        }
        return out
    }

    /// Brute-force int8 cosine similarity against every stored vector.
    func searchSemantic(vector query: [Float], limit: Int) -> [RetrievedChunk] {
        var scored: [(id: Int64, score: Double)] = []
        scored.reserveCapacity(256)

        for (id, blob) in allVectors() {
            scored.append((id, cosineInt8(query, blob)))
        }
        scored.sort { $0.score > $1.score }

        let top = scored.prefix(limit)
        return top.compactMap { (id, score) in loadChunk(id: id, score: score) }
    }

    // MARK: - Row loading

    func loadChunk(id chunkId: Int64, score: Double) -> RetrievedChunk? {
        guard let db = handle else { return nil }
        let sql = """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text
            FROM chunks c
            JOIN documents d ON d.document_id = c.document_id
            WHERE c.chunk_id = ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, chunkId)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let rowChunkId = sqlite3_column_int64(stmt, 0)
        let documentId = sqlite3_column_int64(stmt, 1)
        let title = columnString(stmt, 2)
        let domain = columnString(stmt, 3)
        let text = columnString(stmt, 4)
        // The Android schema has no `section` column; section is derived from the
        // document title prefix where the iOS citation UI wants it. Default "".
        return RetrievedChunk(chunkId: rowChunkId,
                              documentId: documentId,
                              documentTitle: title,
                              section: "",
                              domain: domain,
                              text: text,
                              score: score)
    }

    // MARK: - Helpers

    private func collectChunks(from stmt: OpaquePointer?,
                               scoreColumnIndex: Int32,
                               negateScore: Bool) -> [RetrievedChunk] {
        var out: [RetrievedChunk] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunkId = sqlite3_column_int64(stmt, 0)
            let documentId = sqlite3_column_int64(stmt, 1)
            let title = columnString(stmt, 2)
            let domain = columnString(stmt, 3)
            let text = columnString(stmt, 4)
            var score = sqlite3_column_double(stmt, scoreColumnIndex)
            if negateScore { score = -score }
            out.append(RetrievedChunk(chunkId: chunkId,
                                      documentId: documentId,
                                      documentTitle: title,
                                      section: "",
                                      domain: domain,
                                      text: text,
                                      score: score))
        }
        return out
    }

    private func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        if let cstr = sqlite3_column_text(stmt, index) {
            return String(cString: cstr)
        }
        return ""
    }

    /// Strip FTS5 operators so a plain user question cannot become a syntax
    /// error, then OR the remaining terms. Identical to the Android sanitiser.
    private func sanitiseFts(_ q: String) -> String {
        let stripped = q.unicodeScalars.filter {
            !"\"*():^-".contains(Character(String($0)))
        }.map { String($0) }.joined()
        let terms = stripped.split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
        if terms.isEmpty { return "\"\"" }
        return terms.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Cosine similarity between a float query vector and an int8-stored vector,
    /// where each stored byte is divided by 127.0. Same as the Android routine.
    private func cosineInt8(_ query: [Float], _ blob: Data) -> Double {
        let dims = min(query.count, blob.count)
        guard dims > 0 else { return 0.0 }

        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<dims {
            let a = Double(query[i])
            let b = Double(blob[i]) / 127.0
            dot += a * b
            normA += a * a
            normB += b * b
        }
        let denom = (normA * normB).squareRoot()
        return denom == 0.0 ? 0.0 : dot / denom
    }

    // MARK: - Open

    private func openReadOnly(databaseName: String) -> OpaquePointer? {
        let path = resolveDatabasePath(databaseName: databaseName)
        guard let path else { return nil }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return nil
        }
        return db
    }

    private func resolveDatabasePath(databaseName: String) -> String? {
        // Strip a ".db" suffix so Bundle can split resource/ext, but keep the
        // full name available too for Application Support fallback.
        let nsName = (databaseName as NSString)
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension.isEmpty ? "db" : nsName.pathExtension

        if let bundled = Bundle.main.path(forResource: base, ofType: ext) {
            return bundled
        }
        // LARGE tier ships the archive as a downloaded pack in Application Support.
        if let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first {
            let url = dir.appendingPathComponent("archives").appendingPathComponent(databaseName)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        // Last resort: try the full name as a bundle resource with no extension.
        if let bundled = Bundle.main.path(forResource: databaseName, ofType: nil) {
            return bundled
        }
        return nil
    }
}
