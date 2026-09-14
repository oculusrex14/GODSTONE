// T84 readiness court (android isle) -- the twin of ReadinessT84Tests.swift.
//
// Forward durable ACKs through intermediate relays. The card's defect: MeshNode
// sendeth every ACK to the local DeliveryTracker, so an intermediate relay --
// which holdeth NO delivery row for a message somebody else authored -- answereth
// UnknownMessage and the multihop receipt never cometh home.
//
// One reviewed scenario per witness; every assertion is positive and expected (a
// present side effect is captured, an absent one is CAPTURED as absence through a
// typed refusal / zero census). The observable counters on the injected fakes, the
// ack_frames census and the origin's delivery state are the oracles that make the
// card's named falsifications killable: dropping a relay UnknownMessage ACK,
// deduping it against the MESSAGE id, or retiring it after a local ATT success.
//
// The world is A -- R -- B with NO A/B link. Fixtures are development-only: no
// device, no radio, no clock of the platform's; readiness stays false and no
// gate is closed.
package io.godstone.mesh.readiness

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.MeshNode
import io.godstone.mesh.delivery.AckAdmission
import io.godstone.mesh.delivery.AckAdmissionResult
import io.godstone.mesh.delivery.AckDispatcher
import io.godstone.mesh.delivery.AckDispatch
import io.godstone.mesh.delivery.AckForwardRefusal
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckObligationDriver
import io.godstone.mesh.delivery.AckObligationStore
import io.godstone.mesh.delivery.AckRefusalReason
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.AckSignerSeam
import io.godstone.mesh.delivery.AckVerificationClass
import io.godstone.mesh.delivery.ACK_RELAY_BATCH_LIMIT
import io.godstone.mesh.delivery.ACK_RELAY_BURST_PER_PEER
import io.godstone.mesh.delivery.ACK_RELAY_INITIAL_TTL
import io.godstone.mesh.delivery.ACK_RELAY_RETRY_INTERVAL_MS
import io.godstone.mesh.delivery.CandidateList
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRecord
import io.godstone.mesh.delivery.DeliveryRepository
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.ClearResult
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.DurableAckPump
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.InMemoryAckStore
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.ClockContinuityStamp
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test

private fun decodedOf(encoded: ByteArray): FrameV2 =
    FrameV2.decode(encoded) ?: error("a prepared copy must decode")

private fun sameBytes(a: ByteArray?, b: ByteArray?): Boolean = when {
    a == null && b == null -> true
    a == null || b == null -> false
    else -> a.contentEquals(b)
}

/** One candidate admitted from a raw store verdict (the dispatcher boundary). */
private fun admissionOf(
    result: AckAdmissionResult,
    ackKey: ByteArray? = null,
    klass: AckVerificationClass? = null,
): AckAdmission = AckAdmission(result, ackKey, klass)

class ReadinessT84Test {
    private val rng = SecureRandom()

    // ------------------------------------------------------------ fixtures

    private class BytesKey(bytes: ByteArray) {
        private val b = bytes.copyOf()
        override fun equals(other: Any?): Boolean = other is BytesKey && b.contentEquals(other.b)
        override fun hashCode(): Int = b.contentHashCode()
    }

    /** The recipient key directory: a key present == an authenticated binding. */
    private class KeyTable : RecipientKeyResolver {
        private val table = LinkedHashMap<BytesKey, ByteArray>()
        override fun publicSigningKey(nodeId: ByteArray): ByteArray? =
            table[BytesKey(nodeId)]?.copyOf()

        fun put(nodeId: ByteArray, key: ByteArray) {
            table[BytesKey(nodeId)] = key.copyOf()
        }
    }

    private class Local(val id: ByteArray, val seed: ByteArray, val pub: ByteArray)

    private fun newLocal(): Local {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val identity = Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        return Local(identity.nodeId, ed.priv, ed.pub)
    }

    private class TestSigner(private val local: Local) : AckSignerSeam {
        override val nodeId: ByteArray get() = local.id.copyOf()
        override fun generation(): Long = 1L
        override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray =
            local.seed.copyOf()
    }

    /**
     * The minimal in-memory delivery repository: one row per msg_id holding
     * state + ack mode + the EXPECTED recipient (the C6.1 binding). The
     * guarded CAS mirrors the SQL one: state-only advance, binding preserved.
     */
    private class MemDeliveryRepo : DeliveryRepository {
        val records = LinkedHashMap<List<Byte>, DeliveryRecord>()

        override fun get(msgId: ByteArray): DeliveryLookup {
            if (msgId.size != 16) return DeliveryLookup.InvalidArgument
            val rec = records[msgId.toList()] ?: return DeliveryLookup.NotFound
            return DeliveryLookup.Found(rec)
        }

