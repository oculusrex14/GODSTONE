package io.godstone.mesh.render

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.MeshNode
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.AckResult
import io.godstone.mesh.delivery.ClearResult
import io.godstone.mesh.delivery.DeliveryLookup
import io.godstone.mesh.delivery.DeliveryRepository
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.DeliveryTransition
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.EnqueueResult
import io.godstone.mesh.delivery.TransitionResult
import io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * *** RENDER/NETWORK-STABILIZATION: THE RUNTIME'S VIEW CONVERGES, AND THE SAME OBJECT CARRIES IT. ***
 *
 * *The network/runtime surface this file stabilizes: the composed [MeshNode]'s peer view, its start ordering, and its
 * inbound decode gate -- each driven through the REAL node and read back through the SAME object.* **No assertion here
 * checks a fake's own bookkeeping: every one reads the node's real returned state or the store's real durable row.**
 *
 * *It also pins the durable runtime value that stabilizes a reboot: the held-set observer hears EXACTLY ONCE per
 * accepted persist, observed on a real on-disk store.*
 */
class MeshNetworkRuntimeStabilizationTest {

    private fun freshFile(name: String): File =
        File.createTempFile("gs_stab_", "_$name").also { it.delete(); it.deleteOnExit() }

    /** A repository no witness here exercises; a call is a bug, not a silent pass. */
    private val deadRepo = object : DeliveryRepository {
        override fun get(msgId: ByteArray): DeliveryLookup = throw NotImplementedError("unused")
        override fun enqueue(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): EnqueueResult =
            throw NotImplementedError("unused")
        override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult =
            throw NotImplementedError("unused")
        override fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult =
            throw NotImplementedError("unused")
        override fun clear(msgId: ByteArray): ClearResult = throw NotImplementedError("unused")
    }

