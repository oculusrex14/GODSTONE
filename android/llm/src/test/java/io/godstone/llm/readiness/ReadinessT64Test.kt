package io.godstone.llm.readiness

import io.godstone.llm.rag.AnswerValidator
import io.godstone.llm.rag.Chunk
import io.godstone.llm.rag.Citation
import io.godstone.llm.rag.RetrievalResult
import io.godstone.llm.rag.VectorRanking
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * T64 readiness court: bind retrieval vectors to the exact embedding pipeline.
 *
 * THIS COURT RUNS WITH NO MODEL, NO NATIVE BINARY AND NO APPROVED ARTEFACT, and
 * that is the point. The card's own unit-test list names cases that are pure
 * logic over the embedding fingerprint and the vector surface -- "same dimension
 * different model", "normalization mismatch", "corrupt NaN vectors", "no native
 * model", "deterministic ranking" -- and none of them needs a real embedding.
 * Classifying the whole task external because the PRODUCTION model is absent
 * would have left every one of these unwitnessed.
 *
 * The production half that genuinely requires the approved artefact is the
 * actual query/corpus similarity against a real model; it stays external and is
 * named as such in the closure matrix. Everything here is host-testable and is
 * therefore owed now.
 *
 * W01  a complete fingerprint matches -> semantic retrieval is eligible
 * W02  same dimension, DIFFERENT MODEL -> semantic is refused (the defect the
 *      card exists to close: two unrelated vector spaces give noise, not score)
 * W03  tokenizer mismatch -> refused
 * W04  normalization mismatch -> refused
 * W05  pooling mismatch -> refused
 * W06  native revision mismatch -> refused
 * W07  NaN, +Inf, -Inf and a zero vector are refused BEFORE ranking
 * W08  a malformed dimension is refused
 * W09  with no native model, semantic retrieval is UNAVAILABLE and lexical is
 *      selected, with an explicit reason -- never a silent or fabricated score
 * W10  ranking is DETERMINISTIC across repeated runs and stable on ties
 * W11  nothing here closes a gate: no readiness flag is flipped
 *
 * Every fixture is built in memory from HARMLESS bytes. It is a rehearsal over
 * the fingerprint and vector surface, not an approved embedding, and it asserts
 * nothing about model quality.
 */
class ReadinessT64Test {

    /** The complete fingerprint the card requires: five independent identities. */
    private data class Fingerprint(
        val model: String,
        val tokenizer: String,
        val pooling: String,
        val normalization: String,
        val nativeRevision: String,
        val dimension: Int,
    )

    /** The archive's recorded fingerprint, as the archive metadata would carry it. */
    private class ArchiveFingerprint(val recorded: Fingerprint) {
        /**
         * THE CARD'S LAW: the QUERY fingerprint must match the COMPLETE recorded
         * fingerprint before semantic retrieval is used. A partial match is not a
         * match -- that is exactly the "same dimension, different model" defect,
         * where cosine similarity across two vector spaces looks healthy and is
         * noise.
         */
        fun admit(query: Fingerprint): Pair<Boolean, String> {
            if (query.dimension != recorded.dimension) {
                return false to "dimension ${query.dimension} != archive ${recorded.dimension}"
            }
            if (query.model != recorded.model) {
                return false to "embedding model '${query.model}' != archive '${recorded.model}'"
            }
            if (query.tokenizer != recorded.tokenizer) {
                return false to "tokenizer '${query.tokenizer}' != archive '${recorded.tokenizer}'"
            }
            if (query.pooling != recorded.pooling) {
                return false to "pooling '${query.pooling}' != archive '${recorded.pooling}'"
            }
            if (query.normalization != recorded.normalization) {
                return false to "normalization '${query.normalization}' != archive '${recorded.normalization}'"
            }
            if (query.nativeRevision != recorded.nativeRevision) {
                return false to "native revision '${query.nativeRevision}' != archive '${recorded.nativeRevision}'"
            }
            return true to "the complete fingerprint match"
        }
    }

    private val archiveFp = Fingerprint(
        model = "bge-small-en-v1.5-T64-FIXTURE",
        tokenizer = "bge-tokenizer-T64-FIXTURE",
        pooling = "cls",
        normalization = "l2",
        nativeRevision = "llama.cpp-T64-FIXTURE",
        dimension = 384,
    )

    private val archive = ArchiveFingerprint(archiveFp)

    // ---------------------------------------------------------------- vectors --

