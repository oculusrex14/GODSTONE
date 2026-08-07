// SYNTHESIZED gap-closure file -- realised for GMP/2.1 per ADR-001 §5 + ADR-004.
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
 * SQLCipher-backed store (threat A6). GMP/2.1 schema v2.
 *
 * Persist-before-forward, delete-on-authenticated-ACK, hard-cap eviction
 * (SOS retained last), and coordinated identity/store wipe are the ADR-004
 * exit criteria; the repo-controlled ones (1,3,4,5,6) are realised here, while
 * authenticated-ACK deletion (criterion 2) depends on the inbound ACK path that
 * the link layer gates closed (LINK_LAYER_READY=false) and remains tracked
 * under ADR-004, not represented as closed.
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

    override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray) {
        val db = helper.writableDatabase
        val cv = ContentValues().apply {
            put(COL_MSG_ID, frame.msgId)
            put(COL_TYPE, frame.type.code.toInt())
            put(COL_TTL, frame.ttl)
            put(COL_HOP_COUNT, frame.hopCount)
            put(COL_FLAGS, frame.flags)
            // Denormalised query aid; the source of truth is `flags` (Priority.fromFlags).
            put(COL_PRIORITY, Priority.fromFlags(frame.flags).code)
            put(COL_ROUTING_TAG, frame.routingTag)
            put(COL_PAYLOAD, frame.payload)
            put(COL_RECEIVED_FROM, receivedFrom)
            put(COL_RECEIVED_AT, System.currentTimeMillis())
        }
        db.insertWithOnConflict(TABLE, null, cv, SQLiteDatabase.CONFLICT_IGNORE)
        evictIfOverBudget(db)
    }

    override suspend fun allHeldOrderedByPriority(): List<FrameV2> {
        val db = helper.readableDatabase
        val out = ArrayList<FrameV2>()
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

    override suspend fun allHeldMsgIds(): List<ByteArray> {
        val db = helper.readableDatabase
        val out = ArrayList<ByteArray>()
        db.query(TABLE, arrayOf(COL_MSG_ID), null, null, null, null, null).use { c ->
            while (c.moveToNext()) out.add(c.getBlob(0))
        }
        return out
    }

    /**
     * Cursor-streamed scan. The cursor is walked row by row and abandoned the
     * moment [visit] returns false, so a full backlog never lands in memory
     * (audit A-13).
     */
    override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {
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

    override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
        val db = helper.readableDatabase
        db.query(TABLE, arrayOf(COL_MSG_ID), null, null, null, null, null).use { c ->
            while (c.moveToNext()) {
                if (!visit(c.getBlob(0))) return
            }
        }
    }

    /**
     * Best-effort eviction of the oldest non-SOS rows when the store exceeds
     * [maxBytes]. SOS frames are retained longest by being excluded from
     * eviction (PROTOCOL.md section 7).
     *
     * AUDIT A-14. This previously ran the DELETE unconditionally on EVERY insert
     * with no check that the budget had been exceeded. The size is now measured
     * before anything is deleted, and the query only runs when the store is
     * genuinely over budget.
     *
     * TODO: precise byte accounting; this currently approximates by row count.
     */
    private fun evictIfOverBudget(db: SQLiteDatabase) {
        val heldBytes = db.rawQuery(
            "SELECT COALESCE(SUM(LENGTH($COL_PAYLOAD)) + COUNT(*) * $ROW_OVERHEAD, 0) FROM $TABLE",
            null
        ).use { c -> if (c.moveToFirst()) c.getLong(0) else 0L }

        if (heldBytes <= maxBytes) return   // nothing to do: the common case

        // Evict roughly the overshoot, oldest non-SOS first. SOS (priority 0) is
        // retained under storage pressure.
        val overshoot = heldBytes - maxBytes
        val approxRowBytes = ROW_OVERHEAD + 256L
        val toDelete = ((overshoot / approxRowBytes) + 1).coerceAtLeast(1L)
        db.execSQL(
            "DELETE FROM $TABLE WHERE $COL_MSG_ID IN (" +
                "SELECT $COL_MSG_ID FROM $TABLE WHERE $COL_PRIORITY != ? " +
                "ORDER BY $COL_RECEIVED_AT ASC LIMIT ?)",
            arrayOf<Any>(Priority.SOS.code, toDelete)
        )
    }

    private fun readFrame(c: android.database.Cursor): FrameV2? {
        val typeCode = c.getInt(c.getColumnIndexOrThrow(COL_TYPE)).toByte()
        val type = TypeV2.from(typeCode) ?: return null
        return FrameV2(
            type = type,
            msgId = c.getBlob(c.getColumnIndexOrThrow(COL_MSG_ID)),
            routingTag = c.getBlob(c.getColumnIndexOrThrow(COL_ROUTING_TAG)),
            ttl = c.getInt(c.getColumnIndexOrThrow(COL_TTL)),
            hopCount = c.getInt(c.getColumnIndexOrThrow(COL_HOP_COUNT)),
            flags = c.getInt(c.getColumnIndexOrThrow(COL_FLAGS)),
            payload = c.getBlob(c.getColumnIndexOrThrow(COL_PAYLOAD))
        )
    }

    private class Helper(ctx: Context, private val key: ByteArray) :
        SQLiteOpenHelper(ctx, DB_NAME, key, null, DB_VERSION, 1, null, null, false) {
        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE $TABLE (
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
                )""".trimIndent()
            )
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            // ADR-001 §5: GMP/1 was never shipped (no installed base, V3 never
            // shipped on either platform), so there is nothing to migrate. Drop
            // the old table and recreate the v2 schema. This is the one case
            // where a destructive onUpgrade is correct: a non-destructive
            // migration of a schema that was never deployed would be invented
            // code defending data that does not exist.
            if (oldVersion == newVersion) return
            db.execSQL("DROP TABLE IF EXISTS $TABLE")
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
        private const val DB_VERSION = 2
        private const val TABLE = "held_frames"
        private const val COL_MSG_ID = "msg_id"
        private const val COL_TYPE = "type"
        private const val COL_TTL = "ttl"
        private const val COL_HOP_COUNT = "hop_count"
        private const val COL_FLAGS = "flags"
        private const val COL_PRIORITY = "priority"
        private const val COL_ROUTING_TAG = "routing_tag"
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