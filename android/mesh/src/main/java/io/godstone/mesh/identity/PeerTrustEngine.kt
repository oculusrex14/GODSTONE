package io.godstone.mesh.identity

/**
 * Pure, deterministic peer trust decision engine (ADR-003, Phase C8.2A).
 *
 * Evaluates an incoming cryptographically [ValidatedPeerBinding] against the currently stored
 * [PeerIdentityRecord] (if any) and returns a [TrustPlan].
 *
 * Invariants:
 * - Pure function: zero side-effects, zero timestamps, zero SQL/storage dependencies.
 * - Input authority: consumes strictly [ValidatedPeerBinding] from the C8.1A validator.
 * - First-seen rule: any validated uint32 generation is a valid initial TOFU baseline.
 * - Revocation precedence: revoked records reject all incoming bindings unconditionally.
 * - Quarantine rule: while a rotation candidate is pending, accepted reconnects return KeepQuarantined.
 */
internal object PeerTrustEngine {

    fun evaluate(
        binding: ValidatedPeerBinding,
        current: PeerIdentityRecord?
    ): TrustPlan {
        // 1. FIRST-SEEN: No existing record for this node ID
        if (current == null) {
            return TrustPlan.InsertFirstSeen
        }

        // 2. REVOCATION PRECEDENCE: Revoked records reject all incoming bindings
        if (current.trustLevel == PeerTrustLevel.REVOKED) {
            return TrustPlan.Reject(PeerTrustRejectReason.Revoked)
        }

        // 3. SIGNING-KEY COLLISION: Node ID matches but signing public key differs
        val incomingSigningPub = binding.signingPublicKey
        if (!incomingSigningPub.contentEquals(current.signingPublicKey)) {
            return TrustPlan.Reject(PeerTrustRejectReason.NodeIdSigningKeyCollision)
        }

        val gen = binding.generation
        val incomingStatic = binding.staticDhPublicKey
        val accGen = current.acceptedGeneration
        val accStatic = current.acceptedStaticDhPublicKey
        val pendGen = current.pendingGeneration
        val pendStatic = current.pendingStaticDhPublicKey

        // 4. NO PENDING CANDIDATE
        if (pendGen == null || pendStatic == null) {
            return when {
                gen == accGen && incomingStatic.contentEquals(accStatic) -> TrustPlan.AcceptExisting
                gen < accGen -> TrustPlan.Reject(PeerTrustRejectReason.Rollback)
                gen == accGen && !incomingStatic.contentEquals(accStatic) -> TrustPlan.Reject(PeerTrustRejectReason.SameGenerationConflict)
                gen > accGen && incomingStatic.contentEquals(accStatic) -> TrustPlan.Reject(PeerTrustRejectReason.NoncanonicalGenerationAdvance)
                else -> TrustPlan.SetInitialPendingCandidate
            }
        }

        // 5. PENDING CANDIDATE PRESENT
        return when {
            // 5.1 Rollback below accepted generation
            gen < accGen -> TrustPlan.Reject(PeerTrustRejectReason.Rollback)

            // 5.2 Equal to accepted generation
            gen == accGen -> {
                if (incomingStatic.contentEquals(accStatic)) {
                    TrustPlan.KeepQuarantined
                } else {
                    TrustPlan.Reject(PeerTrustRejectReason.SameGenerationConflict)
                }
            }

            // 5.3 Intermediate generation (A < gen < P)
            gen < pendGen -> TrustPlan.Reject(PeerTrustRejectReason.StaleRelativeToPending)

            // 5.4 Equal to pending generation (gen == P)
            gen == pendGen -> {
                if (incomingStatic.contentEquals(pendStatic)) {
                    TrustPlan.KeepQuarantined
                } else {
                    TrustPlan.Reject(PeerTrustRejectReason.PendingGenerationConflict)
                }
            }

            // 5.5 Newer than pending generation (gen > P)
            else -> {
                if (incomingStatic.contentEquals(accStatic) || incomingStatic.contentEquals(pendStatic)) {
                    TrustPlan.Reject(PeerTrustRejectReason.NoncanonicalGenerationAdvance)
                } else {
                    TrustPlan.AdvancePendingCandidate
                }
            }
        }
    }
}
