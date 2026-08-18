import Foundation
import CryptoKit

/// Peer trust level with explicit persistence codes (ADR-003, Phase C8.2A).
///
/// Explicit Int32 codes are used instead of enum ordinals to prevent database
/// reinterpretation across schema evolutions:
/// - tofuPinned = 1
/// - userVerified = 2
/// - revoked = 3
public enum PeerTrustLevel: Int32, Sendable, Equatable {
    case tofuPinned = 1
    case userVerified = 2
    case revoked = 3

    public static func fromPersistedCode(_ code: Int32) -> PeerTrustLevel? {
        PeerTrustLevel(rawValue: code)
    }
}

/// Effective trust state computed from `PeerIdentityRecord` (ADR-003, Phase C8.2A).
///
/// Precedence rule:
/// 1. revoked -> revoked
/// 2. pendingGeneration != nil -> keyChangedQuarantined
/// 3. userVerified -> activeUserVerified
/// 4. tofuPinned -> activeTofu
public enum EffectivePeerTrustState: Sendable, Equatable {
    case activeTofu
    case activeUserVerified
    case keyChangedQuarantined
    case revoked
}

/// Authoritative cryptographic peer identity record (ADR-003, Phase C8.2A).
///
/// Contains only cryptographic trust authority fields. Contact names, metadata,
/// message-store state, and routing hints are strictly prohibited in this model.
public struct PeerIdentityRecord: Sendable, Equatable {
    public let nodeId: Data
    public let signingPublicKey: Data
    public let acceptedStaticDhPublicKey: Data
    public let acceptedGeneration: UInt32
    public let trustLevel: PeerTrustLevel
    public let pendingStaticDhPublicKey: Data?
    public let pendingGeneration: UInt32?

    public init(
        nodeId: Data,
        signingPublicKey: Data,
        acceptedStaticDhPublicKey: Data,
        acceptedGeneration: UInt32,
        trustLevel: PeerTrustLevel,
        pendingStaticDhPublicKey: Data? = nil,
        pendingGeneration: UInt32? = nil
    ) {
        self.nodeId = nodeId
        self.signingPublicKey = signingPublicKey
        self.acceptedStaticDhPublicKey = acceptedStaticDhPublicKey
        self.acceptedGeneration = acceptedGeneration
        self.trustLevel = trustLevel
        self.pendingStaticDhPublicKey = pendingStaticDhPublicKey
        self.pendingGeneration = pendingGeneration
    }

    public var effectiveState: EffectivePeerTrustState {
        if trustLevel == .revoked {
            return .revoked
        } else if pendingGeneration != nil {
            return .keyChangedQuarantined
        } else if trustLevel == .userVerified {
            return .activeUserVerified
        } else {
            return .activeTofu
        }
    }
}

/// Corruption reasons for durable `PeerIdentityRecord` validation (ADR-003, Phase C8.2A).
public enum PeerRecordCorruptionReason: Sendable, Equatable {
    case invalidNodeIdLength
    case invalidSigningKeyLength
    case invalidAcceptedStaticKeyLength
    case acceptedGenerationOutOfRange
    case nodeIdSigningKeyMismatch
    case pendingCouplingViolation
    case invalidPendingStaticKeyLength
    case pendingGenerationOutOfRange
    case pendingNotNewer
    case pendingStaticEqualsAccepted
    case revokedWithPending
}

/// Validation result taxonomy for durable `PeerIdentityRecord` (ADR-003, Phase C8.2A).
public enum PeerIdentityRecordValidationResult: Sendable, Equatable {
    case valid
    case corrupt(PeerRecordCorruptionReason)
}

/// Pure validator enforcing the 11 durable invariants of `PeerIdentityRecord` (ADR-003, Phase C8.2A).
public enum PeerIdentityRecordValidator {
    public static let nodeIdLength = 16
    public static let signingKeyLength = 32
    public static let staticKeyLength = 32

    public static func validate(record: PeerIdentityRecord) -> PeerIdentityRecordValidationResult {
        // R1: nodeId exactly 16 bytes
        guard record.nodeId.count == nodeIdLength else {
            return .corrupt(.invalidNodeIdLength)
        }

        // R2: signingPublicKey exactly 32 bytes
        guard record.signingPublicKey.count == signingKeyLength else {
            return .corrupt(.invalidSigningKeyLength)
        }

        // R3: acceptedStaticDhPublicKey exactly 32 bytes
        guard record.acceptedStaticDhPublicKey.count == staticKeyLength else {
            return .corrupt(.invalidAcceptedStaticKeyLength)
        }

        // R5: nodeId == BLAKE2s-128(signingPublicKey)
        let expectedNodeId = IdentityBindingV1.deriveNodeId(signingPublicKey: record.signingPublicKey)
        guard record.nodeId == expectedNodeId else {
            return .corrupt(.nodeIdSigningKeyMismatch)
        }

        // R6: pendingStaticDhPublicKey and pendingGeneration are BOTH nil or BOTH non-nil
        let pendStatic = record.pendingStaticDhPublicKey
        let pendGen = record.pendingGeneration
        guard (pendStatic == nil) == (pendGen == nil) else {
            return .corrupt(.pendingCouplingViolation)
        }

        // Pending field invariants
        if let pendStatic = pendStatic, let pendGen = pendGen {
            // R11: if trustLevel == revoked, pending fields MUST both be nil
            guard record.trustLevel != .revoked else {
                return .corrupt(.revokedWithPending)
            }

            // R7: pending static exactly 32 bytes
            guard pendStatic.count == staticKeyLength else {
                return .corrupt(.invalidPendingStaticKeyLength)
            }

            // R8: pendingGeneration > acceptedGeneration
            guard pendGen > record.acceptedGeneration else {
                return .corrupt(.pendingNotNewer)
            }

            // R10: pendingStaticDhPublicKey != acceptedStaticDhPublicKey
            guard pendStatic != record.acceptedStaticDhPublicKey else {
                return .corrupt(.pendingStaticEqualsAccepted)
            }
        }

        return .valid
    }
}

