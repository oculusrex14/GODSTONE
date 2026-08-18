package io.godstone.mesh.identity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PeerTrustEngineTest {

    private val testSeedA = ByteArray(32) { 0x11 }
    private val testSeedB = ByteArray(32) { 0x33 }

    private val staticPrivA = ByteArray(32) { 0x22 }
    private val staticPrivB = ByteArray(32) { 0x44 }
    private val staticPrivC = ByteArray(32) { 0x66 }

    private fun makeValidatedBinding(
        seed: ByteArray,
        generation: Long,
        staticDhPriv: ByteArray = staticPrivA
    ): ValidatedPeerBinding {
        val edKeys = Ed25519Keys.fromSeed(seed)
        val dhKeys = X25519Keys.fromPrivateKey(staticDhPriv)
        val preimage = IdentityBindingV1.signaturePreimage(
            generation = generation,
            signingPublicKey = edKeys.pub,
            staticDhPublicKey = dhKeys.pub
        )
        val sig = Ed25519Keys.sign(preimage, edKeys.priv)
        val binding = IdentityBindingV1.create(
            generation = generation,
            signingPublicKey = edKeys.pub,
            staticDhPublicKey = dhKeys.pub,
            signature = sig
        )
        val res = IdentityBindingValidator.validate(
            serialized = binding.encode(),
            authenticatedRemoteStaticKey = dhKeys.pub,
            advertisedNodeHint = IdentityBindingV1.deriveNodeHint(IdentityBindingV1.deriveNodeId(edKeys.pub))
        )
        require(res is IdentityBindingValidationResult.Valid) { "Validation failed" }
        return res.binding
    }

    private fun makeRecord(
        seed: ByteArray = testSeedA,
        acceptedGeneration: Long = 0L,
        trustLevel: PeerTrustLevel = PeerTrustLevel.TOFU_PINNED,
        acceptedStaticPriv: ByteArray = staticPrivA,
        pendingGeneration: Long? = null,
        pendingStaticPriv: ByteArray? = null
    ): PeerIdentityRecord {
        val edKeys = Ed25519Keys.fromSeed(seed)
        val accDh = X25519Keys.fromPrivateKey(acceptedStaticPriv)
        val pendDh = pendingStaticPriv?.let { X25519Keys.fromPrivateKey(it) }
        return PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(edKeys.pub),
            signingPublicKey = edKeys.pub,
            acceptedStaticDhPublicKey = accDh.pub,
            acceptedGeneration = acceptedGeneration,
            trustLevel = trustLevel,
            pendingStaticDhPublicKey = pendDh?.pub,
            pendingGeneration = pendingGeneration
        )
    }

    // =========================================================================
    // 1. CROSS-PLATFORM SEMANTIC TEST MATRIX (T01 - T25)
    // =========================================================================

    // T01: unseen generation 0 -> InsertFirstSeen
    @Test
    fun testT01UnseenGeneration0() {
        val binding = makeValidatedBinding(testSeedA, 0L)
        val plan = PeerTrustEngine.evaluate(binding, null)
        assertEquals(TrustPlan.InsertFirstSeen, plan)
    }

    // T02: unseen generation 7 -> InsertFirstSeen
    @Test
    fun testT02UnseenGeneration7() {
        val binding = makeValidatedBinding(testSeedA, 7L)
        val plan = PeerTrustEngine.evaluate(binding, null)
        assertEquals(TrustPlan.InsertFirstSeen, plan)
    }

    // T03: unseen UINT32_MAX -> InsertFirstSeen
    @Test
    fun testT03UnseenUint32Max() {
        val binding = makeValidatedBinding(testSeedA, 0xFFFFFFFFL)
        val plan = PeerTrustEngine.evaluate(binding, null)
        assertEquals(TrustPlan.InsertFirstSeen, plan)
    }

    // T04: exact accepted TOFU reconnect -> AcceptExisting
    @Test
    fun testT04ExactAcceptedTofuReconnect() {
        val record = makeRecord(testSeedA, acceptedGeneration = 0L, trustLevel = PeerTrustLevel.TOFU_PINNED)
        val binding = makeValidatedBinding(testSeedA, 0L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.AcceptExisting, plan)
    }

    // T05: exact accepted USER_VERIFIED reconnect -> AcceptExisting
    @Test
    fun testT05ExactAcceptedUserVerifiedReconnect() {
        val record = makeRecord(testSeedA, acceptedGeneration = 5L, trustLevel = PeerTrustLevel.USER_VERIFIED)
        val binding = makeValidatedBinding(testSeedA, 5L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.AcceptExisting, plan)
    }

    // T06: accepted lower generation -> Reject Rollback
    @Test
    fun testT06AcceptedLowerGeneration() {
        val record = makeRecord(testSeedA, acceptedGeneration = 5L)
        val binding = makeValidatedBinding(testSeedA, 4L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.Rollback), plan)
    }

    // T07: same accepted generation / different static -> Reject SameGenerationConflict
    @Test
    fun testT07SameAcceptedGenerationDifferentStatic() {
        val record = makeRecord(testSeedA, acceptedGeneration = 5L, acceptedStaticPriv = staticPrivA)
        val binding = makeValidatedBinding(testSeedA, 5L, staticPrivB)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.SameGenerationConflict), plan)
    }

    // T08: higher generation / accepted static -> Reject NoncanonicalGenerationAdvance
    @Test
    fun testT08HigherGenerationAcceptedStatic() {
        val record = makeRecord(testSeedA, acceptedGeneration = 5L, acceptedStaticPriv = staticPrivA)
        val binding = makeValidatedBinding(testSeedA, 6L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.NoncanonicalGenerationAdvance), plan)
    }

    // T09: higher generation / distinct static -> SetInitialPendingCandidate
    @Test
    fun testT09HigherGenerationDistinctStatic() {
        val record = makeRecord(testSeedA, acceptedGeneration = 5L, acceptedStaticPriv = staticPrivA)
        val binding = makeValidatedBinding(testSeedA, 6L, staticPrivB)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.SetInitialPendingCandidate, plan)
    }

    // T10: pending exact candidate -> KeepQuarantined
    @Test
    fun testT10PendingExactCandidate() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 10L, staticPrivB)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.KeepQuarantined, plan)
    }

    // T11: pending + old accepted exact reconnect -> KeepQuarantined
    @Test
    fun testT11PendingOldAcceptedExactReconnect() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 5L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.KeepQuarantined, plan)
    }

    // T12: pending + gen lower than accepted -> Reject Rollback
    @Test
    fun testT12PendingGenLowerThanAccepted() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 4L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.Rollback), plan)
    }

    // T13: pending + accepted generation / different static -> Reject SameGenerationConflict
    @Test
    fun testT13PendingAcceptedGenerationDifferentStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 5L, staticPrivC)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.SameGenerationConflict), plan)
    }

    // T14: pending + intermediate generation / novel static -> Reject StaleRelativeToPending
    @Test
    fun testT14PendingIntermediateGenerationNovelStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 7L, staticPrivC)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.StaleRelativeToPending), plan)
    }

    // T15: pending + intermediate generation / accepted static -> Reject StaleRelativeToPending
    @Test
    fun testT15PendingIntermediateGenerationAcceptedStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 7L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.StaleRelativeToPending), plan)
    }

    // T16: pending + intermediate generation / pending static -> Reject StaleRelativeToPending
    @Test
    fun testT16PendingIntermediateGenerationPendingStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 7L, staticPrivB)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.StaleRelativeToPending), plan)
    }

    // T17: pending generation / exact pending static -> KeepQuarantined
    @Test
    fun testT17PendingGenerationExactPendingStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 10L, staticPrivB)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.KeepQuarantined, plan)
    }

    // T18: pending generation / different static -> Reject PendingGenerationConflict
    @Test
    fun testT18PendingGenerationDifferentStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 10L, staticPrivC)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.PendingGenerationConflict), plan)
    }

    // T19: pending generation / accepted static -> Reject PendingGenerationConflict
    @Test
    fun testT19PendingGenerationAcceptedStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 10L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.PendingGenerationConflict), plan)
    }

    // T20: newer-than-pending / novel static -> AdvancePendingCandidate
    @Test
    fun testT20NewerThanPendingNovelStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 11L, staticPrivC)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.AdvancePendingCandidate, plan)
    }

    // T21: newer-than-pending / accepted static -> Reject NoncanonicalGenerationAdvance
    @Test
    fun testT21NewerThanPendingAcceptedStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 11L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.NoncanonicalGenerationAdvance), plan)
    }

    // T22: newer-than-pending / pending static -> Reject NoncanonicalGenerationAdvance
    @Test
    fun testT22NewerThanPendingPendingStatic() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        val binding = makeValidatedBinding(testSeedA, 11L, staticPrivB)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.NoncanonicalGenerationAdvance), plan)
    }

    // T23: revoked exact reconnect -> Reject Revoked
    @Test
    fun testT23RevokedExactReconnect() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.REVOKED,
            acceptedStaticPriv = staticPrivA
        )
        val binding = makeValidatedBinding(testSeedA, 5L, staticPrivA)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.Revoked), plan)
    }

    // T24: revoked higher generation -> Reject Revoked
    @Test
    fun testT24RevokedHigherGeneration() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.REVOKED,
            acceptedStaticPriv = staticPrivA
        )
        val binding = makeValidatedBinding(testSeedA, 20L, staticPrivC)
        val plan = PeerTrustEngine.evaluate(binding, record)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.Revoked), plan)
    }

    // T25: active node-id/signing-key collision -> Reject NodeIdSigningKeyCollision
    @Test
    fun testT25ActiveNodeIdSigningKeyCollision() {
        // Synthetic branch test: node ID matched during DB lookup, but signing key differs
        val binding = makeValidatedBinding(testSeedA, 0L)
        val otherSeed = testSeedB
        val otherEd = Ed25519Keys.fromSeed(otherSeed)
        val collisionRecord = PeerIdentityRecord(
            nodeId = binding.nodeId, // lookup identity matched
            signingPublicKey = otherEd.pub, // different stored key!
            acceptedStaticDhPublicKey = binding.staticDhPublicKey,
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED
        )
        val plan = PeerTrustEngine.evaluate(binding, collisionRecord)
        assertEquals(TrustPlan.Reject(PeerTrustRejectReason.NodeIdSigningKeyCollision), plan)
    }

    // =========================================================================
    // 2. RECORD VALIDATION TESTS (V01 - V18)
    // =========================================================================

    // V01: valid TOFU active record
    @Test
    fun testV01ValidTofuActiveRecord() {
        val record = makeRecord(testSeedA, acceptedGeneration = 0L, trustLevel = PeerTrustLevel.TOFU_PINNED)
        assertEquals(PeerIdentityRecordValidationResult.Valid, PeerIdentityRecordValidator.validate(record))
    }

    // V02: valid USER_VERIFIED active record
    @Test
    fun testV02ValidUserVerifiedActiveRecord() {
        val record = makeRecord(testSeedA, acceptedGeneration = 5L, trustLevel = PeerTrustLevel.USER_VERIFIED)
        assertEquals(PeerIdentityRecordValidationResult.Valid, PeerIdentityRecordValidator.validate(record))
    }

    // V03: valid pending record
    @Test
    fun testV03ValidPendingRecord() {
        val record = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            acceptedStaticPriv = staticPrivA,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        assertEquals(PeerIdentityRecordValidationResult.Valid, PeerIdentityRecordValidator.validate(record))
    }

    // V04: valid revoked record
    @Test
    fun testV04ValidRevokedRecord() {
        val record = makeRecord(testSeedA, acceptedGeneration = 5L, trustLevel = PeerTrustLevel.REVOKED)
        assertEquals(PeerIdentityRecordValidationResult.Valid, PeerIdentityRecordValidator.validate(record))
    }

    // V05: nodeId length != 16 -> Corrupt
    @Test
    fun testV05NodeIdLengthInvalid() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dh = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = ByteArray(15),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dh.pub,
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidNodeIdLength),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V06: signing key length != 32 -> Corrupt
    @Test
    fun testV06SigningKeyLengthInvalid() {
        val dh = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = ByteArray(16),
            signingPublicKey = ByteArray(31),
            acceptedStaticDhPublicKey = dh.pub,
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidSigningKeyLength),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V07: accepted static length != 32 -> Corrupt
    @Test
    fun testV07AcceptedStaticLengthInvalid() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = ByteArray(33),
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidAcceptedStaticKeyLength),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V08: nodeId != hash(signing key) -> Corrupt
    @Test
    fun testV08NodeIdSigningKeyMismatch() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dh = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = ByteArray(16) { 0xFF.toByte() }, // mismatched
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dh.pub,
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.NodeIdSigningKeyMismatch),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V09: pending generation only -> Corrupt
    @Test
    fun testV09PendingGenerationOnly() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dh = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dh.pub,
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingStaticDhPublicKey = null,
            pendingGeneration = 5L
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingCouplingViolation),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V10: pending static only -> Corrupt
    @Test
    fun testV10PendingStaticOnly() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dhA = X25519Keys.fromPrivateKey(staticPrivA)
        val dhB = X25519Keys.fromPrivateKey(staticPrivB)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dhA.pub,
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingStaticDhPublicKey = dhB.pub,
            pendingGeneration = null
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingCouplingViolation),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V11: pending static wrong length -> Corrupt
    @Test
    fun testV11PendingStaticWrongLength() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dhA = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dhA.pub,
            acceptedGeneration = 0L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingStaticDhPublicKey = ByteArray(16),
            pendingGeneration = 5L
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidPendingStaticKeyLength),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V12: pendingGeneration == acceptedGeneration -> Corrupt
    @Test
    fun testV12PendingGenerationEqualsAccepted() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dhA = X25519Keys.fromPrivateKey(staticPrivA)
        val dhB = X25519Keys.fromPrivateKey(staticPrivB)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dhA.pub,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingStaticDhPublicKey = dhB.pub,
            pendingGeneration = 5L
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingNotNewer),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V13: pendingGeneration < acceptedGeneration -> Corrupt
    @Test
    fun testV13PendingGenerationLessThanAccepted() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dhA = X25519Keys.fromPrivateKey(staticPrivA)
        val dhB = X25519Keys.fromPrivateKey(staticPrivB)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dhA.pub,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingStaticDhPublicKey = dhB.pub,
            pendingGeneration = 4L
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingNotNewer),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V14: pending static == accepted static -> Corrupt
    @Test
    fun testV14PendingStaticEqualsAccepted() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dhA = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dhA.pub,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingStaticDhPublicKey = dhA.pub, // identical!
            pendingGeneration = 10L
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingStaticEqualsAccepted),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V15: REVOKED + pending -> Corrupt
    @Test
    fun testV15RevokedWithPending() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dhA = X25519Keys.fromPrivateKey(staticPrivA)
        val dhB = X25519Keys.fromPrivateKey(staticPrivB)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dhA.pub,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.REVOKED,
            pendingStaticDhPublicKey = dhB.pub,
            pendingGeneration = 10L
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.RevokedWithPending),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V16: accepted generation < 0 -> Corrupt
    @Test
    fun testV16AcceptedGenerationNegative() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dh = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dh.pub,
            acceptedGeneration = -1L,
            trustLevel = PeerTrustLevel.TOFU_PINNED
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.AcceptedGenerationOutOfRange),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V17: accepted generation > UINT32_MAX -> Corrupt
    @Test
    fun testV17AcceptedGenerationOutOfRange() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dh = X25519Keys.fromPrivateKey(staticPrivA)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dh.pub,
            acceptedGeneration = 0x100000000L,
            trustLevel = PeerTrustLevel.TOFU_PINNED
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.AcceptedGenerationOutOfRange),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // V18: pending generation > UINT32_MAX -> Corrupt
    @Test
    fun testV18PendingGenerationOutOfRange() {
        val ed = Ed25519Keys.fromSeed(testSeedA)
        val dhA = X25519Keys.fromPrivateKey(staticPrivA)
        val dhB = X25519Keys.fromPrivateKey(staticPrivB)
        val record = PeerIdentityRecord(
            nodeId = IdentityBindingV1.deriveNodeId(ed.pub),
            signingPublicKey = ed.pub,
            acceptedStaticDhPublicKey = dhA.pub,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingStaticDhPublicKey = dhB.pub,
            pendingGeneration = 0x100000000L
        )
        assertEquals(
            PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingGenerationOutOfRange),
            PeerIdentityRecordValidator.validate(record)
        )
    }

    // =========================================================================
    // 3. EFFECTIVE STATE TESTS (Section 23)
    // =========================================================================

    @Test
    fun testEffectiveStatePrecedence() {
        // TOFU, no pending -> ACTIVE_TOFU
        val r1 = makeRecord(testSeedA, acceptedGeneration = 0L, trustLevel = PeerTrustLevel.TOFU_PINNED)
        assertEquals(EffectivePeerTrustState.ACTIVE_TOFU, r1.effectiveState)

        // USER_VERIFIED, no pending -> ACTIVE_USER_VERIFIED
        val r2 = makeRecord(testSeedA, acceptedGeneration = 5L, trustLevel = PeerTrustLevel.USER_VERIFIED)
        assertEquals(EffectivePeerTrustState.ACTIVE_USER_VERIFIED, r2.effectiveState)

        // TOFU + pending -> KEY_CHANGED_QUARANTINED
        val r3 = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.TOFU_PINNED,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        assertEquals(EffectivePeerTrustState.KEY_CHANGED_QUARANTINED, r3.effectiveState)

        // USER_VERIFIED + pending -> KEY_CHANGED_QUARANTINED
        val r4 = makeRecord(
            testSeedA,
            acceptedGeneration = 5L,
            trustLevel = PeerTrustLevel.USER_VERIFIED,
            pendingGeneration = 10L,
            pendingStaticPriv = staticPrivB
        )
        assertEquals(EffectivePeerTrustState.KEY_CHANGED_QUARANTINED, r4.effectiveState)

        // REVOKED, no pending -> REVOKED
        val r5 = makeRecord(testSeedA, acceptedGeneration = 5L, trustLevel = PeerTrustLevel.REVOKED)
        assertEquals(EffectivePeerTrustState.REVOKED, r5.effectiveState)
    }

    // =========================================================================
    // 4. READ-ONLY VIEW TYPES TESTS (Section 19)
    // =========================================================================

    @Test
    fun testVerifiedPeerIdentityView() {
        val validRecord = makeRecord(testSeedA, acceptedGeneration = 0L, trustLevel = PeerTrustLevel.TOFU_PINNED)
        val verified = VerifiedPeerIdentity.fromRecord(validRecord)
        assertNotNull(verified)
        assertEquals(0L, verified!!.acceptedGeneration)
        assertEquals(PeerTrustLevel.TOFU_PINNED, verified.trustLevel)

        // Cannot view verified identity from quarantined or revoked record
        val pendingRecord = makeRecord(
            testSeedA,
            acceptedGeneration = 0L,
            pendingGeneration = 5L,
            pendingStaticPriv = staticPrivB
        )
        assertNull(VerifiedPeerIdentity.fromRecord(pendingRecord))

        val revokedRecord = makeRecord(testSeedA, acceptedGeneration = 0L, trustLevel = PeerTrustLevel.REVOKED)
        assertNull(VerifiedPeerIdentity.fromRecord(revokedRecord))
    }

    @Test
    fun testPendingPeerIdentityView() {
        val pendingRecord = makeRecord(
            testSeedA,
            acceptedGeneration = 0L,
            pendingGeneration = 5L,
            pendingStaticPriv = staticPrivB
        )
        val pending = PendingPeerIdentity.fromRecord(pendingRecord)
        assertNotNull(pending)
        assertEquals(0L, pending!!.acceptedGeneration)
        assertEquals(5L, pending.pendingGeneration)

        // Cannot view pending identity from unquarantined active record
        val activeRecord = makeRecord(testSeedA, acceptedGeneration = 0L)
        assertNull(PendingPeerIdentity.fromRecord(activeRecord))
    }

    @Test
    fun testTrustLevelPersistedCodes() {
        assertEquals(1, PeerTrustLevel.TOFU_PINNED.persistedCode)
        assertEquals(2, PeerTrustLevel.USER_VERIFIED.persistedCode)
        assertEquals(3, PeerTrustLevel.REVOKED.persistedCode)

        assertEquals(PeerTrustLevel.TOFU_PINNED, PeerTrustLevel.fromPersistedCode(1))
        assertEquals(PeerTrustLevel.USER_VERIFIED, PeerTrustLevel.fromPersistedCode(2))
        assertEquals(PeerTrustLevel.REVOKED, PeerTrustLevel.fromPersistedCode(3))
        assertNull(PeerTrustLevel.fromPersistedCode(0))
        assertNull(PeerTrustLevel.fromPersistedCode(4))
    }
}
