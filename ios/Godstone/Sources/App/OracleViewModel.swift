import Foundation
import Combine
import GodstoneLLM

/// Drives the Ask screen. Mirrors the Android OracleViewModel one-for-one so
/// the two platforms cannot drift in safety behaviour.
@MainActor
final class OracleViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case retrieving
        case generating(partial: String)
        case answered(text: String, citations: [Citation])
        case refused(nearMisses: [Citation])
        case degraded(reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published var question: String = ""

    private let pipeline: RagPipeline
    private var task: Task<Void, Never>?

    init(pipeline: RagPipeline) {
        self.pipeline = pipeline
    }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        task?.cancel()
        task = Task {
            state = .retrieving

            let retrieval = await pipeline.retrieve(question: q)

            // Constraint C3: the gate runs BEFORE the model is ever invoked.
            guard retrieval.passesConfidenceGate else {
                state = .refused(nearMisses: retrieval.nearMisses)
                return
            }

            guard await pipeline.warmUp() else {
                // C5: degrade, never fail. The Archive is still fully readable.
                state = .degraded(
                    reason: "Not enough free memory to load the model. "
                          + "Browse the Archive directly."
                )
                return
            }

            var accumulated = ""
            do {
                for try await token in pipeline.generate(question: q, retrieval: retrieval) {
                    accumulated += token
                    state = .generating(partial: accumulated)
                }
            } catch {
                state = .degraded(reason: "Generation stopped. Showing sources instead.")
                return
            }

            state = .answered(
                text: accumulated,
                citations: pipeline.extractCitations(answer: accumulated,
                                                     retrieval: retrieval)
            )
        }
    }

    func releaseModel() {
        task?.cancel()
        pipeline.release()
    }
}
