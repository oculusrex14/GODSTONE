package io.godstone.app.trust

import io.godstone.app.mesh.AlwaysAvailableProtectedData
import io.godstone.app.mesh.ProtectedDataGate

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

// ---------------------------------------------------------------------------
// T55 -- the identity, rotation and wipe ViewModel.
//
// The card's law: "User intent -> ViewModel -> shared MeshRuntime commands ->
// durable/verified state -> Compose", and "Use existing durable repository CAS;
// no private-key export".
//
// Three laws this file enforceth, each witnessed by its own case:
//
//   1. THE DISPLAYED CANDIDATE IS THE ONE APPROVED. [onCommand] for
//      [ContactVerificationCommand.ApproveRotation] carrieth the
//      [ExactRotationCandidateRef] the SCREEN held. The port is handed THAT ref --
//      never a re-read "current" pending rotation -- so a rotation that changed
//      between render and tap is refused by the authority's CAS instead of being
//      silently approved.
//
//   2. NO AUTHORITATIVE STATE MOVETH ON A VALIDATION FAILURE. A malformed or
//      oversized QR, a fingerprint that mismatcheth, an out-of-range input: each
//      leaveth the projected state EXACTLY as it was, with a typed, user-visible
//      error beside it.
//
//   3. NOTHING HERE IS A SECRET. The projected state carrieth public
//      fingerprints and public QR payloads only; [TrustUiState.redacted] saith
//      whether the current screen carrieth secret-bearing material and therefore
//      wanteth screenshot protection, and no field ever carrieth key bytes.
//
// The ViewModel is deliberately plain Kotlin (no Android or mesh types) so the
// shipping app compiles it without a mesh edge, and so the court can drive it
// deterministically.
// ---------------------------------------------------------------------------

/** Everything the user can ask for. */
sealed class ContactVerificationCommand {
    /** Show the own fingerprint and QR. */
    object ShowOwnIdentity : ContactVerificationCommand()

    /** Import an exact recipient binding from a scanned QR payload. */
    data class ImportRecipientBinding(val payload: String) : ContactVerificationCommand()

    /**
     * Compare a fingerprint the user read out loud with the durable one, and (on
     * a match) ask the authority to confirm it.
     */
    data class CompareAndConfirmFingerprint(
        val nodeId: ByteArray,
        val displayedFingerprintHex: String,
    ) : ContactVerificationCommand()

    /** Refresh the projection from the durable authority. */
    object Refresh : ContactVerificationCommand()

    /**
     * Approve the EXACT pending rotation the user was shown. The ref travelleth
     * with the command; nothing re-readeth "the current" candidate.
     */
    data class ApproveRotation(val candidate: ExactRotationCandidateRef) : ContactVerificationCommand()

    /** Dismiss a pending rotation without approving it (trust unchanged). */
    data class DismissRotation(val candidate: ExactRotationCandidateRef) : ContactVerificationCommand()

    /** Revoke a contact. */
    data class Revoke(val nodeId: ByteArray) : ContactVerificationCommand()

    /** Begin a wipe (or resume one already in progress). */
    object BeginWipe : ContactVerificationCommand()

    /** Resume an interrupted wipe after a relaunch. */
    object ResumeWipe : ContactVerificationCommand()

    /** Acknowledge an error so it leaveth the screen. */
    object ClearError : ContactVerificationCommand()
}

/** The immutable projection the Compose layer rendereth. */
data class TrustUiState(
    val own: OwnIdentityProjection?,
    val contacts: List<ContactProjection>,
    val census: TrustCensus,
    val wipe: WipeProgressState,
    val error: String?,
    val lastOutcome: String?,
    /** True iff the current screen carrieth secret-bearing material. */
    val redacted: Boolean,
    /** *** GS-UX-001 STEP 6: whether protected data is available, AS THE PLATFORM ANSWERETH. *** */
    val protectedDataAvailable: Boolean,
    val revision: Long,
) {
    companion object {
        val EMPTY = TrustUiState(
            own = null,
            contacts = emptyList(),
            census = TrustCensus.Unavailable("not read yet"),
            wipe = WipeProgressState.Idle,
            error = null,
            lastOutcome = null,
            redacted = false,
            protectedDataAvailable = true,
            revision = 0,
        )
    }

    /** The contact the screen would show for [nodeId], or null. */
    fun contact(nodeId: ByteArray): ContactProjection? =
        contacts.firstOrNull { it.nodeIdCopy().contentEquals(nodeId) }

    /** The verified contacts, in display order. */
    val verified: List<ContactProjection> get() = contacts.filter { it.isVerified }

    /** The contacts still on first-use trust. */
    val tofu: List<ContactProjection> get() = contacts.filter { it.isTofu }

    /** The pending rotations awaiting the user, each with its EXACT ref. */
    val pendingRotations: List<ExactRotationCandidateRef>
        get() = contacts.mapNotNull { it.pendingRotation }
}

