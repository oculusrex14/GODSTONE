// SYNTHESIZED gap-closure file -- realised for GMP/2.1 per ADR-001 §5 + ADR-004.
package io.godstone.mesh.store

import android.content.ContentValues
import android.content.Context
// AUDIT A-06. net.zetetic:sqlcipher-android was declared in build.gradle.kts and
// then never imported: the store used plain android.database.sqlite, so seizing
// a device yielded the entire message history in cleartext while the threat
// model told adversary A6 the store was encrypted. A declared dependency is not
// a control; only the import that actually replaces the plaintext engine is.
// Stage 3 Phase E pins that closure with executable evidence: the production
// engine is SqlcipherStoreDb, whose helper extends
// net.zetetic.database.sqlcipher.SQLiteOpenHelper (not android.database.sqlite),
// and StoreEngineTest reflects on that type so a regression to plaintext is a
// test failure, not a silent reversion.
import net.zetetic.database.sqlcipher.SQLiteDatabase
import net.zetetic.database.sqlcipher.SQLiteOpenHelper
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.SecureRandom
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2

/**
 * The outcome of a durable persist, shared semantically with iOS (Stage 4B.1).
 *
 * Top-level (not nested in [MessageStore]) to mirror iOS, where `PersistResult`
 * is a top-level enum -- the two platforms reference the same name at the same
 * scope. The router must distinguish these to keep the durable `UNIQUE(msg_id)`
 * the authoritative dedup decision (B1) and to refuse to forward what it does not
 * durably hold (B2): only [HELD_NEW] is forwarded/delivered; [HELD_DUPLICATE] is
 * suppressed (already held, do not re-relay); [REJECTED_CAPACITY] and
 * [FAILED_STORAGE] leave the in-memory dedup window untouched so the same
 * msg_id may be re-offered after the store recovers or has room.
 */
enum class PersistResult {
    /** Newly inserted and still present after capacity enforcement. */
    HELD_NEW,
    /** Already held on a duplicate msg_id (INSERT OR IGNORE no-op) and still present. */
    HELD_DUPLICATE,
    /** Inserted but then evicted by the hard cap (or a duplicate whose row was evicted): not durably held. */
    REJECTED_CAPACITY,
    /** A storage exception occurred inside the transaction; it was rolled back. */
    FAILED_STORAGE,
}

/**
 * Persistent hold for relayed and locally-originated frames.
 *
 * The router treats the store as the source of truth for what this node carries,
 * so an encounter with any peer can be answered from disk without an in-memory
 * index. Frames are retained until delivered or aged out, which is the whole
 * point of a delay-tolerant epidemic router.
 *
 * GMP/2.1 schema v2 (ADR-001 §5 / ADR-004): the primary key is the 16-byte
 * content-derived msg_id BLOB; there is no header timestamp column (GMP/2.1
 * carries no header timestamp — created_at lives inside the sealed payload) and
 * no priority-as-source column (priority is 3 flag bits in `flags`; the
 * `priority` column here is a denormalised query aid derived from
 * Priority.fromFlags(flags) so ORDER BY / eviction can avoid SQLite's lack of a
 * bitwise shift operator). Retention is receipt-relative (received_at), not
 * creation-relative. There is no installed base (ADR-001 §5), so no migration
 * code is written: an upgrade drops and recreates the table.
 */
interface MessageStore {

    /**
     * Durably hold [frame], recording the peer it was received from.
     *
     * Returns a [PersistResult]. The row is present in the durable store at or
     * before the moment this returns for [HELD_NEW] / [HELD_DUPLICATE]; for
     * [REJECTED_CAPACITY] / [FAILED_STORAGE] the row is NOT durably held and the
     * caller MUST NOT forward, deliver or permanently mark the id seen (B1/B2,
     * ADR-004 / Stage 4B.1). The insert, hard-cap enforcement and final
     * membership check run in one transaction (B3); a storage exception is
     * rolled back and reported as [FAILED_STORAGE] rather than thrown, so one
     * bad operation cannot kill the inbound receive collector. Mirrors iOS
     * `MessageStore.persist`.
     */
    suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult

    /** All held frames, SOS-first then by priority and recency. */
    suspend fun allHeldOrderedByPriority(): List<FrameV2>

    /** msg_ids of every held frame, for bloom-digest construction. */
    suspend fun allHeldMsgIds(): List<ByteArray>

    /**
     * Stream held frames in priority order, stopping as soon as [visit] returns
     * false. This is what Router.framesPeerLacks actually calls (audit A-13: the
     * list-returning variants materialise the entire store into memory; this
     * streaming form pages rows and abandons the cursor the moment visit stops).
     */
    suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean)

    /** Stream held msg_ids, stopping as soon as [visit] returns false. */
    suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean)
}

