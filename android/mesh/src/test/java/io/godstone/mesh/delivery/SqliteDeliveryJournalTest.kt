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
 * Stage 4C / C4 -- the production [SqliteDeliveryJournal] over a REAL on-disk
 * SQLite ([JdbcStoreDb], the same engine the store tests use). Asserts the
 * durability + preservation invariants that make the C2 ACK binding trustworthy
 * when the expected recipient comes from durable outbound state:
 *   * a state-only write (HANDED_TO_RELAY / ACKNOWLEDGED) MUST preserve a
 *     recipient bound at enqueue -- otherwise the binding the C2 adversarial test
 *     relies on would be silently clobbered by every state transition;
 *   * a recipient-only write MUST preserve the state;
 *   * the row survives a "reboot" (a fresh journal over the same DB file);
 *   * a real [DeliveryTracker] over the real journal binds the ACK to the
 *     durable expected recipient (C1/C2 integration over SQLite, not a fake).
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

    @Test
    fun `write and read recover the state`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(1)
            assertEquals(DeliveryState.UNAVAILABLE, j.read(mid))
            j.write(mid, DeliveryState.QUEUED_DURABLY)
            assertEquals(DeliveryState.QUEUED_DURABLY, j.read(mid))
            j.write(mid, DeliveryState.HANDED_TO_RELAY)
            assertEquals(DeliveryState.HANDED_TO_RELAY, j.read(mid))
            j.write(mid, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, j.read(mid))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `recordExpectedRecipient and expectedRecipient recover the recipient`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(2)
            assertNull(j.expectedRecipient(mid))
            j.recordExpectedRecipient(mid, nodeA())
            assertEquals(nodeA().toList(), j.expectedRecipient(mid)?.toList())
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a state-only write preserves a bound expected recipient`() {
        // The load-bearing C4 invariant for C2: enqueue writes QUEUED_DURABLY
        // then records the expected recipient. Later state transitions
        // (HANDED_TO_RELAY, ACKNOWLEDGED) call write() with the new state but NO
        // recipient. If that clobbered the bound recipient, the ACK binding the
        // C2 test relies on would be gone before the ACK arrives.
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(3)
            j.write(mid, DeliveryState.QUEUED_DURABLY)
            j.recordExpectedRecipient(mid, nodeA())
            assertEquals(nodeA().toList(), j.expectedRecipient(mid)?.toList())
            // State advances; the recipient MUST survive.
            j.write(mid, DeliveryState.HANDED_TO_RELAY)
            assertEquals(DeliveryState.HANDED_TO_RELAY, j.read(mid))
            assertEquals(nodeA().toList(), j.expectedRecipient(mid)?.toList(),
                "state-only write must preserve the bound expected recipient")
            j.write(mid, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, j.read(mid))
            assertEquals(nodeA().toList(), j.expectedRecipient(mid)?.toList(),
                "ACKNOWLEDGED write must preserve the bound expected recipient")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `a recipient-only write preserves the state`() {
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val j = open(file)
            val mid = msgId(4)
            j.write(mid, DeliveryState.QUEUED_DURABLY)
            j.recordExpectedRecipient(mid, nodeA())
            // Re-bind the recipient (e.g. a re-enqueue); the state MUST survive.
            j.recordExpectedRecipient(mid, nodeB())
            assertEquals(nodeB().toList(), j.expectedRecipient(mid)?.toList())
            assertEquals(DeliveryState.QUEUED_DURABLY, j.read(mid),
                "recipient-only write must preserve the state")
            // Clearing the recipient (null) MUST NOT reset the state.
            j.recordExpectedRecipient(mid, null)
            assertNull(j.expectedRecipient(mid))
            assertEquals(DeliveryState.QUEUED_DURABLY, j.read(mid),
                "clearing the recipient must not reset the state")
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
            j.write(mid, DeliveryState.QUEUED_DURABLY)
            j.recordExpectedRecipient(mid, nodeA())
            j.clear(mid)
            assertEquals(DeliveryState.UNAVAILABLE, j.read(mid))
            assertNull(j.expectedRecipient(mid))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `reboot recovery - a fresh journal over the same DB file recovers state and recipient`() {
        // JdbcStoreDb does not auto-close on GC; hold a reference then drop it to
        // simulate a "crash" (the file is closed when the connection is GC'd, and
        // sqlite-jdbc flushes on close). We reopen the same file with a new
        // JdbcStoreDb + journal and recover the persisted state + recipient.
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            // First "boot": queue + bind recipient + hand to relay, then "crash".
            val boot1 = open(file)
            val mid = msgId(6)
            boot1.write(mid, DeliveryState.QUEUED_DURABLY)
            boot1.recordExpectedRecipient(mid, nodeA())
            boot1.write(mid, DeliveryState.HANDED_TO_RELAY)
            assertEquals(DeliveryState.HANDED_TO_RELAY, boot1.read(mid))
            assertEquals(nodeA().toList(), boot1.expectedRecipient(mid)?.toList())

            // Second "boot": a fresh journal over the same file recovers.
            val boot2 = open(file)
            assertEquals(DeliveryState.HANDED_TO_RELAY, boot2.read(mid), "state recovered after reboot")
            assertEquals(nodeA().toList(), boot2.expectedRecipient(mid)?.toList(),
                "expected recipient recovered after reboot")
        } finally {
            file.delete()
        }
    }

    @Test
    fun `DeliveryTracker over SqliteDeliveryJournal binds the ACK to the durable expected recipient`() {
        // C1/C2 integration over the REAL durable store (not a fake). Two valid
        // recipients A and B. A message intended for A is acked by A (accepted)
        // and by B (rejected) -- because the expected recipient is read from the
        // SQLite journal at acknowledge time, independent of the ACK frame.
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val (pubA, privA) = realKeypair()
            val (pubB, privB) = realKeypair()
            val resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
            val journal = open(file)
            // The SAME SqliteDeliveryJournal is BOTH the journal and the expected
            // recipient store (one row holds both), as it will be in production.
            val tracker = DeliveryTracker(journal, Ed25519AckAuthenticator(resolver), journal)

            val mid = msgId(30)
            assertTrue(tracker.enqueue(mid, expectedRecipient = nodeA()))
            assertTrue(tracker.markHandedToRelay(mid))
            // ACK from A verifies -- the durable expected recipient == nodeA.
            val ackA = AckFrame.build(mid, privA, nodeA(), routingTag)
            assertTrue(tracker.acknowledge(mid, ackA), "ACK from the bound recipient A must verify over the durable journal")
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))

            // A second message intended for A: ACK from B must NOT verify.
            val mid2 = msgId(31)
            assertTrue(tracker.enqueue(mid2, expectedRecipient = nodeA()))
            tracker.markHandedToRelay(mid2)
            val ackB = AckFrame.build(mid2, privB, nodeB(), routingTag)
            assertFalse(tracker.acknowledge(mid2, ackB), "ACK from a valid but unintended recipient must not verify over the durable journal")
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
        // on-disk SQLite is BOTH the journal and the expected-recipient store, and an
        // Ed25519AckAuthenticator over the production UnresolvedRecipientKeyResolver
        // rejects every ACK. No delivery is claimed until M2-link binds real keys.
        val file = Files.createTempFile("godstone-delivery", ".db").toFile()
        try {
            val journal = open(file)
            val tracker = DeliveryTracker(
                journal,
                Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver),
                journal,
            )
            val (pub, priv) = realKeypair()
            val recipient = ByteArray(16) { 0x07 }
            val mid = msgId(40)
            // Outbound: enqueue binds the expected recipient + advances to handed.
            assertTrue(tracker.enqueue(mid, expectedRecipient = recipient))
            assertTrue(tracker.markHandedToRelay(mid))
            // A real, well-formed ACK signed by the recipient is STILL rejected,
            // because the production resolver resolves no key. State unchanged.
            val ack = AckFrame.build(mid, priv, recipient, routingTag)
            assertFalse(tracker.acknowledge(mid, ack),
                "unresolved production resolver must reject every ACK -- no delivery claimed without a bound key")
            assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
            // The durable expected recipient is preserved (state-only writes do not
            // clobber it), so the binding substrate is intact for when M2-link wires
            // a real resolver -- but until then the tracker is fail-closed.
            assertEquals(recipient.toList(), journal.expectedRecipient(mid)?.toList())
        } finally {
            file.delete()
        }
    }
}