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

    @Published public private(set) var state: State = .idle
    @Published public var question: String = ""

    private let pipeline: OraclePipelineProtocol
    private var task: Task<Void, Never>?
    // Last validator-approved answer, so a cancelled generation restores it
    // instead of leaving an unfinished draft visible.
    private var lastAnswered: State?

    public init(pipeline: OraclePipelineProtocol) { self.pipeline = pipeline }

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
        do {
            for try await token in pipeline.generate(question: q, retrieval: retrieval) {
                try Task.checkCancellation()
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
            restore()
            return
        } catch {
            state = .degraded(reason: "Generation stopped. Browse the sources instead.")
            return
        }

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