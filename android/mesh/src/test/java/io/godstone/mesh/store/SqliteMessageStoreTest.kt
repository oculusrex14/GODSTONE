package io.godstone.mesh.store

import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.SqliteDeliveryRepository
import io.godstone.mesh.delivery.TransitionResult
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
import kotlin.test.assertNotNull
import kotlin.test.assertNull
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
    private fun open(maxBytes: Long): SqliteMessageStore = open(maxBytes, faultInjector = null)

    /**
     * Open a store with a B3 fault-injection seam. The [faultInjector] is invoked
     * between the insert/evict/contains phases of the persist transaction;
     * throwing from it aborts the transaction (ROLLBACK) and yields
     * `FAILED_STORAGE`, proving the store reopens in a valid, bounded state.
     */
    private fun open(maxBytes: Long, faultInjector: ((String) -> Unit)? = null): SqliteMessageStore {
        val db = JdbcStoreDb(tmp)
        engine = db
        store = SqliteMessageStore(db, maxBytes, faultInjector)
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
        //
        // C6.4.1-BCDEFG: the JDBC engine now runs version + DDL-fingerprint
        // validation on open. A fresh file (user_version=0) would be
        // drop+recreated, destroying the seed. So the seed stamps the CURRENT
        // version and creates ALL FOUR tables (validateSchema checks all four
        // DDL fingerprints), making the open a current-version validate path that
        // preserves the seeded bad-type row.
        val direct = DriverManager.getConnection("jdbc:sqlite:" + tmp.absolutePath)
        direct.createStatement().use { it.execute(StoreSchema.CREATE_SQL) }
        direct.createStatement().use { it.execute(StoreSchema.CREATE_DELIVERY_SQL) }
        direct.createStatement().use { it.execute(StoreSchema.CREATE_OBLIGATION_SQL) }
        direct.createStatement().use { it.execute(StoreSchema.CREATE_ACK_FRAME_SQL) }
        direct.createStatement().use { it.execute("PRAGMA user_version = ${StoreSchema.DB_VERSION}") }
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

    // --- Stage 4B.1 / B2: persist means HELD AFTER cap enforcement ---

    @Test
    fun `ordinary frame evicted under all-SOS pressure reports REJECTED_CAPACITY and is absent`() = runBlocking {
        // Fill the store to the cap with SOS frames. An incoming ORDINARY frame is
        // the first eviction candidate (non-SOS evicted before SOS), so it is
        // inserted then immediately evicted: persist MUST report
        // REJECTED_CAPACITY (NOT HELD_NEW), the row MUST be absent, and the cap
        // MUST remain satisfied. The router must not forward/emit a frame it does
        // not durably hold -- the truthful REJECTED_CAPACITY result is what lets
        // the router refuse to relay without poisoning retry (B1).
        open(maxBytes = 512L)
        // One SOS frame is 464 bytes (400 payload + 64 overhead) -> under the 512 cap.
        store.persistAt(frame(1, Priority.SOS, 400), ByteArray(0), receivedAt = 100L)
        assertTrue(bytes() <= 512L)
        // An ordinary (GROUP) frame: inserted, overshoots, evicted first (non-SOS).
        val result = store.persistAt(frame(2, Priority.GROUP, 400), ByteArray(0), receivedAt = 200L)
        assertEquals(PersistResult.REJECTED_CAPACITY, result)
        val ids = heldIds()
        assertFalse(ids.containsId(msgId(2)), "evicted ordinary frame must be absent")
        assertTrue(ids.containsId(msgId(1)), "SOS retained under pressure")
        assertTrue(bytes() <= 512L, "cap still satisfied after rejected persist")
    }

    @Test
    fun `new SOS under all-SOS pressure keeps cap satisfied and newest SOS retained with truthful result`() = runBlocking {
        // B2: "new SOS under all-SOS pressure, hard cap remains satisfied, newest
        // SOS retention deterministic, persist result exactly matches final row
        // presence." Cap = 512; each SOS is 464 bytes. Each new SOS overshoots and
        // evicts the oldest SOS, so the NEWEST is always retained and the cap holds.
        // The persist result MUST match `contains`: HELD_NEW when present & new,
        // HELD_DUPLICATE when present & already held, REJECTED_CAPACITY when absent.
        open(maxBytes = 512L)
        // frame1 SOS: alone, under cap -> HELD_NEW, present.
        assertEquals(PersistResult.HELD_NEW,
            store.persistAt(frame(1, Priority.SOS, 400), ByteArray(0), receivedAt = 100L))
        // frame2 SOS: 928 > 512 -> evict oldest SOS (frame1) -> frame2 HELD_NEW.
        assertEquals(PersistResult.HELD_NEW,
            store.persistAt(frame(2, Priority.SOS, 400), ByteArray(0), receivedAt = 200L))
        // frame3 SOS: 928 > 512 -> evict oldest SOS (frame2) -> frame3 HELD_NEW.
        assertEquals(PersistResult.HELD_NEW,
            store.persistAt(frame(3, Priority.SOS, 400), ByteArray(0), receivedAt = 300L))
        assertTrue(bytes() <= 512L, "all-SOS pressure stays inside the cap: ${bytes()}")
        val ids = heldIds()
        assertEquals(1, ids.size)
        assertTrue(ids.containsId(msgId(3)), "newest SOS retained deterministically")
        assertFalse(ids.containsId(msgId(2)))

        // "persist result exactly matches final row presence":
        //  (a) re-offer the HELD frame3 -> row exists -> HELD_DUPLICATE, present.
        assertEquals(PersistResult.HELD_DUPLICATE,
            store.persistAt(frame(3, Priority.SOS, 400), ByteArray(0), receivedAt = 400L))
        assertTrue(heldIds().containsId(msgId(3)))
        //  (b) re-offer the evicted frame2 as the OLDEST (t=50) -> re-inserted then
        //      evicted (oldest SOS under all-SOS pressure) -> REJECTED_CAPACITY, absent.
        assertEquals(PersistResult.REJECTED_CAPACITY,
            store.persistAt(frame(2, Priority.SOS, 400), ByteArray(0), receivedAt = 50L))
        assertFalse(heldIds().containsId(msgId(2)), "evicted frame absent -- result matches presence")
        assertTrue(heldIds().containsId(msgId(3)), "newest SOS still retained")
    }

    @Test
    fun `capacity-rejected frame may be retried later after room is freed - dedup window not poisoned`() = runBlocking {
        // B1+B2 interaction: a REJECTED_CAPACITY persist must NOT permanently mark
        // the id seen/deduped. After room is freed (simulating delivery/age-out of a
        // held SOS), the SAME ordinary msg_id MUST be accepted as HELD_NEW. This is
        // the store-boundary half of "the same frame may be retried later".
        open(maxBytes = 512L)
        store.persistAt(frame(1, Priority.SOS, 400), ByteArray(0), receivedAt = 100L)
        // Ordinary frame evicted under SOS pressure -> REJECTED_CAPACITY.
        val ordinary = frame(2, Priority.GROUP, 400)
        assertEquals(PersistResult.REJECTED_CAPACITY,
            store.persistAt(ordinary, ByteArray(0), receivedAt = 200L))
        assertFalse(heldIds().containsId(msgId(2)))
        // Free room: delete the SOS directly via a side JDBC connection
        // (simulates authenticated-ACK delivery deleting a held frame, which is
        // the production path that makes room). The store engine and this side
        // connection see the same on-disk file.
        engine?.close()
        engine = null
        val direct = DriverManager.getConnection("jdbc:sqlite:" + tmp.absolutePath)
        direct.prepareStatement(
            "DELETE FROM ${StoreSchema.TABLE} WHERE ${StoreSchema.COL_MSG_ID} = ?"
        ).use { it.setBytes(1, msgId(1)); it.executeUpdate() }
        direct.close()
        open(maxBytes = 512L)   // reopen over the mutated file
        assertTrue(bytes() <= 512L)
        // Retry the SAME ordinary msg_id: now there is room -> HELD_NEW, present.
        assertEquals(PersistResult.HELD_NEW,
            store.persistAt(ordinary, ByteArray(0), receivedAt = 300L))
        assertTrue(heldIds().containsId(msgId(2)), "retried frame accepted after room freed")
    }

    // --- Stage 4B.1 / B3: insert + eviction + final-held check is atomic ---

    @Test
    fun `fault after insert rolls back the transaction and leaves a valid bounded store`() = runBlocking {
        // B3: a fault between insert and eviction must ROLL BACK the whole
        // transaction (the inserted row is NOT committed), persist reports
        // FAILED_STORAGE, and the store reopens in a valid, bounded state (the
        // pre-fault rows are intact, the faulted row is gone, byte total is
        // unchanged from before the faulted persist).
        open(maxBytes = 1024L)
        store.persistAt(frame(1, Priority.GROUP, 100), ByteArray(0), receivedAt = 100L)
        val bytesBefore = bytes()
        val rowsBefore = heldIds().size

        val fault = { phase: String ->
            if (phase == "after_insert") throw java.sql.SQLException("injected fault after insert")
        }
        val result = store.persistAtWithFault(frame(2, Priority.GROUP, 100), ByteArray(0), receivedAt = 200L, fault)
        assertEquals(PersistResult.FAILED_STORAGE, result)
        // The faulted insert was rolled back: byte total + row count unchanged.
        assertEquals(bytesBefore, bytes(), "faulted insert rolled back -- byte total unchanged")
        assertEquals(rowsBefore, heldIds().size, "faulted insert rolled back -- row count unchanged")
        assertFalse(heldIds().containsId(msgId(2)), "faulted row absent")

        // Reopen the store over the same file: the on-disk state is valid + bounded.
        engine?.close()
        engine = null
        open(maxBytes = 1024L)
        assertEquals(rowsBefore, heldIds().size, "store reopens valid after fault")
        assertTrue(bytes() <= 1024L, "store reopens bounded after fault")
        assertTrue(heldIds().containsId(msgId(1)), "pre-fault row survives reopen")
    }

    @Test
    fun `fault after eviction rolls back and the evicted rows are restored`() = runBlocking {
        // B3: a fault AFTER eviction (but before the final-contains check / commit)
        // rolls back the ENTIRE transaction -- the rows the eviction deleted are
        // RESTORED and the inserted row is gone. This is the guarantee that a
        // mid-transaction fault never leaves the store in a half-evicted state.
        open(maxBytes = 1024L)
        store.persistAt(frame(1, Priority.GROUP, 400), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.GROUP, 400), ByteArray(0), receivedAt = 200L)
        val bytesBefore = bytes()
        val rowsBefore = heldIds().size

        val fault = { phase: String ->
            if (phase == "after_evict") throw java.sql.SQLException("injected fault after evict")
        }
        // A third 400-byte frame overshoots (928 -> 1392 > 1024) and triggers
        // eviction; the fault fires after eviction, before commit -> ROLLBACK.
        val result = store.persistAtWithFault(frame(3, Priority.GROUP, 400), ByteArray(0), receivedAt = 300L, fault)
        assertEquals(PersistResult.FAILED_STORAGE, result)
        // Everything rolled back: both pre-existing rows restored, new row gone,
        // byte total identical to before the faulted persist.
        assertEquals(bytesBefore, bytes(), "evicted rows restored after rollback")
        assertEquals(rowsBefore, heldIds().size, "row count restored after rollback")
        assertTrue(heldIds().containsId(msgId(1)))
        assertTrue(heldIds().containsId(msgId(2)))
        assertFalse(heldIds().containsId(msgId(3)))
    }

    @Test
    fun `fault before contains rolls back and reopens valid`() = runBlocking {
        // B3: the final-contains check is the last phase; faulting just before it
        // still rolls back the whole transaction (insert + any eviction), proving
        // the atomic boundary wraps the entire insert/evict/contains sequence.
        open(maxBytes = 2048L)
        store.persistAt(frame(1, Priority.GROUP, 100), ByteArray(0), receivedAt = 100L)
        val bytesBefore = bytes()

        val fault = { phase: String ->
            if (phase == "before_contains") throw java.sql.SQLException("injected fault before contains")
        }
        val result = store.persistAtWithFault(frame(2, Priority.GROUP, 100), ByteArray(0), receivedAt = 200L, fault)
        assertEquals(PersistResult.FAILED_STORAGE, result)
        assertEquals(bytesBefore, bytes(), "rolled back to pre-fault byte total")
        assertFalse(heldIds().containsId(msgId(2)))
        // Reopen valid.
        engine?.close(); engine = null
        open(maxBytes = 2048L)
        assertTrue(heldIds().containsId(msgId(1)))
        assertEquals(1, heldIds().size)
    }

    // --- C6.6: Atomic outbound DIRECT enqueue real-SQL tests ---

    private fun recipient(seed: Byte = 0x55): ByteArray = ByteArray(16) { (it + seed).toByte() }

    private fun directFrame(
        seed: Byte,
        payloadSize: Int = 64,
        type: TypeV2 = TypeV2.MESSAGE,
        priority: Priority = Priority.DIRECT,
        sealed: Boolean = true,
        hasPow: Boolean = false,
        msgIdOverride: ByteArray? = null,
    ): FrameV2 {
        var flags = (priority.code shl 8)
        if (sealed) flags = flags or FrameV2.SEALED
        if (hasPow) flags = flags or FrameV2.HAS_POW
        return FrameV2(
            type = type,
            msgId = msgIdOverride ?: msgId(seed),
            routingTag = routingTag,
            ttl = 12,
            hopCount = 0,
            flags = flags,
            payload = ByteArray(payloadSize) { seed },
        )
    }

    private fun readDelivery(mid: ByteArray): DeliveryRow? = engine?.readDelivery(mid)

    private fun localNode(seed: Byte = 0x10): ByteArray = ByteArray(16) { (seed.toInt() + it).toByte() }

    @Test
    fun `C6_6 enqueueDirectOutbound happy path atomically creates held frame and QUEUED_DURABLY single-recipient delivery row`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val result = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), result)

        // Verifies both tables have the committed state
        assertTrue(heldIds().containsId(f.msgId), "frame must be present in held_frames")
        val d = readDelivery(f.msgId)
        org.junit.Assert.assertNotNull("delivery row must exist in delivery_state", d)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, d!!.state)
        assertEquals(io.godstone.mesh.delivery.AckMode.SINGLE_RECIPIENT.code, d.ackMode)
        assertTrue(rec.contentEquals(d.expectedRecipient), "expected recipient must match")

        val heldRow = engine?.readHeld(f.msgId)
        assertNotNull(heldRow)
        assertTrue(origin.contentEquals(heldRow!!.receivedFrom), "received_from must match localOriginNodeId")
    }

    @Test
    fun `C6_6 enqueueDirectOutbound fault after held insert rolls back both held and delivery rows`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val fault: ((String) -> Unit) = { phase: String ->
            if (phase == "after_held_insert") throw java.sql.SQLException("injected fault after held insert")
        }
        val result = store.enqueueDirectOutboundAtWithFault(f, rec, localOriginNodeId = origin, receivedAt = 100L, fault = fault)
        assertEquals(OutboundEnqueueResult.StorageFailure, result)

        // Full rollback: 0 held rows, 0 delivery rows
        assertFalse(heldIds().containsId(f.msgId), "held frame must be rolled back")
        assertNull(readDelivery(f.msgId), "delivery row must be rolled back")
        assertEquals(0, heldIds().size)
    }

    @Test
    fun `C6_6 enqueueDirectOutbound fault after evict rolls back and restores evicted rows`() = runBlocking {
        // Pre-fill store with 2 frames
        open(maxBytes = 1024L)
        store.persistAt(frame(1, Priority.GROUP, 400), ByteArray(0), receivedAt = 100L)
        store.persistAt(frame(2, Priority.GROUP, 400), ByteArray(0), receivedAt = 200L)
        val bytesBefore = bytes()

        val f = directFrame(3, payloadSize = 400)
        val rec = recipient(3)
        val origin = localNode(1)

        val fault: ((String) -> Unit) = { phase: String ->
            if (phase == "after_evict") throw java.sql.SQLException("injected fault after evict")
        }
        val result = store.enqueueDirectOutboundAtWithFault(f, rec, localOriginNodeId = origin, receivedAt = 300L, fault = fault)
        assertEquals(OutboundEnqueueResult.StorageFailure, result)

        // Rollback restores evicted rows and creates no new held or delivery rows
        assertEquals(bytesBefore, bytes(), "evicted rows must be restored after rollback")
        assertEquals(2, heldIds().size)
        assertTrue(heldIds().containsId(msgId(1)))
        assertTrue(heldIds().containsId(msgId(2)))
        assertFalse(heldIds().containsId(f.msgId))
        assertNull(readDelivery(f.msgId))
    }

    @Test
    fun `C6_6 enqueueDirectOutbound fault before delivery insert rolls back held insert`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val fault: ((String) -> Unit) = { phase: String ->
            if (phase == "before_delivery_insert") throw java.sql.SQLException("injected fault before delivery insert")
        }
        val result = store.enqueueDirectOutboundAtWithFault(f, rec, localOriginNodeId = origin, receivedAt = 100L, fault = fault)
        assertEquals(OutboundEnqueueResult.StorageFailure, result)

        assertFalse(heldIds().containsId(f.msgId))
        assertNull(readDelivery(f.msgId))
    }

    @Test
    fun `C6_6 enqueueDirectOutbound fault after delivery insert rolls back whole transaction`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val fault: ((String) -> Unit) = { phase: String ->
            if (phase == "after_delivery_insert") throw java.sql.SQLException("injected fault after delivery insert")
        }
        val result = store.enqueueDirectOutboundAtWithFault(f, rec, localOriginNodeId = origin, receivedAt = 100L, fault = fault)
        assertEquals(OutboundEnqueueResult.StorageFailure, result)

        assertFalse(heldIds().containsId(f.msgId))
        assertNull(readDelivery(f.msgId))
    }

    @Test
    fun `C6_6 enqueueDirectOutbound under tight capacity rejects and leaves zero delivery and zero held rows`() = runBlocking {
        // Cap is 200 bytes. Seed with 250 bytes frame (too big to survive).
        open(maxBytes = 200L)
        val f = directFrame(1, payloadSize = 250)
        val rec = recipient(1)
        val origin = localNode(1)

        val result = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.RejectedCapacity, result)

        // Neither held frame nor delivery record exists
        assertFalse(heldIds().containsId(f.msgId))
        assertNull(readDelivery(f.msgId))
        assertEquals(0, heldIds().size)
    }

    @Test
    fun `C6_6 enqueueDirectOutbound same exact retry is idempotent and returns AlreadyQueuedSameBinding`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        val f2 = FrameV2(
            f.type,
            f.msgId.copyOf(),
            f.routingTag.copyOf(),
            f.ttl,
            f.hopCount,
            f.flags,
            f.payload.copyOf(),
        )
        val r2 = store.enqueueDirectOutbound(f2, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.AlreadyQueuedSameBinding(f), r2)

        assertEquals(1, heldIds().size)
        val d = readDelivery(f.msgId)
        org.junit.Assert.assertNotNull(d)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, d!!.state)
        assertTrue(rec.contentEquals(d.expectedRecipient))
    }

    @Test
    fun `C6_6_1 enqueueDirectOutbound same msgId different payload fails closed with CanonicalFrameMismatch`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        val fDiffPayload = FrameV2(f.type, f.msgId, f.routingTag, f.ttl, f.hopCount, f.flags, ByteArray(120) { 0x55 })
        val r2 = store.enqueueDirectOutbound(fDiffPayload, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.CanonicalFrameMismatch, r2)

        val heldRow = engine?.readHeld(f.msgId)
        assertNotNull(heldRow)
        assertEquals(f, heldRow!!.toFrame())
    }

    @Test
    fun `C6_6_1 enqueueDirectOutbound same msgId different routingTag fails closed with CanonicalFrameMismatch`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        val fDiffTag = FrameV2(f.type, f.msgId, byteArrayOf(0x77, 0x88.toByte(), 0x99.toByte(), 0xAA.toByte()), f.ttl, f.hopCount, f.flags, f.payload)
        val r2 = store.enqueueDirectOutbound(fDiffTag, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.CanonicalFrameMismatch, r2)
    }

    @Test
    fun `C6_6_1 enqueueDirectOutbound same msgId different valid flags fails closed with CanonicalFrameMismatch`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        val validModifiedFlags = f.flags or FrameV2.RELAY_OK
        val fDiffFlags = FrameV2(f.type, f.msgId, f.routingTag, f.ttl, f.hopCount, validModifiedFlags, f.payload)
        val r2 = store.enqueueDirectOutbound(fDiffFlags, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.CanonicalFrameMismatch, r2)
    }

    @Test
    fun `C6_6_1 enqueueDirectOutbound same msgId different ttl fails closed with CanonicalFrameMismatch`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        val fDiffTtl = FrameV2(f.type, f.msgId, f.routingTag, ttl = 10, hopCount = f.hopCount, flags = f.flags, payload = f.payload)
        val r2 = store.enqueueDirectOutbound(fDiffTtl, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.CanonicalFrameMismatch, r2)
    }

    @Test
    fun `C6_6_1 enqueueDirectOutbound same msgId different hopCount fails closed with CanonicalFrameMismatch`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        val fDiffHop = FrameV2(f.type, f.msgId, f.routingTag, ttl = f.ttl, hopCount = 1, flags = f.flags, payload = f.payload)
        val r2 = store.enqueueDirectOutbound(fDiffHop, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.CanonicalFrameMismatch, r2)
    }

    @Test
    fun `C6_6_1 enqueueDirectOutbound local origin provenance is localOriginNodeId not msgId`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(2)

        assertFalse(origin.contentEquals(f.msgId), "origin node ID must be distinct from msgId")

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        val heldRow = engine?.readHeld(f.msgId)
        assertNotNull(heldRow)
        assertTrue(origin.contentEquals(heldRow!!.receivedFrom), "persisted received_from must equal localOriginNodeId")
        assertFalse(f.msgId.contentEquals(heldRow.receivedFrom), "persisted received_from must not equal msgId")
    }

    @Test
    fun `C6_6_1 enqueueDirectOutbound wrong preexisting provenance fails closed with InconsistentState`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val originA = localNode(1)
        val foreignNode = localNode(9)

        // Seed held frame with foreignNode provenance
        val rowId = engine!!.insert(f, receivedFrom = foreignNode, receivedAt = 100L)
        assertTrue(rowId != -1L)
        engine!!.insertDelivery(f.msgId, io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, io.godstone.mesh.delivery.AckMode.SINGLE_RECIPIENT.code, rec)

        // Retry from local node A
        val r = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = originA)
        assertEquals(OutboundEnqueueResult.InconsistentState, r)
    }

    @Test
    fun `C6_6 enqueueDirectOutbound conflicting recipient fails closed with ConflictRecipient`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec1 = recipient(1)
        val rec2 = recipient(2)
        val origin = localNode(1)

        val r1 = store.enqueueDirectOutbound(f, expectedRecipient = rec1, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), r1)

        // Retry same frame / msgId but different expected recipient
        val r2 = store.enqueueDirectOutbound(f, expectedRecipient = rec2, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.ConflictRecipient, r2)

        // Historical binding untouched
        val d = readDelivery(f.msgId)
        org.junit.Assert.assertNotNull(d)
        assertTrue(rec1.contentEquals(d!!.expectedRecipient))
    }

    @Test
    fun `C6_6 enqueueDirectOutbound terminal delivery state fails closed with RejectedTerminalState`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        assertEquals(OutboundEnqueueResult.Created(f), store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin))

        // Transition delivery state to ACKNOWLEDGED_BY_RECIPIENT (terminal)
        val updateSql = "UPDATE delivery_state SET state = ${io.godstone.mesh.delivery.DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code} WHERE msg_id = ?"
        engine!!.execDeliveryUpdate(updateSql, arrayOf(f.msgId))

        val r2 = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.RejectedTerminalState, r2)
    }

    @Test
    fun `C6_6 enqueueDirectOutbound held-only inconsistency fails closed with InconsistentState`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        // Persist frame into held_frames only (no delivery_state row)
        assertEquals(PersistResult.HELD_NEW, store.persist(f, receivedFrom = origin))
        assertNull(readDelivery(f.msgId))

        val result = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.InconsistentState, result)
    }

    @Test
    fun `C6_6 enqueueDirectOutbound delivery-only inconsistency fails closed with InconsistentState`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        // Plant delivery row only (no held frame)
        engine!!.insertDelivery(f.msgId, io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, io.godstone.mesh.delivery.AckMode.SINGLE_RECIPIENT.code, rec)
        assertFalse(heldIds().containsId(f.msgId))

        val result = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.InconsistentState, result)
    }

    @Test
    fun `C6_6 enqueueDirectOutbound store reopen preserves both held frames and delivery rows on disk`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        assertEquals(OutboundEnqueueResult.Created(f), store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin))

        // Close store and reopen from same file
        engine?.close()
        engine = null
        open(maxBytes = 4096L)

        assertTrue(heldIds().containsId(f.msgId), "held frame must survive reopen")
        val d = readDelivery(f.msgId)
        org.junit.Assert.assertNotNull("delivery row must survive reopen", d)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, d!!.state)
        assertEquals(io.godstone.mesh.delivery.AckMode.SINGLE_RECIPIENT.code, d.ackMode)
        assertTrue(rec.contentEquals(d.expectedRecipient))
    }

    // ==================================================================
    // Stage 4 Phase C6.6.2 -- Capacity-safe delivery binding + strict row decoding
    // ==================================================================

    private fun assertNoOrphanActiveDeliveries() {
        val conn = DriverManager.getConnection("jdbc:sqlite:${tmp.absolutePath}")
        conn.use { c ->
            val stmt = c.createStatement()
            val rs = stmt.executeQuery(
                "SELECT d.msg_id, d.state FROM delivery_state d " +
                "WHERE d.state IN (1, 2) " +
                "AND NOT EXISTS (SELECT 1 FROM held_frames h WHERE h.msg_id = d.msg_id)"
            )
            val orphans = mutableListOf<Int>()
            while (rs.next()) {
                orphans.add(rs.getInt("state"))
            }
            assertTrue(orphans.isEmpty(), "Found orphan active delivery rows without held frames: $orphans")
        }
    }

    @Test
    fun `C6_6_2 capacity eviction protects QUEUED_DURABLY active direct frame from new direct pressure`() = runBlocking {
        // Frame A is 100 bytes payload + 64 overhead = 164 bytes.
        // Cap is 200 bytes, so A fits alone, but A + B (328 bytes) exceeds cap.
        open(maxBytes = 200L)
        val fa = directFrame(1, payloadSize = 100)
        val fb = directFrame(2, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val ra = store.enqueueDirectOutbound(fa, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(fa), ra)
        assertNoOrphanActiveDeliveries()

        // Enqueue B: A is protected (QUEUED_DURABLY). B cannot fit without evicting A, so B is evicted and rejected.
        val rb = store.enqueueDirectOutbound(fb, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.RejectedCapacity, rb)

        // Frame A held + delivery row remain intact; Frame B is absent.
        assertTrue(heldIds().containsId(fa.msgId))
        val da = readDelivery(fa.msgId)
        assertNotNull(da)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, da!!.state)

        assertFalse(heldIds().containsId(fb.msgId))
        assertNull(readDelivery(fb.msgId))
        assertTrue(bytes() <= 200L)
        assertNoOrphanActiveDeliveries()
    }

    @Test
    fun `C6_6_2 capacity eviction protects HANDED_TO_RELAY active direct frame under pressure`() = runBlocking {
        open(maxBytes = 200L)
        val fa = directFrame(1, payloadSize = 100)
        val fb = directFrame(2, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val ra = store.enqueueDirectOutbound(fa, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(fa), ra)

        // Advance A to HANDED_TO_RELAY (state = 2) via production SqliteDeliveryRepository
        val repo = SqliteDeliveryRepository(engine!!)
        val tr = repo.transition(fa.msgId, DeliveryTransition.MARK_HANDED)
        assertEquals(TransitionResult.Applied, tr)

        // Enqueue B under capacity pressure
        val rb = store.enqueueDirectOutbound(fb, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.RejectedCapacity, rb)

        // A is still held and in HANDED_TO_RELAY
        assertTrue(heldIds().containsId(fa.msgId))
        val da = readDelivery(fa.msgId)
        assertNotNull(da)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.HANDED_TO_RELAY.code, da!!.state)
        assertTrue(bytes() <= 200L)
        assertNoOrphanActiveDeliveries()
    }

    @Test
    fun `C6_6_2 inbound persist cannot orphan local active direct delivery row`() = runBlocking {
        open(maxBytes = 200L)
        val fa = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val ra = store.enqueueDirectOutbound(fa, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(fa), ra)

        // Inbound/unbound relay frame arrives
        val inboundB = frame(2, Priority.GROUP, payloadSize = 100)
        val persistResult = store.persist(inboundB, receivedFrom = localNode(2))
        assertEquals(PersistResult.REJECTED_CAPACITY, persistResult)

        // A is still held and delivery is still QUEUED_DURABLY
        assertTrue(heldIds().containsId(fa.msgId))
        val da = readDelivery(fa.msgId)
        assertNotNull(da)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, da!!.state)
        assertTrue(bytes() <= 200L)
        assertNoOrphanActiveDeliveries()
    }

    @Test
    fun `C6_6_2 unbound relay frames evict before active delivery bound frames`() = runBlocking {
        // Cap is 350 bytes.
        // Relay R (50 bytes payload + 64 = 114 bytes)
        // Direct A (50 bytes payload + 64 = 114 bytes)
        // Total = 228 <= 350.
        open(maxBytes = 350L)
        val relayR = frame(10, Priority.GROUP, payloadSize = 50)
        val persistR = store.persistAt(relayR, receivedFrom = localNode(9), receivedAt = 100L)
        assertEquals(PersistResult.HELD_NEW, persistR)

        val directA = directFrame(1, payloadSize = 50)
        val recA = recipient(1)
        val origin = localNode(1)
        val enqueueA = store.enqueueDirectOutboundAtWithFault(directA, expectedRecipient = recA, localOriginNodeId = origin, receivedAt = 200L, fault = null)
        assertEquals(OutboundEnqueueResult.Created(directA), enqueueA)

        // Now add Direct B (100 bytes payload + 64 = 164 bytes).
        // Total would be 114 + 114 + 164 = 392 > 350 (overshoot = 42 bytes).
        // R is evictable (unbound); A is protected (active delivery). R should be evicted.
        val directB = directFrame(2, payloadSize = 100)
        val enqueueB = store.enqueueDirectOutboundAtWithFault(directB, expectedRecipient = recipient(2), localOriginNodeId = origin, receivedAt = 300L, fault = null)
        assertEquals(OutboundEnqueueResult.Created(directB), enqueueB)

        // R was evicted
        assertFalse(heldIds().containsId(relayR.msgId))
        // A is still held and active
        assertTrue(heldIds().containsId(directA.msgId))
        val da = readDelivery(directA.msgId)
        assertNotNull(da)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, da!!.state)
        // B is held and active
        assertTrue(heldIds().containsId(directB.msgId))
        val db = readDelivery(directB.msgId)
        assertNotNull(db)
        assertEquals(io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY.code, db!!.state)

        assertTrue(bytes() <= 350L)
        assertNoOrphanActiveDeliveries()
    }

    @Test
    fun `C6_6_2 terminal delivery row without held frame returns RejectedTerminalState`() = runBlocking {
        open(maxBytes = 4096L)
        val rec = recipient(1)
        val origin = localNode(1)

        val terminalStates = listOf(
            io.godstone.mesh.delivery.DeliveryState.ACKNOWLEDGED_BY_RECIPIENT,
            io.godstone.mesh.delivery.DeliveryState.EXPIRED,
            io.godstone.mesh.delivery.DeliveryState.CANCELLED_LOCALLY,
        )

        for ((idx, termState) in terminalStates.withIndex()) {
            val f = directFrame((idx + 10).toByte(), payloadSize = 100)
            // Plant delivery row directly with terminal state and NO held frame
            val inserted = engine!!.insertDelivery(
                f.msgId,
                termState.code,
                io.godstone.mesh.delivery.AckMode.SINGLE_RECIPIENT.code,
                rec
            )
            assertTrue(inserted)
            assertFalse(heldIds().containsId(f.msgId))

            // Retry same message
            val result = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
            assertEquals(OutboundEnqueueResult.RejectedTerminalState, result)
            // Zero writes to held_frames
            assertFalse(heldIds().containsId(f.msgId))
        }
    }

    @Test
    fun `C6_6_2 raw SQL corrupted type integer does not alias TypeV2 and fails closed`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val created = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), created)

        // Corrupt type in held_frames to 257 (257.toByte() is 1, which aliases TypeV2.MESSAGE)
        val conn = DriverManager.getConnection("jdbc:sqlite:${tmp.absolutePath}")
        conn.use { c ->
            val stmt = c.prepareStatement("UPDATE held_frames SET type = 257 WHERE msg_id = ?")
            stmt.setBytes(1, f.msgId)
            val n = stmt.executeUpdate()
            assertEquals(1, n)
        }

        // Retry must fail closed as InconsistentState, NOT alias as AlreadyQueuedSameBinding
        val retry = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.InconsistentState, retry)
    }

    @Test
    fun `C6_6_2 raw SQL corrupted ttl or flags fails closed`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val created = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), created)

        // Corrupt ttl to -1
        val conn = DriverManager.getConnection("jdbc:sqlite:${tmp.absolutePath}")
        conn.use { c ->
            val stmt = c.prepareStatement("UPDATE held_frames SET ttl = -1 WHERE msg_id = ?")
            stmt.setBytes(1, f.msgId)
            val n = stmt.executeUpdate()
            assertEquals(1, n)
        }

        val retry = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.InconsistentState, retry)
    }

    @Test
    fun `C6_6_2 pre-SQL outbound validation rejects malformed fields before database mutation`() = runBlocking {
        open(maxBytes = 4096L)
        val rec = recipient(1)
        val origin = localNode(1)
        val validF = directFrame(1)

        // 1. Invalid routing tag length
        val badTag = FrameV2(validF.type, validF.msgId, byteArrayOf(1, 2, 3), validF.ttl, validF.hopCount, validF.flags, validF.payload)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(badTag, rec, origin))

        // 2. Invalid ttl (> MAX_TTL)
        val badTtl = FrameV2(validF.type, validF.msgId, validF.routingTag, ttl = 17, hopCount = validF.hopCount, flags = validF.flags, payload = validF.payload)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(badTtl, rec, origin))

        // 3. Invalid hopCount (> MAX_TTL)
        val badHop = FrameV2(validF.type, validF.msgId, validF.routingTag, ttl = validF.ttl, hopCount = 17, flags = validF.flags, payload = validF.payload)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(badHop, rec, origin))

        // 4. Invalid flags (> 0xFFFF or negative)
        val badFlags = FrameV2(validF.type, validF.msgId, validF.routingTag, ttl = validF.ttl, hopCount = validF.hopCount, flags = 0x10000, payload = validF.payload)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(badFlags, rec, origin))

        // 5. Oversized payload (> MAX_PAYLOAD)
        val badPayload = FrameV2(validF.type, validF.msgId, validF.routingTag, ttl = validF.ttl, hopCount = validF.hopCount, flags = validF.flags, payload = ByteArray(FrameV2.MAX_PAYLOAD + 1))
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(badPayload, rec, origin))

        // Database must remain completely empty
        assertEquals(0L, bytes())
        assertTrue(heldIds().isEmpty())
    }

    @Test
    fun `C6_6_3 raw SQL corrupted type negative 16 does not alias SOS and fails closed`() = runBlocking {
        open(maxBytes = 4096L)
        val f = directFrame(1, payloadSize = 100)
        val rec = recipient(1)
        val origin = localNode(1)

        val created = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.Created(f), created)

        // Corrupt type in held_frames to -16 (0xF0 as signed byte, which would alias TypeV2.SOS if signed bytes were accepted)
        val conn = DriverManager.getConnection("jdbc:sqlite:${tmp.absolutePath}")
        conn.use { c ->
            val stmt = c.prepareStatement("UPDATE held_frames SET type = -16 WHERE msg_id = ?")
            stmt.setBytes(1, f.msgId)
            val n = stmt.executeUpdate()
            assertEquals(1, n)
        }

        // Direct retry must fail closed as InconsistentState (StoreRow.toFrame() returns null)
        val retry = store.enqueueDirectOutbound(f, expectedRecipient = rec, localOriginNodeId = origin)
        assertEquals(OutboundEnqueueResult.InconsistentState, retry)

        // Directly reading the row proves toFrame() returns null for negative typeCode
        val row = engine!!.readHeld(f.msgId)
        assertNotNull(row)
        assertEquals(-16, row!!.typeCode)
        assertNull(row.toFrame())
    }

    @Test
    fun `C6_6 enqueueDirectOutbound policy rejection on non-direct or unsealed or invalid msg_id`() = runBlocking {
        open(maxBytes = 4096L)
        val rec = recipient(1)
        val origin = localNode(1)

        // Non-direct priority
        val groupFrame = directFrame(1, priority = Priority.GROUP)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(groupFrame, rec, origin))

        // Unsealed
        val unsealedFrame = directFrame(2, sealed = false)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(unsealedFrame, rec, origin))

        // Has POW
        val powFrame = directFrame(3, hasPow = true)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(powFrame, rec, origin))

        // Invalid msg_id length
        val badIdFrame = directFrame(4, msgIdOverride = ByteArray(15))
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(badIdFrame, rec, origin))

        // Invalid recipient length
        val validFrame = directFrame(5)
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(validFrame, ByteArray(15), origin))

        // Invalid localOriginNodeId length
        assertEquals(OutboundEnqueueResult.InvalidArgument, store.enqueueDirectOutbound(validFrame, rec, ByteArray(15)))

        // Database must remain unchanged (zero held and zero delivery rows)
        assertEquals(0L, bytes())
        assertTrue(heldIds().isEmpty())
        assertNull(readDelivery(validFrame.msgId))
    }

    /** GS-STORE-004, the finding's own words, MIRRORED FROM THE iOS ISLE: "On first durable receipt, initialize the
     *  local policy budget in the SAME TRANSACTION as the held row. On duplicate receipt, retain/debit the existing
     *  budget; do not replenish it from the sender timestamp." EVERY HELPER HERE IS THE COURT'S OWN -- read, not
     *  invented (rounds 319-322 were three consecutive rounds in which an INVENTED NAME was what measurement
     *  refused). */
    @Test
    fun gsstore004TheBudgetIsPersistedWithTheRowAndNeverReplenished() = runBlocking {
        open(8L * 1024 * 1024)
        var now = 5_000_000L
        store.receiptTimeProvider = { now to "boot-A" }
        val f = frame(6, Priority.DIRECT, payloadSize = 48)
        assertEquals(PersistResult.HELD_NEW, store.persist(f, receivedFrom = ByteArray(0)))
        val first = store.retentionCheckpointForTest(msgId(6))
        assertNotNull(first, "the row must be readable at all")
        assertNotNull(first!![0], "the LOCAL policy budget must be PERSISTED with the row, not left empty")
        assertEquals(
            RetentionClock.lifetimeMs.getValue(MessageKind.DIRECT), first[0],
            "a FIRST receipt is granted the local lifetime exactly once",
        )
        assertEquals(5_000_000L, first[1], "anchored at the INJECTED monotonic reading")
        assertEquals("boot-A", first[2], "the continuity identifier is recorded with it")
        now += 3_600_000L
        assertEquals(PersistResult.HELD_DUPLICATE, store.persist(f, receivedFrom = ByteArray(0)))
        val after = store.retentionCheckpointForTest(msgId(6))!!
        assertEquals(first[0], after[0], "a DUPLICATE receipt must never replenish the budget")
        assertEquals(first[1], after[1], "nor move its anchor")
    }

    /** GS-STORE-004 (round 325): THE READ GATE. A budget WRITTEN and never CONSULTED governeth nothing, so the law
     *  is: a row whose PERSISTED budget is spent must not be forwarded, while a row with budget LEFT must be -- the
     *  second clause is the NEGATIVE CASE that keepeth the gate honest (a gate that withheld everything would pass
     *  the first clause alone). RUN RED BEFORE THE REPAIR. */
    @Test
    fun gsstore004ASpentBudgetIsNotForwardedButALowOneIs() = runBlocking {
        open(8L * 1024 * 1024)
        store.receiptTimeProvider = { 5_000_000L to "boot-A" }
        val spent = frame(7, Priority.DIRECT, payloadSize = 48)
        val kept = frame(8, Priority.DIRECT, payloadSize = 48)
        assertEquals(PersistResult.HELD_NEW, store.persist(spent, receivedFrom = ByteArray(0)))
        assertEquals(PersistResult.HELD_NEW, store.persist(kept, receivedFrom = ByteArray(0)))
        assertTrue(heldIds().containsId(msgId(7)), "the control: a freshly persisted row IS visible")

        // SPEND the FIRST row's budget entirely, and leave the SECOND merely LOW (one millisecond).
        store.engine.execRawSql("UPDATE ${StoreSchema.TABLE} SET ${StoreSchema.COL_REMAINING_MS} = 0")
        val hex = msgId(8).joinToString("") { "%02x".format(it) }
        store.engine.execRawSql(
            "UPDATE ${StoreSchema.TABLE} SET ${StoreSchema.COL_REMAINING_MS} = 1 " +
                "WHERE ${StoreSchema.COL_MSG_ID} = x'$hex'",
        )
        assertEquals(1L, store.retentionCheckpointForTest(msgId(8))!![0], "the control row is merely LOW")

        assertFalse(
            heldIds().containsId(msgId(7)),
            "a row whose PERSISTED budget is spent must NOT be forwarded to a reader",
        )
        assertTrue(
            heldIds().containsId(msgId(8)),
            "a row whose budget is merely LOW must still be forwarded -- the gate must not withhold everything",
        )
    }

    /** GS-STORE-004 (round 326), the finding's own words: "Expiration must ATOMICALLY retire held rows ...". THE
     *  DISCRIMINATING LAW, MIRRORED FROM iOS ROUND 311: a spent row must be GONE FROM STORAGE, not merely hidden
     *  from readers -- and the sweep must SAY how many it retired. RUN RED BEFORE THE REPAIR. */
    @Test
    fun gsstore004TheSweepRetirethTheSpentRowFromStorage() = runBlocking {
        open(8L * 1024 * 1024)
        store.receiptTimeProvider = { 5_000_000L to "boot-A" }
        val f = frame(9, Priority.DIRECT, payloadSize = 48)
        assertEquals(PersistResult.HELD_NEW, store.persist(f, receivedFrom = ByteArray(0)))
        store.engine.execRawSql("UPDATE ${StoreSchema.TABLE} SET ${StoreSchema.COL_REMAINING_MS} = 0")
        assertNotNull(store.retentionCheckpointForTest(msgId(9)), "the row stands before the sweep")

        assertEquals(1, store.sweepExpired(limit = 8), "the sweep must retire the spent row and SAY how many")
        assertNull(
            store.retentionCheckpointForTest(msgId(9)),
            "the row must be GONE FROM STORAGE -- a hidden row is not a retired one",
        )
    }

    /** GS-STORE-004, the finding's own words: "Persist a DIRECT, close/reopen on same boot, advance injected monotonic
     *  time, and verify remaining lifetime only DECREASES." The iOS isle learned this the hard way (its round 308):
     *  A CONSERVATIVE DEBIT COMPUTED AND DROPPED CAN NEVER REACH `discontinuityLimit`, so the bounded rule would be a
     *  DECORATION. An arm that demandeth it be RECORDED is therefore the law. RUN RED BEFORE THE REPAIR. */
    @Test
    fun gsstore004AConservativeDebitIsPersistedBack() = runBlocking {
        open(8L * 1024 * 1024)
        var boot = "boot-A"
        store.receiptTimeProvider = { 5_000_000L to boot }
        val f = frame(11, Priority.DIRECT, payloadSize = 48)
        assertEquals(PersistResult.HELD_NEW, store.persist(f, receivedFrom = ByteArray(0)))
        // A budget that SURVIVES the conservative hour, so the row is not retired -- only debited.
        store.engine.execRawSql("UPDATE ${StoreSchema.TABLE} SET ${StoreSchema.COL_REMAINING_MS} = 300000000")
        assertEquals(0L, store.retentionCheckpointForTest(msgId(11))!![3], "no discontinuity yet")

        // THE BOOT CHANGETH (the same monotonic reading): continuity is NOT provable.
        boot = "boot-B"
        heldIds()   // a read -- and the gate must judge conservatively AND RECORD the judgement

        val after = store.retentionCheckpointForTest(msgId(11))!!
        assertEquals(1L, after[3], "the conservative debit must be PERSISTED, or the bound is unreachable")
        assertTrue((after[0] as Long) < 300_000_000L, "and the debit must be reflected in the persisted budget")
    }

    /** GS-STORE-004, the finding's own words: "CONNECT A BOUNDED EXPIRY SWEEP TO STARTUP AND RUNTIME SCHEDULING." A
     *  sweep that only a hand may invoke is connected to NOTHING. RUN RED BEFORE THE REPAIR. */
    @Test
    fun gsstore004TheSweepIsConnectedToStartup() = runBlocking {
        open(8L * 1024 * 1024)
        store.receiptTimeProvider = { 5_000_000L to "boot-A" }
        val f = frame(12, Priority.DIRECT, payloadSize = 48)
        assertEquals(PersistResult.HELD_NEW, store.persist(f, receivedFrom = ByteArray(0)))
        store.engine.execRawSql("UPDATE ${StoreSchema.TABLE} SET ${StoreSchema.COL_REMAINING_MS} = 0")
        assertNotNull(store.retentionCheckpointForTest(msgId(12)), "the spent row stands before the reopen")

        // A REOPEN of the SAME file, and NO ONE calls the sweep.
        open(8L * 1024 * 1024)
        store.receiptTimeProvider = { 5_000_000L to "boot-A" }
        // A REAL READ (not the test hook): the maintenance must be reached THROUGH THE DOOR A CALLER USES,
        // which is the lesson the iOS isle's round 316 paid for when it hung the connection on a door the arm
        // never walked through.
        assertTrue(heldIds().isEmpty(), "the spent row must not be forwarded after the reopen")
        assertNull(
            store.retentionCheckpointForTest(msgId(12)),
            "STARTUP must retire a spent row WITHOUT a hand on the sweep -- a sweep only a hand may call " +
                "is connected to nothing",
        )
    }

    /** GS-STORE-004, the finding's own words: the sweep must be connected to "STARTUP **AND RUNTIME SCHEDULING**". A
     *  startup sweep alone is HALF that sentence: a store that runneth for days must maintain itself AS IT RUNS, and
     *  the policy carrieth its own cadence (`RetentionClock.CHECKPOINT_CADENCE_MS`) for exactly that. RUN RED BEFORE
     *  THE REPAIR. */
    @Test
    fun gsstore004TheSweepAlsoRunsOnThePolicyCadence() = runBlocking {
        open(8L * 1024 * 1024)
        var now = 1_000_000L
        store.receiptTimeProvider = { now to "boot-A" }
        val f = frame(13, Priority.DIRECT, payloadSize = 48)
        assertEquals(PersistResult.HELD_NEW, store.persist(f, receivedFrom = ByteArray(0)))
        // The STARTUP sweep runneth at this read -- and NOTHING is spent yet, so it retires nothing.
        assertEquals(1, heldIds().size, "the row stands after the startup maintenance")
        store.engine.execRawSql("UPDATE ${StoreSchema.TABLE} SET ${StoreSchema.COL_REMAINING_MS} = 0")

        // ADVANCE THE CLOCK PAST THE POLICY'S OWN CADENCE, then use the store again.
        now += RetentionClock.CHECKPOINT_CADENCE_MS + 1
        heldIds()
        assertNull(
            store.retentionCheckpointForTest(msgId(13)),
            "the RUNTIME cadence must retire rows spent since the last sweep, not only at startup",
        )
    }

    /** *** GS-STORE-004 (round 528): THE MINT MUST GRANT THE ROW'S **OWN** KIND. ***
     *
     * HOW THIS DEFECT SURVIVED EVERY ARM THAT STOOD ON BOTH ISLES, AND IT IS THE ROUND'S OWN LESSON: EVERY retention
     * arm persisted `frame(..., type = TypeV2.MESSAGE)` -- THE DEFAULT -- so every row was DIRECT, and
     * `kind = MessageKind.DIRECT` **HARDCODED IN THE MINT WAS INDISTINGUISHABLE FROM A CORRECT DERIVATION**.
     * **AN ARM THAT EXERCISETH ONE KIND CANNOT JUDGE A PER-KIND TABLE.**
     *
     * MEASURED ON THIS ISLE BEFORE THE REPAIR: `MessageKind` carried **NO OCTET MAPPING AT ALL**, BOTH mint sites
     * hardcoded DIRECT, and `isForwardable`'s `kind` DEFAULTED to DIRECT with BOTH of its callers passing nothing --
     * SO THE ENTIRE PER-KIND RETENTION TABLE WAS INERT HERE, and an SOS (the policy's twenty-four hours) was
     * retained **SEVEN TIMES** too long.
     */
    @Test
    fun gsstore004TheMintGrantethTheRowsOwnKindAndNotADefaultedDirect() = runBlocking {
        open(8L * 1024 * 1024)
        store.receiptTimeProvider = { 5_000_000L to "boot-A" }

        // AN SOS FRAME: the policy saith twenty-four hours, and the mint must agree.
        val sos = frame(31, Priority.DIRECT, payloadSize = 48, type = TypeV2.SOS)
        assertEquals(PersistResult.HELD_NEW, store.persist(sos, receivedFrom = ByteArray(0)))
        assertEquals(
            RetentionClock.lifetimeMs.getValue(MessageKind.SOS),
            store.retentionCheckpointForTest(msgId(31))!![0],
            "*** AN SOS MUST BE GRANTED THE SOS LIFETIME: the mint hardcoded DIRECT, so the most sensitive row on " +
                "this isle was retained SEVEN TIMES too long (GS-STORE-004 step 3) ***",
        )

        // AND A BULK FRAME: one hour, not seven days.
        val bulk = frame(32, Priority.DIRECT, payloadSize = 48, type = TypeV2.BULK_CHUNK)
        assertEquals(PersistResult.HELD_NEW, store.persist(bulk, receivedFrom = ByteArray(0)))
        assertEquals(
            RetentionClock.lifetimeMs.getValue(MessageKind.BULK),
            store.retentionCheckpointForTest(msgId(32))!![0],
            "*** AND A BULK ROW ONE HOUR, NOT ONE HUNDRED AND SIXTY-EIGHT TIMES ITS OWN ***",
        )

        // THE DISCRIMINATOR: a plain MESSAGE frame IS direct -- so this arm cannot pass by minting one kind for all,
        // and the defaulted frame of every OTHER arm in this file stayeth lawful.
        assertEquals(PersistResult.HELD_NEW, store.persist(frame(33, Priority.DIRECT, payloadSize = 48),
                                                           receivedFrom = ByteArray(0)))
        assertEquals(
            RetentionClock.lifetimeMs.getValue(MessageKind.DIRECT),
            store.retentionCheckpointForTest(msgId(33))!![0],
            "and a DIRECT row carrieth DIRECT's lifetime",
        )
    }

    /** *** GS-STORE-004 CLOSURE 3: "related delivery/retention state must survive ... REPEATED RESTART
     *  consistently." -- THE ANDROID TWIN, BECAUSE THE CONTRACT IS SHARED BETWEEN THE ISLES. ***
     *
     * MEASURED AT ROUND 529 BEFORE THE TWIN WAS WRITTEN, ON BOTH ISLES: the arms that stood REOPENED THE STORE
     * **ONCE** (or faulted once), and **NOT ONE PERFORMED REPEATED RESTARTS AND ASKED WHETHER THE STATE STAYED
     * CONSISTENT.** The fault arms roll back the HELD row and the DELIVERY rows -- not the retention write-back --
     * so this clause had no witness at all.
     *
     * THE LAW, IN THREE CLAUSES, AND EACH IS A WAY THE STATE COULD GO WRONG: the budget must fall by **EXACTLY the
     * total elapsed time** (neither double-counted, which spendeth a row early and destroyeth data, nor lost, which
     * holdeth it too long); it must **never rise**; and the counter must **not move**, because every same-boot
     * restart PROVETH continuity.
     */
    @Test
    fun gsstore004RepeatedRestartsLeaveTheRetentionStateConsistent() = runBlocking {
        open(8L * 1024 * 1024)
        var now = 5_000_000L
        store.receiptTimeProvider = { now to "boot-A" }
        val f = frame(41, Priority.DIRECT, payloadSize = 48)
        assertEquals(PersistResult.HELD_NEW, store.persist(f, receivedFrom = ByteArray(0)))
        val admitted = store.retentionCheckpointForTest(msgId(41))!![0] as Long
        engine?.close()

        val hours = 6
        var previous = admitted
        for (restart in 1..hours) {
            now += 3_600_000L                      // an hour of MONOTONIC time passes between restarts
            open(8L * 1024 * 1024)
            store.receiptTimeProvider = { now to "boot-A" }
            val held = heldIds()
            val cp = store.retentionCheckpointForTest(msgId(41))
            engine?.close()

            // ASSERTED AS BOOLEANS, NOT AS OVERLOADED EQUALITIES: Kotlin resolveth JUnit's `Double` overload when
            // the actual is `Any?`, and three attempts at the message-first form still lost that fight. **WHEN THE
            // MECHANISM KEEPETH FAILING, SIMPLIFY IT UNTIL IT CANNOT** -- and an explicit boolean carrieth the actual
            // values into the message, which the overloaded form could not.
            org.junit.Assert.assertTrue(
                "six hours of a seven-day hold must not retire the row (restart $restart, held=${held.size})",
                held.size == 1,
            )
            val budget = cp!![0] as Long
            org.junit.Assert.assertTrue(
                "*** NO RESTART MAY REPLENISH THE BUDGET: a receipt is granted the lifetime EXACTLY ONCE " +
                    "(GS-STORE-004 closure 3; restart $restart: $budget > $previous) ***",
                budget <= previous,
            )
            org.junit.Assert.assertTrue(
                "*** EVERY SAME-BOOT RESTART PROVETH CONTINUITY: the counter must not move -- a restart is not a " +
                    "discontinuity (GS-STORE-004 closure 3; restart $restart: disc=${cp[3]}) ***",
                (cp[3] as Long) == 0L,
            )
            previous = budget
        }
        org.junit.Assert.assertTrue(
            "*** SIX ONE-HOUR RESTARTS MUST SPEND EXACTLY SIX HOURS: a re-based anchor debited twice would spend " +
                "twelve, and an anchor never re-based would spend nothing after the first (GS-STORE-004 closure 3; " +
                "spent=${admitted - previous}) ***",
            admitted - previous == hours * 3_600_000L,
        )
    }

}