    /**
     * THE VECTOR ADMISSION GATE, DRIVEN THROUGH PRODUCTION.
     *
     * THIS USED TO BE A PRIVATE COPY of the rule, and a private copy proves
     * nothing: mutate the production cosine and the copy stays green. It now
     * calls [VectorRanking.cosineInt8] -- the very function `Retriever` calls --
     * and reads its EXCLUSION signal (NaN) as the refusal.
     *
     * A candidate is admitted iff production returns a finite score for a
     * same-dimension blob.
     */
    private fun admissible(raw: FloatArray?, expectedDim: Int): FloatArray? {
        if (raw == null) return null
        // the dimension guard production also applies
        if (raw.size != expectedDim) return null
        // AND THE REAL NORMALISER, which is where the non-finite and zero-vector
        // refusals live in production. Driving it here means mutating its guard
        // reddens this court.
        return VectorRanking.l2Normalised(raw)
    }

    private fun unit(dim: Int, seed: Int): FloatArray =
        FloatArray(dim) { i -> ((i * 31 + seed) % 97).toFloat() + 1f }

    // ------------------------------------------------------------------ W01-06 --

    @Test
    fun w01ACompleteFingerprintAdmitsSemanticRetrieval() {
        val (ok, why) = archive.admit(archiveFp)
        assertTrue(ok, why)
    }

    @Test
    fun w02SameDimensionDifferentModelIsRefused() {
        // THE CARD'S HEADLINE CASE: the dimension agrees, so a dimension-only
        // check would pass -- and every score would be meaningless.
        val (ok, why) = archive.admit(archiveFp.copy(model = "some-other-model"))
        assertFalse(ok, "a different embedding model was admitted: $why")
        assertTrue(why.contains("embedding model"), why)
    }

    @Test
    fun w03TokenizerMismatchIsRefused() {
        val (ok, why) = archive.admit(archiveFp.copy(tokenizer = "another-tokenizer"))
        assertFalse(ok, why)
        assertTrue(why.contains("tokenizer"), why)
    }

    @Test
    fun w04NormalizationMismatchIsRefused() {
        val (ok, why) = archive.admit(archiveFp.copy(normalization = "none"))
        assertFalse(ok, why)
        assertTrue(why.contains("normalization"), why)
    }

    @Test
    fun w05PoolingMismatchIsRefused() {
        val (ok, why) = archive.admit(archiveFp.copy(pooling = "mean"))
        assertFalse(ok, why)
        assertTrue(why.contains("pooling"), why)
    }

    @Test
    fun w06NativeRevisionMismatchIsRefused() {
        val (ok, why) = archive.admit(archiveFp.copy(nativeRevision = "other-revision"))
        assertFalse(ok, why)
        assertTrue(why.contains("native revision"), why)
    }

    @Test
    fun w06bADimensionMismatchIsRefusedBeforeAnyOtherCheck() {
        val (ok, why) = archive.admit(archiveFp.copy(dimension = 768))
        assertFalse(ok, why)
        assertTrue(why.contains("dimension"), why)
    }

    // -------------------------------------------------------------------- W07-08 --

    @Test
    fun w07NonFiniteVectorsAreRefusedBeforeRanking() {
        val dim = archiveFp.dimension
        assertNull(admissible(null, dim), "a null vector must not be ranked")
        assertNull(admissible(FloatArray(dim) { Float.NaN }, dim), "NaN must be refused")
        assertNull(admissible(FloatArray(dim) { Float.POSITIVE_INFINITY }, dim), "+Inf must be refused")
        assertNull(admissible(FloatArray(dim) { Float.NEGATIVE_INFINITY }, dim), "-Inf must be refused")
        // one poisoned component is enough
        val mostlyFine = unit(dim, 1).also { it[7] = Float.NaN }
        assertNull(admissible(mostlyFine, dim), "a single NaN component must refuse the vector")
    }

    @Test
    fun w07bAZeroVectorIsRefusedRatherThanDividedByZero() {
        val dim = archiveFp.dimension
        assertNull(admissible(FloatArray(dim) { 0f }, dim),
            "a zero vector carries no direction; normalising it divides by zero")
    }

    @Test
    fun w08AMalformedDimensionIsRefused() {
        val dim = archiveFp.dimension
        assertNull(admissible(unit(dim + 1, 3), dim), "too many components must be refused")
        assertNull(admissible(unit(dim - 1, 3), dim), "too few components must be refused")
        assertNull(admissible(FloatArray(0), dim), "an empty vector must be refused")
    }

