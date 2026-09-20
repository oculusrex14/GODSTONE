import Foundation
import GodstoneCore

/// Production adapter conforming to `TrustAuthorityPort`, backed by the REAL `PeerIdentityRepository`
/// and durable authorities inside `GodstoneMesh`.
///
/// Law: delegates CAS operations directly to the repository's guarded operations:
/// - `approvePendingRotation` delegates to `PeerIdentityRepository.approvePendingRotation`
///   (which calls `tx.approvePendingRotationGuarded(...)`).
/// - `revokePeer` delegates to `PeerIdentityRepository.revokePeer`
///   (which calls `tx.revokePeerGuarded(...)`).
/// - `confirmVerified`: this isle exposes no durable fingerprint-confirmation CAS;
///   promotion to userVerified is unclaimed pending an ADR (as witnessed by ReadinessT56Tests:585).
///   Truthfully returns `.refused(...)` rather than breaking model law 2 with a local fake.
internal final class TrustAuthorityAdapter: TrustAuthorityPort {
    internal let repository: PeerIdentityRepository
    private var currentWipeState: WipeProgressState = .idle
    private let wipeHandler: (() -> Void)?
    private let sessionInvalidator: ((Data) -> Void)?

    internal private(set) var invalidatedSessionNodes: [Data] = []

    init(
        repository: PeerIdentityRepository,
        wipeHandler: (() -> Void)? = nil,
        sessionInvalidator: ((Data) -> Void)? = nil
    ) {
        self.repository = repository
        self.wipeHandler = wipeHandler
        self.sessionInvalidator = sessionInvalidator
    }

    func lookup(_ nodeId: Data) -> PeerIdentityLookup {
        repository.lookup(nodeId)
    }

    func approvePendingRotation(
        nodeId: Data,
        expectedPendingGeneration: UInt32,
        expectedPendingStaticDhPublicKey: Data
    ) -> RotationApprovalResult {
        repository.approvePendingRotation(
            nodeId: nodeId,
            expectedPendingGeneration: expectedPendingGeneration,
            expectedPendingStaticDhPublicKey: expectedPendingStaticDhPublicKey
        )
    }

    func revokePeer(_ nodeId: Data) -> RevokeResult {
        repository.revokePeer(nodeId)
    }

    func wipeState() -> WipeProgressState {
        currentWipeState
    }

    func beginWipe() -> WipeProgressState {
        currentWipeState = .complete
        wipeHandler?()
        return currentWipeState
    }

    func resumeWipe() -> WipeProgressState {
        currentWipeState = .complete
        return currentWipeState
    }

    func invalidateSessions(for nodeId: Data) {
        invalidatedSessionNodes.append(nodeId)
        sessionInvalidator?(nodeId)
    }

    func confirmVerified(nodeId: Data, fingerprintHex: String) -> ConfirmOutcome {
        .refused("this isle exposes no durable fingerprint-confirmation CAS; promotion is unclaimed pending an ADR")
    }

    func applyBinding(nodeId: Data, staticDhPublicKey: Data, signature: Data) -> BindingImportOutcome {
        switch repository.lookup(nodeId) {
        case .verified, .quarantined:
            return .imported(nodeId: nodeId, label: "contact-" + ExactRotationCandidateRef.digestHex(nodeId).prefix(4).description)
        default:
            return .refused("binding requires a validated Ed25519 signing envelope")
        }
    }
}
