package io.godstone.app.ui.oracle

import io.godstone.llm.rag.AnswerValidator
import io.godstone.llm.rag.Chunk
import io.godstone.llm.rag.OraclePipeline
import io.godstone.llm.rag.RetrievalResult
import io.godstone.llm.safety.SafetyGate
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Runtime-state tests for the Android Oracle ViewModel. These exercise the real
// retrieve -> generate -> validate state machine against a deterministic fake
// OraclePipeline with NO native model on the classpath.
//
// Validation is NOT duplicated: the fake reuses the production AnswerValidator
// (the single source of the fail-closed rules). What is asserted here is the
// STATE-MACHINE behaviour around validation (privacy of the draft, fail-closed
// discard, restore-on-cancel, exact-once publication), not the validator rules.
//
// NOTE (source-reviewed): Android Gradle builds cannot run on this macOS host
// (no Android SDK / JDK toolchain provisioned here — see
// scripts/check_android_toolchain.py). These tests are written to be correct
// under `./gradlew :app:testLightDebugUnitTest --tests "*OracleViewModelTest*"`
// with kotlinx-coroutines-test; run them in a provisioned environment via
// scripts/verify_android_phase0.sh.
class OracleViewModelTest {

    // MARK: - Fixtures

    private fun gate(allow: Boolean = true) = SafetyGate.Result(
        if (allow) SafetyGate.Verdict.ALLOW else SafetyGate.Verdict.REFUSE_NO_EVIDENCE,
        emptyList(), 1.0, 1.0, 1.0, emptyList()
    )

    private fun chunk(text: String, id: Long = 1, domain: String = "medical") =
        Chunk(id, 1, "Reviewed source", domain, text, 1.0)

    private fun retrieval(chunks: List<Chunk>, allow: Boolean = true) =
        RetrievalResult(chunks, 1.0, emptyList(), gate(allow))

    /// True iff any visible ANSWERED snapshot contains one of the emitted
    /// (partial) token strings. Must be false for the production VM and true
    /// for a mutant that republishes partial tokens to state.
    private fun stateExposesPartialToken(states: List<OracleUiState>, tokens: List<String>): Boolean =
        states.any { s ->
            s.phase == OraclePhase.ANSWERED && tokens.any { s.answer.contains(it) }
        }

