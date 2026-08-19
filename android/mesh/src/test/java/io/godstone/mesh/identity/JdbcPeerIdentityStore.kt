package io.godstone.mesh.identity

import java.io.File
import java.sql.Connection
import java.sql.DriverManager
import java.sql.Types

/**
 * Test-only [PeerIdentityStore] backed by a real SQLite database on disk via sqlite-jdbc.
 */
internal class JdbcPeerIdentityStore(file: File) : PeerIdentityStore {
    private val conn: Connection

    init {
        Class.forName("org.sqlite.JDBC")
        conn = DriverManager.getConnection("jdbc:sqlite:" + file.absolutePath)
        // Set busy timeout for cross-connection concurrency arbitration
        conn.createStatement().use { it.execute("PRAGMA busy_timeout = 5000") }
        runMigrations()
    }

    private fun readUserVersion(): Int =
        conn.prepareStatement("PRAGMA user_version").use { ps ->
            ps.executeQuery().use { rs -> if (rs.next()) rs.getInt(1) else 0 }
        }

    private fun tableExists(name: String): Boolean =
        conn.prepareStatement("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").use { ps ->
            ps.setString(1, name)
            ps.executeQuery().use { it.next() }
        }

    private fun runMigrations() {
        val v = readUserVersion()
        val exists = tableExists(PeerIdentitySchema.TABLE)

        when {
            v == 0 && !exists -> {
                conn.createStatement().use { it.execute("BEGIN IMMEDIATE") }
                try {
                    conn.createStatement().use { it.execute(PeerIdentitySchema.CREATE_TABLE_SQL) }
                    conn.createStatement().use { it.execute("COMMIT") }
                } catch (e: Throwable) {
                    runCatching { conn.createStatement().use { it.execute("ROLLBACK") } }
                    throw e
                }
                conn.createStatement().use { it.execute("PRAGMA user_version = ${PeerIdentitySchema.DB_VERSION}") }
                validateSchema()
            }
            v == 0 && exists -> {
                throw IllegalStateException("Unversioned existing peer_identities table found (fail-closed)")
            }
            v == PeerIdentitySchema.DB_VERSION -> {
                validateSchema()
            }
            else -> {
                throw IllegalStateException(
                    "Refusing to open future peer store schema: user_version=$v > DB_VERSION=${PeerIdentitySchema.DB_VERSION}"
                )
            }
        }
    }

    private fun validateSchema() {
        conn.prepareStatement(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?"
        ).use { ps ->
            ps.setString(1, PeerIdentitySchema.TABLE)
            ps.executeQuery().use { rs ->
                if (!rs.next()) throw IllegalStateException("Table ${PeerIdentitySchema.TABLE} missing")
                val actual = rs.getString(1) ?: ""
                if (PeerIdentitySchema.normalizeSql(actual) != PeerIdentitySchema.normalizeSql(PeerIdentitySchema.CREATE_TABLE_SQL)) {
                    throw IllegalStateException("Peer identity table DDL mismatch")
                }
            }
        }
    }

    override fun <T> inImmediateTransaction(block: (PeerIdentityStore) -> T): T {
        conn.createStatement().use { it.execute("BEGIN IMMEDIATE") }
        try {
            val result = block(this)
            conn.createStatement().use { it.execute("COMMIT") }
            return result
        } catch (e: Throwable) {
            runCatching { conn.createStatement().use { it.execute("ROLLBACK") } }
            throw e
        }
    }

    override fun readRaw(nodeId: ByteArray): PeerIdentityRow? {
        return conn.prepareStatement(PeerIdentitySchema.READ_RAW_SQL).use { ps ->
            ps.setBytes(1, nodeId)
            ps.executeQuery().use { rs ->
                if (!rs.next()) null
                else {
                    val nodeIdBytes = rs.getBytes(1)
                    val signPubBytes = rs.getBytes(2)
                    val accStaticBytes = rs.getBytes(3)
                    val accGen = rs.getLong(4)
                    val trustCode = rs.getInt(5)
                    val pendStaticBytes = rs.getBytes(6)
                    val pendGen = if (rs.getObject(7) == null) null else rs.getLong(7)

                    PeerIdentityRow(
                        nodeIdRaw = nodeIdBytes,
                        signingPublicKeyRaw = signPubBytes,
                        acceptedStaticDhPublicKeyRaw = accStaticBytes,
                        acceptedGenerationRaw = accGen,
                        trustCodeRaw = trustCode,
                        pendingStaticDhPublicKeyRaw = pendStaticBytes,
                        pendingGenerationRaw = pendGen
                    )
                }
            }
        }
    }

    override fun insertFirstSeen(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustCode: Int
    ): Int {
        return conn.prepareStatement(PeerIdentitySchema.INSERT_FIRST_SEEN_SQL).use { ps ->
            ps.setBytes(1, nodeId)
            ps.setBytes(2, signingPub)
            ps.setBytes(3, acceptedStatic)
            ps.setLong(4, acceptedGeneration)
            ps.setInt(5, trustCode)
            ps.executeUpdate()
        }
    }

    override fun setInitialPendingGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        newPendingStatic: ByteArray,
        newPendingGeneration: Long
    ): Int {
        return conn.prepareStatement(PeerIdentitySchema.SET_INITIAL_PENDING_SQL).use { ps ->
            ps.setBytes(1, newPendingStatic)
            ps.setLong(2, newPendingGeneration)
            ps.setBytes(3, nodeId)
            ps.setBytes(4, signingPub)
            ps.setBytes(5, acceptedStatic)
            ps.setLong(6, acceptedGeneration)
            ps.setInt(7, trustLevel)
            ps.executeUpdate()
        }
    }

    override fun advancePendingGuarded(
        nodeId: ByteArray,
        signingPub: ByteArray,
        acceptedStatic: ByteArray,
        acceptedGeneration: Long,
        trustLevel: Int,
        oldPendingStatic: ByteArray,
        oldPendingGeneration: Long,
        newPendingStatic: ByteArray,
        newPendingGeneration: Long
    ): Int {
        return conn.prepareStatement(PeerIdentitySchema.ADVANCE_PENDING_SQL).use { ps ->
            ps.setBytes(1, newPendingStatic)
            ps.setLong(2, newPendingGeneration)
            ps.setBytes(3, nodeId)
            ps.setBytes(4, signingPub)
            ps.setBytes(5, acceptedStatic)
            ps.setLong(6, acceptedGeneration)
            ps.setInt(7, trustLevel)
            ps.setBytes(8, oldPendingStatic)
            ps.setLong(9, oldPendingGeneration)
            ps.executeUpdate()
        }
    }

    override fun execRawSql(sql: String) {
        conn.createStatement().use { it.execute(sql) }
    }

    override fun close() {
        conn.close()
    }
}
