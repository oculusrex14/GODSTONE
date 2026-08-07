import XCTest
import Combine
@testable import GodstoneCore

// Runtime-state tests for the Oracle ViewModel. These exercise the real
// retrieve -> generate -> validate state machine against deterministic fakes
// that conform to OraclePipelineProtocol, with NO llama.cpp / native model.
//
// Validation in these tests is NOT duplicated: the fakes inherit the production
// OracleAnswerValidating.validate default, which reuses OracleAnswerValidator.
// What is asserted here is the *state-machine* behaviour around validation
// (privacy of the draft, fail-closed discard, restore-on-cancel, exact-once
// publication), not the validator's rules (covered by OracleAnswerValidatorTests).
@MainActor
final class OracleViewModelRuntimeTests: XCTestCase {

    // MARK: - Fixtures

    private func gate(allow: Bool = true) -> SafetyGate.Result {
        SafetyGate.Result(verdict: allow ? .allow : .refuseNoEvidence,
                           reasons: [], anchorRecall: 1.0, colocation: 1.0,
                           domainCoherence: 1.0, oovTerms: [])
    }

    private func chunk(_ text: String, id: Int64 = 1, domain: String = "medical") -> RetrievedChunk {
        RetrievedChunk(chunkId: id, documentId: 1, documentTitle: "Reviewed source",
                       section: "Procedure", domain: domain, text: text, score: 1.0)
    }

    private func retrieval(_ chunks: [RetrievedChunk], allow: Bool = true) -> RetrievalResult {
        RetrievalResult(chunks: chunks, bestScore: 1.0, nearMisses: [], gateVerdict: gate(allow: allow))
    }

    /// True iff any visible `.answered` snapshot contains one of the emitted
    /// (partial) token strings. This is both the safety invariant and the
    /// negative-control detector: it must be `false` for the production VM and
    /// `true` for a mutant that republishes partial tokens to state.
    private func stateExposesPartialToken(_ snapshots: [OracleViewModel.State],
                                          tokens: [String]) -> Bool {
        snapshots.contains { state in
            if case .answered(let text, _) = state {
                return tokens.contains { text.contains($0) }
            }
            return false
        }
    }

    private final class StateRecorder {
        var snapshots: [OracleViewModel.State] = []
        func append(_ s: OracleViewModel.State) { snapshots.append(s) }
    }

    private func record(_ vm: OracleViewModel) -> (StateRecorder, AnyCancellable) {
        let recorder = StateRecorder()
        let cancellable = vm.$state.sink { recorder.append($0) }
        return (recorder, cancellable)
    }

    // MARK: - 1. Generation emits five tokens and then throws

    func testGenerationThrowingExposesNoTokenAndDegrades() async {
        let tokens = ["Rinse", " with", " 500", " ml", " of"]
        let fake = FakeOraclePipeline(
            retrieval: retrieval([chunk("Rinse with 500 ml of water.")]),
            warmUpResult: true, tokens: tokens, behavior: .throw_)
        let vm = OracleViewModel(pipeline: fake)
        let (rec, cancellable) = record(vm)
        await vm.runPipeline(question: "q")
        cancellable.cancel()

        XCTAssertFalse(stateExposesPartialToken(rec.snapshots, tokens: tokens),
                       "a generated token leaked into visible state: \(rec.snapshots)")
        if case .answered = vm.state {
            XCTFail("a failed/partial draft was promoted to an answered state")
        }
        switch vm.state {
        case .degraded, .refused: break
        default: XCTFail("expected degraded/refused after a generation throw, got \(vm.state)")
        }
    }

    // MARK: - 2. Generation is cancelled after several tokens