/**
 * Schema + SQL shared by the production SQLCipher engine ([SqlcipherStoreDb])
 * and the host-test engine ([JdbcStoreDb] in the test source set). Keeping the
 * SQL in one place means the bounded-capacity eviction, the INSERT OR IGNORE
 * dedup and the priority ORDER BY are exercised against a REAL on-disk SQLite
 * in CI (sqlite-jdbc ships native SQLite in the jar) with the same statements
 * the SQLCipher engine runs -- SQLCipher is SQLite plus page encryption, so the
 * dialect and semantics are identical. The encryption itself is verified on
 * device (instrumented); the SQL invariants are verified here, repo-owned.
 */
internal object StoreSchema {
    const val DB_NAME = "godstone_messages.db"
    const val DB_VERSION = 4
    const val TABLE = "held_frames"
    const val COL_MSG_ID = "msg_id"
    const val COL_TYPE = "type"
    const val COL_TTL = "ttl"
    const val COL_HOP_COUNT = "hop_count"
    const val COL_FLAGS = "flags"
    const val COL_PRIORITY = "priority"
    const val COL_ROUTING_TAG = "routing_tag"
    const val COL_PAYLOAD = "payload"
    const val COL_RECEIVED_FROM = "received_from"
    const val COL_RECEIVED_AT = "received_at"

    /** Per-row bookkeeping beyond the payload blob (columns + page overhead). */
    const val ROW_OVERHEAD = 64L

    val CREATE_SQL: String = """
        CREATE TABLE $TABLE (
            $COL_MSG_ID BLOB PRIMARY KEY,
            $COL_TYPE INTEGER,
            $COL_TTL INTEGER,
            $COL_HOP_COUNT INTEGER,
            $COL_FLAGS INTEGER,
            $COL_PRIORITY INTEGER,
            $COL_ROUTING_TAG BLOB,
            $COL_PAYLOAD BLOB,
            $COL_RECEIVED_FROM BLOB,
            $COL_RECEIVED_AT INTEGER
        )
    """.trimIndent()

    /** Idempotent create for test engines that reopen an existing file. */
    val CREATE_SQL_IF_NOT_EXISTS: String =
        CREATE_SQL.replace("CREATE TABLE ", "CREATE TABLE IF NOT EXISTS ")

    /**
     * Total stored bytes: the sum of every payload plus a fixed per-row
     * bookkeeping allowance. This is the precise measure the bounded-capacity
     * invariant is enforced against (ADR-004 §4).
     */
    fun heldBytesSql(): String =
        "SELECT COALESCE(SUM(LENGTH($COL_PAYLOAD)) + COUNT(*) * $ROW_OVERHEAD, 0) FROM $TABLE"

    /**
     * Precise bounded-capacity eviction (Stage 3 Phase E, replacing the
     * approximate row-count form). Deletes the SMALLEST prefix of rows, ordered
     * NON-SOS-FIRST then oldest-received, whose cumulative (payload +
     * ROW_OVERHEAD) byte cost meets or exceeds the overshoot -- not a rough row
     * count divided by a guessed average row size. The window function walks
     * candidates in eviction order, `cum` is the running total INCLUDING the
     * current row, `cum - sz` is the running total BEFORE it; a row is selected
     * while the total before it was still short of the overshoot, so the
     * selected prefix is exactly what is needed to return under the cap.
     *
     * Ordering: `(priority = 0) ASC` puts non-SOS (0) before SOS (1), so SOS is
     * evicted LAST ("retained last", PROTOCOL.md §7) -- only after every non-SOS
     * row has been evicted. Because the candidate set is ALL rows, the prefix
     * always reaches the overshoot, so the store ALWAYS returns to or under the
     * cap: all-SOS flooding stays inside the configured hard cap (ADR-004
     * criterion 4). Bind: (1) overshoot bytes.
     */
    fun evictPrefixSql(): String =
        "DELETE FROM $TABLE WHERE $COL_MSG_ID IN (" +
            "SELECT $COL_MSG_ID FROM (" +
            "SELECT $COL_MSG_ID, (LENGTH($COL_PAYLOAD) + $ROW_OVERHEAD) AS sz, " +
            "SUM(LENGTH($COL_PAYLOAD) + $ROW_OVERHEAD) OVER (" +
            "ORDER BY ($COL_PRIORITY = 0) ASC, $COL_RECEIVED_AT ASC) AS cum " +
            "FROM $TABLE" +
            ") WHERE cum - sz < ?)"

    /** Priority-order clause: SOS-first (priority 0), then priority asc, then
     *  newest-received first (recency tie-break). */
    const val PRIORITY_ORDER = "$COL_PRIORITY ASC, $COL_RECEIVED_AT DESC"

