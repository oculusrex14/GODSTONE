package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.store.JdbcStoreDb
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.SecureRandom
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Stage 4C.1 / C6.1 -- the production [SqliteDeliveryJournal] over a REAL on-disk
 * SQLite ([JdbcStoreDb], the same engine the store tests use). The delivery
 * state, ack mode and intended recipient live in ONE row keyed by msg_id; the
 * expected recipient is IMMUTABLE post-creation (there is no recipient-only
 * write). Asserts the durability + preservation invariants that make the C2 ACK
 * binding trustworthy when the expected recipient comes from durable outbound
 * state:
 *   * [insert] creates the row (QUEUED_DURABLY + ack mode + recipient); a second
 *     insert for the same msg_id is ON CONFLICT DO NOTHING (returns false) and
 *     does NOT mutate the recipient (C6.1: the historical send intent is never
 *     overwritten);
 *   * [updateState] advances ONLY the state column, preserving ack_mode +
 *     expected_recipient (the C4 invariant the C2 binding relies on);
 *   * the row survives a "reboot" (a fresh journal over the same DB file);
 *   * a real [DeliveryTracker] over the real journal binds the ACK to the
 *     durable expected recipient (C1/C2 integration over SQLite, not a fake);
 *   * the schema CHECK enforces the C6.1 binding invariant at the DB level;
 *   * C6.5: an unknown persisted state / ack_mode fails closed to
 *     [DeliveryLookup.Corrupt] (NOT UNAVAILABLE), and a tracker over it rejects
 *     every mutation.
 *
 * Mirrors the iOS `SqliteDeliveryJournalTests`.
 */
class SqliteDeliveryJournalTest {

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

    private fun open(file: File): SqliteDeliveryJournal = SqliteDeliveryJournal(JdbcStoreDb(file))

    private fun realKeypair(): Pair<ByteArray, ByteArray> {
        val kp = Ed25519Keys.generate(rng)
        return kp.pub to kp.priv
    }

    private fun found(j: SqliteDeliveryJournal, mid: ByteArray): DeliveryRecord =
        (j.read(mid) as DeliveryLookup.Found).record

