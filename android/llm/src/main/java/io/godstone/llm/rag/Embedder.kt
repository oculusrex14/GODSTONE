package io.godstone.llm.rag

import android.content.Context
import java.io.File

/**
 * Query embedder over the BGE embedding model.
 *
 * TWO DEFECTS THIS CLOSES.
 *
 * 1. `Retriever.vectorSearch` called `Embedder.embed(query)` and no `Embedder`
 *    existed anywhere in the tree. That is a straight compile error in the
 *    shipping retrieval path, invisible to every Python invariant because
 *    Kotlin is never compiled in the verification environment.
 *
 * 2. The archive's vectors are produced by content/ingest/embedder.py using
 *    bge-small/bge-base. Embedding a query with the QWEN GENERATION model --
 *    which is what the iOS side did -- puts the query in a completely different
 *    vector space. Cosine similarity between two unrelated spaces is noise, so
 *    every semantic score would have been meaningless while looking perfectly
 *    healthy. The embedding model is therefore pinned to the same GGUF the
 *    archive was built with, and the dimension is asserted against
 *    archive_meta.embed_dim at open time.
 */
class Embedder(
    private val context: Context,
    private val embedModelAsset: String,
    private val expectedDim: Int
) {
    private val bridge = io.godstone.llm.LlamaBridge()

    /** Separate from the generation model on purpose; see defect 2 above. */
    fun ensureLoaded(): Boolean {
        if (bridge.isLoaded) return true
        val dest = File(context.filesDir, embedModelAsset)
        if (!dest.exists()) {
            context.assets.open(embedModelAsset).use { input ->
                dest.outputStream().use { out -> input.copyTo(out) }
            }
        }
        // 512 context is ample for a question and keeps the footprint small.
        return bridge.load(dest.absolutePath, 512, 2)
    }

    /**
     * L2-normalised query vector, or null when the model is unavailable.
     *
     * Null means "no semantic candidates", NOT "score everything zero": the
     * retriever must degrade to lexical-only rather than fabricate similarity.
     */
    fun embed(query: String): FloatArray? {
        if (!ensureLoaded()) return null
        val raw = bridge.embed(query) ?: return null
        if (raw.size != expectedDim) {
            // A dimension mismatch means the archive and the model disagree --
            // exactly defect 2. Fail closed rather than compare noise.
            return null
        }
        var norm = 0.0
        for (v in raw) norm += v.toDouble() * v
        val n = if (norm > 0) Math.sqrt(norm).toFloat() else 1f
        return FloatArray(raw.size) { raw[it] / n }
    }

    fun release() = bridge.release()
}
