package io.godstone.mesh

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.ClearResult
import io.godstone.mesh.delivery.DeliveryRepository
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRecord
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.RecipientKeyResolver
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.test.runTest
import org.junit.Test
import java.security.SecureRandom
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Stage 4C.1 / C6 + C7 -- the MeshNode outbound (C6) and inbound-ACK (C7) wiring,
 * exercised at the NODE level on a real [MeshNode] (no Android Context, no
 * Robolectric). The identity is injected via the test primary constructor
 * (mirrors iOS `MeshNode(identity:store:deliveryTracker:)`), so `dispatchSos` /
 * `ingestInbound` run in a pure JVM `:mesh:testDebugUnitTest`.
 *
 * C6 (outbound): `dispatchSos` persists BEFORE driving the delivery tracker
 * (persist-before-tracker, extending the 4B.1 persist-before-forward gate), then
 * `enqueue(msgId, AckMode.NONE, expectedRecipient = null)` (SOS broadcast -> no
 * recipient binding; a NONE-mode message can never be acknowledged) and
 * `markHandedToRelay` per successful send. Asserts:
 *   - persist succeeds + N successful sends -> HandedToRelays(N) + HANDED_TO_RELAY
 *   - persist succeeds + 0 peers -> QueuedLocally + QUEUED_DURABLY
 *   - persist fails -> NotPersisted + tracker UNTOUCHED (no delivery claimed for
 *     a message this node does not durably hold)
 *
 * C7 (inbound ACK): `ingestInbound` routes an ACK frame to `deliveryTracker
 * .acknowledge`, which binds it to the durable expected recipient (C2) and
 * advances to ACKNOWLEDGED only on cryptographic proof. The Bool the seam returns
 * is true for Applied / AlreadyAcknowledged / DuplicateAuthenticatedAck and false
 * for every rejection. Asserts:
 *   - ACK from the bound recipient -> ACKNOWLEDGED_BY_RECIPIENT (Applied -> true)
 *   - ACK from a different recipient -> rejected, stays HANDED_TO_RELAY
 *   - production fail-closed (UnresolvedRecipientKeyResolver) -> rejected,
 *     stays HANDED_TO_RELAY (no delivery on host-only evidence; A-03/ADR-005 OPEN)
 *   - a non-ACK frame is routed to the epidemic router, NOT the tracker
 *
 * The DeliveryTracker truth-table / negative-ACK matrix / reboot recovery are
 * covered in [io.godstone.mesh.delivery.DeliveryTrackerTest] and
 * [io.godstone.mesh.delivery.SqliteDeliveryRepositoryTest]; these tests pin the
 * MeshNode CALL-SITE wiring (the C6/C7 seams) on top of that proven machine.
 */
class MeshNodeDeliveryIntegrationTest {

    private val rng = SecureRandom()

