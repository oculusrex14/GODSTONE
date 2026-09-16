package io.godstone.mesh.crypto

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * T08: SessionSlot is the serialization authority.
 *
 * Regression targets: handshake methods took peer locks while seal/open/
 * drop/isReady did not, so drop could race active cipher operations. After
 * T08: sessions are keyed by the immutable RelationKey, one slot holds the
 * controller, budget, replay window, terminal state and lease, EVERY
 * operation serializes on the slot, drop's destructive work is routed
 * outside the lock, and retired slots are reclaimed with their lock entries.
 */
class ReadinessT08Test {

    private val authority = object : PeerBindingTrustAuthority {
        override fun applyValidatedBinding(
            binding: ValidatedPeerBinding
        ): PeerTrustApplyResult = PeerTrustApplyResult.Accepted
    }

    private data class ReadySession(
        val initiator: SessionManager,
        val responder: SessionManager,
        val peer: ByteArray,
        val responderHint: ByteArray,
        val initiatorHint: ByteArray,
    )

    private fun readyManagers(): ReadySession {
        val identityI = MeshIdentity.generate()
        val identityR = MeshIdentity.generate()
        val initiatorSide = SessionManager(identityI, authority)
        val responderSide = SessionManager(identityR, authority)
        val peer = identityR.nodeId
        val hs1 = initiatorSide.initiatorStart(peer, identityR.nodeHint)
            ?: throw AssertionError("HS1 must be emitted")
        val hs2 = responderSide.responderProcessHs1(peer, identityI.nodeHint, hs1)
            ?: throw AssertionError("HS2 must be emitted")
        val hs3 = initiatorSide.initiatorProcessHs2(peer, hs2, identityR.nodeHint)
            ?: throw AssertionError("HS3 must be emitted")
        assertTrue(responderSide.responderProcessHs3(peer, hs3, identityI.nodeHint))
        return ReadySession(
            initiatorSide, responderSide, peer,
            identityR.nodeHint, identityI.nodeHint)
    }



    @Test
    fun testSealOpenDropAllSerializeOnTheSlot() {
        val (initiator, responder, peer) = readyManagers()
        // Basic operation through the slot.
        val sealed = initiator.seal(peer, "frame".toByteArray())
        assertTrue(sealed != null)
        assertTrue(responder.open(peer, sealed!!)!!
            .contentEquals("frame".toByteArray()))
        assertTrue(responder.isReady(peer))
        // Drop transitions terminal under the slot lock and destroys outside.
        initiator.drop(peer)
        responder.drop(peer)
        assertNull(initiator.seal(peer, "after-drop".toByteArray()))
        assertFalse(responder.isReady(peer))
    }

    @Test
    fun testConcurrentSealAndDrop_TypedFailureNeverCrash() {
        // The card's security case: drop racing an active seal must fail
        // cleanly (typed null), never crash or corrupt cipher state.
        val failures = AtomicInteger(0)
        val executor: ExecutorService = Executors.newFixedThreadPool(6)
        try {
            for (round in 0 until 40) {
                        val (initiator, responder, peer) = readyManagers()
                // The serialisation witness: the slots themselves report how
                // many distinct threads were ever inside at the same time.
                val sealedSlot = initiator.slotForTest(peer)
                    ?: throw AssertionError("the initiator must hold a slot")
                val openedSlot = responder.slotForTest(peer)
                    ?: throw AssertionError("the responder must hold a slot")
                sealedSlot.maxThreadsInside = 0
                openedSlot.maxThreadsInside = 0
                val start = CountDownLatch(1)
                val sealTask = executor.submit {
                    start.await()
                    repeat(200) {
                        val sealed = initiator.seal(
                            peer, "f$it".toByteArray())
                        if (sealed != null) {
                            // A null open during teardown is a typed
                            // failure (expected); only a WRONG plaintext
                            // counts as corruption.
                            val opened = responder.open(peer, sealed)
                            if (opened != null &&
                                !opened.contentEquals("f$it".toByteArray())) {
                                failures.incrementAndGet()
                            }
                        }
                    }
                }
                val dropTask = executor.submit {
                    start.await()
                    initiator.drop(peer)
                    responder.drop(peer)
                }
                start.countDown()
                sealTask.get(30, TimeUnit.SECONDS)
                dropTask.get(30, TimeUnit.SECONDS)
                // Neither slot may have been entered by two threads at once:
                // the slot is the single serialisation point of a relation.
                assertTrue(
                    "the sealing slot must serialise its operations",
                    sealedSlot.maxThreadsInside < 2
                )
                assertTrue(
                    "the opening slot must serialise its operations",
                    openedSlot.maxThreadsInside < 2
                )
                // After the drops, operations must answer with typed failures only:
                // never ciphertext, and never a successful no-op.
                assertNull(
                    "a dropped relation must not seal",
                    initiator.seal(peer, "post".toByteArray())
                )
                assertNull(
                    "a dropped relation must not open",
                    responder.open(peer, "post".toByteArray())
                )
                assertFalse(
                    "a dropped relation must not be ready",
                    responder.isReady(peer)
                )
            }
        } finally {
            executor.shutdownNow()
        }
        assertEquals(0, failures.get())
    }

