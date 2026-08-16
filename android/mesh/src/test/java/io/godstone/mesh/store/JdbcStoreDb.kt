package io.godstone.mesh.store

import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import java.io.File
import java.sql.Connection
import java.sql.DriverManager
import java.sql.Types

/**
 * Test-only [StoreDb] backed by a REAL on-disk SQLite via sqlite-jdbc.
 *
 * sqlite-jdbc ships native SQLite inside the jar (linux/mac/windows), so this is
 * a genuine SQLite engine -- not a mock, not Robolectric's shadowed
 * android.database.sqlite. The schema, `INSERT OR IGNORE`, the window-function
 * eviction and `SUM(LENGTH(blob))` byte accounting run as real SQL on real disk,
 * the same statements the production SQLCipher engine runs (StoreSchema is
 * shared). SQLCipher is SQLite plus page encryption, so the SQL semantics here
 * are identical to production; what this engine does NOT verify is the at-rest
 * encryption, which is a device/instrumented concern (the SQLCipher engine is
 * pinned structurally in StoreEngineTest).
 *
 * Lives in the test source set so it never reaches the shipping classpath (:mesh
 * is non-shipping regardless; this is belt-and-braces).
 */
internal class JdbcStoreDb(file: File) : StoreDb {
    private val conn: Connection

    init {
        Class.forName("org.sqlite.JDBC")
        conn = DriverManager.getConnection("jdbc:sqlite:" + file.absolutePath)
        // C6.4.1-BCDEFG: fail-closed version + schema-integrity logic, mirroring
        // the iOS StoreSchema runMigrations and the production Helper. The old
        // unconditional `CREATE ... IF NOT EXISTS` open is GONE: a file is now
        // rejected (throws) on a future version, a stale version is transactionally
        // dropped+recreated (no installed base -> destructive, ADR-001 §5), and a
        // current-version file is DDL-fingerprint-validated (a tampered /
        // partially-migrated file with the right version stamp but wrong DDL is
        // rejected, never silently opened).
        runMigrations()
    }

    // --- C6.4.1-BCDEFG: version + schema-integrity (mirrors iOS runMigrations) ---

    /** Current PRAGMA user_version (0 on a fresh file). */
    private fun readUserVersion(): Int =
        conn.prepareStatement("PRAGMA user_version").use { ps ->
            ps.executeQuery().use { rs -> if (rs.next()) rs.getInt(1) else 0 }
        }

    /**
     * Stale (< DB_VERSION) -> transactional DROP + CREATE both tables, then stamp
     * DB_VERSION AFTER the commit (a `PRAGMA user_version = N` inside a
     * sqlite-jdbc transaction is not guaranteed to be durable, so it runs outside
     * the txn; if the stamp fails the file simply re-migrates idempotently on the
     * next open -- no half-migrated schema, since the tables are already current).
     * Current (== DB_VERSION) -> DDL-fingerprint validate (throws on mismatch).
     * Future (> DB_VERSION) -> throw (fail closed, no silent downgrade).
     */
    private fun runMigrations() {
        val v = readUserVersion()
        when {
            v < StoreSchema.DB_VERSION -> {
                val wasAuto = conn.autoCommit
                conn.autoCommit = false
                try {
                    conn.createStatement().use { it.execute("DROP TABLE IF EXISTS ${StoreSchema.DELIVERY_TABLE}") }
                    conn.createStatement().use { it.execute("DROP TABLE IF EXISTS ${StoreSchema.TABLE}") }
                    conn.createStatement().use { it.execute(StoreSchema.CREATE_SQL) }
                    conn.createStatement().use { it.execute(StoreSchema.CREATE_DELIVERY_SQL) }
                    conn.commit()
                } catch (e: Throwable) {
                    runCatching { conn.rollback() }
                    throw e
                } finally {
                    conn.autoCommit = wasAuto
                }
                // Stamp outside the txn (see method doc).
                conn.createStatement().use { it.execute("PRAGMA user_version = ${StoreSchema.DB_VERSION}") }
            }
            v == StoreSchema.DB_VERSION -> validateSchema()
            else -> throw IllegalStateException(
                "refusing to open future store schema: user_version=$v > DB_VERSION=${StoreSchema.DB_VERSION}"
            )
        }
    }

