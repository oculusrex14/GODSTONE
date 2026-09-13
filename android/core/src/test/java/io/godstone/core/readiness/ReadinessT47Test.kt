package io.godstone.core.archive

import io.godstone.core.archive.ArchiveBridge
import io.godstone.core.archive.ArchiveDatabase
import io.godstone.core.archive.ArchiveDrivers
import io.godstone.core.archive.ArchiveInstaller
import io.godstone.core.archive.ArchiveManifestFacts
import io.godstone.core.archive.ArchiveRecord
import io.godstone.core.archive.ArchiveRepository
import io.godstone.core.archive.ArchiveState
import io.godstone.core.archive.InstallOutcome
import io.godstone.core.archive.SearchQuery
import io.godstone.core.archive.Sha256
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteDriver
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.io.File
import kotlin.io.deleteRecursively
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T47 designated regression court (android) -- the Archive install /
 * verify / query path over the PINNED AndroidX bundled SQLite.
 *
 * The card's cases, witnessed here against the REAL engine (the jvm
 * build of the very same bundled driver the LIGHT APK ships, native
 * library and all -- the instrumented-device leg of the case is
 * recorded, not closed, and falls to T73-T75):
 *   1. the actual bundled driver answers on the host: provenance,
 *      sqlite_version of the bundled stock, integrity, the FTS5 canary;
 *   2. the stale cache is RENEWED, never served because it existeth:
 *      renewal, tamper detection with preservation of the bytes, and
 *      repair by reinstall;
 *   3. a corrupted or missing bundle is Refused with its cause named
 *      (digest, size, missing, empty);
 *   4. a failed replacement preserveth the old bytes (engine fault
 *      injected between staging and promotion) and a later good
 *      install mendeth the slot;
 *   5. the bounds of the query: 512-character phrases, 32 distinct
 *      terms, 200-row pages, each enforced and each reported;
 *   6. raw user text never entereth the MATCH grammar: every built
 *      match string obeys the quoted-phrase grammar, hostile inputs
 *      included, and every one of them runneth against the live index;
 *   7. concurrent install and search: readers never observe a torn
 *      database, promoters are serialised, staging is left clean;
 *   8. the read-only handle denieth every write road (INSERT, UPDATE,
 *      DELETE, DDL) and the bytes on disk are byte-identical after;
 *   9. the trusted manifest clause: future versions refused, shape
 *      faults named, traversal names refused, the record round-trips
 *      through the canonical writer byte-identically;
 *  10. the serve decision is never an existence check: a rogue file
 *      without its record, and a truncated file with one, both answer
 *      Unavailable with the cause named;
 *  11. the typed states of the whole road: Ready and Unavailable
 *      report themselves at the repository face, the silent boolean is
 *      dethroned.
 *
 * The fixture archives are built by executing the FROZEN DDL verbatim
 * (content/db/schema.sql + content/db/indexes.sql) through the same
 * bundled engine, so the court and the shipping builder share one
 * truth about the shape of the data.
 */

/* ------------------------------------------------------------------ */
/* file-private helpers (the court's own tools, hidden from the isle) */
/* ------------------------------------------------------------------ */

private const val COURT_ASSET: String = "godstone_light.db"
private const val COURT_MANIFEST: String = "godstone_light.db.manifest"

private fun refuses(block: () -> Unit): Throwable? =
    try { block(); null } catch (exc: Throwable) { exc }

private fun SQLiteConnection.speak(sql: String) {
    try {
        prepare(sql).use { it.step() }
    } catch (exc: Throwable) {
        System.err.println("SPOKE-FALSE[" + sql.replace("\n", "|") + "]")
        throw exc
    }
}

private fun execScript(conn: SQLiteConnection, script: String) {
    // Statements end at a semicolon that stands outside a string literal and
    // outside a comment -- the law the python builder's executescript keeps;
    // a naive split is a lie (the frozen DDL carries semicolons in comments).
    val buf = StringBuilder()
    var i = 0
    while (i < script.length) {
        val c = script[i]
        when {
            c == '\'' -> {
                buf.append(c)
                i++
                while (i < script.length) {
                    val d = script[i]
                    buf.append(d)
                    i++
                    if (d == '\'') {
                        if (i < script.length && script[i] == '\'') {
                            buf.append(script[i])
                            i++
                        } else {
                            break
                        }
                    }
                }
            }
            c == '-' && i + 1 < script.length && script[i + 1] == '-' -> {
                while (i < script.length && script[i] != '\n') {
                    buf.append(script[i])
                    i++
                }
            }
            c == '/' && i + 1 < script.length && script[i + 1] == '*' -> {
                buf.append(c)
                buf.append(script[i + 1])
                i += 2
                while (i + 1 < script.length && !(script[i] == '*' && script[i + 1] == '/')) {
                    buf.append(script[i])
                    i++
                }
                if (i + 1 < script.length) {
                    buf.append('*').append('/')
                    i += 2
                }
            }
            c == ';' -> {
                val stmt = buf.toString().trim()
                if (stmt.isNotEmpty()) conn.speak(stmt)
                buf.clear()
                i++
            }
            else -> {
                buf.append(c)
                i++
            }
        }
    }
    val tail = buf.toString().trim()
    if (tail.isNotEmpty()) conn.speak(tail)
}

/** Build one fixture archive file through the real bundled engine,
 * executing the frozen DDL verbatim. [reservoirRows] extra chunks all
 * carry the words reservoir and marker, for the 200-row page bounds. */
