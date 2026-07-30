// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// Hybrid retrieval over the read-only Archive.
///
/// A thin wrapper around `ArchiveRepository` that exposes the two search modes
/// the RAG pipeline needs:
///   1. BM25 lexical search via FTS5 (`searchLexical`)
///   2. int8 cosine similarity over stored vectors (`searchSemantic`), with the
///      query embedded by an injected async closure so this module stays free of
///      the on-device model.
///
/// Reciprocal Rank Fusion happens in `RagPipeline`, not here; the retriever
/// only returns the two ranked candidate lists.
///
/// Mirrors `io.godstone.llm.rag.Retriever` (Android). Signatures match the
/// call sites in `RagPipeline.swift` exactly.
public final class Retriever {

    private let archive: ArchiveRepository

    public init(archive: ArchiveRepository) {
        self.archive = archive
    }

    /// FTS5 + BM25 lexical search. Returns ranked chunks (best first).
    public func searchLexical(_ query: String, limit: Int) throws -> [RetrievedChunk] {
        archive.searchLexical(query, limit: limit)
    }

    /// Embed the query via `embedder`, then brute-force cosine search over the
    /// archive's int8 vectors. If the embedder returns nil, there is nothing to
    /// search against; return an empty list rather than guessing.
    public func searchSemantic(_ query: String,
                               embedder: (String) async -> [Float]?,
                               limit: Int) async throws -> [RetrievedChunk] {
        guard let vector = await embedder(query) else { return [] }
        guard !vector.isEmpty else { return [] }
        return archive.searchSemantic(vector: vector, limit: limit)
    }
}