    /** Membership check: true iff a row with [msg_id] is present. The
     *  load-bearing final-presence query run AFTER capacity enforcement inside
     *  the persist transaction (B2/B3): `persist` is truthful only when this
     *  confirms the row survived eviction. Bind: (1) msg_id. */
    fun containsSql(): String =
        "SELECT 1 FROM $TABLE WHERE $COL_MSG_ID = ? LIMIT 1"

    // ------------------------------------------------------------------
    // Stage 4C.1 / C6.1 -- delivery_state table (byte-identical cross-platform).
    //
    // Holds the delivery lifecycle state, the ACK mode, AND the intended
    // recipient for a message id in ONE row keyed by msg_id, in the SAME DB
    // file as the held frames, so the ACK authenticity decision (C2) binds to
    // the recipient recorded in durable outbound state INDEPENDENT of the ACK
    // frame. Each mutation is a single atomic SQL statement -- no read-modify-
    // write, no nested transaction -- so the non-recursive connection lock is
    // acquired once per call (iOS) and no transaction seam is needed:
    //   * [insertDeliverySql] creates the row (INSERT ... ON CONFLICT DO
    //     NOTHING); the expected recipient is IMMUTABLE post-creation (there is
    //     no recipient-only write -- the historical send intent is not mutable);
    //   * [updateDeliveryStateSql] advances ONLY the state column (preserving
    //     ack_mode + expected_recipient);
    //   * [clearDeliverySql] drops the row.
    //
    // The C6.1 invariant is enforced by a schema CHECK: a NONE-mode row has no
    // recipient; a SINGLE_RECIPIENT-mode row has a 16-byte recipient. A row that
    // violates it is rejected at write time and decodes to Corrupt at read time
    // (C6.5 fail-closed). The int state + ack_mode codes are the cross-platform
    // persistence contract (DeliveryState.code / AckMode.code), NOT the Kotlin
    // enum ordinals, so the two platforms agree even if their enum orders ever
    // diverge. Mirrors iOS StoreSchema. DB_VERSION bumped 3 -> 4 (no installed
    // base -> destructive onUpgrade recreate, ADR-001 §5).
    // ------------------------------------------------------------------
    const val DELIVERY_TABLE = "delivery_state"
    const val COL_D_MSG_ID = "msg_id"
    const val COL_D_STATE = "state"
    const val COL_D_ACK_MODE = "ack_mode"
    const val COL_D_EXPECTED = "expected_recipient"

    val CREATE_DELIVERY_SQL: String = """
        CREATE TABLE $DELIVERY_TABLE (
            $COL_D_MSG_ID BLOB PRIMARY KEY,
            $COL_D_STATE INTEGER NOT NULL,
            $COL_D_ACK_MODE INTEGER NOT NULL DEFAULT 0,
            $COL_D_EXPECTED BLOB,
            CHECK (
                ($COL_D_ACK_MODE = 0 AND $COL_D_EXPECTED IS NULL) OR
                ($COL_D_ACK_MODE = 1 AND $COL_D_EXPECTED IS NOT NULL AND length($COL_D_EXPECTED) = 16)
            )
        )
    """.trimIndent()

    /** Idempotent create for test engines that reopen an existing file. */
    val CREATE_DELIVERY_SQL_IF_NOT_EXISTS: String =
        CREATE_DELIVERY_SQL.replace("CREATE TABLE ", "CREATE TABLE IF NOT EXISTS ")

    /** Read the delivery row: (state code, ack_mode code, expected recipient or
     *  NULL). Bind: (1) msg_id. */
    fun readDeliverySql(): String =
        "SELECT $COL_D_STATE, $COL_D_ACK_MODE, $COL_D_EXPECTED FROM $DELIVERY_TABLE WHERE $COL_D_MSG_ID = ?"

    /**
     * Create a delivery row in QUEUED_DURABLY with the given ack_mode + expected
     * recipient. ON CONFLICT(msg_id) DO NOTHING: returns row count 1 if a new
     * row was inserted, 0 if a row already exists (the caller re-reads to
     * classify the conflict). The expected recipient is NEVER updated on an
     * existing row. Bind: (1) msg_id, (2) state, (3) ack_mode, (4) expected_recipient.
     */
    fun insertDeliverySql(): String =
        "INSERT INTO $DELIVERY_TABLE ($COL_D_MSG_ID, $COL_D_STATE, $COL_D_ACK_MODE, $COL_D_EXPECTED) " +
            "VALUES (?, ?, ?, ?) ON CONFLICT($COL_D_MSG_ID) DO NOTHING"