private fun buildArchive(target: File, variant: Int, reservoirRows: Int) {
    var probe: File? = File(System.getProperty("user.dir")).absoluteFile
    var repoRoot: File? = null
    while (probe != null) {
        if (File(probe, "content/db/schema.sql").isFile) { repoRoot = probe; break }
        probe = probe.parentFile
    }
    val root = repoRoot ?: error("the court could not find content/db/schema.sql from " +
        System.getProperty("user.dir"))
    val schema = File(root, "content/db/schema.sql").readText()
    val indexes = File(root, "content/db/indexes.sql").readText()
    val driver = BundledSQLiteDriver()
    val conn = driver.open(target.absolutePath)
    try {
        execScript(conn, schema)
        conn.prepare("INSERT INTO documents(document_id,title,domain,source_id,licence,revision,is_critical) VALUES(?,?,?,?,?,?,?)").use { st ->
            st.bindLong(1, 1L); st.bindText(2, "First aid"); st.bindText(3, "health")
            st.bindText(4, "s1"); st.bindText(5, "CC"); st.bindText(6, "r1"); st.bindLong(7, 1L); st.step()
        }
        conn.prepare("INSERT INTO documents(document_id,title,domain,source_id,licence,revision,is_critical) VALUES(?,?,?,?,?,?,?)").use { st ->
            st.bindLong(1, 2L); st.bindText(2, "Water safety"); st.bindText(3, "water")
            st.bindText(4, "s2"); st.bindText(5, "CC"); st.bindText(6, "r1"); st.bindLong(7, 0L); st.step()
        }
        conn.prepare("INSERT INTO documents(document_id,title,domain,source_id,licence,revision,is_critical) VALUES(?,?,?,?,?,?,?)").use { st ->
            st.bindLong(1, 3L); st.bindText(2, "Power outages"); st.bindText(3, "energy")
            st.bindText(4, "s3"); st.bindText(5, "CC"); st.bindText(6, "r1"); st.bindLong(7, 0L); st.step()
        }
        var chunk = 0L
        fun putChunk(documentId: Long, ordinal: Long, section: String, text: String) {
            chunk += 1L
            conn.prepare("INSERT INTO chunks(chunk_id,document_id,ordinal,section,text,token_count) VALUES(?,?,?,?,?,?)").use { st ->
                st.bindLong(1, chunk); st.bindLong(2, documentId); st.bindLong(3, ordinal)
                st.bindText(4, section); st.bindText(5, text); st.bindLong(6, 7L); st.step()
            }
        }
        putChunk(1L, 1L, "Treatment > Bleeding", "haemorrhage bandage pressure power outages guidance")
        putChunk(1L, 2L, "Treatment > Burns", "burns cooling clean water purification methods")
        putChunk(2L, 1L, "Kits > Store", "water purification tablets reservoir station")
        putChunk(2L, 2L, "Kits > Ration", "daily water ration planning field guide")
        if (variant == 2) {
            putChunk(3L, 1L, "Grid > Blackout", "tsunami warning sirens grid blackout")
        } else {
            putChunk(3L, 1L, "Grid > Blackout", "grid blackout torch flashlight repair power outages guidance")
        }
        for (row in 1..reservoirRows) {
            putChunk(2L, (1000L + row), "Logs > Reservoir", "reservoir marker station log item " + row)
        }
        conn.prepare("INSERT INTO archive_meta(key,value) VALUES(?,?)").use { st ->
            st.bindText(1, "schema_version"); st.bindText(2, "3"); st.step()
        }
        execScript(conn, indexes)
    } finally {
        conn.close()
    }
}

/** The canonical manifest text a trusting operator would sign. */
private fun manifestJson(bytes: Long, sha: String, approvals: String? = null): String {
    val meta = if (approvals == null) "" else ",\"archive_meta\":{\"approvals_sha256\":\"$approvals\"}"
    return "{\"archive_bytes\":$bytes,\"archive_file\":\"$COURT_ASSET\"," +
        "\"archive_schema\":3,\"archive_sha256\":\"$sha\",\"schema\":1,\"tier\":\"LIGHT\"" +
        meta + "}"
}

private fun tamperMiddle(file: File) {
    val bytes = file.readBytes()
    val at = bytes.size / 2
    bytes[at] = (bytes[at].toInt() xor 0xFF).toByte()
    file.writeBytes(bytes)
}

private fun truncateLast(file: File) {
    val bytes = file.readBytes()
    file.writeBytes(bytes.copyOf(bytes.size - 1))
}

private class FakeBridge(
    private val assets: Map<String, () -> ByteArray?>,
    private val root: File,
) : ArchiveBridge {
    override fun assetBytes(name: String): ByteArray? = assets[name]?.invoke()
    override fun cacheRoot(): File = root
}

/** A driver that failseth the engine mid-probe for paths matching
 * [faulty], passing every other road through to the true driver. */
private class FaultyDriver(
    private val delegate: SQLiteDriver,
    private val faulty: (String) -> Boolean,
) : SQLiteDriver {
    override fun open(path: String): SQLiteConnection {
        if (faulty(path)) throw IllegalStateException("simulated engine fault at $path")
        return delegate.open(path)
    }
}

/* ------------------------------------------------------------------ */

class ReadinessT47Test {

    companion object {
        init {
            // The very class the LIGHT APK installs out of band; the host
            // road runseth the same driver over the same native stock.
            ArchiveDrivers.install { BundledSQLiteDriver() }
        }
    }

