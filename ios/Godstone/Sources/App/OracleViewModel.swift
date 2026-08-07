import Foundation
import Combine
import GodstoneLLM

@MainActor
final class OracleViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case retrieving
        case generating
        case answered(text: String, citations: [Citation])
        case refused(nearMisses: [Citation])
        case degraded(reason: String)
    }

    @Published private(set) var state: State = .idle
    @Published var question: String = ""
    private let pipeline: RagPipeline
    private var task: Task<Void, Never>?

    init(pipeline: RagPipeline) { self.pipeline = pipeline }

    func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        task?.cancel()
        task = Task {
            state = .retrieving
            let retrieval = await pipeline.retrieve(question: q)
            guard !Task.isCancelled else { return }
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
            } catch is CancellationError {
                return
            } catch {
                state = .degraded(reason: "Generation stopped. Browse the sources instead.")
                return
            }

            switch pipeline.validate(answer: draft, retrieval: retrieval) {
            case .accepted(let text, let citations):
                state = .answered(text: text, citations: citations)
            case .rejected:
                state = .refused(nearMisses: retrieval.nearMisses)
            }
        }
    }

    func releaseModel() {
        task?.cancel()
        pipeline.release()
    }
}
