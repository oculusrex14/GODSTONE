package io.godstone.mesh.lab

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import io.godstone.mesh.delivery.IntentStateRank
import io.godstone.mesh.delivery.JournalAdvanceResult
import io.godstone.mesh.delivery.JournalEntry
import io.godstone.mesh.delivery.JournalInsertResult
import io.godstone.mesh.delivery.OutboundIntentJournal

/**
 * *** GS-FINAL-003 `durable-authority`: THE LAB'S WRITE-AHEAD INTENT LEDGER, ON REAL DISK. ***
 *
 * *THE IOS ISLE HAS `SqliteOutboundIntentJournal(store:)`; THIS ISLE HAD ONLY THE PROCESS-LOCAL MAP, so a retry after a
 * relaunch could not load the SAME authored bytes -- and the retry law ("load identical persisted bytes") was therefore
 * unprovable on Android.* **THIS IS THE ANDROID TWIN: a real `SQLiteOpenHelper` database, under the LABEL's own database
 * directory, holding the one row per intent that the authority write-ahead before it enqueues.**
 *
 * *** IT ADDETH NOTHING BUT THE TRANSLATION. *** *Every act is the store's own verb spelled as SQL, and the medium is
 * the platform's own SQLite -- never a map, never a file, never a fake.* **AND IT FAILETH CLOSED**: a storage fault is
 * `StorageFailure`, never folded into absence, so the authority can tell "the intent was never stored" from "the ledger
 * could not be read".
 *
 * *** AND IT IS PART OF THE ESTATE, SO THE WIPE OWNETH IT. *** *Its database and sidecars are named by
 * [`ProductionLabEstate.ownedFiles`], so a requested wipe deletes the very ledger a retry would have read.*
 */
