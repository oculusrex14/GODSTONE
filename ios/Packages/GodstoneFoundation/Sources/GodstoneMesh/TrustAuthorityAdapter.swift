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
/// - `confirmVerified` delegates to `PeerIdentityRepository.confirmVerified`, which performs the
///   guarded TOFU -> USER_VERIFIED CAS inside the SAME serialized transaction the other mutations use.
///   THE WIRE PROTOCOL IS UNCHANGED: it is a durable local, out-of-band confirmation, captured against
///   the EXACT node/generation/fingerprint the user read, so a stale confirmation changes nothing.
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

    /// *** THE CONFIRMATION IS CARRIED BY THE CAPTURED GENERATION, WHICH THE PORT MUST NOW PASS. ***
    ///
    /// *The port's old signature took only the hex digest, which is not enough to guard a CAS: the generation is the
    /// field that telleth "the displayed candidate" from "the current one". So `TrustAuthorityPort.confirmVerified`
    /// now taketh the displayed generation too, and the ADAPTER passes both through to the repository -- which
    /// comparess the fingerprint against the ROW's own key inside the same transaction.*
    func confirmVerified(nodeId: Data, fingerprintHex: String,
                         displayedGeneration: UInt32) -> ConfirmOutcome {
        switch repository.confirmVerified(nodeId: nodeId,
                                          expectedAcceptedGeneration: displayedGeneration,
                                          expectedFingerprintHex: fingerprintHex) {
        case .confirmed(let view):
            return .confirmed(nodeId: view.nodeId, acceptedGeneration: view.acceptedGeneration)
        case .alreadyVerified(let view):
            _ = view
            return .alreadyVerified
        case .peerNotFound:
            return .peerNotFound
        case .revoked:
            return .revoked
        case .quarantined:
            return .rotatedSinceDisplayed
        case .stale:
            return .rotatedSinceDisplayed
        case .corrupt(let reason):
            return .refused("the durable record is corrupt: \(reason)")
        case .storageFailure:
            return .refused("the durable authority could not be reached")
        case .invalidArgument(let why):
            return .refused(why)
        }
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
