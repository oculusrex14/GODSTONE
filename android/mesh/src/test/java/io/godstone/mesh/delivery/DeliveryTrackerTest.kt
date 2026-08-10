package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.SecureRandom
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Durable recipient-authenticated delivery state machine (ADR-005; A-03; Stage 3
 * Phase H). Drives the REAL [DeliveryTracker] + [Ed25519AckAuthenticator] with a
 * REAL Ed25519 keypair and a REAL on-disk [FileDeliveryJournal] for the reboot
 * path, plus fakes for the truth-table / negative-ACK matrix.
 *
 * Asserts the ADR-005 exit criteria that are provable without a device/radio:
 * truth-table for every state; no unsigned/tampered/wrong-recipient ACK accepted
 * (no delivery claimed without cryptographic evidence); replay across message
 * ids rejected; reboot recovery from the durable journal.
 */
class DeliveryTrackerTest {

    private val rng = SecureRandom()

    private fun msgId(seed: Byte) = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }

    /** In-memory journal for the truth-table / negative matrix. */
    private class FakeJournal : DeliveryJournal {
        val map = mutableMapOf<List<Byte>, DeliveryState>()
        private fun key(m: ByteArray) = m.toList()
        override fun read(msgId: ByteArray) = map[key(msgId)] ?: DeliveryState.UNAVAILABLE
        override fun write(msgId: ByteArray, state: DeliveryState) { map[key(msgId)] = state }
        override fun clear(msgId: ByteArray) { map.remove(key(msgId)) }
    }

    /** Authenticator that returns a fixed verdict (for the truth-table). */
    private class FakeAuthenticator(val ok: Boolean) : AckAuthenticator {
        override fun verify(originalMsgId: ByteArray, expectedRecipientNodeId: ByteArray?, ackFrame: FrameV2) = ok
    }

    /** Resolver backed by a single recipient keypair. */
    private class SingleRecipientResolver(
        val nodeId: ByteArray,
        val pub: ByteArray,
    ) : RecipientKeyResolver {
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? =
            if (nodeId.contentEquals(this.nodeId)) pub else null
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

    /** In-memory [ExpectedRecipientStore] for the C2 binding tests. */
    private class FakeExpectedRecipientStore : ExpectedRecipientStore {
        val map = mutableMapOf<List<Byte>, ByteArray>()
        private fun key(m: ByteArray) = m.toList()
        override fun expectedRecipient(msgId: ByteArray): ByteArray? = map[key(msgId)]
        override fun recordExpectedRecipient(msgId: ByteArray, recipient: ByteArray?) {
            if (recipient != null) map[key(msgId)] = recipient else map.remove(key(msgId))
        }
    }

    private fun realKeypair(): Pair<ByteArray, ByteArray> {
        val kp = Ed25519Keys.generate(rng)
        return kp.pub to kp.priv
    }

    // --- happy path: enqueue -> handed -> acknowledged (authenticated) ---

    @Test
    fun `happy path reaches ACKNOWLEDGED only with an authenticated ACK`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x42 }
        val resolver = SingleRecipientResolver(recipientNodeId, pub)
        val tracker = DeliveryTracker(FakeJournal(), Ed25519AckAuthenticator(resolver))
        val mid = msgId(1)
        assertEquals(DeliveryState.UNAVAILABLE, tracker.state(mid))
        assertTrue(tracker.enqueue(mid))
        assertEquals(DeliveryState.QUEUED_DURABLY, tracker.state(mid))
        assertTrue(tracker.markHandedToRelay(mid))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertTrue(tracker.acknowledge(mid, ack))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))
    }

    // --- no delivery claimed without cryptographic evidence (ADR-005) ---

    @Test
    fun `an ACK that fails authentication does not advance state`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(ok = false))
        val mid = msgId(2)
        tracker.enqueue(mid)
        tracker.markHandedToRelay(mid)
        val bogus = FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))
        assertFalse(tracker.acknowledge(mid, bogus))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid), "state unchanged on rejected ACK")
    }

    @Test
    fun `an ACK for the wrong message id is rejected`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x43 }
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val midX = msgId(10)
        val midY = msgId(11)
        tracker.enqueue(midX); tracker.markHandedToRelay(midX)
        tracker.enqueue(midY); tracker.markHandedToRelay(midY)
        // A valid ACK for X replayed against Y must not ack Y.
        val ackForX = AckFrame.build(midX, priv, recipientNodeId, routingTag)
        assertFalse(tracker.acknowledge(midY, ackForX), "replayed ACK for X must not ack Y")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(midY))
        // The same ACK does ack X (the message it was made for).
        assertTrue(tracker.acknowledge(midX, ackForX))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(midX))
    }

    @Test
    fun `a tampered signature is rejected`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x44 }
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val mid = msgId(3)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        val tampered = ack.payload.copyOf().also { it[0] = (it[0].toInt() xor 0x55).toByte() }
        val bad = ack.copy(payload = tampered)
        assertFalse(tracker.acknowledge(mid, bad))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
    }

    @Test
    fun `an ACK signed by the wrong recipient is rejected`() {
        val (pubA, _) = realKeypair()           // the bound recipient A
        val (_, privB) = realKeypair()          // an attacker B
        val recipientNodeId = ByteArray(16) { 0x45 }
        // Resolver binds recipientNodeId -> A's pub, but the ACK is signed by B.
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pubA)))
        val mid = msgId(4)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        val forged = AckFrame.build(mid, privB, recipientNodeId, routingTag)
        assertFalse(tracker.acknowledge(mid, forged), "wrong-recipient signature must not verify")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
    }

    @Test
    fun `a non-ACK frame is rejected as an acknowledgment`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x46 }
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val mid = msgId(5)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        // Same payload layout but the wrong type -- must be rejected on type.
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        val notAck = ack.copy(type = TypeV2.MESSAGE)
        assertFalse(tracker.acknowledge(mid, notAck))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
    }

    // --- truth-table: legal transitions advance, illegal are rejected ---

    @Test
    fun `truth table -- enqueue only from UNAVAILABLE or QUEUED`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(20)
        // from UNAVAILABLE -> true
        assertTrue(tracker.enqueue(mid))
        // from QUEUED -> idempotent true
        assertTrue(tracker.enqueue(mid))
        assertEquals(DeliveryState.QUEUED_DURABLY, tracker.state(mid))
        // from HANDED -> false
        tracker.markHandedToRelay(mid)
        assertFalse(tracker.enqueue(mid))
        // from ACKNOWLEDGED -> false
        tracker.acknowledge(mid, FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80)))
        assertFalse(tracker.enqueue(mid))
    }

    @Test
    fun `truth table -- markHandedToRelay only from QUEUED or HANDED`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(21)
        assertFalse(tracker.markHandedToRelay(mid), "cannot hand over before enqueue")
        tracker.enqueue(mid)
        assertTrue(tracker.markHandedToRelay(mid))
        assertTrue(tracker.markHandedToRelay(mid), "idempotent from HANDED")
        tracker.acknowledge(mid, FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80)))
        assertFalse(tracker.markHandedToRelay(mid), "cannot hand over after acknowledged")
    }

    @Test
    fun `truth table -- expire and cancel only from QUEUED or HANDED and terminal states reject all`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(22)
        assertFalse(tracker.expire(mid))
        assertFalse(tracker.cancel(mid))
        tracker.enqueue(mid)
        assertTrue(tracker.cancel(mid))
        assertEquals(DeliveryState.CANCELLED_LOCALLY, tracker.state(mid))
        // terminal: a DIFFERENT transition is rejected; re-calling the SAME one
        // is idempotent (a crash-then-resume that re-issues cancel still succeeds).
        assertFalse(tracker.enqueue(mid))
        assertFalse(tracker.markHandedToRelay(mid))
        assertFalse(tracker.acknowledge(mid, FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))))
        assertFalse(tracker.expire(mid), "cannot expire a CANCELLED message")
        assertTrue(tracker.cancel(mid), "re-cancel is idempotent from CANCELLED")

        val mid2 = msgId(23)
        tracker.enqueue(mid2); tracker.markHandedToRelay(mid2)
        assertTrue(tracker.expire(mid2))
        assertEquals(DeliveryState.EXPIRED, tracker.state(mid2))
        assertFalse(tracker.acknowledge(mid2, FrameV2(TypeV2.ACK, mid2, routingTag, 4, 0, 0, ByteArray(80))),
            "cannot ack an EXPIRED message")
        assertFalse(tracker.cancel(mid2), "cannot cancel an EXPIRED message")
        assertTrue(tracker.expire(mid2), "re-expire is idempotent from EXPIRED")
    }

    @Test
    fun `acknowledge is idempotent once acknowledged`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x47 }
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val mid = msgId(6)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertTrue(tracker.acknowledge(mid, ack))
        // A second (even unsigned) ack is idempotent -- already acknowledged.
        assertTrue(tracker.acknowledge(mid, FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))
    }

    // --- reboot recovery: a fresh tracker over the same durable journal ---

    @Test
    fun `reboot recovery -- state survives a fresh tracker over the same file`() {
        val tmp = Files.createTempFile("godstone-delivery", ".props").toFile()
        try {
            val (pub, priv) = realKeypair()
            val recipientNodeId = ByteArray(16) { 0x48 }
            val resolver = SingleRecipientResolver(recipientNodeId, pub)
            val mid = msgId(7)

            // First "boot": enqueue + hand to relay, then "crash".
            val boot1 = DeliveryTracker(FileDeliveryJournal(tmp), Ed25519AckAuthenticator(resolver))
            assertTrue(boot1.enqueue(mid))
            assertTrue(boot1.markHandedToRelay(mid))
            assertEquals(DeliveryState.HANDED_TO_RELAY, boot1.state(mid))

            // Second "boot": a fresh tracker over the same journal file recovers.
            val boot2 = DeliveryTracker(FileDeliveryJournal(tmp), Ed25519AckAuthenticator(resolver))
            assertEquals(DeliveryState.HANDED_TO_RELAY, boot2.state(mid), "state recovered after reboot")
            // And it can still be acknowledged after the reboot.
            val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
            assertTrue(boot2.acknowledge(mid, ack))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, boot2.state(mid))

            // Third "boot": sees the persisted acknowledgment.
            val boot3 = DeliveryTracker(FileDeliveryJournal(tmp), Ed25519AckAuthenticator(resolver))
            assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, boot3.state(mid))
        } finally {
            tmp.delete()
        }
    }

    // --- cross-platform parity: a signature made here verifies here ---

    @Test
    fun `Ed25519 sign and verify round-trip`() {
        val (pub, priv) = realKeypair()
        val msg = ACK_MAGIC.toByteArray(Charsets.US_ASCII) + msgId(8) + ByteArray(16) { 0x49 }
        val sig = Ed25519Keys.sign(msg, priv)
        assertEquals(64, sig.size)
        assertTrue(Ed25519Keys.verify(msg, sig, pub))
        // wrong message -> false
        assertFalse(Ed25519Keys.verify(ByteArray(39), sig, pub))
        // wrong key -> false
        val (otherPub, _) = realKeypair()
        assertFalse(Ed25519Keys.verify(msg, sig, otherPub))
    }

    // --- Stage 4C / C2: two valid identities, ACK bound to the expected recipient ---

    @Test
    fun `two valid identities - ACK verifies only for the expected recipient bound at enqueue`() {
        // C2 (ADR-005): the expected recipient is bound at ENQUEUE time from
        // durable outbound state, INDEPENDENT of the ACK. Two equally valid
        // recipients A and B each have their own key. An ACK from the bound
        // recipient verifies; an ACK from the other valid recipient does NOT,
        // because the ACK's recipientNodeId must equal the expected recipient
        // recorded at send time. This is the adversarial test the directive
        // mandates: two valid identities, wrong-recipient ACK rejected.
        val (pubA, privA) = realKeypair()
        val (pubB, privB) = realKeypair()
        val nodeA = ByteArray(16) { 0x01 }
        val nodeB = ByteArray(16) { 0x02 }
        val resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        val store = FakeExpectedRecipientStore()
        val tracker = DeliveryTracker(FakeJournal(), Ed25519AckAuthenticator(resolver), store)

        // Message intended for A: enqueue binds expectedRecipient = nodeA.
        val mid = msgId(30)
        assertTrue(tracker.enqueue(mid, expectedRecipient = nodeA))
        tracker.markHandedToRelay(mid)
        // ACK from A (signed by A, claiming A) verifies.
        val ackA = AckFrame.build(mid, privA, nodeA, routingTag)
        assertTrue(tracker.acknowledge(mid, ackA), "ACK from the bound recipient A must verify")
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))

        // A second message intended for A: ACK from B (signed by B, claiming B)
        // must NOT verify -- B is valid but NOT the expected recipient.
        val mid2 = msgId(31)
        assertTrue(tracker.enqueue(mid2, expectedRecipient = nodeA))
        tracker.markHandedToRelay(mid2)
        val ackB = AckFrame.build(mid2, privB, nodeB, routingTag)
        assertFalse(tracker.acknowledge(mid2, ackB), "ACK from a valid but unintended recipient must not verify")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid2))

        // Symmetric: a message intended for B is acked by A -> rejected, then by B -> accepted.
        val mid3 = msgId(32)
        assertTrue(tracker.enqueue(mid3, expectedRecipient = nodeB))
        tracker.markHandedToRelay(mid3)
        val ackAforB = AckFrame.build(mid3, privA, nodeA, routingTag)
        assertFalse(tracker.acknowledge(mid3, ackAforB), "ACK from A for a message intended for B must not verify")
        val ackBforB = AckFrame.build(mid3, privB, nodeB, routingTag)
        assertTrue(tracker.acknowledge(mid3, ackBforB), "ACK from the bound recipient B must verify")
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid3))
    }

    @Test
    fun `an ACK whose claimed recipient differs from the expected recipient is rejected`() {
        // C2 edge: the ACK names a recipient that the resolver CAN resolve (a
        // real, valid recipient) but which differs from the expected recipient
        // bound at enqueue. This must be rejected -- the binding is to the
        // durable expected recipient, not to whoever the ACK claims to be.
        val (pubA, privA) = realKeypair()
        val (pubB, _) = realKeypair()
        val nodeA = ByteArray(16) { 0x0A }
        val nodeB = ByteArray(16) { 0x0B }
        val resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        val store = FakeExpectedRecipientStore()
        val tracker = DeliveryTracker(FakeJournal(), Ed25519AckAuthenticator(resolver), store)
        val mid = msgId(33)
        assertTrue(tracker.enqueue(mid, expectedRecipient = nodeA))
        tracker.markHandedToRelay(mid)
        // ACK signed by A but claiming nodeB in its payload (recipientNodeId field).
        // The signature is over preimage(mid, nodeB) -- valid under A's key only
        // if A signed it, which A did not sign for nodeB's preimage. Either way it
        // must be rejected: claimed recipient (B) != expected recipient (A).
        val mismatched = AckFrame.build(mid, privA, nodeB, routingTag)
        assertFalse(tracker.acknowledge(mid, mismatched), "ACK claiming a recipient other than the expected one must be rejected")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
    }

    // --- Stage 4C / C3: production resolver is UNRESOLVED -> fail-closed ---

    @Test
    fun `an unresolved production resolver fail-closes - no ACK is ever accepted`() {
        // C3: the production RecipientKeyResolver is UNRESOLVED (M2-link identity
        // binding not wired). It returns null for every node id, so the
        // Ed25519AckAuthenticator can resolve no key and rejects every ACK. This
        // is the fail-closed production state: no delivery is claimed until real
        // keys are bound -- A-03 / ADR-005 stay OPEN.
        val (_, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x50 }
        val store = FakeExpectedRecipientStore()
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver), store)
        val mid = msgId(40)
        assertTrue(tracker.enqueue(mid, expectedRecipient = recipientNodeId))
        tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertFalse(tracker.acknowledge(mid, ack), "unresolved resolver must reject every ACK")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid), "no delivery claimed without a bound key")
    }
}