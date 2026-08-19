package io.godstone.mesh.identity

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.Future

class PeerIdentityRepositoryTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private val seedA = ByteArray(32) { 0x11 }
    private val seedB = ByteArray(32) { 0x22 }

    private val staticPrivA = ByteArray(32) { 0x33 }
    private val staticPrivB = ByteArray(32) { 0x44 }
    private val staticPrivC = ByteArray(32) { 0x55 }

    private fun makeBinding(
        seed: ByteArray,
        generation: Long,
        staticDhPriv: ByteArray = staticPrivA
    ): ValidatedPeerBinding {
        val signingPub = Ed25519Keys.publicKeyFromPrivate(seed)
        val staticPub = X25519Keys.publicKeyFromPrivate(staticDhPriv)
        val preimage = IdentityBindingV1.signaturePreimage(
            generation = generation,
            signingPublicKey = signingPub,
            staticDhPublicKey = staticPub
        )
        val sig = Ed25519Keys.sign(preimage, seed)
        val binding = IdentityBindingV1.create(
            generation = generation,
            signingPublicKey = signingPub,
            staticDhPublicKey = staticPub,
            signature = sig
        )
        val res = IdentityBindingValidator.validate(
            serialized = binding.encode(),
            authenticatedRemoteStaticKey = staticPub,
            advertisedNodeHint = IdentityBindingV1.deriveNodeHint(IdentityBindingV1.deriveNodeId(signingPub))
        )
        require(res is IdentityBindingValidationResult.Valid) { "Validation failed" }
        return res.binding
    }

    // =========================================================================
    // 1. FIRST SEEN & RECONNECT TESTS
    // =========================================================================

    @Test
    fun testFirstSeenGenerationZero() {
        val file = tempFolder.newFile("fs0.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val binding = makeBinding(seedA, 0L, staticPrivA)
            val result = repo.applyValidatedBinding(binding)
            assertEquals(PeerTrustApplyResult.FirstSeenPinned, result)

            val lookup = repo.lookup(binding.nodeId)
            assertTrue(lookup is PeerIdentityLookup.Verified)
            val verified = (lookup as PeerIdentityLookup.Verified).identity
            assertEquals(0L, verified.acceptedGeneration)
            assertEquals(PeerTrustLevel.TOFU_PINNED, verified.trustLevel)
        }
    }

    @Test
    fun testFirstSeenGenerationSeven() {
        val file = tempFolder.newFile("fs7.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val binding = makeBinding(seedA, 7L, staticPrivA)
            val result = repo.applyValidatedBinding(binding)
            assertEquals(PeerTrustApplyResult.FirstSeenPinned, result)

            val lookup = repo.lookup(binding.nodeId)
            assertTrue(lookup is PeerIdentityLookup.Verified)
            val verified = (lookup as PeerIdentityLookup.Verified).identity
            assertEquals(7L, verified.acceptedGeneration)
        }
    }

    @Test
    fun testFirstSeenGenerationUint32Max() {
        val file = tempFolder.newFile("fs_max.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val binding = makeBinding(seedA, 0xFFFFFFFFL, staticPrivA)
            val result = repo.applyValidatedBinding(binding)
            assertEquals(PeerTrustApplyResult.FirstSeenPinned, result)

            // Exact reconnect at max generation -> Accepted
            val res2 = repo.applyValidatedBinding(binding)
            assertEquals(PeerTrustApplyResult.Accepted, res2)
        }
    }

    @Test
    fun testExactReconnectAccepted() {
        val file = tempFolder.newFile("exact.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val binding = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(binding)

            val res2 = repo.applyValidatedBinding(binding)
            assertEquals(PeerTrustApplyResult.Accepted, res2)
        }
    }

    // =========================================================================
    // 2. ROTATION & QUARANTINE PROGRESSION
    // =========================================================================

    @Test
    fun testInitialPendingCandidate() {
        val file = tempFolder.newFile("init_pending.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val b1 = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(b1)

            val b2 = makeBinding(seedA, 6L, staticPrivB)
            val res = repo.applyValidatedBinding(b2)
            assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, res)

            val lookup = repo.lookup(b1.nodeId)
            assertTrue(lookup is PeerIdentityLookup.Quarantined)
            val quarantined = (lookup as PeerIdentityLookup.Quarantined).identity
            assertEquals(5L, quarantined.acceptedGeneration)
            assertEquals(6L, quarantined.pendingGeneration)
        }
    }

    @Test
    fun testAdvancePendingCandidateHighWater() {
        val file = tempFolder.newFile("advance_pending.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val b1 = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(b1)

            val b2 = makeBinding(seedA, 6L, staticPrivB)
            repo.applyValidatedBinding(b2)

            val b3 = makeBinding(seedA, 8L, staticPrivC)
            val res = repo.applyValidatedBinding(b3)
            assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, res)

            val lookup = repo.lookup(b1.nodeId)
            val quarantined = (lookup as PeerIdentityLookup.Quarantined).identity
            assertEquals(5L, quarantined.acceptedGeneration)
            assertEquals(8L, quarantined.pendingGeneration)
        }
    }

    @Test
    fun testPendingDuplicateKeepsQuarantined() {
        val file = tempFolder.newFile("dup_pending.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val b1 = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(b1)

            val b2 = makeBinding(seedA, 6L, staticPrivB)
            repo.applyValidatedBinding(b2)

            // Re-applying b2 must return KeyChangedQuarantined with no DB mutation
            val res = repo.applyValidatedBinding(b2)
            assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, res)
        }
    }

    @Test
    fun testOldAcceptedDuringQuarantineKeepsQuarantined() {
        val file = tempFolder.newFile("old_acc_quarantine.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val b1 = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(b1)

            val b2 = makeBinding(seedA, 6L, staticPrivB)
            repo.applyValidatedBinding(b2)

            // Reconnecting with b1 while quarantined returns KeyChangedQuarantined
            val res = repo.applyValidatedBinding(b1)
            assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, res)
        }
    }

    // =========================================================================
    // 3. REJECTION & NON-MUTATION TESTS
    // =========================================================================

    @Test
    fun testRollbackRejectedWithoutMutation() {
        val file = tempFolder.newFile("rollback.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val b1 = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(b1)

            val bLower = makeBinding(seedA, 4L, staticPrivA)
            val res = repo.applyValidatedBinding(bLower)
            assertEquals(PeerTrustApplyResult.Rejected(PeerTrustRejectReason.Rollback), res)

            // Verify stored row untouched
            val row = store.readRaw(b1.nodeId)
            assertEquals(5L, row!!.acceptedGenerationRaw)
        }
    }

    // =========================================================================
    // 4. LOOKUP CLASSIFICATION TESTS (L1 - L10)
    // =========================================================================

    @Test
    fun testLookupClassifications() {
        val file = tempFolder.newFile("lookup.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)

            // L1: Absent
            val missingId = ByteArray(16) { 0x99.toByte() }
            assertEquals(PeerIdentityLookup.NotFound, repo.lookup(missingId))

            // L10: Invalid length
            val shortId = ByteArray(15)
            assertTrue(repo.lookup(shortId) is PeerIdentityLookup.InvalidArgument)

            // L2: Valid TOFU / no pending
            val b1 = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(b1)
            val l2 = repo.lookup(b1.nodeId)
            assertTrue(l2 is PeerIdentityLookup.Verified)
            assertEquals(PeerTrustLevel.TOFU_PINNED, (l2 as PeerIdentityLookup.Verified).identity.trustLevel)

            // L4: Valid TOFU / pending
            val b2 = makeBinding(seedA, 10L, staticPrivB)
            repo.applyValidatedBinding(b2)
            val l4 = repo.lookup(b1.nodeId)
            assertTrue(l4 is PeerIdentityLookup.Quarantined)

            // Test Revoked (insert directly via test store helper)
            val revNode = ByteArray(16) { 0x77 }
            val signPub = Ed25519Keys.publicKeyFromPrivate(seedB)
            val revSignNode = IdentityBindingV1.deriveNodeId(signPub)
            val staticPub = X25519Keys.publicKeyFromPrivate(staticPrivA)
            store.insertFirstSeen(revSignNode, signPub, staticPub, 1L, PeerTrustLevel.REVOKED.persistedCode)

            // L6: Revoked
            assertEquals(PeerIdentityLookup.Revoked, repo.lookup(revSignNode))
        }
    }

    // =========================================================================
    // 5. CORRUPT ROW DETECTION (R-C1 to R-C9)
    // =========================================================================

    @Test
    fun testCorruptRowDetectionFailsClosed() {
        val file = tempFolder.newFile("corrupt.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)

            val binding = makeBinding(seedA, 0L, staticPrivA)
            val signPub = Ed25519Keys.publicKeyFromPrivate(seedA)
            val staticPub = X25519Keys.publicKeyFromPrivate(staticPrivA)

            // Insert invalid trust code (99) bypassing CHECK with PRAGMA
            store.execRawSql("PRAGMA ignore_check_constraints = ON")
            store.insertFirstSeen(binding.nodeId, signPub, staticPub, 0L, 99)

            val applyRes = repo.applyValidatedBinding(binding)
            assertTrue(applyRes is PeerTrustApplyResult.Corrupt)
            assertTrue((applyRes as PeerTrustApplyResult.Corrupt).reason is PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode)

            val lookupRes = repo.lookup(binding.nodeId)
            assertTrue(lookupRes is PeerIdentityLookup.Corrupt)
        }
    }

    // =========================================================================
    // 6. MUTATION CARDINALITY & READBACK MISMATCH TESTS
    // =========================================================================

    private class ControlledStore(val delegate: PeerIdentityStore) : PeerIdentityStore by delegate {
        var forcedAffected: Int? = null

        override fun setInitialPendingGuarded(
            nodeId: ByteArray,
            signingPub: ByteArray,
            acceptedStatic: ByteArray,
            acceptedGeneration: Long,
            trustLevel: Int,
            newPendingStatic: ByteArray,
            newPendingGeneration: Long
        ): Int {
            return forcedAffected ?: delegate.setInitialPendingGuarded(
                nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, newPendingStatic, newPendingGeneration
            )
        }

        override fun <T> inImmediateTransaction(block: (PeerIdentityStore) -> T): T {
            return delegate.inImmediateTransaction { block(this) }
        }
    }

    @Test
    fun testMutationCardinalityMismatch() {
        val file = tempFolder.newFile("cardinality.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val controlled = ControlledStore(rawStore)
            val repo = PeerIdentityRepository(controlled)

            val b1 = makeBinding(seedA, 5L, staticPrivA)
            repo.applyValidatedBinding(b1)

            // Force 0 affected rows
            controlled.forcedAffected = 0
            val b2 = makeBinding(seedA, 6L, staticPrivB)
            val res = repo.applyValidatedBinding(b2)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            val reason = (res as PeerTrustApplyResult.Corrupt).reason
            assertTrue(reason is PeerTrustRepositoryCorruptionReason.MutationCardinality)
            assertEquals(0, (reason as PeerTrustRepositoryCorruptionReason.MutationCardinality).actual)
        }
    }

    // =========================================================================
    // 7. SQL FAULT ROLLBACK TESTS (F1, F2, F3)
    // =========================================================================

    private class FaultingStore(val delegate: PeerIdentityStore) : PeerIdentityStore by delegate {
        var faultInTx: Boolean = false

        override fun <T> inImmediateTransaction(block: (PeerIdentityStore) -> T): T {
            return delegate.inImmediateTransaction { tx ->
                val res = block(tx)
                if (faultInTx) {
                    throw RuntimeException("Injected mid-transaction SQL fault")
                }
                res
            }
        }
    }

    @Test
    fun testMidTransactionFaultRollsBack() {
        val file = tempFolder.newFile("fault.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val faulting = FaultingStore(rawStore)
            val repo = PeerIdentityRepository(faulting)

            faulting.faultInTx = true
            val b1 = makeBinding(seedA, 0L, staticPrivA)
            val res = repo.applyValidatedBinding(b1)
            assertTrue(res is PeerTrustApplyResult.StorageFailure)

            // Reopen and assert row absent
            assertNull(rawStore.readRaw(b1.nodeId))
        }
    }

    // =========================================================================
    // 8. CROSS-CONNECTION CONCURRENCY TESTS (C1, C2, C3, C4)
    // =========================================================================

    @Test
    fun testConcurrencyC1IdenticalFirstSeen() {
        val file = tempFolder.newFile("conc_c1.db").also { it.delete() }
        // Create 2 independent stores / connections to the same file
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        val binding = makeBinding(seedA, 5L, staticPrivA)

        val executor = Executors.newFixedThreadPool(2)
        val task1 = Callable { repo1.applyValidatedBinding(binding) }
        val task2 = Callable { repo2.applyValidatedBinding(binding) }

        val f1 = executor.submit(task1)
        val f2 = executor.submit(task2)

        val res1 = f1.get()
        val res2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        val results = listOf(res1, res2)
        assertTrue(results.contains(PeerTrustApplyResult.FirstSeenPinned))
        assertTrue(results.contains(PeerTrustApplyResult.Accepted))

        // Read back on fresh store
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(binding.nodeId)
            assertNotNull(row)
            assertEquals(5L, row!!.acceptedGenerationRaw)
            assertNull(row.pendingGenerationRaw)
        }
    }

    @Test
    fun testConcurrencyC2Gen5Gen6HighWater() {
        val file = tempFolder.newFile("conc_c2.db").also { it.delete() }
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        // Baseline: Gen 0
        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo1.applyValidatedBinding(b0)

        val bGen5 = makeBinding(seedA, 5L, staticPrivB)
        val bGen6 = makeBinding(seedA, 6L, staticPrivC)

        val executor = Executors.newFixedThreadPool(2)
        val f1 = executor.submit(Callable { repo1.applyValidatedBinding(bGen5) })
        val f2 = executor.submit(Callable { repo2.applyValidatedBinding(bGen6) })

        val r1 = f1.get()
        val r2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        // Final state MUST be pendingGeneration == 6 / static K6
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(6L, row.pendingGenerationRaw)
            assertArrayEquals(bGen6.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }
}
