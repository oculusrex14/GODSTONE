package io.godstone.llm.rag

import java.math.BigDecimal
import java.util.Locale

data class AnswerValidationResult(
    val isValid: Boolean,
    val citations: List<Citation> = emptyList(),
    val reason: String? = null,
    val unsupported: List<String> = emptyList()
) {
    companion object {
        fun accepted(citations: List<Citation>) = AnswerValidationResult(true, citations)
        fun rejected(reason: String, unsupported: List<String> = emptyList()) =
            AnswerValidationResult(false, reason = reason, unsupported = unsupported)
    }
}

/**
 * Final, fail-closed validation for generated Oracle answers.
 *
 * The validator intentionally operates on the complete private draft. Callers must not
 * expose any draft bytes before this returns [AnswerValidationResult.isValid] == true.
 */
class AnswerValidator {
    private val citationPattern = Regex("\\[(\\d+)]")
    private val sentencePattern = Regex("(?s)(.*?(?:[.!?](?=\\s|$)|$))")
    private val imperativePattern = Regex(
        "(?i)^\\s*(apply|avoid|call|clean|cool|cover|do|drink|give|keep|move|never|" +
            "place|remove|rinse|seek|stop|take|use|wash)\\b"
    )
    private val injectionPattern = Regex(
        "(?i)(ignore (all |any |the )?(previous|prior|system) instructions|" +
            "system prompt|developer message|jailbreak|do not cite|hide (the )?warning)"
    )
    private val warningPattern = Regex(
        "(?i)(?:warning|contraindicat(?:ion|ed)|do not|never|must not|seek (?:urgent |emergency )?help)[^.!?]*(?:[.!?]|$)"
    )

    fun validate(draft: String, retrieval: RetrievalResult): AnswerValidationResult {
        val answer = draft.trim()
        if (answer.isEmpty()) return AnswerValidationResult.rejected("empty answer")
        if (!retrieval.passesConfidenceGate) {
            return AnswerValidationResult.rejected("retrieval confidence gate did not allow generation")
        }
        if (injectionPattern.containsMatchIn(answer)) {
            return AnswerValidationResult.rejected("instruction-injection marker in generated answer")
        }

        val markerNumbers = citationPattern.findAll(answer)
            .mapNotNull { it.groupValues[1].toIntOrNull() }
            .toList()
        if (markerNumbers.isEmpty()) return AnswerValidationResult.rejected("answer has no citation")
        if (markerNumbers.any { it !in 1..retrieval.chunks.size }) {
            return AnswerValidationResult.rejected("citation does not resolve to a retrieved chunk")
        }

        val unsupported = mutableListOf<String>()
        sentences(answer).forEach { sentence ->
            val body = citationPattern.replace(sentence, "").trim()
            if (body.isEmpty()) return@forEach
            val sentenceMarkers = citationPattern.findAll(sentence)
                .mapNotNull { it.groupValues[1].toIntOrNull() }
                .distinct()
                .toList()
            val highRisk = isHighRiskSentence(body, retrieval)
            if (highRisk && sentenceMarkers.isEmpty()) {
                unsupported += "uncited high-risk instruction: $body"
                return@forEach
            }

            val quantities = QuantityValidator.extract(body)
            if (quantities.isNotEmpty()) {
                if (sentenceMarkers.isEmpty()) {
                    unsupported += "uncited quantity: $body"
                } else {
                    val cited = sentenceMarkers.map { retrieval.chunks[it - 1] }
                    unsupported += QuantityValidator.unsupported(body, quantities, cited)
                }
            }
        }

        val citedChunks = markerNumbers.distinct().map { retrieval.chunks[it - 1] }
        unsupported += missingWarnings(answer, citedChunks)
        if (unsupported.isNotEmpty()) {
            return AnswerValidationResult.rejected("answer is not fully supported", unsupported)
        }

        val citations = markerNumbers.distinct().map { number ->
            val chunk = retrieval.chunks[number - 1]
            Citation(chunk.documentId, chunk.documentTitle, chunk.domain, chunk.text.take(180))
        }
        return AnswerValidationResult.accepted(citations)
    }

    private fun sentences(text: String): List<String> = sentencePattern.findAll(text)
        .map { it.value.trim() }
        .filter { it.isNotEmpty() }
        .toList()

    private fun isHighRiskSentence(sentence: String, retrieval: RetrievalResult): Boolean {
        if (imperativePattern.containsMatchIn(sentence)) return true
        val highRiskDomain = retrieval.chunks.any {
            it.domain.lowercase(Locale.ROOT) in HIGH_RISK_DOMAINS
        }
        return highRiskDomain && QuantityValidator.extract(sentence).isNotEmpty()
    }

    private fun missingWarnings(answer: String, citedChunks: List<Chunk>): List<String> {
        val answerTokens = meaningfulTokens(answer)
        return citedChunks.flatMap { chunk ->
            warningPattern.findAll(chunk.text).mapNotNull { match ->
                val warning = match.value.trim()
                val required = meaningfulTokens(warning)
                // Warning preservation is semantic-token based and intentionally strict.
                val overlap = if (required.isEmpty()) 1.0 else {
                    required.count { it in answerTokens }.toDouble() / required.size
                }
                if (overlap < WARNING_TOKEN_COVERAGE) {
                    "required warning omitted from ${chunk.documentTitle}: $warning"
                } else null
            }.toList()
        }.distinct()
    }