    /**
     * Advance ONLY the state column for msg_id, preserving ack_mode and
     * expected_recipient (the binding is immutable post-creation). Returns row
     * count 1 if a row existed and was updated, 0 otherwise. Bind: (1) state, (2) msg_id.
     */
    fun updateDeliveryStateSql(): String =
        "UPDATE $DELIVERY_TABLE SET $COL_D_STATE = ? WHERE $COL_D_MSG_ID = ?"

    /** Drop the delivery row for msg_id. Bind: (1) msg_id. */
    fun clearDeliverySql(): String =
        "DELETE FROM $DELIVERY_TABLE WHERE $COL_D_MSG_ID = ?"
}

/** A persisted `delivery_state` row before it is typed into a [DeliveryRecord]
 *  (the state / ack_mode codes may be unknown / corrupt). */
internal class DeliveryRow(
    val state: Int,
    val ackMode: Int,
    val expectedRecipient: ByteArray?,
)

/** A stored row before it is typed into a [FrameV2] (the type code may be unknown). */
internal class StoreRow(
    val typeCode: Int,
    val msgId: ByteArray,
    val routingTag: ByteArray,
    val ttl: Int,
    val hopCount: Int,
    val flags: Int,
    val payload: ByteArray,
) {
    /** Resolve to a FrameV2, or null if the type code is not a known TypeV2. */
    fun toFrame(): FrameV2? {
        val type = TypeV2.from(typeCode.toByte()) ?: return null
        return FrameV2(type, msgId, routingTag, ttl, hopCount, flags, payload)
    }
}

/**
 * The storage operations the store logic needs, independent of the SQL engine.
 * Two implementations ship: [SqlcipherStoreDb] (production, encrypted at rest
 * via SQLCipher + Keystore-held key) and `JdbcStoreDb` (test source set, real
 * on-disk SQLite via sqlite-jdbc). The bounded-capacity eviction, dedup and
 * ordering logic in [SqliteMessageStore] runs against this interface, so it is
 * the same code path in production and in CI.
 */
internal interface StoreDb {
    /** Insert [frame] (or ignore on a duplicate msg_id). Returns the rowid, or -1 if ignored. */
    fun insert(frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long): Long

    /** True iff a row with [msgId] is present. Used for the final-presence check (B2/B3). */
    fun contains(msgId: ByteArray): Boolean

    /** Total stored bytes (payloads + per-row overhead). */
    fun heldBytes(): Long

    /** Delete the oldest prefix (non-SOS first, then SOS) whose cumulative size meets [overshoot] bytes. */
    fun evictOldestPrefix(overshoot: Long)

    /** Stream rows in priority order, stopping as soon as [visit] returns false. */
    fun forEachRowOrderedByPriority(visit: (StoreRow) -> Boolean)

    /** Stream msg_ids, stopping as soon as [visit] returns false. */
    fun forEachMsgId(visit: (ByteArray) -> Boolean)

    /**
     * Run [block] in ONE transaction (BEGIN IMMEDIATE ... COMMIT / ROLLBACK) on
     * the engine's single connection (B3). `insert` / `contains` / `heldBytes` /
     * `evictOldestPrefix` called on the receiver inside [block] participate in
     * that transaction (read-your-writes on the same connection). If [block]
     * throws, the transaction is rolled back and the exception rethrown; the
     * caller converts it to [PersistResult.FAILED_STORAGE]. Shared
     * by the production SQLCipher engine and the host-test JDBC engine so the
     * insert/evict/final-membership logic is the SAME code path in CI as in
     * production.
     */
    fun inTransaction(block: (StoreDb) -> PersistResult): PersistResult

    // --- Stage 4C.1 / C6.1 -- delivery_state row for the delivery journal ---
    // Single atomic statements (see StoreSchema); no transaction seam needed.

    /** Read the delivery row for [msgId], or null if no row. */
    fun readDelivery(msgId: ByteArray): DeliveryRow?

    /**
     * Atomically create a delivery row in state [stateOrdinal] with ack_mode
     * [ackModeOrdinal] and [expectedRecipient] (null for NONE, 16 bytes for
     * SINGLE_RECIPIENT). Returns true iff a NEW row was inserted; false if a row
     * already exists for [msgId] (ON CONFLICT DO NOTHING).
     */
    fun insertDelivery(
        msgId: ByteArray,
        stateOrdinal: Int,
        ackModeOrdinal: Int,
        expectedRecipient: ByteArray?,
    ): Boolean

    /**
     * Advance only the state column for [msgId], preserving ack_mode +
     * expected_recipient. Returns the row count (1 if a row existed, 0 otherwise).
     */
    fun updateDeliveryState(msgId: ByteArray, stateOrdinal: Int): Int

    /** Drop the delivery row for [msgId]. */
    fun clearDelivery(msgId: ByteArray)

    fun close()
}

