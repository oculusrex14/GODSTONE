package io.godstone.app.mesh

import io.godstone.app.trust.ContactTrustLabel

// ---------------------------------------------------------------------------
// T57 -- the direct messaging and SOS contracts.
//
// Three laws, and every one of them existeth because the OPPOSITE is easy to
// write and looks fine on a screen:
//
//   1. A STATUS IS PROJECTED FROM THE DURABLE AUTHORITY, NEVER FROM A TRANSPORT
//      ACCEPTANCE. A Boolean `send` proveth only that a radio took some bytes; a
//      message that a link accepted is ATTEMPTING at best, and DELIVERED only when
//      the intended recipient's authenticated ACK committed (T43's law, at the UI
//      layer). "Sent" is not a status this app may show on ATT acceptance.
//
//   2. NOTHING IS "SECURE" OR "CONNECTED" BEFORE THE TRUSTED KEY IS CONFIRMED. A
//      link that is up is not a trusted link, and a peer we have merely pinned is
//      not verified: the compose screen sayeth which of the three it is, and it
//      sayeth it from the durable trust projection, not from a connection flag.
//
//   3. THE SOS ARM IS HELD, NOT TAPPED. A distress call that a pocket can place is
//      a hazard; the control requireth an explicit arm-then-confirm, the ACTIVE
//      call is restored from the durable row after a relaunch, and the cancel
//      nameth the limitation honestly: copies that already left cannot be recalled.
//
// The app layer speaketh to the mesh through [MeshPort] and nothing else, for the
// same reason T55's trust layer did: the shipping app carrieth no radio-era edge,
// so the port is pure Kotlin and the LAB bindeth the real composition.
// ---------------------------------------------------------------------------

/** The DIRECT compose bound: 400 UTF-8 BYTES (not characters). */
object DirectComposePolicy {
    /** The documented budget, in BYTES of UTF-8. */
    const val MAX_BODY_BYTES: Int = 400

    /** Count the UTF-8 bytes a body would occupy. */
    fun byteCount(body: String): Int = body.toByteArray(Charsets.UTF_8).size

    /** True iff the body is empty or whitespace only (nothing to send). */
    fun isBlank(body: String): Boolean = body.isBlank()

    /** True iff the body fits the budget. */
    fun fits(body: String): Boolean = byteCount(body) <= MAX_BODY_BYTES

    /**
     * The longest PREFIX of [body] that fits the budget, cut on a CHARACTER
     * boundary so a multi-byte character is never split into invalid UTF-8.
     */
    fun truncateToFit(body: String): String {
        if (fits(body)) return body
        var end = 0
        for (index in body.indices) {
            val candidate = body.substring(0, index + 1)
            if (byteCount(candidate) > MAX_BODY_BYTES) break
            end = index + 1
        }
        return body.substring(0, end)
    }
}

/** A status the screen may show, projected from the durable authority. */
enum class MessageStatus {
    /** Durably queued and retryable; no link hath taken it yet. */
    QUEUED,
    /** A link took the bytes (an ATT acceptance) and NOTHING more is claimed. */
    ATTEMPTING,
    /** The intended recipient's authenticated ACK committed. The only delivery. */
    DELIVERED,
    /** The user cancelled it locally. */
    CANCELLED,
    /** It expired under the retention law. */
    EXPIRED,
    /** The authority refused it (storage, binding, or an unrecognised row). */
    FAILED,
}

/** One conversation row, projected for the screen. */
data class MessageProjection(
    val msgId: ByteArray,
    val peerLabel: String,
    val body: String,
    val status: MessageStatus,
    val outgoing: Boolean,
    val retryable: Boolean,
    val authorityNote: String? = null,
) {
    init {
        require(msgId.size == 16) { "a message names a 16-octet msg_id" }
    }

    fun msgIdCopy(): ByteArray = msgId.copyOf()

    /** True iff the screen may say a recipient received it. */
    val claimsDelivery: Boolean get() = status == MessageStatus.DELIVERED
}

/** The trust state of the SELECTED recipient, as the compose screen seeth it. */
data class RecipientProjection(
    val nodeId: ByteArray,
    val label: String,
    val trust: ContactTrustLabel,
) {
    init {
        require(nodeId.size == 16) { "a recipient names a 16-octet node id" }
    }

    fun nodeIdCopy(): ByteArray = nodeId.copyOf()

    /** True only for a contact the user personally compared and confirmed. */
    val isVerified: Boolean get() = trust == ContactTrustLabel.USER_VERIFIED

    /** True only when a trusted key standeth (verified or first-use pinned). */
    val hasTrustedKey: Boolean
        get() = trust == ContactTrustLabel.USER_VERIFIED || trust == ContactTrustLabel.TOFU_UNVERIFIED
}

/** The link's state, with the words the screen may use for it. */
sealed class LinkState {
    object Offline : LinkState()
    object Scanning : LinkState()
    /** A radio link is up to somebody -- NOT necessarily a trusted peer. */
    data class Connected(val peers: Int) : LinkState()
    object PermissionDenied : LinkState()
    object Unsupported : LinkState()

