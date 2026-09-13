package io.godstone.core.archive

import android.content.Context
import java.io.File

/**
 * Read-only browser over the bundled Archive -- the SHIPPING survival-knowledge
 * path. Lives in `:core` (the single shipping module the LIGHT app links) so the
 * Archive-only release reaches it WITHOUT pulling in the non-shipping `:llm`
 * (on-device model / Oracle / RAG) module. The Swift twin is
 * `GodstoneCore/ArchiveRepository.swift` (the LIGHT app links only `GodstoneCore`
 * on iOS too); the two are the cross-platform Archive contract.
 *
 * This path deliberately has no dependency on llama.cpp or an embedding model.
 * If generation, semantic search, or every radio fails, the user can still list
 * documents, search them with FTS5, and read complete passages.
 *
 * s17 law: nothing is served because a file happens to exist. Every byte is
 * installed through [ArchiveInstaller] -- bounded, digested against the trusted
 * manifest when one ships, staged, probed by the actual bundled engine
 * ([ArchiveDatabase]: required tables, FTS5 canary, integrity check) -- and
 * re-probed at serve time. The engine is the pinned AndroidX BUNDLED SQLite,
 * never the platform's, whose FTS5 availability is not a portable contract.
 * The outcome is typed: [ArchiveState.Ready] or [ArchiveState.Unavailable]
 * with its cause named. Search text never touches the MATCH grammar unquoted:
 * [SearchQuery] bounds the phrase (512), the distinct terms (32) and the page
 * (200), and every value reaches the engine through a bound parameter.
 */
data class ArchiveDocument(
    val id: Long,
    val title: String,
    val domain: String,
    val isCritical: Boolean,
    // T49 (s17): the source/revision projection of the frozen documents table.
    // Defaulted, that every sealed four-argument construction stayeth lawful.
    val sourceId: String = "",
    val revision: String = ""
)

/** The provenance projection shown when a document is opened whole (T49:
 *  'source/revision display'). A separate projection, that the sealed
 *  [ArchiveDocument] equality abideth undisturbed. */
