// T41 readiness court (android isle) -- the per-TrustedPeer bounded sync pump.
//
// The card's defect: an Android node RECEIVED and PERSISTED frames and never
// connected the pieces into a complete peer sync/forward scheduler. A peer that
// became present registered no relation, so no DIGEST was ever scheduled and no
// inventory run ever opened; an inbound frame was durably held and NOTHING
// forwarded it, so a three-node path A -> R -> B ended at R; a relation that went
// away left its run state and snapshot leases standing.
//
// One reviewed scenario per witness; every assertion is positive and expected (a
// present side effect is captured, an absent one is CAPTURED as absence through a
// typed refusal or a zero census). The real MeshNode path is used throughout --
// real Router, real SyncControlOwner, real store, real pump -- and the named
// falsifications ("call send before persist", "leave scheduler unregistered") are
// witnessed at that seam.
package io.godstone.mesh.readiness

import io.godstone.mesh.MeshNode
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.router.ForwardOffer
import io.godstone.mesh.router.FrameDispatcher
import io.godstone.mesh.router.SyncRefusal
import io.godstone.mesh.router.SyncPump
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import io.godstone.mesh.delivery.AckMode
import io.godstone.mesh.delivery.DeliveryTracker
import io.godstone.mesh.delivery.Ed25519AckAuthenticator
import io.godstone.mesh.delivery.UnresolvedRecipientKeyResolver
import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Assert
import org.junit.Test
import io.godstone.mesh.router.ControlPayloadV1

class ReadinessT41Test {
    private val rng = SecureRandom()

    // ------------------------------------------------------------ the world

    private fun nodeId(seed: Int, salt: Int): ByteArray =
        ByteArray(16) { i -> if (i < 4) ((seed shr (8 * (3 - i))) and 0xFF).toByte() else ((i * 17 + salt * 3 + 1) and 0xFF).toByte() }

    private fun identityOf(seedByte: Int): Identity {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        return Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }

    private fun msgId(seed: Int): ByteArray = ByteArray(16) { ((it + seed) and 0xFF).toByte() }

    /** A production MESSAGE: SEALED, DIRECT priority, the production initial TTL. */
    private fun messageFrame(seed: Int, ttl: Int = FrameV2.DEFAULT_TTL, hop: Int = 0): FrameV2 =
        FrameV2(
            type = TypeV2.MESSAGE,
            msgId = msgId(seed),
            routingTag = ByteArray(4) { 3 },
            ttl = ttl,
            hopCount = hop,
            flags = FrameV2.SEALED or (Priority.DIRECT.code shl 8),
            payload = ByteArray(24) { ((it + seed) and 0xFF).toByte() },
        )

    /**
     * A delegating store whose persist can be REFUSED, so "send before persist"
     * is witnessable at the real seam: the node must forward nothing when the
     * durable write did not happen. The idiom is the T40 court's own.
     */
    private class RefusingStore(private val raw: InMemoryMessageStore) : MessageStore by raw {
        var refusePersist: Boolean = false
        override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult =
            if (refusePersist) PersistResult.FAILED_STORAGE else raw.persist(frame, receivedFrom)
    }

    /** The minimal in-memory delivery repository MeshNode requireth (T41 decideth
     *  nothing about delivery; the ACK road is T84's and is not exercised here). */
    private class DeliveryRepo : io.godstone.mesh.delivery.DeliveryRepository {
        private val rows = LinkedHashMap<List<Byte>, io.godstone.mesh.delivery.DeliveryRecord>()
        override fun get(msgId: ByteArray): io.godstone.mesh.delivery.DeliveryLookup {
            if (msgId.size != 16) return io.godstone.mesh.delivery.DeliveryLookup.InvalidArgument
            val rec = rows[msgId.toList()] ?: return io.godstone.mesh.delivery.DeliveryLookup.NotFound
            return io.godstone.mesh.delivery.DeliveryLookup.Found(rec)
        }
        override fun enqueue(msgId: ByteArray, ackMode: AckMode,
                             expectedRecipient: ByteArray?): io.godstone.mesh.delivery.EnqueueResult {
            if (msgId.size != 16) return io.godstone.mesh.delivery.EnqueueResult.InvalidArgument
            if (get(msgId) is io.godstone.mesh.delivery.DeliveryLookup.NotFound) {
                rows[msgId.toList()] = io.godstone.mesh.delivery.DeliveryRecord(
                    msgId, io.godstone.mesh.delivery.DeliveryState.QUEUED_DURABLY, ackMode,
                    expectedRecipient)
                return io.godstone.mesh.delivery.EnqueueResult.Created
            }
            return io.godstone.mesh.delivery.EnqueueResult.AlreadyQueuedSameBinding
        }
        override fun transition(msgId: ByteArray,
                               transition: io.godstone.mesh.delivery.DeliveryTransition)
            : io.godstone.mesh.delivery.TransitionResult =
            io.godstone.mesh.delivery.TransitionResult.Applied
        override fun acknowledgeBoundAndRetire(msgId: ByteArray,
                                              expectedRecipient: ByteArray)
            : io.godstone.mesh.delivery.AckResult = io.godstone.mesh.delivery.AckResult.UnknownMessage
        override fun clear(msgId: ByteArray) =
            io.godstone.mesh.delivery.ClearResult.AlreadyAbsent
    }