    private val temp: File = File.createTempFile("t47-court", ".dir")
        .also { it.delete(); it.mkdirs() }

    @After
    fun tearDown() {
        runCatching { temp.deleteRecursively() }
    }

    private fun freshRoot(name: String): File =
        File(temp, name).also { it.mkdirs() }

    private fun installerFor(root: File, driver: () -> SQLiteDriver = { ArchiveDrivers.required() }): ArchiveInstaller =
        ArchiveInstaller(root, driver)

    /** Installs a freshly built fixture; returns (file, digest, installer, manifest facts). */
    private class Installed(
        val file: File,
        val sha: String,
        val installer: ArchiveInstaller,
        val facts: ArchiveManifestFacts,
        val root: File,
    )

    private fun installFixture(name: String, variant: Int = 1, reservoirRows: Int = 0): Installed {
        val root = freshRoot(name)
        val source = File(root, "bundle-" + variant + ".db")
        buildArchive(source, variant, reservoirRows)
        val sha = Sha256.hexOf(source)
        val facts = ArchiveManifestFacts.fromJson(manifestJson(source.length(), sha))
        val installer = installerFor(root)
        val outcome = installer.install({ source.readBytes() }, facts)
        assertTrue("$name: the fixture install must be accepted, got " + outcome,
            outcome is InstallOutcome.Selected || outcome is InstallOutcome.Refreshed)
        return Installed(source, sha, installer, facts, root)
    }

    /* ---------------------------------------------------------------- */

    @Test
    fun testTheBundledEngineItselfAnswerethUnderTheCourt() {
        val gone = installFixture("provenance")
        val handle = ArchiveDatabase.openReadOnly(gone.installer.currentFile(), ArchiveDrivers.required())
        try {
            // provenance: the connection's own class, not a platform stand-in
            val spoken = handle.driverClassName
            assertTrue("the road must run upon the bundled driver, got " + spoken,
                spoken.startsWith("androidx.") && spoken.contains(".driver.bundled.") &&
                    spoken.contains("Bundled") && spoken.endsWith("Connection"))
            assertFalse("never the platform engine, got " + spoken,
                spoken.startsWith("android.database"))
            // the actual engine answers, of the bundled stock
            val version = handle.versionString()
            assertTrue("engine version must be of the bundled stock, got $version",
                Regex("^3\\.[0-9]+\\.[0-9]+$").matches(version))
            assertTrue("integrity must answer ok, got " + handle.integrityCheck(),
                handle.integrityCheck().startsWith("ok"))
            for (name in ArchiveDatabase.REQUIRED_TABLES) {
                assertTrue("required table $name must answer", handle.hasTable(name))
            }
            assertTrue("the FTS5 canary must be capable on the real engine", handle.fts5Capable())
            // a live MATCH against the frozen-shape index returns the hit
            val hits = handle.rows(
                "SELECT c.text FROM chunks_fts JOIN chunks c ON c.chunk_id = chunks_fts.rowid " +
                    "WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?",
                arrayOf("\"power\" AND \"outages\"", 10L),
            )
            assertTrue("the frozen FTS5 index must return the power-outages hit",
                hits.isNotEmpty())
            assertEquals("the digest of the served bytes must equal the trusted manifest",
                gone.facts.sha256, Sha256.hexOf(gone.installer.currentFile()))
        } finally {
            handle.close()
        }
    }

    @Test
    fun testTheStaleCacheIsRenewedAndNeverServedBecauseItExisteth() {
        val first = installFixture("renewal", variant = 1)
        assertEquals("the first install must leave the record at the old digest",
            first.sha, Sha256.hexOf(first.installer.currentFile()))
        // a newer approved build cometh: different bytes, new manifest
        val second = File(first.root, "bundle-2.db")
        buildArchive(second, variant = 2, reservoirRows = 0)
        val secondSha = Sha256.hexOf(second)
        assertFalse("the renewal bundle must really differ", secondSha == first.sha)
        val secondFacts = ArchiveManifestFacts.fromJson(manifestJson(second.length(), secondSha))
        val renewed = first.installer.install({ second.readBytes() }, secondFacts)
        assertTrue("the stale cache must be renewed, got " + renewed,
            renewed is InstallOutcome.Refreshed)
        assertEquals("the renewed bytes must be the approved ones",
            secondSha, Sha256.hexOf(first.installer.currentFile()))
        // serve the truth: the new document answereth, the old vanisheth
        val handle = ArchiveDatabase.openReadOnly(first.installer.currentFile(), ArchiveDrivers.required())
        try {
            val tsunami = handle.rows(
                "SELECT text FROM chunks WHERE text LIKE ?", arrayOf("%tsunami%"))
            assertEquals("the renewed build must carry the tsunami passage", 1, tsunami.size)
            val gone = handle.rows(
                "SELECT text FROM chunks WHERE text = ?",
                arrayOf("grid blackout torch flashlight repair power outages guidance"))
            assertEquals("the superseded passage must be gone from the cache", 0, gone.size)
        } finally {
            handle.close()
        }
        // tamper the served bytes: the court must SEE it, and the bytes must be preserved
        tamperMiddle(first.installer.currentFile())
        val after = first.installer.status(secondFacts)
        assertTrue("a tampered cache must not be served, got " + after,
            after is InstallOutcome.Unavailable)
        assertTrue("the report must name the digest mismatch, got " +
            (after as InstallOutcome.Unavailable).reason,
            (after as InstallOutcome.Unavailable).reason.contains("do not match"))
        assertTrue("the bytes must be PRESERVED for the mender, not deleted",
            first.installer.currentFile().isFile)
        // and the telling must stand BLIND too -- without any manifest to
        // compare against, the record itself is the serve-time anchor
        val blind = first.installer.status()
        assertTrue("a tampered cache must be refused blind too, got " + blind,
            blind is InstallOutcome.Unavailable)
        assertTrue("the blind report must name the record, got " +
            (blind as InstallOutcome.Unavailable).reason,
            (blind as InstallOutcome.Unavailable).reason.contains("record"))
        // reinstalling the approved bytes mendeth the slot
        val mended = first.installer.install({ second.readBytes() }, secondFacts)
        assertTrue("a reinstall of the approved bundle must land, got " + mended,
            mended is InstallOutcome.Selected || mended is InstallOutcome.Refreshed)
        assertTrue("the mended cache must serve again, got " + first.installer.status(secondFacts),
            first.installer.status(secondFacts) is InstallOutcome.Selected)
    }

