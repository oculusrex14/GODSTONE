package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import org.junit.Test
import java.security.SecureRandom
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Durable recipient-authenticated delivery state machine (ADR-005; A-03; Stage 4C
 * / C6.1). Drives the REAL [DeliveryTracker] + [Ed25519AckAuthenticator] with a
 * REAL Ed25519 keypair and an in-memory [DeliveryJournal] fake for the
 * truth-table / negative-ACK matrix, plus a SQLite-backed reboot test in
 * [SqliteDeliveryJournalTest] (the file-backed journal was removed in C6.1 -- it
 * could not store the recipient binding).
 *
 * C6.1 invariants asserted here:
 *  * [AckMode.NONE] messages can NEVER be acknowledged -- a valid trusted ACK
 *    from any recipient yields [AckResult.NotAckEligible] and the authenticator
 *    is NOT invoked (a recipient identity may never become trusted merely
 *    because the ACK packet names it).
 *  * the expected recipient is bound at ENQUEUE time from durable outbound state
 *    and is IMMUTABLE; an ACK from a valid-but-unintended recipient is
 *    [RejectedAuthentication]; a re-enqueue with a different binding is
 *    [EnqueueResult.ConflictRecipient] (the historical send intent is not
 *    overwritten).
 *  * only [AckResult.Applied] means "verified"; [AckResult.AlreadyAcknowledged]
 *    is a short-circuit that does NOT authenticate and is NOT a verification.
 *  * no delivery is claimed without cryptographic evidence (A-03 / ADR-005 OPEN).
 */
class DeliveryTrackerTest {

    private val rng = SecureRandom()

