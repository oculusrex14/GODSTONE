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
    /** Persist [frame], recording the peer it was received from. */
    suspend fun persist(frame: FrameV2, receivedFrom: ByteArray)

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
    const val DB_VERSION = 2
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
}

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

    /** Total stored bytes (payloads + per-row overhead). */
    fun heldBytes(): Long

    /** Delete the oldest prefix (non-SOS first, then SOS) whose cumulative size meets [overshoot] bytes. */
    fun evictOldestPrefix(overshoot: Long)

    /** Stream rows in priority order, stopping as soon as [visit] returns false. */
    fun forEachRowOrderedByPriority(visit: (StoreRow) -> Boolean)

    /** Stream msg_ids, stopping as soon as [visit] returns false. */
    fun forEachMsgId(visit: (ByteArray) -> Boolean)

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
    private val engine: StoreDb,
    private val maxBytes: Long,
) : MessageStore {

    /** Production constructor: open the SQLCipher engine with a Keystore-held key. */
    constructor(ctx: Context, maxBytes: Long) : this(SqlcipherStoreDb(ctx.applicationContext), maxBytes)

    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray) =
        persistAt(frame, receivedFrom, System.currentTimeMillis())

    /**
     * Persist with an explicit receipt timestamp. [persist] stamps "now"; this
     * internal form lets the bounded-capacity and ordering tests control
     * received_at deterministically instead of racing the wall clock.
     */
    internal suspend fun persistAt(frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long) {
        engine.insert(frame, receivedFrom, receivedAt)
        evictIfOverBudget()
    }

    /** Current stored byte total (payloads + per-row overhead). */
    internal fun heldBytes(): Long = engine.heldBytes()

    /**
     * Best-effort eviction when the store exceeds [maxBytes]. Candidates are
     * evicted oldest non-SOS first; SOS is evicted LAST ("retained last",
     * PROTOCOL.md §7), only after every non-SOS row has gone. Because the
     * candidate set is all rows, the store always returns to or under the cap:
     * all-SOS flooding stays inside the configured hard cap (ADR-004 criterion 4).
     *
     * AUDIT A-14. This previously ran the DELETE unconditionally on EVERY insert
     * with no check that the budget had been exceeded, and then deleted a row
     * COUNT approximated from the overshoot divided by a guessed average row
     * size. Both defects are closed: the size is measured before anything is
     * deleted and the DELETE only runs when genuinely over budget, and the
     * deletion is now precise byte accounting (StoreSchema.evictPrefixSql) --
     * the smallest oldest (non-SOS-first) prefix whose cumulative byte cost
     * meets the overshoot.
     */
    private fun evictIfOverBudget() {
        val heldBytes = engine.heldBytes()
        if (heldBytes <= maxBytes) return   // nothing to do: the common case
        engine.evictOldestPrefix(heldBytes - maxBytes)
        // Single pass: evictOldestPrefix removes >= overshoot bytes from the
        // non-SOS-first-then-SOS oldest ordering, so the store is at or under
        // maxBytes afterwards (the candidate set is all rows, so the prefix
        // always reaches the overshoot).
    }

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

    override fun close() = helper.close()

    private class Helper(ctx: Context, key: ByteArray) :
        SQLiteOpenHelper(ctx, StoreSchema.DB_NAME, key, null, StoreSchema.DB_VERSION, 1, null, null, false) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(StoreSchema.CREATE_SQL)
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // ADR-001 §5: GMP/1 was never shipped (no installed base, V3 never
            // shipped on either platform), so there is nothing to migrate. Drop
            // the old table and recreate the v2 schema. This is the one case
            // where a destructive onUpgrade is correct: a non-destructive
            // migration of a schema that was never deployed would be invented
            // code defending data that does not exist.
            if (oldVersion == newVersion) return
            db.execSQL("DROP TABLE IF EXISTS ${StoreSchema.TABLE}")
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
 */
internal class InMemoryMessageStore : MessageStore {
    // ByteArray is identity-equal by default, so wrap it for content-based map keys.
    private class BytesKey(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean = other is BytesKey && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }

    private val held = LinkedHashMap<BytesKey, FrameV2>()

    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray) {
        held[BytesKey(frame.msgId)] = frame
    }

    override suspend fun allHeldOrderedByPriority(): List<FrameV2> =
        held.values.sortedWith(
            compareBy<FrameV2> { Priority.fromFlags(it.flags).code }
                .thenByDescending { it.type.code.toInt() }
        )

    override suspend fun allHeldMsgIds(): List<ByteArray> = held.values.map { it.msgId }

    override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {
        for (f in allHeldOrderedByPriority()) if (!visit(f)) return
    }

    override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
        for (id in allHeldMsgIds()) if (!visit(id)) return
    }
}