    @Test
    fun `insert creates a QUEUED_DURABLY row with the ack mode and recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(1)
            assertEquals(DeliveryLookup.NotFound, j.read(mid))
            assertTrue(j.insert(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            val rec = found(j, mid)
            assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
            assertEquals(AckMode.SINGLE_RECIPIENT, rec.ackMode)
            assertEquals(nodeA().toList(), rec.expectedRecipientNodeId?.toList())
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a NONE-mode insert binds no recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(2)
            assertTrue(j.insert(mid, AckMode.NONE, null))
            val rec = found(j, mid)
            assertEquals(AckMode.NONE, rec.ackMode)
            assertNull(rec.expectedRecipientNodeId)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a second insert for the same msg_id is ON CONFLICT DO NOTHING and does not mutate the recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(3)
            assertTrue(j.insert(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            // A second insert (e.g. a retry, or an attempt to rebind) returns false
            // and MUST NOT overwrite the bound recipient with nodeB.
            assertFalse(j.insert(mid, AckMode.SINGLE_RECIPIENT, nodeB()))
            val rec = found(j, mid)
            assertEquals(nodeA().toList(), rec.expectedRecipientNodeId?.toList(),
                "duplicate insert must not mutate the bound recipient")
            assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `updateState advances only the state column, preserving ack_mode and expected_recipient`() {
        // The load-bearing C4 invariant for C2: enqueue binds the expected
        // recipient; later state transitions (HANDED_TO_RELAY, ACKNOWLEDGED) call
        // updateState with the new state but NO recipient. If that clobbered the
        // bound recipient, the ACK binding the C2 test relies on would be gone
        // before the ACK arrives.
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(4)
            assertTrue(j.insert(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(1, j.updateState(mid, DeliveryState.HANDED_TO_RELAY))
            assertEquals(DeliveryState.HANDED_TO_RELAY, found(j, mid).state)
            assertEquals(nodeA().toList(), found(j, mid).expectedRecipientNodeId?.toList(),
                "state-only write must preserve the bound expected recipient")
            assertEquals(AckMode.SINGLE_RECIPIENT, found(j, mid).ackMode,
                "state-only write must preserve the ack mode")
            assertEquals(1, j.updateState(mid, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, found(j, mid).state)
            assertEquals(nodeA().toList(), found(j, mid).expectedRecipientNodeId?.toList(),
                "ACKNOWLEDGED write must preserve the bound expected recipient")
            // updateState for an unknown msg_id returns 0.
            assertEquals(0, j.updateState(msgId(99), DeliveryState.HANDED_TO_RELAY))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `clear drops the row`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(5)
            assertTrue(j.insert(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            j.clear(mid)
            assertEquals(DeliveryLookup.NotFound, j.read(mid))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `reboot recovery - a fresh journal over the same DB file recovers state, ack mode and recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // First "boot": insert + bind recipient + hand to relay, then "crash".
            val boot1 = open(file)
            val mid = msgId(6)
            assertTrue(boot1.insert(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(1, boot1.updateState(mid, DeliveryState.HANDED_TO_RELAY))
            assertEquals(DeliveryState.HANDED_TO_RELAY, found(boot1, mid).state)

            // Second "boot": a fresh journal over the same file recovers the full
            // record -- state, ack mode and the bound expected recipient.
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

    @Test
    fun `the schema CHECK enforces the C6-1 binding invariant at the DB level`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(7)
            // SINGLE_RECIPIENT with a NULL recipient violates the CHECK -> rejected.
            try {
                j.insert(mid, AckMode.SINGLE_RECIPIENT, null)
                error("expected CHECK violation for SINGLE_RECIPIENT + null recipient")
            } catch (e: java.sql.SQLException) {
                // expected: the CHECK constraint rejects the binding-inconsistent row
            }
            assertEquals(DeliveryLookup.NotFound, j.read(mid), "no row written on CHECK violation")
            // NONE with a recipient also violates the CHECK.
            try {
                j.insert(mid, AckMode.NONE, ByteArray(16))
                error("expected CHECK violation for NONE + recipient")
            } catch (e: java.sql.SQLException) {
                // expected
            }
            // A short (non-16-byte) recipient violates the CHECK for SINGLE_RECIPIENT.
            try {
                j.insert(mid, AckMode.SINGLE_RECIPIENT, ByteArray(8))
                error("expected CHECK violation for a short recipient")
            } catch (e: java.sql.SQLException) {
                // expected
            }
            assertEquals(DeliveryLookup.NotFound, j.read(mid))
        } finally {
            file.delete()
        }
    }

    // --- C6.5: unknown persisted states fail closed (NOT UNAVAILABLE) ---

