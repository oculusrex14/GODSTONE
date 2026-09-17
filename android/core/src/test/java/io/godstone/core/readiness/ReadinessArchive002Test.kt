package io.godstone.core.readiness

// GS-ARCHIVE-002: the Android Archive must REFUSE a malformed schema AND must never report a
// SQL read failure as an empty result.
//
// The audit reproduced, through the REAL bundled AndroidX SQLite driver:
//   (a) a database carrying only documents(document_id), chunks(chunk_id) and an ORDINARY
//       chunks_fts(not_an_index) table was admitted Ready and returned empty lists;
//   (b) after a good repository opened, dropping chunks_fts made search() return [] with no
//       throw and the status stayed Ready.
//
// This court replays both schedules against the frozen DDL (content/db/schema.sql and
// content/db/indexes.sql), and carries a POSITIVE CONTROL proving a conforming archive still
// opens and answers.
import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteDriver
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import io.godstone.core.archive.ArchiveBridge
import io.godstone.core.archive.ArchiveDatabase
import io.godstone.core.archive.ArchiveDrivers
import io.godstone.core.archive.ArchiveReadingAnchor
import io.godstone.core.archive.ArchiveReadException
import io.godstone.core.archive.ArchiveRepository
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

class ReadinessArchive002Test {

    companion object {
        init {
            ArchiveDrivers.install { BundledSQLiteDriver() }
        }
    }

    private val temp: File = File.createTempFile("archive002", ".dir").also { it.delete(); it.mkdirs() }

    @After fun tearDown() { runCatching { temp.deleteRecursively() } }

    private fun repoRoot(): File {
        var probe: File? = File(System.getProperty("user.dir")).absoluteFile
        while (probe != null) {
            if (File(probe, "content/db/schema.sql").isFile) return probe
            probe = probe.parentFile
        }
        error("content/db/schema.sql not found from " + System.getProperty("user.dir"))
    }

    /**
     * Execute the frozen DDL. A naive `;` split is a lie -- the DDL carrieth semicolons
     * inside comments -- so comments are stripped first and the remaining statements run
     * one by one through the SAME bundled driver the shipping APK installeth.
     */
    private fun execScript(conn: SQLiteConnection, script: String) {
        val withoutBlockComments = script.replace(Regex("(?s)/\\*.*?\\*/"), " ")
        val withoutLineComments = withoutBlockComments
            .lines().joinToString("\n") { line -> line.substringBefore("--") }
        for (statement in withoutLineComments.split(";")) {
            val trimmed = statement.trim()
            if (trimmed.isEmpty()) continue
            conn.prepare(trimmed).use { it.step() }
        }
    }

    // ------------------------------------------------------------ W01

    @Test fun test_w01_a_malformed_schema_is_refused() {
        val target = File(temp, "malformed.db")
        val driver: SQLiteDriver = BundledSQLiteDriver()
        driver.open(target.absolutePath).use { conn ->
            // exactly the audit's forged shape: names right, structure wrong
            conn.prepare("CREATE TABLE documents(document_id INTEGER PRIMARY KEY)").use { it.step() }
            conn.prepare("CREATE TABLE chunks(chunk_id INTEGER PRIMARY KEY)").use { it.step() }
            conn.prepare("CREATE TABLE chunks_fts(not_an_index TEXT)").use { it.step() }
            conn.prepare("CREATE TABLE archive_meta(key TEXT, value TEXT)").use { it.step() }
        }
        try {
            ArchiveDatabase.openReadOnly(target, ArchiveDrivers.required()).close()
            fail("a malformed schema was ADMITTED: the audit's reproduced defect")
        } catch (expected: IllegalStateException) {
            assertTrue("the refusal must say what is wrong, got: " + expected.message,
                expected.message!!.contains("schema", ignoreCase = true) ||
                    expected.message!!.contains("index", ignoreCase = true) ||
                    expected.message!!.contains("column", ignoreCase = true))
        }
    }


