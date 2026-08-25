package io.godstone.mesh.crypto

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.delivery.BoundRecipientKeyResolver
import io.godstone.mesh.delivery.RepositoryPeerIdentityLookupSource
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.RuntimeGatedPeerBindingTrustAuthority
import io.godstone.mesh.identity.RuntimeGatedPeerIdentityLookupSource
import io.godstone.mesh.identity.ValidatedPeerBinding
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class SessionManagerConcurrencyTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private class RecordingTrustAuthority : PeerBindingTrustAuthority {
        val applyCount = AtomicInteger(0)
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            applyCount.incrementAndGet()
            return PeerTrustApplyResult.Accepted
        }
    }

    @Test
    fun testRC01_ResolverLookupVsInvalidation() {
        val file = tempFolder.newFile("rc01.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(store)
        val gate = DefaultRuntimeLifecycleGate()
        val lookup = RuntimeGatedPeerIdentityLookupSource(RepositoryPeerIdentityLookupSource(repo), gate)
        val resolver = BoundRecipientKeyResolver(lookup)

        val peer = MeshIdentity.generate()
        val binding = peer.issueIdentityBinding()
        val validated = IdentityBindingValidator.validate(binding.encode(), peer.staticDhPub, peer.nodeHint) as IdentityBindingValidationResult.Valid
        repo.applyValidatedBinding(validated.binding)

        // 1. Before invalidation: lookup returns verified non-null key
        assertNotNull(resolver.publicSigningKey(peer.nodeId))

        // 2. Perform invalidation
        gate.invalidateForWipe()
        assertTrue(gate.isInvalidated)

        // 3. After invalidation boundary: concurrent readers all deterministically receive null
        val threads = 8
        val pool = Executors.newFixedThreadPool(threads)
        val doneLatch = CountDownLatch(threads)
        val postInvalidateNullCount = AtomicInteger(0)

        for (i in 0 until threads) {
            pool.execute {
                for (j in 0 until 50) {
                    val key = resolver.publicSigningKey(peer.nodeId)
                    if (key == null) {
                        postInvalidateNullCount.incrementAndGet()
                    }
                }
                doneLatch.countDown()
            }
        }

        assertTrue(doneLatch.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        assertEquals(threads * 50, postInvalidateNullCount.get())
        assertNull(resolver.publicSigningKey(peer.nodeId))
    }

    @Test
    fun testRC02_ReadySealVsInvalidation() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val trustB = RecordingTrustAuthority()
        val gate = DefaultRuntimeLifecycleGate()
        val smA = SessionManager(identityA, trustA, lifecycleGate = gate)
        val smB = SessionManager(identityB, trustB)

        // 1. Establish full cryptographic handshake to READY state
        val hs1 = smA.initiatorStart(identityB.nodeId, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(identityA.nodeId, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(identityB.nodeId, hs2, identityB.nodeHint)!!
        val readyB = smB.responderProcessHs3(identityA.nodeId, hs3, identityA.nodeHint)
        assertTrue(readyB)
        assertTrue(smA.isReady(identityB.nodeId))

        // 2. Linearization test: in-flight seal holds read lock; invalidation write lock must wait
        val enteredReadAuthority = CountDownLatch(1)
        val releaseThreadA = CountDownLatch(1)
        val invalidationStarted = CountDownLatch(1)
        val threadAFinished = CountDownLatch(1)
        val invalidationFinished = CountDownLatch(1)
        var sealResult: ByteArray? = null

        smA.testOperationHook = { op ->
            if (op == "seal") {
                enteredReadAuthority.countDown()
                releaseThreadA.await(5, TimeUnit.SECONDS)
            }
        }
        smA.testInvalidationAttemptHook = {
            invalidationStarted.countDown()
        }

        val pool = Executors.newFixedThreadPool(2)

        // Thread A: enters seal under read lock and pauses
        pool.execute {
            sealResult = smA.seal(identityB.nodeId, "linearized payload".toByteArray(Charsets.UTF_8))
            threadAFinished.countDown()
        }

        // Wait for Thread A to enter read authority
        assertTrue(enteredReadAuthority.await(5, TimeUnit.SECONDS))

        // Thread B: calls invalidateForWipe() which requires exclusive write lock
        pool.execute {
            smA.invalidateForWipe()
            invalidationFinished.countDown()
        }

        // Wait deterministically for Thread B to enter invalidateForWipe() before write-lock acquisition attempt
        assertTrue(invalidationStarted.await(5, TimeUnit.SECONDS))

        // Verify invalidation has NOT completed because Thread A is holding read lock
        assertEquals(1L, invalidationFinished.count)

        // Release Thread A
        releaseThreadA.countDown()

        // Thread A must finish successfully
        assertTrue(threadAFinished.await(5, TimeUnit.SECONDS))
        assertNotNull(sealResult)

        // Invalidation now acquires write lock and completes
        assertTrue(invalidationFinished.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        // Post-invalidation verification
        assertTrue(smA.isInvalidated)
        assertFalse(smA.isActive)
        assertFalse(smA.isReady(identityB.nodeId))
        assertNull(smA.seal(identityB.nodeId, "after wipe".toByteArray(Charsets.UTF_8)))
        assertNull(smA.open(identityB.nodeId, "after wipe".toByteArray(Charsets.UTF_8)))
        assertNull(smA.initiatorStart(identityB.nodeId, identityB.nodeHint))
    }

    @Test
    fun testRC03_HandshakeProcessingVsInvalidation() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val trustB = RecordingTrustAuthority()
        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        // 1. Generate real valid handshake messages
        val hs1 = smA.initiatorStart(identityB.nodeId, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(identityA.nodeId, identityA.nodeHint, hs1)!!

        val enteredHsReadAuthority = CountDownLatch(1)
        val releaseHsThread = CountDownLatch(1)
        val invalidationStarted = CountDownLatch(1)
        val hsThreadFinished = CountDownLatch(1)
        val invalidationFinished = CountDownLatch(1)
        var hs3Result: ByteArray? = null

        smA.testOperationHook = { op ->
            if (op == "initiatorProcessHs2") {
                enteredHsReadAuthority.countDown()
                releaseHsThread.await(5, TimeUnit.SECONDS)
            }
        }
        smA.testInvalidationAttemptHook = {
            invalidationStarted.countDown()
        }

        val pool = Executors.newFixedThreadPool(2)

        // Thread A: processes valid HS2 and pauses in read lock
        pool.execute {
            hs3Result = smA.initiatorProcessHs2(identityB.nodeId, hs2, identityB.nodeHint)
            hsThreadFinished.countDown()
        }

        // Wait for Thread A to enter read authority
        assertTrue(enteredHsReadAuthority.await(5, TimeUnit.SECONDS))

        // Thread B: calls invalidateForWipe() which requires exclusive write lock
        pool.execute {
            smA.invalidateForWipe()
            invalidationFinished.countDown()
        }

        // Wait deterministically for Thread B to enter invalidateForWipe() before write-lock acquisition attempt
        assertTrue(invalidationStarted.await(5, TimeUnit.SECONDS))

        // Verify invalidation has NOT completed because handshake is in-flight under read lock
        assertEquals(1L, invalidationFinished.count)

        // Release Thread A
        releaseHsThread.countDown()

        assertTrue(hsThreadFinished.await(5, TimeUnit.SECONDS))
        assertTrue(invalidationFinished.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        // After invalidation completes: no controller survives, no READY state, fresh operations denied
        assertTrue(smA.isInvalidated)
        assertFalse(smA.isActive)
        assertFalse(smA.isReady(identityB.nodeId))
        assertNull(smA.initiatorStart(identityB.nodeId, identityB.nodeHint))
        assertNull(smA.seal(identityB.nodeId, "test".toByteArray(Charsets.UTF_8)))
    }
}