    private fun meaningfulTokens(text: String): Set<String> = TOKEN.findAll(text.lowercase(Locale.ROOT))
        .map { it.value }
        .filter { it.length >= 3 && it !in STOP_WORDS }
        .toSet()

    companion object {
        private val TOKEN = Regex("[a-z0-9]+")
        private const val WARNING_TOKEN_COVERAGE = 0.60
        private val HIGH_RISK_DOMAINS = setOf(
            "medical", "first_aid", "medicine", "chemical", "water", "food_safety", "emergency"
        )
        private val STOP_WORDS = setOf(
            "and", "the", "for", "with", "from", "that", "this", "your", "you", "are", "not"
        )
    }
}

enum class UnitDimension { MASS, VOLUME, TIME, LENGTH, TEMPERATURE, PERCENT, COUNT }

data class CanonicalQuantity(
    val value: BigDecimal,
    val unit: String,
    val dimension: UnitDimension,
    val qualifier: String?,
    val raw: String
)

/** Exact quantity provenance. Bare-number support is deliberately forbidden. */
object QuantityValidator {
    private val pattern = Regex(
        "(?i)\\b(\\d+(?:\\.\\d+)?)\\s*(mcg|µg|mg|g|kg|ml|mL|l|L|%|" +
            "minutes?|mins?|hours?|hrs?|days?|cm|mm|°?c|°?f|drops?)" +
            "((?:\\s*(?:/|per)\\s*(?:kg|kilograms?|l|litres?|liters?|day|hours?))?)\\b"
    )

    fun extract(text: String): List<CanonicalQuantity> = pattern.findAll(text).map { match ->
        val value = match.groupValues[1].toBigDecimal().stripTrailingZeros()
        val unit = canonicalUnit(match.groupValues[2])
        val qualifier = canonicalQualifier(match.groupValues[3])
        CanonicalQuantity(value, unit, dimension(unit), qualifier, match.value)
    }.toList()

    fun unsupported(
        sentence: String,
        quantities: List<CanonicalQuantity>,
        citedChunks: List<Chunk>
    ): List<String> {
        if (citedChunks.isEmpty()) return quantities.map { "uncited quantity: ${it.raw}" }
        return quantities.mapNotNull { answerQuantity ->
            val supported = citedChunks.any { chunk ->
                extract(chunk.text).any { evidence ->
                    answerQuantity.value.compareTo(evidence.value) == 0 &&
                        answerQuantity.unit == evidence.unit &&
                        answerQuantity.dimension == evidence.dimension &&
                        answerQuantity.qualifier == evidence.qualifier &&
                        contextSupported(sentence, chunk.text)
                }
            }
            if (supported) null else "unsupported quantity/unit/context: ${answerQuantity.raw}"
        }
    }

    private fun contextSupported(sentence: String, evidence: String): Boolean {
        val answerTerms = contextTerms(sentence)
        if (answerTerms.isEmpty()) return false
        val evidenceTerms = contextTerms(evidence)
        return answerTerms.count { it in evidenceTerms } >= minOf(2, answerTerms.size)
    }

    private fun contextTerms(text: String): Set<String> = Regex("[a-zA-Z]{3,}")
        .findAll(text.lowercase(Locale.ROOT))
        .map { it.value }
        .filter { it !in CONTEXT_STOP_WORDS }
        .toSet()

    private fun canonicalUnit(raw: String): String = when (raw.lowercase(Locale.ROOT)) {
        "µg", "mcg" -> "mcg"
        "ml" -> "ml"
        "l" -> "l"
        "minute", "minutes", "min", "mins" -> "min"
        "hour", "hours", "hr", "hrs" -> "h"
        "day", "days" -> "d"
        "°c", "c" -> "degC"
        "°f", "f" -> "degF"
        "drop", "drops" -> "drop"
        else -> raw.lowercase(Locale.ROOT)
    }

    private fun canonicalQualifier(raw: String): String? {
        if (raw.isBlank()) return null
        return raw.lowercase(Locale.ROOT)
            .replace(Regex("\\s+"), "")
            .replace("kilogram", "kg")
            .replace("kilograms", "kg")
            .replace("litres", "l")
            .replace("liters", "l")
            .replace("litre", "l")
            .replace("liter", "l")
            .replace("per", "/")
    }

    private fun dimension(unit: String): UnitDimension = when (unit) {
        "mcg", "mg", "g", "kg" -> UnitDimension.MASS
        "ml", "l" -> UnitDimension.VOLUME
        "min", "h", "d" -> UnitDimension.TIME
        "cm", "mm" -> UnitDimension.LENGTH
        "degC", "degF" -> UnitDimension.TEMPERATURE
        "%" -> UnitDimension.PERCENT
        "drop" -> UnitDimension.COUNT
        else -> error("unhandled unit: $unit")
    }

    private val CONTEXT_STOP_WORDS = setOf(
        "and", "the", "for", "with", "from", "into", "onto", "that", "this", "then", "use"
    )
}
