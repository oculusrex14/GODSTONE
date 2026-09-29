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

/// Rotation approval result taxonomy (ADR-003, Phase C8.2C).
internal enum RotationApprovalResult: Sendable, Equatable {
    case approved(VerifiedPeerIdentity)
    case peerNotFound
    case rejectedRevoked
    case noPendingCandidate
    case staleCandidate
    case invalidArgument(String)
    case corrupt(PeerTrustRepositoryCorruptionReason)
    case storageFailure
}

/// Revocation result taxonomy (ADR-003, Phase C8.2C).
internal enum RevokeResult: Sendable, Equatable {
    case revoked
    case alreadyRevoked
    case peerNotFound
    case invalidArgument(String)
    case corrupt(PeerTrustRepositoryCorruptionReason)
    case storageFailure
}

/// Private transaction-aborting error ensuring corrupted states trigger immediate rollback (ADR-003, Phase C8.2B.1).
private enum ApplyTxnAbort: Error {
    case corrupt(PeerTrustRepositoryCorruptionReason)
}

/// Private transaction-aborting errors for non-mutating control paths (ADR-003, Phase C8.2C).
private enum ApprovalControlAbort: Error {
    case peerNotFound
    case rejectedRevoked
    case noPendingCandidate
    case staleCandidate
}

private enum RevokeControlAbort: Error {
    case peerNotFound
    case alreadyRevoked
}

/// *** THE CONFIRMATION ABORT REASONS -- typed, so the caller can render WHICH refusal it was. ***
private enum ConfirmationAbort: Error {
    case peerNotFound
    case revoked
    case quarantined
    case stale
}

/// *** THE OUTCOME OF A FINGERPRINT CONFIRMATION, TYPED RATHER THAN A BOOLEAN. ***
///
/// *A `Bool` would collapse four distinguishable states -- promoted, already-verified, stale and refused -- into
/// "true/false", and the UI must render DIFFERENT words for each.* **`alreadyVerified` is the idempotent case: the
/// row already stood verified at the EXACT accepted state the fingerprint was displayed against, so nothing changed
/// and nothing needed to.**
enum PeerConfirmationResult: Sendable, Equatable {
    case confirmed(VerifiedPeerIdentity)
    case alreadyVerified(VerifiedPeerIdentity)
    case peerNotFound
    case revoked
    case quarantined
    case stale
    case corrupt(PeerTrustRepositoryCorruptionReason)
    case storageFailure
    case invalidArgument(String)

    /// Whether the durable authority now carrieth the confirmed state (promoted OR already there).
    var isDurableUserVerified: Bool {
        switch self {
        case .confirmed, .alreadyVerified: return true
        default: return false
        }
    }
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