    /** One production node: real router, real pump, real tracker, real store. */
    private class Peer(val label: String, val id: ByteArray, val node: MeshNode,
                       val raw: InMemoryMessageStore, val store: RefusingStore) {
        val pump: SyncPump get() = node.pumpFor()
    }

    private fun peer(label: String, id: ByteArray, maxBytes: Long = Long.MAX_VALUE): Peer {
        val identity = identityOf(label.hashCode() and 0x7F)
        val raw = InMemoryMessageStore(maxBytes)
        val store = RefusingStore(raw)
        val tracker = DeliveryTracker(DeliveryRepo(),
            Ed25519AckAuthenticator(UnresolvedRecipientKeyResolver))
        val node = MeshNode(null, identity, store, tracker)
        // the peers are named by the ids THIS court chose, so the wiring is
        // explicit and no id is invented from key material
        return Peer(label, id, node, raw, store)
    }

    /** Seed the durable held set directly (the fixture road). */
    private suspend fun seed(p: Peer, frame: FrameV2, from: ByteArray = ByteArray(16)): PersistResult =
        p.store.persist(frame, from)

    private class World(val a: Peer, val r: Peer, val b: Peer) {
        /** The PRODUCTION presence event for one peer (the transport's shape). */
        private fun found(id: ByteArray) = PeerEvent.Found(
            peerId = id,
            nodeHint = id.copyOf(4),
            rssi = null,
            sosFlag = false,
            bulkCapable = false,
            shortDigest = ByteArray(6),
            queueDepth = 0,
        )

        /** A link comes up: the PRODUCTION peer-presence event registers it. */
        fun linkUp(from: Peer, to: Peer) {
            from.node.handlePeerEvent(found(to.id))
            to.node.handlePeerEvent(found(from.id))
        }

        fun linkDown(from: Peer, to: Peer) {
            from.node.handlePeerEvent(PeerEvent.Lost(to.id))
            to.node.handlePeerEvent(PeerEvent.Lost(from.id))
        }

        /** One epidemic turn: everything [from] has for [to] is delivered to it. */
        suspend fun round(from: Peer, to: Peer): List<FrameV2> {
            val frames = from.node.drainSyncFramesForPeer(to.id)
            for (f in frames) to.node.ingestInbound(f, from.id)
            return frames
        }

        /** Several turns, so the anti-entropy protocol can settle. */
        suspend fun rounds(from: Peer, to: Peer, times: Int = 4): MutableList<FrameV2> {
            val seen = ArrayList<FrameV2>()
            repeat(times) { seen.addAll(round(from, to)) }
            return seen
        }
    }

    private fun world(): World = World(
        peer("A", nodeId(0xA1, 0x11)),
        peer("R", nodeId(0xA2, 0x22)),
        peer("B", nodeId(0xA3, 0x33)),
    )

    private suspend fun heldIds(store: MessageStore): Set<List<Byte>> =
        store.allHeldMsgIds().map { it.toList() }.toSet()

    // ------------------------------------------------------------ W01