    private fun withMainDispatcher(block: suspend TestScope.() -> Unit) = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try {
            block()
        } finally {
            Dispatchers.resetMain()
        }
    }

    private suspend fun TestScope.record(vm: OracleViewModel): Pair<MutableList<OracleUiState>, Job> {
        val recorded = mutableListOf<OracleUiState>()
        val job = launch { vm.state.toList(recorded) }
        advanceUntilIdle() // let the collector subscribe + receive the current value
        return recorded to job
    }

    // MARK: - 1. Generation emits five tokens and then throws

    @Test
    fun testGenerationThrowingExposesNoTokenAndDegrades() = withMainDispatcher {
        val tokens = listOf("Rinse", " with", " 500", " ml", " of")
        val fake = FakeOraclePipeline(
            retrieval = retrieval(listOf(chunk("Rinse with 500 ml of water."))),
            warmUpResult = true, tokens = tokens, behavior = FakeOraclePipeline.Behavior.THROW
        )
        val vm = OracleViewModel(fake)
        advanceUntilIdle() // init warmUp -> modelReady
        val (recorded, recordJob) = record(vm)
        vm.onQuestionChanged("q"); vm.ask()
        advanceUntilIdle()
        recordJob.cancel()

        assertFalse("a generated token leaked into visible state: $recorded",
            stateExposesPartialToken(recorded, tokens))
        assertTrue("a failed/partial draft was promoted to ANSWERED",
            recorded.none { it.phase == OraclePhase.ANSWERED })
        val phase = vm.state.value.phase
        assertTrue("expected DEGRADED/REFUSED after a generation throw, got $phase",
            phase == OraclePhase.DEGRADED || phase == OraclePhase.REFUSED)
    }

    // MARK: - 2. Generation is cancelled after several tokens

    @Test
    fun testCancellationHidesPartialAndRestoresPriorAnswer() = withMainDispatcher {
        val fake = FakeOraclePipeline(
            retrieval = retrieval(listOf(chunk("Rinse with 500 ml of water."))),
            warmUpResult = true,
            tokens = listOf("Rinse with 500 ml of water [1]."),
            behavior = FakeOraclePipeline.Behavior.COMPLETE
        )
        val vm = OracleViewModel(fake)
        advanceUntilIdle() // init
        vm.onQuestionChanged("q"); vm.ask()
        advanceUntilIdle() // first ask completes -> ANSWERED, lastAnswered set
        assertEquals(OraclePhase.ANSWERED, vm.state.value.phase)
        val prior = vm.state.value

        // Re-ask with a generator that emits partial tokens then parks, and
        // cancel it mid-generation.
        fake.tokens = listOf("PARTIAL ", "DRAFT ")
        fake.behavior = FakeOraclePipeline.Behavior.PARK
        val (recorded, recordJob) = record(vm)
        vm.onQuestionChanged("q2"); vm.ask()
        advanceUntilIdle() // runs until the generator parks; partials collected locally
        vm.cancelGeneration()
        advanceUntilIdle() // cancellation -> restore
        recordJob.cancel()

        assertFalse("a partial draft token became visible: $recorded",
            stateExposesPartialToken(recorded, listOf("PARTIAL ", "DRAFT ")))
        assertEquals("an unfinished draft overwrote the prior approved answer",
            prior, vm.state.value)
    }

    // MARK: - 3. Validation rejects a completed draft

    @Test
    fun testValidationRejectsCompletedDraftDiscardsItInFull() = withMainDispatcher {
        val fake = FakeOraclePipeline(
            retrieval = retrieval(listOf(chunk("Rinse with 500 ml of water."))),
            warmUpResult = true,
            tokens = listOf("Rinse with 500 mg of water [1]."), // wrong unit vs evidence
            behavior = FakeOraclePipeline.Behavior.COMPLETE
        )
        val vm = OracleViewModel(fake)
        advanceUntilIdle()
        val (recorded, recordJob) = record(vm)
        vm.onQuestionChanged("q"); vm.ask()
        advanceUntilIdle()
        recordJob.cancel()

        assertTrue("a rejected draft was promoted to ANSWERED",
            recorded.none { it.phase == OraclePhase.ANSWERED })
        assertEquals(OraclePhase.REFUSED, vm.state.value.phase)
    }

    // MARK: - 4. Validation accepts a completed draft

    @Test
    fun testValidationAcceptsCompletedDraftPublishesExactlyOnce() = withMainDispatcher {
        val fake = FakeOraclePipeline(
            retrieval = retrieval(listOf(chunk("Rinse with 500 ml of water."))),
            warmUpResult = true,
            tokens = listOf("Rinse with 500 ml of water [1]."),
            behavior = FakeOraclePipeline.Behavior.COMPLETE
        )
        val vm = OracleViewModel(fake)
        advanceUntilIdle()
        val (recorded, recordJob) = record(vm)
        vm.onQuestionChanged("q"); vm.ask()
        advanceUntilIdle()
        recordJob.cancel()

        val answeredCount = recorded.count { it.phase == OraclePhase.ANSWERED }
        assertEquals("answer was published $answeredCount times", 1, answeredCount)
        assertEquals(OraclePhase.ANSWERED, vm.state.value.phase)
        assertEquals("Rinse with 500 ml of water [1].", vm.state.value.answer)
        // Citations are the validator-approved citations (chunk 1 only).
        assertEquals(1, vm.state.value.citations.size)
    }

    // MARK: - 5. A fake generator emits mismatched / uncited content

    @Test
    fun testFakeGeneratorMismatchesAreRejected() = withMainDispatcher {
        // 5a: 500 ml against evidence containing 500 mg.
        assertRejected("Rinse with 500 ml of water [1].", "Rinse with 500 mg of water.")
        // 5b: 5 ml per kg against evidence containing only 5 ml.
        assertRejected("Give 5 ml per kg of the solution [1].", "Give 5 ml of the solution.")
        // 5c: uncited trailing instruction (first clause cited, trailing is not).
        assertRejected("Apply pressure to the wound [1]. Keep the area clean.",
            "Apply pressure to the wound.")
    }

    private suspend fun TestScope.assertRejected(tokens: String, evidence: String) {
        val fake = FakeOraclePipeline(
            retrieval = retrieval(listOf(chunk(evidence))),
            warmUpResult = true, tokens = listOf(tokens),
            behavior = FakeOraclePipeline.Behavior.COMPLETE
        )
        val vm = OracleViewModel(fake)
        advanceUntilIdle()
        val (recorded, recordJob) = record(vm)
        vm.onQuestionChanged("q"); vm.ask()
        advanceUntilIdle()
        recordJob.cancel()
        assertTrue("an unsupported answer was accepted: $tokens vs $evidence",
            recorded.none { it.phase == OraclePhase.ANSWERED })
        assertEquals("expected REFUSED for '$tokens' vs '$evidence'",
            OraclePhase.REFUSED, vm.state.value.phase)
    }

    // MARK: - 6. Mutation / negative control: partial-token publication is detected

    @Test
    fun testMutationPublishingPartialTokensIsDetected() = withMainDispatcher {
        val tokens = listOf("LEAK1 ", "LEAK2 ")

        // The mutant republishes partial tokens to visible ANSWERED state during
        // generation (the exact regression the safety boundary prevents).
        val mutantFake = FakeOraclePipeline(
            retrieval = retrieval(listOf(chunk("Rinse with 500 ml of water."))),
            warmUpResult = true, tokens = tokens, behavior = FakeOraclePipeline.Behavior.PARK
        )
        val mutant = LeakyOracleViewModel(mutantFake)
        val mutantRecorded = mutableListOf<OracleUiState>()
        val mutantCollector = launch { mutant.state.toList(mutantRecorded) }
        advanceUntilIdle()
        mutant.ask(this, "q")
        advanceUntilIdle() // mutant publishes partials, then parks
        mutantCollector.cancel()
        mutant.cancel()
        advanceUntilIdle()

        // The detector MUST flag the mutant. This proves the runtime invariant
        // has teeth: if per-token UI publication is reintroduced, this check
        // fails against the mutant (it returns true = violation detected).
        assertTrue("negative control failed: partial-token publication was not detected",
            stateExposesPartialToken(mutantRecorded, tokens))

        // The production VM under the same input exposes no partial token.
        val fake = FakeOraclePipeline(
            retrieval = retrieval(listOf(chunk("Rinse with 500 ml of water."))),
            warmUpResult = true, tokens = tokens, behavior = FakeOraclePipeline.Behavior.PARK
        )
        val vm = OracleViewModel(fake)
        advanceUntilIdle()
        val (recorded, recordJob) = record(vm)
        vm.onQuestionChanged("q"); vm.ask()
        advanceUntilIdle() // parks mid-generation; partials stay local
        vm.cancelGeneration()
        advanceUntilIdle()
        recordJob.cancel()

        assertFalse("the production VM exposed a partial token",
            stateExposesPartialToken(recorded, tokens))
    }
}

