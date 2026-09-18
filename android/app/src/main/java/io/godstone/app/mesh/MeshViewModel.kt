package io.godstone.app.mesh

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

// ---------------------------------------------------------------------------
// T57 -- the messaging ViewModel.
//
// It owneth three laws and nothing else:
//
//   1. EVERY STATUS COMETH FROM THE AUTHORITY. After a send the ViewModel
//      RE-PROJECTS; it never writes DELIVERED, and it never writes a status of its
//      own invention. A transport acceptance produceth ATTEMPTING at most -- and
//      even that word cometh from the projected row, not from the Boolean.
//
//   2. DRAFT VALIDATION HAPPENETH BEFORE THE AUTHORITY IS TROUBLED. An empty or
//      over-budget body is refused locally, byte-accurately, and the durable
//      estate is untouched.
//
//   3. THE SOS CONTROL IS HELD. [MeshCommand.ArmSos] armeth and [ConfirmSos]
//      confirmeth; a bare tap reacheth neither, and a cancel reporteth the
//      limitation in words rather than implying recall.
//
// It is plain Kotlin (no Android or radio-era types) so the shipping app compilth
// it without an edge, and so the court can drive it deterministically.
// ---------------------------------------------------------------------------

class MeshViewModel(
    private val port: MeshPort = UnavailableMeshPort,
    /// *** GS-UX-001 STEP 6 (round 542): THE PLATFORM'S OWN ANSWER, AS A SEAM. *** Defaulted to the
    /// always-available gate, **so nothing that stood before changeth behaviour** and every court that buildeth this
    /// model without a gate keepeth compiling and keepeth its expectations.
    private val protectedData: ProtectedDataGate = AlwaysAvailableProtectedData,
) {
    // --------------------------------------------------------------------------------------
    // *** GS-UX-001 STEP 3 (round 540): OBSERVABLE STATE. ***
    //
    // THE CARD'S OWN WORDS: *'Expose observable state: `StateFlow` collected with lifecycle on Compose, and MainActor
    // observable state consumed by SwiftUI. Refresh after durable events and lifecycle restoration, and unsubscribe
    // when the owner ends.'*
    //
    // MEASURED BEFORE THIS EDIT: this class carried `private var state` and a SNAPSHOT accessor `uiState()`, and the
    // screen read it ONCE (`MeshContent(viewModel.uiState(), modifier)`) -- **SO A DURABLE EVENT COULD NOT REACH THE
    // SCREEN AT ALL.** AND THE PATTERN ALREADY STOOD IN THIS VERY APP: `BrowseViewModel` (`:148-149`) carrieth
    // `MutableStateFlow`/`asStateFlow` and its screen collecteth WITH LIFECYCLE. **A CAPABILITY ITS OWN SIBLING
    // HATH IS NOT A CAPABILITY THIS MODULE LACKETH -- it is one it never wired.**
    //
    // THE SEAM IS VALUE-PRESERVING BY CONSTRUCTION: `state` becometh a PROPERTY OVER the flow, so EVERY existing
    // write (`state = ...`) still compileth AND still carrieth the value -- `_state.value` IS the state. **A
    // MIGRATION THAT REWRITETH THIRTEEN CALL SITES IS A MIGRATION THAT CAN SILENTLY DROP ONE.**
    // --------------------------------------------------------------------------------------
    private val _state = MutableStateFlow(MeshUiState.EMPTY)

    /// The observable state, for a screen that collecteth it WITH LIFECYCLE (the card's own clause).
    val flow: StateFlow<MeshUiState> = _state.asStateFlow()

    private var state: MeshUiState
        get() = _state.value
        set(value) { _state.value = value }

    /// The snapshot accessor stayeth, so every existing caller and court compiles unchanged; the OBSERVABLE door is
    /// `flow`, and a screen that reacheth only this one readeth once -- which is what was measured.
    fun uiState(): MeshUiState = state

    fun refresh(): MeshUiState = project(lastOutcome = null, error = null)

    /**
     * *** GS-FINAL-009: EVERY PROTECTED COMMAND IS REFUSED AT ADMISSION, NOT ONLY IN THE BUTTON. ***
     *
     * THE AUDIT'S MEASUREMENT: *"send/retry/SOS command methods are not guarded by that gate."* AND ITS REMEDY, WHICH
     * THIS FUNCTION IS: *"Enforce the same gate atomically at command/repository admission, not only in buttons."*
     *
     * WHY A DISABLED BUTTON IS NOT ENOUGH, IN THE AUDIT'S OWN TERMS: *"Availability is represented as presentation
     * metadata rather than a prerequisite capability for data access and side effects."* A BUTTON IS A UI PROMISE; THE
     * GATE IS THE MECHANISM. A command can arrive from a restored state, a gesture already in flight, a test, or a
     * future caller -- and none of those consult a button.
     *
     * WHICH COMMANDS ARE PROTECTED, AND WHY THE OTHERS ARE NOT: the reads and the side effects that touch the protected
     * estate are `SendDirect`, `Retry`, `ArmSos`, `ConfirmSos`, `DisarmSos`, `CancelSos` and `RestoreActiveSos`.
     * `Draft`, `SelectRecipient`, `Refresh` and `ClearError` are NOT gated here -- a draft is the user's own typing and
     * `project()` already carrieth the gate for the roads that read. Each is named rather than swept, so the list can
     * be read and argued with.
     */
    private fun isProtectedCommand(command: MeshCommand): Boolean = when (command) {
        is MeshCommand.SendDirect, is MeshCommand.Retry, is MeshCommand.ArmSos,
        is MeshCommand.ConfirmSos, is MeshCommand.DisarmSos, is MeshCommand.CancelSos,
        is MeshCommand.RestoreActiveSos -> true
        is MeshCommand.Refresh, is MeshCommand.ClearError, is MeshCommand.Draft,
        is MeshCommand.SelectRecipient -> false
    }

    fun onCommand(command: MeshCommand): MeshUiState {
        if (isProtectedCommand(command) && !protectedData.isProtectedDataAvailable()) {
            // *** REFUSED BEFORE ANY EFFECT: THE PORT IS NOT CALLED AT ALL. *** The arm that proveth it injects a port
            // that THROWS on every protected call and demands zero calls.
            return publishProtectedUnavailable(lastOutcome = "refused: protected data is unavailable")
        }
        return when (command) {
        is MeshCommand.Refresh -> project(lastOutcome = null, error = null)
        is MeshCommand.ClearError -> project(lastOutcome = null, error = null)

        is MeshCommand.SelectRecipient -> {
            val recipient = port.recipients().firstOrNull {
                it.nodeIdCopy().contentEquals(command.nodeId)
            } ?: return withError("that contact is not a selectable recipient")
            // the SELECTION is the ViewModel's own state -- the authority carrieth
            // recipients, not a choice of them -- so it is stored BEFORE the
            // re-projection (the first form of this handler validated the contact
            // and then threw the choice away, which its own court caught at once)
            state = state.copy(selectedRecipient = recipient, error = null,
                revision = state.revision + 1)
            project(lastOutcome = "recipient: " + recipient.label, error = null)
        }

        is MeshCommand.Draft -> handleDraft(command.body)
        is MeshCommand.SendDirect -> handleSend()
        is MeshCommand.Retry -> handleRetry(command.msgId)
        is MeshCommand.ArmSos -> handleArm()
        is MeshCommand.ConfirmSos -> handleConfirmSos()
        is MeshCommand.DisarmSos -> handleDisarm()
        is MeshCommand.CancelSos -> handleCancelSos(command.msgId)
        is MeshCommand.RestoreActiveSos -> handleRestore()
        }
    }

    // ------------------------------------------------------------ compose

    private fun handleDraft(body: String): MeshUiState {
        // law 2: the budget is enforced in BYTES, and the draft is never silently
        // truncated into something the user did not write
        val bytes = DirectComposePolicy.byteCount(body)
        if (bytes > DirectComposePolicy.MAX_BODY_BYTES) {
            return withError(
                "that message is $bytes bytes; the limit is " +
                    "${DirectComposePolicy.MAX_BODY_BYTES} bytes of UTF-8",
            )
        }
        state = state.copy(draft = body, draftBytes = bytes, error = null,
            revision = state.revision + 1)
        return state
    }

    private fun handleSend(): MeshUiState {
        val recipient = state.selectedRecipient
            ?: return withError("choose a recipient first")
        if (DirectComposePolicy.isBlank(state.draft)) {
            return withError("there is nothing to send")
        }
        if (!DirectComposePolicy.fits(state.draft)) {
            return withError("that message is over the ${
                DirectComposePolicy.MAX_BODY_BYTES}-byte limit")
        }
        return when (val outcome = port.sendDirect(recipient.nodeIdCopy(), state.draft)) {
            is SendOutcome.Refused -> withAuthorityError("send refused: " + outcome.reason)
            is SendOutcome.Queued -> {
                // law 1: the outcome is "queued", NOT "sent" and NOT "delivered":
                // the authority's projected row is what the screen will show
                val cleared = state.copy(draft = "", draftBytes = 0)
                state = cleared
                project(lastOutcome = "queued for " + recipient.label, error = null)
            }
        }
    }

    private fun handleRetry(msgId: ByteArray): MeshUiState {
        if (msgId.size != 16) return withError("that message is not addressable")
        val known = state.messages.firstOrNull { it.msgIdCopy().contentEquals(msgId) }
            ?: return withError("no such message")
        if (!known.retryable) {
            return withError("that message cannot be retried from its current state")
        }
        return when (val outcome = port.retry(msgId)) {
            is RetryOutcome.Refused -> withAuthorityError("retry refused: " + outcome.reason)
            is RetryOutcome.Accepted -> project(lastOutcome = "retrying", error = null)
        }
    }

    // ------------------------------------------------------------ sos

    private fun handleArm(): MeshUiState {
        state = state.copy(sosArmed = true, error = null, lastOutcome = null,
            revision = state.revision + 1)
        return state
    }

    private fun handleDisarm(): MeshUiState {
        state = state.copy(sosArmed = false, error = null, lastOutcome = null,
            revision = state.revision + 1)
        return state
    }

    private fun handleConfirmSos(): MeshUiState {
        // law 3: the confirm is REFUSED unless the control was armed first, so a
        // stray tap (or a pocket) cannot place a distress call
        if (!state.sosArmed) {
            return withError("hold the SOS control to place a call")
        }
        return when (val outcome = port.beginSos(SOS_BODY)) {
            is SosOutcome.Refused -> withAuthorityError("the call could not be placed: " + outcome.reason)
            is SosOutcome.Enqueued -> project(
                lastOutcome = "distress call queued on this phone", error = null)
            is SosOutcome.Cancelled -> withAuthorityError("the call could not be placed")
            is SosOutcome.AlreadyCancelled -> withAuthorityError("the call could not be placed")
        }
    }

    private fun handleCancelSos(msgId: ByteArray): MeshUiState {
        if (msgId.size != 16) return withError("that call is not addressable")
        val active = state.sos
        if (active == null || !active.msgIdCopy().contentEquals(msgId)) {
            return withError("there is no such active call")
        }
        return when (val outcome = port.cancelSos(msgId)) {
            is SosOutcome.Refused -> withAuthorityError("cancel refused: " + outcome.reason)
            is SosOutcome.Cancelled -> project(
                lastOutcome = if (outcome.relayCopiesMayBeOut) {
                    "call cancelled; copies already handed to relays cannot be recalled"
                } else {
                    "call cancelled; no copy had left this device"
                },
                error = null,
            )
            is SosOutcome.AlreadyCancelled -> project(
                lastOutcome = "that call was already cancelled", error = null)
            is SosOutcome.Enqueued -> project(lastOutcome = "call stands", error = null)
        }
    }

    private fun handleRestore(): MeshUiState {
        val restored = port.activeSos()
        return if (restored == null) {
            project(lastOutcome = "no active call", error = null)
        } else {
            project(lastOutcome = "active call restored from this phone's record", error = null)
        }
    }

    // ------------------------------------------------------------ projection

    /**
     * *** GS-FINAL-009 (the independent audit, 2026-09-18): THE GATE IS A PREREQUISITE, NOT PRESENTATION METADATA. ***
     *
     * THE AUDIT'S MEASUREMENT, REPRODUCED AT SOURCE: this function called `port.recipients()` **on its first line**
     * and only asked the gate three lines later -- so an unavailable protected store WAS READ and its (unreadable)
     * contents were projected, with the answer arriving afterwards as a field a screen might or might not show. AND
     * THE ROOT CAUSE IT NAMED IS THE SHAPE OF THAT CODE: *"Availability is represented as presentation metadata rather
     * than a prerequisite capability for data access and side effects."*
     *
     * THE REMEDY IT PRESCRIBES: *"Check availability before projecting protected fields; expose an explicit
     * unavailable projection WITHOUT INVOKING THE PORT."* So the gate is asked FIRST, and when it says no, **NOT ONE
     * PROTECTED READ HAPPENS** -- the arm that proves it injects a port that THROWS on every read, and demands zero
     * calls.
     *
     * AND THE UNAVAILABLE PROJECTION IS TYPED, NOT EMPTY: *"an unavailable protected store must NOT be read as an
     * empty one."* Empty lists would say "you have no contacts", which is a lie that looks like a state.
     */
    private fun project(lastOutcome: String?, error: String?): MeshUiState {
        if (!protectedData.isProtectedDataAvailable()) {
            return publishProtectedUnavailable(lastOutcome = lastOutcome)
        }
        val recipients = port.recipients()
        val selected = state.selectedRecipient?.let { previous ->
            recipients.firstOrNull { it.nodeIdCopy().contentEquals(previous.nodeIdCopy()) }
        }
        // *** THE GATE WAS ALREADY ASKED, ABOVE THIS FUNCTION'S FIRST READ (GS-FINAL-009). *** Recording it here
        // again would be a second opinion about one fact -- the shape the audit condemned. Reaching this line MEANS
        // the gate said yes, so the projection carrieth that answer rather than re-deriving it.
        val next = MeshUiState(
            protectedDataAvailable = true,
            protectedUnavailable = false,
            link = port.linkState(),
            recipients = recipients,
            selectedRecipient = selected,
            draft = state.draft,
            draftBytes = state.draftBytes,
            messages = port.messages(),
            sos = port.activeSos(),
            // the arm surviveth a refresh (a relaunch disarms, because the row is
            // the truth and the arm is a gesture in progress)
            sosArmed = state.sosArmed,
            error = error,
            lastOutcome = lastOutcome,
            revision = state.revision + 1,
        )
        state = next
        return next
    }

    /**
     * *** THE TYPED UNAVAILABLE PROJECTION -- AND IT INVOKES THE PORT FOR NOTHING. ***
     *
     * The audit's remedy: *"expose an explicit unavailable projection without invoking the port."* Every protected
     * projection is emptied BY CONSTRUCTION rather than by reading and discarding, so there is no window in which an
     * unreadable store's contents could reach a screen.
     *
     * `draft` and the selection are KEPT: a draft is the user's own typing, not protected estate, and discarding it
     * would punish them for a platform state they cannot control. The SOS ARM is dropped, because an armed gesture
     * belongs to a call that lives in the protected store.
     */
    private fun publishProtectedUnavailable(lastOutcome: String?): MeshUiState {
        val next = MeshUiState(
            link = state.link,
            recipients = emptyList(),
            selectedRecipient = state.selectedRecipient,
            draft = state.draft,
            draftBytes = state.draftBytes,
            messages = emptyList(),
            sos = null,
            sosArmed = false,
            protectedDataAvailable = false,
            protectedUnavailable = true,
            error = PROTECTED_UNAVAILABLE_REASON,
            lastOutcome = lastOutcome,
            revision = state.revision + 1,
        )
        state = next
        return next
    }

    private fun withError(message: String): MeshUiState {
        state = state.copy(error = message, lastOutcome = null, revision = state.revision + 1)
        return state
    }

    private fun withAuthorityError(message: String): MeshUiState =
        project(lastOutcome = null, error = message)

    companion object {
        /** The broadcast body: it carrieth no free text and no private detail. */
        const val SOS_BODY: String = "SOS"

        /**
         * *** WHY THE SCREEN CARRIETH NOTHING -- SAID RATHER THAN LEFT BLANK. *** The audit's own clause: an
         * unavailable protected store must not read as an empty one. A blank screen and an empty estate look the
         * same; a named reason does not.
         */
        const val PROTECTED_UNAVAILABLE_REASON: String =
            "Protected data is not available right now; this phone's protected storage cannot be read."
    }
}