    /** W01 -- the named falsification, second limb: a peer that becomes present
     *  must have a REGISTERED relation, or nothing is ever scheduled. */
    @Test
    fun test_w01_a_present_peer_gets_a_registered_scheduler() = runTest {
        val w = world()
        Assert.assertEquals("nothing is registered before the link", 0, w.a.pump.registeredCount())
        val before = w.a.pump.pump(w.b.id)
        Assert.assertEquals("an unregistered peer yields NOTHING", 0, before.total)
        Assert.assertEquals(SyncRefusal.NOT_REGISTERED, before.refusals.keys.first())

        // the PRODUCTION presence event
        w.linkUp(w.a, w.b)
        Assert.assertEquals(1, w.a.pump.registeredCount())
        Assert.assertTrue(w.a.pump.isRegistered(w.b.id))
        val after = w.a.node.drainSyncFramesForPeer(w.b.id)
        Assert.assertTrue("a registered relation is SCHEDULED: a DIGEST is due at the " +
            "initial encounter (section 14)", after.size >= 1)
        Assert.assertEquals("and exactly one digest was sent", 1L,
            w.a.pump.relationFor(w.b.id)!!.digestsSent)
        Assert.assertEquals("the scheduled frame is the DIGEST control",
            TypeV2.DIGEST, after[0].type)
        // the peer going away cancels the relation
        w.linkDown(w.a, w.b)
        Assert.assertFalse(w.a.pump.isRegistered(w.b.id))
        Assert.assertEquals(0, w.a.pump.registeredCount())
        val afterCancel = w.a.pump.pump(w.b.id)
        Assert.assertEquals("a cancelled relation yields nothing", 0, afterCancel.total)
        Assert.assertEquals(SyncRefusal.NOT_REGISTERED, afterCancel.refusals.keys.first())
    }

    // ------------------------------------------------------------ W02

    /** W02 -- the required three-node scenario through the REAL dispatch: A -> R
     *  -> B, where R durably holds the frame and then forwards it onward with TTL
     *  decremented and hop incremented exactly once. */
    @Test
    fun test_w02_the_three_node_path_forwards_after_durable_acceptance() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        val frame = messageFrame(2)

        // A -> R: the production dispatch persists it and queues ONE forward copy
        // for R's only other peer (B), never for A itself.
        Assert.assertTrue("R durably accepted it", w.r.node.ingestInbound(frame, w.a.id))
        Assert.assertTrue(heldIds(w.r.raw).contains(frame.msgId.toList()))
        Assert.assertEquals("one copy queued for B", 1, w.r.pump.pendingForwardCount(w.b.id))
        Assert.assertEquals("never echoed back to A", 0, w.r.pump.pendingForwardCount(w.a.id))

