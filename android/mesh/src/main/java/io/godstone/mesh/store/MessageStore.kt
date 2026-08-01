// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.store

import android.content.ContentValues
import android.content.Context
// AUDIT A-06. net.zetetic:sqlcipher-android was declared in build.gradle.kts and
// then never imported: the store used plain android.database.sqlite, so seizing
// a device yielded the entire message history in cleartext while the threat
// model told adversary A6 the store was encrypted. A declared dependency is not
// a control; only the import that actually replaces the plaintext engine is.
import net.zetetic.database.sqlcipher.SQLiteDatabase
import net.zetetic.database.sqlcipher.SQLiteOpenHelper
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.SecureRandom
import io.godstone.mesh.wire.Frame
import io.godstone.mesh.wire.FrameType
import io.godstone.mesh.wire.Priority

/**
 * Persistent hold for relayed and locally-originated frames.
 *
 * The router treats the store as the source of truth for what this node carries,
 * so an encounter with any peer can be answered from disk without an in-memory
 * index. Frames are retained until delivered or aged out, which is the whole
 * point of a delay-tolerant epidemic router.
 */
interface MessageStore {
    /** Persist [frame], recording the peer it was received from. */
    suspend fun persist(frame: Frame, receivedFrom: ByteArray)

    /** All held frames, SOS-first then by priority and recency. */
    suspend fun allHeldOrderedByPriority(): List<Frame>

    /** msg_ids of every held frame, for bloom-digest construction. */
    suspend fun allHeldMsgIds(): List<Long>

    /**
     * Stream held frames in priority order, stopping as soon as [visit] returns
     * false. This is what Router.framesPeerLacks actually calls.
     *
     * Audit A-13: the list-returning variants materialise the entire store (up
     * to the 200 MB budget) into an ArrayList on every peer encounter. Router
     * was already written against this streaming form, but the interface never
     * declared it -- an unresolved reference that no Python-only invariant could
     * see, because Kotlin is never compiled in the verification environment.
     * Invariant F now resolves every cross-file call and would fail the build.
     */
    suspend fun forEachHeldOrderedByPriority(visit: (Frame) -> Boolean)

    /** Stream held msg_ids, stopping as soon as [visit] returns false. */
    suspend fun forEachHeldMsgId(visit: (Long) -> Boolean)
}

/**
 * SQLCipher-backed store (threat A6).
 *
 * This store still uses the legacy GMP/1 logical schema until ADR-001/M1-wire
 * lands. ACK expiry, exact hard-cap semantics, and coordinated identity/store
 * wipe remain tracked in ADR-004 and are not represented as closed here.
 */
