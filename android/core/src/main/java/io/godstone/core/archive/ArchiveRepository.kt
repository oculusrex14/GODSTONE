package io.godstone.core.archive

import android.content.Context
import java.io.File

/**
 * GS-ARCHIVE-002: a READ failure is a FAILURE, never an empty result.
 *
 * The audit reproduced `runCatching { ... }.getOrDefault(emptyList())` turning a broken
 * schema or a vanished index into "no documents" while the status stayed Ready. Every read
 * road now either answereth or raiseth this -- the caller (the view model) shows a sanitised
 * Unavailable/ReadFailure with retry, and the handle's availability is judged separately.
 */
class ArchiveReadException(message: String, cause: Throwable? = null) : Exception(message, cause)

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

/**
 * GS-ARCHIVE-001: the descriptor of an archive whose TRUSTED MANIFEST was verified.
 *
 * The audit reproduced that the runtime served a usable archive from BYTES ALONE -- an
 * absent manifest produced `Ready`, a document and a matching search result. This type can
 * be produced ONLY by the verifier: a repository whose manifest is missing, unreadable,
 * unsigned, wrong-tier or describing other bytes carrieth NO descriptor and is Unavailable.
 */
data class VerifiedArchiveDescriptor(
    val fileName: String,
    val tier: String,
    val archiveSchema: Int,
    val bytes: Long,
    val sha256: String,
    val manifestSchema: Int,
    val approvalsSha256: String?,
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
    /** GS-ARCHIVE-001: the identity this build serveth, declared by the composition root. */
    private val expectedAsset: String = archiveAsset,
    private val expectedTier: String = "LIGHT",
) : ArchiveReader {

    /** The verified descriptor, or null when no approved archive is served. */
    @Volatile
    var descriptor: VerifiedArchiveDescriptor? = null
        private set

    constructor(context: Context, archiveAsset: String,
                expectedTier: String = "LIGHT") : this(
        AndroidArchiveBridge(context),
        archiveAsset,
        expectedAsset = archiveAsset,
        expectedTier = expectedTier,
    )

    private val installer = ArchiveInstaller(bridge.cacheRoot())

    /** The armed state: proven handle plus its typed verdict, computed once. */
    private class Arm(val state: ArchiveState, val handle: ArchiveDatabase?)

    private val arm: Arm by lazy { compute() }


    /**
     * GS-ARCHIVE-002: every read road passeth through here. A SQL failure becometh an
     * [ArchiveReadException] NAMING the road, so the caller showeth Unavailable/ReadFailure
     * with retry -- the audit reproduced `runCatching { ... }.getOrDefault(emptyList())`
     * turning a broken schema or a vanished index into "no documents" while the state stayed
     * Ready. The handle's AVAILABILITY is judged separately (the arm); a transient read
     * failure never poisoneth a valid handle.
     */
    private inline fun <T> checkedRead(road: String, block: () -> List<T>): List<T> =
        try {
            block()
        } catch (exc: ArchiveReadException) {
            throw exc
        } catch (exc: Throwable) {
            throw ArchiveReadException("archive read failed on $road: " +
                (exc.message ?: exc::class.simpleName), exc)
        }

    private fun factsOfManifest(): Pair<ArchiveManifestFacts?, String?> {
        val text = bridge.assetBytes("$archiveAsset.manifest")?.decodeToString()
        if (text == null) {
            // GS-ARCHIVE-001: this was the null-to-null SUCCESS path -- the audit opened a
            // valid asset with no manifest at all and obtained Ready. Bytes are not an
            // approval: without its trusted manifest the archive is UNAVAILABLE.
            return null to ("the trusted manifest is missing: $archiveAsset.manifest -- the " +
                "Archive may not be served from bytes alone (GS-ARCHIVE-001)")
        }
        if (text.isBlank()) {
            return null to ("the trusted manifest is empty: $archiveAsset.manifest")
        }
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
        if (facts == null) {
            // a repository may not install unapproved bytes: the descriptor is the price of
            // a usable handle (GS-ARCHIVE-001 steps 2-3).
            return Arm(ArchiveState.Unavailable(
                "the trusted manifest was not verified, so no descriptor existeth: " +
                    "the Archive is UNAVAILABLE"), null)
        }
        if (facts.tier != expectedTier) {
            return Arm(ArchiveState.Unavailable(
                "the manifest declareth tier ${facts.tier} while this build serveth " +
                    "$expectedTier -- a wrong-tier archive is never served"), null)
        }
        if (facts.fileName != expectedAsset) {
            return Arm(ArchiveState.Unavailable(
                "the manifest declareth ${facts.fileName} while this build serveth " +
                    "$expectedAsset"), null)
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
                if (facts.bytes != installer.currentFile().length() || facts.sha256 != sha) {
                    runCatching { handle.close() }
                    return Arm(ArchiveState.Unavailable(
                        "the manifest describeth ${facts.bytes} bytes at ${facts.sha256}, " +
                            "while the installed file carrieth " +
                            "${installer.currentFile().length()} at $sha -- the descriptor " +
                            "and the bytes MUST agree"), null)
                }
                descriptor = VerifiedArchiveDescriptor(
                    fileName = facts.fileName, tier = facts.tier,
                    archiveSchema = facts.archiveSchema, bytes = facts.bytes,
                    sha256 = facts.sha256, manifestSchema = facts.schema,
                    approvalsSha256 = facts.approvalsSha256,
                )
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
        return checkedRead("listDocuments") {
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
        }
    }

    override fun listDomains(): List<String> {
        val h = arm.handle ?: return emptyList()
        return checkedRead("listDomains") {
            h.rows("SELECT DISTINCT domain FROM documents ORDER BY domain", emptyArray())
                .map { it[0] as String }
        }
    }

    override fun passages(documentId: Long): List<ArchivePassage> {
        val h = arm.handle ?: return emptyList()
        return checkedRead("passages") {
            h.rows(
                """
                SELECT c.chunk_id, c.document_id, d.title, d.domain, c.section, c.text
                FROM chunks c JOIN documents d ON d.document_id = c.document_id
                WHERE c.document_id = ?
                ORDER BY c.ordinal
                """.trimIndent(),
                arrayOf(documentId),
            ).map { it.toPassage() }
        }
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
        return checkedRead("search") {
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
        }
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
