package io.godstone.llm.rag

/**
 * Assembles the grounded prompt.
 *
 * The system rules are the single most safety-critical string in the product.
 * They are written to make refusal the default and invention impossible.
 */
class PromptBuilder(
    val contextTokens: Int = 2048,
    val reservedForAnswer: Int = 512
) {

    private val SYSTEM_RULES = """
        You are Godstone, an offline survival reference. You are being used by
        someone who may be injured, frightened, and without any other help.

        ABSOLUTE RULES:
        1. Answer ONLY from the numbered CONTEXT passages below. If the context
           does not contain the answer, say exactly: "The archive does not cover
           this." Do not guess. Do not use general knowledge.
        2. Cite every factual claim with the bracketed number of the passage it
           came from, like [2].
        3. Give steps in the order they must be performed. Put any action that
           prevents immediate death first.
        4. State dosages, ratios, times and temperatures exactly as written in the
           context. Never round, convert or estimate them yourself.
        5. If the context contains a warning or contraindication, you MUST include
           it. Never omit a safety warning to make an answer shorter.
        6. Be brief and concrete. Short sentences. No preamble, no reassurance,
           no filler. The user does not have time.
    """.trimIndent()

    fun build(question: String, retrieval: RetrievalResult): String =
        build(question, retrieval.chunks)

    fun build(question: String, chunks: List<Chunk>): String {
        // Strongest first: the model sees the most relevant passage earliest, and
        // any budget trimming drops the weakest material from the tail.
        val ranked = chunks.sortedByDescending { it.score }

        // Apply the context budget: drop the weakest chunks from the tail until
        // the prompt fits. Always keep at least the strongest chunk, even if it
        // alone exceeds the budget -- an over-budget single source is still safer
        // than an empty context.
        val budget = contextTokens - reservedForAnswer
        val kept = ranked.toMutableList()
        while (kept.size > 1 && estimateTokens(render(question, kept)) > budget) {
            kept.removeAt(kept.lastIndex)
        }

        return render(question, kept)
    }

    private fun render(question: String, chunks: List<Chunk>): String {
        val sb = StringBuilder()

        sb.append("<|im_start|>system\n")
        sb.append(SYSTEM_RULES)
        sb.append("\n<|im_end|>\n")

        sb.append("<|im_start|>user\n")
        sb.append("CONTEXT:\n")

        chunks.forEachIndexed { i, c ->
            sb.append("[").append(i + 1).append("] ")
            sb.append("(").append(c.domain).append(" — ").append(c.documentTitle).append(")\n")
            sb.append(c.text.trim()).append("\n\n")
        }

        sb.append("QUESTION: ").append(question.trim()).append("\n")
        sb.append("<|im_end|>\n")
        sb.append("<|im_start|>assistant\n")

        return sb.toString()
    }

    /**
     * Heuristic token estimate. Roughly four characters per token for English.
     * TODO: route through the model tokenizer via the native bridge so this
     * matches the model's real vocabulary instead of a length-based guess.
     */
    fun estimateTokens(text: String): Int = text.length / 4
}