/**
 * SQLCipher-backed store (threat A6). GMP/2.1 schema v2.
 *
 * Persist-before-forward, delete-on-authenticated-ACK, hard-cap eviction
 * (SOS retained last), and coordinated identity/store wipe are the ADR-004
 * exit criteria; the repo-controlled ones (1,3,4,5,6) are realised here, while
 * authenticated-ACK deletion (criterion 2) depends on the inbound ACK path that
 * the link layer gates closed (LINK_LAYER_READY=false) and remains tracked
 * under ADR-004, not represented as closed.
 *
 * The bounded-capacity eviction (criterion 4) is precise byte accounting: the
 * oldest non-SOS rows are deleted until the measured byte total is at or under
 * [maxBytes], or only SOS rows remain (SOS retention wins over the cap). This
 * is verified repo-owned in SqliteMessageStoreTest against a real on-disk
 * SQLite engine; the at-rest encryption is verified on device (instrumented).
 */
class SqliteMessageStore internal constructor(
    /**
     * The underlying SQLite/SQLCipher engine. Exposed `internal` so the
     * production composition root (`MeshModule`, Stage 4C / C5) can build a
     * [SqliteDeliveryJournal] over the SAME engine/connection the held-frames
     * store uses -- one process-wide `StoreDb` feeds both the message store and
     * the delivery journal, so the delivery_state row lives in the same DB as
     * the held frames and shares the same connection. `internal` keeps this
     * within the `:mesh` module (non-shipping); it never reaches the
     * archive-only `lightRelease` classpath (Stage 4A forbidden-edge gate).
     */
    internal val engine: StoreDb,
    private val maxBytes: Long,
    /**
     * Test-only fault-injection seam (B3). When non-null it is invoked between
     * the insert/evict/contains phases of the persist transaction; throwing from
     * it aborts the transaction (ROLLBACK) and yields [PersistResult.FAILED_STORAGE],
     * so a test can prove the store reopens in a valid, bounded state after a
     * mid-transaction fault. MUST stay null in production -- the public
     * constructor does not expose it.
     */
    private val faultInjector: ((String) -> Unit)? = null,
) : MessageStore {

    /** Production constructor: open the SQLCipher engine with a Keystore-held key. */
    constructor(ctx: Context, maxBytes: Long) : this(SqlcipherStoreDb(ctx.applicationContext), maxBytes, null)

    /** Internal test constructor without a fault seam (kept for existing callers). */
    internal constructor(engine: StoreDb, maxBytes: Long) : this(engine, maxBytes, null)

    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult =
        persistAt(frame, receivedFrom, System.currentTimeMillis())

    /**
     * Persist with an explicit receipt timestamp. [persist] stamps "now"; this
     * internal form lets the bounded-capacity and ordering tests control
     * received_at deterministically instead of racing the wall clock.
     *
     * Stage 4B.1 (B2/B3): insert, hard-cap enforcement and the final membership
     * check run in ONE transaction (`engine.inTransaction`). `persist` is
     * truthful about holding: it returns [PersistResult.HELD_NEW] /
     * [PersistResult.HELD_DUPLICATE] only when `contains(msg_id)` confirms the
     * row is still present AFTER capacity enforcement, and
     * [PersistResult.REJECTED_CAPACITY] when the just-inserted row (or a
     * duplicate's row) was evicted by the hard cap. A storage exception inside
     * the transaction is rolled back and reported as
     * [PersistResult.FAILED_STORAGE] -- never thrown -- so one bad DB operation
     * cannot kill the inbound receive collector (B2/B3). Matches iOS
     * `SqliteMessageStore.persistAt` for shared persist-result semantics.
     */
    internal suspend fun persistAt(
        frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long
    ): PersistResult = persistAtWithFault(frame, receivedFrom, receivedAt, faultInjector)

    /**
     * [persistAt] with an explicit per-call fault seam (B3). Tests pass a one-shot
     * injector that throws between the insert/evict/contains phases to prove the
     * transaction rolls back and the store reopens valid + bounded; production
     * always passes the constructor's [faultInjector] (null) via [persistAt].
     */
    internal suspend fun persistAtWithFault(
        frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long,
        fault: ((String) -> Unit)?,
    ): PersistResult {
        return try {
            engine.inTransaction { db ->
                val rowId = db.insert(frame, receivedFrom, receivedAt)
                val isNew = rowId != -1L   // -1 == CONFLICT_IGNORE duplicate
                if (isNew) {
                    fault?.invoke("after_insert")
                    val held = db.heldBytes()
                    if (held > maxBytes) db.evictOldestPrefix(held - maxBytes)
                    fault?.invoke("after_evict")
                }
                fault?.invoke("before_contains")
                val present = db.contains(frame.msgId)
                when {
                    present && isNew -> PersistResult.HELD_NEW
                    present -> PersistResult.HELD_DUPLICATE
                    else -> PersistResult.REJECTED_CAPACITY
                }
            }
        } catch (e: Exception) {
            PersistResult.FAILED_STORAGE
        }
    }

    /** Current stored byte total (payloads + per-row overhead). */
    internal fun heldBytes(): Long = engine.heldBytes()

    override suspend fun allHeldOrderedByPriority(): List<FrameV2> {
        val out = ArrayList<FrameV2>()
        engine.forEachRowOrderedByPriority { row ->
            row.toFrame()?.let(out::add)
            true   // keep scanning; this variant materialises the whole store
        }
        return out
    }

    override suspend fun allHeldMsgIds(): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        engine.forEachMsgId { out.add(it); true }
        return out
    }

    /**
     * Cursor-streamed scan. The cursor is walked row by row and abandoned the
     * moment [visit] returns false, so a full backlog never lands in memory
     * (audit A-13).
     */
    override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {
        engine.forEachRowOrderedByPriority { row ->
            val f = row.toFrame() ?: return@forEachRowOrderedByPriority true   // unknown type: skip, continue
            visit(f)
        }
    }

    override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
        engine.forEachMsgId(visit)
    }

    companion object {
        /**
         * Panic wipe (PROTOCOL.md section 2). Destroys the store AND its key, so
         * prior traffic cannot be linked to the regenerated identity. The
         * coordinated, resumable form lands in Stage 3 Phase F; this is the
         * atomic store+key deletion it composes with [Identity.panicWipe].
         */
        fun panicWipe(ctx: Context) = SqlcipherStoreDb.panicWipe(ctx)
    }
}

