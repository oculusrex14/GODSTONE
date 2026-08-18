package io.godstone.mesh.identity

/**
 * Peer trust level with explicit persistence codes (ADR-003, Phase C8.2A).
 *
 * Explicit integer codes are used instead of enum ordinals to prevent database
 * reinterpretation across schema evolutions:
 * - TOFU_PINNED = 1
 * - USER_VERIFIED = 2
 * - REVOKED = 3
 */
enum class PeerTrustLevel(val persistedCode: Int) {
    TOFU_PINNED(1),
    USER_VERIFIED(2),
    REVOKED(3);

    companion object {
        fun fromPersistedCode(code: Int): PeerTrustLevel? = when (code) {
            1 -> TOFU_PINNED
            2 -> USER_VERIFIED
            3 -> REVOKED
            else -> null
        }
    }
}

/**
 * Effective trust state computed from [PeerIdentityRecord] (ADR-003, Phase C8.2A).
 *
 * Precedence rule:
 * 1. REVOKED -> REVOKED
 * 2. pendingGeneration != null -> KEY_CHANGED_QUARANTINED
 * 3. USER_VERIFIED -> ACTIVE_USER_VERIFIED
 * 4. TOFU_PINNED -> ACTIVE_TOFU
 */
internal enum class EffectivePeerTrustState {
    ACTIVE_TOFU,
    ACTIVE_USER_VERIFIED,
    KEY_CHANGED_QUARANTINED,
    REVOKED
}

/**
 * Authoritative cryptographic peer identity record (ADR-003, Phase C8.2A).
 *
 * Module-internal storage and repository model only. Contains only cryptographic
 * trust authority fields.
 */
internal class PeerIdentityRecord(
    nodeId: ByteArray,
    signingPublicKey: ByteArray,
    acceptedStaticDhPublicKey: ByteArray,
    val acceptedGeneration: Long,
    val trustLevel: PeerTrustLevel,
    pendingStaticDhPublicKey: ByteArray? = null,
    val pendingGeneration: Long? = null,
) {
    private val _nodeId: ByteArray = nodeId.copyOf()
    private val _signingPublicKey: ByteArray = signingPublicKey.copyOf()
    private val _acceptedStaticDhPublicKey: ByteArray = acceptedStaticDhPublicKey.copyOf()
    private val _pendingStaticDhPublicKey: ByteArray? = pendingStaticDhPublicKey?.copyOf()

    val nodeId: ByteArray get() = _nodeId.copyOf()
    val signingPublicKey: ByteArray get() = _signingPublicKey.copyOf()
    val acceptedStaticDhPublicKey: ByteArray get() = _acceptedStaticDhPublicKey.copyOf()
    val pendingStaticDhPublicKey: ByteArray? get() = _pendingStaticDhPublicKey?.copyOf()

    val effectiveState: EffectivePeerTrustState
        get() = when {
            trustLevel == PeerTrustLevel.REVOKED -> EffectivePeerTrustState.REVOKED
            pendingGeneration != null -> EffectivePeerTrustState.KEY_CHANGED_QUARANTINED
            trustLevel == PeerTrustLevel.USER_VERIFIED -> EffectivePeerTrustState.ACTIVE_USER_VERIFIED
            else -> EffectivePeerTrustState.ACTIVE_TOFU
        }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PeerIdentityRecord) return false
        return _nodeId.contentEquals(other._nodeId) &&
               _signingPublicKey.contentEquals(other._signingPublicKey) &&
               _acceptedStaticDhPublicKey.contentEquals(other._acceptedStaticDhPublicKey) &&
               acceptedGeneration == other.acceptedGeneration &&
               trustLevel == other.trustLevel &&
               ((_pendingStaticDhPublicKey == null && other._pendingStaticDhPublicKey == null) ||
                (_pendingStaticDhPublicKey != null && other._pendingStaticDhPublicKey != null &&
                 _pendingStaticDhPublicKey.contentEquals(other._pendingStaticDhPublicKey))) &&
               pendingGeneration == other.pendingGeneration
    }

    override fun hashCode(): Int {
        var result = _nodeId.contentHashCode()
        result = 31 * result + _signingPublicKey.contentHashCode()
        result = 31 * result + _acceptedStaticDhPublicKey.contentHashCode()
        result = 31 * result + acceptedGeneration.hashCode()
        result = 31 * result + trustLevel.hashCode()
        result = 31 * result + (_pendingStaticDhPublicKey?.contentHashCode() ?: 0)
        result = 31 * result + (pendingGeneration?.hashCode() ?: 0)
        return result
    }
}

/**
 * Corruption reasons for durable [PeerIdentityRecord] validation (ADR-003, Phase C8.2A).
 */
internal enum class PeerRecordCorruptionReason {
    InvalidNodeIdLength,
    InvalidSigningKeyLength,
    InvalidAcceptedStaticKeyLength,
    AcceptedGenerationOutOfRange,
    NodeIdSigningKeyMismatch,
    PendingCouplingViolation,
    InvalidPendingStaticKeyLength,
    PendingGenerationOutOfRange,
    PendingNotNewer,
    PendingStaticEqualsAccepted,
    RevokedWithPending
}

