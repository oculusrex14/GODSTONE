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
    // ------------------------------------------------------------------------------------------------
    // *** GS-FINAL-003 `true-recovery-topology`: THE TRUST SURFACE'S WIPE IS THE DURABLE LADDER'S, NOT A FLAG'S. ***
    //
    // *MEASURED BEFORE THIS EDIT, AND IT IS THE FINDING'S SENTENCE EXACTLY:* `beginWipe()` set `currentWipeState =
    // .complete` and THEN called the handler -- **so the trust surface CLAIMED A COMPLETED WIPE BEFORE ANYTHING WAS
    // ATTEMPTED, and `resumeWipe()` returned `.complete` WITHOUT CALLING ANYTHING AT ALL.** *"A plausible-looking
    // success over no effect" is the shape this repository's own doctrine names as the worst kind, and it is
    // indistinguishable from the real thing at every surface that reads `wipeState()`.*
    //
    // **THE HANDLER NOW ANSWERS WITH THE TYPED OUTCOME OF A REAL DRIVE**, *and the progress state is DERIVED FROM THAT
    // ANSWER rather than asserted beside it:*
    ///
    //   * `.complete` ONLY when `RecoveryLadderOutcome.isComplete` -- the durable rung ran to its end **and** nothing it
    //     was to delete survived (both halves, measured);
    //   * `.inProgress(stage: ..., resumable: true, lastError: ...)` otherwise, CARRYING THE RUNG AND THE REASON, so a
    //     surface can say WHERE the wipe stands and WHY it stopped -- which is what `blocksOrdinaryUse` needs and what a
    //     bare `.complete` could never express;
    //   * and an unwired handler is a NAMED, NON-RESUMABLE pending state rather than a silent completion: *a facade with
    //     no recovery owner has performed no wipe, and saying otherwise is the defect above.*
    private let wipeHandler: (() -> RecoveryLadderOutcome)?
    private let sessionInvalidator: ((Data) -> Void)?

    internal private(set) var invalidatedSessionNodes: [Data] = []

    init(
        repository: PeerIdentityRepository,
        wipeHandler: (() -> RecoveryLadderOutcome)? = nil,
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

    /// *** THE FRESH WIPE: DRIVE THE DURABLE LADDER, THEN REPORT WHAT IT ACTUALLY LEFT. ***
    func beginWipe() -> WipeProgressState {
        guard let wipeHandler else {
            // A FACADE WITH NO RECOVERY OWNER HAS WIPED NOTHING, and it may not say otherwise.
            currentWipeState = .inProgress(
                stage: "no-recovery-owner", attempt: 1, resumable: false,
                lastError: "this trust surface carries no recovery owner; no wipe was performed")
            return currentWipeState
        }
        currentWipeState = Self.progress(from: wipeHandler())
        return currentWipeState
    }

    /// *** AND THE RESUME IS A REAL RESUME, NOT A SECOND `.complete`. ***
    ///
    /// *THE ROAD THAT STOOD HERE RETURNED `.complete` WITHOUT CALLING ANYTHING -- so a crash mid-wipe, resumed through
    /// this surface, was reported as finished while the journal still stood outstanding. The handler's outcome is now
    /// the ONLY thing that may say `complete`.*
    func resumeWipe() -> WipeProgressState {
        guard let wipeHandler else {
            currentWipeState = .inProgress(
                stage: "no-recovery-owner", attempt: 1, resumable: false,
                lastError: "this trust surface carries no recovery owner; no wipe could be resumed")
            return currentWipeState
        }
        currentWipeState = Self.progress(from: wipeHandler())
        return currentWipeState
    }

    /// *** THE ONE PLACE A `WipeProgressState` IS DERIVED -- FROM THE TYPED OUTCOME, NEVER FROM AN ASSERTION. ***
    ///
    /// *`isComplete` requireth BOTH the durable rung and the filesystem, so `complete` cannot be rendered over a store
    /// that still stands. Every other outcome is `.inProgress` CARRYING THE RUNG AND THE REASON, which is what a
    /// surface needs to say where the wipe stands -- and what `blocksOrdinaryUse` reads to refuse ordinary work while
    /// an unfinished wipe owns the estate.*
    static func progress(from outcome: RecoveryLadderOutcome) -> WipeProgressState {
        if outcome.isComplete { return .complete }
        let stage = outcome.rungs.last
            ?? (outcome.decision == .cleanStart ? "none-outstanding" : outcome.decision.name)
        return .inProgress(
            stage: stage,
            attempt: 1,
            // A PENDING OR RETRYABLE OUTCOME IS RESUMPTABLE; a corrupt record or a policy refusal is NOT -- retrying
            // cannot make an unparseable value parse, and the audit's own distinction is exactly this one.
            resumable: outcome.decision.permitsRecoveryConstruction,
            lastError: outcome.decision.refusalReason
        )
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