/**
 * Production [StoreDb]: SQLCipher (encrypted at rest) with the database key held
 * behind an Android Keystore-backed preference. The native sqlcipher core is
 * loaded once per process here, before any helper opens a database.
 */
internal class SqlcipherStoreDb(ctx: Context) : StoreDb {
    private val helper: SQLiteOpenHelper

    init {
        // sqlcipher-android requires explicit native-core loading before any
        // helper can attempt to open a database.
        System.loadLibrary("sqlcipher")
        helper = Helper(ctx, passphrase(ctx))
    }

    override fun insert(frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long): Long {
        val d = helper.writableDatabase
        val cv = ContentValues().apply {
            put(StoreSchema.COL_MSG_ID, frame.msgId)
            put(StoreSchema.COL_TYPE, frame.type.code.toInt())
            put(StoreSchema.COL_TTL, frame.ttl)
            put(StoreSchema.COL_HOP_COUNT, frame.hopCount)
            put(StoreSchema.COL_FLAGS, frame.flags)
            // Denormalised query aid; the source of truth is `flags` (Priority.fromFlags).
            put(StoreSchema.COL_PRIORITY, Priority.fromFlags(frame.flags).code)
            put(StoreSchema.COL_ROUTING_TAG, frame.routingTag)
            put(StoreSchema.COL_PAYLOAD, frame.payload)
            put(StoreSchema.COL_RECEIVED_FROM, receivedFrom)
            put(StoreSchema.COL_RECEIVED_AT, receivedAt)
        }
        return d.insertWithOnConflict(
            StoreSchema.TABLE, null, cv, SQLiteDatabase.CONFLICT_IGNORE
        )
    }

    override fun contains(msgId: ByteArray): Boolean =
        helper.readableDatabase.rawQuery(
            StoreSchema.containsSql(), arrayOf(msgId)
        ).use { it.moveToFirst() }

    override fun heldBytes(): Long =
        helper.readableDatabase.rawQuery(StoreSchema.heldBytesSql(), null).use { c ->
            if (c.moveToFirst()) c.getLong(0) else 0L
        }

    override fun evictOldestPrefix(overshoot: Long) {
        helper.writableDatabase.execSQL(
            StoreSchema.evictPrefixSql(),
            arrayOf<Any>(overshoot)
        )
    }

    /**
     * One transaction (B3). Uses the framework `beginTransaction` /
     * `setTransactionSuccessful` / `endTransaction` API (an EXCLUSIVE write
     * lock -- the "or equivalent sqlite transaction API" the directive allows;
     * semantically serializes writers exactly as BEGIN IMMEDIATE does).
     * `insert` / `contains` / `heldBytes` / `evictOldestPrefix` called inside
     * [block] participate in this transaction: `readableDatabase` and
     * `writableDatabase` share one underlying connection, so reads see
     * uncommitted writes (read-your-writes). If [block] throws,
     * `setTransactionSuccessful` is never called and `endTransaction` rolls
     * back; the exception propagates to the caller, which reports
     * `PersistResult.FAILED_STORAGE`.
     */
    override fun inTransaction(block: (StoreDb) -> PersistResult): PersistResult {
        val db = helper.writableDatabase
        db.beginTransaction()
        try {
            val result = block(this)
            db.setTransactionSuccessful()
            return result
        } finally {
            db.endTransaction()
        }
    }

