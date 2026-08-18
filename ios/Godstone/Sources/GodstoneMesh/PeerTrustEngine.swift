import Foundation

/// Pure, deterministic peer trust decision engine (ADR-003, Phase C8.2A).
///
/// Evaluates an incoming cryptographically `ValidatedPeerBinding` against the currently stored
/// `PeerIdentityRecord` (if any) and returns a `TrustPlan`.
///
/// Invariants:
/// - Pure function: zero side-effects, zero timestamps, zero SQL/storage dependencies.
/// - Input authority: consumes strictly `ValidatedPeerBinding` from the C8.1A validator.
/// - First-seen rule: any validated uint32 generation is a valid initial TOFU baseline.
/// - Revocation precedence: revoked records reject all incoming bindings unconditionally.
/// - Quarantine rule: while a rotation candidate is pending, accepted reconnects return keepQuarantined.
enum PeerTrustEngine {

    static func evaluate(
        binding: ValidatedPeerBinding,
        current: PeerIdentityRecord?
    ) -> TrustPlan {
        // 1. FIRST-SEEN: No existing record for this node ID
        guard let current = current else {
            return .insertFirstSeen
        }

        // 2. REVOCATION PRECEDENCE: Revoked records reject all incoming bindings
        guard current.trustLevel != .revoked else {
            return .reject(.revoked)
        }

        // 3. SIGNING-KEY COLLISION: Node ID matches but signing public key differs
        let incomingSigningPub = binding.signingPublicKey
        guard incomingSigningPub == current.signingPublicKey else {
            return .reject(.nodeIdSigningKeyCollision)
        }

        let gen = binding.generation
        let incomingStatic = binding.staticDhPublicKey
        let accGen = current.acceptedGeneration
        let accStatic = current.acceptedStaticDhPublicKey
        let pendGen = current.pendingGeneration
        let pendStatic = current.pendingStaticDhPublicKey

        // 4. NO PENDING CANDIDATE
        guard let pendGen = pendGen, let pendStatic = pendStatic else {
            if gen == accGen && incomingStatic == accStatic {
                return .acceptExisting
            } else if gen < accGen {
                return .reject(.rollback)
            } else if gen == accGen && incomingStatic != accStatic {
                return .reject(.sameGenerationConflict)
            } else if gen > accGen && incomingStatic == accStatic {
                return .reject(.noncanonicalGenerationAdvance)
            } else {
                return .setInitialPendingCandidate
            }
        }

        // 5. PENDING CANDIDATE PRESENT
        // 5.1 Rollback below accepted generation
        if gen < accGen {
            return .reject(.rollback)
        }

        // 5.2 Equal to accepted generation
        if gen == accGen {
            if incomingStatic == accStatic {
                return .keepQuarantined
            } else {
                return .reject(.sameGenerationConflict)
            }
        }

        // 5.3 Intermediate generation (A < gen < P)
        if gen < pendGen {
            return .reject(.staleRelativeToPending)
        }

        // 5.4 Equal to pending generation (gen == P)
        if gen == pendGen {
            if incomingStatic == pendStatic {
                return .keepQuarantined
            } else {
                return .reject(.pendingGenerationConflict)
            }
        }

        // 5.5 Newer than pending generation (gen > P)
        if incomingStatic == accStatic || incomingStatic == pendStatic {
            return .reject(.noncanonicalGenerationAdvance)
        } else {
            return .advancePendingCandidate
        }
    }
}
