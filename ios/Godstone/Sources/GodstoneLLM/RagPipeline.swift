import Foundation
import GodstoneCore

// Citation, RetrievalResult, FinalAnswerOutcome and the Oracle seams
// (OracleRetriever / OracleGenerator / OracleAnswerValidating /
// OraclePipelineProtocol) now live in GodstoneCore (OracleOrchestration.swift)
// so the Oracle state machine compiles and tests without this llama.cpp-backed
// module. This module imports GodstoneCore for those types and conforms
// RagPipeline to OraclePipelineProtocol. Final-answer validation is provided
// by the OracleAnswerValidating protocol default, which reuses
// OracleAnswerValidator (the single source of the fail-closed rules).

public enum RagOutcome: Sendable {
    case answer(text: String, citations: [Citation])
    case notInArchive
}

public actor RagPipeline: OraclePipelineProtocol {
    @available(*, deprecated, message: "use SafetyGate.evaluate")
    public static let confidenceFloor: Double = 0.35
    private static let rrfK: Double = 60.0
    private let retriever: Retriever
    private let builder: PromptBuilder

    public init(retriever: Retriever, builder: PromptBuilder = PromptBuilder()) {
        self.retriever = retriever
        self.builder = builder
    }

    @discardableResult
    public func warmUp() async -> Bool {
        guard let runner = try? await ModelManager.shared.ensureLoaded() else { return false }
        ModelManager.shared.touch()
        return await runner.isLoaded
    }

    public func retrieve(question: String) async -> RetrievalResult {
        let lexical = (try? retriever.searchLexical(question, limit: 24)) ?? []
        let semantic = (try? await retriever.searchSemantic(
            question,
            embedder: { await ModelManager.shared.embedQuery($0) },
            limit: 24)) ?? []
        let top = Array(fuse(lexical: lexical, semantic: semantic).prefix(Tier.current.topKChunks))
        let verdict = SafetyGate.evaluate(question: question,
                                          chunks: top,
                                          index: await retriever.corpusIndex())
        let nearMisses: [Citation] = verdict.allowsGeneration ? [] : top.prefix(3).map {
            Citation(id: $0.chunkId, documentTitle: $0.documentTitle,
                     section: $0.section, score: $0.score)
        }
        return RetrievalResult(chunks: top, bestScore: top.first?.score ?? 0,
                               nearMisses: nearMisses, gateVerdict: verdict)
    }

    /// The stream contains private draft bytes. UI code must never publish it directly.
    public nonisolated func generate(question: String,
                                     retrieval: RetrievalResult) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard retrieval.passesConfidenceGate else {
                    continuation.finish(); return
                }
                do {
                    let runner = try await ModelManager.shared.ensureLoaded()
                    ModelManager.shared.touch()
                    let prompt = await self.builder.build(
                        question: question,
                        chunks: retrieval.chunks,
                        budget: Tier.current.contextTokens - 512,
                        countTokens: { await runner.countTokens($0) }
                    )
                    let sampling = self.builder.isClinical(question)
                        ? LlamaRunner.Sampling.clinical
                        : LlamaRunner.Sampling()
                    for try await token in await runner.generate(prompt: prompt, sampling: sampling) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public nonisolated func extractCitations(answer: String,
                                             retrieval: RetrievalResult) -> [Citation] {
        guard case .accepted(_, let citations) = validate(answer: answer, retrieval: retrieval)
        else { return [] }
        return citations
    }

    public nonisolated func release() {
        Task { await ModelManager.shared.evictNow() }
    }

    /// Compatibility API: callback receives one complete validated answer, never draft tokens.
    public func answer(question: String,
                       onToken: @escaping @Sendable (String) -> Void) async throws -> RagOutcome {
        let retrieval = await retrieve(question: question)
        guard retrieval.passesConfidenceGate else { return .notInArchive }
        var collected = ""
        for try await token in generate(question: question, retrieval: retrieval) {
            try Task.checkCancellation()
            collected += token
        }
        guard case .accepted(let text, let citations) = validate(
            answer: collected, retrieval: retrieval) else { return .notInArchive }
        onToken(text)
        return .answer(text: text, citations: citations)
    }

    private func fuse(lexical: [RetrievedChunk], semantic: [RetrievedChunk]) -> [RetrievedChunk] {
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
        let ceiling = 2.0 / (RagPipeline.rrfK + 1.0)
        return scores.compactMap { id, raw -> RetrievedChunk? in
            guard var chunk = byId[id] else { return nil }
            chunk.score = min(1.0, raw / ceiling)
            return chunk
        }.sorted { $0.score > $1.score }
    }
}
