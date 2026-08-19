import Foundation

/// Corruption taxonomy for durable row decode and repository transaction invariant failures (ADR-003, Phase C8.2B).
internal enum PeerTrustRepositoryCorruptionReason: Error, Sendable, Equatable {
    case unknownTrustLevelCode(Int32)
    case acceptedGenerationOutOfRange(Int64)
    case pendingGenerationOutOfRange(Int64)
    case durableRecord(PeerRecordCorruptionReason)
    case mutationCardinality(expected: Int, actual: Int)
    case mutationReadbackMismatch(String)
    case enginePlanInvariant(String)
    case missingPostMutationRow
    case unexpectedInsertConflict
}

/// Mutating trust ingestion result taxonomy (ADR-003, Phase C8.2B).
internal enum PeerTrustApplyResult: Sendable, Equatable {
    case accepted
    case firstSeenPinned
    case keyChangedQuarantined
    case rejected(PeerTrustRejectReason)
    case storageFailure
    case corrupt(PeerTrustRepositoryCorruptionReason)
}

/// Read-only lookup result taxonomy for peer identity resolution (ADR-003, Phase C8.2B).
internal enum PeerIdentityLookup: Sendable, Equatable {
    case notFound
    case verified(VerifiedPeerIdentity)
    case quarantined(PendingPeerIdentity)
    case revoked
    case corrupt(PeerTrustRepositoryCorruptionReason)
    case storageFailure
    case invalidArgument(String)
}

/// Private transaction-aborting error ensuring corrupted states trigger immediate rollback (ADR-003, Phase C8.2B.1).
private enum ApplyTxnAbort: Error {
    case corrupt(PeerTrustRepositoryCorruptionReason)
}

/// Durable peer identity repository owning transaction serialization, strict row decoding,
/// and post-mutation readback verification (ADR-003, Phase C8.2B).
internal final class PeerIdentityRepository {
    private let store: PeerIdentityStore

    init(store: PeerIdentityStore) {
        self.store = store
    }

    /// Strict raw row decoder enforcing steps D1-D5 (ADR-003 §10.2).
    private func decodeRowStrict(_ row: PeerIdentityRow) -> Result<PeerIdentityRecord, PeerTrustRepositoryCorruptionReason> {
        // D1: Decode trust level from persisted code
        guard let trustLevel = PeerTrustLevel.fromPersistedCode(row.trustCodeRaw) else {
            return .failure(.unknownTrustLevelCode(row.trustCodeRaw))
        }

        // D2: Accepted generation must be in 0..UINT32_MAX
        let maxUInt32: Int64 = 4294967295
        guard row.acceptedGenerationRaw >= 0 && row.acceptedGenerationRaw <= maxUInt32 else {
            return .failure(.acceptedGenerationOutOfRange(row.acceptedGenerationRaw))
        }

        // D3: Pending generation (if present) must be in 0..UINT32_MAX
        if let pendGen = row.pendingGenerationRaw {
            guard pendGen >= 0 && pendGen <= maxUInt32 else {
                return .failure(.pendingGenerationOutOfRange(pendGen))
            }
        }

        // D4: Construct internal PeerIdentityRecord
        let record = PeerIdentityRecord(
            nodeId: row.nodeIdRaw,
            signingPublicKey: row.signingPublicKeyRaw,
            acceptedStaticDhPublicKey: row.acceptedStaticDhPublicKeyRaw,
            acceptedGeneration: UInt32(row.acceptedGenerationRaw),
            trustLevel: trustLevel,
            pendingStaticDhPublicKey: row.pendingStaticDhPublicKeyRaw,
            pendingGeneration: row.pendingGenerationRaw.map { UInt32($0) }
        )

        // D5: Run PeerIdentityRecordValidator
        switch PeerIdentityRecordValidator.validate(record: record) {
        case .valid:
            return .success(record)
        case .corrupt(let reason):
            return .failure(.durableRecord(reason))
        }
    }