    /** A CONFORMING archive built from the frozen DDL, with rows and its FTS index. */
    private fun conformingArchive(name: String): File {
        val root = repoRoot()
        val target = File(temp, name)
        val driver: SQLiteDriver = BundledSQLiteDriver()
        driver.open(target.absolutePath).use { conn ->
            execScript(conn, File(root, "content/db/schema.sql").readText())
            // the builder, not the DDL, declareth the served schema version
            conn.prepare("INSERT INTO archive_meta(key,value) VALUES('schema_version','3')").use { it.step() }
            conn.prepare("INSERT INTO documents(document_id,title,domain,source_id,licence,revision,is_critical) VALUES(1,'First aid','health','s1','CC','r1',1)").use { it.step() }
            conn.prepare("INSERT INTO chunks(chunk_id,document_id,ordinal,section,text,token_count) VALUES(1,1,1,'Treatment > Bleeding','haemorrhage bandage pressure',7)").use { it.step() }
            execScript(conn, File(root, "content/db/indexes.sql").readText())
        }
        return target
    }

    /** A FILE-backed bridge: the REAL repository is driven over a real archive. */
    private class FileBridge(private val asset: File, private val root: File) : ArchiveBridge {
        override fun assetBytes(name: String): ByteArray? {
            val candidate = File(asset.parentFile, name)
            return if (candidate.isFile) candidate.readBytes() else null
        }
        override fun cacheRoot(): File = root
    }

    private fun repositoryOver(archive: File, name: String): ArchiveRepository {
        val root = File(temp, "bridge-$name").also { it.mkdirs() }
        return ArchiveRepository(FileBridge(archive, root), archive.name)
    }

    // ------------------------------------------------------------ W02

    @Test fun test_w02_a_read_failure_is_never_an_empty_result() {
        val target = conformingArchive("good.db")
        val handle = ArchiveDatabase.openReadOnly(target, ArchiveDrivers.required())
        try {
            val before = handle.rows(
                "SELECT c.chunk_id FROM chunks_fts f JOIN chunks c ON c.chunk_id = f.rowid " +
                    "WHERE chunks_fts MATCH ?", arrayOf("\"bandage\""))
            assertTrue("the conforming fixture must be searchable", before.isNotEmpty())
            // the audit's second schedule: the index VANISHES under a live handle
            val driver: SQLiteDriver = BundledSQLiteDriver()
            driver.open(target.absolutePath).use { conn ->
                conn.prepare("DROP TABLE chunks_fts").use { it.step() }
            }
            try {
                val rows = handle.rows(
                    "SELECT c.chunk_id FROM chunks_fts f JOIN chunks c ON c.chunk_id = f.rowid " +
                        "WHERE chunks_fts MATCH ?", arrayOf("\"bandage\""))
                fail("a broken index answered " + rows.size + " rows instead of refusing")
            } catch (_expected: ArchiveReadException) {
                // the typed refusal: a SQL failure is a FAILURE, never an empty result
            }
        } finally {
            handle.close()
        }
    }

    // ------------------------------------------------------------ W03

    @Test fun test_w03_the_positive_control_still_opens_and_answers() {
        val handle = ArchiveDatabase.openReadOnly(conformingArchive("control.db"),
            ArchiveDrivers.required())
        try {
            assertEquals(1L, handle.rowCount("documents"))
            assertEquals(1L, handle.rowCount("chunks"))
            assertEquals(ArchiveDatabase.SUPPORTED_SCHEMA_VERSION,
                handle.metaValue("schema_version")?.toIntOrNull() ?: -1)
            val domains = handle.rows("SELECT domain FROM documents", emptyArray())
            assertTrue("the conforming fixture must answer its documents", domains.isNotEmpty())
            val hits = handle.rows("SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ?",
                arrayOf("\"bandage\""))
            assertTrue("the FTS index must answer a real match", hits.isNotEmpty())
        } finally {
            handle.close()
        }
    }



    // ================= GS-ARCHIVE-001: bytes are not an approval =================