internal class LabSqliteIntentJournal(
    private val helper: SQLiteOpenHelper,
) : OutboundIntentJournal, AutoCloseable {

    private val lock = Any()

    /**
     * *** THE ENGINE IS RELEASED WHEN THE ESTATE RETIRES IT. ***
     *
     * *A `SQLiteOpenHelper` holdeth a real database handle -- and on the JVM host, a `CloseGuard`-watched
     * `SQLiteDatabase` -- so a wipe that deleted the ledger's FILES while its handle still stood would leave the
     * estate's own medium open exactly as review A6 warns for the stores.* **The estate therefore closes this the
     * same way it closeth the message and peer stores: BEFORE the bytes are removed.**
     */
    override fun close() {
        runCatching { helper.close() }
    }

    override fun load(intentId: ByteArray): JournalEntry? = synchronized(lock) {
        // *A BLOB primary key cannot be bound through `selectionArgs` (which is typed as TEXT), so the key is embedded
        // as a hex literal -- the platform's own spelling for a blob literal, and the only road that really matches.*
        helper.readableDatabase.rawQuery(
            "SELECT * FROM $TABLE WHERE $COL_INTENT_ID = ${blobLiteral(intentId)}",
            null,
        ).use { cursor -> if (cursor.moveToFirst()) rowOf(cursor) else null }
    }

    /**
     * *** THE CLAIM, KEYED BY THE COMMAND REVISION -- EXACTLY AS THE IN-MEMORY SIBLING AND THE iOS TWIN. ***
     *
     * *Only the SAME (token, canonicalCommandDigest) is a duplicate; a DIFFERENT digest under one token is a NEW logical
     * send and taketh the row.* **The classification re-READETH, so the winner is the row that actually governs rather
     * than one guessed at insert time.**
     */
    override fun insertIfAbsent(entry: JournalEntry): JournalInsertResult = synchronized(lock) {
        try {
            val cv = ContentValues().apply {
                put(COL_INTENT_ID, entry.intentId)
                put(COL_LOGICAL_MESSAGE_ID, entry.logicalMessageId)
                put(COL_SIGNED_PLAINTEXT, entry.signedPlaintextBytes)
                put(COL_CANONICAL_FRAME, entry.canonicalFrameBytes)
                put(COL_RECIPIENT_NODE_ID, entry.recipientNodeId)
                put(COL_RECIPIENT_STATIC_DH, entry.recipientStaticDhPub)
                put(COL_ACCEPTED_GENERATION, entry.acceptedGeneration)
                put(COL_BINDING_DIGEST, entry.bindingDigest)
                put(COL_CREATED_AT, entry.createdAtEpochSeconds)
                put(COL_MESSAGE_NONCE, entry.messageNonce)
                put(COL_PRIORITY_CODE, entry.priorityCode)
                put(COL_STATE_RANK, entry.stateRank.rank)
            }
            val existing = load(intentId = entry.intentId)
            if (existing != null && existing.bindingDigest.contentEquals(entry.bindingDigest)) {
                return@synchronized JournalInsertResult.Duplicate(existing)
            }
            val db = helper.writableDatabase
            // *One row per token: a changed revision REPLACES it, which is the "the row MATCHETH what the authority
            // committed" law the in-memory journal's docstring records.*
            db.insertWithOnConflict(TABLE, null, cv, SQLiteDatabase.CONFLICT_REPLACE)
            val winner = load(entry.intentId) ?: return@synchronized JournalInsertResult.StorageFailure
            JournalInsertResult.Stored.takeIf { winner.bindingDigest.contentEquals(entry.bindingDigest) }
                ?: JournalInsertResult.Duplicate(winner)
        } catch (_: Throwable) {
            JournalInsertResult.StorageFailure
        }
    }

    /** *Strictly monotone: the stored row must stand at [from] and [to] must be exactly one rung above it.* */
    override fun advance(intentId: ByteArray, from: IntentStateRank, to: IntentStateRank): JournalAdvanceResult =
        synchronized(lock) {
            if (to.rank != from.rank + 1) return@synchronized JournalAdvanceResult.Stale
            try {
                val moved = helper.writableDatabase.update(
                    TABLE,
                    ContentValues().apply { put(COL_STATE_RANK, to.rank) },
                    "$COL_INTENT_ID = ${blobLiteral(intentId)} AND $COL_STATE_RANK = ?",
                    arrayOf(from.rank.toString()),
                )
                when {
                    moved == 1 -> JournalAdvanceResult.Advanced
                    load(intentId) == null -> JournalAdvanceResult.NoSuchEntry
                    else -> JournalAdvanceResult.Stale
                }
            } catch (_: Throwable) {
                JournalAdvanceResult.StorageFailure
            }
        }

    /**
     * *** A BLOB AS THE PLATFORM'S OWN HEX LITERAL (`X'..'`). ***
     *
     * *`selectionArgs` is typed TEXT, so a raw byte key bound there compares a text value to a blob and never matches --
     * a defect that would read as "the retry found nothing".* **The literal is built from the bytes themselves, and
     * every literal here is derived from a key the caller already holdeth (never from a row), so there is no injection
     * surface.**
     */
    private fun blobLiteral(bytes: ByteArray): String =
        "X'" + bytes.joinToString("") { "%02x".format(it) } + "'"

    private fun rowOf(cursor: android.database.Cursor): JournalEntry? {
        return try {
            JournalEntry.of(
                intentId = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_INTENT_ID)),
                logicalMessageId = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_LOGICAL_MESSAGE_ID)),
                signedPlaintextBytes = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_SIGNED_PLAINTEXT)),
                canonicalFrameBytes = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_CANONICAL_FRAME)),
                recipientNodeId = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_RECIPIENT_NODE_ID)),
                recipientStaticDhPub = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_RECIPIENT_STATIC_DH)),
                acceptedGeneration = cursor.getLong(cursor.getColumnIndexOrThrow(COL_ACCEPTED_GENERATION)),
                bindingDigest = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_BINDING_DIGEST)),
                createdAtEpochSeconds = cursor.getLong(cursor.getColumnIndexOrThrow(COL_CREATED_AT)),
                messageNonce = cursor.getBlob(cursor.getColumnIndexOrThrow(COL_MESSAGE_NONCE)),
                priorityCode = cursor.getInt(cursor.getColumnIndexOrThrow(COL_PRIORITY_CODE)),
                stateRank = IntentStateRank.fromRank(cursor.getInt(cursor.getColumnIndexOrThrow(COL_STATE_RANK)))
                    ?: return null,
            )
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        /** The ledger's database name, under the LABEL's own database directory. */
        const val DB_NAME: String = "lab_intents.db"
        private const val TABLE = "outbound_intents"
        private const val VERSION = 1

        private const val COL_INTENT_ID = "intent_id"
        private const val COL_LOGICAL_MESSAGE_ID = "logical_message_id"
        private const val COL_SIGNED_PLAINTEXT = "signed_plaintext"
        private const val COL_CANONICAL_FRAME = "canonical_frame"
        private const val COL_RECIPIENT_NODE_ID = "recipient_node_id"
        private const val COL_RECIPIENT_STATIC_DH = "recipient_static_dh_pub"
        private const val COL_ACCEPTED_GENERATION = "accepted_generation"
        private const val COL_BINDING_DIGEST = "binding_digest"
        private const val COL_CREATED_AT = "created_at_epoch_seconds"
        private const val COL_MESSAGE_NONCE = "message_nonce"
        private const val COL_PRIORITY_CODE = "priority_code"
        private const val COL_STATE_RANK = "state_rank"

        /** *Open the ledger over the LABEL's own context view, so its file is the estate's own.* */
        fun over(labelCtx: Context): OutboundIntentJournal = LabSqliteIntentJournal(
            object : SQLiteOpenHelper(labelCtx, DB_NAME, null, VERSION) {
                override fun onCreate(db: SQLiteDatabase) {
                    db.execSQL(
                        "CREATE TABLE IF NOT EXISTS $TABLE (" +
                            "$COL_INTENT_ID BLOB PRIMARY KEY NOT NULL, " +
                            "$COL_LOGICAL_MESSAGE_ID BLOB NOT NULL, " +
                            "$COL_SIGNED_PLAINTEXT BLOB NOT NULL, " +
                            "$COL_CANONICAL_FRAME BLOB NOT NULL, " +
                            "$COL_RECIPIENT_NODE_ID BLOB NOT NULL, " +
                            "$COL_RECIPIENT_STATIC_DH BLOB NOT NULL, " +
                            "$COL_ACCEPTED_GENERATION INTEGER NOT NULL, " +
                            "$COL_BINDING_DIGEST BLOB NOT NULL, " +
                            "$COL_CREATED_AT INTEGER NOT NULL, " +
                            "$COL_MESSAGE_NONCE BLOB NOT NULL, " +
                            "$COL_PRIORITY_CODE INTEGER NOT NULL, " +
                            "$COL_STATE_RANK INTEGER NOT NULL)",
                    )
                }

                override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
                    // *A destructive recreate, on the same doctrine as the message store's schema (ADR-001 §5): the
                    // ledger carrieth no installed base and a stale column set would be worse than a lost replay.*
                    db.execSQL("DROP TABLE IF EXISTS $TABLE")
                    onCreate(db)
                }
            },
        )
    }
}
