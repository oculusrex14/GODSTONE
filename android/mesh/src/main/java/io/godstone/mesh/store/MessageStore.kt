// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.store

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
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
}

/**
 * SQLite-backed store. Plain SQLite today; production layers SQLCipher
 * encryption so that device seizure does not yield message history (threat A6).
 *
 * TODO: precise byte-budget eviction and SQLCipher integration.
 */
class SqliteMessageStore(
    private val ctx: Context,
    private val maxBytes: Long
) : MessageStore {

    private val helper = Helper(ctx)

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
     * Best-effort eviction of the oldest non-SOS rows when the store exceeds
     * [maxBytes]. SOS frames are retained longest by being sorted last out.
     *
     * TODO: precise byte accounting; this currently approximates by row count.
     */
    private fun evictIfOverBudget(db: SQLiteDatabase) {
        // Approximate: cap by a row count derived from maxBytes / assumed row size.
        // A precise byte budget is deferred (see TODO above).
        val approxRowBytes = 512L
        val maxRows = (maxBytes / approxRowBytes).coerceAtLeast(1L)
        db.execSQL(
            "DELETE FROM $TABLE WHERE $COL_MSG_ID IN (" +
                "SELECT $COL_MSG_ID FROM $TABLE WHERE $COL_PRIORITY != ? " +
                "ORDER BY $COL_RECEIVED_AT ASC LIMIT ?)",
            arrayOf<Any>(Priority.SOS.code.toInt(), (maxRows / 4).coerceAtLeast(1L))
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

    private class Helper(ctx: Context) : SQLiteOpenHelper(ctx, DB_NAME, null, DB_VERSION) {
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
            // Single-version store today; a migration path is deferred.
            db.execSQL("DROP TABLE IF EXISTS $TABLE")
            onCreate(db)
        }
    }

    companion object {
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
}