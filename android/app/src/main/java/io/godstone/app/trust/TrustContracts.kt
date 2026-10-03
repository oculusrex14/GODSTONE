package io.godstone.app.trust

import java.security.MessageDigest

// ---------------------------------------------------------------------------
// T55 -- the identity verification, rotation and wipe contracts.
//
// The app layer speaketh to the durable trust authority through THIS narrow port
// and nothing else. Two reasons, both load-bearing:
//
//   1. THE SHIPPING APP CARRIETH NO RADIO-ERA EDGE. `:app` depends on `:core`
//      alone; the shipping-path gate refuseth ANY compiled `:app` source that even
//      NAMES the non-shipping mesh product, its node type or its package -- and it
//      is right to be blunt, because a shipping surface must not speak of them at
//      all. So this port is declared here in pure Kotlin, the lab composition
//      bindeth it to the real repository, and the shipping app bindeth
//      [UnavailableTrustPort] and sayeth so truthfully.
//
//      (This paragraph itself was rewritten when that gate caught the first form:
//      naming the forbidden modules in a comment is still naming them.)
//
//   2. THE USER'S APPROVAL IS BOUND TO WHAT THE USER SAW. A rotation approval
//      carrieth an [ExactRotationCandidateRef] -- the node, the generation and the
//      pending key's digest the screen actually displayed -- never "whichever
//      rotation is current now". The durable CAS (mesh's
//      `approvePendingRotation(nodeId, expectedPendingGeneration, expectedKey)`)
//      refuseth a stale candidate; this layer's whole job is to hand it the
//      DISPLAYED one.
//
// No private key material crosseth this file. A fingerprint is a public digest,
// the QR payload carrieth public binding material only, and nothing here is
// logged.
// ---------------------------------------------------------------------------

/**
 * The exact pending rotation the user was shown.
 *
 * It carrieth the pending STATIC DH PUBLIC key itself -- public material -- and
 * not merely a digest of it, BECAUSE THE DURABLE CAS BINDETH ON THE KEY:
 * `approvePendingRotation(nodeId, expectedPendingGeneration,
 * expectedPendingStaticDhPublicKey)` cannot be satisfied by a digest, so a ref
 * that carried one could never approve anything. The digest is DERIVED, for
 * display and comparison only. (T56 found this while building the iOS twin's
 * court; both isles now carry the same three operands the authority binds on.)
 */