    @Test
    fun testCorruptedOrMissingBundlesAreRefusedWithTheirCausesNamed() {
        val root = freshRoot("refusals")
        val source = File(root, "good.db")
        buildArchive(source, variant = 1, reservoirRows = 0)
        val goodSha = Sha256.hexOf(source)
        val installer = installerFor(root)

        val lyingSha = manifestJson(source.length(), "f".repeat(64))
        val wrongDigest = installer.install({ source.readBytes() },
            ArchiveManifestFacts.fromJson(lyingSha))
        assertTrue("a wrong digest must be Rejected, got " + wrongDigest,
            wrongDigest is InstallOutcome.Rejected)
        assertTrue("the digest refusal must name itself, got " +
            (wrongDigest as InstallOutcome.Rejected).cause,
            (wrongDigest as InstallOutcome.Rejected).cause.contains("digest"))

        val lyingSize = manifestJson(source.length() + 1024, goodSha)
        val wrongSize = installer.install({ source.readBytes() },
            ArchiveManifestFacts.fromJson(lyingSize))
        assertTrue("a lying size must be Rejected, got " + wrongSize,
            wrongSize is InstallOutcome.Rejected)
        assertTrue("the size refusal must name itself, got " +
            (wrongSize as InstallOutcome.Rejected).cause,
            (wrongSize as InstallOutcome.Rejected).cause.contains("size"))

        val missing = installer.install({ null }, null)
        assertTrue("a missing bundle must be Rejected, got " + missing,
            missing is InstallOutcome.Rejected)
        assertTrue("the missing refusal must name itself",
            (missing as InstallOutcome.Rejected).cause.contains("missing"))

        val empty = installer.install({ ByteArray(0) }, null)
        assertTrue("an empty bundle must be Rejected, got " + empty,
            empty is InstallOutcome.Rejected)
        assertTrue("the empty refusal must name itself",
            (empty as InstallOutcome.Rejected).cause.contains("empty"))

        // a bundle that lacks the required tables is refused, and they are named
        val sparse = File(root, "sparse.db")
        val maker = BundledSQLiteDriver().open(sparse.absolutePath)
        try {
            maker.prepare("CREATE TABLE documents(document_id INTEGER PRIMARY KEY, t TEXT)").use { it.step() }
            maker.prepare("INSERT INTO documents(document_id,t) VALUES(1,'only the documents table here')").use { it.step() }
        } finally {
            maker.close()
        }
        val sparseSha = Sha256.hexOf(sparse)
        val sparseFacts = ArchiveManifestFacts.fromJson(
            manifestJson(sparse.length(), sparseSha))
        val sparseCase = installer.install({ sparse.readBytes() }, sparseFacts)
        assertTrue("a table-less bundle must be Refused, got " + sparseCase,
            sparseCase is InstallOutcome.Rejected)
        assertTrue("the refusal must name the missing tables, got " +
            (sparseCase as InstallOutcome.Rejected).cause,
            (sparseCase as InstallOutcome.Rejected).cause.contains("missing required table"))

        // nothing was ever promoted: the root holds no served bytes
        assertTrue("no refusal may leave bytes in the current slot",
            !installer.currentFile().exists())
        assertTrue("no refusal may leave a staging copy behind",
            File(root, ArchiveInstaller.STAGING_DIR_NAME).listFiles()?.isEmpty() ?: true)
    }

    @Test
    fun testTheFailedReplacementPreservethTheOldBytesAndAMendFolloweth() {
        val first = installFixture("failed-replacement")
        val before = Sha256.hexOf(first.installer.currentFile())
        // a good candidate with a bad engine between staging and promotion
        val source = File(first.root, "bundle-9.db")
        buildArchive(source, variant = 1, reservoirRows = 3)
        val sha = Sha256.hexOf(source)
        val facts = ArchiveManifestFacts.fromJson(manifestJson(source.length(), sha))
        val crippling = { path: String -> path.contains("candidate-") }
        val maimed = installerFor(first.root) { FaultyDriver(ArchiveDrivers.required(), crippling) }
        val outcome = maimed.install({ source.readBytes() }, facts)
        assertTrue("an injected engine fault must Reject the candidate, got " + outcome,
            outcome is InstallOutcome.Rejected)
        assertTrue("the refusal must name the probe, got " +
            (outcome as InstallOutcome.Rejected).cause,
            (outcome as InstallOutcome.Rejected).cause.contains("probe"))
        assertEquals("the failed replacement must preserve the old bytes byte-for-byte",
            before, Sha256.hexOf(first.installer.currentFile()))
        assertTrue("the failed candidate must clean its own staging",
            File(first.root, ArchiveInstaller.STAGING_DIR_NAME).listFiles()?.isEmpty() ?: true)
        // and a later good install mendeth the slot
        val mended = first.installer.install({ source.readBytes() }, facts)
        assertTrue("the mend install must land, got " + mended,
            mended is InstallOutcome.Refreshed || mended is InstallOutcome.Selected)
        assertEquals("the slot must carry the mended bytes", sha,
            Sha256.hexOf(first.installer.currentFile()))
        assertTrue("the mended root must serve",
            first.installer.status(facts) is InstallOutcome.Selected)
    }