    /** The honest one-line explanation, or null when nothing needeth saying. */
    val explanation: String?
        get() = when (this) {
            is Offline -> "No radio link. Your message stays queued and is retried."
            is Scanning -> "Looking for peers nearby."
            is Connected -> null
            is PermissionDenied ->
                "Godstone cannot reach the radio: the nearby-devices permission was denied. " +
                    "Messages stay queued until it is granted in Settings."
            is Unsupported ->
                "This device's Bluetooth is off or unsupported, so messages cannot leave it. " +
                    "They stay queued on this phone."
        }
}

/** The active-SOS projection: restored from the durable row, never from memory. */
data class SosProjection(
    val msgId: ByteArray,
    val status: MessageStatus,
    val relayCopiesMayBeOut: Boolean,
) {
    init {
        require(msgId.size == 16)
    }

    fun msgIdCopy(): ByteArray = msgId.copyOf()

    /** The honest words for cancelling a call whose copies may already be out. */
    val cancelExplanation: String
        get() = if (relayCopiesMayBeOut) {
            "Cancelling stops this phone retrying. Copies already handed to relays cannot be recalled."
        } else {
            "Cancelling stops this phone retrying. No copy has left this device yet."
        }
}

/** Everything the user can ask for on the messaging surface. */
sealed class MeshCommand {
    /** Refresh from the durable authority. */
    object Refresh : MeshCommand()

    /** Select the exact recipient a DIRECT message is bound to. */
    data class SelectRecipient(val nodeId: ByteArray) : MeshCommand()

    /** Type into the compose field (the bound is applied on send). */
    data class Draft(val body: String) : MeshCommand()

    /** Send the draft as a DIRECT message to the selected recipient. */
    object SendDirect : MeshCommand()

    /** Retry a queued message. */
    data class Retry(val msgId: ByteArray) : MeshCommand()

    /** Arm the SOS control (the first half of hold-to-confirm). */
    object ArmSos : MeshCommand()

    /** Confirm the armed SOS (the second half). A bare tap never reacheth here. */
    object ConfirmSos : MeshCommand()

    /** Disarm without sending. */
    object DisarmSos : MeshCommand()

    /** Cancel the active call durably. */
    data class CancelSos(val msgId: ByteArray) : MeshCommand()

    /** Restore the active call from the durable row (a relaunch path). */
    object RestoreActiveSos : MeshCommand()

    /** Acknowledge an error so it leaveth the screen. */
    object ClearError : MeshCommand()
}

/** The immutable projection the Compose layer rendereth. */
// ---------------------------------------------------------------------------
// *** GS-UX-001 STEP 6 (round 542): *'Apply protected-data unavailability and permission explanations FROM ACTUAL
// PLATFORM STATE.'* ***
//
// MEASURED BEFORE THIS EDIT: the iOS isle hath carried `ProtectedDataGate` (in `TrustUXModel`) since the model was
// written, and **THE ANDROID ISLE CARRIED NOTHING** -- a grep for any protected-data concept across
// `android/app/src/main` returned NOTHING. **A CONTRACT THE HUMAN'S LAW REQUIREth ON BOTH ISLES WAS MET ON ONE.**
//
// AND THE GATE IS A SEAM RATHER THAN A CALL INTO THE FRAMEWORK, FOR THE SAME REASON THE iOS ONE IS: the model
// stayeth HOST-TESTABLE, and the app injecteth a gate that readeth the REAL platform state
// (`KeyguardManager.isDeviceLocked` / the credential-encrypted storage state). A model that called the framework
// directly could not be driven in a court at all.
// ---------------------------------------------------------------------------
interface ProtectedDataGate {
    /** Whether the platform's protected storage is readable RIGHT NOW. */
    fun isProtectedDataAvailable(): Boolean
}

/** The always-available gate: the default, so nothing that stood before changeth behaviour. */
object AlwaysAvailableProtectedData : ProtectedDataGate {
    override fun isProtectedDataAvailable(): Boolean = true
}

