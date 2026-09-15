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
import io.godstone.core.archive.ArchiveReadException
import io.godstone.core.archive.ArchiveRepository
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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


}