data class ExactRotationCandidateRef(
    /** The contact's 16-octet node id. */
    val nodeId: ByteArray,
    /** The pending generation the screen displayed. */
    val pendingGeneration: Long,
    /** The pending static DH public key the screen displayed (32 octets). */
    val pendingStaticDhPublicKey: ByteArray,
) {
    init {
        require(nodeId.size == 16) { "a rotation candidate names a 16-octet node id" }
        require(pendingGeneration >= 0) { "a pending generation is non-negative" }
        require(pendingStaticDhPublicKey.size == 32) { "a pending static key is 32 octets" }
    }

    /** The digest, derived from the key: display and comparison only. */
    val pendingKeyDigestHex: String get() = digestHex(pendingStaticDhPublicKey)

    fun nodeIdCopy(): ByteArray = nodeId.copyOf()
    fun pendingKeyCopy(): ByteArray = pendingStaticDhPublicKey.copyOf()

    /** Two refs name the same candidate only if ALL THREE operands agree. */
    fun sameCandidateAs(other: ExactRotationCandidateRef): Boolean =
        nodeId.contentEquals(other.nodeId) &&
            pendingGeneration == other.pendingGeneration &&
            pendingStaticDhPublicKey.contentEquals(other.pendingStaticDhPublicKey)

    override fun equals(other: Any?): Boolean =
        other is ExactRotationCandidateRef && sameCandidateAs(other)

    override fun hashCode(): Int = nodeId.contentHashCode() * 31 +
        pendingGeneration.hashCode() * 31 + pendingStaticDhPublicKey.contentHashCode()

    override fun toString(): String =
        "ExactRotationCandidateRef(node=${fingerprintOf(nodeId)}, gen=$pendingGeneration, " +
            "key=${pendingKeyDigestHex.take(8)}...)"

    companion object {
        /** SHA-256 hex of an arbitrary byte string (public material only). */
        fun digestHex(bytes: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(bytes)
                .joinToString("") { "%02x".format(it) }

        /** A short, human-comparable rendering of a node id. */
        fun fingerprintOf(bytes: ByteArray): String =
            digestHex(bytes).chunked(4).take(4).joinToString(" ")
    }
}

/** How the app may label a contact's trust. */
enum class ContactTrustLabel {
    /** No durable record at all. */
    UNKNOWN,
    /** Pinned on first use: a key we accepted because we had nothing else. */
    TOFU_UNVERIFIED,
    /**
     * The user compared and confirmed the fingerprint out of band. The NAME is
     * shared verbatim with the iOS isle (T56), so the two courts speak ONE
     * vocabulary -- and a shared fixture meaneth the same thing on both.
     */
    USER_VERIFIED,
    /** The user revoked the contact. */
    REVOKED,
    /** A pending rotation standeth, awaiting the user's decision. */
    ROTATION_PENDING,
    /** The durable record is unreadable: fail closed, claim nothing. */
    CORRUPT,
}

/** One contact, projected from the durable authority for the screen. */
data class ContactProjection(
    val nodeId: ByteArray,
    val label: String,
    val trust: ContactTrustLabel,
    val fingerprintHex: String,
    val acceptedGeneration: Long,
    val pendingRotation: ExactRotationCandidateRef?,
) {
    init {
        require(nodeId.size == 16) { "a contact names a 16-octet node id" }
        require(fingerprintHex.length == 64) { "a fingerprint is 32 octets of hex" }
    }

    fun nodeIdCopy(): ByteArray = nodeId.copyOf()

    /** The exact bytes a compare/confirm command must echo back. */
    val isVerified: Boolean get() = trust == ContactTrustLabel.USER_VERIFIED
    val isTofu: Boolean get() = trust == ContactTrustLabel.TOFU_UNVERIFIED
}

/** The own-identity projection the QR screen shows. */
data class OwnIdentityProjection(
    val nodeId: ByteArray,
    val fingerprintHex: String,
    /** The PUBLIC binding payload a peer's scanner reads. Never key material. */
    val qrPayload: String,
) {
    init {
        require(nodeId.size == 16) { "an identity names a 16-octet node id" }
        require(!qrPayload.contains("PRIVATE")) { "the QR payload carrieth public material only" }
    }

    fun nodeIdCopy(): ByteArray = nodeId.copyOf()
}

/** The resumable wipe state the screen shows. */
sealed class WipeProgressState {
    /** No wipe is known to be in progress. */
    object Idle : WipeProgressState()

    /**
     * A wipe was started and has NOT completed. [attempt] counteth the resume
     * attempts so a screen can say "tried three times"; [resumable] is true while
     * the journal still standeth, which is what maketh a relaunch able to resume.
     */
    data class InProgress(
        val stage: String,
        val attempt: Int,
        val resumable: Boolean,
        val lastError: String? = null,
    ) : WipeProgressState()

    /** The wipe finished: no local estate remaineth. */
    object Complete : WipeProgressState()

    val isResumable: Boolean get() = this is InProgress && resumable

    /**
     * True iff ordinary use must wait. The first form of this said `this !is Idle`
     * and therefore claimed a COMPLETE wipe blocked ordinary use -- the opposite
     * of the truth, and the court's relaunch witness caught it: a finished wipe
     * is exactly when ordinary use may resume.
     */
    val blocksOrdinaryUse: Boolean get() = this is InProgress
}

/** The import outcome, so a failure is never mistaken for a no-op success. */
sealed class BindingImportOutcome {
    data class Imported(val nodeId: ByteArray, val label: String) : BindingImportOutcome()
    data class Refused(val reason: String) : BindingImportOutcome()
}

/** The rotation-approval outcome. */
sealed class RotationApprovalOutcome {
    data class Approved(val nodeId: ByteArray, val acceptedGeneration: Long) : RotationApprovalOutcome()

    /** The candidate the user approved is no longer the pending one: refused. */
    object StaleCandidate : RotationApprovalOutcome()
    object NoPendingCandidate : RotationApprovalOutcome()
    object PeerNotFound : RotationApprovalOutcome()
    object RejectedRevoked : RotationApprovalOutcome()
    data class Refused(val reason: String) : RotationApprovalOutcome()
}

/**
 * *** GS-UX-001 STEP 8 (TrustUiCasBuilder): THE EXACT MATERIAL THE SCREEN DISPLAYED WHEN THE USER TAPPED CONFIRM. ***
 *
 * THE LAW: *a trust decision is made on WHAT THE USER SAW, not on what the durable row happeneth to hold when the tap
 * arriveth.* The screen rendereth a contact's `fingerprintHex` AND its `acceptedGeneration`; a confirmation that
 * carried only the digest could still be promoted against a row whose accepted generation (or pending candidate) had
 * moved underneath the reader -- **the displayed material would no longer name the row it was compared against.**
 *
 * SO THE DISPLAYED OPERANDS TRAVEL WITH THE REQUEST, exactly as [ExactRotationCandidateRef] maketh the displayed
 * rotation candidate travel with an approval. The authority compareth BOTH: the digest AND the accepted generation the
 * reader saw. `displayedStaticDhPublicKey` is deliberately ABSENT -- the app projection carrieth a DERIVED digest, not
 * the key, so the app layer cannot bind on key bytes it was never shown; that operand belongeth to the repository CAS
 * (the rotation path, where the screen really carrieth the key).
 */
data class FingerprintDisplay(
    val nodeId: ByteArray,
    /** The 64-character hex digest the screen printed for this contact. */
    val fingerprintHex: String,
    /** The accepted generation the screen printed beside that digest. */
    val acceptedGeneration: Long,
) {
    init {
        require(nodeId.size == 16) { "a contact names a 16-octet node id" }
        require(fingerprintHex.length == 64) { "a fingerprint is 32 octets of hex" }
    }

    fun nodeIdCopy(): ByteArray = nodeId.copyOf()

    /** The displayed material and a durable row name the SAME thing only if both operands agree. */
    fun sameAsDurableRow(row: ContactProjection): Boolean =
        row.nodeIdCopy().contentEquals(nodeId) &&
            row.acceptedGeneration == acceptedGeneration &&
            row.fingerprintHex.equals(fingerprintHex, ignoreCase = true)
}

/**
 * The fingerprint-confirmation outcome. Promoting first-use trust to VERIFIED is
 * a DURABLE decision, so it goeth through the authority's own compare-and-set --
 * a matching digest and nothing else.
 */
sealed class ConfirmOutcome {
    /** The digest matched and the contact now standeth VERIFIED. */
    data class Confirmed(val nodeId: ByteArray, val acceptedGeneration: Long) : ConfirmOutcome()

    /** The digest did NOT match the durable one: trust is unchanged. */
    object Mismatch : ConfirmOutcome()
    object PeerNotFound : ConfirmOutcome()
    object AlreadyVerified : ConfirmOutcome()
    data class Refused(val reason: String) : ConfirmOutcome()
}

/** The revocation outcome. */
sealed class RevokeOutcome {
    object Revoked : RevokeOutcome()
    object AlreadyRevoked : RevokeOutcome()
    object PeerNotFound : RevokeOutcome()
    data class Refused(val reason: String) : RevokeOutcome()
}

/**
 * The durable trust authority, as the app layer seeth it. The lab bindeth the
 * real repository; the shipping app bindeth [UnavailableTrustPort].
 */
interface TrustPort {
    /** The own public identity (fingerprint + QR payload). */
    fun ownIdentity(): OwnIdentityProjection?

    /** Every contact the durable estate carrieth, or a CORRUPT marker. */
    fun contacts(): TrustCensus

    /** Apply an exact recipient binding imported from a QR payload. */
    fun importBinding(payload: String): BindingImportOutcome

    /**
     * Approve the EXACT pending candidate. The authority refuseth a ref that no
     * longer matcheth its pending row (a CAS on generation + key), which is what
     * maketh "the displayed candidate" a binding instruction rather than a guess.
     * The ref carrieth the pending static PUBLIC key itself because that is what
     * the durable CAS bindeth on -- a digest could not satisfy it.
     */
    fun approveRotation(ref: ExactRotationCandidateRef): RotationApprovalOutcome

    /**
     * Confirm a contact's fingerprint against the DURABLE one and, on a match, promote its trust.
     *
     * *** GS-UX-001 STEP 8: THE REQUEST CARRYeth THE OPERANDS THE READER WAS SHOWN -- `nodeId` (the row),
     * `fingerprintHex` (the digest) and `acceptedGeneration` (the generation printed beside it). *** The authority
     * compare-and-swappeth on ALL of them: a digest that matcheth a row whose accepted generation had already moved
     * beneath the reader promoteth NOTHING, so a confirmation can never be attributed to a row the user never saw.
     */
    fun confirmVerified(request: FingerprintDisplay): ConfirmOutcome

    /** Revoke a contact; its sessions must be invalidated by the authority. */
    fun revoke(nodeId: ByteArray): RevokeOutcome

    /** The current resumable wipe state, read from the journal. */
    fun wipeProgress(): WipeProgressState

    /** Begin (or resume) a wipe. */
    fun beginWipe(): WipeProgressState

    /** Resume an interrupted wipe after a relaunch. */
    fun resumeWipe(): WipeProgressState
}

/** A census of the trust store: readable, corrupt, or unreadable. */
sealed class TrustCensus {
    data class Readable(val contacts: List<ContactProjection>) : TrustCensus()
    data class Corrupt(val reason: String) : TrustCensus()
    data class Unavailable(val reason: String) : TrustCensus()
}

/** The shipping app's honest binding: no lab runtime is installed. */
object UnavailableTrustPort : TrustPort {
    override fun ownIdentity(): OwnIdentityProjection? = null
    override fun contacts(): TrustCensus =
        TrustCensus.Unavailable("the mesh lab is not composed in this build")
    override fun importBinding(payload: String): BindingImportOutcome =
        BindingImportOutcome.Refused("the mesh lab is not composed in this build")
    override fun approveRotation(ref: ExactRotationCandidateRef): RotationApprovalOutcome =
        RotationApprovalOutcome.Refused("the mesh lab is not composed in this build")
    override fun confirmVerified(request: FingerprintDisplay): ConfirmOutcome =
        ConfirmOutcome.Refused("the mesh lab is not composed in this build")
    override fun revoke(nodeId: ByteArray): RevokeOutcome =
        RevokeOutcome.Refused("the mesh lab is not composed in this build")
    override fun wipeProgress(): WipeProgressState = WipeProgressState.Idle
    override fun beginWipe(): WipeProgressState = WipeProgressState.Idle
    override fun resumeWipe(): WipeProgressState = WipeProgressState.Idle
}
