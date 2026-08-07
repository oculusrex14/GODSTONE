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
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Android durable message store -- bounded capacity + real-SQL invariants
 * (ADR-004 §1,3,4,5,6; Stage 3 Phase E).
 *
 * These tests drive the REAL [SqliteMessageStore] logic against a REAL on-disk
 * SQLite engine ([JdbcStoreDb], backed by sqlite-jdbc's bundled native SQLite).
 * The SQL the store runs -- schema, INSERT OR IGNORE, the window-function
 * eviction, SUM(LENGTH(payload)) byte accounting, priority ORDER BY -- is shared
 * with the production SQLCipher engine via [StoreSchema], so the invariants
 * proven here are the invariants production enforces. (At-rest encryption is a
 * device concern; the SQLCipher engine itself is pinned structurally in
 * [StoreEngineTest].)
 *
 * Every assertion is deterministic. received_at is injected through `persistAt`
 * so eviction oldest-first and priority tie-breaks do not race the wall clock.
 */
class SqliteMessageStoreTest {

    private lateinit var tmp: File
    private var engine: JdbcStoreDb? = null
    private lateinit var store: SqliteMessageStore

    /** Open a fresh real-SQLite store against a temp file with a [maxBytes] cap. */
    private fun open(maxBytes: Long): SqliteMessageStore {
        val db = JdbcStoreDb(tmp)
        engine = db
        store = SqliteMessageStore(db, maxBytes)
        return store
    }

    @Before
    fun setUp() {
        tmp = Files.createTempFile("godstone-store-test", ".db").toFile()
    }

    @After
    fun tearDown() {
        engine?.runCatching { close() }
        tmp.delete()
    }

    private fun msgId(seed: Byte): ByteArray = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }

    /** A frame with [priority] (encoded into flags bits 8..10) and a [payloadSize]-byte payload. */
    private fun frame(
        seed: Byte,
        priority: Priority,
        payloadSize: Int,
        type: TypeV2 = TypeV2.MESSAGE,
    ): FrameV2 = FrameV2(
        type = type,
        msgId = msgId(seed),
        routingTag = routingTag,
        ttl = 12,
        hopCount = 0,
        flags = Priority.toFlags(priority),
        payload = ByteArray(payloadSize) { seed },
    )

    private fun heldIds(): List<ByteArray> = runBlocking { store.allHeldMsgIds() }
    private fun held(): List<FrameV2> = runBlocking { store.allHeldOrderedByPriority() }
    private fun bytes(): Long = store.heldBytes()
    private fun heldPriorities(): List<Priority> = held().map { Priority.fromFlags(it.flags) }

    private fun ByteArray.eq(other: ByteArray): Boolean = this.contentEquals(other)
    private fun List<ByteArray>.containsId(id: ByteArray): Boolean = any { it.eq(id) }

    // --- ADR-004 §1: persist + read-back preserves a frame and its fields ---

    @Test
    fun `persist then read back preserves all fields`() = runBlocking {
        open(Long.MAX_VALUE)
        val f = frame(7, Priority.DIRECT, payloadSize = 64, type = TypeV2.SOS)
        store.persist(f, ByteArray(6) { it.toByte() })
        val out = store.allHeldOrderedByPriority()
        assertEquals(1, out.size)
        val r = out[0]
        assertEquals(f.type, r.type)
        assertTrue(f.msgId.eq(r.msgId))
        assertTrue(f.routingTag.eq(r.routingTag))
        assertEquals(f.ttl, r.ttl)
        assertEquals(f.hopCount, r.hopCount)
        assertEquals(f.flags, r.flags)
        assertTrue(f.payload.eq(r.payload))
    }

    // --- dedup: duplicate msg_id is ignored (INSERT OR IGNORE / CONFLICT_IGNORE) ---

    @Test
    fun `duplicate msg_id is ignored`() = runBlocking {
        open(Long.MAX_VALUE)
        val f = frame(1, Priority.GROUP, payloadSize = 32)
        store.persist(f, ByteArray(0))
        store.persist(f, ByteArray(0))
        assertEquals(1, heldIds().size)
    }

    // --- ordering: SOS first, then priority asc, recency desc on ties ---

    @Test
    fun `priority order is SOS first then ascending with recency tie-break`() = runBlocking {
        open(Long.MAX_VALUE)
        // received_at injected so ties are deterministic: GROUP@t=300, GROUP@t=100
        // (newer-received first within a priority), DIRECT@t=200, SOS@t=50.
        store.persistAt(frame(1, Priority.GROUP, 8), ByteArray(0), receivedAt = 300L)
        store.persistAt(frame(2, Priority.GROUP, 8), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(3, Priority.DIRECT, 8), ByteArray(0), receivedAt = 200L)
        store.persistAt(frame(4, Priority.SOS, 8), ByteArray(0), receivedAt = 50L)
        // Expected: SOS(4), DIRECT(3), GROUP newer-first -> frame(1)@300 then frame(2)@100
        assertEquals(
            listOf(Priority.SOS, Priority.DIRECT, Priority.GROUP, Priority.GROUP),
            heldPriorities(),
        )
        // The ordered frame list's msg_ids confirm the recency tie-break within
        // GROUP (newer-received frame(1)@300 before frame(2)@100). ByteArray is
        // reference-equal, so compare via List<Byte> (content-based). Note
        // allHeldMsgIds() is intentionally unordered (bloom-digest construction),
        // so the order is asserted through the ordered list, not through it.
        assertEquals(
            listOf(msgId(4), msgId(3), msgId(1), msgId(2)).map { it.toList() },
            held().map { it.msgId.toList() },
        )
    }

    // --- ADR-004 §4 / A-14: eviction only when over budget ---

    @Test
    fun `eviction does not run while under budget`() = runBlocking {
        // Cap generous enough that three small frames stay well under it.
        open(maxBytes = 4096L)
        store.persistAt(frame(1, Priority.GROUP, 64), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.GROUP, 64), ByteArray(0), receivedAt = 200L)
        store.persistAt(frame(3, Priority.GROUP, 64), ByteArray(0), receivedAt = 300L)
        assertEquals(3, heldIds().size)
        assertTrue(bytes() <= 4096L)
    }

    // --- ADR-004 §4: bounded capacity evicts oldest non-SOS first (precise) ---

    @Test
    fun `bounded capacity evicts oldest non-SOS first and returns under the cap`() = runBlocking {
        // Each frame: 400-byte payload + 64-byte overhead = 464 bytes. Cap = 1024.
        // Two frames (928) fit; the third (1392) overshoots by 368, so the oldest
        // non-SOS frame (frame(1), 464 >= 368) is deleted -> 928 bytes, under cap.
        open(maxBytes = 1024L)
        store.persistAt(frame(1, Priority.GROUP, 400), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.GROUP, 400), ByteArray(0), receivedAt = 200L)
        assertTrue(bytes() <= 1024L)
        store.persistAt(frame(3, Priority.GROUP, 400), ByteArray(0), receivedAt = 300L)
        // Precise byte accounting: the store is at or under the cap after eviction.
        assertTrue(bytes() <= 1024L, "over cap after eviction: ${bytes()}")
        // The oldest non-SOS frame was evicted; the two newest survive.
        val ids = heldIds()
        assertFalse(ids.containsId(msgId(1)), "oldest non-SOS should be evicted")
        assertTrue(ids.containsId(msgId(2)))
        assertTrue(ids.containsId(msgId(3)))
        assertEquals(2, ids.size)
    }

    @Test
    fun `precise eviction deletes the smallest prefix that meets the overshoot`() = runBlocking {
        // Cap = 1024. Insert one large non-SOS frame (payload 800 -> 864) then a
        // small one (payload 100 -> 164): total 1028, overshoot = 4 bytes. The
        // oldest non-SOS prefix whose cumulative cost >= 4 is just frame(1)
        // (864 >= 4), so ONLY the large old frame is deleted -- not both. The
        // approximate row-count form could over-delete; the precise form does not.
        open(maxBytes = 1024L)
        store.persistAt(frame(1, Priority.GROUP, 800), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.BROADCAST, 100), ByteArray(0), receivedAt = 200L)
        assertTrue(bytes() <= 1024L, "over cap: ${bytes()}")
        val ids = heldIds()
        assertFalse(ids.containsId(msgId(1)))
        assertTrue(ids.containsId(msgId(2)))
        assertEquals(1, ids.size)
    }

    // --- ADR-004 §4: SOS retained under budget pressure (never evicted) ---

    @Test
    fun `SOS frames are retained even when they are the oldest rows`() = runBlocking {
        // Cap = 1024. SOS@t=50 (464), non-SOS X@t=100 (464), non-SOS Y@t=200 (464)
        // -> 1392, overshoot 368. Oldest non-SOS is X (464 >= 368) -> deleted.
        // SOS, though oldest overall, is never considered -> retained.
        open(maxBytes = 1024L)
        store.persistAt(frame(1, Priority.SOS, 400), ByteArray(0), receivedAt = 50L)
        store.persistAt(frame(2, Priority.GROUP, 400), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(3, Priority.GROUP, 400), ByteArray(0), receivedAt = 200L)
        val ids = heldIds()
        assertTrue(ids.containsId(msgId(1)), "SOS must be retained")
        assertFalse(ids.containsId(msgId(2)), "oldest non-SOS evicted")
        assertTrue(ids.containsId(msgId(3)))
    }

    @Test
    fun `all-SOS flooding stays inside the hard cap -- SOS evicted last, newest retained`() = runBlocking {
        // ADR-004 criterion 4: "All-SOS flooding remains inside the configured
        // hard cap." Cap = 512; each SOS frame is 464 bytes.
        //  - after 2nd SOS: 928 > 512, overshoot 416 -> evict oldest SOS (frame1)
        //    -> 464 (frame2), under cap.
        //  - after 3rd SOS: 928 > 512, overshoot 416 -> evict oldest SOS (frame2)
        //    -> 464 (frame3), under cap.
        // SOS is evicted LAST (only because there is no non-SOS to evict), and
        // the bounded FIFO keeps the NEWEST SOS -- it never lets the backlog
        // grow past the cap.
        open(maxBytes = 512L)
        store.persistAt(frame(1, Priority.SOS, 400), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.SOS, 400), ByteArray(0), receivedAt = 200L)
        store.persistAt(frame(3, Priority.SOS, 400), ByteArray(0), receivedAt = 300L)
        assertTrue(bytes() <= 512L, "all-SOS flooding must stay inside the cap: ${bytes()}")
        val ids = heldIds()
        assertEquals(1, ids.size, "only the newest SOS is retained under all-SOS pressure")
        assertTrue(ids.containsId(msgId(3)), "newest SOS retained")
        assertFalse(ids.containsId(msgId(1)), "oldest SOS evicted")
        assertTrue(heldPriorities().all { it == Priority.SOS })
    }

    // --- A-13: streaming stops as soon as visit returns false ---

    @Test
    fun `forEachHeldOrderedByPriority stops when visit returns false`() = runBlocking {
        open(Long.MAX_VALUE)
        store.persistAt(frame(1, Priority.SOS, 8), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.DIRECT, 8), ByteArray(0), receivedAt = 200L)
        store.persistAt(frame(3, Priority.GROUP, 8), ByteArray(0), receivedAt = 300L)
        var seen = 0
        store.forEachHeldOrderedByPriority {
            seen++
            false   // stop after the first (SOS, highest priority)
        }
        assertEquals(1, seen)
    }

    @Test
    fun `forEachHeldMsgId streams all ids while visit returns true`() = runBlocking {
        open(Long.MAX_VALUE)
        store.persistAt(frame(1, Priority.GROUP, 8), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.GROUP, 8), ByteArray(0), receivedAt = 200L)
        val seen = ArrayList<ByteArray>()
        store.forEachHeldMsgId { seen.add(it); true }
        assertEquals(2, seen.size)
    }

    // --- forward-compat: rows with an unknown type code are skipped, not crashed ---

    @Test
    fun `rows with an unknown type code are skipped not thrown`() = runBlocking {
        // Pre-seed the file with a row whose type code (0x77) is not a known
        // TypeV2 via a direct JDBC connection, then open the store over it. The
        // store must skip the row when listing frames (toFrame() -> null) but
        // still report its msg_id (allHeldMsgIds does not type-check).
        val direct = DriverManager.getConnection("jdbc:sqlite:" + tmp.absolutePath)
        direct.createStatement().use { it.execute(StoreSchema.CREATE_SQL_IF_NOT_EXISTS) }
        direct.prepareStatement(
            "INSERT INTO ${StoreSchema.TABLE} (" +
                "${StoreSchema.COL_MSG_ID}, ${StoreSchema.COL_TYPE}, ${StoreSchema.COL_TTL}, " +
                "${StoreSchema.COL_HOP_COUNT}, ${StoreSchema.COL_FLAGS}, ${StoreSchema.COL_PRIORITY}, " +
                "${StoreSchema.COL_ROUTING_TAG}, ${StoreSchema.COL_PAYLOAD}, " +
                "${StoreSchema.COL_RECEIVED_FROM}, ${StoreSchema.COL_RECEIVED_AT}) VALUES (?,?,?,?,?,?,?,?,?,?)"
        ).use { ps ->
            ps.setBytes(1, msgId(9))
            ps.setInt(2, 0x77)   // not a TypeV2
            ps.setInt(3, 12)
            ps.setInt(4, 0)
            ps.setInt(5, Priority.toFlags(Priority.GROUP))
            ps.setInt(6, Priority.GROUP.code)
            ps.setBytes(7, routingTag)
            ps.setBytes(8, ByteArray(8))
            ps.setBytes(9, ByteArray(0))
            ps.setLong(10, 100L)
            ps.executeUpdate()
        }
        direct.close()
        open(Long.MAX_VALUE)   // reopens the existing file (IF NOT EXISTS = no-op)
        assertEquals(0, store.allHeldOrderedByPriority().size, "unknown-type row skipped")
        assertEquals(1, store.allHeldMsgIds().size, "msg_id still reported")
    }
}