    /// Ingest a cryptographically validated peer binding inside a serialized database transaction.
    func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
        do {
            return try store.inImmediateTransaction { tx in
                let currentRaw = try tx.readRaw(binding.nodeId)
                let currentRecord: PeerIdentityRecord?

                if let raw = currentRaw {
                    switch decodeRowStrict(raw) {
                    case .success(let rec):
                        currentRecord = rec
                    case .failure(let reason):
                        throw ApplyTxnAbort.corrupt(reason)
                    }
                } else {
                    currentRecord = nullRecord()
                }

                let plan = PeerTrustEngine.evaluate(binding: binding, current: currentRecord)

                switch plan {
                case .acceptExisting:
                    return .accepted

                case .keepQuarantined:
                    return .keyChangedQuarantined

                case .reject(let reason):
                    return .rejected(reason)

                case .insertFirstSeen:
                    let affected = try tx.insertFirstSeen(
                        nodeId: binding.nodeId,
                        signingPub: binding.signingPublicKey,
                        acceptedStatic: binding.staticDhPublicKey,
                        acceptedGeneration: Int64(binding.generation),
                        trustCode: Int32(PeerTrustLevel.tofuPinned.persistedCode)
                    )
                    if affected != 1 {
                        throw ApplyTxnAbort.corrupt(.mutationCardinality(expected: 1, actual: affected))
                    }

                    guard let readbackRaw = try tx.readRaw(binding.nodeId) else {
                        throw ApplyTxnAbort.corrupt(.missingPostMutationRow)
                    }

                    let readbackRecord: PeerIdentityRecord
                    switch decodeRowStrict(readbackRaw) {
                    case .success(let rec):
                        readbackRecord = rec
                    case .failure(let reason):
                        throw ApplyTxnAbort.corrupt(reason)
                    }

                    let expected = PeerIdentityRecord(
                        nodeId: binding.nodeId,
                        signingPublicKey: binding.signingPublicKey,
                        acceptedStaticDhPublicKey: binding.staticDhPublicKey,
                        acceptedGeneration: binding.generation,
                        trustLevel: .tofuPinned,
                        pendingStaticDhPublicKey: nil,
                        pendingGeneration: nil
                    )

                    guard readbackRecord == expected else {
                        throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("FirstSeen readback mismatch"))
                    }

                    return .firstSeenPinned

                case .setInitialPendingCandidate:
                    guard let current = currentRecord else {
                        throw ApplyTxnAbort.corrupt(.enginePlanInvariant("SetInitialPending requires existing record"))
                    }

                    let affected = try tx.setInitialPendingGuarded(
                        nodeId: current.nodeId,
                        signingPub: current.signingPublicKey,
                        acceptedStatic: current.acceptedStaticDhPublicKey,
                        acceptedGeneration: Int64(current.acceptedGeneration),
                        trustLevel: Int32(current.trustLevel.persistedCode),
                        newPendingStatic: binding.staticDhPublicKey,
                        newPendingGeneration: Int64(binding.generation)
                    )
                    if affected != 1 {
                        throw ApplyTxnAbort.corrupt(.mutationCardinality(expected: 1, actual: affected))
                    }

                    guard let readbackRaw = try tx.readRaw(binding.nodeId) else {
                        throw ApplyTxnAbort.corrupt(.missingPostMutationRow)
                    }

                    let readbackRecord: PeerIdentityRecord
                    switch decodeRowStrict(readbackRaw) {
                    case .success(let rec):
                        readbackRecord = rec
                    case .failure(let reason):
                        throw ApplyTxnAbort.corrupt(reason)
                    }

                    let expected = PeerIdentityRecord(
                        nodeId: current.nodeId,
                        signingPublicKey: current.signingPublicKey,
                        acceptedStaticDhPublicKey: current.acceptedStaticDhPublicKey,
                        acceptedGeneration: current.acceptedGeneration,
                        trustLevel: current.trustLevel,
                        pendingStaticDhPublicKey: binding.staticDhPublicKey,
                        pendingGeneration: binding.generation
                    )

                    guard readbackRecord == expected else {
                        throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("SetInitialPending readback mismatch"))
                    }

                    return .keyChangedQuarantined

                case .advancePendingCandidate:
                    guard let current = currentRecord,
                          let oldPendingStatic = current.pendingStaticDhPublicKey,
                          let oldPendingGen = current.pendingGeneration else {
                        throw ApplyTxnAbort.corrupt(.enginePlanInvariant("AdvancePending requires existing pending candidate"))
                    }

                    let affected = try tx.advancePendingGuarded(
                        nodeId: current.nodeId,
                        signingPub: current.signingPublicKey,
                        acceptedStatic: current.acceptedStaticDhPublicKey,
                        acceptedGeneration: Int64(current.acceptedGeneration),
                        trustLevel: Int32(current.trustLevel.persistedCode),
                        oldPendingStatic: oldPendingStatic,
                        oldPendingGeneration: Int64(oldPendingGen),
                        newPendingStatic: binding.staticDhPublicKey,
                        newPendingGeneration: Int64(binding.generation)
                    )
                    if affected != 1 {
                        throw ApplyTxnAbort.corrupt(.mutationCardinality(expected: 1, actual: affected))
                    }

                    guard let readbackRaw = try tx.readRaw(binding.nodeId) else {
                        throw ApplyTxnAbort.corrupt(.missingPostMutationRow)
                    }

                    let readbackRecord: PeerIdentityRecord
                    switch decodeRowStrict(readbackRaw) {
                    case .success(let rec):
                        readbackRecord = rec
                    case .failure(let reason):
                        throw ApplyTxnAbort.corrupt(reason)
                    }

                    let expected = PeerIdentityRecord(
                        nodeId: current.nodeId,
                        signingPublicKey: current.signingPublicKey,
                        acceptedStaticDhPublicKey: current.acceptedStaticDhPublicKey,
                        acceptedGeneration: current.acceptedGeneration,
                        trustLevel: current.trustLevel,
                        pendingStaticDhPublicKey: binding.staticDhPublicKey,
                        pendingGeneration: binding.generation
                    )

                    guard readbackRecord == expected else {
                        throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("AdvancePending readback mismatch"))
                    }

