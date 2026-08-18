package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.store.DeliveryRow
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.store.StoreDb
import io.godstone.mesh.store.StoreSchema
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.router.Router
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.runBlocking
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
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
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
    private fun msgId(seed: Int) = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }
    private fun nodeA() = ByteArray(16) { 0x01 }
    private fun nodeB() = ByteArray(16) { 0x02 }

    /** Resolver binding a single node id to a key. */
    private class SingleRecipientResolver(
        val expectedNodeId: ByteArray, val pubKey: ByteArray,
    ) : RecipientKeyResolver {
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? =
            if (nodeId.contentEquals(expectedNodeId)) pubKey else null
    }

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

    private class NeverInvokeAuthenticator : AckAuthenticator {
        override fun verify(originalMsgId: ByteArray, expectedRecipientNodeId: ByteArray, ackFrame: FrameV2): Boolean {
            throw AssertionError("NeverInvokeAuthenticator must not be invoked")
        }
    }

    private fun open(file: File): SqliteDeliveryRepository = SqliteDeliveryRepository(JdbcStoreDb(file))

    private fun realKeypair(): Pair<ByteArray, ByteArray> {
        val kp = Ed25519Keys.generate(rng)
        return kp.pub to kp.priv
    }

    private fun found(j: DeliveryRepository, mid: ByteArray): DeliveryRecord =
        (j.get(mid) as DeliveryLookup.Found).record

    private fun plantHeld(file: File, mid: ByteArray) {
        val db = JdbcStoreDb(file)
        try {
            val f = FrameV2(TypeV2.MESSAGE, mid, routingTag, 10, 0, 0, ByteArray(32))
            db.insert(f, ByteArray(0), 100L)
        } finally {
            db.close()
        }
    }

    private fun plantHeld(db: StoreDb, mid: ByteArray) {
        val f = FrameV2(TypeV2.MESSAGE, mid, routingTag, 10, 0, 0, ByteArray(32))
        db.insert(f, ByteArray(0), 100L)
    }

    private fun directFrame(
        seed: Byte,
        payloadSize: Int = 80,
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
            msgId = msgIdOverride ?: msgId(seed.toInt()),
            routingTag = routingTag,
            ttl = 12,
            hopCount = 0,
            flags = flags,
            payload = ByteArray(payloadSize) { seed },
        )
    }

    private fun localNode(seed: Byte = 0x10): ByteArray = ByteArray(16) { (seed.toInt() + it).toByte() }

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
            // ACK: HANDED -> ACKNOWLEDGED (guarded CAS binding state+mode+recipient + held retirement).
            plantHeld(file, mid)
            assertEquals(AckResult.Applied, j.acknowledgeBoundAndRetire(mid, nodeA()))
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
                assertEquals(AckResult.InvalidArgument, j.acknowledgeBoundAndRetire(bad, recipient),
                    "acknowledgeBoundAndRetire with a $size-byte msg_id must be InvalidArgument")
                assertEquals(ClearResult.InvalidArgument, j.clear(bad),
                    "clear with a $size-byte msg_id must be InvalidArgument")
            }
            // And a 16-byte recipient is required for acknowledgeBoundAndRetire (a non-16
            // recipient is InvalidArgument too, NOT a SQL error).
            val mid = msgId(11)
            assertEquals(AckResult.InvalidArgument, j.acknowledgeBoundAndRetire(mid, ByteArray(8)),
                "acknowledgeBoundAndRetire with a non-16-byte recipient must be InvalidArgument")
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
            assertEquals(AckResult.Corrupt, j.acknowledgeBoundAndRetire(mid, nodeA()))
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
        @Volatile var faultDeleteHeld = false
        @Volatile var faultAfterAckCas: (() -> Unit)? = null
        @Volatile var faultAfterTerminalCas: (() -> Unit)? = null
        @Volatile var faultAfterHeldDelete: (() -> Unit)? = null

        override fun insert(frame: FrameV2, receivedFrom: ByteArray, receivedAt: Long): Long =
            inner.insert(frame, receivedFrom, receivedAt)
        override fun readHeld(msgId: ByteArray): io.godstone.mesh.store.StoreRow? = inner.readHeld(msgId)
        override fun contains(msgId: ByteArray): Boolean = inner.contains(msgId)
        override fun heldBytes(): Long = inner.heldBytes()
        override fun evictOldestPrefix(overshoot: Long) = inner.evictOldestPrefix(overshoot)
        override fun forEachRowOrderedByPriority(visit: (io.godstone.mesh.store.StoreRow) -> Boolean) =
            inner.forEachRowOrderedByPriority(visit)
        override fun forEachMsgId(visit: (ByteArray) -> Boolean) = inner.forEachMsgId(visit)
        override fun <T> inTransaction(block: (StoreDb) -> T): T = inner.inTransaction { block(this) }

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
            val res = inner.execDeliveryUpdate(sql, bytesArgs)
            faultAfterAckCas?.invoke()
            faultAfterTerminalCas?.invoke()
            res
        }

        override fun deleteHeld(msgId: ByteArray): Int = synchronized(lock) {
            if (faultDeleteHeld) throw java.sql.SQLException("injected deleteHeld fault")
            val res = inner.deleteHeld(msgId)
            faultAfterHeldDelete?.invoke()
            res
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
                j.acknowledgeBoundAndRetire(msgId(24), nodeA()),
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
            plantHeld(file, mid)
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
            plantHeld(file, mid)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED) // HANDED
            j.transition(mid, DeliveryTransition.CANCEL)      // CANCELLED
            // The ACK CAS requires state IN (QUEUED, HANDED); CANCELLED(5) is not -> 0
            // rows -> re-read CANCELLED -> RejectedState. The terminal state survives.
            assertEquals(AckResult.RejectedState, j.acknowledgeBoundAndRetire(mid, nodeA()))
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
            plantHeld(file, mid)
            assertEquals(AckResult.Applied, j.acknowledgeBoundAndRetire(mid, nodeA()))
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
            assertEquals(AckResult.UnknownMessage, j.acknowledgeBoundAndRetire(mid, nodeA()))
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
            plantHeld(file, mid)
            assertEquals(AckResult.Applied, j.acknowledgeBoundAndRetire(mid, nodeA()))
            // A second authenticated ACK: state is already ACKNOWLEDGED with the SAME
            // binding -> CAS 0 rows -> re-read ACKNOWLEDGED same binding -> Duplicate.
            assertEquals(AckResult.DuplicateAuthenticatedAck,
                j.acknowledgeBoundAndRetire(mid, nodeA()))
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
            plantHeld(wrapped, mid)
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
            plantHeld(wrapped, mid)
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
            plantHeld(wrapped, mid)
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
            plantHeld(wrapped, mid)
            // Arm the CAS fault so the ACK's acknowledgeBoundAndRetire throws -> StorageFailure.
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
            val (wrapped, j) = newSyncRepo(file)
            val tracker = DeliveryTracker(j, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
            val mid = msgId(45)
            plantHeld(wrapped, mid)
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
            plantHeld(file, mid)
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
            plantHeld(file, mid2)
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
            plantHeld(file, mid)
            j.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            j.transition(mid, DeliveryTransition.MARK_HANDED)
            j.transition(mid, DeliveryTransition.CANCEL) // CANCELLED
            assertEquals(AckResult.RejectedState, j.acknowledgeBoundAndRetire(mid, nodeA()),
                "with the state guard ON, an ACK after cancel is RejectedState")
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(j, mid).state)

            // Weakened repo (state guard OFF): the ACK CAS no longer guards state,
            // so it matches on msg_id + mode + recipient only and OVERWRITES CANCELLED
            // with ACKNOWLEDGED. This is the WRONG outcome the guard prevents.
            val dbWeak = JdbcStoreDb(file)
            val jWeak = MutatedDeliveryRepository(dbWeak, stateGuard = false, modeGuard = true, recipientGuard = true)
            val mid2 = msgId(51)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            plantHeld(dbWeak, mid2)
            jWeak.transition(mid2, DeliveryTransition.MARK_HANDED)
            jWeak.transition(mid2, DeliveryTransition.CANCEL) // CANCELLED
            assertEquals(AckResult.Applied,
                jWeak.acknowledgeBoundAndRetire(mid2, nodeA()),
                "with the state guard OFF, the ACK overwrites CANCELLED -> Applied (WRONG)")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(jWeak, mid2).state,
                "the weakened guard let the ACK reverse a terminal state (WRONG)")
            assertFalse(dbWeak.contains(mid2), "held frame deleted on ACK retirement")
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
            assertEquals(AckResult.UnknownMessage, j.acknowledgeBoundAndRetire(mid, nodeA()),
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
            plantHeld(dbWeak, mid2)
            assertEquals(AckResult.Applied,
                jWeak.acknowledgeBoundAndRetire(mid2, nodeA()),
                "with the recipient guard OFF, Alice's ACK binds to Bob's row -> Applied (WRONG)")
            val rec = found(jWeak, mid2)
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, rec.state,
                "the weakened guard let the wrong sender acknowledge the row (WRONG)")
            assertEquals(nodeB().toList(), rec.expectedRecipientNodeId?.toList(),
                "the recipient column is unchanged, but the state advanced from the wrong sender")
            assertFalse(dbWeak.contains(mid2), "held frame deleted on ACK retirement")
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
            assertEquals(AckResult.Corrupt, j.acknowledgeBoundAndRetire(mid, nodeA()),
                "with the mode guard ON, an ACK on a NONE-mode (corrupt) row fails closed to Corrupt")
            assertEquals(DeliveryState.HANDED_TO_RELAY, rawStateOf(db, mid), "state unchanged")

            // Weakened repo (mode guard OFF): the ACK CAS no longer checks ack_mode,
            // so it matches on msg_id + state + recipient and acknowledges the
            // NONE-mode row -> Applied (WRONG: a NONE/broadcast row was acknowledged).
            val jWeak = MutatedDeliveryRepository(db, stateGuard = true, modeGuard = false, recipientGuard = true)
            val mid2 = msgId(55)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            plantHeld(db, mid2)
            jWeak.transition(mid2, DeliveryTransition.MARK_HANDED)
            plantCorruptBinding(db, mid2, nodeA())
            assertEquals(AckResult.Applied,
                jWeak.acknowledgeBoundAndRetire(mid2, nodeA()),
                "with the mode guard OFF, an ACK lands on a NONE-mode row -> Applied (WRONG)")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, rawStateOf(db, mid2),
                "the weakened guard let a NONE-mode row be acknowledged (WRONG)")
            assertFalse(db.contains(mid2), "held frame deleted on ACK retirement")
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
            plantHeld(file, mid)
            assertEquals(AckResult.Applied, j.acknowledgeBoundAndRetire(mid, nodeA()))
            assertEquals(TransitionResult.RejectedState, j.transition(mid, DeliveryTransition.CANCEL),
                "with the state guard ON, cancel after ACK is RejectedState")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(j, mid).state)

            // Weakened repo (state guard OFF): cancel's CAS no longer guards state, so
            // it overwrites ACKNOWLEDGED with CANCELLED (WRONG: reversed a terminal).
            val dbWeak = JdbcStoreDb(file)
            val jWeak = MutatedDeliveryRepository(dbWeak, stateGuard = false, modeGuard = true, recipientGuard = true)
            val mid2 = msgId(57)
            jWeak.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            plantHeld(dbWeak, mid2)
            jWeak.transition(mid2, DeliveryTransition.MARK_HANDED)
            assertEquals(AckResult.Applied, jWeak.acknowledgeBoundAndRetire(mid2, nodeA())) // ACKNOWLEDGED
            assertEquals(TransitionResult.Applied, jWeak.transition(mid2, DeliveryTransition.CANCEL),
                "with the state guard OFF, cancel overwrites ACKNOWLEDGED -> Applied (WRONG)")
            assertEquals(DeliveryState.CANCELLED_LOCALLY, found(jWeak, mid2).state,
                "the weakened guard reversed a terminal state (WRONG)")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `mutation control - skipping held retirement leaves split state (proves atomic held retirement is load-bearing)`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val jWeak = MutatedDeliveryRepository(db, skipHeldRetirement = true)
            val mid = msgId(58)
            jWeak.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA())
            plantHeld(db, mid)
            jWeak.transition(mid, DeliveryTransition.MARK_HANDED)

            // Mutant ACK succeeds at updating delivery_state but SKIPS held deletion
            assertEquals(AckResult.Applied, jWeak.acknowledgeBoundAndRetire(mid, nodeA()))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(jWeak, mid).state)
            assertTrue(db.contains(mid), "MUTANT leaves split state: delivery ACKNOWLEDGED but held frame STILL EXISTS")

            // In contrast, production repository atomically retires held frame
            val mid2 = msgId(59)
            val strong = SqliteDeliveryRepository(db)
            strong.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA())
            plantHeld(db, mid2)
            strong.transition(mid2, DeliveryTransition.MARK_HANDED)

            assertEquals(AckResult.Applied, strong.acknowledgeBoundAndRetire(mid2, nodeA()))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(strong, mid2).state)
            assertFalse(db.contains(mid2), "production atomically deletes held frame")
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
            plantHeld(file, mid)
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
            plantHeld(db, msgIdA)
            val ackA = AckFrame.build(msgIdA, privA, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker.acknowledge(msgIdA, ackA))

            // msgIdA is ACKNOWLEDGED_BY_RECIPIENT, but msgIdB MUST still be HANDED_TO_RELAY
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, msgIdA))
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, msgIdB))
        } finally {
            file.delete()
        }
    }

    // ==================================================================
    // C7.4.1: Atomic Authenticated ACK Commit + Held-Frame Retirement Matrix
    // ==================================================================

    @Test
    fun `C7_4_1 production-shaped queued C6_6 to C7_4 success`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db1 = JdbcStoreDb(file)
            val store1 = SqliteMessageStore(db1, maxBytes = 4096L)
            val repo1 = SqliteDeliveryRepository(db1)
            val (pub, priv) = realKeypair()
            val tracker1 = DeliveryTracker(repo1, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))
            val mid = msgId(150)
            val canonicalFrame = directFrame(1, payloadSize = 80, msgIdOverride = mid)

            val enqueueRes = store1.enqueueDirectOutbound(canonicalFrame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1))
            assertEquals(OutboundEnqueueResult.Created(canonicalFrame), enqueueRes)

            // Before ACK: held row exists, delivery row is QUEUED_DURABLY
            assertTrue(db1.contains(mid))
            val dBefore = db1.readDelivery(mid)
            assertNotNull(dBefore)
            assertEquals(DeliveryState.QUEUED_DURABLY.code, dBefore.state)
            assertEquals(AckMode.SINGLE_RECIPIENT.code, dBefore.ackMode)
            assertTrue(nodeA().contentEquals(dBefore.expectedRecipient))
            val heldBefore = db1.readHeld(mid)
            assertNotNull(heldBefore)
            assertEquals(canonicalFrame, heldBefore.toFrame())

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker1.acknowledge(mid, ack))

            // Close & reopen from disk file
            db1.close()
            val db2 = JdbcStoreDb(file)
            val store2 = SqliteMessageStore(db2, maxBytes = 4096L)
            val repo2 = SqliteDeliveryRepository(db2)
            val tracker2 = DeliveryTracker(repo2, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))

            // After reopen: delivery state is ACKNOWLEDGED, recipient preserved, held row absent
            val dAfter = db2.readDelivery(mid)
            assertNotNull(dAfter)
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code, dAfter.state)
            assertEquals(AckMode.SINGLE_RECIPIENT.code, dAfter.ackMode)
            assertTrue(nodeA().contentEquals(dAfter.expectedRecipient))
            assertFalse(db2.contains(mid), "held frame must be absent after ACK retirement")
            assertNull(db2.readHeld(mid))
            db2.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 production-shaped handed C6_6 to C7_4 success`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db1 = JdbcStoreDb(file)
            val store1 = SqliteMessageStore(db1, maxBytes = 4096L)
            val repo1 = SqliteDeliveryRepository(db1)
            val (pub, priv) = realKeypair()
            val tracker1 = DeliveryTracker(repo1, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))
            val mid = msgId(151)
            val canonicalFrame = directFrame(2, payloadSize = 80, msgIdOverride = mid)

            val enqueueRes = store1.enqueueDirectOutbound(canonicalFrame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1))
            assertEquals(OutboundEnqueueResult.Created(canonicalFrame), enqueueRes)
            assertEquals(TransitionResult.Applied, tracker1.markHandedToRelay(mid))

            // Before ACK: held row exists, delivery row is HANDED_TO_RELAY
            assertTrue(db1.contains(mid))
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker1, mid))

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker1.acknowledge(mid, ack))

            // Close & reopen from disk file
            db1.close()
            val db2 = JdbcStoreDb(file)
            val store2 = SqliteMessageStore(db2, maxBytes = 4096L)
            val repo2 = SqliteDeliveryRepository(db2)
            val tracker2 = DeliveryTracker(repo2, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))

            // After reopen: delivery state is ACKNOWLEDGED, recipient preserved, held row absent
            val dAfter = db2.readDelivery(mid)
            assertNotNull(dAfter)
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code, dAfter.state)
            assertTrue(nodeA().contentEquals(dAfter.expectedRecipient))
            assertFalse(db2.contains(mid), "held frame must be absent after ACK retirement")
            assertNull(db2.readHeld(mid))
            db2.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 rejected authentication held retained`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val (_, privB) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(152)
            val canonicalFrame = directFrame(3, payloadSize = 80, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(canonicalFrame),
                store.enqueueDirectOutbound(canonicalFrame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            val badAck = AckFrame.build(mid, privB, nodeA(), routingTag) // signed with wrong key
            assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, badAck))

            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(db.contains(mid), "held frame must be retained on auth rejection")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 not ack eligible NONE mode held retained`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val tracker = DeliveryTracker(repo, NeverInvokeAuthenticator())
            val mid = msgId(153)

            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.NONE, null))
            plantHeld(db, mid)
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            val dummyAck = FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))
            assertEquals(AckResult.NotAckEligible, tracker.acknowledge(mid, dummyAck))

            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(db.contains(mid), "held frame must be retained for NONE mode")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 missing-held active row rollback and Corrupt`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val (pub, priv) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))
            val mid = msgId(154)

            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            // Note: NO plantHeld -- held frame is missing!

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.Corrupt, tracker.acknowledge(mid, ack))

            // Transaction rolled back -> state remains HANDED_TO_RELAY
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 fault after ACK CAS both restored`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val rawDb = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(rawDb)
            val repo = SqliteDeliveryRepository(faulting)
            val (pub, priv) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))
            val mid = msgId(155)

            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            plantHeld(rawDb, mid)
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            faulting.faultAfterAckCas = { throw java.sql.SQLException("simulated fault after ACK CAS") }

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.StorageFailure, tracker.acknowledge(mid, ack))

            // Both restored
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(rawDb.contains(mid))
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 fault after held DELETE both restored`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val rawDb = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(rawDb)
            val repo = SqliteDeliveryRepository(faulting)
            val (pub, priv) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))
            val mid = msgId(156)

            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            plantHeld(rawDb, mid)
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            faulting.faultAfterHeldDelete = { throw java.sql.SQLException("simulated fault after held delete") }

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.StorageFailure, tracker.acknowledge(mid, ack))

            // Both restored
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(rawDb.contains(mid))
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 held delete SQL failure yields StorageFailure and rolls back`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val rawDb = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(rawDb)
            val repo = SqliteDeliveryRepository(faulting)
            val (pub, priv) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))
            val mid = msgId(157)

            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            plantHeld(rawDb, mid)
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            faulting.faultDeleteHeld = true

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.StorageFailure, tracker.acknowledge(mid, ack))

            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(rawDb.contains(mid))
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 sequential duplicate ACK short-circuits without re-auth`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val (pub, priv) = realKeypair()
            var authCallCount = 0
            val countingAuth = object : AckAuthenticator {
                val delegate = Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub))
                override fun verify(originalMsgId: ByteArray, expectedRecipientNodeId: ByteArray, ackFrame: FrameV2): Boolean {
                    authCallCount++
                    return delegate.verify(originalMsgId, expectedRecipientNodeId, ackFrame)
                }
            }
            val tracker = DeliveryTracker(repo, countingAuth)
            val mid = msgId(158)

            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            plantHeld(db, mid)
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker.acknowledge(mid, ack))
            assertEquals(1, authCallCount)
            assertFalse(db.contains(mid))

            // Second ACK short-circuits without re-invoking authenticator
            val bogusAck = FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))
            assertEquals(AckResult.AlreadyAcknowledged, tracker.acknowledge(mid, bogusAck))
            assertEquals(1, authCallCount, "authenticator must not be invoked for already acknowledged record")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 duplicate authenticated race one Applied one Duplicate`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(db)
            val repo = SqliteDeliveryRepository(faulting)
            val (pub, priv) = realKeypair()
            val recipient = nodeA()
            val auth = DualAckAuthenticator()
            val tracker = DeliveryTracker(repo, auth)
            val mid = msgId(159)

            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
            plantHeld(db, mid)
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            val ack = AckFrame.build(mid, priv, recipient, routingTag)
            val res1 = AtomicReference<AckResult>()
            val res2 = AtomicReference<AckResult>()

            val t1 = Thread { res1.set(tracker.acknowledge(mid, ack)) }
            val t2 = Thread { res2.set(tracker.acknowledge(mid, ack)) }
            t1.start(); t2.start()

            t1.join(5000); t2.join(5000)

            val appliedCount = (if (res1.get() == AckResult.Applied) 1 else 0) + (if (res2.get() == AckResult.Applied) 1 else 0)
            val dupCount = (if (res1.get() == AckResult.DuplicateAuthenticatedAck) 1 else 0) + (if (res2.get() == AckResult.DuplicateAuthenticatedAck) 1 else 0)

            assertEquals(1, appliedCount, "exactly one ACK wins CAS and applies")
            assertEquals(1, dupCount, "the racing duplicate gets DuplicateAuthenticatedAck")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))
            assertFalse(db.contains(mid), "held frame must be deleted by winner")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 production enqueueDirectOutbound after ACK returns RejectedTerminalState`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pub, priv) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pub)))
            val mid = msgId(160)
            val canonicalFrame = directFrame(4, payloadSize = 80, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(canonicalFrame),
                store.enqueueDirectOutbound(canonicalFrame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))

            val ack = AckFrame.build(mid, priv, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker.acknowledge(mid, ack))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))
            assertFalse(db.contains(mid))

            // Re-enqueue for an ACKNOWLEDGED record fails closed via production enqueueDirectOutbound
            val reEnqueue = store.enqueueDirectOutbound(canonicalFrame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1))
            assertEquals(OutboundEnqueueResult.RejectedTerminalState, reEnqueue)
            assertFalse(db.contains(mid), "held frame must remain absent")
            val d = db.readDelivery(mid)
            assertNotNull(d)
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code, d.state)
            assertTrue(nodeA().contentEquals(d.expectedRecipient))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_4_1 capacity released on authenticated ACK is reusable by new frame`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // maxBytes = 200:
            // Frame A: payload 50 + row overhead 64 = 114 bytes <= 200.
            // Frame B: payload 100 + row overhead 64 = 164 bytes.
            // Together: 114 + 164 = 278 > 200.
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 200L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, privA) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))

            val midA = msgId(161)
            val frameA = directFrame(5, payloadSize = 50, msgIdOverride = midA)
            val midB = msgId(162)
            val frameB = directFrame(6, payloadSize = 100, msgIdOverride = midB)

            // 1. Enqueue A succeeds
            assertEquals(OutboundEnqueueResult.Created(frameA),
                store.enqueueDirectOutbound(frameA, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(114L, store.heldBytes())

            // 2. While A is active (QUEUED_DURABLY), B cannot fit and cannot evict A
            assertEquals(OutboundEnqueueResult.RejectedCapacity,
                store.enqueueDirectOutbound(frameB, expectedRecipient = nodeB(), localOriginNodeId = localNode(1)))
            assertEquals(114L, store.heldBytes())

            // 3. Acknowledge and retire A
            val ackA = AckFrame.build(midA, privA, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker.acknowledge(midA, ackA))
            assertEquals(0L, store.heldBytes(), "heldBytes must drop to 0 after A is retired")
            assertFalse(db.contains(midA))

            // 4. Retry B: now succeeds because A's capacity was released!
            assertEquals(OutboundEnqueueResult.Created(frameB),
                store.enqueueDirectOutbound(frameB, expectedRecipient = nodeB(), localOriginNodeId = localNode(1)))
            assertEquals(164L, store.heldBytes())
            assertTrue(db.contains(midB))
            db.close()
        } finally {
            file.delete()
        }
    }

    // ==================================================================
    // C7.5: Atomic EXPIRE/CANCEL held-frame retirement + relay suppression
    // ==================================================================

    @Test
    fun `C7_5 production queued C6_6 to EXPIRE success`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(170)
            val frame = directFrame(1, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))

            assertEquals(TransitionResult.Applied, tracker.expire(mid))
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid))
            assertFalse(db.contains(mid), "held frame must be deleted on EXPIRE")

            val d = db.readDelivery(mid)
            assertNotNull(d)
            assertEquals(DeliveryState.EXPIRED.code, d.state)
            assertTrue(nodeA().contentEquals(d.expectedRecipient))
            db.close()

            // Reopen verification
            val rawDb = JdbcStoreDb(file)
            assertFalse(rawDb.contains(mid), "held frame remains absent across restart")
            val reloaded = rawDb.readDelivery(mid)
            assertNotNull(reloaded)
            assertEquals(DeliveryState.EXPIRED.code, reloaded.state)
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 production handed C6_6 to EXPIRE success`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(171)
            val frame = directFrame(1, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))

            assertEquals(TransitionResult.Applied, tracker.expire(mid))
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid))
            assertFalse(db.contains(mid), "held frame must be deleted on EXPIRE from HANDED state")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 production queued C6_6 to CANCEL success`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(172)
            val frame = directFrame(2, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))

            assertEquals(TransitionResult.Applied, tracker.cancel(mid))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid))
            assertFalse(db.contains(mid), "held frame must be deleted on CANCEL")

            val d = db.readDelivery(mid)
            assertNotNull(d)
            assertEquals(DeliveryState.CANCELLED_LOCALLY.code, d.state)
            assertTrue(nodeA().contentEquals(d.expectedRecipient))
            db.close()

            // Reopen verification
            val rawDb = JdbcStoreDb(file)
            assertFalse(rawDb.contains(mid), "held frame remains absent across restart")
            val reloaded = rawDb.readDelivery(mid)
            assertNotNull(reloaded)
            assertEquals(DeliveryState.CANCELLED_LOCALLY.code, reloaded.state)
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 production handed C6_6 to CANCEL success`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(173)
            val frame = directFrame(2, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))

            assertEquals(TransitionResult.Applied, tracker.cancel(mid))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid))
            assertFalse(db.contains(mid), "held frame must be deleted on CANCEL from HANDED state")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 MARK_HANDED retains held frame`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(174)
            val frame = directFrame(3, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
            assertTrue(db.contains(mid), "MARK_HANDED is state-only and must retain held frame for relay carry")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 missing-held active row rollback and Corrupt on EXPIRE`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(175)

            // Enqueue active delivery row without held frame
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertFalse(db.contains(mid))

            assertEquals(TransitionResult.Corrupt, tracker.expire(mid))
            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid),
                "active delivery state must remain QUEUED_DURABLY after transaction rollback")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 missing-held active row rollback and Corrupt on CANCEL`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(176)

            // Enqueue active delivery row without held frame
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertFalse(db.contains(mid))

            assertEquals(TransitionResult.Corrupt, tracker.cancel(mid))
            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid),
                "active delivery state must remain QUEUED_DURABLY after transaction rollback")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 fault after terminal CAS both restored on EXPIRE`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(db)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(faulting)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(177)
            val frame = directFrame(4, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertTrue(db.contains(mid))

            faulting.faultAfterTerminalCas = { throw java.sql.SQLException("simulated crash after terminal CAS") }
            assertEquals(TransitionResult.StorageFailure, tracker.expire(mid))

            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))
            db.close()

            val rawDb = JdbcStoreDb(file)
            val reloaded = rawDb.readDelivery(mid)
            assertNotNull(reloaded)
            assertEquals(DeliveryState.QUEUED_DURABLY.code, reloaded.state)
            assertTrue(rawDb.contains(mid), "held frame must remain intact after rollback")
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 fault after terminal CAS both restored on CANCEL`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(db)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(faulting)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(178)
            val frame = directFrame(4, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertTrue(db.contains(mid))

            faulting.faultAfterTerminalCas = { throw java.sql.SQLException("simulated crash after terminal CAS") }
            assertEquals(TransitionResult.StorageFailure, tracker.cancel(mid))

            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))
            db.close()

            val rawDb = JdbcStoreDb(file)
            val reloaded = rawDb.readDelivery(mid)
            assertNotNull(reloaded)
            assertEquals(DeliveryState.QUEUED_DURABLY.code, reloaded.state)
            assertTrue(rawDb.contains(mid), "held frame must remain intact after rollback")
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 fault after held DELETE both restored on EXPIRE`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(db)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(faulting)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(179)
            val frame = directFrame(5, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertTrue(db.contains(mid))

            faulting.faultAfterHeldDelete = { throw java.sql.SQLException("simulated crash after held DELETE") }
            assertEquals(TransitionResult.StorageFailure, tracker.expire(mid))

            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))
            db.close()

            val rawDb = JdbcStoreDb(file)
            val reloaded = rawDb.readDelivery(mid)
            assertNotNull(reloaded)
            assertEquals(DeliveryState.QUEUED_DURABLY.code, reloaded.state)
            assertTrue(rawDb.contains(mid), "held frame must remain restored after rollback")
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 fault after held DELETE both restored on CANCEL`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(db)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(faulting)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(180)
            val frame = directFrame(5, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertTrue(db.contains(mid))

            faulting.faultAfterHeldDelete = { throw java.sql.SQLException("simulated crash after held DELETE") }
            assertEquals(TransitionResult.StorageFailure, tracker.cancel(mid))

            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))
            db.close()

            val rawDb = JdbcStoreDb(file)
            val reloaded = rawDb.readDelivery(mid)
            assertNotNull(reloaded)
            assertEquals(DeliveryState.QUEUED_DURABLY.code, reloaded.state)
            assertTrue(rawDb.contains(mid), "held frame must remain restored after rollback")
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 held delete SQL failure yields StorageFailure and rolls back`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val faulting = FaultingStoreDb(db)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(faulting)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(181)
            val frame = directFrame(6, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))

            faulting.faultDeleteHeld = true
            assertEquals(TransitionResult.StorageFailure, tracker.expire(mid))

            assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
            assertTrue(db.contains(mid))
            db.close()

            val rawDb = JdbcStoreDb(file)
            val reloaded = rawDb.readDelivery(mid)
            assertNotNull(reloaded)
            assertEquals(DeliveryState.QUEUED_DURABLY.code, reloaded.state)
            assertTrue(rawDb.contains(mid))
            rawDb.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 idempotent second EXPIRE returns AlreadyInTarget and held remains absent`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(182)
            val frame = directFrame(7, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.expire(mid))
            assertFalse(db.contains(mid))

            assertEquals(TransitionResult.AlreadyInTarget, tracker.expire(mid))
            assertFalse(db.contains(mid), "held frame remains absent")
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 idempotent second CANCEL returns AlreadyInTarget and held remains absent`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(183)
            val frame = directFrame(7, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.cancel(mid))
            assertFalse(db.contains(mid))

            assertEquals(TransitionResult.AlreadyInTarget, tracker.cancel(mid))
            assertFalse(db.contains(mid), "held frame remains absent")
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 cross-terminal rejection EXPIRED then cancel returns RejectedState`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(184)
            val frame = directFrame(8, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.expire(mid))
            assertFalse(db.contains(mid))

            val res = tracker.cancel(mid)
            assertEquals(TransitionResult.RejectedState, res)
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid))
            assertFalse(db.contains(mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 cross-terminal rejection CANCELLED then expire returns RejectedState`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(185)
            val frame = directFrame(8, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.cancel(mid))
            assertFalse(db.contains(mid))

            val res = tracker.expire(mid)
            assertEquals(TransitionResult.RejectedState, res)
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid))
            assertFalse(db.contains(mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 production enqueueDirectOutbound after EXPIRE returns RejectedTerminalState`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(186)
            val frame = directFrame(9, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.expire(mid))
            assertFalse(db.contains(mid))

            val reEnqueue = store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1))
            assertEquals(OutboundEnqueueResult.RejectedTerminalState, reEnqueue)
            assertFalse(db.contains(mid), "held frame must remain absent after terminal rejection")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 production enqueueDirectOutbound after CANCEL returns RejectedTerminalState`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(187)
            val frame = directFrame(9, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.cancel(mid))
            assertFalse(db.contains(mid))

            val reEnqueue = store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1))
            assertEquals(OutboundEnqueueResult.RejectedTerminalState, reEnqueue)
            assertFalse(db.contains(mid), "held frame must remain absent after terminal rejection")
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 ACK vs CANCEL race deterministic real-SQL`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, privA) = realKeypair()
            val auth = BlockingAuthenticator()
            val tracker = DeliveryTracker(repo, auth)
            val mid = msgId(188)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val frame = directFrame(10, payloadSize = 64, msgIdOverride = mid)

            // Arrange HANDED state with held frame present
            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            assertTrue(db.contains(mid))

            val ack = AckFrame.build(mid, privA, nodeA(), routingTag)
            val ackRes = AtomicReference<AckResult?>()
            val t = Thread { ackRes.set(tracker.acknowledge(mid, ack)) }
            t.start()

            // ACK enters verify
            assertTrue(auth.reached.await(2, TimeUnit.SECONDS))
            // Cancel applies while ACK is blocked
            assertEquals(TransitionResult.Applied, tracker.cancel(mid))
            assertFalse(db.contains(mid), "held frame deleted by cancel")

            auth.release.countDown()
            t.join()

            assertEquals(AckResult.RejectedState, ackRes.get())
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid))
            assertFalse(db.contains(mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 ACK vs EXPIRE race deterministic real-SQL`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, privA) = realKeypair()
            val auth = BlockingAuthenticator()
            val tracker = DeliveryTracker(repo, auth)
            val mid = msgId(189)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val frame = directFrame(11, payloadSize = 64, msgIdOverride = mid)

            // Arrange HANDED state with held frame present
            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            assertTrue(db.contains(mid))

            val ack = AckFrame.build(mid, privA, nodeA(), routingTag)
            val ackRes = AtomicReference<AckResult?>()
            val t = Thread { ackRes.set(tracker.acknowledge(mid, ack)) }
            t.start()

            // ACK enters verify
            assertTrue(auth.reached.await(2, TimeUnit.SECONDS))
            // Expire applies while ACK is blocked
            assertEquals(TransitionResult.Applied, tracker.expire(mid))
            assertFalse(db.contains(mid), "held frame deleted by expire")

            auth.release.countDown()
            t.join()

            assertEquals(AckResult.RejectedState, ackRes.get())
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid))
            assertFalse(db.contains(mid))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 CANCEL vs EXPIRE race deterministic real-SQL`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val mid = msgId(190)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val frame = directFrame(12, payloadSize = 64, msgIdOverride = mid)

            assertEquals(OutboundEnqueueResult.Created(frame),
                store.enqueueDirectOutbound(frame, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
            assertTrue(db.contains(mid))

            val rCancel = AtomicReference<TransitionResult?>()
            val rExpire = AtomicReference<TransitionResult?>()
            val t1 = Thread { rCancel.set(tracker.cancel(mid)) }
            val t2 = Thread { rExpire.set(tracker.expire(mid)) }
            t1.start(); t2.start()
            t1.join(5000); t2.join(5000)

            val results = listOf(rCancel.get(), rExpire.get())
            assertEquals(1, results.count { it == TransitionResult.Applied }, "exactly one terminal transition applies")
            assertEquals(1, results.count { it is TransitionResult.RejectedState }, "the loser is rejected with prior state")
            assertFalse(db.contains(mid), "held frame must be absent after race")

            val finalState = stateOf(tracker, mid)
            assertTrue(finalState == DeliveryState.CANCELLED_LOCALLY || finalState == DeliveryState.EXPIRED)
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 anti-entropy excludes retired terminal frame after EXPIRE and CANCEL`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))
            val router = Router(store, localNode(1))

            val midExpire = msgId(191)
            val frameExpire = directFrame(13, payloadSize = 64, msgIdOverride = midExpire)
            val midCancel = msgId(192)
            val frameCancel = directFrame(14, payloadSize = 64, msgIdOverride = midCancel)

            // Enqueue both frames
            assertEquals(OutboundEnqueueResult.Created(frameExpire),
                store.enqueueDirectOutbound(frameExpire, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(OutboundEnqueueResult.Created(frameCancel),
                store.enqueueDirectOutbound(frameCancel, expectedRecipient = nodeB(), localOriginNodeId = localNode(1)))

            // Both present in anti-entropy before retirement
            assertTrue(router.currentDigest().mightContain(midExpire))
            assertTrue(router.currentDigest().mightContain(midCancel))
            val initialLacks = router.framesPeerLacks(BloomDigest())
            assertTrue(initialLacks.any { it.msgId.contentEquals(midExpire) })
            assertTrue(initialLacks.any { it.msgId.contentEquals(midCancel) })

            // 1. Expire midExpire
            assertEquals(TransitionResult.Applied, tracker.expire(midExpire))
            assertFalse(router.currentDigest().mightContain(midExpire), "expired frame must not appear in bloom digest")
            val lacksAfterExpire = router.framesPeerLacks(BloomDigest())
            assertFalse(lacksAfterExpire.any { it.msgId.contentEquals(midExpire) }, "expired frame must not be returned in framesPeerLacks")
            assertTrue(router.currentDigest().mightContain(midCancel))

            // 2. Cancel midCancel
            assertEquals(TransitionResult.Applied, tracker.cancel(midCancel))
            assertFalse(router.currentDigest().mightContain(midCancel), "cancelled frame must not appear in bloom digest")
            val lacksAfterCancel = router.framesPeerLacks(BloomDigest())
            assertFalse(lacksAfterCancel.any { it.msgId.contentEquals(midCancel) }, "cancelled frame must not be returned in framesPeerLacks")

            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 capacity released on EXPIRE is reusable by new frame`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 200L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))

            val midA = msgId(193)
            val frameA = directFrame(15, payloadSize = 50, msgIdOverride = midA)
            val midB = msgId(194)
            val frameB = directFrame(16, payloadSize = 100, msgIdOverride = midB)

            assertEquals(OutboundEnqueueResult.Created(frameA),
                store.enqueueDirectOutbound(frameA, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(114L, store.heldBytes())

            // Frame B rejected due to capacity
            assertEquals(OutboundEnqueueResult.RejectedCapacity,
                store.enqueueDirectOutbound(frameB, expectedRecipient = nodeB(), localOriginNodeId = localNode(1)))

            // Expire A -> releases capacity
            assertEquals(TransitionResult.Applied, tracker.expire(midA))
            assertEquals(0L, store.heldBytes())
            assertFalse(db.contains(midA))

            // B can now enqueue!
            assertEquals(OutboundEnqueueResult.Created(frameB),
                store.enqueueDirectOutbound(frameB, expectedRecipient = nodeB(), localOriginNodeId = localNode(1)))
            assertEquals(164L, store.heldBytes())
            assertTrue(db.contains(midB))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 capacity released on CANCEL is reusable by new frame`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 200L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))

            val midA = msgId(195)
            val frameA = directFrame(17, payloadSize = 50, msgIdOverride = midA)
            val midB = msgId(196)
            val frameB = directFrame(18, payloadSize = 100, msgIdOverride = midB)

            assertEquals(OutboundEnqueueResult.Created(frameA),
                store.enqueueDirectOutbound(frameA, expectedRecipient = nodeA(), localOriginNodeId = localNode(1)))
            assertEquals(114L, store.heldBytes())

            // Frame B rejected due to capacity
            assertEquals(OutboundEnqueueResult.RejectedCapacity,
                store.enqueueDirectOutbound(frameB, expectedRecipient = nodeB(), localOriginNodeId = localNode(1)))

            // Cancel A -> releases capacity
            assertEquals(TransitionResult.Applied, tracker.cancel(midA))
            assertEquals(0L, store.heldBytes())
            assertFalse(db.contains(midA))

            // B can now enqueue!
            assertEquals(OutboundEnqueueResult.Created(frameB),
                store.enqueueDirectOutbound(frameB, expectedRecipient = nodeB(), localOriginNodeId = localNode(1)))
            assertEquals(164L, store.heldBytes())
            assertTrue(db.contains(midB))
            db.close()
        } finally {
            file.delete()
        }
    }

    @Test
    fun `C7_5 AckMode NONE terminal retirement on EXPIRE and CANCEL`() = runBlocking {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val store = SqliteMessageStore(db, maxBytes = 4096L)
            val repo = SqliteDeliveryRepository(db)
            val (pubA, _) = realKeypair()
            val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(SingleRecipientResolver(nodeA(), pubA)))

            // Test NONE mode EXPIRE
            val midNoneExp = msgId(197)
            plantHeld(file, midNoneExp)
            assertEquals(EnqueueResult.Created, tracker.enqueue(midNoneExp, AckMode.NONE, null))
            assertTrue(db.contains(midNoneExp))

            assertEquals(TransitionResult.Applied, tracker.expire(midNoneExp))
            assertEquals(DeliveryState.EXPIRED, stateOf(tracker, midNoneExp))
            assertFalse(db.contains(midNoneExp), "NONE mode frame must be deleted on EXPIRE")

            // Test NONE mode CANCEL
            val midNoneCancel = msgId(198)
            plantHeld(file, midNoneCancel)
            assertEquals(EnqueueResult.Created, tracker.enqueue(midNoneCancel, AckMode.NONE, null))
            assertTrue(db.contains(midNoneCancel))

            assertEquals(TransitionResult.Applied, tracker.cancel(midNoneCancel))
            assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, midNoneCancel))
            assertFalse(db.contains(midNoneCancel), "NONE mode frame must be deleted on CANCEL")

            db.close()
        } finally {
            file.delete()
        }
    }
}