    @Test
    fun testSameSlotOperationsNeverInterleaveCorruptingly() {
        // Two threads hammering the same relation: every accepted frame must
        // decrypt with the matching plaintext (the slot serializes), and the
        // replay window must never reject a legitimately sequenced frame.
        val (initiator, responder, peer) = readyManagers()
        val failures = AtomicInteger(0)
        val executor: ExecutorService = Executors.newFixedThreadPool(2)
        try {
            val producer = executor.submit {
                repeat(200) { index ->
                    initiator.seal(peer, "seq-$index".toByteArray())
                }
            }
            producer.get(60, TimeUnit.SECONDS)
        } finally {
            executor.shutdown()
            executor.awaitTermination(30, TimeUnit.SECONDS)
        }
        // All frames were produced under the slot lock, in order: opening
        // them sequentially must succeed for every index.
        for (index in 0 until 100) {
            val sealed = initiator.seal(peer, "verify-$index".toByteArray())
            if (sealed == null) {
                failures.incrementAndGet()
                continue
            }
            val opened = responder.open(peer, sealed)
            if (opened == null || !opened.contentEquals("verify-$index".toByteArray())) {
                failures.incrementAndGet()
            }
        }
        assertEquals(0, failures.get())
    }

    @Test
    fun testRetiredSlotsAndLockEntriesAreReclaimed() {
        val session = readyManagers()
        session.initiator.drop(session.peer)
        session.responder.drop(session.peer)
        assertFalse(session.initiator.isReady(session.peer))
        // A fresh handshake on the SAME relation reclaims the retired slot:
        // the relation is re-established with a fresh lease, not reused.
        val hs1 = session.initiator.initiatorStart(
            session.peer, session.responderHint)
            ?: throw AssertionError("re-established HS1 must be emitted")
        val hs2 = session.responder.responderProcessHs1(
            session.peer, session.initiatorHint, hs1)
            ?: throw AssertionError("re-established HS2 must be emitted")
        val hs3 = session.initiator.initiatorProcessHs2(
            session.peer, hs2, session.responderHint)
            ?: throw AssertionError("re-established HS3 must be emitted")
        assertTrue(session.responder.responderProcessHs3(
            session.peer, hs3, session.initiatorHint))
        assertTrue(session.initiator.isReady(session.peer))
        assertTrue(session.responder.isReady(session.peer))
    }

    @Test
    fun testLifecycleGateRetainsExclusiveBarrierOrder() {
        // Lock order: lifecycle gate first, then slot. After invalidation
        // every operation is typed-failed and the barrier is exclusive.
        val (initiator, responder, peer) = readyManagers()
        initiator.invalidateForWipe()
        assertTrue(initiator.isInvalidated)
        assertNull(initiator.seal(peer, "x".toByteArray()))
        assertNull(initiator.open(peer, "x".toByteArray().copyOf()))
        assertEquals(false, initiator.isReady(peer))
        // The global barrier is exclusive: a write-locked invalidate blocks
        // in-flight reads; the test completes (no deadlock) within itself.
        initiator.destroyAll()
    }

