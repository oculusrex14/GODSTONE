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

    /**
     * *** THE THIRD STATE, WHICH THE OLD FACE COULD NOT SPEAK AT ALL. ***
     *
     * `sourceMetadata` use'th to begin `val h = arm.handle ?: return null` -- so a road that was NEVER ARMED
     * answer'd the very same sentence as a row that truly carrieth no citation. The reader could not tell
     * "the archive is not installed" from "this document hath no source", and neither could the UI; and it
     * is the second of those two that is *honest*, which is what made the first so hard to see.
     *
     * `null` herer therefore meaneth one thing only -- *the road was armed, the query ran, and the row
     * carrieth no citation*. An un-armed road hath queried nothing and so may make no claim about a row:
     * it cryeth, typed, naming its road. (The list roads' un-armed answer is `emptyList()`, which this
     * court witnesseth above; a nil list is not a claim about one specific row, while a nil provenance
     * projection IS -- which is why the two roads are allowed to differ here, and why this arm existeth.)
     */
    @Test fun test_archive002_an_unarmed_road_is_not_an_uncited_row() {
        val archive = conformingArchive("unarmed-provenance.db")      // no manifest written
        val repository = repositoryOver(archive, "unarmed-provenance")
        assertFalse("the seat must be un-armed, or this arm prove'th nothing", repository.isAvailable)

        var fault: ArchiveReadException? = null
        val answered = try { repository.sourceMetadata(1L) } catch (exc: ArchiveReadException) { fault = exc; "CR" }
        assertTrue("*** THE UN-ARMED ROAD ANSWER'D [$answered] -- a nil here is the conflation this arm " +
            "existeth to kill: it claimeth the row hath no citation, when in truth nothing was ever " +
            "queried ***", fault != null)
        // *** AND THE TALE'S WORDING IS NOT ASSERTED. *** *Two `contains(...)` clauses stood here and are
        // DELETED by the developer mandate: a message is an INCIDENTAL of the implementation, and pinning a test
        // to its spelling testeth the label rather than the behaviour -- it would also forbid the message being
        // reworded for a GOOD reason. What this arm witnesseth, and all it witnesseth, is the BEHAVIOUR: the
        // un-armed road cryeth TYPED (`ArchiveReadException`) instead of answering a nil that a caller would
        // read as "this row carrieth no citation".*
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

    /**
     * GS-ARCHIVE-002 (repository half): EVERY read road raiseth the typed refusal, and no road may
     * SWALLOW a failure into an empty result.
     *
     * *** THIS ARM USED TO READ THE SOURCE FILE AND LOOK FOR `checkedRead("listDocuments")`. *** That
     * is a copy of the implementation, not a witness: it stay'th green while the roads still swallow,
     * so long as the *spellings* survive, and it goeth red when a road is renamed for an unrelated
     * cause. THE PROPERTY IS DEMONSTRATED HERE INSTEAD, ON THE REAL REPOSITORY OVER REAL BYTES: a
     * road's own table is struck from beneath a live, already-armed handle (the same move `w02` make'th
     * against a live handle) and the road is then asked -- where a road that swalloweth answereth an
     * EMPTY LIST, which is the audit's exact defect, and a road that tell'th the truth cryeth.
     *
     * The provenance road `sourceMetadata` is in this roster now, and it belongeth here for the same
     * reason the other four do: it uset to answer `runCatching { … }.getOrNull()`, so its failure
     * arrive'd as `null` -- one step WORSE than an empty list, for `null` is also the honest answer for
     * a row that carrieth no citation at all.
     *
     * *** AND THE FIRST DRAFT OF THIS REWRITE WAS ITSELF RED, WHICH IS WHY THE STRIKE TARGET IS NOW READ
     * FROM THE VERDICT. *** *I struck `archive.absolutePath` -- the STAGED fixture -- and the hosted run
     * reported `[listDocuments] THE ROAD SWALLOW'D: it answer'd [null]` with no exception. **THE ROAD WAS
     * INNOCENT: the repository never opened the file I struck.** `ArchiveInstaller.install` probeth a
     * staged candidate and then PROMOTES it by rename into `current/archive.db`
     * (`ArchiveInstaller.CURRENT_DIR_NAME` + `ARCHIVE_FILE_NAME`), and every road readeth THAT file -- so
     * a mutation upon the staged copy is invisible to the whole repository. The file to strike is the one
     * the verdict itself nameth (`ArchiveState.Ready.origin`), and there is no result cache to work
     * around: each road re-queryeth through `checkedRead`, as a search for `cache` in the repository
     * confirmeth. **The defect was in the WITNESS, not in the road -- and it was found by running it.***
     */
    @Test fun test_archive002_no_read_road_swalloweth_a_failure() {
        val roads = listOf(
            Triple("listDocuments", "DROP TABLE documents",
                { r: ArchiveRepository -> r.listDocuments() }),
            Triple("listDomains", "DROP TABLE documents",
                { r: ArchiveRepository -> r.listDomains() }),
            Triple("passages", "DROP TABLE chunks",
                { r: ArchiveRepository -> r.passages(1L) }),
            Triple("search", "DROP TABLE chunks_fts",
                { r: ArchiveRepository -> r.search("bandage", 5) }),
            Triple("sourceMetadata", "DROP TABLE documents",
                { r: ArchiveRepository -> r.sourceMetadata(1L) }),
        )
        for ((road, strike, ask) in roads) {
            val label = "[$road]"
            val archive = conformingArchive("nofallthrough-$road.db")
            File(archive.parentFile, archive.name + ".manifest").writeText(
                manifestJson(archive, tier = "LIGHT", fileName = archive.name), Charsets.UTF_8)
            val repository = repositoryOver(archive, "nofallthrough-$road")
            // THE ROAD MUST BE ARMED FIRST: a refusal from an un-armed road would prove no-thing.
            val verdict = repository.status()
            assertTrue("$label the fixture must arm Ready, got $verdict",
                repository.isAvailable)
            // *** THE STRIKE MUST FALL UPON THE FILE THE REPOSITORY ACTUALLY SERVES. ***
            //
            // *MEASURED FAILURE OF MY FIRST DRAFT: I struck `archive.absolutePath` -- the STAGED fixture -- and this
            // arm failed with "[listDocuments] THE ROAD SWALLOW'D: it answer'd [null]". **The road was innocent: the
            // repository never opened the staged file.** `ArchiveInstaller.install` PROBES a staged candidate and
            // then PROMOTES it by rename into `current/archive.db` (`ArchiveInstaller.CURRENT_DIR_NAME`), and the
            // repository readeth THAT file -- so a mutation applied to the staged copy is invisible to every road.
            // The verdict's own `origin` NAMETH the served file, which is why it is read from the verdict rather
            // than inferred from the path I happened to construct.*
            val served = File((verdict as io.godstone.core.archive.ArchiveState.Ready).origin)
            assertTrue("$label the verdict must name the served file that existeth: ${served.path}",
                served.isFile)

            // the positive half of the same seat, BEFORE the strike, so the road is proved live
            // on these very bytes and the later cry cannot be blamed on a bad fixture.
            ask(repository)                                   // must NOT cry yet

            val driver: SQLiteDriver = BundledSQLiteDriver()
            driver.open(served.absolutePath).use { conn -> conn.prepare(strike).use { it.step() } }

            var fault: ArchiveReadException? = null
            val swallowed = try { ask(repository); null } catch (exc: ArchiveReadException) { fault = exc; "SWALLOWED" }
            assertTrue("$label THE ROAD SWALLOW'D: it answer'd [$swallowed] where a struck table oweth " +
                "a typed ArchiveReadException -- an empty list, or a nil, is the audited defect",
                fault != null)
            // *** AND NOTHING IS ASSERTED ABOUT THE TALE'S WORDING. *** *A `contains(road)` assertion stood here
            // and was the ONLY red in the hosted run: the exception's message is an INCIDENTAL of the
            // implementation -- `archive read failed: SELECT …` nameth the statement, not the road label -- and
            // re-pinning the assertion to the actual text would test the spelling rather than the behaviour.
            // THE DEVELOPER MANDATE IS EXPLICIT: a test that asserteth incidental wording MUST be DELETED and
            // NEVER re-pinned, and the production message MUST NOT be changed to appease a test. The BEHAVIOUR is
            // what this loop witnesseth, five times over: healthy before the strike, typed `ArchiveReadException`
            // after it.*
        }
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