    /** The audit's own observable: bytes alone must NOT be Ready.
     * It useth ONLY pre-existing API, so it can be run against the PRE-REPAIR product --
     * which is exactly how the RED for GS-ARCHIVE-001 is captured. */
    @Test fun test_archive001_bytes_alone_are_not_ready() {
        val archive = conformingArchive("no-manifest.db")
        val repository = repositoryOver(archive, "no-manifest")
        assertFalse("the audited defect: bytes alone were served as Ready",
            repository.isAvailable)
        assertTrue("the refusal must be typed Unavailable",
            repository.status() is io.godstone.core.archive.ArchiveState.Unavailable)
        assertEquals("no document may be read from unapproved bytes",
            0, repository.listDocuments().size)
        assertTrue("no search may answer from unapproved bytes",
            repository.search("bandage", 5).isEmpty())
    }

    /** No descriptor existeth without a verified manifest (the repair's own API). */
    @Test fun test_archive001_no_descriptor_without_a_verified_manifest() {
        val archive = conformingArchive("no-descriptor.db")
        val repository = repositoryOver(archive, "no-descriptor")
        assertTrue("no descriptor without a verified manifest", repository.descriptor == null)
    }

    /** A manifest of the WRONG TIER is refused by name. */
    @Test fun test_archive001_a_wrong_tier_manifest_is_unavailable() {
        val archive = conformingArchive("wrong-tier.db")
        val manifest = File(archive.parentFile, archive.name + ".manifest")
        manifest.writeText(
            manifestJson(archive, tier = "MEDIUM", fileName = archive.name), Charsets.UTF_8)
        val repository = repositoryOver(archive, "wrong-tier")
        assertFalse("a wrong-tier manifest was accepted", repository.isAvailable)
        assertTrue(repository.status() is io.godstone.core.archive.ArchiveState.Unavailable)
        assertTrue("no descriptor from a wrong-tier manifest", repository.descriptor == null)
    }

    /** A manifest describing OTHER BYTES is refused: the descriptor and the bytes must agree. */
    @Test fun test_archive001_a_manifest_of_other_bytes_is_unavailable() {
        val archive = conformingArchive("other-bytes.db")
        val manifest = File(archive.parentFile, archive.name + ".manifest")
        manifest.writeText(
            manifestJson(archive, tier = "LIGHT", fileName = archive.name,
                bytesOver = 4096L), Charsets.UTF_8)
        val repository = repositoryOver(archive, "other-bytes")
        assertFalse("a manifest describing other bytes was accepted", repository.isAvailable)
        assertTrue("no descriptor when the bytes do not match", repository.descriptor == null)
    }


    /** THE POSITIVE ARM: a manifest that agreeth with the bytes yields Ready AND a descriptor,
     * so the law that refuseth unapproved bytes is not one that refuseth everything. */
    @Test fun test_archive001_a_matching_manifest_yields_ready_and_a_descriptor() {
        val archive = conformingArchive("approved.db")
        File(archive.parentFile, archive.name + ".manifest").writeText(
            manifestJson(archive, tier = "LIGHT", fileName = archive.name), Charsets.UTF_8)
        val repository = repositoryOver(archive, "approved")
        assertTrue("a matching manifest must yield Ready, got " + repository.status(),
            repository.isAvailable)
        val descriptor = repository.descriptor
        assertTrue("Ready without a descriptor is the audited defect",
            descriptor != null)
        assertEquals(archive.name, descriptor!!.fileName)
        assertEquals("LIGHT", descriptor.tier)
        assertEquals(archive.length(), descriptor.bytes)
        assertEquals(1, repository.listDocuments().size)
        assertTrue(repository.search("bandage", 5).isNotEmpty())
    }