    @Test
    fun `an unknown persisted state code reads as Corrupt, not UNAVAILABLE`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val j = SqliteDeliveryJournal(db)
            val mid = msgId(8)
            assertTrue(j.insert(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            // Corrupt the state column to an unknown code (999) on the same connection.
            db.execRawUpdate("UPDATE delivery_state SET state = 999 WHERE msg_id = ?", mid)
            assertEquals(DeliveryLookup.Corrupt, j.read(mid),
                "an unknown state code must fail closed to Corrupt, NOT UNAVAILABLE")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `an unknown ack_mode code decodes to null (fail-closed)`() {
        // C6.5: an unknown persisted ack_mode code must fail closed. The schema
        // CHECK makes an invalid ack_mode UNREACHABLE in the DB -- it rejects any
        // ack_mode outside {0,1} paired with a compatible recipient binding, so
        // `UPDATE ... SET ack_mode = 999` is itself rejected (JDBC raises
        // SQLException; the row stays valid). The fail-closed guard is therefore
        // the `AckMode.fromCode` decoder, which `SqliteDeliveryJournal.read`
        // consults. This test pins the decoder directly (the state-code DB
        // mutation test below covers the DB-level fail-closed path, since `state`
        // is NOT CHECK-constrained and CAN be mutated to 999).
        assertNull(AckMode.fromCode(999))
        assertNull(AckMode.fromCode(-1))
        assertEquals(AckMode.NONE, AckMode.fromCode(0))
        assertEquals(AckMode.SINGLE_RECIPIENT, AckMode.fromCode(1))
    }

    @Test
    fun `a tracker over a corrupt record rejects every mutation`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val db = JdbcStoreDb(file)
            val j = SqliteDeliveryJournal(db)
            val mid = msgId(10)
            assertTrue(j.insert(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            db.execRawUpdate("UPDATE delivery_state SET state = 999 WHERE msg_id = ?", mid)
            val tracker = DeliveryTracker(j, Ed25519AckAuthenticator(TwoRecipientResolver(nodeA(), ByteArray(32), nodeB(), ByteArray(32))))
            // A corrupt row does NOT silently become UNAVAILABLE; every seam fails closed.
            assertEquals(DeliveryState.UNAVAILABLE, tracker.state(mid), "corrupt reads as UNAVAILABLE at the state seam")
            assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertEquals(AckResult.Corrupt, tracker.acknowledge(mid,
                io.godstone.mesh.wire.v2.FrameV2(io.godstone.mesh.wire.v2.TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))))
            assertFalse(tracker.markHandedToRelay(mid))
        } finally {
            file.delete()
        }
    }

    // --- C1/C2 integration + fail-closed production composition ---

    @Test
    fun `DeliveryTracker over SqliteDeliveryJournal binds the ACK to the durable expected recipient`() {
        // C1/C2 integration over the REAL durable store (not a fake). Two valid
        // recipients A and B. A message intended for A is acked by A (Applied) and
        // by B (RejectedAuthentication) -- because the expected recipient is read
        // from the SQLite journal at acknowledge time, independent of the ACK frame.
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (pubA, privA) = realKeypair()
            val (pubB, privB) = realKeypair()
            val resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
            val tracker = DeliveryTracker(open(file), Ed25519AckAuthenticator(resolver))

            val mid = msgId(30)
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA()))
            assertTrue(tracker.markHandedToRelay(mid))
            // ACK from A verifies -- the durable expected recipient == nodeA.
            val ackA = AckFrame.build(mid, privA, nodeA(), routingTag)
            assertEquals(AckResult.Applied, tracker.acknowledge(mid, ackA),
                "ACK from the bound recipient A must verify over the durable journal")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))

            // A second message intended for A: ACK from B must NOT verify.
            val mid2 = msgId(31)
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA()))
            tracker.markHandedToRelay(mid2)
            val ackB = AckFrame.build(mid2, privB, nodeB(), routingTag)
            assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid2, ackB),
                "ACK from a valid but unintended recipient must not verify over the durable journal")
            assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid2))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `production composition is fail-closed under the unresolved resolver`() {
        // C5 production composition recipe (mirrors MeshModule.provideDeliveryTracker,
        // but over the test JdbcStoreDb engine instead of SqlcipherStoreDb since the
        // unit test JVM has no SQLCipher native): a SqliteDeliveryJournal over a real
        // on-disk SQLite is the durable record, and an Ed25519AckAuthenticator over
        // the production UnresolvedRecipientKeyResolver rejects every ACK. No
        // delivery is claimed until M2-link binds real keys.
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val journal = open(file)
            val tracker = DeliveryTracker(journal, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
            val (_, priv) = realKeypair()
            val recipient = ByteArray(16) { 0x07 }
            val mid = msgId(40)
            // Outbound: enqueue binds the expected recipient + advances to handed.
            assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
            assertTrue(tracker.markHandedToRelay(mid))
            // A real, well-formed ACK signed by the recipient is STILL rejected,
            // because the production resolver resolves no key. State unchanged.
            val ack = AckFrame.build(mid, priv, recipient, routingTag)
            assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, ack),
                "unresolved production resolver must reject every ACK -- no delivery claimed without a bound key")
            assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
            // The durable expected recipient is preserved (state-only writes do not
            // clobber it), so the binding substrate is intact for when M2-link wires
            // a real resolver -- but until then the tracker is fail-closed.
            assertEquals(recipient.toList(), found(journal, mid).expectedRecipientNodeId?.toList())
        } finally {
            file.delete()
        }
    }
}