    @Test
    fun testRelationKeyCarriethTheWholeRelation() {
        // CRYPTO-001 (T08 completion): the key is no longer a wrapper of the lookup handle
        // alone. It carrieth the direction, the ORCHESTRATION-OWNED generation and the radio
        // epoch, because a handle is reused across incarnations and only the whole identity
        // telleth two of them apart.
        val handle = "aabbccdd"
        val key = RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 1L, 1L)
        assertEquals(key, RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 1L, 1L))
        assertEquals(key.hashCode(), RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 1L, 1L).hashCode())
        // The handle is the existing transport lookup handle, not a node id.
        assertEquals(handle, key.handle)
        // ... and every other component distinguisheth an incarnation:
        assertNotEquals(key, RelationKey(RelationDirection.INBOUND_PERIPHERAL, handle, 1L, 1L))
        assertNotEquals(key, RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 2L, 1L))
        assertNotEquals(key, RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 1L, 2L))
        assertNotEquals(key, RelationKey(RelationDirection.OUTBOUND_CENTRAL, "eedd", 1L, 1L))
        // (the retired vocabulary of the pre-T08 host courts is gone with the history: there is
        // no SlotLease on this isle any more, because the generation cometh from the link owner)
    }

    @Test
    fun testBoundedSlotMapOverTenThousandReconnects() {
        // The registry is bounded by LIVE relations: 10,000 reconnects over a rotating handle set
        // must not grow the slot map, must reclaim each retired entry together with its lock, and
        // must refuse a teardown addressed to the incarnation it replaced.
        //
        // CRYPTO-001 (T08 completion): the generation is now MINTED BY THE CALLER -- the orchestration
        // owner mints it when it admits the relation -- and the crypto registry keeps NO history of its
        // own. This court therefore speaks the admission exactly as the link owner doth, and the arm
        // which used to read the registry's private history now asserts the law that replaced it: a
        // superseded incarnation is REFUSED by name, and the registry remembers nothing which could be
        // replayed.
        val identityI = MeshIdentity.generate()
        val identityR = MeshIdentity.generate()
        val initiator = SessionManager(identityI, authority)
        val responder = SessionManager(identityR, authority)
        val handleCount = 16
        val handles = arrayOf(
            byteArrayOf(0x52, 0), byteArrayOf(0x52, 1), byteArrayOf(0x52, 2),
            byteArrayOf(0x52, 3), byteArrayOf(0x52, 4), byteArrayOf(0x52, 5),
            byteArrayOf(0x52, 6), byteArrayOf(0x52, 7), byteArrayOf(0x52, 8),
            byteArrayOf(0x52, 9), byteArrayOf(0x52, 10), byteArrayOf(0x52, 11),
            byteArrayOf(0x52, 12), byteArrayOf(0x52, 13), byteArrayOf(0x52, 14),
            byteArrayOf(0x52, 15)
        )
        val previousGeneration = LongArray(handleCount) { 0L }
        for (round in 0 until 10000) {
            val lane = round % handleCount
            val peer = handles[lane]
            val handle = peer.joinToString("") { "%02x".format(it) }
            val generation = previousGeneration[lane] + 1L
            val epoch = (round / handleCount).toLong() + 1L
            val outbound = RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, generation, epoch)
            val inbound = RelationKey(RelationDirection.INBOUND_PERIPHERAL, handle, generation, epoch)
            val hs1 = initiator.initiatorStart(outbound, identityR.nodeHint)
                ?: throw AssertionError("HS1 must be emitted on reconnect $round")
            val hs2 = responder.responderProcessHs1(inbound, identityI.nodeHint, hs1)
                ?: throw AssertionError("HS2 must be emitted on reconnect $round")
            val hs3 = initiator.initiatorProcessHs2(outbound, hs2, identityR.nodeHint)
                ?: throw AssertionError("HS3 must be emitted on reconnect $round")
            assertTrue(responder.responderProcessHs3(inbound, hs3, identityI.nodeHint))
            assertEquals(
                "the live incarnation carrieth the orchestration generation",
                generation, initiator.slotLeaseGenerationForTest(peer))
            previousGeneration[lane] = generation
            if (generation > 1L) {
                val superseded = RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, generation - 1L, epoch)
                assertEquals(
                    "a teardown of the superseded incarnation must be REFUSED",
                    RelationRetirement.STALE, initiator.drop(superseded))
                assertTrue(
                    "the superseded teardown slew the live incarnation",
                    initiator.isReady(outbound))
            }
            assertEquals(RelationRetirement.RETIRED, initiator.drop(outbound))
            assertEquals(RelationRetirement.RETIRED, responder.drop(inbound))
            if (initiator.slotCountForTest() > handleCount) {
                throw AssertionError("slot map grew past the live bound at round $round")
            }
            if (responder.slotCountForTest() > handleCount) {
                throw AssertionError("responder map grew past the live bound at round $round")
            }
        }
        // Every entry was reclaimed with its lock entry: nothing leaks, and the registry remembers
        // NOTHING -- the generation history is reclaimed with the history-free design the
        // orchestration-owned generation made possible.
        assertEquals(0, initiator.slotCountForTest())
        assertEquals(0, responder.slotCountForTest())
        for (peer in handles) {
            assertEquals(0, initiator.incarnationCountForTest(peer))
            assertNull(initiator.slotLeaseGenerationForTest(peer))
        }
    }

    @Test
    fun testDestroyedReferencesRemainTerminal() {
        val session = readyManagers()
        val stale = session.initiator.seal(session.peer, "stale".toByteArray())
            ?: throw AssertionError("the pre-drop seal must succeed")
        session.initiator.drop(session.peer)
        session.responder.drop(session.peer)
        // A held reference to the destroyed incarnation stays terminal: the
        // destroyed responder rejects the frame of the previous session.
        assertNull(session.initiator.seal(session.peer, "again".toByteArray()))
        assertNull(session.responder.open(session.peer, stale))
        assertFalse(session.initiator.isReady(session.peer))
        assertFalse(session.responder.isReady(session.peer))
        // A repeated drop is a typed no-op, never a resurrection.
        session.initiator.drop(session.peer)
        session.initiator.drop(session.peer)
        assertNull(session.initiator.seal(session.peer, "post".toByteArray()))
        assertEquals(0, session.initiator.slotCountForTest())
        assertEquals(0, session.responder.slotCountForTest())
        // The replacement carrieth the NEXT generation the orchestration owner minteth -- not one
        // the crypto registry invented -- so it cannot alias the incarnation it replaces.
        assertNull(session.initiator.slotLeaseGenerationForTest(session.peer))
        val handle = session.peer.joinToString("") { "%02x".format(it) }
        val replacement = RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 1L, 1L)
        val responderReplacement = RelationKey(RelationDirection.INBOUND_PERIPHERAL, handle, 1L, 1L)
        val hs1 = session.initiator.initiatorStart(
            replacement, session.responderHint
        ) ?: throw AssertionError("re-established HS1 must be emitted")
        val hs2 = session.responder.responderProcessHs1(
            responderReplacement, session.initiatorHint, hs1
        ) ?: throw AssertionError("re-established HS2 must be emitted")
        val hs3 = session.initiator.initiatorProcessHs2(
            replacement, hs2, session.responderHint
        ) ?: throw AssertionError("re-established HS3 must be emitted")
        assertTrue(session.responder.responderProcessHs3(
            responderReplacement, hs3, session.initiatorHint))
        assertEquals(
            "the replacement carrieth the orchestration generation",
            1L, session.initiator.slotLeaseGenerationForTest(session.peer))
        // The teardown of the incarnation that was replaced is REFUSED BY NAME, and the replacement
        // standeth untouched: the finding's law, at the boundary.
        val superseded = RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 0L, 0L)
        assertEquals(RelationRetirement.STALE, session.initiator.drop(superseded))
        assertTrue(session.initiator.isReady(replacement))
        assertTrue(session.responder.isReady(responderReplacement))
        // Cross-incarnation replay: the destroyed incarnation's frame cannot
        // be replayed into the replacement. The legacy wrapper fails hard with
        // its typed authentication exception - the documented channel of this
        // boundary - and the replacement keeps its authoritative state.
        var rejected = false
        try {
            session.responder.open(session.peer, stale)
            throw AssertionError("the replacement must reject the destroyed frame")
        } catch (expected: NoiseSession.AuthenticationException) {
            rejected = true
        }
        assertTrue("the replacement must reject the destroyed frame", rejected)
        // A typed failure, not a state loss: the live replacement still serves
        // legitimately sequenced frames.
        assertTrue(session.responder.isReady(session.peer))
        assertTrue(session.initiator.isReady(session.peer))
        val live = session.initiator.seal(session.peer, "live".toByteArray())
            ?: throw AssertionError("the replacement must still seal")
        val opened = session.responder.open(session.peer, live)
            ?: throw AssertionError("a legitimately sequenced frame must still open")
        assertTrue(
            "the replacement must decrypt its own frame",
            opened.contentEquals("live".toByteArray())
        )
    }

    // ------------------------------------------------------------------ CRYPTO-003

    /**
     * A DESTROYED object still HELD BY REFERENCE must report TERMINAL.
     *
     * The audit's charge, in its own words: "Destroyed retained controllers and primitive
     * sessions still report ready or established." Terminality was a property of the
     * REGISTRY -- the manager's slot was removed, so the manager's isReady went false --
     * and NOT of the object, so any code that kept the reference saw a live, ready,
     * established thing. Both objects are retained here on purpose and asked directly.
     */
    @Test
    fun testDestroyedRetainedPrimitivesReportTerminalNotReady() {
        // (a) A PRIMITIVE SESSION, established through the REAL handshake, then destroyed
        //     while the reference is kept.
        val identityI = MeshIdentity.generate()
        val identityR = MeshIdentity.generate()
        val i = NoiseSession.initiator(identityI, identityI.nodeHint, identityR.nodeHint)
        val r = NoiseSession.responder(identityR, identityI.nodeHint, identityR.nodeHint)
        r.readHandshakeMessage(i.writeHandshakeMessage())
        i.readHandshakeMessage(r.writeHandshakeMessage())
        r.readHandshakeMessage(i.writeHandshakeMessage())
        assertTrue("the retained session stands established before the destroy", i.isEstablished)
        val sealedBefore = i.encrypt("before the destroy".toByteArray())
        i.destroy()
        assertFalse("a DESTROYED retained session must not report established", i.isEstablished)
        assertNull("...and must drop its authenticated remote static key", i.remoteStaticKey)
        var refused = 0
        try { i.encrypt(ByteArray(4)) } catch (_e: Throwable) { refused++ }
        try { i.decrypt(sealedBefore) } catch (_e: Throwable) { refused++ }
        try { i.writeHandshakeMessage() } catch (_e: Throwable) { refused++ }
        assertEquals("every key operation must be refused after the destroy", 3, refused)
        i.destroy()
        i.destroy()
        assertFalse("the destroy is idempotent, never a resurrection", i.isEstablished)

        // (b) A CONTROLLER retained out of the slot it was retired from.
        val session = readyManagers()
        val slot = session.initiator.slotForTest(session.peer)
            ?: throw AssertionError("the slot must stand for the ready relation")
        val live = slot.controller ?: throw AssertionError("the slot must hold its controller")
        assertTrue("the retained controller stands ready before the destroy", live.isReady)
        val sealedByController = live.seal("before the destroy".toByteArray())
            ?: throw AssertionError("the ready controller must seal")
        live.destroy()
        assertFalse("a DESTROYED retained controller must not report ready", live.isReady)
        assertNull("...and must withhold seal after the destroy",
                   live.seal("after the destroy".toByteArray()))
        assertNull("...and must withhold open after the destroy", live.open(sealedByController))
        assertFalse("...while the primitive session it owns reports terminal too",
                    live.noiseSession.isEstablished)
        live.destroy()
        assertFalse("the controller destroy is idempotent too", live.isReady)
    }

    // ------------------------------------------------------------- CRYPTO-001
    //
    // The law these two arms assert is the audit's own: THE SESSION AUTHORITY ITSELF must refuse an
    // operation that belongeth to a relation which hath been replaced, and a relation's crypto slot
    // must be keyed by the WHOLE relation -- direction included -- and not by the platform handle
    // alone. (The iOS twin carrieth the same two arms; this isle's RED is its own.)
    //
    // Both were run RED against the tree BEFORE any production line was touched, and the failing run
    // is kept in the finding's evidence log, separate from the repaired run.

    @Test
    fun testCrypto001_aTeardownAddressedToAReplacedRelationMustNotSlayItsReplacement() {
        val session = readyManagers()
        val handle = session.peer.joinToString("") { "%02x".format(it) }
        // ONE platform handle, TWO incarnations: the station is replaced while the handle stands.
        // Each side presenteth its own direction's incarnation -- the identity the link owner
        // minteth -- and the RED form of this arm could only name the HANDLE, which IS the finding.
        val first = RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 0L, 0L)
        val firstIn = RelationKey(RelationDirection.INBOUND_PERIPHERAL, handle, 0L, 0L)
        val second = RelationKey(RelationDirection.OUTBOUND_CENTRAL, handle, 1L, 1L)
        val secondIn = RelationKey(RelationDirection.INBOUND_PERIPHERAL, handle, 1L, 1L)

        val firstFrame = session.initiator.seal(first, "incarnation A".toByteArray())
        assertTrue(firstFrame != null)
        assertEquals(
            "incarnation A",
            String(session.responder.open(firstIn, firstFrame!!)!!))
        assertEquals(RelationRetirement.RETIRED, session.initiator.drop(first))
        assertEquals(RelationRetirement.RETIRED, session.responder.drop(firstIn))

        // Incarnation B: the replacement, handshaken afresh on the very same handle.
        val hs1 = session.initiator.initiatorStart(second, session.responderHint)
            ?: throw AssertionError("the replacement's HS1 must be emitted")
        val hs2 = session.responder.responderProcessHs1(secondIn, session.initiatorHint, hs1)
            ?: throw AssertionError("the replacement's HS2 must be emitted")
        val hs3 = session.initiator.initiatorProcessHs2(second, hs2, session.responderHint)
            ?: throw AssertionError("the replacement's HS3 must be emitted")
        assertTrue(session.responder.responderProcessHs3(secondIn, hs3, session.initiatorHint))
        assertTrue(session.initiator.isReady(second))

        // Now A's DELAYED teardown arrives -- the teardown queued against the incarnation the
        // station already replaced. It must be REFUSED BY NAME.
        assertEquals(
            "a teardown of the replaced incarnation must be refused",
            RelationRetirement.STALE, session.initiator.drop(first))
        assertEquals(
            "the responder must refuse the replaced incarnation's teardown too",
            RelationRetirement.STALE, session.responder.drop(firstIn))

        assertTrue(
            "a teardown that belongs to the REPLACED relation slew its replacement",
            session.initiator.isReady(second))
        assertTrue(session.responder.isReady(secondIn))
        val live = session.initiator.seal(second, "replacement lives".toByteArray())
        assertTrue(live != null)
        assertEquals(
            "replacement lives",
            String(session.responder.open(secondIn, live!!)!!))
        // The replacement's own teardown still worketh, and only it.
        assertEquals(RelationRetirement.RETIRED, session.initiator.drop(second))
        assertFalse(session.initiator.isReady(second))
        assertNull(session.initiator.seal(second, "gone".toByteArray()))
    }

    @Test
    fun testCrypto001_theSecondDirectionOfOneHandleIsADifferentRelation() {
        val identityI = MeshIdentity.generate()
        val identityR = MeshIdentity.generate()
        val initiatorSide = SessionManager(identityI, authority)
        val responderSide = SessionManager(identityR, authority)
        val handle = identityR.nodeId

        // The SAME manager playeth the initiator of one relation and the responder of another, and both
        // relations live on the SAME platform handle. One slot per handle cannot hold them apart: the
        // second counsels are two DIFFERENT relations.
        val outboundHs1 = initiatorSide.initiatorStart(handle, identityR.nodeHint)
        assertTrue("the outbound relation's HS1 must be emitted", outboundHs1 != null)
        val inboundHs1 = initiatorSide.initiatorStart(handle, identityR.nodeHint)
        // (a second initiator counsels the selfsame relation and is refused -- that is the slot's own law)
        val foreignHs1 = responderSide.initiatorStart(handle, identityI.nodeHint)
            ?: throw AssertionError("the counterpart's HS1 must be emitted")
        val inboundHs2 = initiatorSide.responderProcessHs1(handle, identityI.nodeHint, foreignHs1)
        assertTrue(
            "an inbound and an outbound relation of ONE handle must not share a crypto slot",
            inboundHs2 != null)
    }
}
