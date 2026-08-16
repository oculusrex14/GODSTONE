package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.store.DeliveryRow
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.StoreDb
import io.godstone.mesh.store.StoreSchema
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.SecureRandom
import java.sql.DriverManager
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.TimeUnit
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Stage 4C.1 / C6.3 / **C6.4** -- the production [SqliteDeliveryRepository] over a
 * REAL on-disk SQLite ([JdbcStoreDb], the same engine the store tests use). The
 * delivery state, ack mode and intended recipient live in ONE row keyed by
 * msg_id; the expected recipient is IMMUTABLE post-creation (there is no
 * recipient-only write). Asserts the durability + preservation invariants that
 * make the C2 ACK binding trustworthy when the expected recipient comes from
 * durable outbound state, AND the C6.4 hardened contract:
 *   * [enqueue] creates the row (QUEUED_DURABLY + ack mode + recipient); a second
 *     enqueue for the same msg_id with the SAME binding is idempotent
 *     ([EnqueueResult.AlreadyQueuedSameBinding], no mutation); a second enqueue
 *     with a DIFFERENT binding is [EnqueueResult.ConflictRecipient] and does NOT
 *     mutate the recipient (C6.1: the historical send intent is never
 *     overwritten);
 *   * [transition] / [acknowledgeBound] advance ONLY the state column via a
 *     guarded SQL CAS, preserving ack_mode + expected_recipient (the C4 invariant
 *     the C2 binding relies on);
 *   * the row survives a "reboot" (a fresh repository over the same DB file);
 *   * a real [DeliveryTracker] over the real repository binds the ACK to the
 *     durable expected recipient (C1/C2 integration over SQLite, not a fake);
 *   * the schema CHECK enforces the C6.1 binding invariant AND the C6.4-C/D
 *     invariants (state IN (1..5); length(msg_id) = 16) at the DB level;
 *   * C6.5/C6.4-C: an unknown persisted state (incl. code 0 / UNAVAILABLE) fails
 *     closed to [DeliveryLookup.Corrupt] (NOT UNAVAILABLE), and a tracker over it
 *     rejects every mutation;
 *   * C6.4-A: a REAL storage failure (SQL exception) is mapped to the typed
 *     `StorageFailure` variant at every boundary, distinct from absence / conflict
 *     / no-match (never the same sentinel);
 *   * C6.4-D: a non-16-byte msg_id is [InvalidArgument] at every boundary, before
 *     any SQL (only exactly 16 bytes succeeds);
 *   * C6.4-F/H: real guarded SQL CAS -- the write is decided by the affected row
 *     count, not a stale pre-read; a 0-row CAS is re-read ONCE and classified;
 *   * C6.4-L: deterministic concurrency (controlled synchronization via a blocking
 *     authenticator + latches, NOT probabilistic thread races): ACK vs cancel,
 *     ACK vs expire, dual authenticated ACKs, old-ACK vs recipient rebinding,
 *     ACK vs storage failure, cancel vs expire, markHanded vs cancel;
 *   * C6.4-M: mutation controls -- weakening the state / mode / recipient WHERE
 *     predicate (stateGuard / modeGuard / recipientGuard = false) PROVABLY breaks
 *     the concurrency guarantees, so each predicate is load-bearing, not
 *     decorative.
 *
 * Mirrors the iOS `SqliteDeliveryRepositoryTests`.
 */
class SqliteDeliveryRepositoryTest {

    private val rng = SecureRandom()