        override fun enqueue(msgId: ByteArray, ackMode: AckMode,
                             expectedRecipient: ByteArray?): EnqueueResult {
            if (msgId.size != 16) return EnqueueResult.InvalidArgument
            if ((ackMode == AckMode.NONE && expectedRecipient != null) ||
                (ackMode != AckMode.NONE && (expectedRecipient == null || expectedRecipient.size != 16))
            ) {
                return EnqueueResult.Corrupt
            }
            return when (val l = get(msgId)) {
                DeliveryLookup.NotFound -> {
                    records[msgId.toList()] = DeliveryRecord(
                        msgId, DeliveryState.QUEUED_DURABLY, ackMode, expectedRecipient)
                    EnqueueResult.Created
                }
                is DeliveryLookup.Found -> when {
                    l.record.state.isTerminal -> EnqueueResult.RejectedTerminalState
                    l.record.ackMode != ackMode -> EnqueueResult.ConflictRecipient
                    !sameBytes(l.record.expectedRecipientNodeId, expectedRecipient) ->
                        EnqueueResult.ConflictRecipient
                    else -> EnqueueResult.AlreadyQueuedSameBinding
                }
                else -> EnqueueResult.StorageFailure
            }
        }

        override fun transition(msgId: ByteArray,
                               transition: DeliveryTransition): TransitionResult {
            val rec = records[msgId.toList()] ?: return TransitionResult.UnknownMessage
            val target = when (transition) {
                DeliveryTransition.EXPIRE -> DeliveryState.EXPIRED
                DeliveryTransition.CANCEL -> DeliveryState.CANCELLED_LOCALLY
                DeliveryTransition.MARK_HANDED -> DeliveryState.HANDED_TO_RELAY
            }
            if (rec.state == target) return TransitionResult.AlreadyInTarget
            if (rec.state.isTerminal) return TransitionResult.RejectedState
            records[msgId.toList()] = rec.copy(state = target)
            return TransitionResult.Applied
        }

        override fun clear(msgId: ByteArray): ClearResult {
            if (msgId.size != 16) return ClearResult.InvalidArgument
            if (records.remove(msgId.toList()) == null) {
                return ClearResult.AlreadyAbsent
            }
            return ClearResult.Cleared
        }

        override fun acknowledgeBoundAndRetire(msgId: ByteArray,
                                              expectedRecipient: ByteArray): AckResult {
            if (msgId.size != 16 || expectedRecipient.size != 16) return AckResult.InvalidArgument
            val rec = records[msgId.toList()] ?: return AckResult.UnknownMessage
            if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) {
                return AckResult.DuplicateAuthenticatedAck
            }
            if (rec.state.isTerminal) return AckResult.RejectedState
            if (rec.ackMode != AckMode.SINGLE_RECIPIENT) return AckResult.NotAckEligible
            val bound = rec.expectedRecipientNodeId ?: return AckResult.Corrupt
            if (!bound.contentEquals(expectedRecipient)) return AckResult.RejectedState
            records[msgId.toList()] = rec.copy(state = DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
            return AckResult.Applied
        }
    }

    /** One node: A (origin) and B (recipient) hold delivery rows; R holt none. */
    private class Node(
        val label: String,
        val local: Local,
        val store: InMemoryMessageStore,
        val ackStore: AckObligationStore,
        val driver: AckObligationDriver,
        val pump: DurableAckPump,
        val dispatcher: AckDispatcher,
        val tracker: DeliveryTracker,
        val repo: MemDeliveryRepo,
    )

    private fun node(label: String, local: Local, keys: KeyTable): Node {
        val store = InMemoryMessageStore()
        val ackStore = InMemoryAckStore()
        val driver = AckObligationDriver(
            ackStore, TestSigner(local), Ed25519AckAuthenticator(keys), keys,
        )
        val pump = DurableAckPump(ackStore, { encoded, from ->
            driver.admitForeignCandidate(encoded, from)
        })
        val repo = MemDeliveryRepo()
        val tracker = DeliveryTracker(repo, Ed25519AckAuthenticator(keys))
        val dispatcher = AckDispatcher(
            lookupDeliveryRow = { tracker.lookup(it) },
            verifyOrigin = { tracker.acknowledge(it.msgId, it) },
            admitCandidate = { encoded, from -> pump.admit(encoded, from) },
        )
        return Node(label, local, store, ackStore, driver, pump, dispatcher, tracker, repo)
    }

    private class World(val a: Node, val r: Node, val b: Node, val keys: KeyTable) {
        /** The A-R-B topology: A and B never speak directly. */
        fun hopRtoA(frame: FrameV2, from: Node = r): AckDispatch =
            a.dispatcher.dispatch(frame, from.local.id)

        fun hopBtoR(frame: FrameV2, from: Node = b): AckDispatch =
            r.dispatcher.dispatch(frame, from.local.id)