                    return .keyChangedQuarantined
                }
            }
        } catch let ApplyTxnAbort.corrupt(reason) {
            return .corrupt(reason)
        } catch {
            return .storageFailure
        }
    }

    /// Helper returning nil typed PeerIdentityRecord
    @inline(__always)
    private func nullRecord() -> PeerIdentityRecord? {
        nil
    }

    /// Look up a peer identity by its 16-byte node_id.
    func lookup(_ nodeId: Data) -> PeerIdentityLookup {
        guard nodeId.count == 16 else {
            return .invalidArgument("nodeId must be exactly 16 bytes, got \(nodeId.count)")
        }

        let rawRow: PeerIdentityRow?
        do {
            rawRow = try store.readRaw(nodeId)
        } catch {
            return .storageFailure
        }

        guard let raw = rawRow else {
            return .notFound
        }

        let record: PeerIdentityRecord
        switch decodeRowStrict(raw) {
        case .success(let rec):
            record = rec
        case .failure(let reason):
            return .corrupt(reason)
        }

        if record.trustLevel == .revoked {
            return .revoked
        }

        if let quarantinedView = PendingPeerIdentity.fromRecord(record) {
            return .quarantined(quarantinedView)
        }

        if let verifiedView = VerifiedPeerIdentity.fromRecord(record) {
            return .verified(verifiedView)
        }

        return .corrupt(.mutationReadbackMismatch("Unable to construct valid view from unquarantined non-revoked record"))
    }
}