    override fun forEachRowOrderedByPriority(visit: (StoreRow) -> Boolean) {
        helper.readableDatabase.query(
            StoreSchema.TABLE, null, null, null, null, null, StoreSchema.PRIORITY_ORDER
        ).use { c ->
            while (c.moveToNext()) {
                val row = StoreRow(
                    typeCode = c.getInt(c.getColumnIndexOrThrow(StoreSchema.COL_TYPE)),
                    msgId = c.getBlob(c.getColumnIndexOrThrow(StoreSchema.COL_MSG_ID)),
                    routingTag = c.getBlob(c.getColumnIndexOrThrow(StoreSchema.COL_ROUTING_TAG)),
                    ttl = c.getInt(c.getColumnIndexOrThrow(StoreSchema.COL_TTL)),
                    hopCount = c.getInt(c.getColumnIndexOrThrow(StoreSchema.COL_HOP_COUNT)),
                    flags = c.getInt(c.getColumnIndexOrThrow(StoreSchema.COL_FLAGS)),
                    payload = c.getBlob(c.getColumnIndexOrThrow(StoreSchema.COL_PAYLOAD)),
                )
                if (!visit(row)) return
            }
        }
    }

    override fun forEachMsgId(visit: (ByteArray) -> Boolean) {
        helper.readableDatabase.query(
            StoreSchema.TABLE, arrayOf(StoreSchema.COL_MSG_ID), null, null, null, null, null
        ).use { c ->
            while (c.moveToNext()) {
                if (!visit(c.getBlob(0))) return
            }
        }
    }

    // --- Stage 4C.1 / C6.1 -- delivery_state row (single atomic statements) ---

    override fun readDelivery(msgId: ByteArray): DeliveryRow? =
        helper.readableDatabase.rawQuery(StoreSchema.readDeliverySql(), arrayOf(msgId)).use { c ->
            if (!c.moveToFirst()) null
            else DeliveryRow(
                state = c.getInt(0),
                ackMode = c.getInt(1),
                expectedRecipient = if (c.isNull(2)) null else c.getBlob(2),
            )
        }

    override fun insertDelivery(
        msgId: ByteArray,
        stateOrdinal: Int,
        ackModeOrdinal: Int,
        expectedRecipient: ByteArray?,
    ): Boolean = helper.writableDatabase
        .compileStatement(StoreSchema.insertDeliverySql()).use { stmt ->
            stmt.bindBlob(1, msgId)
            stmt.bindLong(2, stateOrdinal.toLong())
            stmt.bindLong(3, ackModeOrdinal.toLong())
            if (expectedRecipient == null) stmt.bindNull(4) else stmt.bindBlob(4, expectedRecipient)
            stmt.executeUpdateDelete() > 0   // 1 inserted, 0 on conflict (DO NOTHING)
        }

    override fun updateDeliveryState(msgId: ByteArray, stateOrdinal: Int): Int =
        helper.writableDatabase
            .compileStatement(StoreSchema.updateDeliveryStateSql()).use { stmt ->
                stmt.bindLong(1, stateOrdinal.toLong())
                stmt.bindBlob(2, msgId)
                stmt.executeUpdateDelete()   // 1 if a row existed, 0 otherwise
            }

    override fun clearDelivery(msgId: ByteArray) {
        helper.writableDatabase.execSQL(StoreSchema.clearDeliverySql(), arrayOf<Any>(msgId))
    }

    override fun close() = helper.close()

