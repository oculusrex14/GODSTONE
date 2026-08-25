package io.godstone.mesh.crypto

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.RuntimeGatedPeerBindingTrustAuthority
import io.godstone.mesh.identity.RuntimeGatedPeerIdentityLookupSource
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.delivery.BoundRecipientKeyResolver
import io.godstone.mesh.delivery.RepositoryPeerIdentityLookupSource
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

        assertNotNull(resolver.publicSigningKey(peer.nodeId))

        val threads = 8
        val pool = Executors.newFixedThreadPool(threads + 1)
        val startLatch = CountDownLatch(1)
        val doneLatch = CountDownLatch(threads + 1)

        val postInvalidateNullCount = AtomicInteger(0)

        // Readers
        for (i in 0 until threads) {
            pool.execute {
                startLatch.await()
                for (j in 0 until 50) {
                    val key = resolver.publicSigningKey(peer.nodeId)
                    if (gate.isInvalidated) {
                        if (key == null) {
                            postInvalidateNullCount.incrementAndGet()
                        }
                    }
                }
                doneLatch.countDown()
            }
        }

        // Invalidator
        pool.execute {
            startLatch.await()
            gate.invalidateForWipe()
            doneLatch.countDown()
        }

        startLatch.countDown()
        assertTrue(doneLatch.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        assertTrue(gate.isInvalidated)
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

        // Perform full handshake to READY
        val hs1 = smA.initiatorStart(identityB.nodeId, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(identityA.nodeId, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(identityB.nodeId, hs2, identityB.nodeHint)!!
        val readyB = smB.responderProcessHs3(identityA.nodeId, hs3, identityA.nodeHint)
        assertTrue(readyB)
        assertTrue(smA.isReady(identityB.nodeId))

        val threads = 8
        val pool = Executors.newFixedThreadPool(threads + 1)
        val startLatch = CountDownLatch(1)
        val doneLatch = CountDownLatch(threads + 1)

        val sealsAttempted = AtomicInteger(0)
        val sealsSucceeded = AtomicInteger(0)
        val postInvalidateDenials = AtomicInteger(0)

        for (i in 0 until threads) {
            pool.execute {
                startLatch.await()
                for (j in 0 until 100) {
                    sealsAttempted.incrementAndGet()
                    val ciphertext = smA.seal(identityB.nodeId, "payload $j".toByteArray(Charsets.UTF_8))
                    if (ciphertext != null) {
                        sealsSucceeded.incrementAndGet()
                    } else if (smA.isInvalidated) {
                        postInvalidateDenials.incrementAndGet()
                    }
                }
                doneLatch.countDown()
            }
        }

        pool.execute {
            startLatch.await()
            smA.invalidateForWipe()
            doneLatch.countDown()
        }

        startLatch.countDown()
        assertTrue(doneLatch.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        // Invalidation must have completed, and all subsequent operations are denied
        assertTrue(smA.isInvalidated)
        assertFalse(smA.isActive)
        assertFalse(smA.isReady(identityB.nodeId))
        assertNull(smA.seal(identityB.nodeId, "after wipe".toByteArray(Charsets.UTF_8)))
        assertNull(smA.open(identityB.nodeId, "after wipe".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun testRC03_HandshakeProcessingVsInvalidation() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val smA = SessionManager(identityA, trustA)

        val peerB = identityB.nodeId
        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)
        assertNotNull(hs1)

        val threads = 4
        val pool = Executors.newFixedThreadPool(threads + 1)
        val startLatch = CountDownLatch(1)
        val doneLatch = CountDownLatch(threads + 1)

        for (i in 0 until threads) {
            pool.execute {
                startLatch.await()
                smA.initiatorProcessHs2(peerB, ByteArray(229), identityB.nodeHint)
                doneLatch.countDown()
            }
        }

        pool.execute {
            startLatch.await()
            smA.invalidateForWipe()
            doneLatch.countDown()
        }

        startLatch.countDown()
        assertTrue(doneLatch.await(5, TimeUnit.SECONDS))
        pool.shutdown()

        assertTrue(smA.isInvalidated)
        assertFalse(smA.isReady(peerB))
        assertNull(smA.initiatorStart(peerB, identityB.nodeHint))
    }
}
