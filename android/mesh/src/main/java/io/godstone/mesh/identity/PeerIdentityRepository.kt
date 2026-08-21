package io.godstone.mesh.identity

/**
 * Corruption taxonomy for durable row decode and repository transaction invariant failures (ADR-003, Phase C8.2B).
 */
internal sealed class PeerTrustRepositoryCorruptionReason {
    data class UnknownTrustLevelCode(val code: Int) : PeerTrustRepositoryCorruptionReason()
    data class AcceptedGenerationOutOfRange(val raw: Long) : PeerTrustRepositoryCorruptionReason()
    data class PendingGenerationOutOfRange(val raw: Long) : PeerTrustRepositoryCorruptionReason()
    data class DurableRecord(val reason: PeerRecordCorruptionReason) : PeerTrustRepositoryCorruptionReason()
    data class MutationCardinality(val expected: Int, val actual: Int) : PeerTrustRepositoryCorruptionReason()
    data class MutationReadbackMismatch(val description: String) : PeerTrustRepositoryCorruptionReason()
    data class EnginePlanInvariant(val description: String) : PeerTrustRepositoryCorruptionReason()
    object MissingPostMutationRow : PeerTrustRepositoryCorruptionReason()
    object UnexpectedInsertConflict : PeerTrustRepositoryCorruptionReason()
}

/**
 * Mutating trust ingestion result taxonomy (ADR-003, Phase C8.2B).
 */
internal sealed class PeerTrustApplyResult {
    object Accepted : PeerTrustApplyResult()
    object FirstSeenPinned : PeerTrustApplyResult()
    object KeyChangedQuarantined : PeerTrustApplyResult()
    data class Rejected(val reason: PeerTrustRejectReason) : PeerTrustApplyResult()
    data class StorageFailure(val exception: Exception? = null) : PeerTrustApplyResult()
    data class Corrupt(val reason: PeerTrustRepositoryCorruptionReason) : PeerTrustApplyResult()
}

/**
 * Read-only lookup result taxonomy for peer identity resolution (ADR-003, Phase C8.2B).
 */
internal sealed class PeerIdentityLookup {
    object NotFound : PeerIdentityLookup()
    data class Verified(val identity: VerifiedPeerIdentity) : PeerIdentityLookup()
    data class Quarantined(val identity: PendingPeerIdentity) : PeerIdentityLookup()
    object Revoked : PeerIdentityLookup()
    data class Corrupt(val reason: PeerTrustRepositoryCorruptionReason) : PeerIdentityLookup()
    data class StorageFailure(val exception: Exception? = null) : PeerIdentityLookup()
    data class InvalidArgument(val message: String) : PeerIdentityLookup()
}

/**
 * Rotation approval result taxonomy (ADR-003, Phase C8.2C).
 */
internal sealed class RotationApprovalResult {
    data class Approved(val identity: VerifiedPeerIdentity) : RotationApprovalResult()
    object PeerNotFound : RotationApprovalResult()
    object RejectedRevoked : RotationApprovalResult()
    object NoPendingCandidate : RotationApprovalResult()
    object StaleCandidate : RotationApprovalResult()
    data class InvalidArgument(val message: String) : RotationApprovalResult()
    data class Corrupt(val reason: PeerTrustRepositoryCorruptionReason) : RotationApprovalResult()
    data class StorageFailure(val exception: Exception? = null) : RotationApprovalResult()
}

/**
 * Revocation result taxonomy (ADR-003, Phase C8.2C).
 */
internal sealed class RevokeResult {
    object Revoked : RevokeResult()
    object AlreadyRevoked : RevokeResult()
    object PeerNotFound : RevokeResult()
    data class InvalidArgument(val message: String) : RevokeResult()
    data class Corrupt(val reason: PeerTrustRepositoryCorruptionReason) : RevokeResult()
    data class StorageFailure(val exception: Exception? = null) : RevokeResult()
}

/**
 * Private transaction-aborting exception to ensure corrupted states trigger immediate rollback (ADR-003, Phase C8.2B.1).
 */
private class CorruptTxnAbort(
    val reason: PeerTrustRepositoryCorruptionReason
) : RuntimeException()

private fun abortCorrupt(
    reason: PeerTrustRepositoryCorruptionReason
): Nothing = throw CorruptTxnAbort(reason)

/**
 * Private transaction-aborting exceptions for non-mutating control paths (ADR-003, Phase C8.2C).
 */
private sealed class ApprovalControlAbort : RuntimeException() {
    object PeerNotFound : ApprovalControlAbort()
    object RejectedRevoked : ApprovalControlAbort()
    object NoPendingCandidate : ApprovalControlAbort()
    object StaleCandidate : ApprovalControlAbort()
}

