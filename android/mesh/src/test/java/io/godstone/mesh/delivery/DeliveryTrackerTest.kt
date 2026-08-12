package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import org.junit.Test
import java.security.SecureRandom
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Durable recipient-authenticated delivery state machine (ADR-005; A-03; Stage 4C
 * / C6.1; C6.3; **C6.4**). Drives the REAL [DeliveryTracker] +
 * [Ed25519AckAuthenticator] with a REAL Ed25519 keypair and an in-memory
 * [DeliveryRepository] fake for the truth-table / negative-ACK matrix, plus a
 * SQLite-backed reboot / CAS / concurrency test in
 * [SqliteDeliveryRepositoryTest] (the file-backed journal was removed in C6.1 --
 * it could not store the recipient binding).
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
 *
 * C6.4 invariants asserted here (fake-level; the SQL-level proofs live in
 * [SqliteDeliveryRepositoryTest]):
 *  * C6.4-B: a corrupt record reads as [DeliveryLookup.Corrupt], NOT UNAVAILABLE --
 *    the lossy `state(msgId)` seam is gone; the tracker exposes [lookup].
 *  * C6.4-D: a non-16-byte msg_id is [InvalidArgument] before any state is touched.
 *  * C6.4-J: [forget] returns a typed [ClearResult] (Cleared / AlreadyAbsent).
 *  * C6.4-K: the durable binding is defensively copied -- mutating the caller's
 *    recipient array after enqueue does NOT mutate the bound recipient.
 */
class DeliveryTrackerTest {

    private val rng = SecureRandom()

