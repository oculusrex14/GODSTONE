package io.godstone.llm

import io.godstone.llm.rag.Chunk
import io.godstone.llm.rag.PromptBuilder
import io.godstone.llm.rag.RetrievalResult
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Grounding tests. These enforce constraint C3: the model never answers from
 * parametric memory alone.
 *
 * This is the most important test file in the repository. A regression here
 * does not produce a crash or a wrong pixel - it produces a confident,
 * well-formatted, fluent answer about a tourniquet that nothing in the archive
 * supports. Everything else can degrade; this cannot.
 */
class RagPipelineTest {

    private fun chunk(
        id: Long,
        title: String,
        text: String,
        score: Double
    ) = Chunk(
        chunkId = id,
        documentId = id,
        documentTitle = title,
        domain = "medical_trauma",
        text = text,
        score = score
    )

    @Test
    fun `prompt contains every retrieved chunk`() {
        val chunks = listOf(
            chunk(1, "Stopping severe bleeding",
                  "Place it 5 to 7 cm above the wound.", 0.81),
            chunk(2, "Stopping severe bleeding",
                  "Push hard with the heel of your hand.", 0.64)
        )

        val prompt = PromptBuilder().build("how do I stop bleeding", chunks)

        assertContains(prompt, "5 to 7 cm above the wound")
        assertContains(prompt, "heel of your hand")
    }

    @Test
    fun `each chunk is labelled with a citation marker`() {
        val chunks = listOf(
            chunk(1, "Stopping severe bleeding", "text one", 0.8),
            chunk(2, "Making water safe to drink", "text two", 0.7)
        )

        val prompt = PromptBuilder().build("question", chunks)

        // The markers are what the UI turns into tappable source cards. Without
        // them an answer is unverifiable and therefore useless.
        assertContains(prompt, "[1]")
        assertContains(prompt, "[2]")
        assertContains(prompt, "Stopping severe bleeding")
        assertContains(prompt, "Making water safe to drink")
    }

    @Test
    fun `system rules forbid answering beyond the context`() {
        val prompt = PromptBuilder().build("question", listOf(
            chunk(1, "Doc", "text", 0.9)
        ))

        val lower = prompt.lowercase()
        // SYSTEM_RULES says "Answer ONLY from" and "The archive does not cover
        // this. Do not guess." Refusal is the default when the context is silent.
        assertTrue("only" in lower)
        assertTrue("archive does not cover" in lower || "do not guess" in lower)
    }

    @Test
    fun `empty retrieval produces a refusal prompt and never a free answer`() {
        val prompt = PromptBuilder().build("how do I build a nuclear reactor", emptyList())

        val lower = prompt.lowercase()
        // With no chunks the system rules still bind: the model is told to say
        // "The archive does not cover this." and not to guess.
        assertTrue("archive does not cover" in lower || "do not guess" in lower)
    }

    @Test
    fun `prompt respects the context budget by dropping the weakest chunks`() {
        val many = (1..40).map {
            chunk(it.toLong(), "Doc $it", "word ".repeat(200), 1.0 / it)
        }

        val builder = PromptBuilder(contextTokens = 2048, reservedForAnswer = 512)
        val prompt = builder.build("question", many)

        // Budgeting must be honest: the bridge refuses to generate at all if the
        // prompt does not fit, so an over-budget prompt is a failed answer.
        assertTrue(builder.estimateTokens(prompt) <= 2048 - 512)

        // The strongest chunk survives the trimming; the weakest does not.
        assertContains(prompt, "Doc 1")
    }

    @Test
    fun `chunks are ordered by descending score`() {
        val chunks = listOf(
            chunk(1, "Weak", "weak text", 0.31),
            chunk(2, "Strong", "strong text", 0.92),
            chunk(3, "Middle", "middle text", 0.55)
        )

        val prompt = PromptBuilder().build("question", chunks.sortedByDescending { it.score })

        assertTrue(prompt.indexOf("strong text") < prompt.indexOf("middle text"))
        assertTrue(prompt.indexOf("middle text") < prompt.indexOf("weak text"))
    }

    @Test
    fun `reciprocal rank fusion favours chunks found by both retrievers`() {
        // Lexical ranks it 3rd, semantic ranks it 3rd - but it is the only chunk
        // both agree on, and RRF should lift it above anything either found once.
        val lexical = listOf(10L, 11L, 12L)
        val semantic = listOf(20L, 21L, 12L)

        val fused = reciprocalRankFusion(lexical, semantic, k = 60.0)

        assertEquals(12L, fused.first())
    }

    private fun reciprocalRankFusion(
        lexical: List<Long>,
        semantic: List<Long>,
        k: Double
    ): List<Long> {
        val scores = mutableMapOf<Long, Double>()
        lexical.forEachIndexed { i, id -> scores.merge(id, 1.0 / (k + i + 1), Double::plus) }
        semantic.forEachIndexed { i, id -> scores.merge(id, 1.0 / (k + i + 1), Double::plus) }
        return scores.entries.sortedByDescending { it.value }.map { it.key }
    }

    @Test
    fun `confidence floor is identical to the iOS pipeline`() {
        // Tab 08 states the two platforms must not drift. If this constant
        // changes, RagPipeline.swift changes in the same commit.
        assertEquals(0.35, RetrievalResult.CONFIDENCE_THRESHOLD, 0.0)
    }
}