/// Rejection reason taxonomy for peer trust evaluation (ADR-003, Phase C8.2A).
public enum PeerTrustRejectReason: Sendable, Equatable {
    case rollback
    case sameGenerationConflict
    case pendingGenerationConflict
    case staleRelativeToPending
    case noncanonicalGenerationAdvance
    case nodeIdSigningKeyCollision
    case revoked
}

/// Pure decision plan emitted by `PeerTrustEngine` (ADR-003, Phase C8.2A).
public enum TrustPlan: Sendable, Equatable {
    case acceptExisting
    case insertFirstSeen
    case setInitialPendingCandidate
    case advancePendingCandidate
    case keepQuarantined
    case reject(PeerTrustRejectReason)
}

/// Read-only view of a verified active peer identity (ADR-003, Phase C8.2A).
public struct VerifiedPeerIdentity: Sendable, Equatable {
    public let nodeId: Data
    public let signingPublicKey: Data
    public let acceptedStaticDhPublicKey: Data
    public let acceptedGeneration: UInt32
    public let trustLevel: PeerTrustLevel

    fileprivate init(
        nodeId: Data,
        signingPublicKey: Data,
        acceptedStaticDhPublicKey: Data,
        acceptedGeneration: UInt32,
        trustLevel: PeerTrustLevel
    ) {
        self.nodeId = nodeId
        self.signingPublicKey = signingPublicKey
        self.acceptedStaticDhPublicKey = acceptedStaticDhPublicKey
        self.acceptedGeneration = acceptedGeneration
        self.trustLevel = trustLevel
    }

    public static func fromRecord(_ record: PeerIdentityRecord) -> VerifiedPeerIdentity? {
        guard case .valid = PeerIdentityRecordValidator.validate(record: record) else {
            return nil
        }
        guard record.trustLevel != .revoked, record.pendingGeneration == nil else {
            return nil
        }
        return VerifiedPeerIdentity(
            nodeId: record.nodeId,
            signingPublicKey: record.signingPublicKey,
            acceptedStaticDhPublicKey: record.acceptedStaticDhPublicKey,
            acceptedGeneration: record.acceptedGeneration,
            trustLevel: record.trustLevel
        )
    }
}

/// Read-only view of a quarantined peer identity with a pending rotation candidate (ADR-003, Phase C8.2A).
public struct PendingPeerIdentity: Sendable, Equatable {
    public let nodeId: Data
    public let signingPublicKey: Data
    public let acceptedStaticDhPublicKey: Data
    public let acceptedGeneration: UInt32
    public let trustLevel: PeerTrustLevel
    public let pendingStaticDhPublicKey: Data
    public let pendingGeneration: UInt32

    fileprivate init(
        nodeId: Data,
        signingPublicKey: Data,
        acceptedStaticDhPublicKey: Data,
        acceptedGeneration: UInt32,
        trustLevel: PeerTrustLevel,
        pendingStaticDhPublicKey: Data,
        pendingGeneration: UInt32
    ) {
        self.nodeId = nodeId
        self.signingPublicKey = signingPublicKey
        self.acceptedStaticDhPublicKey = acceptedStaticDhPublicKey
        self.acceptedGeneration = acceptedGeneration
        self.trustLevel = trustLevel
        self.pendingStaticDhPublicKey = pendingStaticDhPublicKey
        self.pendingGeneration = pendingGeneration
    }

    public static func fromRecord(_ record: PeerIdentityRecord) -> PendingPeerIdentity? {
        guard case .valid = PeerIdentityRecordValidator.validate(record: record) else {
            return nil
        }
        guard record.trustLevel != .revoked,
              let pendStatic = record.pendingStaticDhPublicKey,
              let pendGen = record.pendingGeneration else {
            return nil
        }
        return PendingPeerIdentity(
            nodeId: record.nodeId,
            signingPublicKey: record.signingPublicKey,
            acceptedStaticDhPublicKey: record.acceptedStaticDhPublicKey,
            acceptedGeneration: record.acceptedGeneration,
            trustLevel: record.trustLevel,
            pendingStaticDhPublicKey: pendStatic,
            pendingGeneration: pendGen
        )
    }
}
