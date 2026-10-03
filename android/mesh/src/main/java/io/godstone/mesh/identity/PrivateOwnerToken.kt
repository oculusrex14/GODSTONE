package io.godstone.mesh.identity

import io.godstone.mesh.di.PrivateStorePermit
import io.godstone.mesh.di.StartupWipeDecision

/**
 * *** GS-FINAL-003 `one-owner` (A2/A3/A13): THE NORMAL-PRIVATE-OWNER TOKEN -- THE `permit` PARAMETER MADE A VALUE. ***
 *
 * *THE REVIEW'S FINDING A13, VERBATIM: **"Callers can bypass the permit graph using raw private-owner constructors"** --
 * `SqliteMessageStore(Context,maxBytes)`, `Identity.loadOrCreate(Context)` and `SqlcipherPeerIdentityStore(Context)` all
 * remain reachable without ever consulting a permit.* **SO A CALLER COULD OPEN THE VERY STORES A WIPE IS ERASING WHILE THE
 * DAGGER ROAD REFUSED.**
 *
 * *** THE FIX CLOSES THE ORDINARY CONSTRUCTION AT THE OWNER, NOT ONLY AT THE PROVIDER: *** *every raw normal-private
 * construction now REQUIRES this token as a parameter, and the token cannot be constructed anywhere except from a
 * [PrivateStorePermit] -- which itself is minted ONLY from evidence the recovery graph produced over the durable journal,
 * and which is refused once the estate moves.*
 *
 *   * **a bare `:mesh` helper has no permit, so `PrivateOwnerToken.forNormalConstruction(permit)` is out of reach;**
 *   * **a normal runtime constructor has no permit either, because permits exist only where the journal was read;** and
 *   * **a permit minted against one estate cannot admit construction against another, because the token carrieth the
 *     revision it was validated at and the composition re-checks it (`requireLiveFor`).**
 *
 * *** IT IS NOT A SECOND AUTHORITY. *** *It is the PROOF OF CONSUMPTION of the ONE authority: the permit's decision plus
 * the same-estate revision it was judged at. Keeping it as a distinct value is what lets `Identity`, the message store and
 * the peer store -- which live BELOW the composition and must not import Dagger -- enforce the boundary without becoming
 * authorities themselves.*
 */
class PrivateOwnerToken private constructor(
    /** The typed decision the gating permit was issued from -- carried for the construction counter's falsifiable record. */
    val authorizedBy: StartupWipeDecision,
    /** The durable revision the permit was validated at; the composition re-checks this at consumption. */
    internal val estateRevision: String,
) {
    /**
     * *** GS-FINAL-003 `one-owner` (A13): THE CONSUMPTION *AT THE RAW CONSTRUCTOR BOUNDARY* -- NOT ONLY IN DI. ***
     *
     * *THE TICKET'S CLAUSE, EXECUTED: **"Actualconsume atrawprivateidentity/store/provider constructor boundaries
     * EVERYproductionhelper inclrealDagger graph, notDI-only."*** *A gate that liveth ONLY in the Dagger provider is a
     * gate a bare `:mesh` helper walketh past: `provideIdentity` would refuse, while `SqliteMessageStore(ctx, maxBytes,
     * token)` -- reached from anywhere in this module -- would open the very store the wipe is erasing.*
     *
     * **SO EVERY RAW OWNER CONSUMETH THE TOKEN BEFORE IT TOUCHETH A PLATFORM RESOURCE**, *which maketh the check a
     * property of the OWNER rather than of the composition that called it.* **And the one thing this boundary CAN prove
     * without holding a journal is the half the token carrieth: a token exists only for a PERMITTING decision, so an
     * owner can never be opened under a `RECOVERY_PENDING`/`CORRUPT_JOURNAL`/`TERMINAL_FAILURE` authority.** *The
     * estate-generation half is re-checked by the composition ([PrivateStorePermit.requireLiveFor]) at the same instant,
     * because only the composition holds the record.*
     */
    internal fun consumeForConstruction(): PrivateOwnerToken {
        require(authorizedBy.allowsPrivateConstruction) {
            "GS-FINAL-003: a private-owner token must have been minted from a PERMITTING decision; observed " +
                "$authorizedBy. No private owner may be opened under an authority that refused construction."
        }
        return this
    }

    companion object {
        /**
         * *THE ONLY PRODUCER.* **It takes a [PrivateStorePermit] -- not a decision -- so the token cannot exist without
         * the evidence-bound authority that permit represents.**
         */
        fun forNormalConstruction(permit: PrivateStorePermit): PrivateOwnerToken =
            PrivateOwnerToken(permit.issuedFrom, permit.estateRevision)
    }
}