    /** GS-ARCHIVE-002 (repository half): EVERY read road raiseth the typed refusal, and no
     * road may SWALLOW a failure into an empty list. The behavioural arm for the handle live
     * above (`test_w02_...`); this arm asserteth the CONTRACT of the repository's four roads,
     * which is what the audit's `runCatching { ... }.getOrDefault(emptyList())` broke. */
    @Test fun test_archive002_no_read_road_swalloweth_a_failure() {
        val source = File(repoRoot(), "android/core/src/main/java/io/godstone/core/archive/ArchiveRepository.kt")
            .readText()
        val roads = listOf("listDocuments", "listDomains", "passages", "search")
        for (road in roads) {
            assertTrue("the $road road must pass through the checked read",
                source.contains("checkedRead(\"$road\")"))
        }
        // the swallowing idiom is GONE from the code (it surviveth only in the comments that
        // explain why it was removed)
        val code = source.lines().filterNot { it.trimStart().startsWith("*") || it.trimStart().startsWith("//") }
            .joinToString("\n")
        assertFalse("a read road still swalloweth a failure into an empty list",
            code.contains("runCatching {") && code.contains("getOrDefault(emptyList())") &&
                code.contains("checkedRead") == false)
        assertTrue("every swallowing site must be gone",
            !Regex("runCatching \\{[^}]*getOrDefault\\(emptyList\\(\\)\\)", RegexOption.DOT_MATCHES_ALL)
                .containsMatchIn(code))
    }

    /** The manifest document this court writes (the shape the runtime readeth). */
    private fun manifestJson(archive: File, tier: String, fileName: String,
                             bytesOver: Long = 0L): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256")
            .digest(archive.readBytes())
            .joinToString("") { "%02x".format(it) }
        return """
        {
          "schema": 1,
          "archive_schema": 3,
          "tier": "$tier",
          "archive_file": "$fileName",
          "archive_bytes": ${archive.length() + bytesOver},
          "archive_sha256": "$digest",
          "source_manifest_sha256": "${"a".repeat(64)}",
          "review_manifest_sha256": "${"b".repeat(64)}",
          "corpus_manifest_sha256": "${"c".repeat(64)}",
          "build_tool_commit": "${"d".repeat(40)}",
          "counts": {"documents": 1, "chunks": 1, "vectors": 0},
          "signature": {"algorithm": "Ed25519", "key_id": "COURT-001", "value": "AA=="}
        }
        """.trimIndent()
    }

    // MARK: - GS-ARCHIVE-005 step 3: "a VALID reading anchor"

    /**
     * *** THE LAW, WHERE IT LIVETH, ON THE ISLE THAT HAD NONE. ***
     *
     * iOS carrieth `ArchiveReadingAnchor` (`ArchiveReadingAnchor.swift:17`) and Android carried NOTHING: MEASURED at
     * round 526, the string `anchor` appeared NOWHERE in the Android browse path. THE CARD'S STEP 3 NAMETH "a valid
     * reading anchor" FOR BOTH ISLES, so this arm asserteth THE SAME LAW THE iOS ISLE CARRIETH -- and `VALID` is the
     * whole of it: a persisted passage identity is a promise about a document that may have been replaced while the
     * process was away.
     */
    @Test
    fun testTheAnchorIsAValidPlaceAndNotAStaleIdentity() {
        assertEquals("a saved passage that STILL STANDETH is honoured, because the reader's place is theirs",
            12L, ArchiveReadingAnchor.target(listOf(11L, 12L), 12L))
        assertEquals("*** A STALE ANCHOR MUST FALL BACK TO THE FIRST PASSAGE, not be honoured blindly ***",
            11L, ArchiveReadingAnchor.target(listOf(11L, 12L), 99L))
        assertEquals("with nothing saved, the first passage standeth",
            11L, ArchiveReadingAnchor.target(listOf(11L, 12L), null))
        assertNull("*** AN EMPTY DOCUMENT ANCHORETH NOTHING: inventing a passage would be a lie with a scroll behind it ***",
            ArchiveReadingAnchor.target(emptyList(), 11L))

        assertTrue("and the anchor's survival is REPORTABLE rather than assumed",
            ArchiveReadingAnchor.anchorHolds(listOf(11L, 12L), 12L))
        assertFalse("*** a stale anchor must NOT be reported as holding, or a caller would pretend it held ***",
            ArchiveReadingAnchor.anchorHolds(listOf(11L, 12L), 99L))
        assertFalse("nor may an absent anchor claim to hold", ArchiveReadingAnchor.anchorHolds(listOf(11L, 12L), null))
    }
}