/**
 * Validation result taxonomy for durable [PeerIdentityRecord] (ADR-003, Phase C8.2A).
 */
internal sealed class PeerIdentityRecordValidationResult {
    object Valid : PeerIdentityRecordValidationResult()
    data class Corrupt(val reason: PeerRecordCorruptionReason) : PeerIdentityRecordValidationResult()
}

/**
 * Pure validator enforcing the 11 durable invariants of [PeerIdentityRecord] (ADR-003, Phase C8.2A).
 *
 * Proves structural dimensions, domain ranges, cryptographic node_id derivation, and field coupling.
 * Does NOT prove repository provenance or out-of-band user verification.
 */
internal object PeerIdentityRecordValidator {
    const val NODE_ID_LENGTH = 16
    const val SIGNING_KEY_LENGTH = 32
    const val STATIC_KEY_LENGTH = 32
    const val MAX_UINT32 = 0xFFFFFFFFL

    fun validate(record: PeerIdentityRecord): PeerIdentityRecordValidationResult {
        // R1: nodeId exactly 16 bytes
        val nodeBytes = record.nodeId
        if (nodeBytes.size != NODE_ID_LENGTH) {
            return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidNodeIdLength)
        }

        // R2: signingPublicKey exactly 32 bytes
        val signBytes = record.signingPublicKey
        if (signBytes.size != SIGNING_KEY_LENGTH) {
            return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidSigningKeyLength)
        }

        // R3: acceptedStaticDhPublicKey exactly 32 bytes
        val accStatic = record.acceptedStaticDhPublicKey
        if (accStatic.size != STATIC_KEY_LENGTH) {
            return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidAcceptedStaticKeyLength)
        }

        // R4: acceptedGeneration within uint32 domain
        if (record.acceptedGeneration !in 0L..MAX_UINT32) {
            return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.AcceptedGenerationOutOfRange)
        }

        // R5: nodeId == BLAKE2s-128(signingPublicKey)
        val expectedNodeId = IdentityBindingV1.deriveNodeId(signBytes)
        if (!nodeBytes.contentEquals(expectedNodeId)) {
            return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.NodeIdSigningKeyMismatch)
        }

        // R6: pendingStaticDhPublicKey and pendingGeneration are BOTH null or BOTH non-null
        val pendStatic = record.pendingStaticDhPublicKey
        val pendGen = record.pendingGeneration
        if ((pendStatic == null) != (pendGen == null)) {
            return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingCouplingViolation)
        }

        // Pending field invariants
        if (pendStatic != null && pendGen != null) {
            // R11: if trustLevel == REVOKED, pending fields MUST both be null
            if (record.trustLevel == PeerTrustLevel.REVOKED) {
                return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.RevokedWithPending)
            }

            // R7: pending static exactly 32 bytes
            if (pendStatic.size != STATIC_KEY_LENGTH) {
                return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.InvalidPendingStaticKeyLength)
            }

            // R9: pendingGeneration <= MAX_UINT32 and >= 0
            if (pendGen !in 0L..MAX_UINT32) {
                return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingGenerationOutOfRange)
            }

            // R8: pendingGeneration > acceptedGeneration
            if (pendGen <= record.acceptedGeneration) {
                return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingNotNewer)
            }

            // R10: pendingStaticDhPublicKey != acceptedStaticDhPublicKey
            if (pendStatic.contentEquals(accStatic)) {
                return PeerIdentityRecordValidationResult.Corrupt(PeerRecordCorruptionReason.PendingStaticEqualsAccepted)
            }
        }

        return PeerIdentityRecordValidationResult.Valid
    }
}

/**
 * Rejection reason taxonomy for peer trust evaluation (ADR-003, Phase C8.2A).
 */
internal enum class PeerTrustRejectReason {
    Rollback,
    SameGenerationConflict,
    PendingGenerationConflict,
    StaleRelativeToPending,
    NoncanonicalGenerationAdvance,
    NodeIdSigningKeyCollision,
    Revoked
}

/**
 * Pure decision plan emitted by [PeerTrustEngine] (ADR-003, Phase C8.2A).
 */
internal sealed class TrustPlan {
    object AcceptExisting : TrustPlan()
    object InsertFirstSeen : TrustPlan()
    object SetInitialPendingCandidate : TrustPlan()
    object AdvancePendingCandidate : TrustPlan()
    object KeepQuarantined : TrustPlan()
    data class Reject(val reason: PeerTrustRejectReason) : TrustPlan()
}

/**
 * Read-only view of a verified active peer identity (ADR-003, Phase C8.2A).
 */
