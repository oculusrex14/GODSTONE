package io.godstone.llm.archive

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File

/** A document that can be opened without loading the language model. */
data class ArchiveDocument(
    val id: Long,
    val title: String,
    val domain: String,
    val isCritical: Boolean
)

/** A readable passage from the immutable on-device archive. */
data class ArchivePassage(
    val chunkId: Long,
    val documentId: Long,
    val documentTitle: String,
    val domain: String,
    val section: String,
    val text: String,
    val score: Double = 0.0
)

/**
 * Read-only browser over the bundled Archive.
 *
 * This path deliberately has no dependency on llama.cpp or an embedding model.
 * If generation, semantic search, or every radio fails, the user can still list
 * documents, search them with FTS5, and read complete passages.
 */
class ArchiveRepository(
    context: Context,
    private val archiveAsset: String
) {
    private val appContext = context.applicationContext
    private val db: SQLiteDatabase by lazy { openReadOnly() }

    val isAvailable: Boolean
        get() = runCatching { db.isOpen }.getOrDefault(false)

    fun listDocuments(domain: String? = null): List<ArchiveDocument> {
        val out = ArrayList<ArchiveDocument>()
        val where = if (domain.isNullOrBlank()) "" else "WHERE domain = ?"
        val args = if (domain.isNullOrBlank()) null else arrayOf(domain)
        db.rawQuery(
            "SELECT document_id, title, domain, is_critical FROM documents " +
                "$where ORDER BY is_critical DESC, domain, title",
            args
        ).use { c ->
            while (c.moveToNext()) {
                out += ArchiveDocument(
                    id = c.getLong(0),
                    title = c.getString(1),
                    domain = c.getString(2),
                    isCritical = c.getInt(3) != 0
                )
            }
        }
        return out
    }

    fun listDomains(): List<String> {
        val out = ArrayList<String>()
        db.rawQuery("SELECT DISTINCT domain FROM documents ORDER BY domain", null).use { c ->
            while (c.moveToNext()) out += c.getString(0)
        }
        return out
    }

    fun passages(documentId: Long): List<ArchivePassage> {
        val out = ArrayList<ArchivePassage>()
        db.rawQuery(
            """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text
            FROM chunks c JOIN documents d ON d.document_id = c.document_id
            WHERE c.document_id = ?
            ORDER BY c.ordinal
            """.trimIndent(),
            arrayOf(documentId.toString())
        ).use { c ->
            while (c.moveToNext()) out += c.toPassage()
        }
        return out
    }

    fun search(query: String, limit: Int = 40): List<ArchivePassage> {
        val safe = sanitiseFts(query)
        if (safe.isBlank()) return emptyList()
        val out = ArrayList<ArchivePassage>()
        db.rawQuery(
            """
            SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text,
                   bm25(chunks_fts) AS rank
            FROM chunks_fts
            JOIN chunks c ON c.chunk_id = chunks_fts.rowid
            JOIN documents d ON d.document_id = c.document_id
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """.trimIndent(),
            arrayOf(safe, limit.toString())
        ).use { c ->
            while (c.moveToNext()) out += c.toPassage(score = -c.getDouble(6))
        }
        return out
    }

    private fun android.database.Cursor.toPassage(score: Double = 0.0) = ArchivePassage(
        chunkId = getLong(0),
        documentId = getLong(1),
        documentTitle = getString(2),
        domain = getString(3),
        section = getString(4),
        text = getString(5),
        score = score
    )

    private fun openReadOnly(): SQLiteDatabase {
        val dest = File(appContext.filesDir, archiveAsset)
        if (!dest.exists()) {
            val tmp = File(dest.parentFile, dest.name + ".tmp")
            appContext.assets.open(archiveAsset).use { input ->
                tmp.outputStream().use { output ->
                    input.copyTo(output)
                    output.fd.sync()
                }
            }
            check(tmp.renameTo(dest) || dest.exists()) {
                "could not install archive asset $archiveAsset"
            }
            if (tmp.exists()) tmp.delete()
        }
        return SQLiteDatabase.openDatabase(
            dest.absolutePath,
            null,
            SQLiteDatabase.OPEN_READONLY
        ).apply {
            execSQL("PRAGMA query_only = ON")
            execSQL("PRAGMA mmap_size = 268435456")
        }
    }

    private fun sanitiseFts(value: String): String =
        value.replace(Regex("[\\\"*():^-]"), " ")
            .split(Regex("\\s+"))
            .filter { it.isNotBlank() }
            .joinToString(" OR ") { "\"$it\"" }
}