    private class Helper(ctx: Context, key: ByteArray) :
        SQLiteOpenHelper(ctx, StoreSchema.DB_NAME, key, null, StoreSchema.DB_VERSION, 1, null, null, false) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(StoreSchema.CREATE_SQL)
            // Stage 4C.1 / C6.1: delivery_state holds the lifecycle state, ack
            // mode, and expected recipient in one row, in the same DB. onCreate
            // creates both tables on first open; onUpgrade drops both then calls
            // onCreate, so a version bump (3 -> 4) recreates both with the
            // ack_mode column + CHECK (no installed base -> destructive recreate
            // is correct, ADR-001 §5).
            db.execSQL(StoreSchema.CREATE_DELIVERY_SQL)
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // ADR-001 §5: GMP/1 was never shipped (no installed base, V3 never
            // shipped on either platform), so there is nothing to migrate. Drop
            // the old table and recreate the schema. This is the one case where
            // a destructive onUpgrade is correct: a non-destructive migration of
            // a schema that was never deployed would be invented code defending
            // data that does not exist.
            if (oldVersion == newVersion) return
            db.execSQL("DROP TABLE IF EXISTS ${StoreSchema.TABLE}")
            db.execSQL("DROP TABLE IF EXISTS ${StoreSchema.DELIVERY_TABLE}")
            onCreate(db)
        }
    }

    companion object {
        /**
         * 256-bit store key, generated once and held in EncryptedSharedPreferences
         * behind a Keystore master key -- so the passphrase is protected by
         * hardware where the device provides it, and never appears in the APK.
         *
         * Losing this key makes the store unreadable, which is the correct
         * outcome: a recoverable key is not a key, it is an inconvenience for
         * whoever seized the phone.
         */
        private fun passphrase(ctx: Context): ByteArray {
            val master = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            val prefs = EncryptedSharedPreferences.create(
                ctx, KEY_PREFS, master,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM)
            prefs.getString("k", null)?.let {
                return android.util.Base64.decode(it, android.util.Base64.NO_WRAP)
            }
            val k = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val encoded = android.util.Base64.encodeToString(k, android.util.Base64.NO_WRAP)
            check(prefs.edit().putString("k", encoded).commit()) {
                "failed to persist SQLCipher key"
            }
            return k
        }

        private const val KEY_PREFS = "godstone_store_key"

        /**
         * Panic wipe (PROTOCOL.md section 2). Destroys the store AND its key, so
         * prior traffic cannot be linked to the regenerated identity. The
         * coordinated, resumable form lands in Stage 3 Phase F; this is the
         * atomic store+key deletion it builds on.
         */
        fun panicWipe(ctx: Context) {
            ctx.deleteDatabase(StoreSchema.DB_NAME)
            ctx.deleteSharedPreferences(KEY_PREFS)
        }
    }
}

/**
 * Pure-Kotlin in-memory store with no Android dependency. Used by unit tests
 * that exercise the router with no device or SQLite available.
 *
 * Stage 4B.1: contract-parity with [SqliteMessageStore]. `persist` reports the
 * same [PersistResult] distinctions (HELD_NEW / HELD_DUPLICATE / REJECTED_CAPACITY)
 * so router-level at-most-once and capacity-rejection tests can run without
 * sqlite3. The hard cap defaults to unlimited so existing router tests that
 * never approach a cap compile unchanged; a tight cap exercises the same
 * eviction ordering (non-SOS first, then SOS, newest retained) as the SQL store.
 */
internal class InMemoryMessageStore(
    private val maxBytes: Long = Long.MAX_VALUE,
) : MessageStore {
    // ByteArray is identity-equal by default, so wrap it for content-based map keys.
    private class BytesKey(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean = other is BytesKey && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }

    private data class Held(val frame: FrameV2, val receivedAt: Long)

    private val held = LinkedHashMap<BytesKey, Held>()

    private fun bytesOf(f: FrameV2): Long = f.payload.size.toLong() + StoreSchema.ROW_OVERHEAD

    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult {
        val key = BytesKey(frame.msgId)
        val isNew = !held.containsKey(key)
        if (isNew) held[key] = Held(frame, System.currentTimeMillis())
        if (held.values.sumOf { bytesOf(it.frame) } > maxBytes) evictUntilUnderCap()
        return when {
            held.containsKey(key) && isNew -> PersistResult.HELD_NEW
            held.containsKey(key) -> PersistResult.HELD_DUPLICATE
            else -> PersistResult.REJECTED_CAPACITY   // the just-inserted frame was evicted
        }
    }

    /** Evict oldest non-SOS first (then SOS, oldest first) until <= maxBytes. */
    private fun evictUntilUnderCap() {
        // Eviction order: non-SOS (priority != 0) first, oldest received; then SOS, oldest.
        val order = held.entries.sortedWith(
            compareBy<Map.Entry<BytesKey, Held>> { if (Priority.fromFlags(it.value.frame.flags) == Priority.SOS) 1 else 0 }
                .thenBy { it.value.receivedAt }
        )
        var total = held.values.sumOf { bytesOf(it.frame) }
        for (e in order) {
            if (total <= maxBytes) break
            held.remove(e.key)
            total -= bytesOf(e.value.frame)
        }
    }

    override suspend fun allHeldOrderedByPriority(): List<FrameV2> =
        held.values.map { it.frame }.sortedWith(
            compareBy<FrameV2> { Priority.fromFlags(it.flags).code }
                .thenByDescending { it.type.code.toInt() }
        )

    override suspend fun allHeldMsgIds(): List<ByteArray> = held.values.map { it.frame.msgId }

    override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {
        for (f in allHeldOrderedByPriority()) if (!visit(f)) return
    }

    override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
        for (id in allHeldMsgIds()) if (!visit(id)) return
    }
}