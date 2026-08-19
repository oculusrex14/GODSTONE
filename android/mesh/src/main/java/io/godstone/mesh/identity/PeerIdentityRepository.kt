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
        try {
            return store.inImmediateTransaction { tx ->
                val currentRaw = tx.readRaw(binding.nodeId)
                val currentRecord: PeerIdentityRecord?

                if (currentRaw != null) {
                    when (val decode = decodeRowStrict(currentRaw)) {
                        is DecodeResult.Success -> currentRecord = decode.record
                        is DecodeResult.Failure -> {
                            // Discovering corrupt row aborts transaction
                            return@inImmediateTransaction PeerTrustApplyResult.Corrupt(decode.reason)
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
                            return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected)
                            )
                        }

                        val readbackRaw = tx.readRaw(binding.nodeId)
                            ?: return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MissingPostMutationRow
                            )

                        val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                            is DecodeResult.Success -> d.record
                            is DecodeResult.Failure -> return@inImmediateTransaction PeerTrustApplyResult.Corrupt(d.reason)
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
                            return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("FirstSeen readback mismatch")
                            )
                        }

                        PeerTrustApplyResult.FirstSeenPinned
                    }

                    is TrustPlan.SetInitialPendingCandidate -> {
                        checkNotNull(currentRecord) { "SetInitialPendingCandidate requires existing record" }
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
                            return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected)
                            )
                        }

                        val readbackRaw = tx.readRaw(binding.nodeId)
                            ?: return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MissingPostMutationRow
                            )

                        val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                            is DecodeResult.Success -> d.record
                            is DecodeResult.Failure -> return@inImmediateTransaction PeerTrustApplyResult.Corrupt(d.reason)
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
                            return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("SetInitialPending readback mismatch")
                            )
                        }

                        PeerTrustApplyResult.KeyChangedQuarantined
                    }

                    is TrustPlan.AdvancePendingCandidate -> {
                        checkNotNull(currentRecord) { "AdvancePendingCandidate requires existing record" }
                        val oldPendingStatic = checkNotNull(currentRecord.pendingStaticDhPublicKey)
                        val oldPendingGen = checkNotNull(currentRecord.pendingGeneration)

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
                            return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MutationCardinality(1, affected)
                            )
                        }

                        val readbackRaw = tx.readRaw(binding.nodeId)
                            ?: return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MissingPostMutationRow
                            )

                        val readbackRecord = when (val d = decodeRowStrict(readbackRaw)) {
                            is DecodeResult.Success -> d.record
                            is DecodeResult.Failure -> return@inImmediateTransaction PeerTrustApplyResult.Corrupt(d.reason)
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
                            return@inImmediateTransaction PeerTrustApplyResult.Corrupt(
                                PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("AdvancePending readback mismatch")
                            )
                        }

                        PeerTrustApplyResult.KeyChangedQuarantined
                    }
                }
            }
        } catch (e: Exception) {
            return PeerTrustApplyResult.StorageFailure(e)
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
}
