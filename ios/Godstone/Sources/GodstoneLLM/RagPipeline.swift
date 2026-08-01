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

/// Staged retrieval result exposed to the UI so the confidence gate can run
/// BEFORE the model is loaded (C3) and so a refusal can still show near-miss
/// sources from the Archive (C5). Mirrors `OracleViewModel.State` on Android.
public struct RetrievalResult: Sendable {
    public let chunks: [RetrievedChunk]
    public let bestScore: Double
    public let nearMisses: [Citation]

    /// Verdict from `SafetyGate.evaluate` -- the same logic the probe suite
    /// exercises. Nil means the gate never ran, which fails closed.
    public let gateVerdict: SafetyGate.Result?

    public var passesConfidenceGate: Bool {
        gateVerdict?.allowsGeneration ?? false
    }
}

public actor RagPipeline {

    /// Below this fused score we consider the Archive silent on the question.
    /// Tuned on the offline eval set in tab 12; deliberately conservative.
    /// PARITY with Android (was 0.28; raised to 0.35 to match tab 05).
    /// RETAINED ONLY AS A LEGACY CONSTANT. The verdict now comes from
    /// SafetyGate.evaluate; see `RetrievalResult.passesConfidenceGate`.
    /// Invariant G fails the build if this value is ever compared against
    /// again, because the repository's own audit proved it cannot discriminate.
    @available(*, deprecated, message: "use SafetyGate.evaluate")
    public static let confidenceFloor: Double = 0.35

    /// Reciprocal-rank-fusion constant. Standard value; combines the FTS5 rank
    /// and the vector rank without either having to be calibrated to the other.
    private static let rrfK: Double = 60.0

    private let retriever: Retriever
    private let builder: PromptBuilder

    public init(retriever: Retriever, builder: PromptBuilder = PromptBuilder()) {
        self.retriever = retriever
        self.builder = builder
    }

    // MARK: - Staged API (drives OracleViewModel)

    /// Best-effort model preload. Returns true when a runner is resident and
    /// ready, false when the model cannot be loaded (e.g. modelMissing). The UI
    /// uses this to decide between "generate" and "degrade to Archive browse"
    /// without ever blocking the gate on a model that may not fit (C5).
    @discardableResult
    public func warmUp() async -> Bool {
        guard let runner = try? await ModelManager.shared.ensureLoaded() else {
            return false
        }
        ModelManager.shared.touch()
        return await runner.isLoaded
    }

    /// Hybrid retrieval + reciprocal-rank fusion. Runs the gate evaluation but
    /// does NOT load the model; the embedder lazily touches `ModelManager.shared`
    /// so a cold Archive query never pays for a model load it may not need.
    public func retrieve(question: String) async -> RetrievalResult {
        // Hybrid retrieval: FTS5 catches exact terms ("tourniquet", "1:200"),
        // vectors catch paraphrase ("how do I stop bad bleeding"). Neither alone
        // is good enough for a user who is frightened and typing badly.
        let lexical = (try? retriever.searchLexical(question, limit: 24)) ?? []
        // The archive's vectors come from bge-small/bge-base (see
        // content/ingest/embedder.py). This used to embed the query with the
        // QWEN GENERATION model, putting query and corpus in two completely
        // different vector spaces -- cosine similarity between them is noise,
        // so every semantic score was meaningless while looking healthy.
        //
        // ModelManager.shared.embedder loads the SAME GGUF the archive was
        // built with and returns nil on a dimension mismatch, so retrieval
        // degrades to lexical-only rather than comparing across spaces.
        let semantic = (try? await retriever.searchSemantic(
            question,
            embedder: { await ModelManager.shared.embedQuery($0) },
            limit: 24)) ?? []

        let fused = fuse(lexical: lexical, semantic: semantic)
        let top = Array(fused.prefix(Tier.current.topKChunks))

        let bestScore = top.first?.score ?? 0
        let verdict = SafetyGate.evaluate(question: question,
                                          chunks: top,
                                          index: await retriever.corpusIndex())
        let nearMisses: [Citation] = verdict.allowsGeneration ? [] : top.prefix(3).map {
            Citation(id: $0.chunkId,
                     documentTitle: $0.documentTitle,
                     section: $0.section,
                     score: $0.score)
        }
        return RetrievalResult(chunks: top, bestScore: bestScore,
                               nearMisses: nearMisses, gateVerdict: verdict)
    }

    /// Streaming generation gated on the retrieval result. The stream finishes
    /// immediately (empty) when the gate did not pass, so the UI's `for try await`
    /// loop simply does nothing and falls through to the refused state.
    ///
    /// `nonisolated` because `OracleViewModel` iterates it without `await`-ing the
    /// call itself: the actor state is only touched inside the stream's detached
    /// continuation, where isolation is re-acquired at each `await`.
    public nonisolated func generate(question: String,
                                     retrieval: RetrievalResult) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                // Constraint C3: the gate runs BEFORE the model is ever invoked.
                guard retrieval.passesConfidenceGate else {
                    continuation.finish()
                    return
                }

                do {
                    let runner = try await ModelManager.shared.ensureLoaded()
                    ModelManager.shared.touch()

                    // Budget the context honestly using the model's own tokenizer
                    // rather than a characters-per-token guess, then drop whole
                    // chunks from the tail until it fits. A truncated chunk can
                    // sever a citation from its procedure, which is exactly the
                    // failure C3 exists to prevent.
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

    /// Maps `[n]` citation markers in the generated answer back to the chunks
    /// that were actually placed in the prompt, so the UI can render tappable
    /// sources instead of bare index numbers. 1-based, matches PromptBuilder.
    public nonisolated func extractCitations(answer: String,
                                             retrieval: RetrievalResult) -> [Citation] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+)\]"#) else {
            return []
        }
        let ns = answer as NSString
        let matches = regex.matches(in: answer,
                                    range: NSRange(location: 0, length: ns.length))

        var seen = Set<Int>()
        var citations: [Citation] = []
        for match in matches {
            let n = Int(ns.substring(with: match.range(at: 1))) ?? 0
            guard n >= 1, n <= retrieval.chunks.count, !seen.contains(n) else { continue }
            seen.insert(n)
            let chunk = retrieval.chunks[n - 1]
            citations.append(Citation(id: chunk.chunkId,
                                      documentTitle: chunk.documentTitle,
                                      section: chunk.section,
                                      score: chunk.score))
        }
        return citations
    }

    /// Release the model back to the OS. Fire-and-forget: the UI calls this on
    /// background without awaiting, so the eviction runs on its own task.
    public nonisolated func release() {
        Task { await ModelManager.shared.evictNow() }
    }

    // MARK: - Legacy single-shot API (preserved for callers that do not stream)

    public func answer(question: String,
                       onToken: @escaping @Sendable (String) -> Void) async throws -> RagOutcome {
        let retrieval = await retrieve(question: question)

        guard retrieval.passesConfidenceGate else {
            return .notInArchive
        }

        var collected = ""
        for try await token in generate(question: question, retrieval: retrieval) {
            collected += token
            onToken(token)
        }

        let citations = extractCitations(answer: collected, retrieval: retrieval)

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