private sealed class RevokeControlAbort : RuntimeException() {
    object PeerNotFound : RevokeControlAbort()
    object AlreadyRevoked : RevokeControlAbort()
}

/**
 * Durable peer identity repository owning transaction serialization, strict row decoding,
 * and post-mutation readback verification (ADR-003, Phase C8.2B).
 */
internal class PeerIdentityRepository(private val store: PeerIdentityStore) {

    /**
     * Strict raw row decoder enforcing steps D1-D5 (ADR-003 §10.2).
     */
    private sealed class DecodeResult {
        data class Success(val record: PeerIdentityRecord) : DecodeResult()
        data class Failure(val reason: PeerTrustRepositoryCorruptionReason) : DecodeResult()
    }

    private fun decodeRowStrict(row: PeerIdentityRow): DecodeResult {
        // D1: Decode trust level from explicit persisted code
        val trustLevel = PeerTrustLevel.fromPersistedCode(row.trustCodeRaw)
            ?: return DecodeResult.Failure(PeerTrustRepositoryCorruptionReason.UnknownTrustLevelCode(row.trustCodeRaw))

        // D2: Accepted generation must be in 0..UINT32_MAX
        val accGen = row.acceptedGenerationRaw
        if (accGen !in 0L..PeerIdentityRecordValidator.MAX_UINT32) {
            return DecodeResult.Failure(PeerTrustRepositoryCorruptionReason.AcceptedGenerationOutOfRange(accGen))
        }

        // D3: Pending generation (if present) must be in 0..UINT32_MAX
        val pendGen = row.pendingGenerationRaw
        if (pendGen != null && pendGen !in 0L..PeerIdentityRecordValidator.MAX_UINT32) {
            return DecodeResult.Failure(PeerTrustRepositoryCorruptionReason.PendingGenerationOutOfRange(pendGen))
        }

        // D4: Construct internal PeerIdentityRecord
        val record = PeerIdentityRecord(
            nodeId = row.nodeIdRaw,
            signingPublicKey = row.signingPublicKeyRaw,
            acceptedStaticDhPublicKey = row.acceptedStaticDhPublicKeyRaw,
            acceptedGeneration = accGen,
            trustLevel = trustLevel,
            pendingStaticDhPublicKey = row.pendingStaticDhPublicKeyRaw,
            pendingGeneration = pendGen
        )

        // D5: Run PeerIdentityRecordValidator
        when (val validation = PeerIdentityRecordValidator.validate(record)) {
            is PeerIdentityRecordValidationResult.Valid -> return DecodeResult.Success(record)
            is PeerIdentityRecordValidationResult.Corrupt -> return DecodeResult.Failure(
                PeerTrustRepositoryCorruptionReason.DurableRecord(validation.reason)
            )
        }
    }

