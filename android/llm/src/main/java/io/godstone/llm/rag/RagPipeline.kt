package io.godstone.llm.rag

import io.godstone.llm.ModelManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.withContext

/**
 * Retrieval-Augmented Generation pipeline.
 *
 * Order matters and is enforced here: RETRIEVE, then GATE, then GENERATE.
 * Generation is never reached when the archive does not support an answer.
 */
class RagPipeline(
    private val models: ModelManager,
    private val retriever: Retriever,
    private val topK: Int
) {

    suspend fun warmUp(): Boolean = withContext(Dispatchers.IO) {
        models.load()
    }

    suspend fun retrieve(question: String): RetrievalResult =
        withContext(Dispatchers.IO) {
            retriever.retrieve(question, topK)
        }

    fun generate(question: String, retrieval: RetrievalResult): Flow<String> {
        if (!retrieval.passesConfidenceGate) return emptyFlow()
        if (!models.isLoaded) return emptyFlow()

        val prompt = PromptBuilder().build(question, retrieval)
        return models.generate(prompt, MAX_ANSWER_TOKENS)
    }

    /**
     * Map the bracketed markers the model produced back to real documents, so
     * every claim on screen is tappable through to its source manual.
     */
    fun extractCitations(answer: String, retrieval: RetrievalResult): List<Citation> {
        val used = Regex("\\[(\\d+)]")
            .findAll(answer)
            .mapNotNull { it.groupValues[1].toIntOrNull() }
            .filter { it in 1..retrieval.chunks.size }
            .distinct()
            .toList()

        return used.map { n ->
            val c = retrieval.chunks[n - 1]
            Citation(c.documentId, c.documentTitle, c.domain, c.text.take(180))
        }
    }

    fun release() = models.release()

    companion object {
        const val MAX_ANSWER_TOKENS = 512
    }
}