data class ArchiveSourceMetadata(
    val documentId: Long,
    val title: String,
    val sourceId: String,
    val licence: String,
    val revision: String,
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

/** The typed availability of the browse path. Never a silent boolean. */
sealed class ArchiveState {
    data class Ready(val origin: String, val sha256: String) : ArchiveState()
    data class Unavailable(val reason: String) : ArchiveState()
}

/** The read face of the Archive, shared by the repository and its courts. */
interface ArchiveReader {
    fun listDocuments(domain: String? = null): List<ArchiveDocument>
    fun listDomains(): List<String>
    fun passages(documentId: Long): List<ArchivePassage>
    fun search(query: String, limit: Int = 40): List<ArchivePassage>

    /** T49 (s17): the typed availability of the read path. The default
     *  sayeth ready, that the sealed fakes compile unchanged; the real
     *  repository answereth with its arm's verdict and a court may make a
     *  fake report otherwise. An unavailable archive must never masquerade
     *  as an honest empty result -- the caller consulteth this first. */
    fun status(): ArchiveState = ArchiveState.Ready(origin = "assumed", sha256 = "")

    /** T49 (s17): the source/revision projection of one document, or null
     *  when the reader cannot speak of provenance. */
    fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? = null
}

/** The seam to the android world; the host court drive driveth a filesystem fake. */
interface ArchiveBridge {
    /** Bytes of a shipped asset, or null when the asset is not there. */
    fun assetBytes(name: String): ByteArray?

    /** The writable root under which the installed archive and its record live. */
    fun cacheRoot(): File
}

private class AndroidArchiveBridge(context: Context) : ArchiveBridge {
    private val appContext = context.applicationContext

    override fun assetBytes(name: String): ByteArray? =
        runCatching { appContext.assets.open(name).use { it.readBytes() } }.getOrNull()

    override fun cacheRoot(): File = File(appContext.filesDir, "archives")
}

class ArchiveRepository(
    private val bridge: ArchiveBridge,
    private val archiveAsset: String,
) : ArchiveReader {

    constructor(context: Context, archiveAsset: String) : this(
        AndroidArchiveBridge(context),
        archiveAsset,
    )

    private val installer = ArchiveInstaller(bridge.cacheRoot())

    /** The armed state: proven handle plus its typed verdict, computed once. */
    private class Arm(val state: ArchiveState, val handle: ArchiveDatabase?)

    private val arm: Arm by lazy { compute() }

    private fun factsOfManifest(): Pair<ArchiveManifestFacts?, String?> {
        val text = bridge.assetBytes("$archiveAsset.manifest")?.decodeToString()
        if (text == null) return null to null
        val parsed = try {
            ArchiveManifestFacts.fromJson(text)
        } catch (exc: Throwable) {
            return null to ("the trusted manifest is unreadable: " +
                (exc.message ?: exc::class.simpleName))
        }
        return parsed to null
    }

    private fun compute(): Arm {
        val (facts, manifestFault) = factsOfManifest()
        if (manifestFault != null) {
            return Arm(ArchiveState.Unavailable(manifestFault), null)
        }
        val outcome = installer.install({ bridge.assetBytes(archiveAsset) }, facts)
        val verdict = when (outcome) {
            is InstallOutcome.Selected, is InstallOutcome.Refreshed -> {
                val sha = when (outcome) {
                    is InstallOutcome.Selected -> outcome.sha256
                    is InstallOutcome.Refreshed -> outcome.sha256
                    else -> error("unreachable")
                }
                val handle = try {
                    ArchiveDatabase.openReadOnly(installer.currentFile(), ArchiveDrivers.required())
                } catch (exc: Throwable) {
                    return Arm(
                        ArchiveState.Unavailable(
                            "the proven bytes refused to open read-only: " +
                                (exc.message ?: exc::class.simpleName)),
                        null,
                    )
                }
                ArchiveState.Ready(origin = installer.currentFile().absolutePath, sha256 = sha) to handle
            }
            is InstallOutcome.Rejected ->
                (ArchiveState.Unavailable("install refused: " + outcome.cause) to null)
            is InstallOutcome.Unavailable ->
                (ArchiveState.Unavailable("install unavailable: " + outcome.reason) to null)
        }
        return Arm(verdict.first, verdict.second)
    }

    /** Typed availability; drives the UI's honest empty states. */
    val state: ArchiveState get() = arm.state

    val isAvailable: Boolean
        get() = arm.state is ArchiveState.Ready

    // T49 (s17): the reader face speaketh the same typed truth the arm keeps.
    override fun status(): ArchiveState = arm.state

    override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? {
        val h = arm.handle ?: return null
        return runCatching {
            h.rows(
                "SELECT document_id, title, source_id, licence, revision, is_critical " +
                    "FROM documents WHERE document_id = ?",
                arrayOf(documentId),
            ).firstOrNull()?.let { row ->
                ArchiveSourceMetadata(
                    documentId = row[0] as Long,
                    title = row[1] as String,
                    sourceId = row[2] as String,
                    licence = row[3] as String,
                    revision = row[4] as String,
                    isCritical = (row[5] as Long) != 0L,
                )
            }
        }.getOrNull()
    }

    override fun listDocuments(domain: String?): List<ArchiveDocument> {
        val h = arm.handle ?: return emptyList()
        val where = if (domain.isNullOrBlank()) "" else "WHERE domain = ?"
        val args: Array<Any?> = if (domain.isNullOrBlank()) emptyArray() else arrayOf(domain)
        return runCatching {
            h.rows(
                "SELECT document_id, title, domain, is_critical, source_id, revision " +
                    "FROM documents $where ORDER BY is_critical DESC, domain, title",
                args,
            ).map { row ->
                ArchiveDocument(
                    id = row[0] as Long,
                    title = row[1] as String,
                    domain = row[2] as String,
                    isCritical = (row[3] as Long) != 0L,
                    sourceId = row[4] as String,
                    revision = row[5] as String,
                )
            }
        }.getOrDefault(emptyList())
    }

    override fun listDomains(): List<String> {
        val h = arm.handle ?: return emptyList()
        return runCatching {
            h.rows("SELECT DISTINCT domain FROM documents ORDER BY domain", emptyArray())
                .map { it[0] as String }
        }.getOrDefault(emptyList())
    }

    override fun passages(documentId: Long): List<ArchivePassage> {
        val h = arm.handle ?: return emptyList()
        return runCatching {
            h.rows(
                """
                SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                WHERE c.document_id = ?
                ORDER BY c.ordinal
                """.trimIndent(),
                arrayOf(documentId),
            ).map { it.toPassage() }
        }.getOrDefault(emptyList())
    }

    /** Bounded, tokenised, quoted FTS5 search. A refused query answereth no
     * rows; [explainSearch] nameth the reason for a refusal. */
    override fun search(query: String, limit: Int): List<ArchivePassage> {
        val h = arm.handle ?: return emptyList()
        val built = SearchQuery.build(query)
        if (built !is SearchQuery.Built.Ready) {
            return emptyList()
        }
        val match = built.match
        return runCatching {
            h.rows(
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
                arrayOf(match, SearchQuery.bound(limit).toLong()),
            ).map { it.toPassage(score = -(it[6] as Double)) }
        }.getOrDefault(emptyList())
    }

    /** The typed verdict of a query without running it: what would answer,
     * or why nothing would. */
    fun explainSearch(query: String): SearchQuery.Built = SearchQuery.build(query)

    private fun List<Any?>.toPassage(score: Double = 0.0) = ArchivePassage(
        chunkId = this[0] as Long,
        documentId = this[1] as Long,
        documentTitle = this[2] as String,
        domain = this[3] as String,
        section = this[4] as String,
        text = this[5] as String,
        score = score,
    )
}
