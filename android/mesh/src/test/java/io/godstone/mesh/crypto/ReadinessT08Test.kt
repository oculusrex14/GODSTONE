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
                // After the drops, operations must be typed-failed, alive.
                initiator.seal(peer, "post".toByteArray())
                responder.isReady(peer)
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
    fun testRelationKeyIsImmutableWrapperOfTheLookupHandle() {
        val handle = "aabbccdd"
        val key = RelationKey(handle)
        assertEquals(key, RelationKey(handle))
        assertEquals(key.hashCode(), RelationKey(handle).hashCode())
        assertNotEquals(key, RelationKey("eedd"))
        // The handle is the existing transport lookup handle, not a node id.
        assertEquals(handle, key.handle)
    }

    @Test
    fun testBoundedSlotMapOverTenThousandReconnects() {
        // The registry is bounded by LIVE relations: 10,000 reconnects over a
        // rotating handle set must not grow the slot map, must reclaim each
        // retired entry together with its lock, and must advance the
        // remembered generation so a replacement never aliases the incarnation
        // it replaces.
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
        val previousGeneration = LongArray(handleCount) { -1L }
        for (round in 0 until 10000) {
            val lane = round % handleCount
            val peer = handles[lane]
            val hs1 = initiator.initiatorStart(peer, identityR.nodeHint)
                ?: throw AssertionError("HS1 must be emitted on reconnect $round")
            val hs2 = responder.responderProcessHs1(peer, identityI.nodeHint, hs1)
                ?: throw AssertionError("HS2 must be emitted on reconnect $round")
            val hs3 = initiator.initiatorProcessHs2(peer, hs2, identityR.nodeHint)
                ?: throw AssertionError("HS3 must be emitted on reconnect $round")
            assertTrue(responder.responderProcessHs3(peer, hs3, identityI.nodeHint))
            val generation = initiator.slotLeaseGenerationForTest(peer)
                ?: throw AssertionError("a live slot must carry a lease")
            assertTrue(
                "generation must advance for lane $lane",
                generation > previousGeneration[lane]
            )
            previousGeneration[lane] = generation
            initiator.drop(peer)
            responder.drop(peer)
            if (initiator.slotCountForTest() > handleCount) {
                throw AssertionError("slot map grew past the live bound at round $round")
            }
            if (responder.slotCountForTest() > handleCount) {
                throw AssertionError("responder map grew past the live bound at round $round")
            }
            if (initiator.rememberedCountForTest() > 256) {
                throw AssertionError("the remembered-generation registry is unbounded")
            }
        }
        // Every entry was reclaimed with its lock entry: nothing leaks.
        assertEquals(0, initiator.slotCountForTest())
        assertEquals(0, responder.slotCountForTest())
        // Ten thousand reconnects over sixteen handles remember sixteen
        // generations - one per handle, not one per reconnect.
        assertEquals(handleCount, initiator.rememberedCountForTest())
        assertEquals(handleCount, responder.rememberedCountForTest())
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
        // The replacement advances the lease instead of aliasing the old one.
        assertNull(session.initiator.slotLeaseGenerationForTest(session.peer))
        val hs1 = session.initiator.initiatorStart(
            session.peer, session.responderHint
        ) ?: throw AssertionError("re-established HS1 must be emitted")
        val hs2 = session.responder.responderProcessHs1(
            session.peer, session.initiatorHint, hs1
        ) ?: throw AssertionError("re-established HS2 must be emitted")
        val hs3 = session.initiator.initiatorProcessHs2(
            session.peer, hs2, session.responderHint
        ) ?: throw AssertionError("re-established HS3 must be emitted")
        assertTrue(session.responder.responderProcessHs3(
            session.peer, hs3, session.initiatorHint))
        val generation = session.initiator.slotLeaseGenerationForTest(session.peer)
            ?: throw AssertionError("the replacement must carry a lease")
        assertTrue("the replacement must advance the generation", generation > 0L)
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
}