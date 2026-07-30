package io.godstone.llm.rag

/**
 * Assembles the grounded prompt.
 *
 * The system rules are the single most safety-critical string in the product.
 * They are written to make refusal the default and invention impossible.
 */
object PromptBuilder {

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

    fun build(question: String, retrieval: RetrievalResult): String {
        val sb = StringBuilder()

        sb.append("<|im_start|>system\n")
        sb.append(SYSTEM_RULES)
        sb.append("\n<|im_end|>\n")

        sb.append("<|im_start|>user\n")
        sb.append("CONTEXT:\n")

        retrieval.chunks.forEachIndexed { i, c ->
            sb.append("[").append(i + 1).append("] ")
            sb.append("(").append(c.domain).append(" — ").append(c.documentTitle).append(")\n")
            sb.append(c.text.trim()).append("\n\n")
        }

        sb.append("QUESTION: ").append(question.trim()).append("\n")
        sb.append("<|im_end|>\n")
        sb.append("<|im_start|>assistant\n")

        return sb.toString()
    }
}
