package io.godstone.app.mesh

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
) {
    private var state: MeshUiState = MeshUiState.EMPTY

    fun uiState(): MeshUiState = state

    fun refresh(): MeshUiState = project(lastOutcome = null, error = null)

    fun onCommand(command: MeshCommand): MeshUiState = when (command) {
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

    /** The ONE read of the authority, and the ONLY writer of state. */
    private fun project(lastOutcome: String?, error: String?): MeshUiState {
        val recipients = port.recipients()
        val selected = state.selectedRecipient?.let { previous ->
            recipients.firstOrNull { it.nodeIdCopy().contentEquals(previous.nodeIdCopy()) }
        }
        val next = MeshUiState(
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

    private fun withError(message: String): MeshUiState {
        state = state.copy(error = message, lastOutcome = null, revision = state.revision + 1)
        return state
    }

    private fun withAuthorityError(message: String): MeshUiState =
        project(lastOutcome = null, error = message)

    companion object {
        /** The broadcast body: it carrieth no free text and no private detail. */
        const val SOS_BODY: String = "SOS"
    }
}
