package io.godstone.mesh

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.delivery.AckFrame
import io.godstone.mesh.delivery.DeliveryJournal
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.ExpectedRecipientStore
import io.godstone.mesh.delivery.RecipientKeyResolver
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
 * Stage 4C / C6 + C7 -- the MeshNode outbound (C6) and inbound-ACK (C7) wiring,
 * exercised at the NODE level on a real [MeshNode] (no Android Context, no
 * Robolectric). The identity is injected via the test primary constructor
 * (mirrors iOS `MeshNode(identity:store:deliveryTracker:)`), so `dispatchSos` /
 * `ingestInbound` run in a pure JVM `:mesh:testDebugUnitTest`.
 *
 * C6 (outbound): `dispatchSos` persists BEFORE driving the delivery tracker
 * (persist-before-tracker, extending the 4B.1 persist-before-forward gate), then
 * `enqueue(msgId, expectedRecipient = null)` (SOS broadcast -> unbound) and
 * `markHandedToRelay` per successful send. Asserts:
 *   - persist succeeds + N successful sends -> HandedToRelays(N) + HANDED_TO_RELAY
 *   - persist succeeds + 0 peers -> QueuedLocally + QUEUED_DURABLY
 *   - persist fails -> NotPersisted + tracker UNTOUCHED (no delivery claimed for
 *     a message this node does not durably hold)
 *
 * C7 (inbound ACK): `ingestInbound` routes an ACK frame to `deliveryTracker
 * .acknowledge`, which binds it to the durable expected recipient (C2) and
 * advances to ACKNOWLEDGED only on cryptographic proof. Asserts:
 *   - ACK from the bound recipient -> ACKNOWLEDGED_BY_RECIPIENT
 *   - ACK from a different recipient -> rejected, stays HANDED_TO_RELAY
 *   - production fail-closed (UnresolvedRecipientKeyResolver) -> rejected,
 *     stays HANDED_TO_RELAY (no delivery on host-only evidence; A-03/ADR-005 OPEN)
 *   - a non-ACK frame is routed to the epidemic router, NOT the tracker
 *
 * The DeliveryTracker truth-table / negative-ACK matrix / reboot recovery are
 * covered in [io.godstone.mesh.delivery.DeliveryTrackerTest] and
 * [io.godstone.mesh.delivery.SqliteDeliveryJournalTest]; these tests pin the
 * MeshNode CALL-SITE wiring (the C6/C7 seams) on top of that proven machine.
 */
class MeshNodeDeliveryIntegrationTest {

    private val rng = SecureRandom()

    private fun msgId(seed: Byte) = ByteArray(16) { (it + seed).toByte() }
    private val routingTag = ByteArray(4) { it.toByte() }
    private fun nodeA() = ByteArray(16) { 0x01 }
    private fun nodeB() = ByteArray(16) { 0x02 }

