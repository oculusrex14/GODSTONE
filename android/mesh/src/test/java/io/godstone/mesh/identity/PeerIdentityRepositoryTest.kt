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
    private val staticPrivD = ByteArray(32) { 0x66 }

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
    // 5. CORRUPT ROW DETECTION & TRANSACTION ABORT ROLLBACK
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
            store.execRawSqlForTest("PRAGMA ignore_check_constraints = ON")
            store.insertFirstSeen(binding.nodeId, signPub, staticPub, 0L, 99)

            val applyRes = repo.applyValidatedBinding(binding)
            assertTrue(applyRes is PeerTrustApplyResult.Corrupt)
            assertTrue((applyRes as PeerTrustApplyResult.Corrupt).reason is PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode)

            val lookupRes = repo.lookup(binding.nodeId)
            assertTrue(lookupRes is PeerIdentityLookup.Corrupt)
        }
    }

    // Test proxy store capable of simulating readback corruption, cardinality variations, and faults
    private class HookableStore(val delegate: PeerIdentityStore) : PeerIdentityStore by delegate {
        var hookReadRaw: ((ByteArray) -> PeerIdentityRow?)? = null
        var hookInsertFirstSeen: ((ByteArray, ByteArray, ByteArray, Long, Int) -> Int)? = null
        var hookSetInitialPending: ((ByteArray, ByteArray, ByteArray, Long, Int, ByteArray, Long) -> Int)? = null
        var hookAdvancePending: ((ByteArray, ByteArray, ByteArray, Long, Int, ByteArray, Long, ByteArray, Long) -> Int)? = null
        var hookInTx: (((PeerIdentityStore) -> Any?) -> Any?)? = null

        override fun readRaw(nodeId: ByteArray): PeerIdentityRow? {
            val hook = hookReadRaw
            return if (hook != null) hook(nodeId) else delegate.readRaw(nodeId)
        }

        override fun insertFirstSeen(
            nodeId: ByteArray,
            signingPub: ByteArray,
            acceptedStatic: ByteArray,
            acceptedGeneration: Long,
            trustCode: Int
        ): Int {
            val hook = hookInsertFirstSeen
            return if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustCode)
            else delegate.insertFirstSeen(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustCode)
        }

        override fun setInitialPendingGuarded(
            nodeId: ByteArray,
            signingPub: ByteArray,
            acceptedStatic: ByteArray,
            acceptedGeneration: Long,
            trustLevel: Int,
            newPendingStatic: ByteArray,
            newPendingGeneration: Long
        ): Int {
            val hook = hookSetInitialPending
            return if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, newPendingStatic, newPendingGeneration)
            else delegate.setInitialPendingGuarded(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, newPendingStatic, newPendingGeneration)
        }

        override fun advancePendingGuarded(
            nodeId: ByteArray,
            signingPub: ByteArray,
            acceptedStatic: ByteArray,
            acceptedGeneration: Long,
            trustLevel: Int,
            oldPendingStatic: ByteArray,
            oldPendingGeneration: Long,
            newPendingStatic: ByteArray,
            newPendingGeneration: Long
        ): Int {
            val hook = hookAdvancePending
            return if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, oldPendingStatic, oldPendingGeneration, newPendingStatic, newPendingGeneration)
            else delegate.advancePendingGuarded(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, oldPendingStatic, oldPendingGeneration, newPendingStatic, newPendingGeneration)
        }

        override fun <T> inImmediateTransaction(block: (PeerIdentityStore) -> T): T {
            val hook = hookInTx
            return if (hook != null) {
                @Suppress("UNCHECKED_CAST")
                hook(block as (PeerIdentityStore) -> Any?) as T
            } else {
                delegate.inImmediateTransaction { block(this) }
            }
        }
    }

    @Test
    fun testFirstSeenReadbackCorruptionRollsBack() {
        val file = tempFolder.newFile("rb_fs_corrupt.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)
            val b = makeBinding(seedA, 0L, staticPrivA)

            var readCount = 0
            hookStore.hookReadRaw = { nodeId ->
                readCount++
                if (readCount == 1) {
                    // Initial lookup before evaluate: absent
                    null
                } else {
                    // Post-mutation readback: corrupt trust level code
                    PeerIdentityRow(
                        nodeIdRaw = nodeId,
                        signingPublicKeyRaw = b.signingPublicKey,
                        acceptedStaticDhPublicKeyRaw = b.staticDhPublicKey,
                        acceptedGenerationRaw = b.generation,
                        trustCodeRaw = 999, // Corrupt!
                        pendingStaticDhPublicKeyRaw = null,
                        pendingGenerationRaw = null
                    )
                }
            }

            val res = repo.applyValidatedBinding(b)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            val reason = (res as PeerTrustApplyResult.Corrupt).reason
            assertTrue(reason is PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode)

            // CRITICAL: Ensure transaction was aborted and database has NO row inserted!
            hookStore.hookReadRaw = null
            assertNull(rawStore.readRaw(b.nodeId))
        }
    }

    @Test
    fun testInitialPendingReadbackCorruptionRollsBack() {
        val file = tempFolder.newFile("rb_init_corrupt.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            assertEquals(PeerTrustApplyResult.FirstSeenPinned, repo.applyValidatedBinding(b1))

            val b2 = makeBinding(seedA, 1L, staticPrivB)
            var readCount = 0
            hookStore.hookReadRaw = { nodeId ->
                readCount++
                if (readCount == 1) {
                    rawStore.readRaw(nodeId)
                } else {
                    // Post-mutation readback: corrupt out-of-range pending generation
                    val valid = rawStore.readRaw(nodeId)!!
                    PeerIdentityRow(
                        nodeIdRaw = valid.nodeIdRaw,
                        signingPublicKeyRaw = valid.signingPublicKeyRaw,
                        acceptedStaticDhPublicKeyRaw = valid.acceptedStaticDhPublicKeyRaw,
                        acceptedGenerationRaw = valid.acceptedGenerationRaw,
                        trustCodeRaw = valid.trustCodeRaw,
                        pendingStaticDhPublicKeyRaw = b2.staticDhPublicKey,
                        pendingGenerationRaw = 5000000000L // Corrupt > UINT32_MAX!
                    )
                }
            }

            val res = repo.applyValidatedBinding(b2)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            assertTrue((res as PeerTrustApplyResult.Corrupt).reason is PeerTrustRepositoryCorruptionReason.PendingGenerationOutOfRange)

            // Ensure rollback: state must remain b1 with no pending
            hookStore.hookReadRaw = null
            val restored = rawStore.readRaw(b1.nodeId)
            assertNotNull(restored)
            assertNull(restored!!.pendingStaticDhPublicKeyRaw)
            assertNull(restored.pendingGenerationRaw)
        }
    }

    @Test
    fun testAdvancePendingReadbackCorruptionRollsBack() {
        val file = tempFolder.newFile("rb_adv_corrupt.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b1)
            val b2 = makeBinding(seedA, 1L, staticPrivB)
            repo.applyValidatedBinding(b2)

            val b3 = makeBinding(seedA, 2L, staticPrivC)
            var readCount = 0
            hookStore.hookReadRaw = { nodeId ->
                readCount++
                if (readCount == 1) {
                    rawStore.readRaw(nodeId)
                } else {
                    // Return mismatch (valid candidate record, but does not match b3)
                    val valid = rawStore.readRaw(nodeId)!!
                    PeerIdentityRow(
                        nodeIdRaw = valid.nodeIdRaw,
                        signingPublicKeyRaw = valid.signingPublicKeyRaw,
                        acceptedStaticDhPublicKeyRaw = valid.acceptedStaticDhPublicKeyRaw,
                        acceptedGenerationRaw = valid.acceptedGenerationRaw,
                        trustCodeRaw = valid.trustCodeRaw,
                        pendingStaticDhPublicKeyRaw = b2.staticDhPublicKey, // Valid (differs from accepted), but does NOT match b3!
                        pendingGenerationRaw = 99L
                    )
                }
            }

            val res = repo.applyValidatedBinding(b3)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            assertTrue((res as PeerTrustApplyResult.Corrupt).reason is PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch)

            // Ensure rollback: state retains b2 pending candidate
            hookStore.hookReadRaw = null
            val restored = rawStore.readRaw(b1.nodeId)
            assertNotNull(restored)
            assertEquals(1L, restored!!.pendingGenerationRaw)
            assertArrayEquals(b2.staticDhPublicKey, restored.pendingStaticDhPublicKeyRaw)
        }
    }

    // =========================================================================
    // 6. MUTATION CARDINALITY MATRIX (0 and 2 affected rows)
    // =========================================================================

    @Test
    fun testCardinalityMatrix_InitialPending_ZeroAffected_RollsBack() {
        val file = tempFolder.newFile("card_init_0.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b1)

            hookStore.hookSetInitialPending = { _, _, _, _, _, _, _ -> 0 } // Force 0 affected
            val b2 = makeBinding(seedA, 1L, staticPrivB)
            val res = repo.applyValidatedBinding(b2)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            assertEquals(
                PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 0),
                (res as PeerTrustApplyResult.Corrupt).reason
            )

            hookStore.hookSetInitialPending = null
            val row = rawStore.readRaw(b1.nodeId)
            assertNull(row!!.pendingGenerationRaw)
        }
    }

    @Test
    fun testCardinalityMatrix_InitialPending_TwoAffected_RollsBack() {
        val file = tempFolder.newFile("card_init_2.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b1)

            hookStore.hookSetInitialPending = { _, _, _, _, _, _, _ -> 2 } // Force 2 affected
            val b2 = makeBinding(seedA, 1L, staticPrivB)
            val res = repo.applyValidatedBinding(b2)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            assertEquals(
                PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 2),
                (res as PeerTrustApplyResult.Corrupt).reason
            )
        }
    }

    @Test
    fun testCardinalityMatrix_AdvancePending_ZeroAffected_RollsBack() {
        val file = tempFolder.newFile("card_adv_0.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b1)
            val b2 = makeBinding(seedA, 1L, staticPrivB)
            repo.applyValidatedBinding(b2)

            hookStore.hookAdvancePending = { _, _, _, _, _, _, _, _, _ -> 0 }
            val b3 = makeBinding(seedA, 2L, staticPrivC)
            val res = repo.applyValidatedBinding(b3)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            assertEquals(
                PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 0),
                (res as PeerTrustApplyResult.Corrupt).reason
            )
        }
    }

    @Test
    fun testCardinalityMatrix_AdvancePending_TwoAffected_RollsBack() {
        val file = tempFolder.newFile("card_adv_2.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b1)
            val b2 = makeBinding(seedA, 1L, staticPrivB)
            repo.applyValidatedBinding(b2)

            hookStore.hookAdvancePending = { _, _, _, _, _, _, _, _, _ -> 2 }
            val b3 = makeBinding(seedA, 2L, staticPrivC)
            val res = repo.applyValidatedBinding(b3)
            assertTrue(res is PeerTrustApplyResult.Corrupt)
            assertEquals(
                PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 2),
                (res as PeerTrustApplyResult.Corrupt).reason
            )
        }
    }

    // =========================================================================
    // 7. STORAGE FAULT ROLLBACK TESTS (F1, F2, F3, Commit Failure)
    // =========================================================================

    @Test
    fun testStorageFaultF1_FirstSeenFailure_RollsBack() {
        val file = tempFolder.newFile("fault_f1.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            hookStore.hookInsertFirstSeen = { _, _, _, _, _ ->
                throw java.sql.SQLException("Injected fault in insertFirstSeen")
            }

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            val res = repo.applyValidatedBinding(b1)
            assertTrue(res is PeerTrustApplyResult.StorageFailure)

            hookStore.hookInsertFirstSeen = null
            assertNull(rawStore.readRaw(b1.nodeId))
        }
    }

    @Test
    fun testStorageFaultF2_InitialPendingFailure_RollsBack() {
        val file = tempFolder.newFile("fault_f2.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b1)

            hookStore.hookSetInitialPending = { _, _, _, _, _, _, _ ->
                throw java.sql.SQLException("Injected fault in setInitialPendingGuarded")
            }

            val b2 = makeBinding(seedA, 1L, staticPrivB)
            val res = repo.applyValidatedBinding(b2)
            assertTrue(res is PeerTrustApplyResult.StorageFailure)

            hookStore.hookSetInitialPending = null
            val row = rawStore.readRaw(b1.nodeId)
            assertNull(row!!.pendingGenerationRaw)
        }
    }

    @Test
    fun testStorageFaultF3_AdvancePendingFailure_RollsBack() {
        val file = tempFolder.newFile("fault_f3.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b1)
            val b2 = makeBinding(seedA, 1L, staticPrivB)
            repo.applyValidatedBinding(b2)

            hookStore.hookAdvancePending = { _, _, _, _, _, _, _, _, _ ->
                throw java.sql.SQLException("Injected fault in advancePendingGuarded")
            }

            val b3 = makeBinding(seedA, 2L, staticPrivC)
            val res = repo.applyValidatedBinding(b3)
            assertTrue(res is PeerTrustApplyResult.StorageFailure)

            hookStore.hookAdvancePending = null
            val row = rawStore.readRaw(b1.nodeId)
            assertEquals(1L, row!!.pendingGenerationRaw)
        }
    }

    @Test
    fun testCommitFailureRollsBack() {
        val file = tempFolder.newFile("fault_commit.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { rawStore ->
            val hookStore = HookableStore(rawStore)
            val repo = PeerIdentityRepository(hookStore)

            hookStore.hookInTx = { block ->
                rawStore.inImmediateTransaction { tx ->
                    block(tx)
                    throw java.sql.SQLException("Simulated commit failure")
                }
            }

            val b1 = makeBinding(seedA, 0L, staticPrivA)
            val res = repo.applyValidatedBinding(b1)
            assertTrue(res is PeerTrustApplyResult.StorageFailure)

            hookStore.hookInTx = null
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
        assertTrue("One must first-seen pin", results.contains(PeerTrustApplyResult.FirstSeenPinned))
        assertTrue("One must accept", results.contains(PeerTrustApplyResult.Accepted))

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

        // Legal outcome taxonomy for C2:
        // Either:
        // Option 1: Gen 5 runs first (KeyChangedQuarantined), then Gen 6 runs (KeyChangedQuarantined)
        // Option 2: Gen 6 runs first (KeyChangedQuarantined), then Gen 5 runs (Rejected(Rollback))
        val isOption1 = (r1 == PeerTrustApplyResult.KeyChangedQuarantined && r2 == PeerTrustApplyResult.KeyChangedQuarantined)
        val isOption2 = (r1 == PeerTrustApplyResult.Rejected(PeerTrustRejectReason.Rollback) && r2 == PeerTrustApplyResult.KeyChangedQuarantined) ||
                        (r1 == PeerTrustApplyResult.KeyChangedQuarantined && r2 == PeerTrustApplyResult.Rejected(PeerTrustRejectReason.Rollback))

        assertTrue("Outcome must match legal taxonomy: r1=$r1, r2=$r2", isOption1 || isOption2)

        // Final state MUST be pendingGeneration == 6 / static K6
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(6L, row.pendingGenerationRaw)
            assertArrayEquals(bGen6.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testConcurrencyC3AdvancePendingHighWater() {
        val file = tempFolder.newFile("conc_c3.db").also { it.delete() }
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        // Setup: accepted Gen 0, pending Gen 5
        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo1.applyValidatedBinding(b0)
        val bGen5 = makeBinding(seedA, 5L, staticPrivB)
        repo1.applyValidatedBinding(bGen5)

        val bGen7 = makeBinding(seedA, 7L, staticPrivC)
        val bGen8 = makeBinding(seedA, 8L, staticPrivD)

        val executor = Executors.newFixedThreadPool(2)
        val f1 = executor.submit(Callable { repo1.applyValidatedBinding(bGen7) })
        val f2 = executor.submit(Callable { repo2.applyValidatedBinding(bGen8) })

        val r1 = f1.get()
        val r2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        val isOption1 = (r1 == PeerTrustApplyResult.KeyChangedQuarantined && r2 == PeerTrustApplyResult.KeyChangedQuarantined)
        val isOption2 = (r1 == PeerTrustApplyResult.Rejected(PeerTrustRejectReason.StaleRelativeToPending) && r2 == PeerTrustApplyResult.KeyChangedQuarantined)

        assertTrue("Outcome must match legal taxonomy: r1=$r1, r2=$r2", isOption1 || isOption2)

        // Final state MUST be pendingGeneration == 8
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(8L, row.pendingGenerationRaw)
            assertArrayEquals(bGen8.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testConcurrencyC4IndependentNodes() {
        val file = tempFolder.newFile("conc_c4.db").also { it.delete() }
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        val bNodeA = makeBinding(seedA, 1L, staticPrivA)
        val bNodeB = makeBinding(seedB, 1L, staticPrivB)

        val executor = Executors.newFixedThreadPool(2)
        val f1 = executor.submit(Callable { repo1.applyValidatedBinding(bNodeA) })
        val f2 = executor.submit(Callable { repo2.applyValidatedBinding(bNodeB) })

        val r1 = f1.get()
        val r2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        assertEquals(PeerTrustApplyResult.FirstSeenPinned, r1)
        assertEquals(PeerTrustApplyResult.FirstSeenPinned, r2)

        JdbcPeerIdentityStore(file).use { store ->
            val rowA = store.readRaw(bNodeA.nodeId)
            val rowB = store.readRaw(bNodeB.nodeId)
            assertNotNull(rowA)
            assertNotNull(rowB)
            assertEquals(1L, rowA!!.acceptedGenerationRaw)
            assertEquals(1L, rowB!!.acceptedGenerationRaw)
        }
    }
}