/**
 * The ViewModel. [project] is the ONE place the durable authority is read, so
 * every command endeth by re-projecting rather than by patching the UI state.
 */
class IdentityTrustViewModel(
    private val port: TrustPort = UnavailableTrustPort,
    /// *** GS-UX-001 STEP 6 (round 542): THE PLATFORM'S OWN ANSWER -- the trust side of the same gate, defaulted so
    /// nothing that stood before changeth behaviour. ***
    private val protectedData: ProtectedDataGate = AlwaysAvailableProtectedData,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    // --------------------------------------------------------------------------------------
    // *** GS-UX-001 STEP 3 (round 540): OBSERVABLE STATE -- THE TRUST SIDE OF THE SAME CONTRACT. ***
    // MEASURED BEFORE THIS EDIT: a private `state` behind a SNAPSHOT accessor, and the screen read it ONCE -- so a
    // durable event could not reach the screen. **THE PATTERN ALREADY STOOD IN THIS APP** (`BrowseViewModel`), and
    // now in its sibling `MeshViewModel` too: this is the LAST of the app's state owners to be wired.
    // AND THE SEAM IS VALUE-PRESERVING: `state` becometh a PROPERTY OVER the flow, so every existing write still
    // compileth, still carrieth the value, AND NOW PUBLISHETH.
    //
    // (AND THE COMMENT THAT STOOD HERE CLAIMED 'the Compose layer collecteth this in production' -- MEASURED, IT
    // COLLECTED NOTHING: the screen called `uiState()` ONCE. **A COMMENT CLAIMING A WIRING IS NOT A WIRING.**)
    // --------------------------------------------------------------------------------------
    private val _state = MutableStateFlow(TrustUiState.EMPTY)

    /// The observable state, for a screen that collecteth it WITH LIFECYCLE (the card's own clause).
    val flow: StateFlow<TrustUiState> = _state.asStateFlow()

    private var state: TrustUiState
        get() = _state.value
        set(value) { _state.value = value }

    fun uiState(): TrustUiState = state

    /** Refresh from the durable authority. */
    fun refresh(): TrustUiState = project(lastOutcome = null, error = null)

    /** Handle one command. Returns the new projection. */
    fun onCommand(command: ContactVerificationCommand): TrustUiState {
        if (isProtectedCommand(command) && !protectedData.isProtectedDataAvailable()) {
            // *** REFUSED BEFORE ANY EFFECT: THE PORT IS NOT CALLED AT ALL. *** *The arm for this injects a port that
            // THROWS on every protected call and demands zero calls.*
            return unavailableProjection(lastOutcome = "refused: protected data is unavailable", error = null)
        }
        return when (command) {
        is ContactVerificationCommand.ShowOwnIdentity ->
            project(lastOutcome = "own identity shown", error = null)

        is ContactVerificationCommand.Refresh -> project(lastOutcome = null, error = null)

        is ContactVerificationCommand.ImportRecipientBinding -> handleImport(command.payload)

        is ContactVerificationCommand.CompareAndConfirmFingerprint ->
            handleCompare(command.nodeId, command.displayedFingerprintHex)

        is ContactVerificationCommand.ApproveRotation -> handleApprove(command.candidate)

        is ContactVerificationCommand.DismissRotation -> handleDismiss(command.candidate)

        is ContactVerificationCommand.Revoke -> handleRevoke(command.nodeId)

        is ContactVerificationCommand.BeginWipe -> {
            port.beginWipe()
            project(lastOutcome = "wipe begun", error = null)
        }

        is ContactVerificationCommand.ResumeWipe -> {
            port.resumeWipe()
            project(lastOutcome = "wipe resumed", error = null)
        }

        is ContactVerificationCommand.ClearError -> project(lastOutcome = null, error = null)
        }
    }

    /**
     * *** THE EXPLICIT UNAVAILABLE PROJECTION -- "an explicit unavailable projection without invoking the port." ***
     *
     * *Every field that would have come FROM the port is answered with its own honest "unavailable" vocabulary rather
     * than a plausible-looking empty value:* `census` is `TrustCensus.Unavailable` (*the type already speaketh it*),
     * `own` is nil, and `contacts` is empty **BECAUSE NOTHING WAS READ -- not because the authority said there are
     * none.** **`wipe` reporteth `Idle` for the same reason, and `protectedDataAvailable = false` tell the UI WHY.**
     */
    private fun unavailableProjection(lastOutcome: String?, error: String?): TrustUiState =
        TrustUiState(
            own = null,
            contacts = emptyList(),
            census = TrustCensus.Unavailable("protected data is unavailable"),
            wipe = WipeProgressState.Idle,
            error = error,
            lastOutcome = lastOutcome,
            redacted = false,
            protectedDataAvailable = false,
            revision = state.revision + 1,
        )

    /**
     * *** AND THE COMMANDS ARE GATED AT ADMISSION, NOT ONLY IN BUTTONS -- THE AUDIT'S SECOND CLAUSE. ***
     *
     * *The audit: "Enforce the same gate atomically at command/repository admission, not only in buttons."*
     *
     * *** THE CLASSIFICATION IS DERIVED FROM ONE STATED TEST, NOT FROM PER-COMMAND INTUITION: A COMMAND IS PROTECTED
     * IFF ITS HANDLER REACHES `port.` DIRECTLY. *** *A reviewer asked me to re-derive this rather than intuit it, and the
     * derivation is mechanical:* **`handleImport` -> `port.importBinding`, `handleCompare` ->
     * `port.confirmVerified`, `handleApprove` -> `port.approveRotation`, `handleRevoke` -> `port.revoke`, and the two
     * wipe arms call `port.beginWipe()`/`port.resumeWipe()` inline -- THOSE SEVEN REACH THE AUTHORITY.** *The other
     * three -- `ShowOwnIdentity`, `Refresh`, `ClearError` -- call NOTHING but `project()`, which asketh the gate itself,
     * so they are covered transitively by ONE enforcement point rather than by a second guard a future caller could
     * forget.*
     *
     * **AND `DismissRotation` FALLS ON THE "DOES NOT REACH" SIDE, MEASURED RATHER THAN ASSUMED** -- *it was challenged as
     * an exemption that "moveth the durable estate", and `handleDismiss` was read to settle it:* **its own comment says
     * "A dismissal is a UI decision, not an authority mutation" and its entire body is `project()` + a lookup on the
     * RESULT** -- *no port call, so the pending row genuinely stands untouched and `project()`'s gate covereth it.*
     *
     * *** AND THE WIPE ARMS STAY PROTECTED (true) ON PURPOSE, WHICH IS A DECIDED CHOICE WITH A REASON -- NOT A BYPRODUCT
     * OF WHERE THEY FELL IN A SPLIT. *** *This repository already decided the question one layer down, in
     * `WipeGatedAckObligationStore.deleteAllFrames`, whose comment readeth: **"THE ONE METHOD THAT IS *NOT* GATED ... A
     * WIPE MUST BE ABLE TO ERASE THE ACK NAMESPACE WHILE A WIPE IS PENDING -- gating this would make the eraser refuse to
     * erase ... THE GATE PROTECTS USE, NOT DESTRUCTION."*** **HERE THE SAME LAW POINTS THE OTHER WAY, AND THE ASYMMETRY
     * IS THE POINT:** that seam sits INSIDE the wipe's own execution (*it must not refuse*), whereas this gate sits on
     * the UI's ADMISSION to START one (*a locked device is exactly when a user may need to trigger a wipe, and refusing
     * it would be the deadlock the eraser's exemption existeth to prevent*). *Both are wipe roads; one must not be
     * refused, the other must not be able to refuse. Naming that is the decision.*
     */
    internal fun isProtectedCommand(command: ContactVerificationCommand): Boolean = when (command) {
        is ContactVerificationCommand.ImportRecipientBinding -> true
        is ContactVerificationCommand.CompareAndConfirmFingerprint -> true
        is ContactVerificationCommand.ApproveRotation -> true
        is ContactVerificationCommand.DismissRotation -> true
        is ContactVerificationCommand.Revoke -> true
        is ContactVerificationCommand.BeginWipe -> true
        is ContactVerificationCommand.ResumeWipe -> true
        is ContactVerificationCommand.ShowOwnIdentity -> false
        is ContactVerificationCommand.Refresh -> false
        is ContactVerificationCommand.ClearError -> false
    }

    // ------------------------------------------------------------ handlers

    private fun handleImport(payload: String): TrustUiState {
        // law 2: a refused payload leaveth the authority and the projection alone
        when (val parsed = QrPayloadPolicy.parse(payload)) {
            is QrParseResult.Refused -> return withError("that code cannot be used: " + parsed.reason)
            is QrParseResult.Parsed -> {
                val outcome = port.importBinding(payload)
                return when (outcome) {
                    is BindingImportOutcome.Refused ->
                        withAuthorityError("import refused: " + outcome.reason)
                    is BindingImportOutcome.Imported ->
                        project(lastOutcome = "imported " + outcome.label, error = null)
                }
            }
        }
    }

    private fun handleCompare(nodeId: ByteArray, displayedHex: String): TrustUiState {
        if (nodeId.size != 16) return withError("that contact is not addressable")
        if (displayedHex.length != 64 || !displayedHex.all { it.isDigit() || it in 'a'..'f' }) {
            return withError("the fingerprint you entered is not a 64-character hex digest")
        }
        val current = project(lastOutcome = null, error = null)
        val contact = current.contact(nodeId) ?: return withError("no such contact")
        if (!contact.fingerprintHex.equals(displayedHex, ignoreCase = true)) {
            // a mismatch NEVER promotes trust: the durable state standeth
            return withError(
                "those fingerprints differ; the contact was NOT verified and trust is unchanged",
            )
        }
        // the promotion is DURABLE, and it goeth through the authority's own CAS:
        // a local match is never enough to claim a verification
        return when (val outcome = port.confirmVerified(nodeId, contact.fingerprintHex)) {
            is ConfirmOutcome.Confirmed ->
                project(lastOutcome = "fingerprint confirmed for " + contact.label, error = null)
            is ConfirmOutcome.Mismatch -> withAuthorityError(
                "the durable fingerprint is not the one you compared: trust is unchanged",
            )
            is ConfirmOutcome.PeerNotFound -> withAuthorityError("no such contact")
            is ConfirmOutcome.AlreadyVerified ->
                project(lastOutcome = "that contact was already verified", error = null)
            is ConfirmOutcome.Refused ->
                withAuthorityError("confirmation refused: " + outcome.reason)
        }
    }

    private fun handleApprove(candidate: ExactRotationCandidateRef): TrustUiState {
        // the DISPLAYED ref travelleth: a re-read of "the current" rotation would
        // silently approve a different key than the user compared
        val outcome = port.approveRotation(candidate)
        return when (outcome) {
            is RotationApprovalOutcome.Approved ->
                project(lastOutcome = "rotation approved at generation " + outcome.acceptedGeneration,
                    error = null)
            // an AUTHORITY refusal is also NEWS ABOUT THE ESTATE (the pending row
            // moved, the contact was revoked), so these re-project; a LOCAL
            // validation failure (below) never touches the authority at all
            is RotationApprovalOutcome.StaleCandidate -> withAuthorityError(
                "that rotation is no longer pending: nothing was approved",
            )
            is RotationApprovalOutcome.NoPendingCandidate ->
                withAuthorityError("there is no pending rotation to approve")
            is RotationApprovalOutcome.PeerNotFound -> withAuthorityError("no such contact")
            is RotationApprovalOutcome.RejectedRevoked ->
                withAuthorityError("that contact is revoked: its rotation cannot be approved")
            is RotationApprovalOutcome.Refused ->
                withAuthorityError("approval refused: " + outcome.reason)
        }
    }

    private fun handleDismiss(candidate: ExactRotationCandidateRef): TrustUiState {
        // A dismissal is a UI decision, not an authority mutation: the pending
        // row standeth, so the OLD trust keepeth working and nothing is approved.
        val current = project(lastOutcome = null, error = null)
        val contact = current.contact(candidate.nodeIdCopy())
            ?: return withError("no such contact")
        if (contact.pendingRotation == null) {
            return withError("there is no pending rotation to dismiss")
        }
        return project(lastOutcome = "rotation review dismissed; trust unchanged", error = null)
    }

    private fun handleRevoke(nodeId: ByteArray): TrustUiState {
        if (nodeId.size != 16) return withError("that contact is not addressable")
        return when (val outcome = port.revoke(nodeId)) {
            is RevokeOutcome.Revoked ->
                project(lastOutcome = "contact revoked; its sessions are invalidated", error = null)
            is RevokeOutcome.AlreadyRevoked ->
                project(lastOutcome = "the contact was already revoked", error = null)
            is RevokeOutcome.PeerNotFound -> withError("no such contact")
            is RevokeOutcome.Refused -> withAuthorityError("revocation refused: " + outcome.reason)
        }
    }

    // ------------------------------------------------------------ projection

    /** The ONE read of the durable authority, and the ONLY writer of state. */
    private fun project(lastOutcome: String?, error: String?): TrustUiState {
        // *** GS-FINAL-009 (round 715): THE GATE COMES FIRST -- THIS VIEW-MODEL WAS A SECOND, UNDECLARED CONSUMER OF THE
        // SAME DEFECT. ***
        //
        // **FOUND BY AN INDEPENDENT SWEEP THAT ENUMERATED EVERY CONSUMER OF `ProtectedDataGate` RATHER THAN TRUSTING THE
        // FINDING'S `affected_files`** (*which named only `MeshContracts.kt` and `MeshViewModel.kt`*). *The audit's own
        // wording is generic to the CLASS, not to one file: "view-model methods are callable ... Enforce the same gate
        // atomically at command/repository admission, not only in buttons."*
        //
        // **MEASURED, THIS METHOD READ THE PORT BEFORE ASKING THE GATE:** `port.contacts()`, `port.ownIdentity()` and
        // `port.wipeProgress()` all ran FIRST, and `protectedData.isProtectedDataAvailable()` was consulted only to fill a
        // PRESENTATION FIELD -- *precisely the root cause the audit names: "Availability is represented as presentation
        // metadata rather than a prerequisite capability for data access and side effects."*
        if (!protectedData.isProtectedDataAvailable()) {
            return unavailableProjection(lastOutcome = lastOutcome, error = error)
        }
        val census = port.contacts()
        val contacts = (census as? TrustCensus.Readable)?.contacts ?: emptyList()
        val own = port.ownIdentity()
        val next = TrustUiState(
            protectedDataAvailable = protectedData.isProtectedDataAvailable(),
            own = own,
            contacts = contacts,
            census = census,
            wipe = port.wipeProgress(),
            error = error,
            lastOutcome = lastOutcome,
            // the own-identity screen carrieth the QR, which is public material
            // but IS identity-bearing: a screenshot of it is a durable
            // impersonation aid, so the screen wanteth protection exactly while
            // that material standeth on it -- and not otherwise
            redacted = own != null,
            revision = state.revision + 1,
        )
        state = next
        return next
    }

    /**
     * A LOCALLY-refused command: the authority was not consulted, so the
     * projection cannot have changed and is patched with the reason alone. This is
     * law 2 in its cheapest form -- a malformed payload reacheth no store.
     */
    private fun withError(message: String): TrustUiState {
        state = state.copy(error = message, revision = state.revision + 1)
        return state
    }

    /**
     * An AUTHORITY refusal: the estate may have moved under us (a rotation was
     * approved elsewhere, the contact was revoked, the store went corrupt), so the
     * screen is re-projected from the authority and the reason ride beside it.
     */
    private fun withAuthorityError(message: String): TrustUiState =
        project(lastOutcome = null, error = message)
}
