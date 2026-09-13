package io.godstone.core.archive

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteDriver
import androidx.sqlite.SQLiteStatement
import java.io.File

/**
 * The read-only handle over one Archive, opened through the pinned
 * ANDROIDX BUNDLED driver -- never through the platform engine, whose
 * FTS5 availability is not a portable contract (blueprint s17).
 *
 * The handle is made read-only twice over: PRAGMA query_only = ON
 * setteth the engine's own refusal of writes upon the connection, and
 * the readiness court proveth that a write attempt is denied. The
 * column-type codes below mirror the SQLITE_DATA_* enumeration of the
 * bundled engine (INTEGER 1, FLOAT 2, BLOB 3, NULL 4, TEXT 5); the
 * court proveth the mirroring against the answering engine itself.
 */
class ArchiveDatabase private constructor(
    private val connection: SQLiteConnection,
    private val driver: SQLiteDriver,
) : AutoCloseable {

    /** Name of the driver class that opened this handle: the provenance
     * witness readeth it. On every road it must answer the bundled one. */
    val driverClassName: String get() = (connection as Any)::class.java.name

    /** SELECT sqlite_version() -- the built-in scalar of the actual
     * engine that answered; "3.x.y" of the bundled stock. */
    fun versionString(): String =
        query("SELECT sqlite_version()", { }) { st -> if (st.step()) st.getText(0) ?: "" else "" }

    /** PRAGMA integrity_check -- "ok" or a full tale of faults. */
    fun integrityCheck(): String =
        query("PRAGMA integrity_check", { }) { st -> if (st.step()) st.getText(0) ?: "null" else "absent" }

    fun hasTable(name: String): Boolean =
        query("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name = ?",
            { st -> st.bindText(1, name) }) { st -> st.step() }

    /** The FTS5 canary: a virtual table of the fts5 module is created,
     * written and matched; every step must answer, else the capability
     * is not there and the caller refuseth the file. */
    fun fts5Capable(): Boolean = runCatching {
        val canary = driver.open(":memory:")
        try {
            canary.prepare("CREATE VIRTUAL TABLE t47_canary USING fts5(canary)").use { it.step() }
            canary.prepare("INSERT INTO t47_canary(canary) VALUES('power source')").use { it.step() }
            var hit = false
            canary.prepare("SELECT canary FROM t47_canary WHERE t47_canary MATCH ?").use { st ->
                st.bindText(1, "\"power\"")
                hit = st.step()
            }
            canary.prepare("DROP TABLE t47_canary").use { it.step() }
            hit
        } finally {
            canary.close()
        }
    }.getOrDefault(false)

    /** Run one read query: the bind block bindeth (0-based), the read
     * block readeth. The statement is closed either way. */
    fun <T> query(sql: String, bind: (SQLiteStatement) -> Unit, read: (SQLiteStatement) -> T): T {
        val statement = connection.prepare(sql)
        try {
            bind(statement)
            return read(statement)
        } finally {
            statement.close()
        }
    }

    fun exec(sql: String) {
        val statement = connection.prepare(sql)
        try {
            statement.step()
        } finally {
            statement.close()
        }
    }

    /** Collect every row of a read query into lists of column values. */
    fun rows(sql: String, args: Array<out Any?>): List<List<Any?>> =
        query(sql, { st ->
            for ((index, value) in args.withIndex()) {
                when (value) {
                    null -> st.bindNull(index + 1)
                    is Long -> st.bindLong(index + 1, value)
                    is Int -> st.bindLong(index + 1, value.toLong())
                    is Boolean -> st.bindLong(index + 1, if (value) 1L else 0L)
                    is Double -> st.bindDouble(index + 1, value)
                    is ByteArray -> st.bindBlob(index + 1, value)
                    else -> st.bindText(index + 1, value.toString())
                }
            }
        }, { st ->
            val out = ArrayList<List<Any?>>()
            while (st.step()) {
                val row = ArrayList<Any?>(st.getColumnCount())
                for (col in 0 until st.getColumnCount()) {
                    row.add(when (st.getColumnType(col)) {
                    CODE_INTEGER -> st.getLong(col)
                    CODE_FLOAT -> st.getDouble(col)
                    CODE_TEXT -> st.getText(col)
                    else -> if (st.isNull(col)) null
                    else runCatching { st.getBlob(col) }.getOrNull()
                        ?: runCatching { st.getText(col) }.getOrNull()
                })
                }
                out.add(row)
            }
            out
        })

    override fun close() {
        connection.close()
    }

    companion object {
// The numbering as the bundled driver of this build speaks it,
        // proved by the court probe of the very same engine: INTEGER 1, FLOAT 2,
        // TEXT 3. What remaineth of the further numbers (blob/null territory) is
        // answered not by a guessed constant but by an honest fall back: isNull
        // first, then blob, then text.
        const val CODE_INTEGER = 1
        const val CODE_FLOAT = 2
        const val CODE_TEXT = 3

        /** The tables every conforming Archive must carry; the probe is
         * not complete without them. */
        val REQUIRED_TABLES: Set<String> = setOf("documents", "chunks", "chunks_fts")

        /**
         * Open [file] read-only through the bundled driver and make it
         * safe for the browsing road: the query_only pragma setteth the
         * engine's own refusal, the mmap pragma riseth as the house
         * keeps it, and every required table, the FTS5 canary and the
         * integrity check must answer -- else IllegalStateException
         * crieth out and the caller refuseth.
         */
        fun openReadOnly(
            file: File,
            driver: SQLiteDriver = ArchiveDrivers.required(),
        ): ArchiveDatabase {
            if (!file.isAbsolute) {
                throw IllegalArgumentException("archive path must be absolute: $file")
            }
            if (!file.isFile) {
                throw IllegalStateException("archive file is missing: $file")
            }
            val connection = driver.open(file.absolutePath)
            var opened: ArchiveDatabase? = null
            var ok = false
            try {
                val handle = ArchiveDatabase(connection, driver)
                opened = handle
                handle.exec("PRAGMA query_only = ON")
                handle.exec("PRAGMA mmap_size = 268435456")
                val missing = REQUIRED_TABLES.filterNot { name -> handle.hasTable(name) }
                if (missing.isNotEmpty()) {
                    throw IllegalStateException(
                        "archive is missing required table(s): " + missing.joinToString(", "))
                }
                if (!handle.fts5Capable()) {
                    throw IllegalStateException(
                        "the FTS5 canary did not answer: the bundled engine " +
                            "cannot serve this archive")
                }
                val integrity = handle.integrityCheck()
                if (!integrity.startsWith("ok")) {
                    throw IllegalStateException("integrity_check did not answer ok: $integrity")
                }
                ok = true
            } finally {
                if (!ok) runCatching { connection.close() }
            }
            return opened!!
        }

        /** Prove the file without a long-lived handle: open, probe,
         * close. null when [openReadOnly] would have accepted it; else
         * the named cause of the refusal. */
        fun verify(file: File, driver: SQLiteDriver = ArchiveDrivers.required()): String? =
            try {
                val handle = openReadOnly(file, driver)
                try {
                    val version = handle.versionString()
                    if (!version.startsWith("3.")) {
                        "engine version is not of the bundled stock: $version"
                    } else {
                        null
                    }
                } finally {
                    handle.close()
                }
            } catch (exc: Throwable) {
                "handle could not be opened: " + (exc.message ?: exc::class.simpleName)
            }
    }
}