    @Test
    fun testTheBoundsOfPhraseTermAndPageAreEachEnforcedAndReported() {
        val built0 = installFixture("bounds", reservoirRows = 250)
        val repo = ArchiveRepository(
            FakeBridge(
                mapOf(
                    COURT_ASSET to { built0.file.readBytes() },
                    COURT_MANIFEST to { manifestJson(built0.file.length(), built0.facts.sha256).encodeToByteArray() },
                ),
                freshRoot("bounds-view"),
            ),
            COURT_ASSET,
        )
        assertTrue("the bounds fixture must serve", repo.isAvailable)

        // the phrase bound: 512 characters
        val longPhrase = "x".repeat(SearchQuery.MAX_PHRASE_CHARS + 88)
        val over = SearchQuery.build(longPhrase)
        assertTrue("a " + longPhrase.length + "-character phrase must be refused",
            over is SearchQuery.Built.Refused)
        assertTrue("the phrase refusal must name the bound, got " +
            (over as SearchQuery.Built.Refused).reason,
            (over as SearchQuery.Built.Refused).reason.contains("512"))
        assertEquals("the boundary itself must still be accepted",
            SearchQuery.Built.Ready::class.simpleName,
            (SearchQuery.build("y".repeat(SearchQuery.MAX_PHRASE_CHARS)) as SearchQuery.Built)
                ::class.simpleName?.substringAfterLast('.'))

        // the term bound: 32 distinct terms pass, 33 are refused
        val thirtyTwo = (1..SearchQuery.MAX_TERMS).joinToString(" ") { "term$it" }
        val okTerms = SearchQuery.build(thirtyTwo)
        assertTrue("thirty-two terms must pass, got " + okTerms,
            okTerms is SearchQuery.Built.Ready)
        assertEquals("the ready build must report its count", 32,
            (okTerms as SearchQuery.Built.Ready).termCount)
        val thirtyThree = (1..SearchQuery.MAX_TERMS + 1).joinToString(" ") { "term$it" }
        val denied = SearchQuery.build(thirtyThree)
        assertTrue("thirty-three terms must be refused", denied is SearchQuery.Built.Refused)
        assertTrue("the term refusal must name the bound, got " +
            (denied as SearchQuery.Built.Refused).reason,
            (denied as SearchQuery.Built.Refused).reason.contains("32"))

        // the page bound: 200 results, whatever the petition
        val petitioning = repo.search("reservoir", limit = 9_999)
        assertEquals("an over-great petition must be clamped to the page bound",
            SearchQuery.MAX_RESULTS, petitioning.size)
        assertEquals("the page bound itself must be the answer", 200,
            repo.search("reservoir", limit = 200).size)
        assertEquals("a small petition must pass unheard", 40,
            repo.search("reservoir", limit = 40).size)
        assertEquals("the bound of the limit must hold from below", 1,
            repo.search("reservoir", limit = 0).size)
        assertTrue("the bound reporteth itself in SearchQuery too",
            SearchQuery.bound(-7) == 1 && SearchQuery.bound(9_999) == 200)

        // a refused query answereth nothing, and saith why, at the repository face
        val why = repo.explainSearch(longPhrase)
        assertTrue("the explanation must be a refusal", why is SearchQuery.Built.Refused)
        assertEquals("a refused query must serve no rows", 0, repo.search(longPhrase).size)
    }

    @Test
    fun testNoRawMouthFullTextEnteretheMatchGrammarUnquoted() {
        installFixture("grammar")
        val hostile = arrayOf(
            "power\" OR \"evil",           // quotes that would close the phrase
            "\"\"",                        // an empty phrase
            "**",                          // bare wildcards
            "a:b", "c(d)", "^caret", "-dash", "under_score",
            "OR", "AND NOT", "NOT",        // bare boolean words
            "emi** ", " ra**d", "inval:id",
            "power* AND outage",           // trailing wildcard inside a term
            "  multiple   spaces\ttab\nand newline ",
            "unicode café ☃ rez",          // non-ascii neighbours
            "\"unbalanced",
            "colons:and(dashes)^mixed*words",
            SearchQuery.MAX_TERMS.toString(),
        )
        val grammar = Regex("\"[^\"]+\"( OR \"[^\"]+\")*")
        for (input in hostile) {
            val built = SearchQuery.build(input)
            when (built) {
                is SearchQuery.Built.Ready -> {
                    assertTrue("built match must obey the quoted grammar, got [" + built.match + "]",
                        grammar.matches(built.match))
                    assertFalse("no term may carry an inner quote: " + built.match,
                        built.match.drop(1).dropLast(1).contains("\\\"\\\""))
                    // and the live engine must digest every built form without complaint
                    val h = ArchiveDatabase.openReadOnly(
                        File(temp, "grammar/current/archive.db"), ArchiveDrivers.required())
                    try {
                        h.rows(
                            "SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? LIMIT ?",
                            arrayOf(built.match, 5L))
                    } finally {
                        h.close()
                    }
                }
                is SearchQuery.Built.Refused -> {
                    assertTrue("a refusal must name its cause for [" + input + "]",
                        built.reason.isNotEmpty())
                }
                is SearchQuery.Built.Empty -> { /* silence is allowed where nothing was asked */ }
            }
        }
        // the determinative check: every hostile word, twice asked, answereth alike
        val a = SearchQuery.build("power\" OR \"evil")
        val b = SearchQuery.build("power\" OR \"evil")
        assertEquals("the build must be deterministic", a::class.java, b::class.java)
        assertEquals("and its match byte-identical",
            (a as SearchQuery.Built.Ready).match, (b as SearchQuery.Built.Ready).match)
    }

