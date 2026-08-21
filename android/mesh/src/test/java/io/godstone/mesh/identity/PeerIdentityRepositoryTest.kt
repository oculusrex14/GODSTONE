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
import java.sql.SQLException
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
        var hookApprovePending: ((ByteArray, ByteArray, ByteArray, Long, Int, ByteArray, Long) -> Int)? = null
        var hookRevoke: ((ByteArray, ByteArray, ByteArray, Long, Int, ByteArray?, Long?) -> Int)? = null
        var hookInTx: (((PeerIdentityStore) -> Any?) -> Any?)? = null

        var faultAfterInsert: Boolean = false
        var faultAfterInitialPending: Boolean = false
        var faultAfterAdvancePending: Boolean = false
        var faultAfterApprove: Boolean = false
        var faultAfterRevoke: Boolean = false

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
            val affected = if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustCode)
            else delegate.insertFirstSeen(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustCode)
            if (faultAfterInsert) {
                assertEquals(1, affected)
                throw SQLException("Injected post-insert storage fault (F1)")
            }
            return affected
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
            val affected = if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, newPendingStatic, newPendingGeneration)
            else delegate.setInitialPendingGuarded(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, newPendingStatic, newPendingGeneration)
            if (faultAfterInitialPending) {
                assertEquals(1, affected)
                throw SQLException("Injected post-initial-pending storage fault (F2)")
            }
            return affected
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
            val affected = if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, oldPendingStatic, oldPendingGeneration, newPendingStatic, newPendingGeneration)
            else delegate.advancePendingGuarded(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, oldPendingStatic, oldPendingGeneration, newPendingStatic, newPendingGeneration)
            if (faultAfterAdvancePending) {
                assertEquals(1, affected)
                throw SQLException("Injected post-advance-pending storage fault (F3)")
            }
            return affected
        }

        override fun approvePendingRotationGuarded(
            nodeId: ByteArray,
            signingPub: ByteArray,
            acceptedStatic: ByteArray,
            acceptedGeneration: Long,
            trustLevel: Int,
            expectedPendingStatic: ByteArray,
            expectedPendingGeneration: Long
        ): Int {
            val hook = hookApprovePending
            val affected = if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, expectedPendingStatic, expectedPendingGeneration)
            else delegate.approvePendingRotationGuarded(nodeId, signingPub, acceptedStatic, acceptedGeneration, trustLevel, expectedPendingStatic, expectedPendingGeneration)
            if (faultAfterApprove) {
                assertEquals(1, affected)
                throw SQLException("Injected post-approve storage fault")
            }
            return affected
        }

        override fun revokePeerGuarded(
            nodeId: ByteArray,
            signingPub: ByteArray,
            acceptedStatic: ByteArray,
            acceptedGeneration: Long,
            currentTrustLevel: Int,
            oldPendingStatic: ByteArray?,
            oldPendingGeneration: Long?
        ): Int {
            val hook = hookRevoke
            val affected = if (hook != null) hook(nodeId, signingPub, acceptedStatic, acceptedGeneration, currentTrustLevel, oldPendingStatic, oldPendingGeneration)
            else delegate.revokePeerGuarded(nodeId, signingPub, acceptedStatic, acceptedGeneration, currentTrustLevel, oldPendingStatic, oldPendingGeneration)
            if (faultAfterRevoke) {
                assertEquals(1, affected)
                throw SQLException("Injected post-revoke storage fault")
            }
            return affected
        }

        override fun <T> inImmediateTransaction(block: (PeerIdentityStore) -> T): T {
            val hook = hookInTx
            return if (hook != null) {
                @Suppress("UNCHECKED_CAST")
                hook(block as (PeerIdentityStore) -> Any?) as T
            } else {
                delegate.inImmediateTransaction { tx ->
                    val txHook = HookableStore(tx).also {
                        it.hookReadRaw = this.hookReadRaw
                        it.hookInsertFirstSeen = this.hookInsertFirstSeen
                        it.hookSetInitialPending = this.hookSetInitialPending
                        it.hookAdvancePending = this.hookAdvancePending
                        it.hookApprovePending = this.hookApprovePending
                        it.hookRevoke = this.hookRevoke
                        it.faultAfterInsert = this.faultAfterInsert
                        it.faultAfterInitialPending = this.faultAfterInitialPending
                        it.faultAfterAdvancePending = this.faultAfterAdvancePending
                        it.faultAfterApprove = this.faultAfterApprove
                        it.faultAfterRevoke = this.faultAfterRevoke
                    }
                    block(txHook)
                }
            }
        }
    }

    @Test
    fun testFirstSeenReadbackCorruptionRollsBack() {
        val file = tempFolder.newFile("corrupt_readback_first_seen.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)
        val b = makeBinding(seedA, 0L, staticPrivA)

        var readCount = 0
        hookStore.hookReadRaw = { nodeId ->
            readCount += 1
            if (readCount == 1) {
                null
            } else {
                PeerIdentityRow(
                    nodeIdRaw = nodeId,
                    signingPublicKeyRaw = b.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw = b.staticDhPublicKey,
                    acceptedGenerationRaw = b.generation,
                    trustCodeRaw = 999, // Corrupt unknown trust level code
                    pendingStaticDhPublicKeyRaw = null,
                    pendingGenerationRaw = null
                )
            }
        }

        val res = repo.applyValidatedBinding(b)
        assertTrue(res is PeerTrustApplyResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode(999),
            (res as PeerTrustApplyResult.Corrupt).reason
        )

        rawStore.close()
        // Fresh independent durable readback: transaction rolled back, row absent
        JdbcPeerIdentityStore(file).use { freshStore ->
            assertNull(freshStore.readRaw(b.nodeId))
        }
    }

    @Test
    fun testInitialPendingReadbackCorruptionRollsBack() {
        val file = tempFolder.newFile("corrupt_readback_init_pending.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        assertEquals(PeerTrustApplyResult.FirstSeenPinned, repo.applyValidatedBinding(b1))

        val b2 = makeBinding(seedA, 5L, staticPrivB)
        var readCount = 0
        hookStore.hookReadRaw = { nodeId ->
            readCount += 1
            if (readCount == 1) {
                PeerIdentityRow(
                    nodeIdRaw = b1.nodeId,
                    signingPublicKeyRaw = b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw = b1.staticDhPublicKey,
                    acceptedGenerationRaw = b1.generation,
                    trustCodeRaw = PeerTrustLevel.TOFU_PINNED.persistedCode,
                    pendingStaticDhPublicKeyRaw = null,
                    pendingGenerationRaw = null
                )
            } else {
                // Post-mutation readback: corrupt out-of-range pending generation > UINT32_MAX
                PeerIdentityRow(
                    nodeIdRaw = b1.nodeId,
                    signingPublicKeyRaw = b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw = b1.staticDhPublicKey,
                    acceptedGenerationRaw = b1.generation,
                    trustCodeRaw = PeerTrustLevel.TOFU_PINNED.persistedCode,
                    pendingStaticDhPublicKeyRaw = b2.staticDhPublicKey,
                    pendingGenerationRaw = 5000000000L // Corrupt > UINT32_MAX!
                )
            }
        }

        val res = repo.applyValidatedBinding(b2)
        assertTrue(res is PeerTrustApplyResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.PendingGenerationOutOfRange(5000000000L),
            (res as PeerTrustApplyResult.Corrupt).reason
        )

        rawStore.close()
        // Fresh independent durable readback: transaction rolled back, row unchanged
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row.trustCodeRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testAdvancePendingReadbackCorruptionRollsBack() {
        val file = tempFolder.newFile("corrupt_readback_adv_pending.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b1)
        val b2 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b2)

        val b3 = makeBinding(seedA, 6L, staticPrivC)
        var readCount = 0
        hookStore.hookReadRaw = { nodeId ->
            readCount += 1
            if (readCount == 1) {
                PeerIdentityRow(
                    nodeIdRaw = b1.nodeId,
                    signingPublicKeyRaw = b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw = b1.staticDhPublicKey,
                    acceptedGenerationRaw = b1.generation,
                    trustCodeRaw = PeerTrustLevel.TOFU_PINNED.persistedCode,
                    pendingStaticDhPublicKeyRaw = b2.staticDhPublicKey,
                    pendingGenerationRaw = b2.generation
                )
            } else {
                // Post-mutation readback: structurally valid row, but mismatch with expected b3
                PeerIdentityRow(
                    nodeIdRaw = b1.nodeId,
                    signingPublicKeyRaw = b1.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw = b1.staticDhPublicKey,
                    acceptedGenerationRaw = b1.generation,
                    trustCodeRaw = PeerTrustLevel.TOFU_PINNED.persistedCode,
                    pendingStaticDhPublicKeyRaw = b2.staticDhPublicKey, // Valid, but does NOT match b3!
                    pendingGenerationRaw = 99L
                )
            }
        }

        val res = repo.applyValidatedBinding(b3)
        assertTrue(res is PeerTrustApplyResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("AdvancePending readback mismatch"),
            (res as PeerTrustApplyResult.Corrupt).reason
        )

        rawStore.close()
        // Fresh independent durable readback: transaction rolled back, pending 5/B preserved
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(5L, row.pendingGenerationRaw)
            assertArrayEquals(b2.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row.trustCodeRaw)
        }
    }

    // =========================================================================
    // 6. MUTATION CARDINALITY MATRIX (0 and 2 affected rows)
    // =========================================================================

    @Test
    fun testCardinalityMatrix_InitialPending_ZeroAffected_RollsBack() {
        val file = tempFolder.newFile("card_init_0.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b1)

        hookStore.hookSetInitialPending = { _, _, _, _, _, _, _ -> 0 }
        val b2 = makeBinding(seedA, 1L, staticPrivB)
        val res = repo.applyValidatedBinding(b2)
        assertTrue(res is PeerTrustApplyResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 0),
            (res as PeerTrustApplyResult.Corrupt).reason
        )

        rawStore.close()
        // Fresh independent durable readback
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testCardinalityMatrix_InitialPending_TwoAffected_RollsBack() {
        val file = tempFolder.newFile("card_init_2.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b1)

        hookStore.hookSetInitialPending = { _, _, _, _, _, _, _ -> 2 }
        val b2 = makeBinding(seedA, 1L, staticPrivB)
        val res = repo.applyValidatedBinding(b2)
        assertTrue(res is PeerTrustApplyResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 2),
            (res as PeerTrustApplyResult.Corrupt).reason
        )

        rawStore.close()
        // Fresh independent durable readback
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testCardinalityMatrix_AdvancePending_ZeroAffected_RollsBack() {
        val file = tempFolder.newFile("card_adv_0.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b1)
        val b2 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b2)

        hookStore.hookAdvancePending = { _, _, _, _, _, _, _, _, _ -> 0 }
        val b3 = makeBinding(seedA, 6L, staticPrivC)
        val res = repo.applyValidatedBinding(b3)
        assertTrue(res is PeerTrustApplyResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 0),
            (res as PeerTrustApplyResult.Corrupt).reason
        )

        rawStore.close()
        // Fresh independent durable readback
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(5L, row.pendingGenerationRaw)
            assertArrayEquals(b2.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testCardinalityMatrix_AdvancePending_TwoAffected_RollsBack() {
        val file = tempFolder.newFile("card_adv_2.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b1)
        val b2 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b2)

        hookStore.hookAdvancePending = { _, _, _, _, _, _, _, _, _ -> 2 }
        val b3 = makeBinding(seedA, 6L, staticPrivC)
        val res = repo.applyValidatedBinding(b3)
        assertTrue(res is PeerTrustApplyResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 2),
            (res as PeerTrustApplyResult.Corrupt).reason
        )

        rawStore.close()
        // Fresh independent durable readback
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(5L, row.pendingGenerationRaw)
            assertArrayEquals(b2.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    // =========================================================================
    // 7. STORAGE FAULT ROLLBACK TESTS (F1, F2, F3, Commit Failure)
    // =========================================================================

    @Test
    fun testStorageFaultF1_FirstSeenFailure_RollsBack() {
        val file = tempFolder.newFile("fault_f1.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        hookStore.faultAfterInsert = true

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        val res = repo.applyValidatedBinding(b1)
        assertTrue(res is PeerTrustApplyResult.StorageFailure)

        rawStore.close()
        // Fresh independent durable readback: row absent
        JdbcPeerIdentityStore(file).use { freshStore ->
            assertNull(freshStore.readRaw(b1.nodeId))
        }
    }

    @Test
    fun testStorageFaultF2_InitialPendingFailure_RollsBack() {
        val file = tempFolder.newFile("fault_f2.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b1)

        hookStore.faultAfterInitialPending = true

        val b2 = makeBinding(seedA, 5L, staticPrivB)
        val res = repo.applyValidatedBinding(b2)
        assertTrue(res is PeerTrustApplyResult.StorageFailure)

        rawStore.close()
        // Fresh independent durable readback: pending remains null
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testStorageFaultF3_AdvancePendingFailure_RollsBack() {
        val file = tempFolder.newFile("fault_f3.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b1)
        val b2 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b2)

        hookStore.faultAfterAdvancePending = true

        val b3 = makeBinding(seedA, 6L, staticPrivC)
        val res = repo.applyValidatedBinding(b3)
        assertTrue(res is PeerTrustApplyResult.StorageFailure)

        rawStore.close()
        // Fresh independent durable readback: pending remains 5/B (P6 does not survive)
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b1.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b1.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(5L, row.pendingGenerationRaw)
            assertArrayEquals(b2.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testSimulatedCommitFailureAfterSuccessfulBodyRollsBack() {
        val file = tempFolder.newFile("fault_commit.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        hookStore.hookInTx = { block ->
            rawStore.inImmediateTransaction { tx ->
                block(tx)
                // Simulated commit failure after transaction body success
                throw java.sql.SQLException("Simulated commit failure after transaction body success")
            }
        }

        val b1 = makeBinding(seedA, 0L, staticPrivA)
        val res = repo.applyValidatedBinding(b1)
        assertTrue(res is PeerTrustApplyResult.StorageFailure)

        rawStore.close()
        // Fresh independent durable readback: row absent
        JdbcPeerIdentityStore(file).use { freshStore ->
            assertNull(freshStore.readRaw(b1.nodeId))
        }
    }

    // =========================================================================
    // 8. CROSS-CONNECTION CONCURRENCY TESTS (C1, C2, C3, C4, Supplemental)
    // =========================================================================

    @Test
    fun testConcurrencyC1IdenticalFirstSeen() {
        val file = tempFolder.newFile("conc_c1.db").also { it.delete() }
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

        // Baseline: Gen 0 / Static A
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
        // Option 1: Gen 5 serializes first: { KeyChangedQuarantined, KeyChangedQuarantined }
        // Option 2: Gen 6 serializes first: { KeyChangedQuarantined, Rejected(StaleRelativeToPending) }
        val isOption1 = (r1 == PeerTrustApplyResult.KeyChangedQuarantined && r2 == PeerTrustApplyResult.KeyChangedQuarantined)
        val isOption2 = (r1 == PeerTrustApplyResult.Rejected(PeerTrustRejectReason.StaleRelativeToPending) && r2 == PeerTrustApplyResult.KeyChangedQuarantined) ||
                        (r1 == PeerTrustApplyResult.KeyChangedQuarantined && r2 == PeerTrustApplyResult.Rejected(PeerTrustRejectReason.StaleRelativeToPending))

        val legalResults = listOf(
            PeerTrustApplyResult.KeyChangedQuarantined,
            PeerTrustApplyResult.Rejected(PeerTrustRejectReason.StaleRelativeToPending)
        )
        assertTrue("r1 must be legal result: $r1", legalResults.contains(r1))
        assertTrue("r2 must be legal result: $r2", legalResults.contains(r2))
        assertTrue("Outcome must match legal taxonomy: r1=$r1, r2=$r2", isOption1 || isOption2)

        // Final state MUST be accepted 0 / static A, pendingGeneration == 6 / static C
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(6L, row.pendingGenerationRaw)
            assertArrayEquals(bGen6.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testConcurrencyC3ExactPendingReplayKeepsQuarantined() {
        val file = tempFolder.newFile("conc_c3_canonical.db").also { it.delete() }
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        // Setup on connection 1: accepted A (gen 0, static A), pending P (gen 5, static B)
        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo1.applyValidatedBinding(b0)
        val bGen5 = makeBinding(seedA, 5L, staticPrivB)
        repo1.applyValidatedBinding(bGen5)

        // Verify precondition
        val preRow = store1.readRaw(b0.nodeId)
        assertNotNull(preRow)
        assertEquals(0L, preRow!!.acceptedGenerationRaw)
        assertArrayEquals(b0.staticDhPublicKey, preRow.acceptedStaticDhPublicKeyRaw)
        assertEquals(5L, preRow.pendingGenerationRaw)
        assertArrayEquals(bGen5.staticDhPublicKey, preRow.pendingStaticDhPublicKeyRaw)

        val executor = Executors.newFixedThreadPool(2)
        val f1 = executor.submit(Callable { repo1.applyValidatedBinding(bGen5) })
        val f2 = executor.submit(Callable { repo2.applyValidatedBinding(bGen5) })

        val r1 = f1.get()
        val r2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, r1)
        assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, r2)

        // Final durable row must be exact: accepted unchanged, pending generation 5, pending static B, trust unchanged
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(5L, row.pendingGenerationRaw)
            assertArrayEquals(bGen5.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row.trustCodeRaw)
        }
    }

    @Test
    fun testConcurrencyC4OldAcceptedReplayKeepsQuarantined() {
        val file = tempFolder.newFile("conc_c4_canonical.db").also { it.delete() }
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        // Setup: accepted A (gen 0, static A), pending P (gen 5, static B)
        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo1.applyValidatedBinding(b0)
        val bGen5 = makeBinding(seedA, 5L, staticPrivB)
        repo1.applyValidatedBinding(bGen5)

        // Verify precondition
        val preRow = store1.readRaw(b0.nodeId)
        assertNotNull(preRow)
        assertEquals(0L, preRow!!.acceptedGenerationRaw)
        assertArrayEquals(b0.staticDhPublicKey, preRow.acceptedStaticDhPublicKeyRaw)
        assertEquals(5L, preRow.pendingGenerationRaw)
        assertArrayEquals(bGen5.staticDhPublicKey, preRow.pendingStaticDhPublicKeyRaw)

        val executor = Executors.newFixedThreadPool(2)
        val f1 = executor.submit(Callable { repo1.applyValidatedBinding(b0) })
        val f2 = executor.submit(Callable { repo2.applyValidatedBinding(b0) })

        val r1 = f1.get()
        val r2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, r1)
        assertEquals(PeerTrustApplyResult.KeyChangedQuarantined, r2)

        // Final durable row must be exact: pending candidate MUST NOT be cleared
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(5L, row.pendingGenerationRaw)
            assertArrayEquals(bGen5.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row.trustCodeRaw)
        }
    }

    @Test
    fun testConcurrencySupplementalAdvancePendingHighWater() {
        val file = tempFolder.newFile("conc_supp_adv.db").also { it.delete() }
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
    fun testConcurrencySupplementalIndependentNodes() {
        val file = tempFolder.newFile("conc_supp_indep.db").also { it.delete() }
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

    // =========================================================================
    // 10. APPROVAL SEMANTIC TESTS (Phase C8.2C)
    // =========================================================================

    @Test
    fun testApprovePending_ExactCandidateSuccess_PromotesToAcceptedAndClearsPending() {
        val file = tempFolder.newFile("appr_exact.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.Approved)
        val view = (res as RotationApprovalResult.Approved).identity
        assertEquals(5L, view.acceptedGeneration)
        assertArrayEquals(b5.staticDhPublicKey, view.acceptedStaticDhPublicKey)
        assertEquals(PeerTrustLevel.TOFU_PINNED, view.trustLevel)

        val lookup = repo.lookup(b0.nodeId)
        assertTrue(lookup is PeerIdentityLookup.Verified)
        val lookedUp = (lookup as PeerIdentityLookup.Verified).identity
        assertEquals(5L, lookedUp.acceptedGeneration)
        assertArrayEquals(b5.staticDhPublicKey, lookedUp.acceptedStaticDhPublicKey)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(5L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b5.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row.trustCodeRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testApprovePending_PreservesTofuPinnedTrustLevel() {
        val file = tempFolder.newFile("appr_tofu.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.Approved)
        val view = (res as RotationApprovalResult.Approved).identity
        assertEquals(PeerTrustLevel.TOFU_PINNED, view.trustLevel)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testApprovePending_PreservesUserVerifiedTrustLevel() {
        val file = tempFolder.newFile("appr_uv.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        // Test SQL seam: promote to USER_VERIFIED (code 2) before pending candidate
        rawStore.execRawSqlForTest("UPDATE peer_identities SET trust_level = 2")
        repo.applyValidatedBinding(b5)

        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.Approved)
        val view = (res as RotationApprovalResult.Approved).identity
        assertEquals(PeerTrustLevel.USER_VERIFIED, view.trustLevel)
        assertEquals(5L, view.acceptedGeneration)
        assertArrayEquals(b5.staticDhPublicKey, view.acceptedStaticDhPublicKey)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(5L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b5.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.USER_VERIFIED.persistedCode, row.trustCodeRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testApprovePending_StaleGeneration_ReturnsStaleCandidateAndDoesNotMutate() {
        val file = tempFolder.newFile("appr_stale_gen.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        val b6 = makeBinding(seedA, 6L, staticPrivC)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)
        repo.applyValidatedBinding(b6)

        // Try to approve stale P5
        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertEquals(RotationApprovalResult.StaleCandidate, res)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(6L, row.pendingGenerationRaw)
            assertArrayEquals(b6.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testApprovePending_SameGenerationWrongStatic_ReturnsStaleCandidateAndDoesNotMutate() {
        val file = tempFolder.newFile("appr_wrong_static.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        val wrongStatic = X25519Keys.publicKeyFromPrivate(staticPrivC)
        val res = repo.approvePendingRotation(b0.nodeId, 5L, wrongStatic)
        assertEquals(RotationApprovalResult.StaleCandidate, res)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(5L, row.pendingGenerationRaw)
            assertArrayEquals(b5.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testApprovePending_NoPendingCandidate_ReturnsNoPendingCandidateAndDoesNotMutate() {
        val file = tempFolder.newFile("appr_no_pending.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        val staticB = X25519Keys.publicKeyFromPrivate(staticPrivB)
        val res = repo.approvePendingRotation(b0.nodeId, 5L, staticB)
        assertEquals(RotationApprovalResult.NoPendingCandidate, res)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertNull(row.pendingGenerationRaw)
        }
    }

    @Test
    fun testApprovePending_PeerNotFound_ReturnsPeerNotFound() {
        val file = tempFolder.newFile("appr_not_found.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val unknownNode = ByteArray(16) { 0x99.toByte() }
        val staticB = X25519Keys.publicKeyFromPrivate(staticPrivB)
        val res = repo.approvePendingRotation(unknownNode, 5L, staticB)
        assertEquals(RotationApprovalResult.PeerNotFound, res)

        rawStore.close()
    }

    @Test
    fun testApprovePending_Revoked_ReturnsRejectedRevoked() {
        val file = tempFolder.newFile("appr_revoked.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)
        repo.revokePeer(b0.nodeId)

        val staticB = X25519Keys.publicKeyFromPrivate(staticPrivB)
        val res = repo.approvePendingRotation(b0.nodeId, 5L, staticB)
        assertEquals(RotationApprovalResult.RejectedRevoked, res)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.REVOKED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testApprovePending_InvalidArgument_NodeIdOrKeyOrGenerationInvalid() {
        val file = tempFolder.newFile("appr_invalid.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val validNode = ByteArray(16)
        val validKey = ByteArray(32)

        assertTrue(repo.approvePendingRotation(ByteArray(15), 5L, validKey) is RotationApprovalResult.InvalidArgument)
        assertTrue(repo.approvePendingRotation(validNode, 5L, ByteArray(31)) is RotationApprovalResult.InvalidArgument)
        assertTrue(repo.approvePendingRotation(validNode, -1L, validKey) is RotationApprovalResult.InvalidArgument)
        assertTrue(repo.approvePendingRotation(validNode, 4294967296L, validKey) is RotationApprovalResult.InvalidArgument)

        rawStore.close()
    }

    @Test
    fun testApprovePending_CardinalityZero_RollsBack() {
        val file = tempFolder.newFile("appr_card0.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        hookStore.hookApprovePending = { _, _, _, _, _, _, _ -> 0 }
        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 0),
            (res as RotationApprovalResult.Corrupt).reason
        )

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(5L, row.pendingGenerationRaw)
        }
    }

    @Test
    fun testApprovePending_CardinalityTwo_RollsBack() {
        val file = tempFolder.newFile("appr_card2.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        hookStore.hookApprovePending = { _, _, _, _, _, _, _ -> 2 }
        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 2),
            (res as RotationApprovalResult.Corrupt).reason
        )

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(5L, row.pendingGenerationRaw)
        }
    }

    @Test
    fun testApprovePending_PostWriteCorruptReadback_RollsBack() {
        val file = tempFolder.newFile("appr_readback_corrupt.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        var readCount = 0
        hookStore.hookReadRaw = { nodeId ->
            readCount += 1
            if (readCount == 1) {
                rawStore.readRaw(nodeId)
            } else {
                PeerIdentityRow(
                    nodeIdRaw = nodeId,
                    signingPublicKeyRaw = b0.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw = b5.staticDhPublicKey,
                    acceptedGenerationRaw = 5L,
                    trustCodeRaw = 999, // Corrupt code
                    pendingStaticDhPublicKeyRaw = null,
                    pendingGenerationRaw = null
                )
            }
        }

        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode(999),
            (res as RotationApprovalResult.Corrupt).reason
        )

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(5L, row.pendingGenerationRaw)
        }
    }

    @Test
    fun testApprovePending_StorageFaultAfterUpdate_RollsBack() {
        val file = tempFolder.newFile("appr_fault.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        hookStore.faultAfterApprove = true

        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.StorageFailure)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(5L, row.pendingGenerationRaw)
        }
    }

    @Test
    fun testApprovePending_SimulatedCommitFailure_RollsBack() {
        val file = tempFolder.newFile("appr_commit_fail.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        hookStore.hookInTx = { block ->
            rawStore.inImmediateTransaction { tx ->
                block(tx)
                throw SQLException("Simulated commit failure after successful approval body")
            }
        }

        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertTrue(res is RotationApprovalResult.StorageFailure)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertEquals(5L, row.pendingGenerationRaw)
        }
    }

    @Test
    fun testApprovePending_Vs_NewerPending_CrossConnectionRace() {
        val file = tempFolder.newFile("appr_race.db").also { it.delete() }
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo1.applyValidatedBinding(b0)
        repo1.applyValidatedBinding(b5)

        val b6 = makeBinding(seedA, 6L, staticPrivC)

        val executor = Executors.newFixedThreadPool(2)
        val f1 = executor.submit(Callable { repo1.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey) })
        val f2 = executor.submit(Callable { repo2.applyValidatedBinding(b6) })

        val r1 = f1.get()
        val r2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        val isOptionA = (r1 is RotationApprovalResult.Approved && r2 == PeerTrustApplyResult.KeyChangedQuarantined)
        val isOptionB = (r1 == RotationApprovalResult.StaleCandidate && r2 == PeerTrustApplyResult.KeyChangedQuarantined)

        assertTrue("Outcome must match legal serialization Option A or B: r1=$r1, r2=$r2", isOptionA || isOptionB)

        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            if (isOptionA) {
                assertEquals(5L, row!!.acceptedGenerationRaw)
                assertArrayEquals(b5.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
                assertEquals(6L, row.pendingGenerationRaw)
                assertArrayEquals(b6.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
            } else {
                assertEquals(0L, row!!.acceptedGenerationRaw)
                assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
                assertEquals(6L, row.pendingGenerationRaw)
                assertArrayEquals(b6.staticDhPublicKey, row.pendingStaticDhPublicKeyRaw)
            }
        }
    }

    // =========================================================================
    // 11. REVOCATION SEMANTIC TESTS (Phase C8.2C)
    // =========================================================================

    @Test
    fun testRevokePeer_ActiveNoPending_RevokesAndPreservesAcceptedAudit() {
        val file = tempFolder.newFile("rev_nopending.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        val res = repo.revokePeer(b0.nodeId)
        assertEquals(RevokeResult.Revoked, res)

        val lookup = repo.lookup(b0.nodeId)
        assertEquals(PeerIdentityLookup.Revoked, lookup)

        val reapply = repo.applyValidatedBinding(b0)
        assertEquals(PeerTrustApplyResult.Rejected(PeerTrustRejectReason.Revoked), reapply)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.REVOKED.persistedCode, row.trustCodeRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testRevokePeer_ActiveWithPending_RevokesAndClearsPending() {
        val file = tempFolder.newFile("rev_withpending.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        val res = repo.revokePeer(b0.nodeId)
        assertEquals(RevokeResult.Revoked, res)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.REVOKED.persistedCode, row.trustCodeRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testRevokePeer_AlreadyRevoked_ReturnsAlreadyRevokedWithoutMutation() {
        val file = tempFolder.newFile("rev_already.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)
        assertEquals(RevokeResult.Revoked, repo.revokePeer(b0.nodeId))
        assertEquals(RevokeResult.AlreadyRevoked, repo.revokePeer(b0.nodeId))

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.REVOKED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testRevokePeer_PeerNotFound_ReturnsPeerNotFound() {
        val file = tempFolder.newFile("rev_not_found.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val unknownNode = ByteArray(16) { 0x88.toByte() }
        assertEquals(RevokeResult.PeerNotFound, repo.revokePeer(unknownNode))

        rawStore.close()
    }

    @Test
    fun testRevokePeer_InvalidArgument_InvalidNodeId() {
        val file = tempFolder.newFile("rev_invalid.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        assertTrue(repo.revokePeer(ByteArray(15)) is RevokeResult.InvalidArgument)
        assertTrue(repo.revokePeer(ByteArray(17)) is RevokeResult.InvalidArgument)

        rawStore.close()
    }

    @Test
    fun testRevokePeer_CorruptDurableRow_RollsBack() {
        val file = tempFolder.newFile("rev_corrupt.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        hookStore.hookReadRaw = { nodeId ->
            PeerIdentityRow(
                nodeIdRaw = nodeId,
                signingPublicKeyRaw = b0.signingPublicKey,
                acceptedStaticDhPublicKeyRaw = b0.staticDhPublicKey,
                acceptedGenerationRaw = 0L,
                trustCodeRaw = 999, // Corrupt code
                pendingStaticDhPublicKeyRaw = null,
                pendingGenerationRaw = null
            )
        }

        val res = repo.revokePeer(b0.nodeId)
        assertTrue(res is RevokeResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode(999),
            (res as RevokeResult.Corrupt).reason
        )

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testRevokePeer_CardinalityZero_RollsBack() {
        val file = tempFolder.newFile("rev_card0.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        hookStore.hookRevoke = { _, _, _, _, _, _, _ -> 0 }
        val res = repo.revokePeer(b0.nodeId)
        assertTrue(res is RevokeResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 0),
            (res as RevokeResult.Corrupt).reason
        )

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testRevokePeer_CardinalityTwo_RollsBack() {
        val file = tempFolder.newFile("rev_card2.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        hookStore.hookRevoke = { _, _, _, _, _, _, _ -> 2 }
        val res = repo.revokePeer(b0.nodeId)
        assertTrue(res is RevokeResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.MutationCardinality(1, 2),
            (res as RevokeResult.Corrupt).reason
        )

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testRevokePeer_StorageFaultAfterUpdate_RollsBack() {
        val file = tempFolder.newFile("rev_fault.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        hookStore.faultAfterRevoke = true

        val res = repo.revokePeer(b0.nodeId)
        assertTrue(res is RevokeResult.StorageFailure)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testRevokePeer_PostWriteCorruptReadback_RollsBack() {
        val file = tempFolder.newFile("rev_readback_corrupt.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        var readCount = 0
        hookStore.hookReadRaw = { nodeId ->
            readCount += 1
            if (readCount == 1) {
                rawStore.readRaw(nodeId)
            } else {
                PeerIdentityRow(
                    nodeIdRaw = nodeId,
                    signingPublicKeyRaw = b0.signingPublicKey,
                    acceptedStaticDhPublicKeyRaw = b0.staticDhPublicKey,
                    acceptedGenerationRaw = 0L,
                    trustCodeRaw = 999, // Corrupt code
                    pendingStaticDhPublicKeyRaw = null,
                    pendingGenerationRaw = null
                )
            }
        }

        val res = repo.revokePeer(b0.nodeId)
        assertTrue(res is RevokeResult.Corrupt)
        assertEquals(
            PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode(999),
            (res as RevokeResult.Corrupt).reason
        )

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testRevokePeer_SimulatedCommitFailure_RollsBack() {
        val file = tempFolder.newFile("rev_commit_fail.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val hookStore = HookableStore(rawStore)
        val repo = PeerIdentityRepository(hookStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(b0)

        hookStore.hookInTx = { block ->
            rawStore.inImmediateTransaction { tx ->
                block(tx)
                throw SQLException("Simulated commit failure after successful revoke body")
            }
        }

        val res = repo.revokePeer(b0.nodeId)
        assertTrue(res is RevokeResult.StorageFailure)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row!!.trustCodeRaw)
        }
    }

    @Test
    fun testRevokePeer_Vs_InboundApply_CrossConnectionRace() {
        val file = tempFolder.newFile("rev_race.db").also { it.delete() }
        val store1 = JdbcPeerIdentityStore(file)
        val store2 = JdbcPeerIdentityStore(file)

        val repo1 = PeerIdentityRepository(store1)
        val repo2 = PeerIdentityRepository(store2)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo1.applyValidatedBinding(b0)
        repo1.applyValidatedBinding(b5)

        val b6 = makeBinding(seedA, 6L, staticPrivC)

        val executor = Executors.newFixedThreadPool(2)
        val f1 = executor.submit(Callable { repo1.revokePeer(b0.nodeId) })
        val f2 = executor.submit(Callable { repo2.applyValidatedBinding(b6) })

        val r1 = f1.get()
        val r2 = f2.get()

        executor.shutdown()
        store1.close()
        store2.close()

        val isOptionA = (r1 == RevokeResult.Revoked && r2 == PeerTrustApplyResult.Rejected(PeerTrustRejectReason.Revoked))
        val isOptionB = (r1 == RevokeResult.Revoked && r2 == PeerTrustApplyResult.KeyChangedQuarantined)

        assertTrue("Outcome must match legal serialization Option A or B: r1=$r1, r2=$r2", isOptionA || isOptionB)

        // FINAL STATE IN BOTH: trust REVOKED, accepted 0/A, pending NULL
        JdbcPeerIdentityStore(file).use { store ->
            val row = store.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(0L, row!!.acceptedGenerationRaw)
            assertArrayEquals(b0.staticDhPublicKey, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(PeerTrustLevel.REVOKED.persistedCode, row.trustCodeRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }

    @Test
    fun testRevokePeer_ThenApprovePending_ReturnsRejectedRevoked() {
        val file = tempFolder.newFile("rev_then_appr.db").also { it.delete() }
        val rawStore = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(rawStore)

        val b0 = makeBinding(seedA, 0L, staticPrivA)
        val b5 = makeBinding(seedA, 5L, staticPrivB)
        repo.applyValidatedBinding(b0)
        repo.applyValidatedBinding(b5)

        assertEquals(RevokeResult.Revoked, repo.revokePeer(b0.nodeId))

        val res = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
        assertEquals(RotationApprovalResult.RejectedRevoked, res)

        rawStore.close()
        JdbcPeerIdentityStore(file).use { freshStore ->
            val row = freshStore.readRaw(b0.nodeId)
            assertNotNull(row)
            assertEquals(PeerTrustLevel.REVOKED.persistedCode, row!!.trustCodeRaw)
            assertNull(row.pendingGenerationRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
        }
    }
}