    /** In-memory DeliveryJournal + ExpectedRecipientStore (both roles in one
     *  object, mirroring SqliteDeliveryJournal over a real DB). */
    private class InMemoryDeliveryJournal : DeliveryJournal, ExpectedRecipientStore {
        val state = mutableMapOf<List<Byte>, DeliveryState>()
        val recipient = mutableMapOf<List<Byte>, ByteArray>()
        private fun k(m: ByteArray) = m.toList()
        override fun read(msgId: ByteArray) = state[k(msgId)] ?: DeliveryState.UNAVAILABLE
        override fun write(msgId: ByteArray, s: DeliveryState) { state[k(msgId)] = s }
        override fun clear(msgId: ByteArray) { state.remove(k(msgId)); recipient.remove(k(msgId)) }
        override fun expectedRecipient(msgId: ByteArray): ByteArray? = recipient[k(msgId)]
        override fun recordExpectedRecipient(msgId: ByteArray, r: ByteArray?) {
            if (r != null) recipient[k(msgId)] = r else recipient.remove(k(msgId))
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

    /** Build a node over [store] + an in-memory journal/tracker with the supplied
     *  resolver. Returns the node + the journal so tests can assert on the
     *  durable delivery state. The caller retains its own [store] reference. */
    private fun makeNode(
        store: MessageStore,
        resolver: RecipientKeyResolver,
    ): Pair<MeshNode, InMemoryDeliveryJournal> {
        val journal = InMemoryDeliveryJournal()
        val tracker = DeliveryTracker(journal, Ed25519AckAuthenticator(resolver), journal)
        val node = MeshNode(ctx = null, identity = freshIdentity(), store = store, deliveryTracker = tracker)
        return node to journal
    }

    // --- C6: outbound SOS dispatch drives the delivery tracker ---

    /** C6: persist succeeds + 1 successful send -> HandedToRelays(1) and the
     *  tracker reaches HANDED_TO_RELAY (persist-before-tracker: enqueue runs only
     *  after persist succeeded, markHandedToRelay after the send returned true). */
    @Test
    fun `C6 dispatchSos with a successful send reaches HANDED_TO_RELAY`() = runTest {
        val store = InMemoryMessageStore()
        val (node, journal) = makeNode(store, UnresolvedRecipientKeyResolver)
        node.injectPeerForTest(ByteArray(16) { 0x10 })
        val result = node.dispatchSos(ByteArray(8)) { _, _ -> true }
        assertEquals(SosDispatchResult.HandedToRelays(1), result)
        val mid = store.allHeldMsgIds().single()
        assertEquals(DeliveryState.HANDED_TO_RELAY, journal.read(mid))
        // SOS broadcast binds NO recipient (unbound path).
        assertNull(journal.expectedRecipient(mid))
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
        assertEquals(DeliveryState.QUEUED_DURABLY, journal.read(mid))
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
        assertTrue(journal.state.isEmpty(), "tracker must not record a message that was not durably held")
        assertTrue(store.allHeldMsgIds().isEmpty())
    }

    // --- C7: inbound ACK dispatch binds to the durable expected recipient ---

    /** C7: an ACK from the bound recipient advances the state to
     *  ACKNOWLEDGED_BY_RECIPIENT. The expected recipient was bound in durable
     *  outbound state INDEPENDENT of the ACK (C1/C2). */
    @Test
    fun `C7 ingestInbound ack from bound recipient reaches ACKNOWLEDGED`() = runTest {
        val (pubA, privA) = realKeypair()
        val a = nodeA()
        val resolver = TwoRecipientResolver(a, pubA, nodeB(), ByteArray(32) { 0 })
        val (node, journal) = makeNode(InMemoryMessageStore(), resolver)
        val mid = msgId(1)
        // Pre-bind the outbound state (a directed message's enqueue), then hand it.
        assertTrue(node.deliveryTracker.enqueue(mid, expectedRecipient = a))
        assertTrue(node.deliveryTracker.markHandedToRelay(mid))
        assertEquals(a, journal.expectedRecipient(mid))
        val ack = AckFrame.build(mid, privA, a, routingTag)
        val accepted = node.ingestInbound(ack, fromPeer = a)
        assertTrue(accepted, "an ACK from the bound recipient must be accepted")
        assertEquals(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT, node.deliveryTracker.state(mid))
    }

    /** C7: an ACK from a DIFFERENT recipient (bound recipient was A, ACK claims
     *  B and is signed by B) is rejected -- the expected recipient bound in
     *  durable state is independent of the ACK, so a stranger's ACK cannot advance
     *  delivery. State stays HANDED_TO_RELAY. */
    @Test
    fun `C7 ingestInbound ack from wrong recipient is rejected`() = runTest {
        val (pubA, _) = realKeypair()
        val (pubB, privB) = realKeypair()
        val a = nodeA(); val b = nodeB()
        val resolver = TwoRecipientResolver(a, pubA, b, pubB)
        val (node, _) = makeNode(InMemoryMessageStore(), resolver)
        val mid = msgId(2)
        assertTrue(node.deliveryTracker.enqueue(mid, expectedRecipient = a))
        assertTrue(node.deliveryTracker.markHandedToRelay(mid))
        // ACK claims B and is signed by B -- but the bound recipient is A.
        val wrongAck = AckFrame.build(mid, privB, b, routingTag)
        val accepted = node.ingestInbound(wrongAck, fromPeer = b)
        assertFalse(accepted, "an ACK from a recipient other than the bound one must be rejected")
        assertEquals(DeliveryState.HANDED_TO_RELAY, node.deliveryTracker.state(mid))
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
        assertTrue(node.deliveryTracker.enqueue(mid, expectedRecipient = a))
        assertTrue(node.deliveryTracker.markHandedToRelay(mid))
        val ack = AckFrame.build(mid, privA, a, routingTag)
        val accepted = node.ingestInbound(ack, fromPeer = a)
        assertFalse(accepted, "fail-closed: the unresolved resolver rejects every ACK")
        assertEquals(DeliveryState.HANDED_TO_RELAY, node.deliveryTracker.state(mid))
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
        assertTrue(journal.state.isEmpty(), "the tracker must not track an inbound non-ACK frame")
        assertEquals(1, store.allHeldMsgIds().size, "the router durably held the epidemic SOS")
    }
}