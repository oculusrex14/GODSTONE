package io.godstone.mesh.store

import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.sql.DriverManager
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * GS-STORE-003 (Android) -- actual message-store upgrades must not DROP durable
 * tables.
 *
 * The audit reproduced it behaviourally on the iOS probe and confirmed it by
 * source on both isles ("both production upgrade methods execute DROP TABLE").
 * W01/W02 assert the SOURCE facts in the production upgrade road
 * ([MessageStore.Helper.onUpgrade]); W04/W05 drive the SAME versioned road on the
 * host through [JdbcStoreDb] -- a REAL on-disk SQLite with the same SQL the
 * production engine runs -- and assert the BEHAVIOUR the audit reproduced. W06 is
 * the positive control (the harness can PASS as well as FAIL).
 *
 * These are RED against the destructive road: an older stamped file loses its held
 * frames on reopen, and a drifted file is silently recreated instead of refused.
 */
class ReadinessStore003Test {

    private lateinit var tmp: File

    @Before
    fun setUp() {
        tmp = Files.createTempFile("godstone-store003", ".db").toFile()
    }

    @After
    fun tearDown() {
        tmp.delete()
    }

    // ---- the SOURCE arm: what the audit confirmed by inspection ----

    /** W01 -- the VERSIONED upgrade path may not drop durable tables. */
    @Test
    fun `W01 the versioned upgrade doth not drop durable tables`() {
        val code = stripProse(upgradeBody(storeSource()))
        assertFalse(
            code.contains("DROP TABLE"),
            "the production onUpgrade executes DROP TABLE: a versioned reopen LOSES the held " +
                "frames the store exists to keep (GS-STORE-003)",
        )
    }

    /** W02 -- the migration engine that REPLACES the drop path must be the one BOUND to onUpgrade. */
    @Test
    fun `W02 the migration engine is bound to the upgrade`() {
        val code = stripProse(upgradeBody(storeSource()))
        assertTrue(
            code.contains("SchemaMigrationEngine") || code.contains("migrationPlan"),
            "MessageStore must CALL the non-destructive migration engine on its upgrade road; its " +
                "own contract says the engine is what the runtime binds onUpgrade to once installs " +
                "must survive (GS-STORE-003)",
        )
    }

    // ---- the BEHAVIOURAL arms: the audit's reproduction, on the host ----

    /** W04 -- THE AUDIT'S PROBE: an older stamped file whose DDL is compatible keeps its rows. */
    @Test
    fun `W04 an older stamped file must migrate instead of losing durable rows`() = runBlocking {
        // boot 1: fresh file -- the schema is created and stamped at DB_VERSION.
        val db1 = JdbcStoreDb(tmp)
        val store1 = SqliteMessageStore(db1, Long.MAX_VALUE)
        val mid = msgId(70)
        store1.persist(frame(mid, 32), ByteArray(0))
        assertEquals(listOf(true), store1.allHeldMsgIds().map { it.contentEquals(mid) })
        // A stale dev file: the DDL is already the CURRENT one, only the stamp is old.
        stamp(4)
        db1.close()
        // boot 2: an EXISTING older file must MIGRATE, never delete.
        val db2 = JdbcStoreDb(tmp)
        val store2 = SqliteMessageStore(db2, Long.MAX_VALUE)
        val heldAfter = store2.allHeldOrderedByPriority().filter { it.msgId.contentEquals(mid) }
        assertEquals(
            1, heldAfter.size,
            "a versioned reopen LOST the held frame the store exists to keep (GS-STORE-003)",
        )
        assertEquals(32, heldAfter[0].payload.size, "the signed bytes must survive byte for byte")
        db2.close()
        assertEquals(
            StoreSchema.DB_VERSION, userVersion(),
            "the migrated file is stamped at the current revision",
        )
    }

    /** W05 -- THE NEGATIVE: a drifted older schema is refused, nothing deleted, nothing re-stamped. */
    @Test
    fun `W05 a drifting older schema is refused without deleting or re-stamping`() = runBlocking {
        val db1 = JdbcStoreDb(tmp)
        val store1 = SqliteMessageStore(db1, Long.MAX_VALUE)
        val mid = msgId(71)
        store1.persist(frame(mid, 24), ByteArray(0))
        // Tamper INTO a drifted older file: ack_frames recreated WITHOUT its CHECKs.
        direct().use { c ->
            c.createStatement().use { it.execute("DROP TABLE IF EXISTS ${StoreSchema.ACK_FRAME_TABLE}") }
            c.createStatement().use {
                it.execute(
                    "CREATE TABLE ${StoreSchema.ACK_FRAME_TABLE} (" +
                        "${StoreSchema.COL_K_ACK_KEY} BLOB PRIMARY KEY, ${StoreSchema.COL_K_MSG_ID} BLOB)",
                )
            }
        }
        stamp(4)
        db1.close()
        assertFailsWith<Throwable>(
            "a drifted older schema must be refused fail-closed, not recreated (GS-STORE-003)",
        ) { JdbcStoreDb(tmp).close() }
        assertEquals(4, userVersion(), "a refused file must NOT be re-stamped to the current revision")
        assertEquals(
            1, count("SELECT COUNT(*) FROM ${StoreSchema.TABLE}"),
            "a refused file must NOT lose its durable rows",
        )
    }