    private fun msgId(seed: Byte) = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }

    /** Extract the state from a [DeliveryTracker.lookup] for a valid-state assertion,
     *  or null for NotFound / Corrupt / StorageFailure / InvalidArgument. */
    private fun stateOf(tracker: DeliveryTracker, mid: ByteArray): DeliveryState? =
        when (val l = tracker.lookup(mid)) {
            is DeliveryLookup.Found -> l.record.state
            else -> null
        }

    /**
     * In-memory [DeliveryRepository] for the truth-table / negative matrix.
     * Stores the full [DeliveryRecord] (state + ackMode + recipient) so the
     * binding is preserved across [transition] / [acknowledgeBound]. [corruptIds]
     * forces a [DeliveryLookup.Corrupt] read for the listed msg ids (the C6.5
     * fail-closed path at the tracker level). [insertReturnsFalse] forces the
     * NotFound -> insert branch to behave as an ON-CONFLICT so the re-read
     * classification branch is exercised. Mirrors the real
     * [SqliteDeliveryRepository] truth-table one-for-one, including the C6.4
     * 16-byte [InvalidArgument] guard and the typed [ClearResult].
     */
    private class FakeRepository(
        private val insertReturnsFalse: Boolean = false,
    ) : DeliveryRepository {
        val map = mutableMapOf<List<Byte>, DeliveryRecord>()
        val corruptIds = mutableSetOf<List<Byte>>()
        private fun key(m: ByteArray) = m.toList()

        /** Test seam: plant a record (bypassing the QUEUED_DURABLY enqueue). */
        fun plant(rec: DeliveryRecord) { map[key(rec.msgId)] = rec }

        override fun get(msgId: ByteArray): DeliveryLookup {
            if (msgId.size != 16) return DeliveryLookup.InvalidArgument // C6.4-D
            val k = key(msgId)
            if (corruptIds.contains(k)) return DeliveryLookup.Corrupt
            val rec = map[k] ?: return DeliveryLookup.NotFound
            return DeliveryLookup.Found(rec)
        }

        override fun enqueue(
            msgId: ByteArray,
            ackMode: AckMode,
            expectedRecipient: ByteArray?,
        ): EnqueueResult {
            if (msgId.size != 16) return EnqueueResult.InvalidArgument // C6.4-D
            if (!bindingConsistent(ackMode, expectedRecipient)) return EnqueueResult.Corrupt
            return when (val l = get(msgId)) {
                DeliveryLookup.NotFound -> {
                    if (insertReturnsFalse) return classifyExisting(msgId, ackMode, expectedRecipient)
                    val k = key(msgId)
                    if (map.containsKey(k)) return classifyExisting(msgId, ackMode, expectedRecipient)
                    map[k] = DeliveryRecord(msgId, DeliveryState.QUEUED_DURABLY, ackMode, expectedRecipient)
                    EnqueueResult.Created
                }
                is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
                DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
                DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
                DeliveryLookup.InvalidArgument -> EnqueueResult.InvalidArgument
            }
        }

        override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult {
            if (msgId.size != 16) return TransitionResult.InvalidArgument // C6.4-D
            val (target, validFroms) = transitionMapping(transition)
            return when (val l = get(msgId)) {
                DeliveryLookup.NotFound -> TransitionResult.UnknownMessage
                DeliveryLookup.Corrupt -> TransitionResult.Corrupt
                DeliveryLookup.StorageFailure -> TransitionResult.StorageFailure
                DeliveryLookup.InvalidArgument -> TransitionResult.InvalidArgument
                is DeliveryLookup.Found -> {
                    val s = l.record.state
                    when {
                        s == target -> TransitionResult.AlreadyInTarget
                        s in validFroms -> {
                            map[key(msgId)] = l.record.copy(state = target) // preserve ackMode + recipient
                            TransitionResult.Applied
                        }
                        else -> TransitionResult.RejectedState
                    }
                }
            }
        }

        override fun acknowledgeBound(
            msgId: ByteArray,
            expectedRecipient: ByteArray,
        ): AckResult {
            if (msgId.size != 16) return AckResult.InvalidArgument // C6.4-D
            if (expectedRecipient.size != 16) return AckResult.InvalidArgument
            return when (val l = get(msgId)) {
                DeliveryLookup.NotFound -> AckResult.UnknownMessage
                DeliveryLookup.Corrupt -> AckResult.Corrupt
                DeliveryLookup.StorageFailure -> AckResult.StorageFailure
                DeliveryLookup.InvalidArgument -> AckResult.InvalidArgument
                is DeliveryLookup.Found -> {
                    val rec = l.record
                    if (rec.ackMode != AckMode.SINGLE_RECIPIENT ||
                        !rec.expectedRecipientNodeId.contentEquals(expectedRecipient)
                    ) return AckResult.UnknownMessage
                    if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) {
                        AckResult.DuplicateAuthenticatedAck // C6.4-H (parity; tracker short-circuits before this)
                    } else {
                        map[key(msgId)] = rec.copy(state = DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
                        AckResult.Applied
                    }
                }
            }
        }

        override fun clear(msgId: ByteArray): ClearResult {
            if (msgId.size != 16) return ClearResult.InvalidArgument // C6.4-D
            return if (map.remove(key(msgId)) != null) ClearResult.Cleared else ClearResult.AlreadyAbsent
        }

        private fun transitionMapping(t: DeliveryTransition): Pair<DeliveryState, Set<DeliveryState>> =
            when (t) {
                DeliveryTransition.MARK_HANDED ->
                    DeliveryState.HANDED_TO_RELAY to setOf(DeliveryState.QUEUED_DURABLY)
                DeliveryTransition.EXPIRE ->
                    DeliveryState.EXPIRED to setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY)
                DeliveryTransition.CANCEL ->
                    DeliveryState.CANCELLED_LOCALLY to setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY)
            }

        private fun classifyExisting(
            msgId: ByteArray,
            ackMode: AckMode,
            expectedRecipient: ByteArray?,
        ): EnqueueResult = when (val l = get(msgId)) {
            is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
            DeliveryLookup.NotFound -> EnqueueResult.StorageFailure // row vanished -- storage anomaly
            DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
            DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
            DeliveryLookup.InvalidArgument -> EnqueueResult.InvalidArgument
        }

        private fun classifyExisting(
            rec: DeliveryRecord,
            ackMode: AckMode,
            expectedRecipient: ByteArray?,
        ): EnqueueResult {
            if (rec.state.isTerminal) return EnqueueResult.RejectedTerminalState
            return if (rec.ackMode == ackMode &&
                rec.expectedRecipientNodeId.contentEquals(expectedRecipient)
            ) EnqueueResult.AlreadyQueuedSameBinding
            else EnqueueResult.ConflictRecipient
        }

        private fun bindingConsistent(ackMode: AckMode, expectedRecipient: ByteArray?): Boolean =
            when (ackMode) {
                AckMode.NONE -> expectedRecipient == null
                AckMode.SINGLE_RECIPIENT -> expectedRecipient != null && expectedRecipient.size == 16
            }
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
        val tracker = DeliveryTracker(FakeRepository(), Ed25519AckAuthenticator(resolver))
        val mid = msgId(1)
        assertEquals(DeliveryLookup.NotFound, tracker.lookup(mid)) // C6.4-B: untracked = NotFound, not UNAVAILABLE
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId))
        assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
        assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid, ack))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))
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
        val tracker = DeliveryTracker(FakeRepository(), auth)
        val mid = msgId(50)
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
        assertEquals(TransitionResult.Applied, tracker.markHandedToRelay(mid))
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))

        // A valid, trusted ACK from Alice -> NotAckEligible, state unchanged, auth NOT invoked.
        val ackA = AckFrame.build(mid, privA, nodeA, routingTag)
        assertEquals(AckResult.NotAckEligible, tracker.acknowledge(mid, ackA))
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid), "NONE-mode state unchanged on ACK")
        assertFalse(auth.invoked, "authenticator must NOT be invoked for a NONE-mode message")

        // Repeat with Bob -> still NotAckEligible, still no authenticator call.
        val ackB = AckFrame.build(mid, privB, nodeB, routingTag)
        assertEquals(AckResult.NotAckEligible, tracker.acknowledge(mid, ackB))
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
        assertFalse(auth.invoked)
    }

    // --- no delivery claimed without cryptographic evidence (ADR-005) ---

    @Test
    fun `an ACK that fails authentication returns RejectedAuthentication and does not advance state`() {
        val tracker = DeliveryTracker(FakeRepository(), FakeAuthenticator(ok = false))
        val mid = msgId(2)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x02 })
        tracker.markHandedToRelay(mid)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, rawAckFrame(mid)))
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid), "state unchanged on rejected ACK")
    }

    @Test
    fun `an ACK for the wrong message id is rejected`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x43 }
        val tracker = DeliveryTracker(
            FakeRepository(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val midX = msgId(10)
        val midY = msgId(11)
        tracker.enqueue(midX, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(midX)
        tracker.enqueue(midY, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(midY)
        // A valid ACK for X replayed against Y must not ack Y.
        val ackForX = AckFrame.build(midX, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(midY, ackForX),
            "replayed ACK for X must not ack Y")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, midY))
        // The same ACK does ack X (the message it was made for).
        assertEquals(AckResult.Applied, tracker.acknowledge(midX, ackForX))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, midX))
    }

    @Test
    fun `a tampered signature is rejected`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x44 }
        val tracker = DeliveryTracker(
            FakeRepository(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val mid = msgId(3)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        val tampered = ack.payload.copyOf().also { it[0] = (it[0].toInt() xor 0x55).toByte() }
        val bad = ack.copy(payload = tampered)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, bad))
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
    }

    @Test
    fun `an ACK signed by the wrong recipient is rejected`() {
        val (pubA, _) = realKeypair()           // the bound recipient A
        val (_, privB) = realKeypair()          // an attacker B
        val recipientNodeId = ByteArray(16) { 0x45 }
        // Resolver binds recipientNodeId -> A's pub, but the ACK is signed by B.
        val tracker = DeliveryTracker(
            FakeRepository(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pubA)))
        val mid = msgId(4)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val forged = AckFrame.build(mid, privB, recipientNodeId, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, forged),
            "wrong-recipient signature must not verify")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
    }

    @Test
    fun `a non-ACK frame is rejected as an acknowledgment`() {
        val (pub, priv) = realKeypair()
        val recipientNodeId = ByteArray(16) { 0x46 }
        val tracker = DeliveryTracker(
            FakeRepository(), Ed25519AckAuthenticator(SingleRecipientResolver(recipientNodeId, pub)))
        val mid = msgId(5)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        // Same payload layout but the wrong type -- must be rejected on type.
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        val notAck = ack.copy(type = TypeV2.MESSAGE)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, notAck))
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
    }

    // --- truth-table: enqueue ---

    @Test
    fun `truth table -- enqueue from UNAVAILABLE creates, same binding is idempotent, terminal rejects`() {
        val tracker = DeliveryTracker(FakeRepository(), FakeAuthenticator(true))
        val mid = msgId(20)
        val recipient = ByteArray(16) { 0x20 }
        // from NotFound -> Created
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
        // from QUEUED, same binding -> AlreadyQueuedSameBinding
        assertEquals(EnqueueResult.AlreadyQueuedSameBinding, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
        assertEquals(DeliveryState.QUEUED_DURABLY, stateOf(tracker, mid))
        // from HANDED, same binding -> AlreadyQueuedSameBinding
        tracker.markHandedToRelay(mid)
        assertEquals(EnqueueResult.AlreadyQueuedSameBinding, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
        // from ACKNOWLEDGED -> RejectedTerminalState
        tracker.acknowledge(mid, rawAckFrame(mid))
        assertEquals(EnqueueResult.RejectedTerminalState, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient))
    }

    @Test
    fun `truth table -- re-enqueue with a different binding is ConflictRecipient and preserves the original binding`() {
        val journal = FakeRepository()
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
        val rec = (journal.get(mid) as DeliveryLookup.Found).record
        assertEquals(nodeA.toList(), rec.expectedRecipientNodeId?.toList())
        assertEquals(DeliveryState.QUEUED_DURABLY, rec.state)
        // NONE vs SINGLE for the same msg_id is also a conflict.
        assertEquals(EnqueueResult.ConflictRecipient, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
    }

    @Test
    fun `NONE-mode enqueue is idempotent on the same (null) binding`() {
        val tracker = DeliveryTracker(FakeRepository(), FakeAuthenticator(true))
        val mid = msgId(25)
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
        assertEquals(EnqueueResult.AlreadyQueuedSameBinding, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
    }

    @Test
    fun `an inconsistent binding is rejected as Corrupt before the journal is touched`() {
        val journal = FakeRepository()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(26)
        // SINGLE_RECIPIENT with no recipient violates the C6.1 invariant.
        assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, expectedRecipient = null))
        // NONE with a recipient violates it too.
        assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.NONE, expectedRecipient = ByteArray(16)))
        // Neither touched the journal (C6.4-B: untracked = NotFound, not UNAVAILABLE).
        assertEquals(DeliveryLookup.NotFound, journal.get(mid))
    }

    // --- truth-table: markHandedToRelay / expire / cancel (TransitionResult) ---

    @Test
    fun `truth table -- markHandedToRelay only from QUEUED or HANDED`() {
        val tracker = DeliveryTracker(FakeRepository(), FakeAuthenticator(true))
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
        val tracker = DeliveryTracker(FakeRepository(), FakeAuthenticator(true))
        val mid = msgId(22)
        assertEquals(TransitionResult.UnknownMessage, tracker.expire(mid))
        assertEquals(TransitionResult.UnknownMessage, tracker.cancel(mid))
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x22 })
        assertEquals(TransitionResult.Applied, tracker.cancel(mid))
        assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(tracker, mid))
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
        assertEquals(DeliveryState.EXPIRED, stateOf(tracker, mid2))
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
        val tracker = DeliveryTracker(FakeRepository(), auth)
        val mid = msgId(6)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid, ack))
        // A second (even unsigned) ACK short-circuits to AlreadyAcknowledged --
        // option B: the authenticator is NOT consulted for a terminal record, and
        // this is NOT a new verification.
        assertEquals(AckResult.AlreadyAcknowledged, tracker.acknowledge(mid, rawAckFrame(mid)))
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))
    }

    // --- corrupt / unknown message lookup fail closed (C6.4-B: Corrupt != UNAVAILABLE) ---

    @Test
    fun `an unknown message ACK is UnknownMessage and a corrupt record is Corrupt`() {
        val journal = FakeRepository()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(60)
        assertEquals(AckResult.UnknownMessage, tracker.acknowledge(mid, rawAckFrame(mid)))
        // A corrupt row -> Corrupt (NOT UNAVAILABLE / NOT authenticated).
        journal.corruptIds.add(mid.toList())
        assertEquals(EnqueueResult.Corrupt, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x60 }))
        assertEquals(AckResult.Corrupt, tracker.acknowledge(mid, rawAckFrame(mid)))
        // C6.4-B: a corrupt record reads as Corrupt at the lookup seam, NOT UNAVAILABLE.
        assertEquals(DeliveryLookup.Corrupt, tracker.lookup(mid), "corrupt reads as Corrupt, NOT UNAVAILABLE")
    }

    @Test
    fun `forget clears the delivery record and returns a typed ClearResult`() {
        val journal = FakeRepository()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(61)
        tracker.enqueue(mid, AckMode.NONE, expectedRecipient = null)
        assertEquals(ClearResult.Cleared, tracker.forget(mid)) // C6.4-J: typed, not Unit
        assertEquals(DeliveryLookup.NotFound, tracker.lookup(mid)) // C6.4-B: untracked = NotFound
        assertEquals(DeliveryLookup.NotFound, journal.get(mid))
        // Forgetting an already-absent row is AlreadyAbsent (not a silent "success").
        assertEquals(ClearResult.AlreadyAbsent, tracker.forget(mid))
    }

    // --- C6.4-D: 16-byte msg_id is enforced at the delivery boundary ---

    @Test
    fun `a non-16-byte msg_id is InvalidArgument at every delivery boundary`() {
        val tracker = DeliveryTracker(FakeRepository(), FakeAuthenticator(true))
        val bad8 = ByteArray(8)
        val bad17 = ByteArray(17)
        // lookup / enqueue / transition / forget all reject a non-16-byte msg_id
        // BEFORE any state is touched (C6.4-D).
        assertEquals(DeliveryLookup.InvalidArgument, tracker.lookup(bad8))
        assertEquals(EnqueueResult.InvalidArgument, tracker.enqueue(bad8, AckMode.NONE, null))
        assertEquals(TransitionResult.InvalidArgument, tracker.markHandedToRelay(bad8))
        assertEquals(TransitionResult.InvalidArgument, tracker.expire(bad17))
        assertEquals(TransitionResult.InvalidArgument, tracker.cancel(bad17))
        assertEquals(ClearResult.InvalidArgument, tracker.forget(bad8))
        // An ACK on a non-16-byte msg_id is InvalidArgument (get rejects before auth).
        assertEquals(AckResult.InvalidArgument, tracker.acknowledge(bad8, rawAckFrame(ByteArray(16))))
    }

    // --- C6.4-K: the durable binding is defensively copied ---

    @Test
    fun `mutating the caller's recipient array after enqueue does not mutate the bound recipient`() {
        val journal = FakeRepository()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(70)
        val recipient = ByteArray(16) { 0x70 }
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient)
        // Mutate the caller's array AFTER enqueue.
        recipient[0] = (recipient[0].toInt() xor 0xFF.toByte().toInt()).toByte()
        // The durable binding held by the record is the ORIGINAL bytes (C6.4-K
        // defensive copy) -- not a live reference to the caller's mutable array.
        val rec = (journal.get(mid) as DeliveryLookup.Found).record
        assertEquals(0x70.toByte(), rec.expectedRecipientNodeId!![0], "durable binding is defensively copied")
        assertNotEquals(recipient[0], rec.expectedRecipientNodeId!![0], "the record does not alias the caller's array")
    }

    @Test
    fun `mutating the caller's msg_id array after enqueue does not mutate the record msg_id`() {
        val journal = FakeRepository()
        val tracker = DeliveryTracker(journal, FakeAuthenticator(true))
        val mid = msgId(71)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, ByteArray(16) { 0x71 })
        mid[0] = (mid[0].toInt() xor 0xFF.toByte().toInt()).toByte()
        // The record's msg_id is a defensive copy (C6.4-K); the original lookup key
        // is unchanged, so a lookup with the ORIGINAL mid still finds the row.
        val rec = (journal.get(ByteArray(16) { (it + 71).toByte() }) as DeliveryLookup.Found).record
        assertEquals((71).toByte(), rec.msgId[0], "record msg_id is defensively copied")
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

    // (ACK_MAGIC is the top-level preimage sentinel in this package.)

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
        val tracker = DeliveryTracker(FakeRepository(), Ed25519AckAuthenticator(resolver))

        // Message intended for A: enqueue binds expectedRecipient = nodeA.
        val mid = msgId(30)
        assertEquals(EnqueueResult.Created, tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA))
        tracker.markHandedToRelay(mid)
        // ACK from A (signed by A, claiming A) verifies.
        val ackA = AckFrame.build(mid, privA, nodeA, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid, ackA), "ACK from the bound recipient A must verify")
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid))

        // A second message intended for A: ACK from B (signed by B, claiming B)
        // must NOT verify -- B is valid but NOT the expected recipient.
        val mid2 = msgId(31)
        tracker.enqueue(mid2, AckMode.SINGLE_RECIPIENT, nodeA); tracker.markHandedToRelay(mid2)
        val ackB = AckFrame.build(mid2, privB, nodeB, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid2, ackB),
            "ACK from a valid but unintended recipient must not verify")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid2))

        // Symmetric: a message intended for B is acked by A -> rejected, then by B -> accepted.
        val mid3 = msgId(32)
        tracker.enqueue(mid3, AckMode.SINGLE_RECIPIENT, nodeB); tracker.markHandedToRelay(mid3)
        val ackAforB = AckFrame.build(mid3, privA, nodeA, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid3, ackAforB),
            "ACK from A for a message intended for B must not verify")
        val ackBforB = AckFrame.build(mid3, privB, nodeB, routingTag)
        assertEquals(AckResult.Applied, tracker.acknowledge(mid3, ackBforB), "ACK from the bound recipient B must verify")
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(tracker, mid3))
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
        val tracker = DeliveryTracker(FakeRepository(), Ed25519AckAuthenticator(resolver))
        val mid = msgId(33)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, nodeA); tracker.markHandedToRelay(mid)
        // ACK signed by A but claiming nodeB in its payload (recipientNodeId field).
        // claimed recipient (B) != expected recipient (A) -> rejected.
        val mismatched = AckFrame.build(mid, privA, nodeB, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, mismatched),
            "ACK claiming a recipient other than the expected one must be rejected")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid))
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
        val tracker = DeliveryTracker(FakeRepository(), Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
        val mid = msgId(40)
        tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipientNodeId); tracker.markHandedToRelay(mid)
        val ack = AckFrame.build(mid, priv, recipientNodeId, routingTag)
        assertEquals(AckResult.RejectedAuthentication, tracker.acknowledge(mid, ack),
            "unresolved resolver must reject every ACK")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(tracker, mid), "no delivery claimed without a bound key")
    }
}