    /**
     * Ingest a cryptographically validated peer binding inside a serialized database transaction.
     */
    fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
        return try {
            store.inImmediateTransaction { tx ->
                val currentRaw = tx.readRaw(binding.nodeId)
                val currentRecord: PeerIdentityRecord?

                if (currentRaw != null) {
                    when (val decode = decodeRowStrict(currentRaw)) {
                        is DecodeResult.Success -> currentRecord = decode.record
                        is DecodeResult.Failure -> {
                            // Discovering corrupt row aborts transaction via throw
                            abortCorrupt(decode.reason)
                        }
                    }
                } else {
                    currentRecord = null
                }

                val plan = PeerTrustEngine.evaluate(binding, currentRecord)

                when (plan) {
                    is TrustPlan.AcceptExisting -> {
                        PeerTrustApplyResult.Accepted
                    }

                    is TrustPlan.KeepQuarantined -> {
                        PeerTrustApplyResult.KeyChangedQuarantined
                    }

                    is TrustPlan.Reject -> {
                        PeerTrustApplyResult.Rejected(plan.reason)
                    }

                    is TrustPlan.InsertFirstSeen -> {
                        val affected = tx.insertFirstSeen(
                            nodeId = binding.nodeId,
                            signingPub = binding.signingPublicKey,
                            acceptedStatic = binding.staticDhPublicKey,
                            acceptedGeneration = binding.generation,
                            trustCode = PeerTrustLevel.TOFU_PINNED.persistedCode
                        )
                        if (affected != 1) {
                            abortCorrupt(PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected))
                        }

                        val readbackRaw = tx.readRaw(binding.nodeId)
                            ?: abortCorrupt(PeerTrustRepositoryCorruptionReason.MissingPostMutationRow)

                        val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                            is DecodeResult.Success -> d.record
                            is DecodeResult.Failure -> abortCorrupt(d.reason)
                        }

                        val expected = PeerIdentityRecord(
                            nodeId = binding.nodeId,
                            signingPublicKey = binding.signingPublicKey,
                            acceptedStaticDhPublicKey = binding.staticDhPublicKey,
                            acceptedGeneration = binding.generation,
                            trustLevel = PeerTrustLevel.TOFU_PINNED,
                            pendingStaticDhPublicKey = null,
                            pendingGeneration = null
                        )

                        if (readbackRecord != expected) {
                            abortCorrupt(
                                PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("FirstSeen readback mismatch")
                            )
                        }

                        PeerTrustApplyResult.FirstSeenPinned
                    }

                    is TrustPlan.SetInitialPendingCandidate -> {
                        if (currentRecord == null) {
                            abortCorrupt(
                                PeerTrustRepositoryCorruptionReason.EnginePlanInvariant("SetInitialPendingCandidate requires existing record")
                            )
                        }
                        val affected = tx.setInitialPendingGuarded(
                            nodeId = currentRecord.nodeId,
                            signingPub = currentRecord.signingPublicKey,
                            acceptedStatic = currentRecord.acceptedStaticDhPublicKey,
                            acceptedGeneration = currentRecord.acceptedGeneration,
                            trustLevel = currentRecord.trustLevel.persistedCode,
                            newPendingStatic = binding.staticDhPublicKey,
                            newPendingGeneration = binding.generation
                        )
                        if (affected != 1) {
                            abortCorrupt(PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected))
                        }

                        val readbackRaw = tx.readRaw(binding.nodeId)
                            ?: abortCorrupt(PeerTrustRepositoryCorruptionReason.MissingPostMutationRow)

                        val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                            is DecodeResult.Success -> d.record
                            is DecodeResult.Failure -> abortCorrupt(d.reason)
                        }

                        val expected = PeerIdentityRecord(
                            nodeId = currentRecord.nodeId,
                            signingPublicKey = currentRecord.signingPublicKey,
                            acceptedStaticDhPublicKey = currentRecord.acceptedStaticDhPublicKey,
                            acceptedGeneration = currentRecord.acceptedGeneration,
                            trustLevel = currentRecord.trustLevel,
                            pendingStaticDhPublicKey = binding.staticDhPublicKey,
                            pendingGeneration = binding.generation
                        )

                        if (readbackRecord != expected) {
                            abortCorrupt(
                                PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("SetInitialPending readback mismatch")
                            )
                        }

