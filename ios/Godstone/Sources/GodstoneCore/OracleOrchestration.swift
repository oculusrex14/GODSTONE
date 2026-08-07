import Foundation

// MARK: - Shared Oracle value types
//
// These types live in GodstoneCore (not GodstoneLLM) so the Oracle state machine
// can be compiled and tested against deterministic fakes WITHOUT the llama.cpp
// inference bridge. The concrete llama.cpp-backed pipeline (RagPipeline, in
// GodstoneLLM) conforms to OraclePipelineProtocol; the production adapter is the
// only thing that touches a native model.

/// A single citation shown in the UI, derived from a retrieved chunk after the
/// answer validator has approved it. Mirrors the Android `Citation` data class.
public struct Citation: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let documentTitle: String
    public let section: String
    public let score: Double

    public init(id: Int64, documentTitle: String, section: String, score: Double) {
        self.id = id
        self.documentTitle = documentTitle
        self.section = section
        self.score = score
    }
}

/// The retrieval result consumed by the generator and the final validator.
/// `gateVerdict` is the SafetyGate verdict; a result that never went through the
/// gate has a nil verdict and therefore fails the confidence gate (fail-closed).
public struct RetrievalResult: Sendable {
    public let chunks: [RetrievedChunk]
    public let bestScore: Double
    public let nearMisses: [Citation]
    public let gateVerdict: SafetyGate.Result?

    public var passesConfidenceGate: Bool { gateVerdict?.allowsGeneration ?? false }

    public init(chunks: [RetrievedChunk],
                bestScore: Double,
                nearMisses: [Citation],
                gateVerdict: SafetyGate.Result?) {
        self.chunks = chunks
        self.bestScore = bestScore
        self.nearMisses = nearMisses
        self.gateVerdict = gateVerdict
    }
}

/// Outcome of final, fail-closed validation of a complete private draft.
public enum FinalAnswerOutcome: Sendable {
    case accepted(text: String, citations: [Citation])
    case rejected(reason: String)
}

// MARK: - Oracle seams
//
// Small protocols so the ViewModel + state machine depend on behaviour, not on
// the concrete llama.cpp-backed pipeline. The production RagPipeline conforms;
// tests use deterministic fakes. No seam here references a native model.

public protocol OracleRetriever: Sendable {
    func retrieve(question: String) async -> RetrievalResult
}

public protocol OracleGenerator: Sendable {
    /// A stream of private draft tokens. UI code must never bind this directly to
    /// visible state; it is consumed into a local draft that is only published
    /// after OracleAnswerValidating succeeds.
    func generate(question: String, retrieval: RetrievalResult) -> AsyncThrowingStream<String, Error>
}

public protocol OracleAnswerValidating: Sendable {
    /// Validate a complete private draft. Returns the approved text + citations
    /// only when the answer is fully supported; otherwise the whole draft is
    /// rejected in full.
    func validate(answer: String, retrieval: RetrievalResult) -> FinalAnswerOutcome
}

public protocol OraclePipelineProtocol: OracleRetriever, OracleGenerator, OracleAnswerValidating, Sendable {
    /// Bring the model to a ready state. Returns false if the model is unavailable;
    /// the ViewModel degrades truthfully rather than guessing.
    func warmUp() async -> Bool
    /// Release native resources.
    func release()
}

// MARK: - Shared validation bridge (no duplication)
//
// The default implementation of OracleAnswerValidating.validate reuses the
// production OracleAnswerValidator (the same logic the unit-test suite
// exercises) and only bridges its Result into FinalAnswerOutcome. Both the
// production RagPipeline and any test fake obtain validation this way, so the
// fail-closed rules are defined exactly once.
public extension OracleAnswerValidating {
    func validate(answer: String, retrieval: RetrievalResult) -> FinalAnswerOutcome {
        let result = OracleAnswerValidator.validate(
            answer: answer,
            chunks: retrieval.chunks,
            retrievalAllowed: retrieval.passesConfidenceGate)
        guard result.isValid else {
            return .rejected(reason: result.reason ?? "answer validation failed")
        }
        let citations = result.citedIndices.map { index -> Citation in
            let chunk = retrieval.chunks[index - 1]
            return Citation(id: chunk.chunkId,
                            documentTitle: chunk.documentTitle,
                            section: chunk.section,
                            score: chunk.score)
        }
        return .accepted(text: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                          citations: citations)
    }
}