// MARK: - Fakes

private class TestException : RuntimeException()

private class FakeOraclePipeline(
    var retrieval: RetrievalResult,
    var warmUpResult: Boolean = true,
    var tokens: List<String> = emptyList(),
    var behavior: Behavior = Behavior.COMPLETE
) : OraclePipeline {
    enum class Behavior { COMPLETE, THROW, PARK }

    private val parkGate = CompletableDeferred<Unit>()

    override suspend fun warmUp(): Boolean = warmUpResult
    override suspend fun retrieve(question: String): RetrievalResult = retrieval
    override fun release() {}

    override fun generate(question: String, retrieval: RetrievalResult): Flow<String> = flow {
        for (token in tokens) emit(token)
        when (behavior) {
            Behavior.COMPLETE -> { /* flow completes normally */ }
            Behavior.THROW -> throw TestException()
            Behavior.PARK -> parkGate.await() // never completes; cancelled externally
        }
    }

    // Reuse the production validator: no duplication of the fail-closed rules.
    override fun validate(answer: String, retrieval: RetrievalResult) =
        AnswerValidator().validate(answer, retrieval)
}

// MARK: - Mutation (negative control)

private class LeakyOracleViewModel(private val rag: OraclePipeline) {
    private val _state = MutableStateFlow(OracleUiState())
    val state: StateFlow<OracleUiState> = _state.asStateFlow()
    private var job: Job? = null

    /// Deliberately broken: publishes each partial token to visible ANSWERED
    /// state during generation. This is the regression the production
    /// OracleViewModel must prevent; the negative-control test proves the
    /// runtime detector catches it.
    fun ask(scope: CoroutineScope, question: String) {
        job = scope.launch {
            _state.value = _state.value.copy(streaming = true, phase = OraclePhase.RETRIEVING)
            val retrieval = rag.retrieve(question)
            if (!retrieval.passesConfidenceGate) {
                _state.value = _state.value.copy(phase = OraclePhase.REFUSED, refused = true)
                return@launch
            }
            _state.value = _state.value.copy(phase = OraclePhase.GENERATING)
            val draft = StringBuilder()
            try {
                rag.generate(question, retrieval).collect { token ->
                    draft.append(token)
                    // MUTATION: partial draft becomes visible state.
                    _state.value = _state.value.copy(phase = OraclePhase.ANSWERED, answer = draft.toString())
                }
            } catch (_: Throwable) {
                // The mutant swallows generation failure; whatever partial draft
                // accumulated is already visible (the defect under test).
            }
            val validation = rag.validate(draft.toString(), retrieval)
            if (validation.isValid) {
                _state.value = _state.value.copy(
                    phase = OraclePhase.ANSWERED,
                    answer = draft.toString().trim(),
                    citations = validation.citations
                )
            } else {
                _state.value = _state.value.copy(phase = OraclePhase.REFUSED, refused = true)
            }
        }
    }

    fun cancel() { job?.cancel() }
}