        /** One epidemic turn: R offereth to [to] on LinkReady; [to] dispatcheth. */
        fun forwardTurn(from: Node, to: Node, now: Long): List<AckDispatch> {
            from.pump.onLinkReady(to.local.id, now)
            val batch = from.pump.nextBatch(to.local.id, now)
            return batch.copies.map { copy ->
                val verdict = to.dispatcher.dispatch(copy.let { decodedOf(it.encodedFrame) }, from.local.id)
                from.pump.onForwardOutcome(copy, to.local.id, accepted = true, now = now)
                verdict
            }
        }
    }

    private fun world(): World {
        val keys = KeyTable()
        val a = newLocal()
        val r = newLocal()
        val b = newLocal()
        // the authenticated bindings: A knows B's signing key (it addressed B),
        // and the RELAY knows nobody (it is an unknown-key relay by nature).
        keys.put(b.id, b.pub)
        return World(node("A", a, KeyTable().also { it.put(b.id, b.pub) }),
            node("R", r, KeyTable()),
            node("B", b, keys),
            keys)
    }

    private fun ackOf(msgId: ByteArray, signer: Local, ttl: Int = ACK_RELAY_INITIAL_TTL): FrameV2 =
        AckFrame.build(msgId, signer.seed, signer.id, ByteArray(4) { 7 }, ttl = ttl)

    private fun msgId(seed: Int): ByteArray = ByteArray(16) { (it + seed).toByte() }

    private suspend fun heldFrames(store: MessageStore): Int = store.allHeldMsgIds().size