    @Test
    fun testConcurrentInstallAndSearchLeaveNoTornWorldBehind() {
        val built = installFixture("concurrency", reservoirRows = 250)
        val pool = Executors.newFixedThreadPool(12)
        val faults = java.util.concurrent.CopyOnWriteArrayList<Throwable>()
        val outcomes = java.util.concurrent.CopyOnWriteArrayList<InstallOutcome>()
        val promises = ArrayList<java.util.concurrent.Future<*>>()
        try {
            repeat(4) {
                promises.add(pool.submit {
                    runCatching {
                        val again = ArchiveInstaller(built.root)
                        outcomes.add(again.install({ built.file.readBytes() }, built.facts))
                    }.onFailure { faults.add(it) }
                })
            }
            repeat(8) {
                promises.add(pool.submit {
                    runCatching {
                        val reader = ArchiveDatabase.openReadOnly(
                            built.installer.currentFile(), ArchiveDrivers.required())
                        try {
                            repeat(3) {
                                val rows = reader.rows(
                                    "SELECT text FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT ?",
                                    arrayOf("\"reservoir\" AND \"marker\"",
                                        SearchQuery.bound(9_999).toLong()))
                                if (rows.size != SearchQuery.MAX_RESULTS) {
                                    throw IllegalStateException("torn read: " + rows.size + " rows")
                                }
                            }
                        } finally {
                            reader.close()
                        }
                    }.onFailure { faults.add(it) }
                })
            }
            pool.shutdown()
            assertTrue("the harvest must finish within the hour",
                pool.awaitTermination(120, TimeUnit.SECONDS))
            for (promise in promises) promise.get()
        } finally {
            pool.shutdownNow()
        }
        assertTrue("no thread may carry a fault away, got " + faults.map { "$it" },
            faults.isEmpty())
        assertTrue("every install must report success, got " + outcomes.map { it::class.simpleName },
            outcomes.isNotEmpty() && outcomes.all {
                it is InstallOutcome.Selected || it is InstallOutcome.Refreshed
            })
        assertEquals("the survivors must agree on one digest",
            built.sha, Sha256.hexOf(built.installer.currentFile()))
        assertTrue("staging must be left clean behind the harvest",
            File(built.root, ArchiveInstaller.STAGING_DIR_NAME).listFiles()?.isEmpty() ?: true)
        assertTrue("the final state must serve",
            built.installer.status(built.facts) is InstallOutcome.Selected)
    }

    @Test
    fun testTheReadOnlyHandleDeniethEveryWriteAndTheBytesAbideth() {
        val built = installFixture("read-only")
        val before = Sha256.hexOf(built.installer.currentFile())
        val handle = ArchiveDatabase.openReadOnly(built.installer.currentFile(), ArchiveDrivers.required())
        val writeRoads = arrayOf(
            "INSERT INTO documents(document_id,title,domain,source_id,licence,revision) " +
                "VALUES(99,'x','y','z','c','r')",
            "UPDATE documents SET title = 'mutated' WHERE document_id = 1",
            "DELETE FROM chunks WHERE chunk_id = 1",
            "DROP TABLE documents",
            "CREATE TABLE t47_smuggled(x)",
            "ALTER TABLE documents ADD COLUMN junk TEXT",
        )
        for (road in writeRoads) {
            val denial = refuses { handle.exec(road) }
            assertTrue("the read-only road must deny [" + road + "]", denial != null)
        }
        assertEquals("every denial must leave the bytes byte-identical",
            before, Sha256.hexOf(built.installer.currentFile()))
        // and the lawful roads still answer
        assertEquals("reads must still serve the three documents", 3,
            handle.rows("SELECT document_id FROM documents ORDER BY document_id", emptyArray()).size)
        val version = refuses { handle.exec("PRAGMA journal_mode = 'DELETE'") }
        // a write-pragmat is a write too: the engine must deny it or leave it inert
        assertTrue("even a write pragma must not change the bytes: " +
            Sha256.hexOf(built.installer.currentFile()),
            Sha256.hexOf(built.installer.currentFile()) == before)
        assertNotNull("the engine must still name its version", handle.versionString())
        handle.close()
    }