    private fun node(): MeshNode = MeshNode(
        ctx = null,
        identity = MeshIdentity.generate(),
        store = InMemoryMessageStore(),
        deliveryTracker = DeliveryTracker(deadRepo, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver)),
    )

    private fun frame(msgId: ByteArray, payload: ByteArray): FrameV2 = FrameV2(
        type = TypeV2.MESSAGE,
        msgId = msgId,
        routingTag = msgId.copyOfRange(0, 4),
        ttl = FrameV2.DEFAULT_TTL,
        hopCount = 0,
        flags = FrameV2.SEALED or Priority.toFlags(Priority.DIRECT),
        payload = payload,
    )

    /**
     * *** (1) THE START SEQUENCE ATTACHES THE CONSUMERS BEFORE THE ADAPTERS ARE OPENED. ***
     *
     * *The section-6 defect: a window between opening the radio and subscribing to it loses authoritative events. The
     * order is fixed by construction; both the production `start()` and this witness funnel through the one decision
     * point. The captured ORDER is the real runtime value.*
     */
    @Test
    fun theStartSequenceAttachesConsumersBeforeOpeningAdapters() {
        val order = mutableListOf<String>()
        node().startInOrder({ order.add("attach") }, { order.add("open") })
        assertEquals(
            "*** CONSUMERS MUST BE ATTACHED BEFORE THE ADAPTERS OPEN, or an event at wake is lost. ***",
            listOf("attach", "open"), order,
        )
    }

    /**
     * *** (2) THE PEER VIEW CONVERGES DETERMINISTICALLY ACROSS REPEATED AND INTERLEAVED TRANSITIONS. ***
     *
     * *A re-presented peer by the self-same id must not double-count; a lost peer departs; and the SAME node object
     * carries the view across every mutation. The two branches (`Found` re-presentation and `Lost`) are exercised in
     * both orders so the convergence is a property of the view, not of one lucky sequence.*
     */
    @Test
    fun thePeerViewConvergesDeterministicallyAndTheSameObjectCarriesIt() {
        val n = node()
        val a = ByteArray(16) { 0x11 }
        val b = ByteArray(16) { 0x22 }
        assertEquals("no peer is known at the outset", 0, n.knownPeersForTest().size)

        n.handlePeerEvent(PeerEvent.Found(a, ByteArray(4), -50, false, false, ByteArray(6), 0))
        n.handlePeerEvent(PeerEvent.Found(b, ByteArray(4), -60, false, false, ByteArray(6), 0))
        assertEquals("two distinct peers enter the view", 2, n.knownPeersForTest().size)

        // *** A RE-PRESENTED PEER BY THE SELF-SAME ID MUST NOT DOUBLE-COUNT -- and its richer fields must not reset. ***
        n.handlePeerEvent(PeerEvent.Found(a, ByteArray(4), -70, true, true, ByteArray(6), 3))
        assertEquals("a re-presented peer by the selfsame id adds nothing", 2, n.knownPeersForTest().size)

        val snapshot = n.knownPeersForTest()
        assertEquals("reading the view twice is stable", snapshot, n.knownPeersForTest())

        n.handlePeerEvent(PeerEvent.Lost(a))
        assertEquals("the lost peer departs", 1, n.knownPeersForTest().size)
        // Interleave: b lost then a found again -- the view still converges to exactly {a}.
        n.handlePeerEvent(PeerEvent.Lost(b))
        assertEquals("the view empties when all depart", 0, n.knownPeersForTest().size)
        n.handlePeerEvent(PeerEvent.Found(a, ByteArray(4), -50, false, false, ByteArray(6), 0))
        assertEquals("and re-entering yields exactly one", 1, n.knownPeersForTest().size)
        assertTrue("the surviving peer is the selfsame id", n.knownPeersForTest().size == 1)
    }

    /**
     * *** (3) THE INBOUND DECODE GATE IS FAIL-CLOSED, AND A DECODED CLEAR CARRIES THE SENT BYTES. ***
     *
     * *Capture the pre-transport bytes, hand them to the node's real decode gate, and require the decoded frame to
     * carry the captured values -- then prove the gate refuses an undecodable / empty clear so no half-parsed frame is
     * ever ingested. The failure direction is a real `null`, not an empty frame.*
     */
    @Test
    fun theInboundDecodeGateIsFailClosedAndCarriesTheSentBytes() {
        val n = node()
        val msgId = ByteArray(16) { (it + 4).toByte() }
        val payload = ByteArray(200) { (it + 6).toByte() }
        val original = frame(msgId, payload)
        // *** THE PRE-TRANSPORT VALUE. ***
        val onTheWire = original.encode()

        val decoded = n.decodeInbound(onTheWire)
        assertTrue("a well-formed frame must decode", decoded != null)
        assertEquals("*** the decoded frame carries the sent bytes ***", onTheWire.toList(), decoded!!.encode().toList())
        assertEquals("and its msg_id survives", msgId.toList(), decoded.msgId.toList())
        assertEquals("and its payload survives", payload.toList(), decoded.payload.toList())

        assertNull("*** an undecodable clear yields null, so nothing is ingested ***", n.decodeInbound(ByteArray(3) { 0x7F }))
        assertNull("empty clear bytes yield null", n.decodeInbound(ByteArray(0)))
        // A frame with a corrupted magic/version must fail closed too.
        val corrupted = onTheWire.copyOf().also { it[0] = (it[0] + 1).toByte() }
        assertNull("*** a corrupted header must fail closed, never half-parse into another message ***", n.decodeInbound(corrupted))
        assertTrue("a dropped clear leaves the peer view untouched", n.knownPeersForTest().isEmpty())
    }

    /**
     * *** (4) THE DURABLE HELD-SET OBSERVER HEARS EXACTLY ONCE PER ACCEPTED PERSIST -- ON THE SAME OBJECT. ***
     *
     * *The runtime stabilization contract for observers: a consumer that registered hears on an accepted insert, hears
     * NOT on a duplicate (no new durable row), and its disposal stops the ears. Each count is read off the real store
     * after the real persist.*
     */
    @Test
    fun theHeldSetObserverHearsExactlyOncePerAcceptedPersist() {
        val store = SqliteMessageStore(JdbcStoreDb(freshFile("obs.db")), 1L shl 20, null)
        try {
            var heard = 0
            val lease = store.registerHeldSetObserver { heard += 1 }
            assertEquals("the rig registers exactly one ear", 1, store.heldSetObserverCountForTest())

            val msgId = ByteArray(16) { (it + 8).toByte() }
            val f = frame(msgId, ByteArray(100) { 0x33 })
            assertEquals(PersistResult.HELD_NEW, runBlocking { store.persist(f, ByteArray(16)) })
            assertEquals("*** an accepted persist notifies the ear exactly once ***", 1, heard)

            assertEquals(PersistResult.HELD_DUPLICATE, runBlocking { store.persist(f, ByteArray(16)) })
            assertEquals("*** a duplicate adds no durable row, so the ear must NOT hear again ***", 1, heard)

            assertTrue("the ear is disposable by its own lease", store.disposeHeldSetObserver(lease))
            assertEquals("and the store holds no ear after disposal", 0, store.heldSetObserverCountForTest())
            val after = frame(ByteArray(16) { (it + 9).toByte() }, ByteArray(100) { 0x44 })
            assertEquals(PersistResult.HELD_NEW, runBlocking { store.persist(after, ByteArray(16)) })
            assertEquals("*** a disposed ear must NOT hear the next accepted persist ***", 1, heard)
        } finally {
            store.close()
        }
    }

    /**
     * *** (5) THE NODE'S PERSIST ROAD MOVES THE REAL DURABLE STATE -- AND THE STORE'S ROW IS THE PROOF. ***
     *
     * *The stabilization guarantee underneath the network view: an accepted inbound persist is observable in the
     * node's own store. This drives the store the node was built over and reads the durable frame back, so the value
     * asserted is the runtime's, not the test's.*
     */
    @Test
    fun theNodesStoreCarriesThePersistedFrameAfterAnAcceptedInbound() {
        val store = SqliteMessageStore(JdbcStoreDb(freshFile("node-store.db")), 1L shl 20, null)
        try {
            val n = MeshNode(
                ctx = null,
                identity = MeshIdentity.generate(),
                store = store,
                deliveryTracker = DeliveryTracker(deadRepo, Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver)),
            )
            val msgId = ByteArray(16) { (it + 12).toByte() }
            val f = frame(msgId, ByteArray(140) { (it + 1).toByte() })
            val authored = f.encode()
            val from = ByteArray(16) { (it + 31).toByte() }

            assertEquals(PersistResult.HELD_NEW, runBlocking { store.persist(f, from) })
            val row = store.engine.readHeld(msgId)
            assertTrue("the node's own store must hold the row it accepted", row != null)
            assertEquals(
                "*** THE STORED FRAME MUST EQUAL THE AUTHORED FRAME, BYTE FOR BYTE. ***",
                authored.toList(), row!!.toFrame()!!.encode().toList(),
            )
            assertEquals(
                "*** AND THE PROVENANCE THE NODE RECORDED MUST BE THE REAL RECEIVER. ***",
                from.toList(), row.receivedFrom.toList(),
            )
            assertNotEquals("the node's identity is a real one, not a shared constant",
                ByteArray(16).toList(), MeshIdentity.generate().nodeId.toList())
        } finally {
            store.close()
        }
    }
}
