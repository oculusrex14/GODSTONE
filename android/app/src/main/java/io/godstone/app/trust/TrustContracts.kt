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

/** The exact pending rotation the user was shown. */
data class ExactRotationCandidateRef(
    /** The contact's 16-octet node id. */
    val nodeId: ByteArray,
    /** The pending generation the screen displayed. */
    val pendingGeneration: Long,
    /** SHA-256 of the pending static DH public key the screen displayed. */
    val pendingKeyDigestHex: String,
    /** When the candidate was first observed (monotonic), for ordering only. */
    val firstSeenMonoMillis: Long,
) {
    init {
        require(nodeId.size == 16) { "a rotation candidate names a 16-octet node id" }
        require(pendingGeneration >= 0) { "a pending generation is non-negative" }
        require(pendingKeyDigestHex.length == 64) { "a key digest is 32 octets of hex" }
    }

    fun nodeIdCopy(): ByteArray = nodeId.copyOf()

    /** Two refs name the same candidate only if ALL THREE fields agree. */
    fun sameCandidateAs(other: ExactRotationCandidateRef): Boolean =
        nodeId.contentEquals(other.nodeId) &&
            pendingGeneration == other.pendingGeneration &&
            pendingKeyDigestHex == other.pendingKeyDigestHex

    override fun equals(other: Any?): Boolean =
        other is ExactRotationCandidateRef && sameCandidateAs(other) &&
            firstSeenMonoMillis == other.firstSeenMonoMillis

    override fun hashCode(): Int = nodeId.contentHashCode() * 31 +
        pendingGeneration.hashCode() * 31 + pendingKeyDigestHex.hashCode()

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
    /** The user compared and confirmed the fingerprint out of band. */
    VERIFIED,
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
    val isVerified: Boolean get() = trust == ContactTrustLabel.VERIFIED
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
     */
    fun approveRotation(ref: ExactRotationCandidateRef): RotationApprovalOutcome

    /**
     * Confirm a contact's fingerprint against the DURABLE one and, on a match,
     * promote its trust. The authority compareth; a mismatch promoteth nothing.
     */
    fun confirmVerified(nodeId: ByteArray, fingerprintHex: String): ConfirmOutcome

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
    override fun confirmVerified(nodeId: ByteArray, fingerprintHex: String): ConfirmOutcome =
        ConfirmOutcome.Refused("the mesh lab is not composed in this build")
    override fun revoke(nodeId: ByteArray): RevokeOutcome =
        RevokeOutcome.Refused("the mesh lab is not composed in this build")
    override fun wipeProgress(): WipeProgressState = WipeProgressState.Idle
    override fun beginWipe(): WipeProgressState = WipeProgressState.Idle
    override fun resumeWipe(): WipeProgressState = WipeProgressState.Idle
}
