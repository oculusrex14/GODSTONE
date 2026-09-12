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
                    conn.createStatement().use { it.execute("DROP TABLE IF EXISTS ${StoreSchema.ACK_FRAME_TABLE}") }
                    conn.createStatement().use { it.execute("DROP TABLE IF EXISTS ${StoreSchema.ACK_OBLIGATION_TABLE}") }
                    conn.createStatement().use { it.execute("DROP TABLE IF EXISTS ${StoreSchema.TABLE}") }
                    conn.createStatement().use { it.execute(StoreSchema.CREATE_SQL) }
                    conn.createStatement().use { it.execute(StoreSchema.CREATE_DELIVERY_SQL) }
                    conn.createStatement().use { it.execute(StoreSchema.CREATE_OBLIGATION_SQL) }
                    conn.createStatement().use { it.execute(StoreSchema.CREATE_ACK_FRAME_SQL) }
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

    /** DDL-fingerprint validation against `sqlite_master` for ALL FOUR tables
     *  (C6.4.1-E/F + T83 section 14). Throws on a missing table or DDL mismatch. */
    private fun validateSchema() {
        checkTableDdl(StoreSchema.TABLE, StoreSchema.CREATE_SQL)
        checkTableDdl(StoreSchema.DELIVERY_TABLE, StoreSchema.CREATE_DELIVERY_SQL)
        checkTableDdl(StoreSchema.ACK_OBLIGATION_TABLE, StoreSchema.CREATE_OBLIGATION_SQL)
        checkTableDdl(StoreSchema.ACK_FRAME_TABLE, StoreSchema.CREATE_ACK_FRAME_SQL)
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

    override fun insert(frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long): Long = synchronized(conn) {
        val sql = "INSERT OR IGNORE INTO ${StoreSchema.TABLE} (" +
            "${StoreSchema.COL_MSG_ID}, ${StoreSchema.COL_TYPE}, ${StoreSchema.COL_TTL}, " +
            "${StoreSchema.COL_HOP_COUNT}, ${StoreSchema.COL_FLAGS}, ${StoreSchema.COL_PRIORITY}, " +
            "${StoreSchema.COL_ROUTING_TAG}, ${StoreSchema.COL_PAYLOAD}, " +
            "${StoreSchema.COL_RECEIVED_FROM}, ${StoreSchema.COL_RECEIVED_AT}) " +
            "VALUES (?,?,?,?,?,?,?,?,?,?)"
        conn.prepareStatement(sql).use { ps ->
            ps.setBytes(1, frame.msgId)
            ps.setInt(2, frame.type.code.toInt() and 0xFF)
            ps.setInt(3, frame.ttl)
            ps.setInt(4, frame.hopCount)
            ps.setInt(5, frame.flags)
            ps.setInt(6, Priority.fromFlags(frame.flags).code)
            ps.setBytes(7, frame.routingTag)
            ps.setBytes(8, frame.payload)
            ps.setBytes(9, receivedFrom)
            ps.setLong(10, receivedAt)
            if (ps.executeUpdate() > 0) 1L else -1L   // IGNORE -> -1
        }
    }

    override fun contains(msgId: ByteArray): Boolean = synchronized(conn) {
        conn.prepareStatement(StoreSchema.containsSql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.executeQuery().use { rs -> rs.next() }
        }
    }

    override fun readHeld(msgId: ByteArray): StoreRow? = synchronized(conn) {
        conn.prepareStatement(StoreSchema.readHeldSql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                StoreRow(
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

    override fun heldBytes(): Long = synchronized(conn) {
        conn.prepareStatement(StoreSchema.heldBytesSql()).use { ps ->
            ps.executeQuery().use { rs -> if (rs.next()) rs.getLong(1) else 0L }
        }
    }

    override fun evictOldestPrefix(overshoot: Long) = synchronized(conn) {
        conn.prepareStatement(StoreSchema.evictPrefixSql()).use { ps ->
            ps.setLong(1, overshoot)
            ps.executeUpdate()
        }
        Unit
    }

    /**
     * One transaction on the single shared JDBC connection (B3). `insert` /
     * `contains` / `heldBytes` / `evictOldestPrefix` called inside [block]
     * participate (autoCommit=false -> sqlite-jdbc maps commit() to COMMIT). If
     * [block] throws, rollback and rethrow so the caller reports
     * `PersistResult.FAILED_STORAGE` and the store reopens in a valid state.
     */
    override fun <T> inTransaction(block: (StoreDb) -> T): T = synchronized(conn) {
        val wasAuto = conn.autoCommit
        conn.autoCommit = false
        try {
            val result = block(this)
            conn.commit()
            result
        } catch (e: Throwable) {
            runCatching { conn.rollback() }
            throw e
        } finally {
            conn.autoCommit = wasAuto
        }
    }

    override fun forEachRowOrderedByPriority(visit: (StoreRow) -> Boolean) = synchronized(conn) {
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

    override fun forEachMsgId(visit: (ByteArray) -> Boolean) = synchronized(conn) {
        conn.prepareStatement("SELECT ${StoreSchema.COL_MSG_ID} FROM ${StoreSchema.TABLE}").use { ps ->
            ps.executeQuery().use { rs ->
                while (rs.next()) {
                    if (!visit(rs.getBytes(1))) return
                }
            }
        }
    }

    // --- Stage 4C.1 / C6.1 -- delivery_state row (single atomic statements) ---

    override fun readDelivery(msgId: ByteArray): DeliveryRow? = synchronized(conn) {
        conn.prepareStatement(StoreSchema.readDeliverySql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                val state = rs.getInt(1)
                val ackMode = rs.getInt(2)
                val expected = rs.getBytes(3)   // null when the SQL column is NULL
                DeliveryRow(state, ackMode, expected)
            }
        }
    }

    override fun insertDelivery(
        msgId: ByteArray,
        stateOrdinal: Int,
        ackModeOrdinal: Int,
        expectedRecipient: ByteArray?,
    ): Boolean = synchronized(conn) {
        conn.prepareStatement(StoreSchema.insertDeliverySql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.setInt(2, stateOrdinal)
            ps.setInt(3, ackModeOrdinal)
            if (expectedRecipient == null) ps.setNull(4, Types.BLOB) else ps.setBytes(4, expectedRecipient)
            ps.executeUpdate() > 0   // 1 inserted, 0 on conflict (DO NOTHING)
        }
    }

    /**
     * Execute a guarded delivery UPDATE / DELETE (C6.4-F/G/H/J). Returns the
     * affected row count; THROWS SQLException on a storage failure -> the
     * repository maps it to the typed StorageFailure variant. The repository
     * builds the SQL (fixed transition mapping / ACK CAS / clear) and binds the
     * BLOB args in order (null -> SQL NULL).
     */
    override fun execDeliveryUpdate(sql: String, bytesArgs: Array<ByteArray?>): Int = synchronized(conn) {
        conn.prepareStatement(sql).use { ps ->
            bytesArgs.forEachIndexed { i, b ->
                if (b == null) ps.setNull(i + 1, Types.BLOB) else ps.setBytes(i + 1, b)
            }
            ps.executeUpdate()
        }
    }

    /** Raw no-arg SQL (C6.4 test seam -- `PRAGMA ignore_check_constraints`). */
    override fun execRawSql(sql: String): Unit = synchronized(conn) {
        conn.createStatement().use { it.execute(sql) }
    }

    override fun deleteHeld(msgId: ByteArray): Int = synchronized(conn) {
        conn.prepareStatement(
            "DELETE FROM ${StoreSchema.TABLE} WHERE ${StoreSchema.COL_MSG_ID} = ?"
        ).use { ps ->
            ps.setBytes(1, msgId)
            ps.executeUpdate()
        }
    }

    // --- T83 (section 14): the recipient ACK return path, JDBC mirror of the
    // SQLCipher primitives above (same SQL texts from StoreSchema; JDBC column
    // indexes are 1-based, the SQLite cursor indexes 0-based).

    override fun insertObligation(
        msgId: ByteArray,
        recipientNodeId: ByteArray,
        identityGeneration: Long,
        remainingLifetimeMs: Long,
        stateCode: Int,
    ): Boolean = synchronized(conn) {
        conn.prepareStatement(StoreSchema.insertObligationSql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.setBytes(2, recipientNodeId)
            ps.setLong(3, identityGeneration)
            ps.setLong(4, remainingLifetimeMs)
            ps.setLong(5, stateCode.toLong())
            ps.executeUpdate() > 0
        }
    }

    override fun readObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationEntryRow? =
        synchronized(conn) {
            conn.prepareStatement(StoreSchema.readObligationSql()).use { ps ->
                ps.setBytes(1, msgId)
                ps.setBytes(2, recipientNodeId)
                ps.executeQuery().use { rs ->
                    if (!rs.next()) return null
                    ObligationEntryRow(
                        msgId = msgId.copyOf(),
                        recipientNodeId = recipientNodeId.copyOf(),
                        identityGeneration = rs.getLong(1),
                        remainingLifetimeMs = rs.getLong(2),
                        stateCode = rs.getInt(3),
                    )
                }
            }
        }

    override fun listPendingObligations(bound: Int): List<ObligationEntryRow> = synchronized(conn) {
        conn.prepareStatement(StoreSchema.listPendingObligationSql()).use { ps ->
            ps.setLong(1, bound.toLong())
            ps.executeQuery().use { rs ->
                val out = ArrayList<ObligationEntryRow>()
                while (rs.next()) {
                    out.add(
                        ObligationEntryRow(
                            msgId = rs.getBytes(1),
                            recipientNodeId = rs.getBytes(2),
                            identityGeneration = rs.getLong(3),
                            remainingLifetimeMs = rs.getLong(4),
                            stateCode = rs.getInt(5),
                        ),
                    )
                }
                out
            }
        }
    }

    override fun countObligationRows(): Int = synchronized(conn) {
        conn.prepareStatement(StoreSchema.countObligationSql()).use { ps ->
            ps.executeQuery().use { rs -> if (!rs.next()) 0 else rs.getInt(1) }
        }
    }

    override fun casMarkObligationSigned(msgId: ByteArray, recipientNodeId: ByteArray): Int =
        synchronized(conn) {
            conn.prepareStatement(StoreSchema.markSignedObligationSql()).use { ps ->
                ps.setBytes(1, msgId)
                ps.setBytes(2, recipientNodeId)
                ps.executeUpdate()
            }
        }

    override fun deleteObligation(msgId: ByteArray, recipientNodeId: ByteArray): Int =
        synchronized(conn) {
            conn.prepareStatement(StoreSchema.retireObligationSql()).use { ps ->
                ps.setBytes(1, msgId)
                ps.setBytes(2, recipientNodeId)
                ps.executeUpdate()
            }
        }

    override fun insertAckFrameRow(row: AckFrameRowView): Boolean = synchronized(conn) {
        conn.prepareStatement(StoreSchema.insertAckFrameSql()).use { ps ->
            ps.setBytes(1, row.ackKey)
            ps.setBytes(2, row.msgId)
            ps.setBytes(3, row.recipientNodeId)
            ps.setBytes(4, row.signature)
            ps.setBytes(5, row.encodedFrame)
            if (row.receivedFrom == null) ps.setNull(6, Types.BLOB) else ps.setBytes(6, row.receivedFrom)
            ps.setLong(7, row.remainingLifetimeMs)
            ps.setLong(8, row.verificationClassCode.toLong())
            ps.executeUpdate() > 0
        }
    }

    override fun readAckFrameRowByAckKey(ackKey: ByteArray): AckFrameRowView? = synchronized(conn) {
        conn.prepareStatement(StoreSchema.readAckFrameSql()).use { ps ->
            ps.setBytes(1, ackKey)
            ps.executeQuery().use { rs ->
                if (!rs.next()) return null
                AckFrameRowView(
                    ackKey = ackKey.copyOf(),
                    msgId = rs.getBytes(1),
                    recipientNodeId = rs.getBytes(2),
                    signature = rs.getBytes(3),
                    encodedFrame = rs.getBytes(4),
                    receivedFrom = rs.getBytes(5),
                    remainingLifetimeMs = rs.getLong(6),
                    verificationClassCode = rs.getInt(7),
                )
            }
        }
    }

    override fun listAckFrameRowsForPair(
        msgId: ByteArray,
        recipientNodeId: ByteArray,
        bound: Int,
    ): List<AckFrameRowView> = synchronized(conn) {
        conn.prepareStatement(StoreSchema.listAckFrameForPairSql()).use { ps ->
            ps.setBytes(1, msgId)
            ps.setBytes(2, recipientNodeId)
            ps.setLong(3, bound.toLong())
            ps.executeQuery().use { rs ->
                val out = ArrayList<AckFrameRowView>()
                while (rs.next()) {
                    out.add(
                        AckFrameRowView(
                            ackKey = rs.getBytes(1),
                            msgId = rs.getBytes(2),
                            recipientNodeId = rs.getBytes(3),
                            signature = rs.getBytes(4),
                            encodedFrame = rs.getBytes(5),
                            receivedFrom = rs.getBytes(6),
                            remainingLifetimeMs = rs.getLong(7),
                            verificationClassCode = rs.getInt(8),
                        ),
                    )
                }
                out
            }
        }
    }

    override fun countAckFrameRowsForPair(msgId: ByteArray, recipientNodeId: ByteArray): Int =
        synchronized(conn) {
            conn.prepareStatement(StoreSchema.countAckFrameForPairSql()).use { ps ->
                ps.setBytes(1, msgId)
                ps.setBytes(2, recipientNodeId)
                ps.executeQuery().use { rs -> if (!rs.next()) 0 else rs.getInt(1) }
            }
        }

    override fun countAckFrameRowsTotal(): Int = synchronized(conn) {
        conn.prepareStatement(StoreSchema.countAckFrameTotalSql()).use { ps ->
            ps.executeQuery().use { rs -> if (!rs.next()) 0 else rs.getInt(1) }
        }
    }

    override fun deleteAllAckFrameRows(): Int = synchronized(conn) {
        conn.prepareStatement(StoreSchema.clearAckFramesSql()).use { it.executeUpdate() }
    }

    override fun commitAckPair(
        row: AckFrameRowView,
        msgId: ByteArray,
        recipientNodeId: ByteArray,
    ): FrameCommitOutcome = inTransaction { db ->
        val present = db.readAckFrameRowByAckKey(row.ackKey) != null
        if (!present) {
            if (db.countAckFrameRowsForPair(row.msgId, row.recipientNodeId) >=
                io.godstone.mesh.delivery.ACK_CANDIDATES_PER_PAIR_LIMIT
            ) {
                return@inTransaction FrameCommitOutcome.REFUSED_QUOTA_PAIR
            }
            if (db.countAckFrameRowsTotal() >= io.godstone.mesh.delivery.ACK_CANDIDATES_TOTAL_LIMIT) {
                return@inTransaction FrameCommitOutcome.REFUSED_QUOTA_GLOBAL
            }
            db.insertAckFrameRow(row)
        }
        db.deleteObligation(msgId, recipientNodeId)
        if (present) FrameCommitOutcome.IDEMPOTENT else FrameCommitOutcome.COMMITTED
    }

    override fun close() = synchronized(conn) { conn.close() }

    /**
     * Test seam: run a raw UPDATE against the SAME connection (C6.5 corrupt-write
     * tests mutate the state / ack_mode columns to unknown codes, then re-read via
     * [readDelivery] to assert [DeliveryLookup.Corrupt]). Using the shared
     * connection avoids any cross-connection file-lock issue. C6.4-C: with the new
     * `CHECK (state IN (1..5))`, planting a bad state code requires
     * `PRAGMA ignore_check_constraints = ON` first (see [execRawSql]); a plain
     * bad-state UPDATE is now rejected by the schema CHECK, which is the point.
     */
    internal fun execRawUpdate(sql: String, vararg bytesArgs: ByteArray): Int = synchronized(conn) {
        conn.prepareStatement(sql).use { ps ->
            bytesArgs.forEachIndexed { i, b -> ps.setBytes(i + 1, b) }
            ps.executeUpdate()
        }
    }
}