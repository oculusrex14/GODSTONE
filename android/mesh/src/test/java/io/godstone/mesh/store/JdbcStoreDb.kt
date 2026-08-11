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
        // IF NOT EXISTS so a test can pre-seed the file (e.g. a bad-type row)
        // and reopen it without "table already exists" failing the open.
        conn.createStatement().use { it.execute(StoreSchema.CREATE_SQL_IF_NOT_EXISTS) }
        // Stage 4C / C4: delivery_state table, idempotent (same as held_frames).
        conn.createStatement().use { it.execute(StoreSchema.CREATE_DELIVERY_SQL_IF_NOT_EXISTS) }
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
    override fun inTransaction(block: (StoreDb) -> PersistResult): PersistResult {
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