    private fun msgId(seed: Byte) = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }
    private fun nodeA() = ByteArray(16) { 0x01 }
    private fun nodeB() = ByteArray(16) { 0x02 }

    /**
     * In-memory [DeliveryRepository] mirroring [io.godstone.mesh.delivery
     * .SqliteDeliveryRepository] over a real DB: one [DeliveryRecord] per msg_id
     * holding state + ack mode + recipient; [transition] / [acknowledgeBound]
     * preserve the binding (state-only advance). C6.4: implements the new
     * [DeliveryTransition] + typed [ClearResult] + 16-byte [InvalidArgument] guard.
     */
    private class InMemoryDeliveryRepository : DeliveryRepository {
        val records = mutableMapOf<List<Byte>, DeliveryRecord>()
        private fun k(m: ByteArray) = m.toList()
        override fun get(msgId: ByteArray): DeliveryLookup {
            if (msgId.size != 16) return DeliveryLookup.InvalidArgument
            val rec = records[k(msgId)] ?: return DeliveryLookup.NotFound
            return DeliveryLookup.Found(rec)
        }
        override fun enqueue(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): EnqueueResult {
            if (msgId.size != 16) return EnqueueResult.InvalidArgument
            if (!bindingConsistent(ackMode, expectedRecipient)) return EnqueueResult.Corrupt
            return when (val l = get(msgId)) {
                DeliveryLookup.NotFound -> {
                    records[k(msgId)] = DeliveryRecord(msgId, DeliveryState.QUEUED_DURABLY, ackMode, expectedRecipient)
                    EnqueueResult.Created
                }
                is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
                DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
                DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
                DeliveryLookup.InvalidArgument -> EnqueueResult.InvalidArgument
            }
        }
        override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult {
            if (msgId.size != 16) return TransitionResult.InvalidArgument
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
                            records[k(msgId)] = l.record.copy(state = target) // preserve ackMode + recipient
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
            if (msgId.size != 16) return AckResult.InvalidArgument
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
                    if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) AckResult.DuplicateAuthenticatedAck
                    else {
                        records[k(msgId)] = rec.copy(state = DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
                        AckResult.Applied
                    }
                }
            }
        }
        override fun clear(msgId: ByteArray): ClearResult {
            if (msgId.size != 16) return ClearResult.InvalidArgument
            return if (records.remove(k(msgId)) != null) ClearResult.Cleared else ClearResult.AlreadyAbsent
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

        private fun classifyExisting(rec: DeliveryRecord, ackMode: AckMode, expectedRecipient: ByteArray?): EnqueueResult {
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

    /** Resolver binding two distinct node ids to two distinct keys (C2 binding). */
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

    /** A [MessageStore] whose persist always fails -- the C6 persist-failure gate. */
    private class FailingMessageStore : MessageStore {
        override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult =
            PersistResult.FAILED_STORAGE
        override suspend fun allHeldOrderedByPriority(): List<FrameV2> = emptyList()
        override suspend fun allHeldMsgIds(): List<ByteArray> = emptyList()
        override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {}
        override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {}
    }

    private fun realKeypair(): Pair<ByteArray, ByteArray> {
        val kp = Ed25519Keys.generate(rng)
        return kp.pub to kp.priv
    }

    /** A fresh injected identity (no Context / no Keystore). */
    private fun freshIdentity(): Identity {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        return Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }

    private fun rec(j: InMemoryDeliveryRepository, mid: ByteArray): DeliveryRecord =
        (j.get(mid) as DeliveryLookup.Found).record

    /** C6.4-B: the lossy `state(mid)` seam is gone; extract the state from
     *  [DeliveryTracker.lookup] for a valid-state assertion. */
    private fun stateOf(tracker: DeliveryTracker, mid: ByteArray): DeliveryState? =
        when (val l = tracker.lookup(mid)) {
            is DeliveryLookup.Found -> l.record.state
            else -> null
        }

    /** Build a node over [store] + an in-memory repository/tracker with the
     *  supplied resolver. Returns the node + the repository so tests can assert
     *  on the durable delivery state. The caller retains its own [store]
     *  reference. */
    private fun makeNode(
        store: MessageStore,
        resolver: RecipientKeyResolver,
    ): Pair<MeshNode, InMemoryDeliveryRepository> {
        val journal = InMemoryDeliveryRepository()
        val tracker = DeliveryTracker(journal, Ed25519AckAuthenticator(resolver))
        val node = MeshNode(ctx = null, identity = freshIdentity(), store = store, deliveryTracker = tracker)
        return node to journal
    }

    // --- C6: outbound SOS dispatch drives the delivery tracker ---

    /** C6: persist succeeds + 1 successful send -> HandedToRelays(1) and the
     *  tracker reaches HANDED_TO_RELAY with AckMode.NONE and NO recipient binding
     *  (persist-before-tracker: enqueue runs only after persist succeeded,
     *  markHandedToRelay after the send returned true). */
    @Test
    fun `C6 dispatchSos with a successful send reaches HANDED_TO_RELAY as NONE`() = runTest {
        val store = InMemoryMessageStore()
        val (node, journal) = makeNode(store, UnresolvedRecipientKeyResolver)
        node.injectPeerForTest(ByteArray(16) { 0x10 })
        val result = node.dispatchSos(ByteArray(8)) { _, _ -> true }
        assertEquals(SosDispatchResult.HandedToRelays(1), result)
        val mid = store.allHeldMsgIds().single()
        val r = rec(journal, mid)
        assertEquals(DeliveryState.HANDED_TO_RELAY, r.state)
        assertEquals(AckMode.NONE, r.ackMode, "SOS broadcast is AckMode.NONE")
        assertNull(r.expectedRecipientNodeId, "SOS broadcast binds NO recipient")
    }

    /** C6: persist succeeds + 0 peers -> QueuedLocally and the tracker reaches
     *  QUEUED_DURABLY (enqueued, but never handed -- no peer to hand to). */
    @Test
    fun `C6 dispatchSos with zero peers stays QUEUED_DURABLY`() = runTest {
        val store = InMemoryMessageStore()
        val (node, journal) = makeNode(store, UnresolvedRecipientKeyResolver)
        val result = node.dispatchSos(ByteArray(8)) { _, _ -> true }
        assertEquals(SosDispatchResult.QueuedLocally, result)
        val mid = store.allHeldMsgIds().single()
        assertEquals(DeliveryState.QUEUED_DURABLY, rec(journal, mid).state)
        assertEquals(AckMode.NONE, rec(journal, mid).ackMode)
    }

    /** C6: persist fails -> NotPersisted, ZERO sends, and the tracker is NOT
     *  touched -- no delivery is claimed for a message this node does not durably
     *  hold (persist-before-tracker). */
    @Test
    fun `C6 dispatchSos persist failure leaves the tracker untouched`() = runTest {
        val store = FailingMessageStore()
        val (node, journal) = makeNode(store, UnresolvedRecipientKeyResolver)
        node.injectPeerForTest(ByteArray(16) { 0x10 })
        var sendCalls = 0
        val result = node.dispatchSos(ByteArray(8)) { _, _ -> sendCalls++; true }
        assertEquals(SosDispatchResult.NotPersisted, result)
        assertEquals(0, sendCalls, "persistence failure must exit before any transport operation")
        assertTrue(journal.records.isEmpty(), "tracker must not record a message that was not durably held")
        assertTrue(store.allHeldMsgIds().isEmpty())
    }

    // --- C7: inbound ACK dispatch binds to the durable expected recipient ---

    /** C7: an ACK from the bound recipient advances the state to
     *  ACKNOWLEDGED_BY_RECIPIENT. The expected recipient was bound in durable
     *  outbound state INDEPENDENT of the ACK (C1/C2). ingestInbound returns true
     *  (Applied). */
    @Test
    fun `C7 ingestInbound ack from bound recipient reaches ACKNOWLEDGED`() = runTest {
        val (pubA, privA) = realKeypair()
        val a = nodeA()
        val resolver = TwoRecipientResolver(a, pubA, nodeB(), ByteArray(32) { 0 })
        val (node, journal) = makeNode(InMemoryMessageStore(), resolver)
        val mid = msgId(1)
        // Pre-bind the outbound state (a directed message's enqueue), then hand it.
        assertEquals(EnqueueResult.Created, node.deliveryTracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, a))
        assertEquals(TransitionResult.Applied, node.deliveryTracker.markHandedToRelay(mid))
        assertEquals(a.toList(), rec(journal, mid).expectedRecipientNodeId?.toList())
        val ack = AckFrame.build(mid, privA, a, routingTag)
        val accepted = node.ingestInbound(ack, fromPeer = a)
        assertTrue(accepted, "an ACK from the bound recipient must be accepted (Applied -> true)")
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, stateOf(node.deliveryTracker, mid))
    }

    /** C7: an ACK from a DIFFERENT recipient (bound recipient was A, ACK claims
     *  B and is signed by B) is rejected -- the expected recipient bound in
     *  durable state is independent of the ACK, so a stranger's ACK cannot advance
     *  delivery. ingestInbound returns false (RejectedAuthentication); state stays
     *  HANDED_TO_RELAY. */
    @Test
    fun `C7 ingestInbound ack from wrong recipient is rejected`() = runTest {
        val (pubA, _) = realKeypair()
        val (pubB, privB) = realKeypair()
        val a = nodeA(); val b = nodeB()
        val resolver = TwoRecipientResolver(a, pubA, b, pubB)
        val (node, _) = makeNode(InMemoryMessageStore(), resolver)
        val mid = msgId(2)
        assertEquals(EnqueueResult.Created, node.deliveryTracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, a))
        assertEquals(TransitionResult.Applied, node.deliveryTracker.markHandedToRelay(mid))
        // ACK claims B and is signed by B -- but the bound recipient is A.
        val wrongAck = AckFrame.build(mid, privB, b, routingTag)
        val accepted = node.ingestInbound(wrongAck, fromPeer = b)
        assertFalse(accepted, "an ACK from a recipient other than the bound one must be rejected")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(node.deliveryTracker, mid))
    }

    /** C7: the PRODUCTION authenticator is fail-closed
     *  (UnresolvedRecipientKeyResolver resolves no key), so even a well-formed
     *  ACK signed by the bound recipient is rejected and the state stays
     *  HANDED_TO_RELAY -- no delivery is claimed until M2-link binds real
     *  recipient keys (A-03 / ADR-005 OPEN). */
    @Test
    fun `C7 production ingestInbound ack is fail-closed under the unresolved resolver`() = runTest {
        val (pubA, privA) = realKeypair()
        val a = nodeA()
        val (node, _) = makeNode(InMemoryMessageStore(), UnresolvedRecipientKeyResolver)
        val mid = msgId(3)
        assertEquals(EnqueueResult.Created, node.deliveryTracker.enqueue(mid, AckMode.SINGLE_RECIPIENT, a))
        assertEquals(TransitionResult.Applied, node.deliveryTracker.markHandedToRelay(mid))
        val ack = AckFrame.build(mid, privA, a, routingTag)
        val accepted = node.ingestInbound(ack, fromPeer = a)
        assertFalse(accepted, "fail-closed: the unresolved resolver rejects every ACK")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(node.deliveryTracker, mid))
    }

    /** C7: an ACK for a NONE-mode (broadcast) message is NotAckEligible even when
     *  it is a valid, trusted ACK -- the seam returns false and the state is
     *  unchanged. (Mandatory C6.1 invariant at the node seam.) */
    @Test
    fun `C7 ingestInbound ack for a NONE-mode broadcast is NotAckEligible`() = runTest {
        val (pubA, privA) = realKeypair()
        val a = nodeA()
        val resolver = TwoRecipientResolver(a, pubA, nodeB(), ByteArray(32) { 0 })
        val (node, _) = makeNode(InMemoryMessageStore(), resolver)
        val mid = msgId(4)
        // A broadcast enqueued with AckMode.NONE, then handed.
        assertEquals(EnqueueResult.Created, node.deliveryTracker.enqueue(mid, AckMode.NONE, expectedRecipient = null))
        assertEquals(TransitionResult.Applied, node.deliveryTracker.markHandedToRelay(mid))
        // A valid ACK from A -> the tracker returns NotAckEligible (authenticator
        // NOT invoked); the seam maps that to false; state stays HANDED_TO_RELAY.
        val ack = AckFrame.build(mid, privA, a, routingTag)
        assertEquals(AckResult.NotAckEligible, node.deliveryTracker.acknowledge(mid, ack))
        val accepted = node.ingestInbound(ack, fromPeer = a)
        assertFalse(accepted, "an ACK for a NONE-mode broadcast must not be accepted")
        assertEquals(DeliveryState.HANDED_TO_RELAY, stateOf(node.deliveryTracker, mid))
    }

    /** C7: a non-ACK frame is routed to the epidemic router, NOT the delivery
     *  tracker (ACK frames are point-to-point; every other type is epidemic
     *  content to persist + relay). The tracker is left untouched, and the router
     *  durably holds the epidemic frame. */
    @Test
    fun `C7 ingestInbound non-ack frame does not touch the delivery tracker`() = runTest {
        val store = InMemoryMessageStore()
        val (node, journal) = makeNode(store, UnresolvedRecipientKeyResolver)
        val sos = node.router.buildSos(ByteArray(4))   // a non-ACK frame
        assertEquals(TypeV2.SOS, sos.type)
        node.ingestInbound(sos, fromPeer = ByteArray(16) { 0x20 })
        // The router persists the SOS (epidemic); the delivery tracker does not
        // track it (an inbound SOS is not a delivery confirmation for THIS node).
        assertTrue(journal.records.isEmpty(), "the tracker must not track an inbound non-ACK frame")
        assertEquals(1, store.allHeldMsgIds().size, "the router durably held the epidemic SOS")
    }
}