    /** DDL-fingerprint validation against `sqlite_master` for BOTH tables
     *  (C6.4.1-E/F). Throws on a missing table or DDL mismatch. */
    private fun validateSchema() {
        checkTableDdl(StoreSchema.TABLE, StoreSchema.CREATE_SQL)
        checkTableDdl(StoreSchema.DELIVERY_TABLE, StoreSchema.CREATE_DELIVERY_SQL)
    }

    private fun checkTableDdl(name: String, expected: String) {
        conn.prepareStatement(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?"
        ).use { ps ->
            ps.setString(1, name)
            ps.executeQuery().use { rs ->
                if (!rs.next() || rs.getString(1) == null) {
                    throw IllegalStateException("store schema validation: missing table $name")
                }
                if (StoreSchema.normalizeSql(rs.getString(1)) != StoreSchema.normalizeSql(expected)) {
                    throw IllegalStateException("store schema validation: DDL mismatch for $name")
                }
            }
        }
    }

    override fun insert(frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long): Long {
        val sql = "INSERT OR IGNORE INTO ${StoreSchema.TABLE} (" +
            "${StoreSchema.COL_MSG_ID}, ${StoreSchema.COL_TYPE}, ${StoreSchema.COL_TTL}, " +
            "${StoreSchema.COL_HOP_COUNT}, ${StoreSchema.COL_FLAGS}, ${StoreSchema.COL_PRIORITY}, " +
            "${StoreSchema.COL_ROUTING_TAG}, ${StoreSchema.COL_PAYLOAD}, " +
            "${StoreSchema.COL_RECEIVED_FROM}, ${StoreSchema.COL_RECEIVED_AT}) " +
            "VALUES (?,?,?,?,?,?,?,?,?,?)"
        conn.prepareStatement(sql).use { ps ->
            ps.setBytes(1, frame.msgId)
            ps.setInt(2, frame.type.code.toInt())
            ps.setInt(3, frame.ttl)
            ps.setInt(4, frame.hopCount)
            ps.setInt(5, frame.flags)
            ps.setInt(6, Priority.fromFlags(frame.flags).code)
            ps.setBytes(7, frame.routingTag)
            ps.setBytes(8, frame.payload)
            ps.setBytes(9, receivedFrom)
            ps.setLong(10, receivedAt)
            return if (ps.executeUpdate() > 0) 1L else -1L   // IGNORE -> -1
        }
    }

    override fun contains(msgId: ByteArray): Boolean {
        conn.prepareStatement(StoreSchema.containsSql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.executeQuery().use { rs -> return rs.next() }
        }
    }

