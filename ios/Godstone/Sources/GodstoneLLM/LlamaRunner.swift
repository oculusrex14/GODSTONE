import Foundation
import GodstoneCore
import GodstoneLLMBridge

/// Swift-side owner of the model.
///
/// An actor, not a class with a lock. There is exactly one llama_context and it
/// is not thread safe, so serialisation is not an optimisation choice — it is a
/// correctness requirement. The actor makes that impossible to get wrong.
public actor LlamaRunner {

    public enum RunnerError: Error, Sendable {
        case modelMissing
        case outOfMemory
        case contextFailed
        case notLoaded
        case promptTooLong
    }

    /// Sampling profile. Deliberately cold: this application answers questions
    /// about tourniquets and water purification, and creativity is a defect.
    public struct Sampling: Sendable {
        public var temperature: Float = 0.3
        public var topP: Float = 0.9
        public var repeatPenalty: Float = 1.1
        public var maxTokens: Int = 512
        public var stopWords: [String] = ["</answer>", "\nUSER:", "\nQUESTION:"]

        public init() {}

        /// Even colder for anything with a dose, a ratio or a timing in it.
        public static var clinical: Sampling {
            var s = Sampling()
            s.temperature = 0.1
            s.topP = 0.7
            return s
        }
    }

    private let bridge = GSLlamaBridge()
    private var loadedPath: String?

    public init() {}

    public var isLoaded: Bool { bridge.isLoaded }

    public func load(path: String, contextTokens: Int, gpuLayers: Int, threads: Int) throws {
        if loadedPath == path && bridge.isLoaded { return }

        let status = bridge.loadModel(atPath: path,
                                      contextTokens: contextTokens,
                                      gpuLayers: gpuLayers,
                                      threads: threads)
        switch status {
        case .OK:
            loadedPath = path
        case .modelNotFound:
            throw RunnerError.modelMissing
        case .outOfMemory:
            throw RunnerError.outOfMemory
        default:
            throw RunnerError.contextFailed
        }
    }

    public func unload() {
        bridge.unload()
        loadedPath = nil
    }

    public func countTokens(_ text: String) -> Int {
        bridge.countTokens(text)
    }

    public func cancel() {
        bridge.requestCancel()
    }

    /// Streaming generation. The AsyncStream is the only interface the UI ever
    /// sees, so a slow model shows words appearing rather than a frozen screen.
    public func generate(prompt: String,
                         sampling: Sampling = Sampling()) -> AsyncThrowingStream<String, Error> {

        AsyncThrowingStream { continuation in
            Task.detached(priority: .userInitiated) {
                guard await self.isLoaded else {
                    continuation.finish(throwing: RunnerError.notLoaded)
                    return
                }

                let out = await self.runBlocking(prompt: prompt, sampling: sampling) { token in
                    continuation.yield(token)
                    return true
                }

                if out == nil {
                    continuation.finish(throwing: RunnerError.promptTooLong)
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                Task { await self.cancel() }
            }
        }
    }

    private func runBlocking(prompt: String,
                             sampling: Sampling,
                             onToken: @escaping @Sendable (String) -> Bool) -> String? {
        bridge.generate(withPrompt: prompt,
                        maxTokens: sampling.maxTokens,
                        temperature: sampling.temperature,
                        topP: sampling.topP,
                        repeatPenalty: sampling.repeatPenalty,
                        stopWords: sampling.stopWords,
                        callback: onToken)
    }

    /// Non-streaming convenience, used by tests and by the offline evaluation
    /// harness in tab 12.
    public func complete(prompt: String, sampling: Sampling = Sampling()) throws -> String {
        guard bridge.isLoaded else { throw RunnerError.notLoaded }
        guard let out = runBlocking(prompt: prompt, sampling: sampling, onToken: { _ in true }) else {
            throw RunnerError.promptTooLong
        }
        return out
    }

    public func embed(_ text: String) -> [Float]? {
        bridge.embed(text)?.map { $0.floatValue }
    }
}