    /**
     * Explicitly approve an exact pending rotation candidate inside a serialized write transaction (ADR-003, Phase C8.2C).
     */
    func approvePendingRotation(
        nodeId: Data,
        expectedPendingGeneration: UInt32,
        expectedPendingStaticDhPublicKey: Data
    ) -> RotationApprovalResult {
        guard nodeId.count == 16 else {
            return .invalidArgument("nodeId must be exactly 16 bytes, got \(nodeId.count)")
        }
        guard expectedPendingStaticDhPublicKey.count == 32 else {
            return .invalidArgument(
                "expectedPendingStaticDhPublicKey must be exactly 32 bytes, got \(expectedPendingStaticDhPublicKey.count)"
            )
        }

        do {
            return try store.inImmediateTransaction { tx in
                guard let currentRaw = try tx.readRaw(nodeId) else {
                    throw ApprovalControlAbort.peerNotFound
                }

                let currentRecord: PeerIdentityRecord
                switch decodeRowStrict(currentRaw) {
                case .success(let rec):
                    currentRecord = rec
                case .failure(let reason):
                    throw ApplyTxnAbort.corrupt(reason)
                }

                if currentRecord.trustLevel == .revoked {
                    throw ApprovalControlAbort.rejectedRevoked
                }

                guard let currentPendingGen = currentRecord.pendingGeneration,
                      let currentPendingStatic = currentRecord.pendingStaticDhPublicKey else {
                    throw ApprovalControlAbort.noPendingCandidate
                }

                if currentPendingGen != expectedPendingGeneration ||
                    currentPendingStatic != expectedPendingStaticDhPublicKey {
                    throw ApprovalControlAbort.staleCandidate
                }

                let affected = try tx.approvePendingRotationGuarded(
                    nodeId: currentRecord.nodeId,
                    signingPub: currentRecord.signingPublicKey,
                    acceptedStatic: currentRecord.acceptedStaticDhPublicKey,
                    acceptedGeneration: Int64(currentRecord.acceptedGeneration),
                    trustLevel: Int32(currentRecord.trustLevel.persistedCode),
                    expectedPendingStatic: expectedPendingStaticDhPublicKey,
                    expectedPendingGeneration: Int64(expectedPendingGeneration)
                )
                if affected != 1 {
                    throw ApplyTxnAbort.corrupt(.mutationCardinality(expected: 1, actual: affected))
                }

                guard let readbackRaw = try tx.readRaw(nodeId) else {
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
                    nodeId: currentRecord.nodeId,
                    signingPublicKey: currentRecord.signingPublicKey,
                    acceptedStaticDhPublicKey: expectedPendingStaticDhPublicKey,
                    acceptedGeneration: expectedPendingGeneration,
                    trustLevel: currentRecord.trustLevel,
                    pendingStaticDhPublicKey: nil,
                    pendingGeneration: nil
                )

                guard readbackRecord == expected else {
                    throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("ApprovePendingRotation readback mismatch"))
                }

                guard let verifiedView = VerifiedPeerIdentity.fromRecord(readbackRecord) else {
                    throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("Unable to mint VerifiedPeerIdentity from approved record"))
                }

                return .approved(verifiedView)
            }
        } catch ApprovalControlAbort.peerNotFound {
            return .peerNotFound
        } catch ApprovalControlAbort.rejectedRevoked {
            return .rejectedRevoked
        } catch ApprovalControlAbort.noPendingCandidate {
            return .noPendingCandidate
        } catch ApprovalControlAbort.staleCandidate {
            return .staleCandidate
        } catch let ApplyTxnAbort.corrupt(reason) {
            return .corrupt(reason)
        } catch {
            return .storageFailure
        }
    }

    /// *** THE FINGERPRINT-CONFIRMATION OPERATION: A LOCAL, OUT-OF-BAND TOFU -> USER_VERIFIED TRANSITION. ***
    ///
    /// *THE GAP THIS CLOSES: both peer schemas carried `USER_VERIFIED = 2`, and no guarded operation could reach it --
    /// so `TrustAuthorityAdapter.confirmVerified` refused unconditionally and a user could SEE a verified fingerprint
    /// and never confirm it.* **The wire protocol is UNCHANGED: this is a durable local trust transition.**
    ///
    /// **THE CAS IS GUARDED ON THE **DISPLAYED** STATE, NOT A RE-RESOLVED ONE:** the caller passeth the exact node,
    /// signing key, accepted static key and accepted generation it showed with the fingerprint, and the store's
    /// predicates require exactly those plus TOFU and NO pending candidate. *So a stale confirmation (the key rotated
    /// or the generation moved since) changes nothing, and a quarantined/revoked/corrupt row is refused rather than
    /// promoted. A row ALREADY at `userVerified` with the SAME accepted state is reported `.alreadyVerified`
    /// (idempotent), and a row already verified at a DIFFERENT accepted state is `.stale` -- never a silent
    /// promotion.*
    func confirmVerified(
        nodeId: Data,
        expectedAcceptedGeneration: UInt32,
        expectedFingerprintHex: String
    ) -> PeerConfirmationResult {
        guard nodeId.count == 16 else {
            return .invalidArgument("nodeId must be exactly 16 bytes, got \(nodeId.count)")
        }
        guard expectedFingerprintHex.count == 64,
              expectedFingerprintHex.allSatisfy({ $0.isHexDigit }) else {
            return .invalidArgument("expectedFingerprintHex must be a 64-character hex digest")
        }
        do {
            return try store.inImmediateTransaction { tx in
                guard let currentRaw = try tx.readRaw(nodeId) else {
                    throw ConfirmationAbort.peerNotFound
                }
                let current: PeerIdentityRecord
                switch decodeRowStrict(currentRaw) {
                case .success(let rec): current = rec
                case .failure(let reason): throw ApplyTxnAbort.corrupt(reason)
                }
                // *** THE FIVE PREDICATES THE STORE ALSO ENFORCES, CHECKED HERE TO RETURN A TYPED REASON. ***
                // *The store's SQL is the authority; this decode names WHY it will not match, so the caller gets
                // `.revoked`/`.quarantined`/`.stale` rather than a bare "no row changed".*
                guard current.trustLevel != .revoked else { throw ConfirmationAbort.revoked }
                guard current.pendingGeneration == nil, current.pendingStaticDhPublicKey == nil else {
                    throw ConfirmationAbort.quarantined
                }
                // *** THE CAPTURED REFERENCE MUST NAME **THIS ROW**: the generation AND the fingerprint of the
                // accepted static key must be exactly what was DISPLAYED when the user read it. ***
                // *A digest is enough here because it is compared against the ROW's own key inside the same
                // transaction -- so a key that rotated between display and tap produceth a different digest and the
                // CAS refuseth, without this layer ever handling key material.*
                guard current.acceptedGeneration == expectedAcceptedGeneration,
                      ExactRotationCandidateRef.digestHex(current.acceptedStaticDhPublicKey)
                        .lowercased() == expectedFingerprintHex.lowercased() else {
                    throw ConfirmationAbort.stale
                }
                // *** IDEMPOTENCE FOR A ROW ALREADY VERIFIED AT THIS EXACT STATE. ***
                if current.trustLevel == .userVerified {
                    guard let view = VerifiedPeerIdentity.fromRecord(current) else {
                        throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("unable to mint a verified view"))
                    }
                    return .alreadyVerified(view)
                }
                // *** ONLY NOW THE GUARDED PROMOTION, WHICH CANNOT TOUCH ANY OTHER COLUMN. ***
                let affected = try tx.confirmVerifiedGuarded(
                    nodeId: current.nodeId,
                    signingPub: current.signingPublicKey,
                    acceptedStatic: current.acceptedStaticDhPublicKey,
                    acceptedGeneration: Int64(current.acceptedGeneration))
                if affected != 1 {
                    throw ApplyTxnAbort.corrupt(.mutationCardinality(expected: 1, actual: affected))
                }
                guard let readbackRaw = try tx.readRaw(nodeId) else {
                    throw ApplyTxnAbort.corrupt(.missingPostMutationRow)
                }
                let readback: PeerIdentityRecord
                switch decodeRowStrict(readbackRaw) {
                case .success(let rec): readback = rec
                case .failure(let reason): throw ApplyTxnAbort.corrupt(reason)
                }
                let expected = PeerIdentityRecord(
                    nodeId: current.nodeId,
                    signingPublicKey: current.signingPublicKey,
                    acceptedStaticDhPublicKey: current.acceptedStaticDhPublicKey,
                    acceptedGeneration: current.acceptedGeneration,
                    trustLevel: .userVerified,
                    pendingStaticDhPublicKey: nil,
                    pendingGeneration: nil)
                guard readback == expected else {
                    throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("confirmVerified readback mismatch"))
                }
                guard let view = VerifiedPeerIdentity.fromRecord(readback) else {
                    throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("unable to mint a verified view"))
                }
                return .confirmed(view)
            }
        } catch ConfirmationAbort.peerNotFound {
            return .peerNotFound
        } catch ConfirmationAbort.revoked {
            return .revoked
        } catch ConfirmationAbort.quarantined {
            return .quarantined
        } catch ConfirmationAbort.stale {
            return .stale
        } catch let ApplyTxnAbort.corrupt(reason) {
            return .corrupt(reason)
        } catch {
            return .storageFailure
        }
    }

    /**
     * Durably revoke a peer identity inside a serialized write transaction (ADR-003, Phase C8.2C).
     */
    func revokePeer(_ nodeId: Data) -> RevokeResult {
        guard nodeId.count == 16 else {
            return .invalidArgument("nodeId must be exactly 16 bytes, got \(nodeId.count)")
        }

        do {
            return try store.inImmediateTransaction { tx in
                guard let currentRaw = try tx.readRaw(nodeId) else {
                    throw RevokeControlAbort.peerNotFound
                }

                let currentRecord: PeerIdentityRecord
                switch decodeRowStrict(currentRaw) {
                case .success(let rec):
                    currentRecord = rec
                case .failure(let reason):
                    throw ApplyTxnAbort.corrupt(reason)
                }

                if currentRecord.trustLevel == .revoked {
                    throw RevokeControlAbort.alreadyRevoked
                }

                let affected = try tx.revokePeerGuarded(
                    nodeId: currentRecord.nodeId,
                    signingPub: currentRecord.signingPublicKey,
                    acceptedStatic: currentRecord.acceptedStaticDhPublicKey,
                    acceptedGeneration: Int64(currentRecord.acceptedGeneration),
                    currentTrustLevel: Int32(currentRecord.trustLevel.persistedCode),
                    oldPendingStatic: currentRecord.pendingStaticDhPublicKey,
                    oldPendingGeneration: currentRecord.pendingGeneration.map { Int64($0) }
                )
                if affected != 1 {
                    throw ApplyTxnAbort.corrupt(.mutationCardinality(expected: 1, actual: affected))
                }

                guard let readbackRaw = try tx.readRaw(nodeId) else {
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
                    nodeId: currentRecord.nodeId,
                    signingPublicKey: currentRecord.signingPublicKey,
                    acceptedStaticDhPublicKey: currentRecord.acceptedStaticDhPublicKey,
                    acceptedGeneration: currentRecord.acceptedGeneration,
                    trustLevel: .revoked,
                    pendingStaticDhPublicKey: nil,
                    pendingGeneration: nil
                )

                guard readbackRecord == expected else {
                    throw ApplyTxnAbort.corrupt(.mutationReadbackMismatch("RevokePeer readback mismatch"))
                }

                return .revoked
            }
        } catch RevokeControlAbort.peerNotFound {
            return .peerNotFound
        } catch RevokeControlAbort.alreadyRevoked {
            return .alreadyRevoked
        } catch let ApplyTxnAbort.corrupt(reason) {
            return .corrupt(reason)
        } catch {
            return .storageFailure
        }
    }
}