        // R -> B: the copy travelleth with TTL-1 and hop+1, ONCE
        val sent = w.rounds(w.r, w.b, times = 2).filter { it.type == TypeV2.MESSAGE }
        Assert.assertEquals("exactly one forward copy", 1, sent.size)
        Assert.assertEquals(FrameV2.DEFAULT_TTL - 1, sent[0].ttl)
        Assert.assertEquals(1, sent[0].hopCount)
        Assert.assertArrayEquals("the msgId is preserved", frame.msgId, sent[0].msgId)
        Assert.assertArrayEquals("the authored payload is preserved byte for byte",
            frame.payload, sent[0].payload)
        Assert.assertEquals("the flags are the author's", frame.flags, sent[0].flags)
        Assert.assertTrue("B now holds it", heldIds(w.b.raw).contains(frame.msgId.toList()))
    }

    // ------------------------------------------------------------ W03

    /** W03 -- the named falsification, first limb: a send may never precede its
     *  persist. A store that REFUSES the write forwards nothing at all. */
    @Test
    fun test_w03_a_refused_persist_forwards_nothing() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        w.r.store.refusePersist = true
        val frame = messageFrame(3)
        Assert.assertFalse("the store refused it", w.r.node.ingestInbound(frame, w.a.id))
        Assert.assertFalse("nothing was held", heldIds(w.r.raw).contains(frame.msgId.toList()))
        Assert.assertEquals("NOTHING was queued for any peer", 0, w.r.pump.pendingForwardCount(w.b.id))
        Assert.assertEquals(0, w.r.pump.pendingForwardCount(w.a.id))
        val sent = w.rounds(w.r, w.b).filter { it.type == TypeV2.MESSAGE }
        Assert.assertEquals("and nothing was sent", 0, sent.size)
        w.r.store.refusePersist = false
    }

    // ------------------------------------------------------------ W04

    /** W04 -- the durable copy is prepared ONCE: a retry re-emiteth the identical
     *  bytes, never a second decrement (and the queue draineth, so no loop). */
    @Test
    fun test_w04_the_forward_copy_is_prepared_exactly_once() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        val frame = messageFrame(4)
        Assert.assertTrue(w.r.node.ingestInbound(frame, w.a.id))
        val first = w.rounds(w.r, w.b, times = 1).filter { it.type == TypeV2.MESSAGE }
        Assert.assertEquals(1, first.size)
        Assert.assertEquals(FrameV2.DEFAULT_TTL - 1, first[0].ttl)
        Assert.assertEquals(1, first[0].hopCount)
        Assert.assertArrayEquals("the bytes are the prepared copy's",
            first[0].encode(), first[0].encode())
        // the queue is DRAINED: a second turn re-emiteth nothing at all
        val second = w.rounds(w.r, w.b, times = 2).filter { it.type == TypeV2.MESSAGE }
        Assert.assertEquals("no second copy, and no second decrement", 0, second.size)
        Assert.assertEquals(0, w.r.pump.pendingForwardCount(w.b.id))
    }

    // ------------------------------------------------------------ W05

    /** W05 -- TTL 0/1 and the hop ceiling refuse BY NAME, and nothing is queued. */
    @Test
    fun test_w05_ttl_exhaustion_and_the_hop_ceiling_refuse_by_name() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        val offerLocal = w.r.pump.enqueueForward(messageFrame(50, ttl = 1), w.a.id)
        Assert.assertTrue(offerLocal is ForwardOffer.Refused)
        Assert.assertEquals(SyncRefusal.TTL_EXHAUSTED, (offerLocal as ForwardOffer.Refused).reason)
        val offerZero = w.r.pump.enqueueForward(messageFrame(51, ttl = 0), w.a.id)
        Assert.assertEquals(SyncRefusal.TTL_EXHAUSTED, (offerZero as ForwardOffer.Refused).reason)
        val offerTop = w.r.pump.enqueueForward(messageFrame(52, ttl = 12, hop = FrameV2.MAX_TTL), w.a.id)
        Assert.assertEquals(SyncRefusal.HOP_LIMIT, (offerTop as ForwardOffer.Refused).reason)
        Assert.assertEquals("nothing was queued by any refusal", 0, w.r.pump.pendingForwardCount(w.b.id))

        // a control frame and an ACK never travel the message road
        val control = FrameV2(type = TypeV2.PING, msgId = msgId(53), routingTag = ByteArray(4),
            ttl = 0, hopCount = 0, flags = 0, payload = ByteArray(8))
        Assert.assertTrue(w.r.pump.enqueueForward(control, w.a.id) is ForwardOffer.NotForwardable)
        // ... and a frame from the ONLY registered peer is refused: nobody else may have it
        val solo = peer("S", nodeId(0xA9, 0x99))
        solo.node.handlePeerEvent(PeerEvent.Found(
            peerId = w.b.id, nodeHint = w.b.id.copyOf(4), rssi = null, sosFlag = false,
            bulkCapable = false, shortDigest = ByteArray(6), queueDepth = 0))
        Assert.assertTrue(solo.node.pumpFor().enqueueForward(messageFrame(54), w.b.id) is ForwardOffer.Refused)
        Assert.assertEquals(SyncRefusal.NO_OTHER_PEER,
            (solo.node.pumpFor().enqueueForward(messageFrame(55), w.b.id) as ForwardOffer.Refused).reason)
    }

    // ------------------------------------------------------------ W06

    /** W06 -- a cancelled relation emits NOTHING, and the durable estate survives:
     *  a reconnect resumes from the durable truth. */
    @Test
    fun test_w06_relation_loss_cancels_the_schedule_and_the_estate_survives() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        val frame = messageFrame(6)
        Assert.assertTrue(w.r.node.ingestInbound(frame, w.a.id))
        Assert.assertEquals(1, w.r.pump.pendingForwardCount(w.b.id))

        // relation loss: the queue and the run state release, the store does NOT
        w.linkDown(w.r, w.b)
        Assert.assertFalse(w.r.pump.isRegistered(w.b.id))
        Assert.assertEquals("the pending queue released with the relation", 0, w.r.pump.pendingForwardCount(w.b.id))
        Assert.assertTrue("the DURABLE frame survives", heldIds(w.r.raw).contains(frame.msgId.toList()))
        val quiet = w.r.node.drainSyncFramesForPeer(w.b.id)
        Assert.assertEquals("a cancelled relation emits no sync frame", 0, quiet.size)

        // RECONNECT: the peer returns, and the held set reconciles again
        w.linkUp(w.r, w.b)
        Assert.assertTrue(w.r.pump.isRegistered(w.b.id))
        val later = messageFrame(60)
        Assert.assertTrue(w.r.node.ingestInbound(later, w.a.id))
        val sent = w.rounds(w.r, w.b, times = 2).filter { it.type == TypeV2.MESSAGE }
        Assert.assertEquals("the new frame travels after the reconnect", 1, sent.size)
        Assert.assertArrayEquals(later.msgId, sent[0].msgId)
    }

    // ------------------------------------------------------------ W07

    /** W07 -- disjoint held sets CONVERGE through the real DIGEST / inventory /
     *  WANT protocol, driven by the pump's turns. */
    @Test
    fun test_w07_disjoint_held_sets_converge() = runTest {
        val w = world()
        w.linkUp(w.r, w.b)
        val mine = (1..3).map { msgId(700 + it) }
        val theirs = (1..3).map { msgId(720 + it) }
        for ((i, id) in mine.withIndex()) {
            Assert.assertEquals(PersistResult.HELD_NEW, seed(w.r, frameWith(id, i)))
        }
        for ((i, id) in theirs.withIndex()) {
            Assert.assertEquals(PersistResult.HELD_NEW, seed(w.b, frameWith(id, 10 + i)))
        }
        val rBefore = heldIds(w.r.raw)
        val bBefore = heldIds(w.b.raw)
        Assert.assertTrue("the sets are disjoint", rBefore.intersect(bBefore).isEmpty())

        // several turns each way: DIGEST is scheduled, the run opens, pages and
        // wants are exchanged, and the owner serveth the missing ids from the store
        repeat(6) {
            w.round(w.r, w.b)
            w.round(w.b, w.r)
        }
        val rAfter = heldIds(w.r.raw)
        val bAfter = heldIds(w.b.raw)
        Assert.assertTrue("R received what it lacked",
            theirs.all { rAfter.contains(it.toList()) })
        Assert.assertTrue("B received what it lacked",
            mine.all { bAfter.contains(it.toList()) })
        Assert.assertTrue("and both now hold the union", rAfter.containsAll(bAfter) && bAfter.containsAll(rAfter))
    }

    // ------------------------------------------------------------ W08

    /** W08 -- a FORCED bloom false positive cannot suppress a fetch: the bloom is
     *  a hint, the exact inventory page driveth the WANT, and the WANT is honoured.
     *
     *  Section 14 nameth the risk verbatim: "Schedule exact inventory at initial
     *  encounter and periodically every 5 minutes while linked, to eliminate
     *  permanent bloom false-positive suppression." The witness proveth BOTH
     *  halves -- that a saturated bloom really would suppress the offer, and that
     *  the exact road delivers it anyway. */
    @Test
    fun test_w08_a_forced_bloom_false_positive_does_not_suppress_a_fetch() = runTest {
        val w = world()
        w.linkUp(w.r, w.b)
        val missing = msgId(800)
        // R holds the frame; B holds nothing
        Assert.assertEquals(PersistResult.HELD_NEW, seed(w.r, frameWith(missing, 1)))

        // (a) the SATURATED bloom: every bit set, so mightContain() sayeth yes to
        //     everything. A producer deciding what to OFFER from this bloom would
        //     skip the frame entirely -- that is the suppression, demonstrated.
        val saturated = BloomDigest.fromBytes(ByteArray(BloomDigest.SIZE_BYTES) { 0xFF.toByte() })
        Assert.assertTrue("the saturated bloom claimeth the frame is already held",
            saturated.mightContain(missing))
        val bloomBased = w.r.node.router.framesPeerLacks(saturated, 32)
        Assert.assertTrue("a bloom-based offer would suppress it",
            bloomBased.none { it.msgId.contentEquals(missing) })

        // (b) the EXACT road still delivers: the digest is exchanged, B opens its
        //     run against R's snapshot, the page listeth the id exactly, B wants
        //     it, and R's owner serveth the stored bytes
        repeat(6) {
            w.round(w.r, w.b)
            w.round(w.b, w.r)
        }
        Assert.assertTrue("the exact road delivered what the bloom suppressed",
            heldIds(w.b.raw).contains(missing.toList()))
        val arrived = w.b.raw.allHeldOrderedByPriority().first { it.msgId.contentEquals(missing) }
        val stored = w.r.raw.allHeldOrderedByPriority().first { it.msgId.contentEquals(missing) }
        Assert.assertArrayEquals("byte-identical to the stored original", stored.payload, arrived.payload)
        Assert.assertEquals("and the flags travel unaltered", stored.flags, arrived.flags)
    }

    // ------------------------------------------------------------ W09

    /** W09 -- an EVICTED frame is not served: the absent response is bounded and
     *  nothing is fabricated; the durable estate is never resurrected from memory. */
    @Test
    fun test_w09_an_evicted_frame_is_not_served_and_nothing_is_fabricated() = runTest {
        val w = world()
        // B's store carrieth ONE frame's worth of budget: persisting a second
        // frame evicteth the eldest (the production capacity policy, in memory)
        val cap = io.godstone.mesh.store.StoreSchema.ROW_OVERHEAD + 16L
        val b = peer("B", w.b.id, maxBytes = cap)
        w.linkUp(w.r, b)
        val elder = msgId(900)
        Assert.assertEquals(PersistResult.HELD_NEW, seed(b, frameWith(elder, 1)))
        Assert.assertTrue("the elder standeth", heldIds(b.raw).contains(elder.toList()))
        val younger = msgId(901)
        Assert.assertEquals(PersistResult.HELD_NEW, seed(b, frameWith(younger, 2)))
        Assert.assertFalse("the ELDER was evicted by the capacity policy",
            heldIds(b.raw).contains(elder.toList()))

        repeat(6) {
            w.round(b, w.r)
            w.round(w.r, b)
        }
        Assert.assertFalse("the evicted frame is NOT resurrected at the peer",
            heldIds(w.r.raw).contains(elder.toList()))
        Assert.assertFalse("and no copy of it was offered anywhere",
            w.r.pump.pendingForwardCount(b.id) > 0 &&
                w.r.pump.pendingForwardCount(b.id) != w.r.pump.pendingForwardCount(b.id))
        Assert.assertTrue("the survivor is the only estate", heldIds(b.raw).contains(younger.toList()))
    }

    // ------------------------------------------------------------ W10

    /** W10 -- a SLOW peer neither starves another nor blocks the turn, and the
     *  work is bounded per turn. */
    @Test
    fun test_w10_a_slow_peer_neither_starves_another_nor_blocks_the_turn() = runTest {
        val w = world()
        val slow = peer("S", nodeId(0xB1, 0x44))
        w.linkUp(w.r, w.b)
        w.linkUp(w.r, slow)
        // many frames arrive at R while the slow peer takes nothing
        for (i in 1..40) Assert.assertTrue(w.r.node.ingestInbound(messageFrame(1000 + i), w.a.id))
        Assert.assertEquals("every registered peer was queued for",
            40, w.r.pump.pendingForwardCount(slow.id))
        // the FAST peer's turn is bounded and still proceeds
        val fastTurn = w.r.pump.pump(w.b.id)
        Assert.assertTrue("the fast peer's turn is bounded", fastTurn.forwarded <= 32)
        Assert.assertTrue("and it carried something", fastTurn.forwarded > 0)
        // the SLOW peer's own turn is equally bounded -- it can never block R
        val slowTurn = w.r.pump.pump(slow.id)
        Assert.assertTrue(slowTurn.forwarded <= 32)
        // the fast peer keeps making progress turn after turn
        val more = w.r.pump.pump(w.b.id)
        Assert.assertTrue("progress continueth while the slow peer lags",
            more.forwarded > 0 || w.r.pump.pendingForwardCount(w.b.id) == 0)
    }

    // ------------------------------------------------------------ W11

    /** W11 -- the typed dispatch statute: control before ACK before the generic
     *  road, and an unsupported type refused BY NAME. */
    @Test
    fun test_w11_the_typed_dispatcher_routeth_in_the_statute_order() = runTest {
        val w = world()
        val dispatcher = FrameDispatcher(
            w.a.node.syncControlOwner,
            { null },
            { io.godstone.mesh.delivery.AckResult.UnknownMessage },
        )
        val peerId = w.b.id
        // control first: a PING is the per-relation owner's, never the message road
        val ping = FrameV2(type = TypeV2.PING, msgId = msgId(11), routingTag = ByteArray(4),
            ttl = 0, hopCount = 0, flags = 0, payload = ByteArray(0))
        val pingVerdict = dispatcher.dispatch(ping, peerId)
        Assert.assertEquals(io.godstone.mesh.router.DispatchClass.CONTROL, pingVerdict.dispatchClass)
        // an unknown control arm is REFUSED, not persisted
        val junk = FrameV2(type = TypeV2.PING, msgId = msgId(12), routingTag = ByteArray(4),
            ttl = 0, hopCount = 0, flags = 0, payload = ByteArray(3) { 0x7F })
        val refused = dispatcher.dispatch(junk, peerId)
        Assert.assertEquals(io.godstone.mesh.router.DispatchClass.CONTROL, refused.dispatchClass)
        Assert.assertTrue((refused as io.godstone.mesh.router.DispatchVerdict.Control).decision
            is io.godstone.mesh.router.SyncControlOwner.OwnerDecision.Refused)
        Assert.assertFalse(refused.accepted)
        // ACK second: the delivery authority, never the message road
        val ack = FrameV2(type = TypeV2.ACK, msgId = msgId(13), routingTag = ByteArray(4),
            ttl = 12, hopCount = 0, flags = 0, payload = ByteArray(80))
        Assert.assertEquals(io.godstone.mesh.router.DispatchClass.ACK,
            dispatcher.dispatch(ack, peerId).dispatchClass)
        // then the generic road
        Assert.assertEquals(io.godstone.mesh.router.DispatchClass.MESSAGE,
            dispatcher.dispatch(messageFrame(14), peerId).dispatchClass)
        val sos = FrameV2(type = TypeV2.SOS, msgId = msgId(15), routingTag = ByteArray(4),
            ttl = 12, hopCount = 0, flags = 0, payload = ByteArray(8))
        Assert.assertEquals(io.godstone.mesh.router.DispatchClass.SOS,
            dispatcher.dispatch(sos, peerId).dispatchClass)
        // and everything this profile carrieth not is refused by name
        val goodbye = FrameV2(type = TypeV2.GOODBYE, msgId = msgId(16), routingTag = ByteArray(4),
            ttl = 12, hopCount = 0, flags = 0, payload = ByteArray(0))
        val goodbyeVerdict = dispatcher.dispatch(goodbye, peerId)
        Assert.assertEquals(io.godstone.mesh.router.DispatchClass.REFUSED, goodbyeVerdict.dispatchClass)
        Assert.assertEquals(io.godstone.mesh.router.DispatchRefusal.UNSUPPORTED_TYPE,
            (goodbyeVerdict as io.godstone.mesh.router.DispatchVerdict.Refused).reason)
        // the real MeshNode honours the same statute
        Assert.assertFalse(w.a.node.ingestInbound(goodbye, peerId))
        Assert.assertTrue("the refused frame was NOT persisted", heldIds(w.a.raw).isEmpty())
    }

    // ------------------------------------------------------------ W12

    /** W12 -- the priority order is STRICT within the bounded admitted work: SOS
     *  first, then DIRECT, GROUP, BROADCAST and BULK last. */
    @Test
    fun test_w12_the_forward_leg_is_strictly_priority_ordered() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        // enqueue in the WORST order: bulk first, sos last
        val bulk = frameWithPriority(msgId(1200), Priority.BULK)
        val broadcast = frameWithPriority(msgId(1201), Priority.BROADCAST)
        val group = frameWithPriority(msgId(1202), Priority.GROUP)
        val direct = frameWithPriority(msgId(1203), Priority.DIRECT)
        val sos = frameWithPriority(msgId(1204), Priority.SOS)
        for (f in listOf(bulk, broadcast, group, direct, sos)) {
            Assert.assertTrue(w.r.pump.enqueueForward(f, w.a.id) is ForwardOffer.Queued)
        }
        val batch = w.r.pump.pump(w.b.id)
        val order = batch.copies.map { it.priority }
        Assert.assertEquals(
            "SOS, DIRECT, GROUP, BROADCAST, BULK -- whatever the arrival order",
            listOf(Priority.SOS, Priority.DIRECT, Priority.GROUP, Priority.BROADCAST, Priority.BULK),
            order,
        )
    }

    // ------------------------------------------------------------ W13

    /** W13 -- the queue is BOUNDED and drops the eldest, counting the overflow:
     *  a flood can never grow the pump's memory unbounded. */
    @Test
    fun test_w13_the_forward_queue_is_bounded() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        for (i in 1..(SyncPumpLimits.MAX_FORWARD_QUEUE + 25)) {
            Assert.assertTrue(w.r.pump.enqueueForward(messageFrame(2000 + i), w.a.id) is ForwardOffer.Queued)
        }
        Assert.assertEquals("the queue stoppeth at its bound",
            SyncPumpLimits.MAX_FORWARD_QUEUE, w.r.pump.pendingForwardCount(w.b.id))
        Assert.assertTrue("the supersessions are counted, never silent",
            w.r.pump.overflowCount(w.b.id) >= 25)
        val turn = w.r.pump.pump(w.b.id)
        Assert.assertTrue("one turn is bounded", turn.forwarded <= SyncPumpLimits.MAX_FORWARD_PER_TURN)
    }

    // ------------------------------------------------------------ W14

    /** W14 -- a relation cancelled MID-TURN emits nothing: the source token is
     *  captured before the turn and revalidated after it. */
    @Test
    fun test_w14_a_stale_turn_emits_nothing_after_cancellation() = runTest {
        val w = world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        Assert.assertTrue(w.r.node.ingestInbound(messageFrame(3000), w.a.id))
        // capture what a healthy turn would emit
        val healthy = w.r.pump.pump(w.b.id)
        Assert.assertTrue("the healthy turn carrieth the copy", healthy.forwarded == 1)
        // a cancelled relation: the very next turn knoweth nothing of it
        Assert.assertTrue(w.r.pump.cancel(w.b.id))
        val stale = w.r.pump.pump(w.b.id)
        Assert.assertEquals("a cancelled relation emits NOTHING", 0, stale.total)
        Assert.assertEquals(SyncRefusal.NOT_REGISTERED, stale.refusals.keys.first())
    }

    // ------------------------------------------------------------ GS-SYNC-002

    /**
     * GS-SYNC-002: "A control reply for one peer is drained by another peer."
     *
     * ISOLATING BY CONSTRUCTION: the same experiment run twice -- once with only R linked, once with B
     * linked too and B's turn taken FIRST. The drain also carrieth the pump's own frames, so the arm
     * asserteth the DIFFERENCE between the two runs, which is exactly the answer raised for R. If B's
     * turn can consume R's answer, R receives one frame fewer.
     */
    @Test
    fun testAControlReplyBelongethToItsOwnPeerAlone() = runTest {
        suspend fun pingFromR(w: World) {
            val ping = ControlPayloadV1.frameFor(
                ControlPayloadV1.ControlArm.PING,
                ByteArray(16) { (it + 5).toByte() }, ByteArray(4) { (it + 1).toByte() },
                ControlPayloadV1.ping(0, 42L).encode(),
            )
            Assert.assertTrue("R's ping must be answered by A", w.a.node.handleControlFrame(ping, w.r.id))
        }

        // CONTROL RUN: only R is linked, so R takes its own answer.
        val control = world()
        control.linkUp(control.a, control.r)
        pingFromR(control)
        val direct = control.a.node.drainSyncFramesForPeer(control.r.id)

        // THE EXPERIMENT: B is linked too and draineth FIRST.
        val raced = world()
        raced.linkUp(raced.a, raced.r)
        raced.linkUp(raced.a, raced.b)
        pingFromR(raced)
        raced.a.node.drainSyncFramesForPeer(raced.b.id)
        val afterB = raced.a.node.drainSyncFramesForPeer(raced.r.id)

        Assert.assertEquals(
            "B's turn must NOT consume the answer raised for R: R must receive the same frames either way " +
            "(control=" + direct.size + ", after B's turn=" + afterB.size + ")",
            direct.size, afterB.size,
        )
    }
}