    @Test
    fun testTheManifestClauseRefusethFutureVersionsAndLies() {
        val good = manifestJson(1024L, "a".repeat(64), "b".repeat(64))
        val facts = ArchiveManifestFacts.fromJson(good)
        assertEquals("a lawful manifest must be believed", 1, facts.schema)
        assertEquals("the archive schema must be the known three", 3, facts.archiveSchema)
        assertEquals("the approvals must be remembered", "b".repeat(64), facts.approvalsSha256)

        // the future version clause
        val future = good.replace("\"archive_schema\":3", "\"archive_schema\":4")
        assertTrue("a future archive schema must be refused",
            refuses { ArchiveManifestFacts.fromJson(future) } != null)
        val futureManifest = good.replace("\"schema\":1", "\"schema\":2")
        val why = refuses { ArchiveManifestFacts.fromJson(futureManifest) }
        assertTrue("the refusal must speak of the schema", why != null &&
            (why.message ?: "").contains("schema"))

        // shape faults, each named
        val shapeFaults = mapOf(
            "a missing sha must be named" to good.replace(
                ",\"archive_sha256\":\"" + "a".repeat(64) + "\"", ""),
            "a short digest must be named" to good.replace("a".repeat(64), "a".repeat(63)),
            "an uppercase digest must be named" to good.replace("a".repeat(64), "A".repeat(64)),
            "a zero length must be named" to good.replace("\"archive_bytes\":1024", "\"archive_bytes\":0"),
            "a traversal name must be named" to good.replace("godstone_light.db", "../evil.db"),
            "a path name must be named" to good.replace("godstone_light.db", "sub/dir.db"),
            "an absolute name must be named" to good.replace("godstone_light.db", "/etc/passwd"),
            "a bad tier must be named" to good.replace("\"tier\":\"LIGHT\"", "\"tier\":\"KINDA\""),
            "a lying approvals must be named" to good.replace("b".repeat(64), "not-hex"),
            "a trailing matter must be named" to good + "x",
            "a duplicate key must be named" to good.replace(
                "\"archive_file\":\"" + COURT_ASSET + "\"",
                "\"archive_file\":\"" + COURT_ASSET + "\",\"archive_file\":\"" + COURT_ASSET + "\""),
        )
        for ((plea, text) in shapeFaults) {
            assertTrue(plea + " in [" + text + "]",
                refuses { ArchiveManifestFacts.fromJson(text) } != null)
        }

        // the record round-trip through the canonical writer
        val record = ArchiveRecord(1, "c".repeat(64), 4096L, "godstone_light.db", 1_755_100_000_000L)
        val canon = record.toCanonJson()
        assertEquals("the canonical writer must sort the keys",
            canon.indexOf("bytes"), canon.indexOf("bytes").let { n ->
                assertTrue("keys must be tight and sorted",
                    canon.indexOf("\"bytes\":") < canon.indexOf("\"origin\":") &&
                        canon.indexOf("\"origin\":") < canon.indexOf("\"schema\":") &&
                        canon.indexOf("\"schema\":") < canon.indexOf("\"selected_at_ms\":") &&
                        canon.indexOf("\"selected_at_ms\":") < canon.indexOf("\"sha256\":"))
                n
            })
        assertEquals("the record must round-trip unchanged", record, ArchiveRecord.fromJson(canon))
        assertTrue("a future record must be refused",
            refuses { ArchiveRecord.fromJson(canon.replace("\"schema\":1", "\"schema\":2")) } != null)
        assertTrue("a loose digest in a record must be refused",
            refuses { ArchiveRecord.fromJson(canon.replace("c".repeat(64), "C".repeat(64))) } != null)
    }

    @Test
    fun testServeIsNeverAnExistenceCheckAlone() {
        val built = installFixture("existence")
        // (a) a rogue file laid in the slot without its record must not serve
        val rogueRoot = freshRoot("rogue")
        val rogueSlot = File(File(rogueRoot, ArchiveInstaller.CURRENT_DIR_NAME),
            ArchiveInstaller.ARCHIVE_FILE_NAME)
        rogueSlot.parentFile.mkdirs()
        rogueSlot.writeBytes(built.file.readBytes())
        val rogueInstaller = ArchiveInstaller(rogueRoot)
        val rogue = rogueInstaller.status()
        assertTrue("a recordless file must not be served because it existeth, got " + rogue,
            rogue is InstallOutcome.Unavailable)
        assertTrue("the report must name the missing record, got " +
            (rogue as InstallOutcome.Unavailable).reason,
            (rogue as InstallOutcome.Unavailable).reason.contains("record"))
        // (b) the installed bytes truncared must be refused, and preserved
        val intact = Sha256.hexOf(built.installer.currentFile())
        truncateLast(built.installer.currentFile())
        val torn = built.installer.status(built.facts)
        assertTrue("torn bytes must never serve, got " + torn,
            torn is InstallOutcome.Unavailable)
        assertTrue("the torn report must name its cause, got " +
            (torn as InstallOutcome.Unavailable).reason,
            (torn as InstallOutcome.Unavailable).reason.isNotEmpty())
        assertEquals("the torn file must be preserved, not purged",
            built.file.length() - 1L, built.installer.currentFile().length())
        assertFalse("the whole file's digest can no longer be the trusted one",
            Sha256.hexOf(built.installer.currentFile()) == intact)
        // (c) yet the same installer, reinstalled from the true bundle, serveth
        val healed = built.installer.install({ built.file.readBytes() }, built.facts)
        assertTrue("the heal must land, got " + healed,
            healed is InstallOutcome.Selected || healed is InstallOutcome.Refreshed)
        assertTrue("the healed root must serve",
            built.installer.status(built.facts) is InstallOutcome.Selected)
        // (d) the deepest proof: bytes smeared where both the record and a
        // rebuilt honest manifest agree with the smear -- only the engine's
        // own integrity probe can tell truth from rot. The road must refuse,
        // and say probe.
        val smeared = File(built.root, "smeared.db")
        val body = built.file.readBytes()
        // smear the b-tree head of every page but the master: cell counts
        // and free-block pointers become 0xFFFF. The master page is left
        // whole so the required-tables probe and the canary may pass --
        // what is left to tell the truth is the integrity probe alone.
        val pageSize = 4096
        var pageNo = 2
        while ((pageNo - 1) * pageSize + 8 <= body.size) {
            for (k in 0 until 8) body[(pageNo - 1) * pageSize + k] = 0xFF.toByte()
            pageNo += 1
        }
        smeared.writeBytes(body)
        val smearedSha = Sha256.hexOf(smeared)
        val smearedFacts = ArchiveManifestFacts.fromJson(
            manifestJson(smeared.length(), smearedSha))
        val deep = ArchiveInstaller(freshRoot("smeared-deep")).install(
            { smeared.readBytes() }, smearedFacts)
        assertTrue("an integrity-failing bundle with a true record must be Refused, got " + deep,
            deep is InstallOutcome.Rejected)
        assertTrue("the refusal must speak of the probe, got " +
            (deep as InstallOutcome.Rejected).cause,
            (deep as InstallOutcome.Rejected).cause.contains("probe"))
    }