    /** W06 -- THE POSITIVE CONTROL: a brand-new file still creates all four tables at DB_VERSION. */
    @Test
    fun `W06 a brand new file is created at the current revision`() = runBlocking {
        val db = JdbcStoreDb(tmp)
        val store = SqliteMessageStore(db, Long.MAX_VALUE)
        store.persist(frame(msgId(72), 16), ByteArray(0))
        db.close()
        for (table in listOf(
            StoreSchema.TABLE, StoreSchema.DELIVERY_TABLE,
            StoreSchema.ACK_OBLIGATION_TABLE, StoreSchema.ACK_FRAME_TABLE,
        )) {
            assertEquals(1, count("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = '$table'"),
                "a brand-new file must create $table")
        }
        assertEquals(StoreSchema.DB_VERSION, userVersion(), "a brand-new file is stamped at the current revision")
    }

    // ---- the digest the migration executor reports over the immutable domain ----

    /**
     * W07 -- the immutable-cell digest must report REAL bytes: it is stable, independent of
     * row order, it CHANGES when a cell changes, and it does not confuse a NULL with an empty
     * blob. A constant (or a digest taken over the frozen DEFINITION rather than the file)
     * satisfies none of these. The fold is pure stdlib, so it is witnessed on the host; the
     * production binding supplies the rows it reads from the live file.
     */
    @Test
    fun `W07 the immutable digest fold reads real bytes`() {
        val rows = listOf(listOf(byteArrayOf(1, 2), byteArrayOf(3)), listOf(byteArrayOf(4)))
        val a = immutableDigestOf(mapOf(StoreSchema.TABLE to rows))
        assertEquals(a, immutableDigestOf(mapOf(StoreSchema.TABLE to rows)), "the digest must be stable")
        assertEquals(
            a, immutableDigestOf(mapOf(StoreSchema.TABLE to rows.reversed())),
            "the fold is order-independent: a row order change must not move the digest",
        )
        assertNotEquals(
            a, immutableDigestOf(mapOf(StoreSchema.TABLE to listOf(listOf(byteArrayOf(1, 3), byteArrayOf(3)), listOf(byteArrayOf(4))))),
            "the digest must CHANGE when an immutable cell changes (else it is a constant)",
        )
        assertNotEquals(
            immutableDigestOf(mapOf(StoreSchema.TABLE to listOf(listOf<ByteArray?>(null)))),
            immutableDigestOf(mapOf(StoreSchema.TABLE to listOf(listOf<ByteArray?>(ByteArray(0))))),
            "a NULL must not collide with an empty blob",
        )
    }

    // ---- helpers ----

    private fun msgId(seed: Byte): ByteArray = ByteArray(16) { (it + seed).toByte() }

    private fun frame(mid: ByteArray, payloadSize: Int): FrameV2 = FrameV2(
        type = TypeV2.MESSAGE,
        msgId = mid,
        routingTag = ByteArray(4),
        ttl = 12,
        hopCount = 0,
        flags = Priority.toFlags(Priority.DIRECT),
        payload = ByteArray(payloadSize) { 0x5A },
    )

    /** Stamp `PRAGMA user_version` through a SEPARATE connection (the store is idle/closed). */
    private fun stamp(version: Int) {
        direct().use { c -> c.createStatement().use { it.execute("PRAGMA user_version = $version") } }
    }

    private fun userVersion(): Int = count("PRAGMA user_version")

    private fun count(sql: String): Int = direct().use { c ->
        c.createStatement().use { st ->
            st.executeQuery(sql).use { rs -> if (rs.next()) rs.getInt(1) else -1 }
        }
    }

    private fun direct() = DriverManager.getConnection("jdbc:sqlite:" + tmp.absolutePath)

    private fun repoRoot(): File {
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        var hops = 0
        while (dir != null && hops < 8) {
            if (File(dir, "android").isDirectory) return dir
            dir = dir.parentFile
            hops++
        }
        error("repo root not found from ${System.getProperty("user.dir")}")
    }

    private fun storeSource(): String =
        File(repoRoot(), "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt").readText()

    /** Strip line prose so a source arm reads CODE, never a comment quoting the very token it forbids. */
    private fun stripProse(text: String): String =
        text.lineSequence().map { it.substringBefore("//").substringBefore("/*") }.joinToString("\n")

    /** The body of the production upgrade method, from its declaration to the next top-level brace. */
    private fun upgradeBody(source: String): String {
        val header = "override fun onUpgrade("
        val start = source.indexOf(header)
        check(start >= 0) {
            "the versioned upgrade method is not called onUpgrade(…) any more: re-point this arm at " +
                "its new name rather than skipping (GS-STORE-003)"
        }
        var depth = 0
        var seenBrace = false
        val body = StringBuilder()
        for (ch in source.substring(start)) {
            if (ch == '{') { depth++; seenBrace = true }
            if (ch == '}') depth--
            body.append(ch)
            if (seenBrace && depth == 0) break
        }
        return body.toString()
    }
}