                        PeerTrustApplyResult.KeyChangedQuarantined
                    }

                    is TrustPlan.AdvancePendingCandidate -> {
                        val oldPendingStatic = currentRecord?.pendingStaticDhPublicKey
                        val oldPendingGen = currentRecord?.pendingGeneration
                        if (currentRecord == null || oldPendingStatic == null || oldPendingGen == null) {
                            abortCorrupt(
                                PeerTrustRepositoryCorruptionReason.EnginePlanInvariant(
                                    "AdvancePendingCandidate requires currentRecord with non-null pending fields"
                                )
                            )
                        }

                        val affected = tx.advancePendingGuarded(
                            nodeId = currentRecord.nodeId,
                            signingPub = currentRecord.signingPublicKey,
                            acceptedStatic = currentRecord.acceptedStaticDhPublicKey,
                            acceptedGeneration = currentRecord.acceptedGeneration,
                            trustLevel = currentRecord.trustLevel.persistedCode,
                            oldPendingStatic = oldPendingStatic,
                            oldPendingGeneration = oldPendingGen,
                            newPendingStatic = binding.staticDhPublicKey,
                            newPendingGeneration = binding.generation
                        )
                        if (affected != 1) {
                            abortCorrupt(PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected))
                        }

                        val readbackRaw = tx.readRaw(binding.nodeId)
                            ?: abortCorrupt(PeerTrustRepositoryCorruptionReason.MissingPostMutationRow)

                        val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                            is DecodeResult.Success -> d.record
                            is DecodeResult.Failure -> abortCorrupt(d.reason)
                        }

                        val expected = PeerIdentityRecord(
                            nodeId = currentRecord.nodeId,
                            signingPublicKey = currentRecord.signingPublicKey,
                            acceptedStaticDhPublicKey = currentRecord.acceptedStaticDhPublicKey,
                            acceptedGeneration = currentRecord.acceptedGeneration,
                            trustLevel = currentRecord.trustLevel,
                            pendingStaticDhPublicKey = binding.staticDhPublicKey,
                            pendingGeneration = binding.generation
                        )

                        if (readbackRecord != expected) {
                            abortCorrupt(
                                PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("AdvancePending readback mismatch")
                            )
                        }

                        PeerTrustApplyResult.KeyChangedQuarantined
                    }
                }
            }
        } catch (e: CorruptTxnAbort) {
            PeerTrustApplyResult.Corrupt(e.reason)
        } catch (e: Exception) {
            PeerTrustApplyResult.StorageFailure(e)
        }
    }

    /**
     * Look up a peer identity by its 16-byte node_id.
     */
    fun lookup(nodeId: ByteArray): PeerIdentityLookup {
        if (nodeId.size != 16) {
            return PeerIdentityLookup.InvalidArgument("nodeId must be exactly 16 bytes, got ${nodeId.size}")
        }

        val rawRow: PeerIdentityRow?
        try {
            rawRow = store.readRaw(nodeId)
        } catch (e: Exception) {
            return PeerIdentityLookup.StorageFailure(e)
        }

        if (rawRow == null) {
            return PeerIdentityLookup.NotFound
        }

        val record = when (val decode = decodeRowStrict(rawRow)) {
            is DecodeResult.Success -> decode.record
            is DecodeResult.Failure -> return PeerIdentityLookup.Corrupt(decode.reason)
        }

        if (record.trustLevel == PeerTrustLevel.REVOKED) {
            return PeerIdentityLookup.Revoked
        }

        val quarantinedView = PendingPeerIdentity.fromRecord(record)
        if (quarantinedView != null) {
            return PeerIdentityLookup.Quarantined(quarantinedView)
        }

        val verifiedView = VerifiedPeerIdentity.fromRecord(record)
        if (verifiedView != null) {
            return PeerIdentityLookup.Verified(verifiedView)
        }

        return PeerIdentityLookup.Corrupt(
            PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("Unable to construct valid view from unquarantined non-revoked record")
        )
    }

    /**
     * Explicitly approve an exact pending rotation candidate inside a serialized write transaction (ADR-003, Phase C8.2C).
     */
    fun approvePendingRotation(
        nodeId: ByteArray,
        expectedPendingGeneration: Long,
        expectedPendingStaticDhPublicKey: ByteArray
    ): RotationApprovalResult {
        if (nodeId.size != 16) {
            return RotationApprovalResult.InvalidArgument("nodeId must be exactly 16 bytes, got ${nodeId.size}")
        }
        if (expectedPendingStaticDhPublicKey.size != 32) {
            return RotationApprovalResult.InvalidArgument(
                "expectedPendingStaticDhPublicKey must be exactly 32 bytes, got ${expectedPendingStaticDhPublicKey.size}"
            )
        }
        if (expectedPendingGeneration !in 0L..PeerIdentityRecordValidator.MAX_UINT32) {
            return RotationApprovalResult.InvalidArgument(
                "expectedPendingGeneration out of range: $expectedPendingGeneration"
            )
        }

        return try {
            store.inImmediateTransaction { tx ->
                val currentRaw = tx.readRaw(nodeId)
                    ?: throw ApprovalControlAbort.PeerNotFound

                val currentRecord = when (val decode = decodeRowStrict(currentRaw)) {
                    is DecodeResult.Success -> decode.record
                    is DecodeResult.Failure -> abortCorrupt(decode.reason)
                }

                if (currentRecord.trustLevel == PeerTrustLevel.REVOKED) {
                    throw ApprovalControlAbort.RejectedRevoked
                }

                if (currentRecord.pendingGeneration == null || currentRecord.pendingStaticDhPublicKey == null) {
                    throw ApprovalControlAbort.NoPendingCandidate
                }

                if (currentRecord.pendingGeneration != expectedPendingGeneration ||
                    !currentRecord.pendingStaticDhPublicKey.contentEquals(expectedPendingStaticDhPublicKey)
                ) {
                    throw ApprovalControlAbort.StaleCandidate
                }

                val affected = tx.approvePendingRotationGuarded(
                    nodeId = currentRecord.nodeId,
                    signingPub = currentRecord.signingPublicKey,
                    acceptedStatic = currentRecord.acceptedStaticDhPublicKey,
                    acceptedGeneration = currentRecord.acceptedGeneration,
                    trustLevel = currentRecord.trustLevel.persistedCode,
                    expectedPendingStatic = expectedPendingStaticDhPublicKey,
                    expectedPendingGeneration = expectedPendingGeneration
                )
                if (affected != 1) {
                    abortCorrupt(PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected))
                }

                val readbackRaw = tx.readRaw(nodeId)
                    ?: abortCorrupt(PeerTrustRepositoryCorruptionReason.MissingPostMutationRow)

                val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                    is DecodeResult.Success -> d.record
                    is DecodeResult.Failure -> abortCorrupt(d.reason)
                }

                val expected = PeerIdentityRecord(
                    nodeId = currentRecord.nodeId,
                    signingPublicKey = currentRecord.signingPublicKey,
                    acceptedStaticDhPublicKey = expectedPendingStaticDhPublicKey,
                    acceptedGeneration = expectedPendingGeneration,
                    trustLevel = currentRecord.trustLevel,
                    pendingStaticDhPublicKey = null,
                    pendingGeneration = null
                )

                if (readbackRecord != expected) {
                    abortCorrupt(
                        PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("ApprovePendingRotation readback mismatch")
                    )
                }

                val verifiedView = VerifiedPeerIdentity.fromRecord(readbackRecord)
                    ?: abortCorrupt(
                        PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("Unable to mint VerifiedPeerIdentity from approved record")
                    )

                RotationApprovalResult.Approved(verifiedView)
            }
        } catch (e: ApprovalControlAbort.PeerNotFound) {
            RotationApprovalResult.PeerNotFound
        } catch (e: ApprovalControlAbort.RejectedRevoked) {
            RotationApprovalResult.RejectedRevoked
        } catch (e: ApprovalControlAbort.NoPendingCandidate) {
            RotationApprovalResult.NoPendingCandidate
        } catch (e: ApprovalControlAbort.StaleCandidate) {
            RotationApprovalResult.StaleCandidate
        } catch (e: CorruptTxnAbort) {
            RotationApprovalResult.Corrupt(e.reason)
        } catch (e: Exception) {
            RotationApprovalResult.StorageFailure(e)
        }
    }

    /**
     * Durably revoke a peer identity inside a serialized write transaction (ADR-003, Phase C8.2C).
     */
    fun revokePeer(nodeId: ByteArray): RevokeResult {
        if (nodeId.size != 16) {
            return RevokeResult.InvalidArgument("nodeId must be exactly 16 bytes, got ${nodeId.size}")
        }

        return try {
            store.inImmediateTransaction { tx ->
                val currentRaw = tx.readRaw(nodeId)
                    ?: throw RevokeControlAbort.PeerNotFound

                val currentRecord = when (val decode = decodeRowStrict(currentRaw)) {
                    is DecodeResult.Success -> decode.record
                    is DecodeResult.Failure -> abortCorrupt(decode.reason)
                }

                if (currentRecord.trustLevel == PeerTrustLevel.REVOKED) {
                    throw RevokeControlAbort.AlreadyRevoked
                }

                val affected = tx.revokePeerGuarded(
                    nodeId = currentRecord.nodeId,
                    signingPub = currentRecord.signingPublicKey,
                    acceptedStatic = currentRecord.acceptedStaticDhPublicKey,
                    acceptedGeneration = currentRecord.acceptedGeneration,
                    currentTrustLevel = currentRecord.trustLevel.persistedCode,
                    oldPendingStatic = currentRecord.pendingStaticDhPublicKey,
                    oldPendingGeneration = currentRecord.pendingGeneration
                )
                if (affected != 1) {
                    abortCorrupt(PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected))
                }

                val readbackRaw = tx.readRaw(nodeId)
                    ?: abortCorrupt(PeerTrustRepositoryCorruptionReason.MissingPostMutationRow)

                val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                    is DecodeResult.Success -> d.record
                    is DecodeResult.Failure -> abortCorrupt(d.reason)
                }

                val expected = PeerIdentityRecord(
                    nodeId = currentRecord.nodeId,
                    signingPublicKey = currentRecord.signingPublicKey,
                    acceptedStaticDhPublicKey = currentRecord.acceptedStaticDhPublicKey,
                    acceptedGeneration = currentRecord.acceptedGeneration,
                    trustLevel = PeerTrustLevel.REVOKED,
                    pendingStaticDhPublicKey = null,
                    pendingGeneration = null
                )

                if (readbackRecord != expected) {
                    abortCorrupt(
                        PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("RevokePeer readback mismatch")
                    )
                }

                RevokeResult.Revoked
            }
        } catch (e: RevokeControlAbort.PeerNotFound) {
            RevokeResult.PeerNotFound
        } catch (e: RevokeControlAbort.AlreadyRevoked) {
            RevokeResult.AlreadyRevoked
        } catch (e: CorruptTxnAbort) {
            RevokeResult.Corrupt(e.reason)
        } catch (e: Exception) {
            RevokeResult.StorageFailure(e)
        }
    }
}