    func testCancellationHidesPartialAndRestoresPriorAnswer() async {
        // Establish a prior, validator-approved answer.
        let fake = FakeOraclePipeline(
            retrieval: retrieval([chunk("Rinse with 500 ml of water.")]),
            warmUpResult: true,
            tokens: ["Rinse with 500 ml of water [1]."],
            behavior: .complete)
        let vm = OracleViewModel(pipeline: fake)
        await vm.runPipeline(question: "q")
        guard case .answered(let priorText, _) = vm.state else {
            XCTFail("expected a prior answered state, got \(vm.state)"); return
        }
        let prior = vm.state

        // Re-ask with a generator that emits partial tokens then parks, and
        // cancel it mid-generation.
        fake.tokens = ["PARTIAL ", "DRAFT "]
        fake.behavior = .park
        let (rec, cancellable) = record(vm)
        let work = Task { await vm.runPipeline(question: "q2") }
        try? await Task.sleep(nanoseconds: 100_000_000)  // let partial tokens be consumed + park
        work.cancel()
        _ = await work.value
        cancellable.cancel()

        XCTAssertFalse(stateExposesPartialToken(rec.snapshots, tokens: ["PARTIAL ", "DRAFT "]),
                       "a partial draft token became visible: \(rec.snapshots)")
        XCTAssertEqual(vm.state, prior,
                       "an unfinished draft overwrote the prior approved answer")
        if case .answered(let text, _) = vm.state {
            XCTAssertEqual(text, priorText, "restored answer text differs from the prior approved answer")
        }
    }

    // MARK: - 3. Validation rejects a completed draft

    func testValidationRejectsCompletedDraftDiscardsItInFull() async {
        let fake = FakeOraclePipeline(
            retrieval: retrieval([chunk("Rinse with 500 ml of water.")]),
            warmUpResult: true,
            tokens: ["Rinse with 500 mg of water [1]."],  // wrong unit vs evidence
            behavior: .complete)
        let vm = OracleViewModel(pipeline: fake)
        let (rec, cancellable) = record(vm)
        await vm.runPipeline(question: "q")
        cancellable.cancel()

        // The entire draft is discarded: no `.answered` snapshot is ever published.
        XCTAssertFalse(rec.snapshots.contains { state in
            if case .answered = state { return true } else { return false }
        }, "a rejected draft was promoted to an answered state")
        // Only the approved refusal state is published.
        if case .refused = vm.state { /* ok */ } else {
            XCTFail("expected refused after validation rejection, got \(vm.state)")
        }
    }

    // MARK: - 4. Validation accepts a completed draft

    func testValidationAcceptsCompletedDraftPublishesExactlyOnce() async {
        let fake = FakeOraclePipeline(
            retrieval: retrieval([chunk("Rinse with 500 ml of water.")]),
            warmUpResult: true,
            tokens: ["Rinse with 500 ml of water [1]."],
            behavior: .complete)
        let vm = OracleViewModel(pipeline: fake)
        let (rec, cancellable) = record(vm)
        await vm.runPipeline(question: "q")
        cancellable.cancel()

        // The answer becomes visible exactly once, and only after validation.
        let answered = rec.snapshots.filter {
            if case .answered = $0 { return true } else { return false }
        }
        XCTAssertEqual(answered.count, 1, "answer was published \(answered.count) times")
        guard case .answered(let text, let citations) = vm.state else {
            XCTFail("expected answered, got \(vm.state)"); return
        }
        XCTAssertEqual(text, "Rinse with 500 ml of water [1].")
        // Citations are the validator-approved citations (chunk 1 only).
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations.first?.id, 1)
    }

    // MARK: - 5. A fake generator emits mismatched / uncited content

    func testFakeGeneratorMismatchesAreRejected() async {
        // 5a: 500 ml against evidence containing 500 mg.
        await assertRejected(
            tokens: "Rinse with 500 ml of water [1].",
            evidence: "Rinse with 500 mg of water.")
        // 5b: 5 ml per kg against evidence containing only 5 ml.
        await assertRejected(
            tokens: "Give 5 ml per kg of the solution [1].",
            evidence: "Give 5 ml of the solution.")
        // 5c: uncited trailing instruction (first clause cited, trailing is not).
        await assertRejected(
            tokens: "Apply pressure to the wound [1]. Keep the area clean.",
            evidence: "Apply pressure to the wound.")
    }

    private func assertRejected(tokens: String, evidence: String) async {
        let fake = FakeOraclePipeline(
            retrieval: retrieval([chunk(evidence)]),
            warmUpResult: true, tokens: [tokens], behavior: .complete)
        let vm = OracleViewModel(pipeline: fake)
        let (rec, cancellable) = record(vm)
        await vm.runPipeline(question: "q")
        cancellable.cancel()
        XCTAssertFalse(rec.snapshots.contains { state in
            if case .answered = state { return true } else { return false }
        }, "an unsupported answer was accepted: \(tokens) vs \(evidence)")
        if case .refused = vm.state { /* ok */ } else {
            XCTFail("expected refused for '\(tokens)' vs '\(evidence)', got \(vm.state)")
        }
    }

    // MARK: - 6. Mutation / negative control: partial-token publication is detected

    func testMutationPublishingPartialTokensIsDetected() async {
        let tokens = ["LEAK1 ", "LEAK2 "]

        // The mutant republishes partial tokens to visible state during
        // generation (the exact regression the safety boundary prevents).
        let fake = FakeOraclePipeline(
            retrieval: retrieval([chunk("Rinse with 500 ml of water.")]),
            warmUpResult: true, tokens: tokens, behavior: .complete)
        let mutant = LeakyOracleViewModel(pipeline: fake)
        let mutantRecorder = StateRecorder()
        let mc = mutant.$state.sink { mutantRecorder.append($0) }
        await mutant.runPipeline(question: "q")
        mc.cancel()

        // The detector MUST flag the mutant. This proves the runtime invariant
        // has teeth: if per-token UI publication is reintroduced, this check
        // fails against the mutant (it returns `true` = violation detected).
        XCTAssertTrue(stateExposesPartialToken(mutantRecorder.snapshots, tokens: tokens),
                      "negative control failed: partial-token publication was not detected")

        // The production VM under the same input exposes no partial token.
        fake.tokens = tokens
        fake.behavior = .complete
        let vm = OracleViewModel(pipeline: fake)
        let (rec, c) = record(vm)
        await vm.runPipeline(question: "q")
        c.cancel()
        XCTAssertFalse(stateExposesPartialToken(rec.snapshots, tokens: tokens),
                       "the production VM exposed a partial token")
    }
}

