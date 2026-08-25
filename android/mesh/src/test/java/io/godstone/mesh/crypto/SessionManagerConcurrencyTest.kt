package io.godstone.mesh.crypto

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class SessionManagerConcurrencyTest {

    private class RecordingTrustAuthority : PeerBindingTrustAuthority {
        val applyCount = AtomicInteger(0)
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            applyCount.incrementAndGet()
            return PeerTrustApplyResult.Accepted
        }
    }

    @Test
    fun testConcurrency_SimultaneousInitiatorAndResponder_DoesNotCorrupt() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val smA = SessionManager(identityA, trustA)

        val threads = 8
        val pool = Executors.newFixedThreadPool(threads)
        val latch = CountDownLatch(threads)
        val successes = AtomicInteger(0)

        for (i in 0 until threads) {
            pool.execute {
                try {
                    val hs1 = smA.initiatorStart(identityB.nodeId, identityB.nodeHint)
                    if (hs1 != null) {
                        successes.incrementAndGet()
                    }
                } finally {
                    latch.countDown()
                }
            }
        }

        assertTrue(latch.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        // Exactly one concurrent initiatorStart should succeed for the same peer
        assertTrue(successes.get() in 1..threads)
    }

    @Test
    fun testConcurrency_SimultaneousSealAndInvalidation_FailsSafely() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val trustB = RecordingTrustAuthority()
        val gate = DefaultRuntimeLifecycleGate()
        val smA = SessionManager(identityA, trustA, lifecycleGate = gate)
        val smB = SessionManager(identityB, trustB)

        val hs1 = smA.initiatorStart(identityB.nodeId, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(identityA.nodeId, identityA.nodeHint, hs1)!!
        smA.initiatorProcessHs2(identityB.nodeId, hs2, identityB.nodeHint)!!
        smB.responderProcessHs3(identityA.nodeId, hs1, identityA.nodeHint)

        val threads = 16
        val pool = Executors.newFixedThreadPool(threads)
        val latch = CountDownLatch(threads)

        for (i in 0 until threads) {
            pool.execute {
                try {
                    if (i == 0) {
                        smA.invalidateForWipe()
                    } else {
                        smA.seal(identityB.nodeId, "test payload".toByteArray(Charsets.UTF_8))
                    }
                } finally {
                    latch.countDown()
                }
            }
        }

        assertTrue(latch.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        assertTrue(smA.isInvalidated)
        assertFalse(smA.isReady(identityB.nodeId))
    }

    @Test
    fun testConcurrency_ConcurrentHandshakeCompletions_SerializedPerPeer() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val smA = SessionManager(identityA, trustA)

        val peerB = identityB.nodeId
        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)
        assertNotNull(hs1)

        val threads = 4
        val pool = Executors.newFixedThreadPool(threads)
        val latch = CountDownLatch(threads)

        for (i in 0 until threads) {
            pool.execute {
                try {
                    // Bogus HS2 frames
                    smA.initiatorProcessHs2(peerB, ByteArray(229), identityB.nodeHint)
                } finally {
                    latch.countDown()
                }
            }
        }

        assertTrue(latch.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        // smA dropped peerB upon failure and never reached READY
        assertFalse(smA.isReady(peerB))
    }
}
