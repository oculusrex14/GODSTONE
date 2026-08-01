package io.godstone.llm.rag

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File
import kotlin.math.sqrt

data class Chunk(
    val chunkId: Long,
    val documentId: Long,
    val documentTitle: String,
    val domain: String,
    val text: String,
    val score: Double
)

data class Citation(
    val documentId: Long,
    val title: String,
    val domain: String,
    val snippet: String
)

data class RetrievalResult(
    val chunks: List<Chunk>,
    val bestScore: Double,
    val nearMisses: List<Citation>,
    /** Verdict from io.godstone.llm.safety.SafetyGate. Null = never gated = refuse. */
    val gateVerdict: io.godstone.llm.safety.SafetyGate.Result? = null
) {
    /**
     * Constraint C3.
     *
     * This used to read `bestScore >= 0.35` over a reciprocal-rank-fusion
     * score. The repository's own audit proved that rule cannot discriminate --
     * RRF's entire top-20 spans 0.500..0.381, so ANY BM25 hit passed -- and the
     * app shipped it anyway while the improved gate sat in the test harness.
     *
     * The verdict is now computed by SafetyGate.evaluate, the same logic the
     * probe suite exercises. `gateVerdict` is populated by Retriever.retrieve;
     * a result that never went through the gate is refused, so forgetting to
     * run it fails closed instead of silently allowing.
     */
    val passesConfidenceGate: Boolean
        get() = gateVerdict?.allowsGeneration ?: false
}

/**
 * Hybrid retrieval over the read-only Archive.
 *
 *   1. BM25 lexical search via FTS5  (exact, fast, great for "tourniquet")
 *   2. Cosine similarity over int8 vectors (semantic, catches paraphrase)
 *   3. Reciprocal Rank Fusion merges the two rankings
 *
 * Brute-force vector scan is deliberate. At LARGE tier that is ~400k int8 dot
 * products over 768 dims, about 150 ms on a mid-range 2023 SoC. That is well
 * inside budget and it removes an entire class of index-corruption failures.
 * Simplicity is a survival feature.
 */
