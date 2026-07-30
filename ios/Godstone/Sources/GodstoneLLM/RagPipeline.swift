import Foundation
import GodstoneCore

/// Retrieval-Augmented Generation over the Archive.
///
/// This file is the enforcement point for constraint C3: the Oracle NEVER
/// answers from parametric memory. If retrieval returns nothing above the
/// confidence floor, the pipeline refuses and says so. A 0.6B model inventing a
/// paediatric dose is not a quality problem, it is a fatality.
///
/// Policy is identical to the Android RagPipeline in tab 05. The two must not
/// drift, or the same question answers differently on two phones in the same room.
public struct Citation: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let documentTitle: String
    public let section: String
    public let score: Double
}

public enum RagOutcome: Sendable {
    case answer(text: String, citations: [Citation])
    case notInArchive
}

public actor RagPipeline {

    /// Below this fused score we consider the Archive silent on the question.
    /// Tuned on the offline eval set in tab 12; deliberately conservative.
    private static let confidenceFloor: Double = 0.28

    /// Reciprocal-rank-fusion constant. Standard value; combines the FTS5 rank
    /// and the vector rank without either having to be calibrated to the other.
    private static let rrfK: Double = 60.0

    private let retriever: Retriever
    private let builder: PromptBuilder

    public init(retriever: Retriever, builder: PromptBuilder = PromptBuilder()) {
        self.retriever = retriever
        self.builder = builder
    }

    public func answer(question: String,
                       onToken: @escaping @Sendable (String) -> Void) async throws -> RagOutcome {

        let runner = try await ModelManager.shared.ensureLoaded()
        ModelManager.shared.touch()

        // Hybrid retrieval: FTS5 catches exact terms ("tourniquet", "1:200"),
        // vectors catch paraphrase ("how do I stop bad bleeding"). Neither alone
        // is good enough for a user who is frightened and typing badly.
        let lexical = try retriever.searchLexical(question, limit: 24)
        let semantic = try await retriever.searchSemantic(question,
                                                          embedder: { await runner.embed($0) },
                                                          limit: 24)

        let fused = fuse(lexical: lexical, semantic: semantic)
        let top = Array(fused.prefix(Tier.current.topKChunks))

        guard let best = top.first, best.score >= RagPipeline.confidenceFloor else {
            return .notInArchive
        }

        // Budget the context honestly using the model's own tokenizer rather
        // than a characters-per-token guess, then drop whole chunks from the
        // tail until it fits. A truncated chunk can sever a citation from its
        // procedure, which is exactly the failure C3 exists to prevent.
        let prompt = await builder.build(question: question,
                                         chunks: top,
                                         budget: Tier.current.contextTokens - 512,
                                         countTokens: { await runner.countTokens($0) })

        var collected = ""
        let sampling = builder.isClinical(question)
            ? LlamaRunner.Sampling.clinical
            : LlamaRunner.Sampling()

        for try await token in await runner.generate(prompt: prompt, sampling: sampling) {
            collected += token
            onToken(token)
        }

        let citations = top.map {
            Citation(id: $0.chunkId,
                     documentTitle: $0.documentTitle,
                     section: $0.section,
                     score: $0.score)
        }

        // Post-condition, cheap and worth it: a non-empty answer must carry at
        // least one citation, or we discard it and admit ignorance instead.
        guard !collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !citations.isEmpty else {
            return .notInArchive
        }

        return .answer(text: collected, citations: citations)
    }

    /// Reciprocal rank fusion. Rank-based, so the wildly different scales of
    /// BM25 and cosine similarity never have to be reconciled.
    private func fuse(lexical: [RetrievedChunk],
                      semantic: [RetrievedChunk]) -> [RetrievedChunk] {

        var scores: [Int64: Double] = [:]
        var byId: [Int64: RetrievedChunk] = [:]

        for (rank, chunk) in lexical.enumerated() {
            scores[chunk.chunkId, default: 0] += 1.0 / (RagPipeline.rrfK + Double(rank + 1))
            byId[chunk.chunkId] = chunk
        }
        for (rank, chunk) in semantic.enumerated() {
            scores[chunk.chunkId, default: 0] += 1.0 / (RagPipeline.rrfK + Double(rank + 1))
            byId[chunk.chunkId] = chunk
        }

        // Normalise to 0...1 against the best possible fused score so the
        // confidence floor means the same thing regardless of result count.
        let ceiling = 2.0 / (RagPipeline.rrfK + 1.0)

        return scores
            .compactMap { (id, raw) -> RetrievedChunk? in
                guard var c = byId[id] else { return nil }
                c.score = min(1.0, raw / ceiling)
                return c
            }
            .sorted { $0.score > $1.score }
    }
}