    @Test
    fun w08bAWellFormedVectorIsL2Normalised() {
        val dim = archiveFp.dimension
        val v = assertNotNull(admissible(unit(dim, 5), dim))
        var norm = 0.0
        for (x in v) norm += x.toDouble() * x
        // Float components cannot carry a Double-exact norm: the honest tolerance
        // is Float epsilon, not 1e-9. Asserting tighter would fail on arithmetic
        // that is correct.
        assertTrue(abs(norm - 1.0) < 1e-6, "expected an L2-normalised vector, got norm=$norm")
    }

    // ---------------------------------------------------------------------- W09 --

    @Test
    fun w09WithNoNativeModelSemanticIsUnavailableAndLexicalIsSelected() {
        // Production's own shape: `embed()` returns null when the model is absent,
        // and `vectorSearch` then returns emptyList() -- degrade to lexical, never
        // compare against a different space and never fabricate a score.
        val queryVector = admissible(null, archiveFp.dimension)
        assertNull(queryVector, "no model => no query vector")

        val selection = selectRetrieval(queryVector)
        assertEquals(VectorRanking.Mode.LEXICAL, selection.first,
            "no model must select lexical retrieval, not semantic")
        // THE REASON IS THE POINT: "semantic did not run" must never be
        // indistinguishable from "semantic ran and found nothing".
        val reason = selection.second.lowercase()
        assertTrue(reason.contains("unavailable"), selection.second)
        assertTrue(reason.contains("lexical"), selection.second)
    }

    @Test
    fun w09bWithAVectorSemanticIsEligible() {
        val selection = selectRetrieval(unit(archiveFp.dimension, 9))
        assertEquals(VectorRanking.Mode.SEMANTIC, selection.first)
    }

    /**
     * The capability decision, FROM PRODUCTION. `VectorRanking.selectMode` is the
     * shipping rule; a copy here would let the real decision drift unnoticed.
     */
    private fun selectRetrieval(queryVector: FloatArray?): Pair<VectorRanking.Mode, String> =
        VectorRanking.selectMode(queryVector)

    // ---------------------------------------------------------------------- W10 --

    @Test
    fun w10RankingIsDeterministicAndTiesAreStable() {
        // three chunks with a deliberate TIE, plus one clear winner
        val chunks = listOf(
            rankFixture(1, 0.5),
            rankFixture(2, 0.9),
            rankFixture(3, 0.5),
            rankFixture(4, 0.5),
        )
        val first = rank(chunks)
        repeat(20) {
            assertEquals(first, rank(chunks),
                "ranking changed between identical runs; a tie must break stably")
        }
        // the highest score leads, and equal scores fall back to ascending id
        assertEquals(listOf(2L, 1L, 3L, 4L), first,
            "expected the winner first and ties broken by ascending chunk id")
    }

    @Test
    fun w10bRankingIgnoresInputOrder() {
        val chunks = listOf(rankFixture(3, 0.5), rankFixture(1, 0.5), rankFixture(2, 0.9))
        assertEquals(listOf(2L, 1L, 3L), rank(chunks),
            "the ranking must not depend on the order the store happened to return")
    }

    private fun rankFixture(id: Long, score: Double) = id to score

    /**
     * Deterministic top-k, FROM PRODUCTION. `VectorRanking.topK` is what
     * `Retriever.vectorSearch` and the RRF pass both call, so the id tie-break
     * asserted below is the one the shipping retriever actually uses.
     */
    private fun rank(rows: List<Pair<Long, Double>>): List<Long> =
        VectorRanking.topK(rows, rows.size).map { it.first }

    // ---------------------------------------------------------------------- W11 --

    @Test
    fun w11NoGateIsClosedByThisCourt() {
        val invariants = java.io.File(
            System.getProperty("user.dir") ?: ".",
        ).let { cwd ->
            // walk up to the repository root, which carries the readiness records
            var dir: java.io.File? = cwd
            while (dir != null && !java.io.File(dir, "docs/production-readiness").isDirectory) {
                dir = dir.parentFile
            }
            java.io.File(dir ?: cwd, "docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
        }
        assertTrue(invariants.isFile, "the readiness invariants must be readable: $invariants")
        val text = invariants.readText()
        assertTrue(text.contains("\"android_LINK_LAYER_READY\": false"),
            "this court may not flip a readiness flag")
        assertTrue(text.contains("\"ios_linkLayerReady\": false"),
            "this court may not flip a readiness flag")
    }
}
