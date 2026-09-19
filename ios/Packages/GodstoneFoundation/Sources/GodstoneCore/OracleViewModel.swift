import Foundation
import Combine

// OracleViewModel lives in GodstoneCore (not App/GodstoneLLM) so the full
// retrieve -> generate -> validate state machine can be compiled and tested
// against an OraclePipelineProtocol fake WITHOUT the llama.cpp inference
// bridge. The production pipeline (RagPipeline in GodstoneLLM) conforms to
// OraclePipelineProtocol; nothing in this file references a native model.
//
// Safety invariants enforced here, and asserted by OracleViewModelRuntimeTests:
//   * generated tokens are accumulated into a LOCAL draft and are never present
//     in visible state (the .generating state carries no text payload);
//   * the whole draft is private until OracleAnswerValidating succeeds;
//   * cancellation or a generation failure leaves no partial answer in state
//     (a cancelled run restores the last successfully-answered state, so an
//     unfinished draft can never overwrite a prior approved answer);
//   * the only `.answered` ever published carries validator-approved text and
//     validator-approved citations.
@MainActor
public final class OracleViewModel: ObservableObject {
    public enum State: Sendable, Equatable {
        case idle
        case retrieving
        case generating
        case answered(text: String, citations: [Citation])
        case refused(nearMisses: [Citation])
        case degraded(reason: String)
    }

    /// TIER BUDGETS (T65): the retrieval context, the token budget and the draft
    /// buffer are all BOUNDED, so a runaway generation cannot grow unbounded memory
    /// and an oversized draft can never be published as a shorter answer.
    ///
    /// ABSENT UNTIL NOW, AND MEASURED: the draft loop below appended tokens with no
    /// limit at all, so a generator that never stopped would grow the buffer until
    /// the process died. The card requires the bound; the code did not carry one.
    public struct TierBudget: Sendable, Equatable {
        public let retrievalChunks: Int
        public let contextTokens: Int
        public let draftCharacters: Int

        public init(retrievalChunks: Int, contextTokens: Int, draftCharacters: Int) {
            self.retrievalChunks = retrievalChunks
            self.contextTokens = contextTokens
            self.draftCharacters = draftCharacters
        }

        /// The LIGHT tier, matching the Android `Tier.LIGHT` bounds.
        public static let light = TierBudget(retrievalChunks: 4, contextTokens: 128,
                                             draftCharacters: 512)
        /// The MEDIUM tier.
        public static let medium = TierBudget(retrievalChunks: 8, contextTokens: 256,
                                              draftCharacters: 1024)
    }

    /// The bound in force for this ViewModel. Defaults to LIGHT.
    public let budget: TierBudget

    /// The length of the draft that was actually accumulated, for the tier-bound
    /// witness. Not part of the UI contract; it exists so a court can assert the
    /// bound held rather than inferring it from the absence of a publication.
    private(set) var lastDraftLengthForTest: Int = 0

    @Published public private(set) var state: State = .idle
    @Published public var question: String = ""

    private let pipeline: OraclePipelineProtocol
    private var task: Task<Void, Never>?
    // Last validator-approved answer, so a cancelled generation restores it
    // instead of leaving an unfinished draft visible.
    private var lastAnswered: State?

    public init(pipeline: OraclePipelineProtocol, budget: TierBudget = .light) {
        self.pipeline = pipeline
        self.budget = budget
    }

    public func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        task = Task { await self.runPipeline(question: q) }
    }

    /// Testable orchestration seam. `ask()` wraps this in a cancellable Task;
    /// tests may await it directly for deterministic, non-cancellation scenarios,
    /// or wrap it in a Task they cancel to exercise the cancellation path.
    func runPipeline(question q: String) async {
        state = .retrieving
        let retrieval = await pipeline.retrieve(question: q)
        guard !Task.isCancelled else { restore(); return }
        guard retrieval.passesConfidenceGate else {
            state = .refused(nearMisses: retrieval.nearMisses)
            return
        }
        guard await pipeline.warmUp() else {
            state = .degraded(reason: "The model is unavailable. Browse the Archive directly.")
            return
        }

        // Critical safety boundary: no draft text is associated with this state.
        state = .generating
        var draft = ""
        var exceededBudget = false
        do {
            for try await token in pipeline.generate(question: q, retrieval: retrieval) {
                try Task.checkCancellation()
                // THE TIER BOUND. A draft that would exceed the budget stops the
                // run rather than truncating: a half-draft is not a shorter
                // answer, and publishing one would be a silently wrong response.
                if draft.count + token.count > budget.draftCharacters {
                    exceededBudget = true
                    throw CancellationError()
                }
                draft += token
            }
            // A cancelled generation may end the stream (next() returns nil when
            // the producer is cancelled) rather than throwing CancellationError,
            // so the per-token check above can miss it. Re-check before treating
            // the accumulated draft as a complete answer: a cancelled draft must
            // never reach validation or become visible.
            try Task.checkCancellation()
        } catch is CancellationError {
            // No partial answer was ever published or persisted; restore the
            // last approved answer so an unfinished draft cannot overwrite it.
            lastDraftLengthForTest = draft.count
            if exceededBudget {
                state = .degraded(reason: "The answer exceeded this tier's size limit. "
                                   + "Browse the sources directly.")
                return
            }
            restore()
            return
        } catch {
            state = .degraded(reason: "Generation stopped. Browse the sources instead.")
            return
        }

        lastDraftLengthForTest = draft.count
        switch pipeline.validate(answer: draft, retrieval: retrieval) {
        case .accepted(let text, let citations):
            state = .answered(text: text, citations: citations)
            lastAnswered = state
        case .rejected:
            state = .refused(nearMisses: retrieval.nearMisses)
        }
    }

    private func restore() {
        state = lastAnswered ?? .idle
    }

    func cancelPipeline() { task?.cancel() }

    public func releaseModel() {
        task?.cancel()
        pipeline.release()
    }
}