    private fun msgId(seed: Byte) = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }

    /**
     * In-memory [DeliveryJournal] for the truth-table / negative matrix. Stores
     * the full [DeliveryRecord] (state + ackMode + recipient) so the binding is
     * preserved across [updateState]. [corruptIds] forces a [DeliveryLookup.Corrupt]
     * read for the listed msg ids (the C6.5 fail-closed path at the tracker
     * level). [insertReturnsFalse] forces [insert] to report "no new row" so the
     * re-read classification branch is exercised.
     */
    private class FakeJournal(
        private val insertReturnsFalse: Boolean = false,
    ) : DeliveryJournal {
        val map = mutableMapOf<List<Byte>, DeliveryRecord>()
        val corruptIds = mutableSetOf<List<Byte>>()
        private fun key(m: ByteArray) = m.toList()

        /** Test seam: plant a record (bypassing the QUEUED_DURABLY insert). */
        fun plant(rec: DeliveryRecord) { map[key(rec.msgId)] = rec }

        override fun read(msgId: ByteArray): DeliveryLookup {
            val k = key(msgId)
            if (corruptIds.contains(k)) return DeliveryLookup.Corrupt
            val rec = map[k] ?: return DeliveryLookup.NotFound
            return DeliveryLookup.Found(rec)
        }

        override fun insert(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): Boolean {
            if (insertReturnsFalse) return false
            val k = key(msgId)
            if (map.containsKey(k)) return false // ON CONFLICT DO NOTHING
            map[k] = DeliveryRecord(msgId, DeliveryState.QUEUED_DURABLY, ackMode, expectedRecipient)
            return true
        }

        override fun updateState(msgId: ByteArray, state: DeliveryState): Int {
            val k = key(msgId)
            val rec = map[k] ?: return 0
            map[k] = rec.copy(state = state) // preserve ackMode + recipient
            return 1
        }

        override fun clear(msgId: ByteArray) { map.remove(key(msgId)) }
    }

    /** Authenticator returning a fixed verdict, recording whether it was invoked. */
    private class FakeAuthenticator(val ok: Boolean) : AckAuthenticator {
        var invoked = false
        override fun verify(
            originalMsgId: ByteArray,
            expectedRecipientNodeId: ByteArray,
            ackFrame: FrameV2,
        ): Boolean {
            invoked = true
            return ok
        }
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

    private fun realKeypair(): Pair<ByteArray, ByteArray> {
        val kp = Ed25519Keys.generate(rng)
        return kp.pub to kp.priv
    }

    private fun rawAckFrame(mid: ByteArray): FrameV2 =
        FrameV2(TypeV2.ACK, mid, routingTag, 4, 0, 0, ByteArray(80))

    // --- happy path: SINGLE_RECIPIENT enqueue -> handed -> acknowledged ---

    @Test
    fun `happy path reaches ACKNOWLEDGED only with an authenticated ACK`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x42 }
        val resolver = SingleRecipientResolver(recipientNodeId, pub)
        val tracker = DeliveryTracker(FakeJournal(), Ed25519AckAuthenticator(resolver))
        val mid = msgId(1)
        assertEquals(DeliveryState.UNAVAILABLE, tracker.state(mid))
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId))
        assertEquals(DeliveryState.QUEUED_DURABLY, tracker.state(mid))
        assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid, ack))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))
    }

    // --- C6.1 mandatory negative: AckMode.NONE can NEVER be acknowledged ---

    @Test
    fun `NONE-mode message rejects every ACK as NotAckEligible without invoking the authenticator`() {
        // A broadcast / SOS is AckMode.NONE: no recipient is bound, so NO ACK may
        // advance it -- not even a cryptographically valid ACK from a recipient we
        // fully trust. The authenticator is NOT invoked (a recipient identity may
        // never become trusted merely because the ACK packet names it).
        val (pubA, privA) = realKeypair()
        val (pubB, privB) = realKeypair()
        val nodeA = ByteArray(16) { 0x01 }
        val nodeB = ByteArray(16) { 0x02 }
        val resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        val auth = FakeAuthenticator(ok = true) // would say "yes" -- must never be asked
        val tracker = DeliveryTracker(FakeJournal(), auth)
        val mid = msgId(50)
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
        assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))

        // A valid, trusted ACK from Alice -> NotAckEligible, state unchanged, auth NOT invoked.
        val ackA = AckFrame.build(mid, privA, nodeA, routingTag)
        assertEquals(AckResult.NotAckEligible, tracker.acknowledge(mid, ackA))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid), "NONE-mode state unchanged on ACK")
        assertFalse(auth.invoked, "authenticator must NOT be invoked for a NONE-mode message")

        // Repeat with Bob -> still NotAckEligible, still no authenticator call.
        val ackB = AckFrame.build(mid, privB, nodeB, routingTag)
        assertEquals(AckResult.NotAckEligible, tracker.acknowledge(mid, ackB))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
        assertFalse(auth.invoked)
    }

    // --- no delivery claimed without cryptographic evidence (ADR-005) ---

    @Test
    fun `an ACK that fails authentication returns RejectedAuthentication and does not advance state`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(ok = false))
        val mid = msgId(2)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x02 })
        tracker.markHandedToRelay(mid)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, rawAckFrame(mid)))
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
        tracker.enqueue(midX, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(midX)
        tracker.enqueue(midY, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(midY)
        // A valid ACK for X replayed against Y must not ack Y.
        val ackForX = AckFrame.build(midX, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(midY, ackForX),
            "replayed ACK for X must not ack Y")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(midY))
        // The same ACK does ack X (the message it was made for).
        assertEquals(AckResult.Applied, tracker.acknowledge(midX, ackForX))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(midX))
    }

    @Test
    fun `a tampered signature is rejected`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x44 }
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val mid = msgId(3)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        val tampered = ack.payload.copyOf().also { it[0] = (it[0].toInt() xor 0x55).toByte() }
        val bad = ack.copy(payload = tampered)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, bad))
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
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val forged = AckFrame.build(mid, privB, recipientNodeId, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, forged),
            "wrong-recipient signature must not verify")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
    }

    @Test
    fun `a non-ACK frame is rejected as an acknowledgment`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x46 }
        val tracker = DeliveryTracker(
            FakeJournal(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val mid = msgId(5)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        // Same payload layout but the wrong type -- must be rejected on type.
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        val notAck = ack.copy(type = TypeV2.MESSAGE)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, notAck))
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid))
    }

    // --- truth-table: enqueue ---

    @Test
    fun `truth table -- enqueue from UNAVAILABLE creates, same binding is idempotent, terminal rejects`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(20)
        val recipient = ByteArray(16) { 0x20 }
        // from UNAVAILABLE -> Created
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
        // from QUEUED, same binding -> AlreadyQueuedSameBinding
        assertEquals(EnqueueResult.AlreadyQueuedSameBinding, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
        assertEquals(DeliveryState.QUEUED_DURABLY, tracker.state(mid))
        // from HANDED, same binding -> AlreadyQueuedSameBinding
        tracker.markHandedToRelay(mid)
        assertEquals(EnqueueResult.AlreadyQueuedSameBinding, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
        // from ACKNOWLEDGED -> RejectedTerminalState
        tracker.acknowledge(mid, rawAckFrame(mid))
        assertEquals(EnqueueResult.RejectedTerminalState, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
    }

    @Test
    fun `truth table -- re-enqueue with a different binding is ConflictRecipient and preserves the original binding`() {
        val journal = FakeJournal()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(24)
        // 0xA1 / 0xB1 exceed signed Byte (-128..127), so they must be widened
        // to Int then narrowed with .toByte() -- Kotlin constant-narrows only
        // in-range literals (e.g. 0x20), not out-of-range ones.
        val nodeA = ByteArray(16) { 0xA1.toByte() }
        val nodeB = ByteArray(16) { 0xB1.toByte() }
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA))
        // Different intended recipient for the SAME msg_id -> ConflictRecipient.
        assertEquals(EnqueueResult.ConflictRecipient, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeB))
        // The historical send intent (nodeA) is preserved -- not overwritten.
        val rec = (journal.read(mid) as DeliveryLookup.Found).record
        assertEquals(nodeA, rec.expectedRecipientNodeId)
        assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
        // NONE vs SINGLE for the same msg_id is also a conflict.
        assertEquals(EnqueueResult.ConflictRecipient, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
    }

    @Test
    fun `NONE-mode enqueue is idempotent on the same (null) binding`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(25)
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
        assertEquals(EnqueueResult.AlreadyQueuedSameBinding, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
    }

    @Test
    fun `an inconsistent binding is rejected as Corrupt before the journal is touched`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(26)
        // SINGLE_RECIPIENT with no recipient violates the C6.1 invariant.
        assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, expectedRecipient = null))
        // NONE with a recipient violates it too.
        assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = ByteArray(16)))
        // Neither touched the journal.
        assertEquals(DeliveryState.UNAVAILABLE, tracker.state(mid))
    }

    // --- truth-table: markHandedToRelay / expire / cancel (TransitionResult) ---

    @Test
    fun `truth table -- markHandedToRelay only from QUEUED or HANDED`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(21)
        assertEquals(TransitionResult.UnknownMessage, tracker.markHandedToRelay(mid), "cannot hand over before enqueue")
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x21 })
        assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
        assertEquals(TransitionResult.AlreadyInTarget, tracker.markHandedToRelay(mid), "idempotent from HANDED")
        tracker.acknowledge(mid, rawAckFrame(mid))
        assertEquals(TransitionResult.RejectedState, tracker.markHandedToRelay(mid), "cannot hand over after acknowledged")
    }

    @Test
    fun `truth table -- expire and cancel only from QUEUED or HANDED and terminal states reject all`() {
        val tracker = DeliveryTracker(FakeJournal(), FakeAuthenticator(true))
        val mid = msgId(22)
        assertEquals(TransitionResult.UnknownMessage, tracker.expire(mid))
        assertEquals(TransitionResult.UnknownMessage, tracker.cancel(mid))
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x22 })
        assertEquals(TransitionResult.Applied, tracker.cancel(mid))
        assertEquals(DeliveryState.CANCELLED_LOCALLY, tracker.state(mid))
        // terminal: a DIFFERENT transition is rejected; re-calling the SAME one
        // is idempotent (a crash-then-resume that re-issues cancel still succeeds).
        assertEquals(EnqueueResult.RejectedTerminalState, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x22 }))
        assertEquals(TransitionResult.RejectedState, tracker.markHandedToRelay(mid))
        assertEquals(AckResult.RejectedState, tracker.acknowledge(mid, rawAckFrame(mid)))
        assertEquals(TransitionResult.RejectedState, tracker.expire(mid), "cannot expire a CANCELLED message")
        assertEquals(TransitionResult.AlreadyInTarget, tracker.cancel(mid), "re-cancel is idempotent from CANCELLED")

        val mid2 = msgId(23)
        tracker.enqueue(mid2, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x23 }); tracker.markHandedToRelay(mid2)
        assertEquals(TransitionResult.Applied, tracker.expire(mid2))
        assertEquals(DeliveryState.EXPIRED, tracker.state(mid2))
        assertEquals(AckResult.RejectedState, tracker.acknowledge(mid2, rawAckFrame(mid2)),
            "cannot ack an EXPIRED message")
        assertEquals(TransitionResult.RejectedState, tracker.cancel(mid2), "cannot cancel an EXPIRED message")
        assertEquals(TransitionResult.AlreadyInTarget, tracker.expire(mid2), "re-expire is idempotent from EXPIRED")
    }

    // --- acknowledge idempotency: AlreadyAcknowledged is NOT a verification ---

    @Test
    fun `acknowledge is idempotent -- a second ACK is AlreadyAcknowledged, not Applied`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x47 }
        val auth = Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub))
        val tracker = DeliveryTracker(FakeJournal(), auth)
        val mid = msgId(6)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid, ack))
        // A second (even unsigned) ACK short-circuits to AlreadyAcknowledged --
        // option B: the authenticator is NOT consulted for a terminal record, and
        // this is NOT a new verification.
        assertEquals(AckResult.AlreadyAcknowledged, tracker.acknowledge(mid, rawAckFrame(mid)))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))
    }

    // --- corrupt / unknown message lookup fail closed ---

    @Test
    fun `an unknown message ACK is UnknownMessage and a corrupt record is Corrupt`() {
        val journal = FakeJournal()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(60)
        assertEquals(AckResult.UnknownMessage, tracker.acknowledge(mid, rawAckFrame(mid)))
        // A corrupt row -> Corrupt (NOT UNAVAILABLE / NOT authenticated).
        journal.corruptIds.add(mid.toList())
        assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x60 }))
        assertEquals(AckResult.Corrupt, tracker.acknowledge(mid, rawAckFrame(mid)))
        assertEquals(DeliveryState.UNAVAILABLE, tracker.state(mid), "corrupt reads as UNAVAILABLE at the state seam")
    }

    @Test
    fun `forget clears the delivery record`() {
        val journal = FakeJournal()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(61)
        tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null)
        tracker.forget(mid)
        assertEquals(DeliveryState.UNAVAILABLE, tracker.state(mid))
        assertEquals(DeliveryLookup.NotFound, journal.read(mid))
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
        // recipient verifies (Applied); an ACK from the other valid recipient
        // does NOT (RejectedAuthentication), because the ACK's recipientNodeId
        // must equal the expected recipient recorded at send time.
        val (pubA, privA) = realKeypair()
        val (pubB, privB) = realKeypair()
        val nodeA = ByteArray(16) { 0x01 }
        val nodeB = ByteArray(16) { 0x02 }
        val resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        val tracker = DeliveryTracker(FakeJournal(), Ed25519AckAuthenticator(resolver))

        // Message intended for A: enqueue binds expectedRecipient = nodeA.
        val mid = msgId(30)
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA))
        tracker.markHandedToRelay(mid)
        // ACK from A (signed by A, claiming A) verifies.
        val ackA = AckFrame.build(mid, privA, nodeA, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid, ackA), "ACK from the bound recipient A must verify")
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, tracker.state(mid))

        // A second message intended for A: ACK from B (signed by B, claiming B)
        // must NOT verify -- B is valid but NOT the expected recipient.
        val mid2 = msgId(31)
        tracker.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA); tracker.markHandedToRelay(mid2)
        val ackB = AckFrame.build(mid2, privB, nodeB, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid2, ackB),
            "ACK from a valid but unintended recipient must not verify")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid2))

        // Symmetric: a message intended for B is acked by A -> rejected, then by B -> accepted.
        val mid3 = msgId(32)
        tracker.enqueue(mid3, AckMode.SINGLE_RECIPIENT, nodeB); tracker.markHandedToRelay(mid3)
        val ackAforB = AckFrame.build(mid3, privA, nodeA, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid3, ackAforB),
            "ACK from A for a message intended for B must not verify")
        val ackBforB = AckFrame.build(mid3, privB, nodeB, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid3, ackBforB), "ACK from the bound recipient B must verify")
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
        val tracker = DeliveryTracker(FakeJournal(), Ed25519AckAuthenticator(resolver))
        val mid = msgId(33)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA); tracker.markHandedToRelay(mid)
        // ACK signed by A but claiming nodeB in its payload (recipientNodeId field).
        // claimed recipient (B) != expected recipient (A) -> rejected.
        val mismatched = AckFrame.build(mid, privA, nodeB, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, mismatched),
            "ACK claiming a recipient other than the expected one must be rejected")
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
        val tracker = DeliveryTracker(FakeJournal(), Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
        val mid = msgId(40)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, ack),
            "unresolved resolver must reject every ACK")
        assertEquals(DeliveryState.HANDED_TO_RELAY, tracker.state(mid), "no delivery claimed without a bound key")
    }
}