    private fun msgId(seed: Byte) = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }
    private fun nodeA() = ByteArray(16) { 0x01 }
    private fun nodeB() = ByteArray(16) { 0x02 }

    /** Resolver binding two distinct node ids to two distinct keys (C2 test). */
    private class TwoRecipientResolver(
        val a: ByteArray, val pubA: ByteArray,
        val b: ByteArray, val pubB: ByteArray,
    ) : RecipientKeyResolver {
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? = when {
            nodeId.contentEquals(a) -> pubA
            nodeId.contentEquals(b) -> pubB
            else -> null
        }
    }

    private fun open(file: File): SqliteDeliveryRepository = SqliteDeliveryRepository(JdbcStoreDb(file))

    private fun realKeypair(): Pair<ByteArray, ByteArray> {
        val kp = Ed25519Keys.generate(rng)
        return kp.pub to kp.priv
    }

    private fun found(j: DeliveryRepository, mid: ByteArray): DeliveryRecord =
        (j.get(mid) as DeliveryLookup.Found).record

    /** State via the typed [DeliveryTracker.lookup] seam (C6.4-B: state() is gone). */
    private fun stateOf(tracker: DeliveryTracker, mid: ByteArray): DeliveryState? =
        when (val l = tracker.lookup(mid)) {
            is DeliveryLookup.Found -> l.record.state
            else -> null
        }

    /**
     * Raw persisted state code straight from the row, BYPASSING the repository's
     * binding-consistency guard. A corrupt-binding row (ack_mode mutated past the
     * CHECK so NONE carries a non-null recipient) is still a row with a `state`
     * column; the production [SqliteDeliveryRepository.get] correctly fails it
     * closed to [DeliveryLookup.Corrupt], so [found] (which force-casts `get`)
     * CANNOT read it. The C6.4-M mode-guard mutation-control test asserts the raw
     * `state` column on such a row to prove the guarded CAS did (or, under the
     * weakened guard, did NOT) mutate it -- mirroring the iOS twin, which asserts
     * only ACK outcomes on the corrupt row and never routes its raw state through
     * the guarded `get`.
     */
    private fun rawStateOf(db: StoreDb, mid: ByteArray): DeliveryState {
        val row = db.readDelivery(mid) ?: error("row ${mid.toList()} absent")
        return DeliveryState.fromPersistedCode(row.state)
            ?: error("row ${mid.toList()} state code ${row.state} not a legal durable state")
    }

    /**
     * Plant a bad state code past the `CHECK (state IN (1,2,3,4,5))` (C6.4-C).
     * The CHECK rejects a plain `UPDATE ... SET state = <bad>`; the
     * `PRAGMA ignore_check_constraints` test seam lets the bad write through so
     * the decode guard ([DeliveryState.fromPersistedCode], rejects 0/unknown) is
     * exercised -- a row that bypassed the CHECK fails closed to Corrupt at read.
     */
    private fun plantBadState(db: JdbcStoreDb, mid: ByteArray, code: Int) {
        db.execRawSql("PRAGMA ignore_check_constraints = ON")
        db.execRawUpdate(
            "UPDATE ${StoreSchema.DELIVERY_TABLE} SET ${StoreSchema.COL_D_STATE} = $code " +
                "WHERE ${StoreSchema.COL_D_MSG_ID} = ?",
            mid,
        )
        db.execRawSql("PRAGMA ignore_check_constraints = OFF")
    }

    /**
     * Plant a corrupt binding (ack_mode=0 + non-null recipient) past the binding
     * CHECK, for the C6.4-M modeGuard mutation control (a NONE-mode row that still
     * carries a recipient is corrupt; only reachable by bypassing the CHECK).
     */
    private fun plantCorruptBinding(db: JdbcStoreDb, mid: ByteArray, recipient: ByteArray) {
        db.execRawSql("PRAGMA ignore_check_constraints = ON")
        db.execRawUpdate(
            "UPDATE ${StoreSchema.DELIVERY_TABLE} SET ${StoreSchema.COL_D_ACK_MODE} = 0 " +
                "WHERE ${StoreSchema.COL_D_MSG_ID} = ?",
            mid,
        )
        db.execRawSql("PRAGMA ignore_check_constraints = OFF")
    }

    // ------------------------------------------------------------------
    // C6.3 baseline (migrated to the C6.4 API): enqueue / transition / ACK / clear
    // ------------------------------------------------------------------

    @Test
    fun `enqueue creates a QUEUED_DURABLY row with the ack mode and recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(1)
            assertEquals(DeliveryLookup.NotFound, j.get(mid))
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            val rec = found(j, mid)
            assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
            assertEquals(AckMode.SINGLE_RECIPIENT, rec.ackMode)
            assertEquals(nodeA().toList(), rec.expectedRecipientNodeId?.toList())
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a NONE-mode enqueue binds no recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(2)
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.NONE, null))
            val rec = found(j, mid)
            assertEquals(AckMode.NONE, rec.ackMode)
            assertNull(rec.expectedRecipientNodeId)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a second enqueue for the same msg_id is idempotent on the same binding and does not mutate the recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(3)
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(EnqueueResult.AlreadyQueuedSameBinding,
                j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(EnqueueResult.ConflictRecipient,
                j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeB()))
            val rec = found(j, mid)
            assertEquals(nodeA().toList(), rec.expectedRecipientNodeId?.toList(),
                "duplicate enqueue must not mutate the bound recipient")
            assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `transition and acknowledgeBound advance only the state column, preserving ack_mode and expected_recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(4)
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            // MARK_HANDED: QUEUED -> HANDED (guarded CAS).
            assertEquals(TransitionResult.Applied,
                j.transition(mid, DeliveryTransition.MARK_HANDED))
            assertEquals(DeliveryState.HANDED_TO_RELAY, found(j, mid).state)
            assertEquals(nodeA().toList(), found(j, mid).expectedRecipientNodeId?.toList(),
                "state-only write must preserve the bound expected recipient")
            assertEquals(AckMode.SINGLE_RECIPIENT, found(j, mid).ackMode,
                "state-only write must preserve the ack mode")
            // ACK: HANDED -> ACKNOWLEDGED (guarded CAS binding state+mode+recipient).
            assertEquals(AckResult.Applied, j.acknowledgeBound(mid, nodeA()))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(j, mid).state)
            assertEquals(nodeA().toList(), found(j, mid).expectedRecipientNodeId?.toList(),
                "ACKNOWLEDGED write must preserve the bound expected recipient")
            // transition for an unknown msg_id is UnknownMessage.
            assertEquals(TransitionResult.UnknownMessage,
                j.transition(msgId(99), DeliveryTransition.MARK_HANDED))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `clear drops the row and returns a typed ClearResult`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(5)
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(ClearResult.Cleared, j.clear(mid))
            assertEquals(DeliveryLookup.NotFound, j.get(mid))
            // re-clear is AlreadyAbsent, NOT an error -- a failed destructive op is
            // never indistinguishable from success (C6.4-J).
            assertEquals(ClearResult.AlreadyAbsent, j.clear(mid))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `reboot recovery - a fresh repository over the same DB file recovers state, ack mode and recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val boot1 = open(file)
            val mid = msgId(6)
            assertEquals(EnqueueResult.Created, boot1.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(TransitionResult.Applied,
                boot1.transition(mid, DeliveryTransition.MARK_HANDED))
            assertEquals(DeliveryState.HANDED_TO_RELAY, found(boot1, mid).state)
            val boot2 = open(file)
            val rec = found(boot2, mid)
            assertEquals(DeliveryState.HANDED_TO_RELAY, rec.state, "state recovered after reboot")
            assertEquals(AckMode.SINGLE_RECIPIENT, rec.ackMode, "ack mode recovered after reboot")
            assertEquals(nodeA().toList(), rec.expectedRecipientNodeId?.toList(),
                "expected recipient recovered after reboot")
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C6.4-D / C6.4-C: schema CHECKs (binding + state + 16-byte msg_id)
    // ------------------------------------------------------------------

    @Test
    fun `the schema CHECK enforces the binding, state and 16-byte msg_id invariants at the DB level`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val j = SqliteDeliveryRepository(db)
            val mid = msgId(7)
            // SINGLE_RECIPIENT with a NULL recipient violates the binding CHECK.
            assertCheckRejects(db, mid, DeliveryState.QUEUED_DURABLY.code, AckMode.SINGLE_RECIPIENT.code, null,
                "SINGLE_RECIPIENT + null recipient")
            // NONE with a recipient also violates the binding CHECK.
            assertCheckRejects(db, mid, DeliveryState.QUEUED_DURABLY.code, AckMode.NONE.code, ByteArray(16),
                "NONE + recipient")
            // A short (non-16-byte) recipient violates the binding CHECK.
            assertCheckRejects(db, mid, DeliveryState.QUEUED_DURABLY.code, AckMode.SINGLE_RECIPIENT.code, ByteArray(8),
                "short recipient")
            // C6.4-C: a persisted state code 0 (UNAVAILABLE) violates state CHECK.
            assertCheckRejects(db, mid, 0, AckMode.NONE.code, null, "state = 0 (UNAVAILABLE)")
            // C6.4-C: an unknown state code (999) violates state CHECK.
            assertCheckRejects(db, mid, 999, AckMode.NONE.code, null, "state = 999 (unknown)")
            // C6.4-D: a non-16-byte msg_id violates the length CHECK.
            try {
                db.insertDelivery(ByteArray(8), DeliveryState.QUEUED_DURABLY.code, AckMode.NONE.code, null)
                error("expected CHECK violation for a non-16-byte msg_id")
            } catch (e: java.sql.SQLException) {
                // expected: length(msg_id) = 16 CHECK rejects an 8-byte id
            }
            assertEquals(DeliveryLookup.NotFound, j.get(mid), "no row written on any CHECK violation")
        } finally {
            file.delete()
        }
    }

    private fun assertCheckRejects(
        db: JdbcStoreDb, mid: ByteArray, state: Int, ackMode: Int, recipient: ByteArray?, label: String,
    ) {
        try {
            db.insertDelivery(mid, state, ackMode, recipient)
            error("expected CHECK violation for $label")
        } catch (e: java.sql.SQLException) {
            // expected
        }
    }

    // ------------------------------------------------------------------
    // C6.4-D: 16-byte msg_id at every delivery boundary
    // ------------------------------------------------------------------

    @Test
    fun `a non-16-byte msg_id is InvalidArgument at every delivery boundary`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val recipient = nodeA()
            val badSizes = listOf(0, 8, 15, 17, 64)
            for (size in badSizes) {
                val bad = ByteArray(size)
                assertEquals(DeliveryLookup.InvalidArgument, j.get(bad),
                    "get with a $size-byte msg_id must be InvalidArgument")
                assertEquals(EnqueueResult.InvalidArgument, j.enqueue(bad, AckMode.SINGLE_RECIPIENT, recipient),
                    "enqueue with a $size-byte msg_id must be InvalidArgument")
                assertEquals(TransitionResult.InvalidArgument, j.transition(bad, DeliveryTransition.MARK_HANDED),
                    "transition with a $size-byte msg_id must be InvalidArgument")
                assertEquals(TransitionResult.InvalidArgument, j.transition(bad, DeliveryTransition.EXPIRE),
                    "expire with a $size-byte msg_id must be InvalidArgument")
                assertEquals(TransitionResult.InvalidArgument, j.transition(bad, DeliveryTransition.CANCEL),
                    "cancel with a $size-byte msg_id must be InvalidArgument")
                assertEquals(AckResult.InvalidArgument, j.acknowledgeBound(bad, recipient),
                    "acknowledgeBound with a $size-byte msg_id must be InvalidArgument")
                assertEquals(ClearResult.InvalidArgument, j.clear(bad),
                    "clear with a $size-byte msg_id must be InvalidArgument")
            }
            // And a 16-byte recipient is required for acknowledgeBound (a non-16
            // recipient is InvalidArgument too, NOT a SQL error).
            val mid = msgId(11)
            assertEquals(AckResult.InvalidArgument, j.acknowledgeBound(mid, ByteArray(8)),
                "acknowledgeBound with a non-16-byte recipient must be InvalidArgument")
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C6.4.1-BCDEFG: fail-closed store schema version + migration. Mirrors the
    // iOS StoreSchema runMigrations tests. The JDBC engine now version-gates
    // the open (no unconditional CREATE IF NOT EXISTS): a FUTURE user_version
    // throws (no silent downgrade); a current-version file is DDL-fingerprint
    // validated (a tampered / hand-edited file with the right stamp but wrong
    // DDL is rejected); a stale version is transactionally recreated.
    // ------------------------------------------------------------------

    @Test
    fun `a future user_version is rejected fail-closed and left untouched`() {
        val file = Files.createTempFile("godstone-delivery-future", ".db").toFile()
        try {
            // Pre-stamp a FUTURE version (999 > DB_VERSION=6) and create the
            // current tables so the only rejection reason is the version.
            val direct = DriverManager.getConnection("jdbc:sqlite:" + file.absolutePath)
            direct.createStatement().use { it.execute(StoreSchema.CREATE_SQL) }
            direct.createStatement().use { it.execute(StoreSchema.CREATE_DELIVERY_SQL) }
            direct.createStatement().use { it.execute("PRAGMA user_version = 999") }
            direct.close()
            // Opening must FAIL CLOSED (no silent downgrade to DB_VERSION).
            try {
                JdbcStoreDb(file)
                error("expected future-version open to fail closed")
            } catch (e: IllegalStateException) {
                // expected: refusing to open future store schema
            }
            // The file is NOT touched by the failed open: user_version is still
            // 999 (no silent downgrade / no recreate).
            val check = DriverManager.getConnection("jdbc:sqlite:" + file.absolutePath)
            check.prepareStatement("PRAGMA user_version").use { ps ->
                ps.executeQuery().use { rs ->
                    assertEquals(999, rs.getInt(1), "future user_version must be left untouched")
                }
            }
            check.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a malformed current-version schema is rejected fail-closed`() {
        val file = Files.createTempFile("godstone-delivery-malformed", ".db").toFile()
        try {
            // Stamp the CURRENT version but create held_frames with the WRONG
            // DDL (no NOT NULL, no CHECK) -- a tampered / hand-edited file with
            // the right version stamp but the wrong schema. delivery_state is
            // created correctly so the failure is specifically the held_frames
            // DDL-fingerprint mismatch.
            val direct = DriverManager.getConnection("jdbc:sqlite:" + file.absolutePath)
            direct.createStatement().use {
                it.execute("CREATE TABLE ${StoreSchema.TABLE} (${StoreSchema.COL_MSG_ID} BLOB PRIMARY KEY, ${StoreSchema.COL_TYPE} INTEGER)")
            }
            direct.createStatement().use { it.execute(StoreSchema.CREATE_DELIVERY_SQL) }
            direct.createStatement().use { it.execute("PRAGMA user_version = ${StoreSchema.DB_VERSION}") }
            direct.close()
            // Opening must FAIL CLOSED: validateSchema reads sqlite_master and
            // the held_frames DDL fingerprint does not match CREATE_SQL.
            try {
                JdbcStoreDb(file)
                error("expected malformed-current-version open to fail closed")
            } catch (e: IllegalStateException) {
                // expected: store schema validation: DDL mismatch for held_frames
            }
        } finally {
            file.delete()
        }
    }

    @Test
    fun `msg_id NULL and length boundaries are rejected by both tables at the raw SQL level`() {
        val file = Files.createTempFile("godstone-delivery-msgid", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            // C6.4.1-G: the explicit NOT NULL on msg_id (plus the existing
            // CHECK (length(msg_id) = 16)) rejects a NULL msg_id at the raw
            // SQL level on BOTH tables. execRawSql runs literal SQL (no
            // binding); a NULL insert throws a SQLException.
            try {
                db.execRawSql("INSERT INTO ${StoreSchema.TABLE} (${StoreSchema.COL_MSG_ID}, ${StoreSchema.COL_TYPE}) VALUES (NULL, 1)")
                error("expected NOT NULL violation for a NULL held_frames msg_id")
            } catch (e: java.sql.SQLException) {
                // expected: msg_id NOT NULL / length(NULL) = NULL != 16
            }
            try {
                db.execRawSql(
                    "INSERT INTO ${StoreSchema.DELIVERY_TABLE} (${StoreSchema.COL_D_MSG_ID}, ${StoreSchema.COL_D_STATE}, ${StoreSchema.COL_D_ACK_MODE}, ${StoreSchema.COL_D_EXPECTED}) " +
                        "VALUES (NULL, 1, 0, NULL)"
                )
                error("expected NOT NULL violation for a NULL delivery_state msg_id")
            } catch (e: java.sql.SQLException) {
                // expected
            }
            // C6.4-D: non-16-byte msg_id is rejected by the length CHECK on
            // BOTH tables (execRawUpdate throws on the constraint violation).
            val badSizes = listOf(0, 8, 15, 17, 64)
            for (size in badSizes) {
                val bad = ByteArray(size)
                try {
                    db.execRawUpdate(
                        "INSERT INTO ${StoreSchema.TABLE} (${StoreSchema.COL_MSG_ID}, ${StoreSchema.COL_TYPE}) VALUES (?, 1)",
                        bad,
                    )
                    error("expected length CHECK violation for a $size-byte held_frames msg_id")
                } catch (e: java.sql.SQLException) {
                    // expected
                }
                try {
                    db.execRawUpdate(
                        "INSERT INTO ${StoreSchema.DELIVERY_TABLE} (${StoreSchema.COL_D_MSG_ID}, ${StoreSchema.COL_D_STATE}, ${StoreSchema.COL_D_ACK_MODE}, ${StoreSchema.COL_D_EXPECTED}) " +
                            "VALUES (?, 1, 0, NULL)",
                        bad,
                    )
                    error("expected length CHECK violation for a $size-byte delivery_state msg_id")
                } catch (e: java.sql.SQLException) {
                    // expected
                }
            }
            // A 16-byte msg_id is accepted on BOTH tables (raw insert into
            // held_frames succeeds; enqueue creates a delivery_state row).
            val ok = ByteArray(16) { (it + 42).toByte() }
            assertEquals(1, db.execRawUpdate(
                "INSERT INTO ${StoreSchema.TABLE} (${StoreSchema.COL_MSG_ID}, ${StoreSchema.COL_TYPE}) VALUES (?, 1)",
                ok,
            ), "16-byte held_frames msg_id accepted")
            val j = SqliteDeliveryRepository(db)
            assertEquals(EnqueueResult.Created, j.enqueue(ok, AckMode.NONE, null),
                "16-byte delivery_state msg_id accepted")
            db.close()
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C6.5 / C6.4-C: unknown persisted states fail closed (NOT UNAVAILABLE)
    // ------------------------------------------------------------------

    @Test
    fun `an unknown persisted state code reads as Corrupt, not UNAVAILABLE`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val j = SqliteDeliveryRepository(db)
            val mid = msgId(8)
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            plantBadState(db, mid, 999)
            assertEquals(DeliveryLookup.Corrupt, j.get(mid),
                "an unknown state code must fail closed to Corrupt, NOT UNAVAILABLE")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a persisted state code 0 (UNAVAILABLE) reads as Corrupt and cannot be silently revived`() {
        // C6.4-C: UNAVAILABLE (code 0) is NOT a legal durable row. The schema CHECK
        // rejects a write of 0; a row planted past the CHECK (ignore_check_constraints)
        // fails closed to Corrupt at read, and every mutation over it fails closed
        // (no silent revival to a fresh QUEUED row).
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val j = SqliteDeliveryRepository(db)
            val mid = msgId(9)
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            plantBadState(db, mid, 0) // persisted UNAVAILABLE -- corrupt
            assertEquals(DeliveryLookup.Corrupt, j.get(mid),
                "a persisted state 0 (UNAVAILABLE) must fail closed to Corrupt")
            // enqueue over a corrupt row cannot silently revive it.
            assertEquals(EnqueueResult.Corrupt, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            // ACK / transition over a corrupt row fail closed.
            assertEquals(AckResult.Corrupt, j.acknowledgeBound(mid, nodeA()))
            assertEquals(TransitionResult.Corrupt, j.transition(mid, DeliveryTransition.MARK_HANDED))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `an unknown ack_mode code decodes to null (fail-closed)`() {
        assertNull(AckMode.fromCode(999))
        assertNull(AckMode.fromCode(-1))
        assertEquals(AckMode.NONE, AckMode.fromCode(0))
        assertEquals(AckMode.SINGLE_RECIPIENT, AckMode.fromCode(1))
    }

    @Test
    fun `a tracker over a corrupt record rejects every mutation and never reports UNAVAILABLE`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val j = SqliteDeliveryRepository(db)
            val mid = msgId(10)
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            plantBadState(db, mid, 999)
            val tracker = DeliveryTracker(j, Ed25519AckAuthenticator(TwoRecipientResolver(nodeA(), ByteArray(32), nodeB(), ByteArray(32))))
            // C6.4-B: a corrupt row is Corrupt at the lookup seam, NOT UNAVAILABLE.
            assertEquals(DeliveryLookup.Corrupt, tracker.lookup(mid),
                "corrupt reads as Corrupt at the lookup seam, NOT UNAVAILABLE")
            assertNull(stateOf(tracker, mid), "a corrupt row has no typed state")
            assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(AckResult.Corrupt, tracker.acknowledge(mid,
                FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))))
            assertEquals(TransitionResult.Corrupt, tracker.markHandedToRelay(mid))
            // forget (clear) over a corrupt row: the row still physically exists, so
            // the DELETE matches 1 -> Cleared (clear is the one way out of corrupt).
            assertEquals(ClearResult.Cleared, tracker.forget(mid))
            assertEquals(DeliveryLookup.NotFound, tracker.lookup(mid))
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C6.4-A: REAL StorageFailure classification (absence/conflict/no-match != failure)
    // ------------------------------------------------------------------

    /**
     * Wraps a [StoreDb] to (a) synchronize the delivery primitives so two threads
     * can share one JDBC connection safely in the concurrency tests, and (b)
     * inject a SQL exception into a delivery primitive on demand so a storage
     * failure is a REAL, deterministic outcome (C6.4-A). The held-frames
     * primitives are delegated directly (the delivery tests do not exercise them
     * under concurrency). [PersistResult] / [DeliveryRow] / [StoreDb] are
     * `internal` to `:mesh`; this test class lives in the same module.
     */
    private class FaultingStoreDb(private val inner: StoreDb) : StoreDb {
        private val lock = Any()
        @Volatile var faultReadDelivery = false
        @Volatile var faultInsertDelivery = false
        @Volatile var faultExecDeliveryUpdate = false

        override fun insert(frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long): Long =
            inner.insert(frame, receivedFrom, receivedAt)
        override fun contains(msgId: ByteArray): Boolean = inner.contains(msgId)
        override fun heldBytes(): Long = inner.heldBytes()
        override fun evictOldestPrefix(overshoot: Long) = inner.evictOldestPrefix(overshoot)
        override fun forEachRowOrderedByPriority(visit: (io.godstone.mesh.store.StoreRow) -> Boolean) =
            inner.forEachRowOrderedByPriority(visit)
        override fun forEachMsgId(visit: (ByteArray) -> Boolean) = inner.forEachMsgId(visit)
        override fun inTransaction(block: (StoreDb) -> PersistResult): PersistResult = inner.inTransaction(block)

        override fun readDelivery(msgId: ByteArray): DeliveryRow? = synchronized(lock) {
            if (faultReadDelivery) throw java.sql.SQLException("injected readDelivery fault")
            inner.readDelivery(msgId)
        }

        override fun insertDelivery(
            msgId: ByteArray, stateOrdinal: Int, ackModeOrdinal: Int, expectedRecipient: ByteArray?,
        ): Boolean = synchronized(lock) {
            if (faultInsertDelivery) throw java.sql.SQLException("injected insertDelivery fault")
            inner.insertDelivery(msgId, stateOrdinal, ackModeOrdinal, expectedRecipient)
        }

        override fun execDeliveryUpdate(sql: String, bytesArgs: Array<ByteArray?>): Int = synchronized(lock) {
            if (faultExecDeliveryUpdate) throw java.sql.SQLException("injected execDeliveryUpdate fault")
            inner.execDeliveryUpdate(sql, bytesArgs)
        }

        override fun execRawSql(sql: String) = synchronized(lock) { inner.execRawSql(sql) }
        override fun close() = inner.close()
    }

    @Test
    fun `a read failure is StorageFailure at the get and lookup seams, distinct from NotFound`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val inner = JdbcStoreDb(file)
            val wrapped = FaultingStoreDb(inner)
            val j = SqliteDeliveryRepository(wrapped)
            val mid = msgId(20)
            // Absence (no fault) is NotFound -- never StorageFailure.
            assertEquals(DeliveryLookup.NotFound, j.get(mid), "absence is NotFound, not a failure")
            // A read fault is StorageFailure -- never NotFound.
            wrapped.faultReadDelivery = true
            assertEquals(DeliveryLookup.StorageFailure, j.get(mid),
                "a read failure must be StorageFailure, not folded into NotFound")
            val tracker = DeliveryTracker(j, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
            assertEquals(DeliveryLookup.StorageFailure, tracker.lookup(mid))
            assertEquals(AckResult.StorageFailure, tracker.acknowledge(mid,
                FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `an enqueue read or insert failure is EnqueueResult StorageFailure`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // Read fault inside enqueue (enqueue calls get -> readDelivery).
            val w1 = FaultingStoreDb(JdbcStoreDb(file))
            val j1 = SqliteDeliveryRepository(w1)
            w1.faultReadDelivery = true
            assertEquals(EnqueueResult.StorageFailure, j1.enqueue(msgId(21), AckMode.SINGLE_RECIPIENT, nodeA()),
                "an enqueue read failure must be StorageFailure")
            // Insert fault inside enqueue (get -> NotFound -> insertDelivery faults).
            val w2 = FaultingStoreDb(JdbcStoreDb(file))
            val j2 = SqliteDeliveryRepository(w2)
            w2.faultInsertDelivery = true
            assertEquals(EnqueueResult.StorageFailure, j2.enqueue(msgId(22), AckMode.SINGLE_RECIPIENT, nodeA()),
                "an enqueue insert failure must be StorageFailure")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a transition CAS failure is TransitionResult StorageFailure`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val wrapped = FaultingStoreDb(JdbcStoreDb(file))
            val j = SqliteDeliveryRepository(wrapped)
            wrapped.faultExecDeliveryUpdate = true
            assertEquals(TransitionResult.StorageFailure, j.transition(msgId(23), DeliveryTransition.MARK_HANDED),
                "a transition SQL failure must be StorageFailure")
            assertEquals(TransitionResult.StorageFailure, j.transition(msgId(23), DeliveryTransition.EXPIRE))
            assertEquals(TransitionResult.StorageFailure, j.transition(msgId(23), DeliveryTransition.CANCEL))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `an ACK CAS failure is AckResult StorageFailure`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val wrapped = FaultingStoreDb(JdbcStoreDb(file))
            val j = SqliteDeliveryRepository(wrapped)
            wrapped.faultExecDeliveryUpdate = true
            assertEquals(AckResult.StorageFailure,
                j.acknowledgeBound(msgId(24), nodeA()),
                "an ACK CAS SQL failure must be StorageFailure")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a clear failure is ClearResult StorageFailure`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val wrapped = FaultingStoreDb(JdbcStoreDb(file))
            val j = SqliteDeliveryRepository(wrapped)
            wrapped.faultExecDeliveryUpdate = true
            assertEquals(ClearResult.StorageFailure, j.clear(msgId(25)),
                "a clear SQL failure must be StorageFailure, not AlreadyAbsent")
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C6.4-F/G/H: real guarded SQL CAS (decided by affected row count, not a
    // stale pre-read). Sequential ordering proofs (no threads needed -- the CAS
    // is state-based); the interleaving proofs are in the concurrency section.
    // ------------------------------------------------------------------

    @Test
    fun `a transition to the current state is AlreadyInTarget, not a fresh transition`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(30)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            assertEquals(TransitionResult.Applied, j.transition(mid, DeliveryTransition.MARK_HANDED))
            // Re-marking handed: state is already HANDED -> AlreadyInTarget (no mutation).
            assertEquals(TransitionResult.AlreadyInTarget, j.transition(mid, DeliveryTransition.MARK_HANDED))
            assertEquals(DeliveryState.HANDED_TO_RELAY, found(j, mid).state)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a terminal state rejects further non-ACK transitions`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(31)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            assertEquals(TransitionResult.Applied, j.transition(mid, DeliveryTransition.CANCEL))
            // CANCELLED -> markHanded is RejectedState (no transition out of terminal).
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.MARK_HANDED))
            // CANCELLED -> expire is RejectedState (CANCELLED not in (QUEUED, HANDED)).
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.EXPIRE))
            // AlreadyInTarget from CANCELLED via cancel.
            assertEquals(TransitionResult.AlreadyInTarget, j.transition(mid, DeliveryTransition.CANCEL))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(j, mid).state)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `an ACK after a cancel is RejectedState - the CAS does not overwrite the terminal state`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(32)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED) // HANDED
            j.transition(mid, DeliveryTransition.CANCEL)      // CANCELLED
            // The ACK CAS requires state IN (QUEUED, HANDED); CANCELLED(5) is not -> 0
            // rows -> re-read CANCELLED -> RejectedState. The terminal state survives.
            assertEquals(AckResult.RejectedState, j.acknowledgeBound(mid, nodeA()))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(j, mid).state)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a cancel after an ACK is RejectedState - ACKNOWLEDGED is irreversible`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(33)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED)
            assertEquals(AckResult.Applied, j.acknowledgeBound(mid, nodeA()))
            // ACKNOWLEDGED(3) not in (QUEUED, HANDED) -> cancel CAS 0 rows -> RejectedState.
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.CANCEL))
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.EXPIRE))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(j, mid).state)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `an ACK with the wrong recipient is UnknownMessage - an old ACK never binds to a re-bound row`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(34)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED)
            // Rebind: clear + re-enqueue to Bob.
            assertEquals(ClearResult.Cleared, j.clear(mid))
            assertEquals(EnqueueResult.Created, j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeB()))
            // Alice's old ACK CAS: expected=nodeA but row is nodeB -> 0 rows -> re-read
            // -> binding changed -> UnknownMessage. Bob's row is untouched.
            assertEquals(AckResult.UnknownMessage, j.acknowledgeBound(mid, nodeA()))
            val rec = found(j, mid)
            assertEquals(nodeB().toList(), rec.expectedRecipientNodeId?.toList())
            assertEquals(DeliveryState.QUEUED_DURABLY, rec.state, "Bob's fresh row stays QUEUED")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a duplicate authenticated ACK is DuplicateAuthenticatedAck, not Applied`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(35)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED)
            assertEquals(AckResult.Applied, j.acknowledgeBound(mid, nodeA()))
            // A second authenticated ACK: state is already ACKNOWLEDGED with the SAME
            // binding -> CAS 0 rows -> re-read ACKNOWLEDGED same binding -> Duplicate.
            assertEquals(AckResult.DuplicateAuthenticatedAck,
                j.acknowledgeBound(mid, nodeA()))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(j, mid).state)
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C6.4-L: deterministic concurrency (controlled synchronization, NOT
    // probabilistic thread races). A blocking authenticator + latches interleave
    // the ACK's get/verify/acknowledgeBound so the CAS race is exact. The
    // [FaultingStoreDb] synchronizes the delivery primitives so two threads share
    // one JDBC connection safely (serialization preserves the 0-row classification).
    // ------------------------------------------------------------------

    /** Authenticator that signals it reached verify, then blocks for release. */
    private class BlockingAuthenticator : AckAuthenticator {
        val reached = CountDownLatch(1)
        val release = CountDownLatch(1)
        @Volatile var result = true
        override fun verify(originalMsgId: ByteArray, expectedRecipientNodeId: ByteArray, ackFrame: FrameV2): Boolean {
            reached.countDown()
            release.await(5, TimeUnit.SECONDS)
            return result
        }
    }

    /** Authenticator whose two verify calls meet at a barrier, then both proceed (dual-ACK race). */
    private class DualAckAuthenticator : AckAuthenticator {
        val barrier = CyclicBarrier(2)
        override fun verify(originalMsgId: ByteArray, expectedRecipientNodeId: ByteArray, ackFrame: FrameV2): Boolean {
            barrier.await(5, TimeUnit.SECONDS)
            return true
        }
    }

    private fun newSyncRepo(file: File): Pair<FaultingStoreDb, SqliteDeliveryRepository> {
        val wrapped = FaultingStoreDb(JdbcStoreDb(file))
        return wrapped to SqliteDeliveryRepository(wrapped)
    }

    @Test
    fun `concurrency - ACK vs cancel - cancel wins, ACK is RejectedState, final is CANCELLED`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (wrapped, j) = newSyncRepo(file)
            val auth = BlockingAuthenticator()
            val tracker = DeliveryTracker(j, auth)
            val mid = msgId(40)
            tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            tracker.markHandedToRelay(mid) // HANDED
            val (_, privA) = realKeypair()
            val ack = AckFrame.build(mid, privA, nodeA(), routingTag)
            val ackResult = AtomicReference<AckResult?>(null)
            val t = Thread { ackResult.set(tracker.acknowledge(mid, ack)) }
            t.start()
            // ACK has read the HANDED binding + entered verify (blocks here).
            assertTrue(auth.reached.await(2, TimeUnit.SECONDS), "ACK reached verify")
            // While the ACK is blocked in verify, cancel wins the row.
            assertEquals(TransitionResult.Applied, tracker.cancel(mid), "cancel applies while ACK is in verify")
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid))
            // Release the ACK: its CAS sees CANCELLED (not in (1,2)) -> RejectedState.
            auth.release.countDown()
            t.join()
            assertEquals(AckResult.RejectedState, ackResult.get(),
                "ACK that lost the CAS to a cancel must be RejectedState, NOT Applied")
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid),
                "final state is CANCELLED -- the ACK did not overwrite it")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `concurrency - ACK vs expire - expire wins, ACK is RejectedState, final is EXPIRED`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (wrapped, j) = newSyncRepo(file)
            val auth = BlockingAuthenticator()
            val tracker = DeliveryTracker(j, auth)
            val mid = msgId(41)
            tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            tracker.markHandedToRelay(mid)
            val (_, privA) = realKeypair()
            val ack = AckFrame.build(mid, privA, nodeA(), routingTag)
            val ackResult = AtomicReference<AckResult?>(null)
            val t = Thread { ackResult.set(tracker.acknowledge(mid, ack)) }
            t.start()
            assertTrue(auth.reached.await(2, TimeUnit.SECONDS))
            assertEquals(TransitionResult.Applied, tracker.expire(mid), "expire applies while ACK is in verify")
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid))
            auth.release.countDown()
            t.join()
            assertEquals(AckResult.RejectedState, ackResult.get())
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `concurrency - two authenticated ACKs - exactly one Applied, one DuplicateAuthenticatedAck, final ACKNOWLEDGED`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (wrapped, j) = newSyncRepo(file)
            val auth = DualAckAuthenticator()
            val tracker = DeliveryTracker(j, auth)
            val mid = msgId(42)
            tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            tracker.markHandedToRelay(mid)
            val (_, privA) = realKeypair()
            val ack = AckFrame.build(mid, privA, nodeA(), routingTag)
            val r1 = AtomicReference<AckResult?>(null)
            val r2 = AtomicReference<AckResult?>(null)
            val t1 = Thread { r1.set(tracker.acknowledge(mid, ack)) }
            val t2 = Thread { r2.set(tracker.acknowledge(mid, ack)) }
            t1.start(); t2.start()
            t1.join(); t2.join()
            val results = listOf(r1.get(), r2.get())
            assertEquals(1, results.count { it == AckResult.Applied }, "exactly one ACK wins the CAS")
            assertEquals(1, results.count { it == AckResult.DuplicateAuthenticatedAck },
                "exactly one ACK is a duplicate (lost the CAS, same binding)")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `concurrency - old Alice ACK vs recipient rebinding to Bob - ACK is UnknownMessage, Bob row unchanged`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (wrapped, j) = newSyncRepo(file)
            val auth = BlockingAuthenticator()
            val tracker = DeliveryTracker(j, auth)
            val mid = msgId(43)
            tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            tracker.markHandedToRelay(mid)
            val (_, privA) = realKeypair()
            val ack = AckFrame.build(mid, privA, nodeA(), routingTag)
            val ackResult = AtomicReference<AckResult?>(null)
            val t = Thread { ackResult.set(tracker.acknowledge(mid, ack)) }
            t.start()
            assertTrue(auth.reached.await(2, TimeUnit.SECONDS), "Alice ACK reached verify against Alice binding")
            // While Alice's ACK is blocked in verify, rebind the row to Bob.
            assertEquals(ClearResult.Cleared, tracker.forget(mid))
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeB()))
            auth.release.countDown()
            t.join()
            assertEquals(AckResult.UnknownMessage, ackResult.get(),
                "Alice's old ACK must not bind to a re-bound (Bob) row")
            val rec = found(j, mid)
            assertEquals(nodeB().toList(), rec.expectedRecipientNodeId?.toList(), "Bob's row is unchanged")
            assertEquals(DeliveryState.QUEUED_DURABLY, rec.state, "Bob's row stays QUEUED")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `concurrency - ACK vs storage failure - auth succeeds, CAS faults, state NOT acknowledged`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (wrapped, j) = newSyncRepo(file)
            val auth = BlockingAuthenticator()
            val tracker = DeliveryTracker(j, auth)
            val mid = msgId(44)
            tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            tracker.markHandedToRelay(mid) // succeeds (no fault yet)
            // Arm the CAS fault so the ACK's acknowledgeBound throws -> StorageFailure.
            wrapped.faultExecDeliveryUpdate = true
            val (_, privA) = realKeypair()
            val ack = AckFrame.build(mid, privA, nodeA(), routingTag)
            val ackResult = AtomicReference<AckResult?>(null)
            val t = Thread { ackResult.set(tracker.acknowledge(mid, ack)) }
            t.start()
            assertTrue(auth.reached.await(2, TimeUnit.SECONDS), "ACK authenticated before the CAS fault")
            auth.release.countDown()
            t.join()
            assertEquals(AckResult.StorageFailure, ackResult.get(),
                "an ACK whose CAS faults is StorageFailure, NOT Applied")
            // The state must NOT be ACKNOWLEDGED (the CAS threw before committing).
            wrapped.faultExecDeliveryUpdate = false
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid),
                "state unchanged after a CAS storage failure")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `concurrency - cancel vs expire - exactly one terminal CAS Applied, other RejectedState, final is one terminal`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (_, j) = newSyncRepo(file)
            val tracker = DeliveryTracker(j, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
            val mid = msgId(45)
            tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            tracker.markHandedToRelay(mid) // HANDED (both cancel+expire valid from HANDED)
            val r1 = AtomicReference<TransitionResult?>(null)
            val r2 = AtomicReference<TransitionResult?>(null)
            val t1 = Thread { r1.set(tracker.cancel(mid)) }
            val t2 = Thread { r2.set(tracker.expire(mid)) }
            t1.start(); t2.start()
            t1.join(); t2.join()
            val results = listOf(r1.get(), r2.get())
            assertEquals(1, results.count { it == TransitionResult.Applied }, "exactly one terminal CAS applies")
            assertEquals(1, results.count { it == TransitionResult.RejectedState },
                "the other loses the CAS to a terminal -> RejectedState")
            val s = stateOf(tracker, mid)
            assertTrue(s == DeliveryState.CANCELLED_LOCALLY || s == DeliveryState.EXPIRED,
                "final state is exactly one terminal, was $s")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `concurrency - markHanded vs cancel - either order legal, no transition moves OUT of terminal`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(46)
            // Order 1: markHanded then cancel (both apply; CANCELLED is terminal).
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            assertEquals(TransitionResult.Applied, j.transition(mid, DeliveryTransition.MARK_HANDED))
            assertEquals(TransitionResult.Applied, j.transition(mid, DeliveryTransition.CANCEL))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(j, mid).state)
            // Invariant: no transition moves OUT of terminal. markHanded from
            // CANCELLED -> RejectedState (CANCELLED not in (QUEUED,)).
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.MARK_HANDED))
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.EXPIRE))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(j, mid).state, "still CANCELLED -- no move out")

            // Order 2: cancel from QUEUED then markHanded (cancel applies; markHanded
            // rejected -- CANCELLED not in (QUEUED,)).
            val mid2 = msgId(47)
            j.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeB())
            assertEquals(TransitionResult.Applied, j.transition(mid2, DeliveryTransition.CANCEL))
            assertEquals(TransitionResult.RejectedState, j.transition(mid2, DeliveryTransition.MARK_HANDED))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(j, mid2).state)
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C6.4-M: CAS mutation controls. Each guard (state / mode / recipient) is
    // dropped in turn via the test constructor and PROVEN load-bearing: the
    // weakened predicate lets the wrong outcome through, so the production
    // predicate (all guards on) is what makes the concurrency guarantees hold.
    // ------------------------------------------------------------------

    @Test
    fun `mutation control - dropping the state guard lets an ACK overwrite a CANCELLED row (proves it is load-bearing)`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // Production repo (state guard ON): ACK after cancel -> RejectedState.
            val j = open(file)
            val mid = msgId(50)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED)
            j.transition(mid, DeliveryTransition.CANCEL) // CANCELLED
            assertEquals(AckResult.RejectedState, j.acknowledgeBound(mid, nodeA()),
                "with the state guard ON, an ACK after cancel is RejectedState")
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(j, mid).state)

            // Weakened repo (state guard OFF): the ACK CAS no longer guards state,
            // so it matches on msg_id + mode + recipient only and OVERWRITES CANCELLED
            // with ACKNOWLEDGED. This is the WRONG outcome the guard prevents.
            val dbWeak = JdbcStoreDb(file)
            val jWeak = MutatedDeliveryRepository(dbWeak, stateGuard = false, modeGuard = true, recipientGuard = true)
            val mid2 = msgId(51)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            jWeak.transition(mid2, DeliveryTransition.MARK_HANDED)
            jWeak.transition(mid2, DeliveryTransition.CANCEL) // CANCELLED
            assertEquals(AckResult.Applied,
                jWeak.acknowledgeBound(mid2, nodeA()),
                "with the state guard OFF, the ACK overwrites CANCELLED -> Applied (WRONG)")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(jWeak, mid2).state,
                "the weakened guard let the ACK reverse a terminal state (WRONG)")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `mutation control - dropping the recipient guard lets an old ACK bind to a re-bound row (proves it is load-bearing)`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // Production repo (recipient guard ON): Alice's ACK vs Bob's row -> UnknownMessage.
            val j = open(file)
            val mid = msgId(52)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED)
            j.clear(mid)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeB()) // re-bound to Bob, QUEUED
            assertEquals(AckResult.UnknownMessage, j.acknowledgeBound(mid, nodeA()),
                "with the recipient guard ON, Alice's ACK does not bind to Bob's row")
            assertEquals(DeliveryState.QUEUED_DURABLY, found(j, mid).state)

            // Weakened repo (recipient guard OFF): the ACK CAS no longer checks
            // expected_recipient, so Alice's ACK matches Bob's row (msg_id + state +
            // mode) and acknowledges it -> Applied (WRONG: Alice acked Bob's message).
            val dbWeak = JdbcStoreDb(file)
            val jWeak = MutatedDeliveryRepository(dbWeak, stateGuard = true, modeGuard = true, recipientGuard = false)
            val mid2 = msgId(53)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            jWeak.transition(mid2, DeliveryTransition.MARK_HANDED)
            jWeak.clear(mid2)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeB()) // re-bound to Bob
            assertEquals(AckResult.Applied,
                jWeak.acknowledgeBound(mid2, nodeA()),
                "with the recipient guard OFF, Alice's ACK binds to Bob's row -> Applied (WRONG)")
            val rec = found(jWeak, mid2)
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, rec.state,
                "the weakened guard let the wrong sender acknowledge the row (WRONG)")
            assertEquals(nodeB().toList(), rec.expectedRecipientNodeId?.toList(),
                "the recipient column is unchanged, but the state advanced from the wrong sender")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `mutation control - dropping the mode guard lets an ACK land on a NONE-mode row (proves it is load-bearing)`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // Plant a corrupt row: SINGLE binding but ack_mode mutated to NONE (0)
            // past the binding CHECK. This is the only row the mode predicate
            // distinguishes from a legitimate SINGLE row at the SQL level.
            val db = JdbcStoreDb(file)
            val j = SqliteDeliveryRepository(db)
            val mid = msgId(54)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()) // SINGLE, nodeA, QUEUED
            j.transition(mid, DeliveryTransition.MARK_HANDED) // HANDED
            plantCorruptBinding(db, mid, nodeA()) // ack_mode=0 (NONE), recipient=nodeA (CHECK bypassed)

            // Production repo (mode guard ON): the ACK CAS requires ack_mode=1, but
            // the row is 0 -> 0 rows -> re-read -> binding inconsistent (NONE + non-null
            // recipient) -> Corrupt. Fail closed.
            assertEquals(AckResult.Corrupt, j.acknowledgeBound(mid, nodeA()),
                "with the mode guard ON, an ACK on a NONE-mode (corrupt) row fails closed to Corrupt")
            assertEquals(DeliveryState.HANDED_TO_RELAY, rawStateOf(db, mid), "state unchanged")

            // Weakened repo (mode guard OFF): the ACK CAS no longer checks ack_mode,
            // so it matches on msg_id + state + recipient and acknowledges the
            // NONE-mode row -> Applied (WRONG: a NONE/broadcast row was acknowledged).
            val jWeak = MutatedDeliveryRepository(db, stateGuard = true, modeGuard = false, recipientGuard = true)
            val mid2 = msgId(55)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            jWeak.transition(mid2, DeliveryTransition.MARK_HANDED)
            plantCorruptBinding(db, mid2, nodeA())
            assertEquals(AckResult.Applied,
                jWeak.acknowledgeBound(mid2, nodeA()),
                "with the mode guard OFF, an ACK lands on a NONE-mode row -> Applied (WRONG)")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, rawStateOf(db, mid2),
                "the weakened guard let a NONE-mode row be acknowledged (WRONG)")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `mutation control - dropping the transition state guard lets a cancel overwrite an ACKNOWLEDGED row`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // Production repo (state guard ON): cancel after ACK -> RejectedState.
            val j = open(file)
            val mid = msgId(56)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED)
            j.acknowledgeBound(mid, nodeA()) // ACKNOWLEDGED
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.CANCEL),
                "with the state guard ON, cancel after ACK is RejectedState")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(j, mid).state)

            // Weakened repo (state guard OFF): cancel's CAS no longer guards state, so
            // it overwrites ACKNOWLEDGED with CANCELLED (WRONG: reversed a terminal).
            val dbWeak = JdbcStoreDb(file)
            val jWeak = MutatedDeliveryRepository(dbWeak, stateGuard = false, modeGuard = true, recipientGuard = true)
            val mid2 = msgId(57)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            jWeak.transition(mid2, DeliveryTransition.MARK_HANDED)
            jWeak.acknowledgeBound(mid2, nodeA()) // ACKNOWLEDGED
            assertEquals(TransitionResult.Applied, jWeak.transition(mid2, DeliveryTransition.CANCEL),
                "with the state guard OFF, cancel overwrites ACKNOWLEDGED -> Applied (WRONG)")
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(jWeak, mid2).state,
                "the weakened guard reversed a terminal state (WRONG)")
        } finally {
            file.delete()
        }
    }

    // ------------------------------------------------------------------
    // C1/C2 integration + fail-closed production composition
    // ------------------------------------------------------------------

    @Test
    fun `DeliveryTracker over SqliteDeliveryRepository binds the ACK to the durable expected recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (pubA, privA) = realKeypair()
            val (pubB, privB) = realKeypair()
            val resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
            val tracker = DeliveryTracker(open(file), Ed25519AckAuthenticator(resolver))

            val mid = msgId(70)
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            val ackA = AckFrame.build(mid, privA, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker.acknowledge(mid, ackA),
                "ACK from the bound recipient A must verify over the durable repository")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))

            val mid2 = msgId(71)
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA()))
            tracker.markHandedToRelay(mid2)
            val ackB = AckFrame.build(mid2, privB, nodeB(), routingTag)
            assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid2, ackB),
                "ACK from a valid but unintended recipient must not verify over the durable repository")
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid2))

            // A NONE-mode message is NotAckEligible -- the authenticator is NOT invoked.
            val mid3 = msgId(72)
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid3, AckMode.NONE, null))
            tracker.markHandedToRelay(mid3)
            assertEquals(AckResult.NotAckEligible, tracker.acknowledge(mid3, ackA),
                "a NONE-mode message is never ACK-eligible")
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid3))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `production composition is fail-closed under the unresolved resolver`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val journal = open(file)
            val tracker = DeliveryTracker(journal, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
            val (_, priv) = realKeypair()
            val recipient = ByteArray(16) { 0x07 }
            val mid = msgId(80)
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            val ack = AckFrame.build(mid, priv, recipient, routingTag)
            assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, ack),
                "unresolved production resolver must reject every ACK -- no delivery claimed without a bound key")
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertEquals(recipient.toList(), found(journal, mid).expectedRecipientNodeId?.toList())
        } finally {
            file.delete()
        }
    }

    // ==================================================================
    // C6.7.1 Logical Message Identity & Delivery State Collision Tests
    // ==================================================================

    @Test
    fun `case 1 - alice and bob concurrent sends with same content and time coexist as distinct rows`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)

            val sender = ByteArray(16) { 0x01 }
            val timestamp = 1700000000L
            val plaintext = "medical supply update".toByteArray()

            val nonceA = ByteArray(16) { 0x11 }
            val nonceB = ByteArray(16) { 0x22 }
            val aliceNode = ByteArray(16) { 0xAA.toByte() }
            val bobNode = ByteArray(16) { 0xBB.toByte() }

            val msgIdA = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, nonceA, plaintext)
            val msgIdB = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, nonceB, plaintext)

            // Distinct logical msg_ids
            kotlin.test.assertNotEquals(msgIdA.toList(), msgIdB.toList())

            // Enqueue both
            assertEquals(EnqueueResult.Created, repo.enqueue(msgIdA, AckMode.SINGLE_RECIPIENT, aliceNode))
            assertEquals(EnqueueResult.Created, repo.enqueue(msgIdB, AckMode.SINGLE_RECIPIENT, bobNode))

            // Both rows exist independently with their respective recipient bindings
            val recA = (repo.get(msgIdA) as DeliveryLookup.Found).record
            val recB = (repo.get(msgIdB) as DeliveryLookup.Found).record

            assertEquals(aliceNode.toList(), recA.expectedRecipientNodeId?.toList())
            assertEquals(bobNode.toList(), recB.expectedRecipientNodeId?.toList())
            assertEquals(DeliveryState.QUEUED_DURABLY, recA.state)
            assertEquals(DeliveryState.QUEUED_DURABLY, recB.state)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `case 2 - two distinct logical sends to same recipient with same content coexist`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)

            val sender = ByteArray(16) { 0x01 }
            val timestamp = 1700000000L
            val plaintext = "repeated status report".toByteArray()
            val recipientAlice = ByteArray(16) { 0xAA.toByte() }

            val nonce1 = ByteArray(16) { 0x33 }
            val nonce2 = ByteArray(16) { 0x44 }

            val msgId1 = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, nonce1, plaintext)
            val msgId2 = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, nonce2, plaintext)

            kotlin.test.assertNotEquals(msgId1.toList(), msgId2.toList())

            assertEquals(EnqueueResult.Created, repo.enqueue(msgId1, AckMode.SINGLE_RECIPIENT, recipientAlice))
            assertEquals(EnqueueResult.Created, repo.enqueue(msgId2, AckMode.SINGLE_RECIPIENT, recipientAlice))

            val rec1 = (repo.get(msgId1) as DeliveryLookup.Found).record
            val rec2 = (repo.get(msgId2) as DeliveryLookup.Found).record

            assertEquals(recipientAlice.toList(), rec1.expectedRecipientNodeId?.toList())
            assertEquals(recipientAlice.toList(), rec2.expectedRecipientNodeId?.toList())
        } finally {
            file.delete()
        }
    }

    @Test
    fun `case 3 - retry with same logical identity produces same msg_id and is idempotent`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)

            val sender = ByteArray(16) { 0x01 }
            val timestamp = 1700000000L
            val plaintext = "idempotent retry message".toByteArray()
            val nonce = ByteArray(16) { 0x55 }
            val recipient = ByteArray(16) { 0xCC.toByte() }

            val msgIdOriginal = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, nonce, plaintext)
            val msgIdRetry = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, nonce, plaintext)

            assertEquals(msgIdOriginal.toList(), msgIdRetry.toList())

            // Initial enqueue creates the row
            assertEquals(EnqueueResult.Created, repo.enqueue(msgIdOriginal, AckMode.SINGLE_RECIPIENT, recipient))

            // Re-enqueue for the same logical message is idempotent
            assertEquals(EnqueueResult.AlreadyQueuedSameBinding, repo.enqueue(msgIdRetry, AckMode.SINGLE_RECIPIENT, recipient))

            val rec = (repo.get(msgIdOriginal) as DeliveryLookup.Found).record
            assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
            assertEquals(recipient.toList(), rec.expectedRecipientNodeId?.toList())
        } finally {
            file.delete()
        }
    }

    @Test
    fun `case 4 - ack isolation acknowledging msgIdA does not alter delivery state of msgIdB`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)

            val (pubA, privA) = realKeypair()
            val (pubB, privB) = realKeypair()
            val resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(resolver))

            val sender = ByteArray(16) { 0x01 }
            val timestamp = 1700000000L
            val plaintext = "coordinated delivery message".toByteArray()

            val msgIdA = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, ByteArray(16) { 0x66 }, plaintext)
            val msgIdB = io.godstone.mesh.wire.v2.MessageId.derive(sender, timestamp, ByteArray(16) { 0x77 }, plaintext)

            assertEquals(EnqueueResult.Created, tracker.enqueue(msgIdA, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(EnqueueResult.Created, tracker.enqueue(msgIdB, AckMode.SINGLE_RECIPIENT, nodeB()))

            tracker.markHandedToRelay(msgIdA)
            tracker.markHandedToRelay(msgIdB)

            // Acknowledge msgIdA
            val ackA = AckFrame.build(msgIdA, privA, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker.acknowledge(msgIdA, ackA))

            // msgIdA is ACKNOWLEDGED_BY_RECIPIENT, but msgIdB MUST still be HANDED_TO_RELAY
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, msgIdA))
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, msgIdB))
        } finally {
            file.delete()
        }
    }
}