    @Test
    fun testTheTypedStatesReportThemelvesAtTheRepositoryFace() {
        // the empty root speaketh first, and saith what is missing
        val barren = ArchiveRepository(FakeBridge(emptyMap(), freshRoot("barren")), COURT_ASSET)
        assertFalse("nothing installed cannot be available", barren.isAvailable)
        val barrenState = barren.state
        assertTrue("the empty root must report Unavailable, got " + barrenState,
            barrenState is ArchiveState.Unavailable)
        assertTrue("and name the want of the bundle, got " +
            (barrenState as ArchiveState.Unavailable).reason,
            (barrenState as ArchiveState.Unavailable).reason.contains("missing"))

        // the well-furnished bridge serveth, typed throughout
        val built = installFixture("typed-face")
        val honest = ArchiveRepository(
            FakeBridge(
                mapOf(
                    COURT_ASSET to { built.file.readBytes() },
                    COURT_MANIFEST to { manifestJson(built.file.length(), built.facts.sha256).encodeToByteArray() },
                ),
                freshRoot("typed-honest"),
            ),
            COURT_ASSET,
        )
        assertTrue("the honest bridge must be available", honest.isAvailable)
        val ready = honest.state
        assertTrue("the honest state must be Ready, got " + ready, ready is ArchiveState.Ready)
        assertEquals("Ready must carry the trusted digest", built.facts.sha256,
            (ready as ArchiveState.Ready).sha256)
        assertEquals("three documents must answer by name", 3, honest.listDocuments(null).size)
        assertEquals("one critical document must answer", 1,
            honest.listDocuments(null).count { it.isCritical })
        assertEquals("the domain filter must filter", 1, honest.listDocuments("water").size)
        assertEquals("the domains must be listed whole", 3, honest.listDomains().size)
        assertEquals("passages must come home in order", 2, honest.passages(2L).size)
        val found = honest.search("power outages", limit = 10)
        assertTrue("the search must find", found.isNotEmpty())
        assertTrue("the best hit must rank first (scores descend), got " +
            found.joinToString(", ") { "" + it.score },
            found.first().score >= found.last().score)
        // the liar's manifest proveth the typed refusal
        val liar = ArchiveRepository(
            FakeBridge(
                mapOf(
                    COURT_ASSET to { built.file.readBytes() },
                    COURT_MANIFEST to { manifestJson(built.file.length(), "0".repeat(64)).encodeToByteArray() },
                ),
                freshRoot("typed-liar"),
            ),
            COURT_ASSET,
        )
        assertFalse("a lied manifest must not serve", liar.isAvailable)
        val lied = liar.state
        assertTrue("the lie must be reported as Unavailable, got " + lied,
            lied is ArchiveState.Unavailable)
        assertTrue("and its cause named, got " + (lied as ArchiveState.Unavailable).reason,
            (lied as ArchiveState.Unavailable).reason.contains("digest"))
        // an unreadable manifest is itself a cause, named
        val muddle = ArchiveRepository(
            FakeBridge(
                mapOf(
                    COURT_ASSET to { built.file.readBytes() },
                    COURT_MANIFEST to { "{not json".encodeToByteArray() },
                ),
                freshRoot("typed-muddle"),
            ),
            COURT_ASSET,
        )
        assertFalse("a muddled manifest must not serve", muddle.isAvailable)
        assertTrue("the muddle must name itself, got " + muddle.state,
            "${muddle.state}".contains("manifest"))
        // all five outcome-shapes must be reportable, none a bare boolean
        val shapes = listOf<InstallOutcome>(
            InstallOutcome.Selected("f".repeat(64), 1L),
            InstallOutcome.Refreshed("e".repeat(64), 1L),
            InstallOutcome.Rejected("a cause"),
            InstallOutcome.Unavailable("a reason"),
        )
        assertEquals("the outcome alphabet must hold its four letters", 4, shapes.size)
        assertTrue("each letter must speak", shapes.all { "$it".isNotEmpty() })
    }
}