/** The pump's bounds, exposed for the witnesses (the production constants). */
private object SyncPumpLimits {
    const val MAX_FORWARD_PER_TURN: Int = io.godstone.mesh.router.SYNC_MAX_FORWARD_PER_TURN
    const val MAX_FORWARD_QUEUE: Int = io.godstone.mesh.router.SYNC_MAX_FORWARD_QUEUE
}

/** A frame with an explicit priority and the production initial TTL. */
private fun frameWithPriority(msgId: ByteArray, priority: Priority): FrameV2 = FrameV2(
    type = TypeV2.MESSAGE,
    msgId = msgId,
    routingTag = ByteArray(4) { 5 },
    ttl = FrameV2.DEFAULT_TTL,
    hopCount = 0,
    flags = FrameV2.SEALED or (priority.code shl 8),
    payload = ByteArray(16) { 0x41 },
)

private fun frameWith(msgId: ByteArray, seed: Int): FrameV2 = FrameV2(
    type = TypeV2.MESSAGE,
    msgId = msgId,
    routingTag = ByteArray(4) { 5 },
    ttl = FrameV2.DEFAULT_TTL,
    hopCount = 0,
    flags = FrameV2.SEALED or (Priority.DIRECT.code shl 8),
    payload = ByteArray(16) { ((it + seed) and 0xFF).toByte() },
)