data class MeshUiState(
    val link: LinkState,
    val recipients: List<RecipientProjection>,
    val selectedRecipient: RecipientProjection?,
    val draft: String,
    val draftBytes: Int,
    val messages: List<MessageProjection>,
    val sos: SosProjection?,
    val sosArmed: Boolean,
    /**
     * *** GS-UX-001 STEP 6: WHETHER PROTECTED DATA IS AVAILABLE, AS THE PLATFORM ANSWERETH. *** The screen sayeth so
     * rather than showing an empty estate that looketh like an empty archive -- **AN UNAVAILABLE STORE AND AN EMPTY
     * ONE MUST NOT READ THE SAME.**
     */
    val protectedDataAvailable: Boolean,
    /**
     * *** GS-FINAL-009 (the independent audit, 2026-09-18): THE TYPED UNAVAILABLE STATE. ***
     *
     * THE AUDIT'S OWN CLAUSE, WHICH THIS FIELD EXISTETH TO SATISFY: *"an unavailable protected store must NOT be read
     * as an empty one."* `protectedDataAvailable == false` with EMPTY LISTS is ambiguous to a screen: it looketh
     * exactly like "you have no contacts", WHICH IS A LIE THAT LOOKS LIKE A STATE. This flag maketh the two states
     * distinguishable BY TYPE rather than by the reader's care.
     *
     * IT DEFAULTS TO `false`, so a state built before this field existed still compiles AND still meaneth what it
     * meant: an ordinary projection is not an unavailable one.
     */
    val protectedUnavailable: Boolean = false,
    val error: String?,
    val lastOutcome: String?,
    val revision: Long,
) {
    companion object {
        val EMPTY = MeshUiState(
            link = LinkState.Offline, recipients = emptyList(), selectedRecipient = null,
            draft = "", draftBytes = 0, messages = emptyList(), sos = null, sosArmed = false,
            protectedDataAvailable = true, protectedUnavailable = false,
            error = null, lastOutcome = null, revision = 0,
        )
    }

    /** True iff the compose control may send. */
    val canSend: Boolean
        get() = selectedRecipient != null && !DirectComposePolicy.isBlank(draft) &&
            DirectComposePolicy.fits(draft)

    /**
     * True iff the screen may call this conversation secure. A link that is up is
     * not enough, and a merely pinned peer is not enough: the key must have been
     * CONFIRMED by the user.
     */
    val isSecure: Boolean get() = selectedRecipient?.isVerified == true

    /** The honest words for the security chip. */
    val securitySummary: String
        get() = when {
            selectedRecipient == null -> "No recipient selected."
            isSecure -> "Secure: you verified this contact's key yourself."
            selectedRecipient!!.trust == ContactTrustLabel.TOFU_UNVERIFIED ->
                "Not verified: this contact's key was pinned on first use. " +
                    "Comparing fingerprints is what maketh it secure."
            selectedRecipient!!.trust == ContactTrustLabel.REVOKED ->
                "Blocked: this contact was revoked."
            else -> "No trusted key for this contact yet."
        }

    /** The remaining byte budget for the compose field. */
    val bytesRemaining: Int get() = DirectComposePolicy.MAX_BODY_BYTES - draftBytes
}

/** The outcome of asking the authority to send or retry. */
sealed class SendOutcome {
    /** The authority durably queued it. NOT a delivery, and not even an attempt yet. */
    data class Queued(val msgId: ByteArray) : SendOutcome()
    data class Refused(val reason: String) : SendOutcome()
}

sealed class RetryOutcome {
    data class Accepted(val msgId: ByteArray) : RetryOutcome()
    data class Refused(val reason: String) : RetryOutcome()
}

sealed class SosOutcome {
    /** The call was durably enqueued locally. Copies may leave later. */
    data class Enqueued(val msgId: ByteArray) : SosOutcome()
    data class Cancelled(val relayCopiesMayBeOut: Boolean) : SosOutcome()
    data class AlreadyCancelled(val relayCopiesMayBeOut: Boolean?) : SosOutcome()
    data class Refused(val reason: String) : SosOutcome()
}

/**
 * The mesh as the app layer seeth it. The LAB bindeth the real composition; the
 * shipping app bindeth [UnavailableMeshPort] and sayeth so.
 */
interface MeshPort {
    /** The link's state (and why it is not up, when it is not). */
    fun linkState(): LinkState

    /** The contacts a DIRECT message may be addressed to, with their trust. */
    fun recipients(): List<RecipientProjection>

    /** Every message the durable estate carrieth, for the conversation view. */
    fun messages(): List<MessageProjection>

    /** The active SOS, restored from the durable row (null when no call standeth). */
    fun activeSos(): SosProjection?

    /** Durably enqueue a DIRECT message; the body must already fit the budget. */
    fun sendDirect(recipientNodeId: ByteArray, body: String): SendOutcome

    /** Resume a queued message. */
    fun retry(msgId: ByteArray): RetryOutcome

    /** Durably enqueue an SOS call. */
    fun beginSos(body: String): SosOutcome

    /** Durably cancel a call, reporting whether copies may already be out. */
    fun cancelSos(msgId: ByteArray): SosOutcome
}

/** The shipping app's honest binding: no lab runtime is installed. */
object UnavailableMeshPort : MeshPort {
    override fun linkState(): LinkState = LinkState.Offline
    override fun recipients(): List<RecipientProjection> = emptyList()
    override fun messages(): List<MessageProjection> = emptyList()
    override fun activeSos(): SosProjection? = null
    override fun sendDirect(recipientNodeId: ByteArray, body: String): SendOutcome =
        SendOutcome.Refused("the mesh lab is not composed in this build")
    override fun retry(msgId: ByteArray): RetryOutcome =
        RetryOutcome.Refused("the mesh lab is not composed in this build")
    override fun beginSos(body: String): SosOutcome =
        SosOutcome.Refused("the mesh lab is not composed in this build")
    override fun cancelSos(msgId: ByteArray): SosOutcome =
        SosOutcome.Refused("the mesh lab is not composed in this build")
}
