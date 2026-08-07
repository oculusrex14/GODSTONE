package io.godstone.llm.rag

import io.godstone.llm.ModelManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.withContext

/** Retrieval, confidence gating, private generation, and final validation. */
class RagPipeline(
    private val models: ModelManager,
    private val retriever: Retriever,
    private val topK: Int,
    private val answerValidator: AnswerValidator = AnswerValidator()
) : OraclePipeline {
    override suspend fun warmUp(): Boolean = withContext(Dispatchers.IO) { models.load() }

    override suspend fun retrieve(question: String): RetrievalResult = withContext(Dispatchers.IO) {
        retriever.retrieve(question, topK)
    }

    /** The returned flow is private draft material and must never be bound to visible UI. */
    override fun generate(question: String, retrieval: RetrievalResult): Flow<String> {
        if (!retrieval.passesConfidenceGate || !models.isLoaded) return emptyFlow()
        return models.generate(PromptBuilder().build(question, retrieval), MAX_ANSWER_TOKENS)
    }

    override fun validate(answer: String, retrieval: RetrievalResult): AnswerValidationResult =
        answerValidator.validate(answer, retrieval)

    /** Retained for source browsing; validated UI paths use [AnswerValidationResult.citations]. */
    fun extractCitations(answer: String, retrieval: RetrievalResult): List<Citation> =
        validate(answer, retrieval).takeIf { it.isValid }?.citations ?: emptyList()

    override fun release() = models.release()

    companion object {
        const val MAX_ANSWER_TOKENS = 512
    }
}