    override fun readHeld(msgId: ByteArray): StoreRow? {
        conn.prepareStatement(StoreSchema.readHeldSql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                return StoreRow(
                    typeCode = rs.getInt(1),
                    msgId = rs.getBytes(2),
                    routingTag = rs.getBytes(3),
                    ttl = rs.getInt(4),
                    hopCount = rs.getInt(5),
                    flags = rs.getInt(6),
                    payload = rs.getBytes(7),
                    receivedFrom = rs.getBytes(8),
                    receivedAt = rs.getLong(9),
                )
            }
        }
    }

    override fun heldBytes(): Long {
        conn.prepareStatement(StoreSchema.heldBytesSql()).use { ps ->
            ps.executeQuery().use { rs -> return if (rs.next()) rs.getLong(1) else 0L }
        }
    }

    override fun evictOldestPrefix(overshoot: Long) {
        conn.prepareStatement(StoreSchema.evictPrefixSql()).use { ps ->
            ps.setLong(1, overshoot)
            ps.executeUpdate()
        }
    }

    /**
     * One transaction on the single shared JDBC connection (B3). `insert` /
     * `contains` / `heldBytes` / `evictOldestPrefix` called inside [block]
     * participate (autoCommit=false -> sqlite-jdbc maps commit() to COMMIT). If
     * [block] throws, rollback and rethrow so the caller reports
     * `PersistResult.FAILED_STORAGE` and the store reopens in a valid state.
     */
    override fun <T> inTransaction(block: (StoreDb) -> T): T {
        val wasAuto = conn.autoCommit
        conn.autoCommit = false
        try {
            val result = block(this)
            conn.commit()
            return result
        } catch (e: Throwable) {
            runCatching { conn.rollback() }
            throw e
        } finally {
            conn.autoCommit = wasAuto
        }
    }

    override fun forEachRowOrderedByPriority(visit: (StoreRow) -> Boolean) {
        val sql = "SELECT ${StoreSchema.COL_TYPE}, ${StoreSchema.COL_MSG_ID}, " +
            "${StoreSchema.COL_ROUTING_TAG}, ${StoreSchema.COL_TTL}, ${StoreSchema.COL_HOP_COUNT}, " +
            "${StoreSchema.COL_FLAGS}, ${StoreSchema.COL_PAYLOAD} FROM ${StoreSchema.TABLE} " +
            "ORDER BY ${StoreSchema.PRIORITY_ORDER}"
        conn.prepareStatement(sql).use { ps ->
            ps.executeQuery().use { rs ->
                while (rs.next()) {
                    val row = StoreRow(
                        typeCode = rs.getInt(1),
                        msgId = rs.getBytes(2),
                        routingTag = rs.getBytes(3),
                        ttl = rs.getInt(4),
                        hopCount = rs.getInt(5),
                        flags = rs.getInt(6),
                        payload = rs.getBytes(7),
                    )
                    if (!visit(row)) return
                }
            }
        }
    }

    override fun forEachMsgId(visit: (ByteArray) -> Boolean) {
        conn.prepareStatement("SELECT ${StoreSchema.COL_MSG_ID} FROM ${StoreSchema.TABLE}").use { ps ->
            ps.executeQuery().use { rs ->
                while (rs.next()) {
                    if (!visit(rs.getBytes(1))) return
                }
            }
        }
    }

    // --- Stage 4C.1 / C6.1 -- delivery_state row (single atomic statements) ---

    override fun readDelivery(msgId: ByteArray): DeliveryRow? {
        conn.prepareStatement(StoreSchema.readDeliverySql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                val state = rs.getInt(1)
                val ackMode = rs.getInt(2)
                val expected = rs.getBytes(3)   // null when the SQL column is NULL
                return DeliveryRow(state, ackMode, expected)
            }
        }
    }

    override fun insertDelivery(
        msgId: ByteArray,
        stateOrdinal: Int,
        ackModeOrdinal: Int,
        expectedRecipient: ByteArray?,
    ): Boolean {
        conn.prepareStatement(StoreSchema.insertDeliverySql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.setInt(2, stateOrdinal)
            ps.setInt(3, ackModeOrdinal)
            if (expectedRecipient == null) ps.setNull(4, Types.BLOB) else ps.setBytes(4, expectedRecipient)
            return ps.executeUpdate() > 0   // 1 inserted, 0 on conflict (DO NOTHING)
        }
    }

    /**
     * Execute a guarded delivery UPDATE / DELETE (C6.4-F/G/H/J). Returns the
     * affected row count; THROWS SQLException on a storage failure -> the
     * repository maps it to the typed StorageFailure variant. The repository
     * builds the SQL (fixed transition mapping / ACK CAS / clear) and binds the
     * BLOB args in order (null -> SQL NULL).
     */
    override fun execDeliveryUpdate(sql: String, bytesArgs: Array<ByteArray?>): Int =
        conn.prepareStatement(sql).use { ps ->
            bytesArgs.forEachIndexed { i, b ->
                if (b == null) ps.setNull(i + 1, Types.BLOB) else ps.setBytes(i + 1, b)
            }
            ps.executeUpdate()
        }

    /** Raw no-arg SQL (C6.4 test seam -- `PRAGMA ignore_check_constraints`). */
    override fun execRawSql(sql: String) {
        conn.createStatement().use { it.execute(sql) }
    }

    override fun close() = conn.close()

    /**
     * Test seam: run a raw UPDATE against the SAME connection (C6.5 corrupt-write
     * tests mutate the state / ack_mode columns to unknown codes, then re-read via
     * [readDelivery] to assert [DeliveryLookup.Corrupt]). Using the shared
     * connection avoids any cross-connection file-lock issue. C6.4-C: with the new
     * `CHECK (state IN (1..5))`, planting a bad state code requires
     * `PRAGMA ignore_check_constraints = ON` first (see [execRawSql]); a plain
     * bad-state UPDATE is now rejected by the schema CHECK, which is the point.
     */
    internal fun execRawUpdate(sql: String, vararg bytesArgs: ByteArray): Int =
        conn.prepareStatement(sql).use { ps ->
            bytesArgs.forEachIndexed { i, b -> ps.setBytes(i + 1, b) }
            ps.executeUpdate()
        }
}