class VerifiedPeerIdentity private constructor(
    nodeId: ByteArray,
    signingPublicKey: ByteArray,
    acceptedStaticDhPublicKey: ByteArray,
    val acceptedGeneration: Long,
    val trustLevel: PeerTrustLevel,
) {
    private val _nodeId: ByteArray = nodeId.copyOf()
    private val _signingPublicKey: ByteArray = signingPublicKey.copyOf()
    private val _acceptedStaticDhPublicKey: ByteArray = acceptedStaticDhPublicKey.copyOf()

    val nodeId: ByteArray get() = _nodeId.copyOf()
    val signingPublicKey: ByteArray get() = _signingPublicKey.copyOf()
    val acceptedStaticDhPublicKey: ByteArray get() = _acceptedStaticDhPublicKey.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is VerifiedPeerIdentity) return false
        return _nodeId.contentEquals(other._nodeId) &&
               _signingPublicKey.contentEquals(other._signingPublicKey) &&
               _acceptedStaticDhPublicKey.contentEquals(other._acceptedStaticDhPublicKey) &&
               acceptedGeneration == other.acceptedGeneration &&
               trustLevel == other.trustLevel
    }

    override fun hashCode(): Int {
        var result = _nodeId.contentHashCode()
        result = 31 * result + _signingPublicKey.contentHashCode()
        result = 31 * result + _acceptedStaticDhPublicKey.contentHashCode()
        result = 31 * result + acceptedGeneration.hashCode()
        result = 31 * result + trustLevel.hashCode()
        return result
    }

    companion object {
        internal fun fromRecord(record: PeerIdentityRecord): VerifiedPeerIdentity? {
            if (PeerIdentityRecordValidator.validate(record) !is PeerIdentityRecordValidationResult.Valid) {
                return null
            }
            if (record.trustLevel == PeerTrustLevel.REVOKED || record.pendingGeneration != null) {
                return null
            }
            return VerifiedPeerIdentity(
                nodeId = record.nodeId,
                signingPublicKey = record.signingPublicKey,
                acceptedStaticDhPublicKey = record.acceptedStaticDhPublicKey,
                acceptedGeneration = record.acceptedGeneration,
                trustLevel = record.trustLevel
            )
        }
    }
}

/**
 * Read-only view of a quarantined peer identity with a pending rotation candidate (ADR-003, Phase C8.2A).
 */
class PendingPeerIdentity private constructor(
    nodeId: ByteArray,
    signingPublicKey: ByteArray,
    acceptedStaticDhPublicKey: ByteArray,
    val acceptedGeneration: Long,
    val trustLevel: PeerTrustLevel,
    pendingStaticDhPublicKey: ByteArray,
    val pendingGeneration: Long,
) {
    private val _nodeId: ByteArray = nodeId.copyOf()
    private val _signingPublicKey: ByteArray = signingPublicKey.copyOf()
    private val _acceptedStaticDhPublicKey: ByteArray = acceptedStaticDhPublicKey.copyOf()
    private val _pendingStaticDhPublicKey: ByteArray = pendingStaticDhPublicKey.copyOf()

    val nodeId: ByteArray get() = _nodeId.copyOf()
    val signingPublicKey: ByteArray get() = _signingPublicKey.copyOf()
    val acceptedStaticDhPublicKey: ByteArray get() = _acceptedStaticDhPublicKey.copyOf()
    val pendingStaticDhPublicKey: ByteArray get() = _pendingStaticDhPublicKey.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PendingPeerIdentity) return false
        return _nodeId.contentEquals(other._nodeId) &&
               _signingPublicKey.contentEquals(other._signingPublicKey) &&
               _acceptedStaticDhPublicKey.contentEquals(other._acceptedStaticDhPublicKey) &&
               acceptedGeneration == other.acceptedGeneration &&
               trustLevel == other.trustLevel &&
               _pendingStaticDhPublicKey.contentEquals(other._pendingStaticDhPublicKey) &&
               pendingGeneration == other.pendingGeneration
    }

    override fun hashCode(): Int {
        var result = _nodeId.contentHashCode()
        result = 31 * result + _signingPublicKey.contentHashCode()
        result = 31 * result + _acceptedStaticDhPublicKey.contentHashCode()
        result = 31 * result + acceptedGeneration.hashCode()
        result = 31 * result + trustLevel.hashCode()
        result = 31 * result + _pendingStaticDhPublicKey.contentHashCode()
        result = 31 * result + pendingGeneration.hashCode()
        return result
    }

    companion object {
        internal fun fromRecord(record: PeerIdentityRecord): PendingPeerIdentity? {
            if (PeerIdentityRecordValidator.validate(record) !is PeerIdentityRecordValidationResult.Valid) {
                return null
            }
            if (record.trustLevel == PeerTrustLevel.REVOKED || record.pendingGeneration == null || record.pendingStaticDhPublicKey == null) {
                return null
            }
            return PendingPeerIdentity(
                nodeId = record.nodeId,
                signingPublicKey = record.signingPublicKey,
                acceptedStaticDhPublicKey = record.acceptedStaticDhPublicKey,
                acceptedGeneration = record.acceptedGeneration,
                trustLevel = record.trustLevel,
                pendingStaticDhPublicKey = record.pendingStaticDhPublicKey!!,
                pendingGeneration = record.pendingGeneration
            )
        }
    }
}