// MARK: - Fakes

private struct TestError: Error {}

private final class FakeOraclePipeline: OraclePipelineProtocol, @unchecked Sendable {
    enum Behavior { case complete, throw_, park }

    var retrieval: RetrievalResult
    var warmUpResult: Bool
    var tokens: [String]
    var behavior: Behavior

    init(retrieval: RetrievalResult, warmUpResult: Bool = true,
         tokens: [String] = [], behavior: Behavior = .complete) {
        self.retrieval = retrieval
        self.warmUpResult = warmUpResult
        self.tokens = tokens
        self.behavior = behavior
    }

    func warmUp() async -> Bool { warmUpResult }
    func retrieve(question: String) async -> RetrievalResult { retrieval }
    func release() {}

    func generate(question: String, retrieval: RetrievalResult) -> AsyncThrowingStream<String, Error> {
        let toEmit = tokens
        let mode = behavior
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let prod = Task {
                for token in toEmit { continuation.yield(token) }
                switch mode {
                case .complete:
                    continuation.finish()
                case .throw_:
                    continuation.finish(throwing: TestError())
                case .park:
                    // Park with the stream open so a cancellation lands
                    // mid-generation. The single onTermination handler below
                    // cancels this producer; the cancellable sleep then throws
                    // and the producer exits cleanly.
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in prod.cancel() }
        }
    }

    // validate is provided by the OracleAnswerValidating protocol default,
    // which reuses the production OracleAnswerValidator (no duplication).
}

// MARK: - Mutation (negative control)

private final class LeakyOracleViewModel: ObservableObject {
    @Published private(set) var state: OracleViewModel.State = .idle

    private let pipeline: OraclePipelineProtocol

    init(pipeline: OraclePipelineProtocol) { self.pipeline = pipeline }

    /// Deliberately broken: publishes each partial token to visible `.answered`
    /// state during generation. This is the regression the production
    /// OracleViewModel must prevent; the negative-control test proves the
    /// runtime detector catches it.
    func runPipeline(question q: String) async {
        state = .retrieving
        let retrieval = await pipeline.retrieve(question: q)
        guard retrieval.passesConfidenceGate else { state = .refused(nearMisses: []); return }
        _ = await pipeline.warmUp()
        state = .generating
        var draft = ""
        do {
            for try await token in pipeline.generate(question: q, retrieval: retrieval) {
                draft += token
                // MUTATION: partial draft becomes visible state.
                state = .answered(text: draft, citations: [])
            }
        } catch {
            // The mutant swallows generation failure; whatever partial draft
            // accumulated is already visible (the defect under test).
        }
        switch pipeline.validate(answer: draft, retrieval: retrieval) {
        case .accepted(let text, let citations):
            state = .answered(text: text, citations: citations)
        case .rejected:
            state = .refused(nearMisses: [])
        }
    }
}