    private fun enqueuedAtOrigin(world: World, mid: ByteArray, recipient: Local,
                                 state: DeliveryState = DeliveryState.HANDED_TO_RELAY): DeliveryTracker {
        Assert.assertEquals(
            EnqueueResult.Created,
            world.a.tracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, recipient.id),
        )
        if (state == DeliveryState.HANDED_TO_RELAY) {
            Assert.assertEquals(TransitionResult.Applied, world.a.tracker.markHandedToRelay(mid))
        }
        return world.a.tracker
    }

    private fun stateOf(tracker: DeliveryTracker, mid: ByteArray): DeliveryState? =
        (tracker.lookup(mid) as? DeliveryLookup.Found)?.record?.state

    // ------------------------------------------------------------ W1

    /** W1 -- the ORIGIN classification: a durable delivery row maketh an ACK
     *  origin verification, and only that road reacheth DELIVERED. */
    @Test
    fun test_w01_an_ack_with_a_durable_row_is_origin_verification() {
        val w = world()
        val mid = msgId(1)
        enqueuedAtOrigin(w, mid, w.b.local)
        val verdict = w.a.dispatcher.dispatch(ackOf(mid, w.b.local), w.r.local.id)
        Assert.assertTrue("the origin road is taken", verdict is AckDispatch.OriginVerification)
        Assert.assertEquals(
            io.godstone.mesh.delivery.AckDispatchClass.ORIGIN_VERIFICATION,
            verdict.dispatchClass,
        )
        Assert.assertTrue("the intended recipient verified", (verdict as AckDispatch.OriginVerification).accepted)
        Assert.assertEquals(AckResult.Applied, verdict.result)
        Assert.assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(w.a.tracker, mid))
        Assert.assertEquals("nothing entered the relay namespace at the origin", 0, w.a.ackStore.countFrames())
    }

    // ------------------------------------------------------------ W2

    /** W2 -- the required three-node scenario: A -> R -> B and B's ACK ->
     *  R -> A with NO A/B link, reaching DELIVERED at the origin. */
    @Test
    fun test_w02_the_three_node_receipt_returneth_home_without_a_direct_link() {
        val w = world()
        val mid = msgId(2)
        enqueuedAtOrigin(w, mid, w.b.local)

        // B holds the delivery row for the message it authored the answer to,
        // i.e. B is the RECIPIENT: its answer is a canonical ACK.
        val ack = ackOf(mid, w.b.local)

        // B answers; the relay is the immediate hop.
        val atRelay = w.hopBtoR(ack)
        Assert.assertTrue("the relay carrieth it, never discardeth it (was UnknownMessage)",
            atRelay is AckDispatch.OpaqueRelay)
        Assert.assertTrue((atRelay as AckDispatch.OpaqueRelay).accepted)
        Assert.assertEquals(1, w.r.ackStore.countFrames())
        Assert.assertEquals("a relay never claimeth recipient verification",
            AckVerificationClass.OPAQUE_CANDIDATE, atRelay.verificationClass)

        // the relay's pump returneth it to A on LinkReady
        val forwards = w.forwardTurn(w.r, w.a, now = 1_000L)
        Assert.assertEquals("exactly one copy homeward", 1, forwards.size)
        Assert.assertTrue(forwards[0] is AckDispatch.OriginVerification)
        Assert.assertTrue((forwards[0] as AckDispatch.OriginVerification).accepted)

        Assert.assertEquals("A reacheth the only truthful terminal state",
            DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(w.a.tracker, mid))
        Assert.assertEquals("custody is not retired by a local ATT success",
            1, w.r.ackStore.countFrames())
    }

    // ------------------------------------------------------------ W3

    /** W3 -- the separate namespace: a relay's custody liveth in ack_frames and
     *  NEVER in the message store (the card's named falsification, second limb). */
    @Test
    fun test_w03_relay_custody_never_entereth_the_message_namespace() = runTest {
        val w = world()
        val mid = msgId(3)
        val ack = ackOf(mid, w.b.local)
        val before = heldFrames(w.r.store)
        w.hopBtoR(ack)
        Assert.assertEquals(1, w.r.ackStore.countFrames())
        Assert.assertEquals("the message store is untouched by an ACK", before, heldFrames(w.r.store))
        // ... and the candidate's local cache key is the ACK-CACHE domain, never
        // the message identity: the same msg_id may carry FOUR candidates.
        val signature = ack.payload.copyOfRange(0, 64)
        val key = io.godstone.mesh.delivery.AckCacheKey.compute(mid, w.b.local.id, signature)
        Assert.assertNotNull(key)
        Assert.assertNotEquals(
            "the ack key is NOT the message id",
            mid.toList(), key!!.toList(),
        )
        val rows = w.r.ackStore.listCandidates(64) as CandidateList.Records
        Assert.assertEquals(1, rows.records.size)
        Assert.assertEquals(AckVerificationClass.OPAQUE_CANDIDATE, rows.records[0].verificationClass)
    }

    // ------------------------------------------------------------ W4

    /** W4 -- an ACK is never echoed back to the peer it came from. */
    @Test
    fun test_w04_a_candidate_is_never_echoed_to_receivedFrom() {
        val w = world()
        val mid = msgId(4)
        w.hopBtoR(ackOf(mid, w.b.local))       // receivedFrom == B
        w.r.pump.onLinkReady(w.b.local.id, 10L)
        val backToB = w.r.pump.nextBatch(w.b.local.id, 10L)
        Assert.assertEquals(0, backToB.copies.size)
        Assert.assertEquals(1, backToB.refusals[AckForwardRefusal.RECEIVED_FROM_THIS_PEER])
        w.r.pump.onLinkReady(w.a.local.id, 10L)
        Assert.assertEquals("and it IS offered to the other trusted peer",
            1, w.r.pump.nextBatch(w.a.local.id, 10L).copies.size)
    }

    // ------------------------------------------------------------ W5

    /** W5 -- the TTL/hop statute: exactly once per copy, the canonical 12
     *  initial, and every out-of-band TTL refused BY NAME. */
    @Test
    fun test_w05_the_forward_copy_taketh_ttl_and_hop_exactly_once() {
        val w = world()
        val mid = msgId(5)
        val original = ackOf(mid, w.b.local, ttl = ACK_RELAY_INITIAL_TTL)
        w.hopBtoR(original)
        w.r.pump.onLinkReady(w.a.local.id, 5L)
        val batch = w.r.pump.nextBatch(w.a.local.id, 5L)
        Assert.assertEquals(1, batch.copies.size)
        val copy = batch.copies[0]
        Assert.assertEquals(ACK_RELAY_INITIAL_TTL - 1, copy.ttl)
        Assert.assertEquals(1, copy.hopCount)
        Assert.assertEquals(0, copy.let { decodedOf(it.encodedFrame) }.flags)
        Assert.assertEquals("the 80-byte payload travelleth whole",
            80, copy.let { decodedOf(it.encodedFrame) }.payload.size)
        Assert.assertArrayEquals("the 80-byte signed payload is preserved byte for byte",
            original.payload, copy.let { decodedOf(it.encodedFrame) }.payload)
        Assert.assertArrayEquals("the msgId is preserved",
            original.msgId, copy.let { decodedOf(it.encodedFrame) }.msgId)
        Assert.assertArrayEquals("the canonical routing hint is preserved",
            original.routingTag, copy.let { decodedOf(it.encodedFrame) }.routingTag)

        // the RETRY re-emiteth the IDENTICAL bytes: never a second decrement
        val again = w.r.pump.nextBatch(w.a.local.id, 5L + ACK_RELAY_RETRY_INTERVAL_MS)
        Assert.assertEquals(1, again.copies.size)
        Assert.assertArrayEquals(copy.encodedFrame, again.copies[0].encodedFrame)
        Assert.assertEquals(copy.ttl, again.copies[0].ttl)
        Assert.assertEquals(copy.hopCount, again.copies[0].hopCount)

        // out-of-band TTLs are refused by name, and no copy is built
        val exhausted = world()
        exhausted.hopBtoR(ackOf(msgId(51), exhausted.b.local, ttl = 1))
        exhausted.r.pump.onLinkReady(exhausted.a.local.id, 5L)
        val e = exhausted.r.pump.nextBatch(exhausted.a.local.id, 5L)
        Assert.assertEquals(0, e.copies.size)
        Assert.assertEquals(1, e.refusals[AckForwardRefusal.TTL_EXHAUSTED])

        val inflated = world()
        inflated.hopBtoR(ackOf(msgId(52), inflated.b.local, ttl = 13))
        inflated.r.pump.onLinkReady(inflated.a.local.id, 5L)
        val i = inflated.r.pump.nextBatch(inflated.a.local.id, 5L)
        Assert.assertEquals(0, i.copies.size)
        Assert.assertEquals(1, i.refusals[AckForwardRefusal.TTL_ABOVE_PRODUCTION_INITIAL])
    }

    // ------------------------------------------------------------ W6

    /** W6 -- scheduling and budgets: no LinkReady, no offer; batch 32; one
     *  retry per candidate/peer per 30 s; burst 16 with a 1/s refill. */
    @Test
    fun test_w06_the_pump_is_scheduled_bounded_and_rate_limited() {
        val w = world()
        val mid = msgId(6)
        w.hopBtoR(ackOf(mid, w.b.local))
        val unscheduled = w.r.pump.nextBatch(w.a.local.id, 1L)
        Assert.assertEquals(0, unscheduled.copies.size)
        Assert.assertEquals(1, unscheduled.refusals[AckForwardRefusal.NOT_SCHEDULED])
        Assert.assertFalse(w.r.pump.isScheduled(w.a.local.id))

        w.r.pump.onLinkReady(w.a.local.id, 1L)
        Assert.assertTrue(w.r.pump.isScheduled(w.a.local.id))
        Assert.assertEquals(1, w.r.pump.nextBatch(w.a.local.id, 1L).copies.size)
        // the 30 s retry gate
        val gated = w.r.pump.nextBatch(w.a.local.id, 1L + ACK_RELAY_RETRY_INTERVAL_MS - 1)
        Assert.assertEquals(0, gated.copies.size)
        Assert.assertEquals(1, gated.refusals[AckForwardRefusal.RETRY_WINDOW])
        // exactly at the boundary it is offered again
        Assert.assertEquals(1, w.r.pump.nextBatch(w.a.local.id,
            1L + 2 * ACK_RELAY_RETRY_INTERVAL_MS).copies.size)

        // the burst: 16 distinct candidates to one peer at one instant
        val burst = world()
        for (i in 0 until ACK_RELAY_BURST_PER_PEER + 4) {
            burst.hopBtoR(ackOf(msgId(600 + i), burst.b.local, ttl = ACK_RELAY_INITIAL_TTL))
        }
        burst.r.pump.onLinkReady(burst.a.local.id, 9L)
        val batched = burst.r.pump.nextBatch(burst.a.local.id, 9L)
        Assert.assertEquals(ACK_RELAY_BURST_PER_PEER, batched.copies.size)
        Assert.assertTrue("the batch bound is never exceeded",
            batched.copies.size <= ACK_RELAY_BATCH_LIMIT)
        Assert.assertEquals(4, batched.refusals[AckForwardRefusal.PEER_RATE_LIMIT])
        // ONE SECOND later (the pump's clock is milliseconds), one more token
        Assert.assertEquals(1, burst.r.pump.nextBatch(
            burst.a.local.id, 9L + io.godstone.mesh.delivery.ACK_RELAY_RATE_MS).copies.size)
    }

    // ------------------------------------------------------------ W7

    /** W7 -- the card's named falsification, third limb: a LOCAL ATT ACCEPTANCE
     *  never retireth ACK custody; only expiry and quota do. */
    @Test
    fun test_w07_a_local_att_acceptance_never_retireth_custody() {
        val w = world()
        val mid = msgId(7)
        w.hopBtoR(ackOf(mid, w.b.local))
        w.r.pump.onLinkReady(w.a.local.id, 20L)
        val copy = w.r.pump.nextBatch(w.a.local.id, 20L).copies.single()
        w.r.pump.onForwardOutcome(copy, w.a.local.id, accepted = true, now = 20L)
        Assert.assertTrue("the radio accepted some bytes; the custody standeth",
            w.r.pump.custodyHolds(copy.ackKey))
        Assert.assertEquals(1, w.r.ackStore.countFrames())
        // a REFUSED hand-off likewise retireth nothing
        w.r.pump.onForwardOutcome(copy, w.a.local.id, accepted = false, now = 20L)
        Assert.assertEquals(1, w.r.ackStore.countFrames())
        // and the candidate is offered again after the retry window
        Assert.assertEquals(1, w.r.pump.nextBatch(w.a.local.id,
            20L + ACK_RELAY_RETRY_INTERVAL_MS).copies.size)
    }

    // ------------------------------------------------------------ W8

    /** W8 -- an ACK that PRECEDETH its message is not discarded; when the
     *  origin row appears later it is the origin road that decideth. */
    @Test
    fun test_w08_an_ack_preceding_its_message_is_carried_not_discarded() {
        val w = world()
        val mid = msgId(8)
        val ack = ackOf(mid, w.b.local)
        // no delivery row standeth ANYWHERE yet
        Assert.assertTrue(w.a.tracker.lookup(mid) is DeliveryLookup.NotFound)
        val early = w.hopBtoR(ack)
        Assert.assertTrue("relay traffic, never an automatic discard",
            early is AckDispatch.OpaqueRelay)
        Assert.assertEquals(1, w.r.ackStore.countFrames())

        // "and during the original message": the same ACK arriving AGAIN while
        // the relay already holdeth it is a duplicate, not a second slot
        val again = w.hopBtoR(ack)
        Assert.assertTrue(again is AckDispatch.OpaqueRelay)
        Assert.assertEquals("the same signature is ONE candidate",
            1, w.r.ackStore.countFrames())

        // the origin's row appears; the origin road now decideth, and the relay
        // custody is untouched by it
        enqueuedAtOrigin(w, mid, w.b.local)
        val atOrigin = w.a.dispatcher.dispatch(ack, w.r.local.id)
        Assert.assertTrue(atOrigin is AckDispatch.OriginVerification)
        Assert.assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(w.a.tracker, mid))
        Assert.assertEquals("the relay's candidacy standeth independently",
            1, w.r.ackStore.countFrames())
    }

    // ------------------------------------------------------------ W9

    /** W9 -- a forged candidate is refused and cannot suppress a later VALID
     *  one; a rejected origin candidate leaveth delivery unchanged. */
    @Test
    fun test_w09_a_forged_candidate_cannot_suppress_a_later_valid_signature() {
        val w = world()
        val mid = msgId(9)
        // An available authenticated key for B, and a FORGED signature.
        val forged = FrameV2(
            type = TypeV2.ACK, msgId = mid, routingTag = ByteArray(4) { 7 },
            ttl = ACK_RELAY_INITIAL_TTL, hopCount = 0, flags = 0,
            payload = ByteArray(64) { 0x5A } + w.b.local.id,
        )
        // B's own node carrieth B's key, so the forgery is KNOWN-INVALID there.
        val refused = w.b.dispatcher.dispatch(forged, w.r.local.id)
        Assert.assertTrue(refused is AckDispatch.Refused)
        Assert.assertEquals(AckRefusalReason.KNOWN_INVALID_SIGNATURE,
            (refused as AckDispatch.Refused).reason)
        Assert.assertEquals("nothing was written", 0, w.b.ackStore.countFrames())

        // ... and the VALID signature for the same pair is admitted afterwards
        w.hopBtoR(ackOf(mid, w.b.local))
        Assert.assertEquals(1, w.r.ackStore.countFrames())

        // at the origin: a rejected candidate cannot suppress the valid one
        enqueuedAtOrigin(w, mid, w.b.local)
        val wrongSigner = newLocal()
        val badAck = ackOf(mid, wrongSigner)
        val rejected = w.a.dispatcher.dispatch(badAck, w.r.local.id)
        Assert.assertTrue(rejected is AckDispatch.OriginVerification)
        Assert.assertFalse((rejected as AckDispatch.OriginVerification).accepted)
        Assert.assertEquals("delivery is UNCHANGED by a rejected candidate",
            DeliveryState.HANDED_TO_RELAY, stateOf(w.a.tracker, mid))
        val good = w.a.dispatcher.dispatch(ackOf(mid, w.b.local), w.r.local.id)
        Assert.assertTrue((good as AckDispatch.OriginVerification).accepted)
        Assert.assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(w.a.tracker, mid))
    }

    // ------------------------------------------------------------ W10

    /** W10 -- process death and reconnect: a NEW pump over the SAME durable
     *  store rebuildeth custody from the store alone, and reacheth the origin. */
    @Test
    fun test_w10_relay_process_death_and_reconnect_still_returneth_the_receipt() {
        val w = world()
        val mid = msgId(10)
        enqueuedAtOrigin(w, mid, w.b.local)
        w.hopBtoR(ackOf(mid, w.b.local))
        Assert.assertEquals(1, w.r.ackStore.countFrames())

        // PROCESS DEATH: a fresh pump over the SAME store; no memory survives.
        val reborn = DurableAckPump(w.r.ackStore, { encoded, from ->
            w.r.driver.admitForeignCandidate(encoded, from)
        })
        Assert.assertEquals("custody surviveth the process",
            1, reborn.custodyCount())
        Assert.assertFalse("nothing is scheduled before LinkReady",
            reborn.isScheduled(w.a.local.id))
        reborn.onLinkReady(w.a.local.id, 50L)
        val batch = reborn.nextBatch(w.a.local.id, 50L)
        Assert.assertEquals(1, batch.copies.size)
        val verdict = w.a.dispatcher.dispatch(batch.copies[0].let { decodedOf(it.encodedFrame) }, w.r.local.id)
        Assert.assertTrue((verdict as AckDispatch.OriginVerification).accepted)
        Assert.assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(w.a.tracker, mid))

        // the retention sweep taketh the conservative branch EXACTLY ONCE and
        // never replenishes a life
        val sweep = reborn.sweep(now = 50L, wallEstimateMs = 0L,
            continuity = ClockContinuityStamp.Unknown)
        Assert.assertEquals(1, sweep.scanned)
        Assert.assertEquals(0, sweep.refusedReplenish)
        Assert.assertTrue("an unknown continuity debiteth at least one hour",
            sweep.debited == 1 || sweep.expired == 1)

        // the debit never REPLENISHETH: an equal or greater value changeth
        // nothing, so no restart and no duplicate can extend a life
        val standing = (w.r.ackStore.listCandidates(64) as CandidateList.Records).records
        Assert.assertEquals("the estate standeth after a one-hour debit", 1, standing.size)
        val candidate = standing[0]
        Assert.assertFalse(
            "a debit may never EXTEND a candidate's life",
            w.r.ackStore.debitCandidateLifetime(candidate.ackKey, Long.MAX_VALUE),
        )
        Assert.assertFalse(
            "an EQUAL value changeth nothing either",
            w.r.ackStore.debitCandidateLifetime(candidate.ackKey, candidate.remainingLifetimeMs),
        )
        Assert.assertTrue(
            "a strictly shorter life IS applied",
            w.r.ackStore.debitCandidateLifetime(candidate.ackKey,
                candidate.remainingLifetimeMs - 1_000L),
        )
    }

    // ------------------------------------------------------------ W11

    /** W11 -- an expired or cancelled origin cannot be acknowledged, and a
     *  TTL-exhausted candidate is never forwarded. */
    @Test
    fun test_w11_an_expired_or_cancelled_origin_and_ttl_exhaustion() {
        val w = world()
        val expiredMid = msgId(11)
        enqueuedAtOrigin(w, expiredMid, w.b.local)
        Assert.assertEquals(TransitionResult.Applied, w.a.tracker.expire(expiredMid))
        val atExpired = w.a.dispatcher.dispatch(ackOf(expiredMid, w.b.local), w.r.local.id)
        Assert.assertTrue(atExpired is AckDispatch.OriginVerification)
        Assert.assertFalse((atExpired as AckDispatch.OriginVerification).accepted)
        Assert.assertEquals(DeliveryState.EXPIRED, stateOf(w.a.tracker, expiredMid))

        val cancelledMid = msgId(12)
        enqueuedAtOrigin(w, cancelledMid, w.b.local)
        Assert.assertEquals(TransitionResult.Applied, w.a.tracker.cancel(cancelledMid))
        val atCancelled = w.a.dispatcher.dispatch(ackOf(cancelledMid, w.b.local), w.r.local.id)
        Assert.assertFalse((atCancelled as AckDispatch.OriginVerification).accepted)
        Assert.assertEquals(DeliveryState.CANCELLED_LOCALLY, stateOf(w.a.tracker, cancelledMid))

        // a TTL-exhausted candidate may be carried but never forwarded
        val ttlMid = msgId(13)
        w.hopBtoR(ackOf(ttlMid, w.b.local, ttl = 1))
        w.r.pump.onLinkReady(w.a.local.id, 60L)
        val batch = w.r.pump.nextBatch(w.a.local.id, 60L)
        Assert.assertEquals(0, batch.copies.size)
        Assert.assertEquals(1, batch.refusals[AckForwardRefusal.TTL_EXHAUSTED])
        Assert.assertEquals("the estate is retained, never silently dropped",
            1, w.r.ackStore.countFrames())
    }

    // ------------------------------------------------------------ W12

    /** W12 -- capacity is refused EXPLICITLY, and a refusal poisoneth nothing:
     *  the original message and the origin verification state are untouched. */
    @Test
    fun test_w12_candidate_capacity_is_refused_explicitly() = runTest {
        val w = world()
        val mid = msgId(14)
        enqueuedAtOrigin(w, mid, w.b.local)
        // Four candidates per (msgId, recipient) pair. The SAME pair is meant:
        // the claimed recipient is fixed and only the SIGNATURE varieth, so the
        // four are four distinct candidates of one pair (never deduped against
        // each other) and the fifth and sixth are refused explicitly.
        val claimed = newLocal()
        var refusedSeen = 0
        for (i in 0 until 6) {
            val signature = ByteArray(64) { (it + i).toByte() }
            val frame = FrameV2(
                type = TypeV2.ACK, msgId = mid, routingTag = ByteArray(4) { 7 },
                ttl = ACK_RELAY_INITIAL_TTL, hopCount = 0, flags = 0,
                payload = signature + claimed.id,
            )
            val verdict = w.r.dispatcher.dispatch(frame, w.a.local.id)
            if (verdict is AckDispatch.Refused) {
                Assert.assertEquals(AckRefusalReason.CANDIDATE_CAPACITY,
                    verdict.reason)
                refusedSeen += 1
            }
            Assert.assertFalse("an unknown-key relay never claimeth recipient verification",
                verdict is AckDispatch.OpaqueRelay &&
                    (verdict as AckDispatch.OpaqueRelay).verificationClass ==
                    AckVerificationClass.VERIFIED_RECIPIENT)
        }
        Assert.assertEquals("the fifth and the sixth are refused, not silently dropped",
            2, refusedSeen)
        Assert.assertEquals("four candidates of one pair stand", 4, w.r.ackStore.countFrames())
        Assert.assertEquals("the origin state is untouched",
            DeliveryState.HANDED_TO_RELAY, stateOf(w.a.tracker, mid))
        Assert.assertEquals("the original message is untouched", 0, heldFrames(w.r.store))
    }

    // ------------------------------------------------------------ W13

    /** W13 -- malformed and non-canonical ACKs are refused by name before any
     *  write, and a FAILED delivery lookup is never read as relay traffic. */
    @Test
    fun test_w13_malformed_frames_and_a_failed_lookup_are_refused_by_name() {
        val w = world()
        val mid = msgId(15)
        val shortPayload = FrameV2(
            type = TypeV2.ACK, msgId = mid, routingTag = ByteArray(4) { 7 },
            ttl = ACK_RELAY_INITIAL_TTL, hopCount = 0, flags = 0,
            payload = ByteArray(16),
        )
        var verdict = w.r.dispatcher.dispatch(shortPayload, w.a.local.id)
        Assert.assertEquals(AckRefusalReason.MALFORMED_PAYLOAD,
            (verdict as AckDispatch.Refused).reason)

        val flagged = FrameV2(
            type = TypeV2.ACK, msgId = mid, routingTag = ByteArray(4) { 7 },
            ttl = ACK_RELAY_INITIAL_TTL, hopCount = 0, flags = FrameV2.RELAY_OK,
            payload = ByteArray(80),
        )
        verdict = w.r.dispatcher.dispatch(flagged, w.a.local.id)
        Assert.assertEquals(AckRefusalReason.NON_CANONICAL_FLAGS,
            (verdict as AckDispatch.Refused).reason)
        Assert.assertEquals("no write preceded either refusal", 0, w.r.ackStore.countFrames())

        // a delivery lookup that FAILED is a refusal, never "no row -> relay"
        val failing = AckDispatcher(
            lookupDeliveryRow = { DeliveryLookup.StorageFailure },
            verifyOrigin = { AckResult.StorageFailure },
            admitCandidate = { _, _ -> admissionOf(AckAdmissionResult.Stored(ByteArray(32))) },
        )
        verdict = failing.dispatch(ackOf(mid, w.b.local), w.a.local.id)
        Assert.assertEquals(AckRefusalReason.DELIVERY_STATE_UNREADABLE,
            (verdict as AckDispatch.Refused).reason)
        val corrupt = AckDispatcher(
            lookupDeliveryRow = { DeliveryLookup.Corrupt },
            verifyOrigin = { AckResult.Corrupt },
            admitCandidate = { _, _ -> admissionOf(AckAdmissionResult.Stored(ByteArray(32))) },
        )
        verdict = corrupt.dispatch(ackOf(mid, w.b.local), w.a.local.id)
        Assert.assertEquals(AckRefusalReason.DELIVERY_STATE_UNREADABLE,
            (verdict as AckDispatch.Refused).reason)
    }

    // ------------------------------------------------------------ W14

    /** W14 -- the WIRING: MeshNode route eth an ACK to the dispatcher before any
     *  generic message TTL/dedup/store handling, and the historical
     *  point-to-point face standeth when no namespace is bound. */
    @Test
    fun test_w14_meshnode_dispatcheth_the_ack_and_never_discardeth_relay_traffic() = runTest {
        val w = world()
        val mid = msgId(16)
        val dh = X25519Keys.generate(rng)
        val identity = Identity.fromKeyMaterial(
            w.a.local.pub, w.a.local.seed, dh.pub, dh.priv,
        )
        val wired = MeshNode(null, identity, w.a.store, w.a.tracker)
        Assert.assertNull("no namespace is bound by default", wired.ackDispatcher)
        val ack = ackOf(mid, w.b.local)
        val historical = wired.ingestInbound(ack, w.r.local.id)
        Assert.assertFalse(
            "the historical face is point-to-point: an unknown msgId is refused",
            historical,
        )
        Assert.assertEquals(0, w.a.ackStore.countFrames())

        // bind the dispatcher: the SAME frame is now carried as relay custody
        wired.ackDispatcher = w.a.dispatcher
        val carried = wired.ingestInbound(ack, w.r.local.id)
        Assert.assertTrue("relay traffic is carried, never silently dropped", carried)
        Assert.assertEquals(1, w.a.ackStore.countFrames())
        Assert.assertEquals("and the message namespace is untouched",
            0, heldFrames(w.a.store))
        Assert.assertEquals("the router never saw it (no bloom/inventory entry)",
            0, heldFrames(w.a.store))
    }
}