class SqliteMessageStore(
    private val ctx: Context,
    private val maxBytes: Long
) : MessageStore {

    private val helper: Helper

    init {
        // sqlcipher-android requires explicit native-core loading before any
        // helper can attempt to open a database.
        System.loadLibrary("sqlcipher")
        helper = Helper(ctx.applicationContext, passphrase(ctx.applicationContext))
    }

    override suspend fun persist(frame: Frame, receivedFrom: ByteArray) {
        val db = helper.writableDatabase
        val cv = ContentValues().apply {
            put(COL_MSG_ID, frame.msgId)
            put(COL_TYPE, frame.type.code.toInt())
            put(COL_TTL, frame.ttl)
            put(COL_PRIORITY, frame.priority.code.toInt())
            put(COL_TIMESTAMP, frame.timestamp)
            put(COL_PAYLOAD, frame.payload)
            put(COL_RECEIVED_FROM, receivedFrom)
            put(COL_RECEIVED_AT, System.currentTimeMillis())
        }
        db.insertWithOnConflict(TABLE, null, cv, SQLiteDatabase.CONFLICT_IGNORE)
        evictIfOverBudget(db)
    }

    override suspend fun allHeldOrderedByPriority(): List<Frame> {
        val db = helper.readableDatabase
        val out = ArrayList<Frame>()
        db.query(
            TABLE, null, null, null, null, null,
            "$COL_PRIORITY ASC, $COL_RECEIVED_AT DESC"
        ).use { c ->
            while (c.moveToNext()) {
                val f = readFrame(c)
                if (f != null) out.add(f)
            }
        }
        return out
    }

    override suspend fun allHeldMsgIds(): List<Long> {
        val db = helper.readableDatabase
        val out = ArrayList<Long>()
        db.query(TABLE, arrayOf(COL_MSG_ID), null, null, null, null, null).use { c ->
            while (c.moveToNext()) out.add(c.getLong(0))
        }
        return out
    }

    /**
     * Cursor-streamed scan. The cursor is walked row by row and abandoned the
     * moment [visit] returns false, so a full backlog never lands in memory
     * (audit A-13).
     */
    override suspend fun forEachHeldOrderedByPriority(visit: (Frame) -> Boolean) {
        val db = helper.readableDatabase
        db.query(
            TABLE, null, null, null, null, null,
            "$COL_PRIORITY ASC, $COL_RECEIVED_AT DESC"
        ).use { c ->
            while (c.moveToNext()) {
                val f = readFrame(c) ?: continue
                if (!visit(f)) return
            }
        }
    }

    override suspend fun forEachHeldMsgId(visit: (Long) -> Boolean) {
        val db = helper.readableDatabase
        db.query(TABLE, arrayOf(COL_MSG_ID), null, null, null, null, null).use { c ->
            while (c.moveToNext()) {
                if (!visit(c.getLong(0))) return
            }
        }
    }

    /**
     * Best-effort eviction of the oldest non-SOS rows when the store exceeds
     * [maxBytes]. SOS frames are retained longest by being sorted last out.
     *
     * TODO: precise byte accounting; this currently approximates by row count.
     */
    private fun evictIfOverBudget(db: SQLiteDatabase) {
        // AUDIT A-14. This previously ran the DELETE unconditionally on EVERY
        // insert, with no check that the budget had been exceeded at all. Its
        // own doc comment said "when the store exceeds maxBytes", and it never
        // asked. On a fresh install with two messages held, inserting a third
        // deleted a quarter of the non-SOS backlog immediately -- a
        // delay-tolerant store that discards the traffic it exists to carry.
        //
        // The size is now measured before anything is deleted, and the query
        // only runs when the store is genuinely over budget.
        val heldBytes = db.rawQuery(
            "SELECT COALESCE(SUM(LENGTH($COL_PAYLOAD)) + COUNT(*) * $ROW_OVERHEAD, 0) FROM $TABLE",
            null
        ).use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }

        if (heldBytes <= maxBytes) return   // nothing to do: the common case

        // Evict roughly the overshoot, oldest non-SOS first. SOS is retained
        // last under storage pressure (PROTOCOL.md section 7).
        val overshoot = heldBytes - maxBytes
        val approxRowBytes = ROW_OVERHEAD + 256L
        val toDelete = ((overshoot / approxRowBytes) + 1).coerceAtLeast(1L)
        db.execSQL(
            "DELETE FROM $TABLE WHERE $COL_MSG_ID IN (" +
                "SELECT $COL_MSG_ID FROM $TABLE WHERE $COL_PRIORITY != ? " +
                "ORDER BY $COL_RECEIVED_AT ASC LIMIT ?)",
            arrayOf<Any>(Priority.SOS.code.toInt(), toDelete)
        )
    }

    private fun readFrame(c: android.database.Cursor): Frame? {
        // Reconstruct via the wire enum types, not the payload bytes.
        val typeCode = c.getInt(c.getColumnIndexOrThrow(COL_TYPE)).toByte()
        val priorityCode = c.getInt(c.getColumnIndexOrThrow(COL_PRIORITY)).toByte()
        val ft = FrameType.from(typeCode) ?: return null
        val pr = Priority.from(priorityCode) ?: return null
        return Frame(
            type = ft,
            ttl = c.getInt(c.getColumnIndexOrThrow(COL_TTL)),
            priority = pr,
            msgId = c.getLong(c.getColumnIndexOrThrow(COL_MSG_ID)),
            timestamp = c.getLong(c.getColumnIndexOrThrow(COL_TIMESTAMP)),
            payload = c.getBlob(c.getColumnIndexOrThrow(COL_PAYLOAD))
        )
    }

    private class Helper(ctx: Context, private val key: ByteArray) :
        SQLiteOpenHelper(ctx, DB_NAME, key, null, DB_VERSION, 1, null, null, false) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE $TABLE (
                    $COL_MSG_ID INTEGER PRIMARY KEY,
                    $COL_TYPE INTEGER,
                    $COL_TTL INTEGER,
                    $COL_PRIORITY INTEGER,
                    $COL_TIMESTAMP INTEGER,
                    $COL_PAYLOAD BLOB,
                    $COL_RECEIVED_FROM BLOB,
                    $COL_RECEIVED_AT INTEGER
                )""".trimIndent()
            )
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // AUDIT A-12. This used to DROP TABLE, destroying every undelivered
            // frame -- including SOS traffic the mesh had not yet been able to
            // hand on -- the first time a user updated the app. In a blackout an
            // app update is exactly when a queued distress beacon matters most.
            //
            // Additive migration only. Any future schema change must preserve
            // held frames or explicitly justify why it cannot.
            if (oldVersion == newVersion) return
            db.execSQL("ALTER TABLE $TABLE RENAME TO ${TABLE}_migrating")
            onCreate(db)
            db.execSQL(
                "INSERT OR IGNORE INTO $TABLE SELECT * FROM ${TABLE}_migrating")
            db.execSQL("DROP TABLE ${TABLE}_migrating")
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
                ctx, "godstone_store_key", master,
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

        /**
         * Panic wipe (PROTOCOL.md section 2). Destroys the store AND its key, so
         * prior traffic cannot be linked to the regenerated identity.
         */
        fun panicWipe(ctx: Context) {
            ctx.deleteDatabase(DB_NAME)
            ctx.deleteSharedPreferences("godstone_store_key")
        }

        /** Per-row bookkeeping beyond the payload blob. */
        private const val ROW_OVERHEAD = 64L
        private const val DB_NAME = "godstone_messages.db"
        private const val DB_VERSION = 1
        private const val TABLE = "held_frames"
        private const val COL_MSG_ID = "msg_id"
        private const val COL_TYPE = "type"
        private const val COL_TTL = "ttl"
        private const val COL_PRIORITY = "priority"
        private const val COL_TIMESTAMP = "timestamp"
        private const val COL_PAYLOAD = "payload"
        private const val COL_RECEIVED_FROM = "received_from"
        private const val COL_RECEIVED_AT = "received_at"
    }
}

/**
 * Pure-Kotlin in-memory store with no Android dependency. Used by unit tests
 * that exercise the router with no device or SQLite available.
 */
internal class InMemoryMessageStore : MessageStore {
    private val held = LinkedHashMap<Long, Frame>()

    override suspend fun persist(frame: Frame, receivedFrom: ByteArray) {
        held[frame.msgId] = frame
    }

    override suspend fun allHeldOrderedByPriority(): List<Frame> =
        held.values.sortedWith(
            compareBy<Frame> { it.priority.code }.thenByDescending { it.timestamp }
        )

    override suspend fun allHeldMsgIds(): List<Long> = held.keys.toList()

    override suspend fun forEachHeldOrderedByPriority(visit: (Frame) -> Boolean) {
        for (f in allHeldOrderedByPriority()) if (!visit(f)) return
    }

    override suspend fun forEachHeldMsgId(visit: (Long) -> Boolean) {
        for (id in allHeldMsgIds()) if (!visit(id)) return
    }
}
