package io.godstone.llm.rag

import io.godstone.llm.safety.SafetyGate
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AnswerValidatorTest {
    private val validator = AnswerValidator()

    @Test fun exactQuantityAndCitationAreAccepted() {
        val result = validator.validate(
            "Rinse the container with 500 ml of clean water [1].",
            retrieval("Rinse the container with 500 ml of clean water.")
        )
        assertTrue(result.isValid, result.unsupported.joinToString())
    }

    @Test fun wrongUnitIsRejectedEvenWhenBareNumberMatches() {
        val result = validator.validate(
            "Rinse the container with 500 mg of clean water [1].",
            retrieval("Rinse the container with 500 ml of clean water.")
        )
        assertFalse(result.isValid)
    }

    @Test fun denominatorOmissionIsRejected() {
        val result = validator.validate(
            "Give 5 ml of the solution [1].",
            retrieval("Give 5 ml per kg of the solution.")
        )
        assertFalse(result.isValid)
    }

    @Test fun invalidCitationIsRejected() {
        assertFalse(validator.validate("Use 5 ml of water [2].", retrieval("Use 5 ml of water.")).isValid)
    }

    @Test fun uncitedHighRiskInstructionIsRejected() {
        assertFalse(validator.validate("Apply pressure to the wound.", retrieval("Apply pressure to the wound.")).isValid)
    }

    @Test fun requiredWarningMustBePreserved() {
        val result = validator.validate(
            "Use the medicine as directed [1].",
            retrieval("Use the medicine as directed. Do not use for children under 2.")
        )
        assertFalse(result.isValid)
    }

    /// (c) 10 minutes cannot approve 10 hours: value matches, time dimension
    /// matches, unit differs (min vs h) -> rejected.
    @Test fun wrongTimeUnitIsRejectedEvenWhenNumberMatches() {
        val result = validator.validate(
            "Allow the solution to rest for 10 minutes [1].",
            retrieval("Allow the solution to rest for 10 hours.")
        )
        assertFalse(result.isValid)
    }

    /// (e) An answer with no citation markers is rejected in full.
    @Test fun uncitedAnswerIsRejectedInFull() {
        assertFalse(validator.validate("Give 500 ml of water.", retrieval("Give 500 ml of water.")).isValid)
    }

    /// Invalid output is discarded in full: one unsupported quantity among two
    /// rejects the entire answer, never a partially-sanitised one.
    @Test fun invalidOutputIsDiscardedInFull() {
        val result = validator.validate(
            "Rinse with 500 ml of water [1], then wait 10 minutes [1].",
            retrieval("Rinse with 500 ml of water. Wait 10 hours.")
        )
        assertFalse(result.isValid)
    }

    private fun retrieval(text: String): RetrievalResult = RetrievalResult(
        chunks = listOf(Chunk(1, 1, "Reviewed source", "medical", text, 1.0)),
        bestScore = 1.0,
        nearMisses = emptyList(),
        gateVerdict = SafetyGate.Result(
            verdict = SafetyGate.Verdict.ALLOW,
            reasons = listOf("test fixture"),
            anchorRecall = 1.0,
            colocation = 1.0,
            domainCoherence = 1.0,
            oovTerms = emptyList()
        )
    )
}