class Retriever(
    private val context: Context,
    private val archiveAsset: String,
    private val embedder: Embedder? = null
) {
    /** Built once from the archive; drives the gate's vocabulary and IDF. */
    private val corpusIndex: io.godstone.llm.safety.SafetyGate.CorpusIndex by lazy {
        io.godstone.llm.safety.SafetyGate.CorpusIndex(allChunks())
    }

    private fun allChunks(): List<Chunk> {
        val out = ArrayList<Chunk>()
        db.rawQuery(
            "SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text " +
            "FROM chunks c JOIN documents d ON d.document_id = c.document_id", null
        ).use { cur ->
            while (cur.moveToNext()) out.add(Chunk(
                cur.getLong(0), cur.getLong(1), cur.getString(2),
                cur.getString(3), cur.getString(4), 0.0))
        }
        return out
    }

    private val db: SQLiteDatabase by lazy { openReadOnly() }

    private fun openReadOnly(): SQLiteDatabase {
        val dest = File(context.filesDir, archiveAsset)
        if (!dest.exists()) {
            context.assets.open(archiveAsset).use { input ->
                dest.outputStream().use { out -> input.copyTo(out) }
            }
        }
        val d = SQLiteDatabase.openDatabase(
            dest.absolutePath, null, SQLiteDatabase.OPEN_READONLY
        )
        d.execSQL("PRAGMA query_only = ON")
        d.execSQL("PRAGMA mmap_size = 268435456")
        return d
    }

    fun retrieve(query: String, topK: Int, domainHint: String? = null): RetrievalResult {
        val lexical = bm25Search(query, LEXICAL_CANDIDATES, domainHint)
        val semantic = vectorSearch(query, SEMANTIC_CANDIDATES, domainHint)
        val fused = reciprocalRankFusion(lexical, semantic, topK)

        val best = fused.firstOrNull()?.score ?: 0.0

        val verdict = io.godstone.llm.safety.SafetyGate.evaluate(query, fused, corpusIndex)

        val nearMisses = if (!verdict.allowsGeneration) {
            (lexical + semantic)
                .distinctBy { it.documentId }
                .take(3)
                .map { Citation(it.documentId, it.documentTitle, it.domain,
                                it.text.take(180)) }
        } else emptyList()

        return RetrievalResult(fused, best, nearMisses, verdict)
    }

    private fun bm25Search(query: String, limit: Int, domain: String?): List<Chunk> {
        val sql = """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text,
                   bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.chunk_id = chunks_fts.rowid
            JOIN documents d ON d.document_id = c.document_id
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
        """.trimIndent()

        val out = ArrayList<Chunk>()
        db.rawQuery(sql, arrayOf(sanitiseFts(query), limit.toString())).use { cur ->
            while (cur.moveToNext()) {
                out.add(
                    Chunk(
                        chunkId = cur.getLong(0),
                        documentId = cur.getLong(1),
                        documentTitle = cur.getString(2),
                        domain = cur.getString(3),
                        text = cur.getString(4),
                        // bm25() returns negative values, lower is better.
                        score = -cur.getDouble(5)
                    )
                )
            }
        }
        return out
    }

    private fun vectorSearch(query: String, limit: Int, domain: String?): List<Chunk> {
        // Null when no embedding model is available: degrade to lexical-only
        // rather than compare against a different vector space (see Embedder).
        val qvec = embedder?.embed(query) ?: return emptyList()
        val results = ArrayList<Pair<Long, Double>>()

        db.rawQuery("SELECT chunk_id, vec FROM vectors", null).use { cur ->
            while (cur.moveToNext()) {
                val id = cur.getLong(0)
                val blob = cur.getBlob(1)
                results.add(id to cosineInt8(qvec, blob))
            }
        }

        val top = results.sortedByDescending { it.second }.take(limit)
        return top.mapNotNull { (id, score) -> loadChunk(id, score) }
    }

    /**
     * Reciprocal Rank Fusion. Rank-based rather than score-based, so we never
     * have to normalise BM25 against cosine, which are not comparable scales.
     */
    private fun reciprocalRankFusion(
        lexical: List<Chunk>,
        semantic: List<Chunk>,
        topK: Int
    ): List<Chunk> {
        val scores = HashMap<Long, Double>()
        val byId = HashMap<Long, Chunk>()

        lexical.forEachIndexed { i, c ->
            scores[c.chunkId] = (scores[c.chunkId] ?: 0.0) + 1.0 / (RRF_K + i + 1)
            byId[c.chunkId] = c
        }
        semantic.forEachIndexed { i, c ->
            scores[c.chunkId] = (scores[c.chunkId] ?: 0.0) + 1.0 / (RRF_K + i + 1)
            byId[c.chunkId] = c
        }

        // Normalise to roughly 0..1 so the confidence gate is interpretable.
        val maxPossible = 2.0 / (RRF_K + 1)

        return scores.entries
            .sortedByDescending { it.value }
            .take(topK)
            .mapNotNull { (id, s) -> byId[id]?.copy(score = s / maxPossible) }
    }

    private fun loadChunk(chunkId: Long, score: Double): Chunk? {
        val sql = """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.text
            FROM chunks c JOIN documents d ON d.document_id = c.document_id
            WHERE c.chunk_id = ?
        """.trimIndent()

        db.rawQuery(sql, arrayOf(chunkId.toString())).use { cur ->
            if (!cur.moveToFirst()) return null
            return Chunk(
                cur.getLong(0), cur.getLong(1), cur.getString(2),
                cur.getString(3), cur.getString(4), score
            )
        }
    }

    private fun cosineInt8(query: FloatArray, blob: ByteArray): Double {
        // Comparing only a shared prefix silently mixes incompatible embedding
        // spaces. A dimension mismatch is archive/model corruption, so this
        // candidate receives the lowest possible score and semantic retrieval
        // degrades to the lexical path.
        if (query.isEmpty() || blob.size != query.size) return 0.0
        var dot = 0.0
        var normB = 0.0
        for (i in query.indices) {
            val b = blob[i].toDouble() / 127.0
            dot += query[i] * b
            normB += b * b
        }
        var normA = 0.0
        for (v in query) normA += v * v
        val denom = sqrt(normA) * sqrt(normB)
        return if (denom == 0.0) 0.0 else dot / denom
    }

    /** Strip FTS5 operators so a user's plain question cannot become a syntax error. */
    private fun sanitiseFts(q: String): String =
        q.replace(Regex("[\"*():^-]"), " ")
            .split(Regex("\\s+"))
            .filter { it.isNotBlank() }
            .joinToString(" OR ") { "\"" + it + "\"" }

    companion object {
        const val LEXICAL_CANDIDATES = 20
        const val SEMANTIC_CANDIDATES = 20
        const val RRF_K = 60.0
    }
}
