package io.godstone.llm.rag

import kotlin.math.sqrt

/**
 * The pure retrieval arithmetic, extracted from [Retriever] so it can be executed
 * and falsified without an Android `Context`, a SQLite archive or a native model.
 *
 * WHY THIS EXISTS (T64). The card requires cases -- "same dimension different
 * model", "corrupt NaN vectors", "deterministic ranking" -- that are pure logic
 * over a query vector and a stored vector. While that arithmetic lived as
 * `private fun` inside a class needing a `Context`, the only way to "test" it was
 * to RETYPE it in the test, and a court that asserts its own copy proveth nothing
 * about the shipping code: mutate the production sort and the copy stays green.
 *
 * These functions are the SAME code the retriever calls; `Retriever` delegates
 * here, so there is exactly one implementation and a court that drives this
 * drives production.
 */
object VectorRanking {

    /**
     * Cosine similarity between an L2-normalised float query and an int8 blob,
     * or [Double.NaN] when the candidate must be EXCLUDED.
     *
     * NaN IS NOT ZERO. A dismissed candidate is not a poor match: it is a vector
     * the retriever cannot reason about at all, and returning 0.0 would place it
     * in the ranking as though it had been measured.
     */
    fun cosineInt8(query: FloatArray, blob: ByteArray): Double {
        // Comparing only a shared prefix silently mixes incompatible embedding
        // spaces. A dimension mismatch is archive/model corruption.
        if (query.isEmpty() || blob.size != query.size) return Double.NaN
        // NON-FINITE SCREENING. A NaN or infinite component poisons the
        // accumulator, every score becomes NaN, and Kotlin's sort orders NaN
        // inconsistently -- so the ranking would depend on comparison order
        // rather than on the vectors.
        for (v in query) if (!v.isFinite()) return Double.NaN
        var dot = 0.0
        var normB = 0.0
        for (i in query.indices) {
            val b = blob[i].toDouble() / 127.0
            if (!b.isFinite()) return Double.NaN
            dot += query[i] * b
            normB += b * b
        }
        var normA = 0.0
        for (v in query) normA += v * v
        val denom = sqrt(normA) * sqrt(normB)
        if (denom == 0.0) return 0.0
        val score = dot / denom
        return if (score.isFinite()) score else Double.NaN
    }

    /**
     * Deterministic top-k over `(id, score)` pairs: descending score, then
     * ASCENDING ID.
     *
     * THE ID TIE-BREAK IS THE POINT. Kotlin's sort is stable, which means equal
     * scores keep whatever order the caller supplied -- and the caller here is a
     * SQLite cursor, whose order is not guaranteed and is not the same twice.
     * A stable-by-accident order is not a deterministic one, so the card's
     * "deterministic ranking" requirement was unmet until this tie-break existed.
     *
     * Non-finite scores are EXCLUDED rather than ranked: they are not scores.
     */
    fun topK(rows: List<Pair<Long, Double>>, limit: Int): List<Pair<Long, Double>> =
        rows.filter { it.second.isFinite() }
            .sortedWith(compareByDescending<Pair<Long, Double>> { it.second }.thenBy { it.first })
            .take(limit)

    /**
     * The same deterministic tie-break for Reciprocal Rank Fusion, whose
     * accumulator is a HashMap and would otherwise rank by iteration order.
     */
    fun fusedTopK(scores: Map<Long, Double>, topK: Int): List<Pair<Long, Double>> =
        scores.entries
            .sortedWith(compareByDescending<Map.Entry<Long, Double>> { it.value }.thenBy { it.key })
            .take(topK)
            .map { it.key to it.value }

    /**
     * L2-normalise a raw query vector, or return null when it cannot be used.
     *
     * REJECTED, NOT ADJUSTED: a vector that is non-finite, zero-length, or all
     * zeros carries no usable direction. Returning it normalised would be a lie
     * (there is nothing to normalise) and returning it raw would put an
     * unnormalised vector into a cosine comparison that assumes unit length.
     * Both are refused by name.
     */
    fun l2Normalised(raw: FloatArray?): FloatArray? {
        if (raw == null || raw.isEmpty()) return null
        for (v in raw) if (!v.isFinite()) return null
        var norm = 0.0
        for (v in raw) norm += v.toDouble() * v
        if (norm <= 0.0) return null      // a zero vector has no direction
        val n = sqrt(norm).toFloat()
        if (!n.isFinite() || n == 0f) return null
        return FloatArray(raw.size) { raw[it] / n }
    }

    /**
     * The capability decision the card requires: with no query vector, semantic
     * retrieval is UNAVAILABLE and lexical is selected, WITH AN EXPLICIT REASON.
     * The reason is returned rather than logged, so a caller cannot mistake
     * "semantic did not run" for "semantic ran and found nothing".
     */
    fun selectMode(queryVector: FloatArray?): Pair<Mode, String> =
        if (queryVector == null) {
            Mode.LEXICAL to "semantic retrieval UNAVAILABLE: no embedding model; lexical selected"
        } else {
            Mode.SEMANTIC to "semantic retrieval eligible"
        }

    enum class Mode { LEXICAL, SEMANTIC }
}
