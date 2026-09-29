package io.godstone.labmesh

import io.godstone.mesh.SosCommand
import io.godstone.mesh.SosCommandResult
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.lab.LabRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * *** GS-UX-001 `rendered-controls` / `.accessibility` (Android isle): THE JOURNEY BOUND TO THE REAL RUNTIME. ***
 *
 * *THE FINDING'S OWN CHARGE, RESOLVED ON THIS ISLE: the rendered journey reacheth `io.godstone.mesh.lab.LabRuntime`'s
 * DURABLE AUTHORITY, so a rendered control really authoring a message commits it to the real store -- not to a view's
 * memory.* **BEFORE THIS FILE, `LabMainActivity` SHOWED A `TextView` AND NO JOURNEY EXISTED AT ALL: every callback a
 * caller could have written would have been the caller's, and the screen's own `= {}` defaults made the omission
 * silent.**
 *
 * THE THREE LAWS THIS CLASS OBEYETH:
 *
 *  1. **EVERY READ COMETH FROM THE RUNTIME.** *The recipient list is `LabRuntime.labels`; the committed message id is
 *     the store's own `msg_id`; the label is `MeshNode.deliveryProjection`'s honest `DeliveryLabel`; the SOS words are
 *     `MeshNode.activeSosSnapshot`'s durable row. A remembered UI string cannot satisfy any of them.*
 *  2. **EVERY WRITE GOETH THROUGH A REAL COMMAND.** *Send is `LabRuntime.sendDirectResult` (the harness's own author
 *     -> sealed frame -> `dispatchDirect` -> durable enqueue); the distress arms are the node's OWN
 *     `handleSosCommand(.author/.retry/.cancel)` -- the same door iOS bindeth -- so there is no second SOS machine.*
 *  3. **NO READINESS IS MANUFACTURED.** *Nothing here setteth a flag: `LabProfile.MANUFACTURES_READINESS` stayeth a
 *     compile-time `false` and this file carrieth no setter at all.*
 *
 * *** THE SCOPE IS THE OWNER'S. *** *The Activity hands its own lifecycle scope, so the flow is collected while the
 * owner liveth and cancelled with it -- an unowned scope here would outlive the surface that reads it.*
 */
class LabJourneyBindings(
    private val runtime: LabRuntime,
    private val scope: CoroutineScope,
    /** The author this journey sendeth as -- the runtime's own first label by default. */
    val author: String = runtime.labels.first(),
) {
    /** The recipients the runtime's OWN label set offers (never a list this class invented). */
    val recipients: List<String> = runtime.labels.filter { it != author }

    private val _state = MutableStateFlow(
        LabJourneyState(
            recipients = recipients,
            outcome = NOTHING_SENT,
            stateWords = io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("QUEUED"),
            sosStateWords = stateWordsForState(null),
            durableMsgId = null,
            durableLabel = NO_LABEL,
            onArmSos = ::armSos,
            onCancelSos = ::cancelSos,
            onRetry = ::retry,
        )
    )

    /** The rendered state, observed lifecycle-aware by the surface. */
    val state: StateFlow<LabJourneyState> = _state.asStateFlow()

    private suspend fun refreshDurable(extraOutcome: String? = null) {
        val msgId = runtime.heldMsgIdOf(author)
        val label = msgId?.let { runtime.deliveryLabelOf(author, it) }
        val sos = runtime.activeSosStateOf(author)
        val previous = _state.value
        _state.value = previous.copy(
            outcome = extraOutcome ?: previous.outcome,
            // *The state word followeth a COMMITTED ROW; while no row standeth the surface keepeth the word it had,
            // so "nothing sent yet" is not silently relabelled a failure.*
            stateWords = if (label != null) stateWordsForLabel(label) else previous.stateWords,
            sosStateWords = stateWordsForState(sos),
            durableMsgId = msgId?.let { hexOf(it) },
            durableLabel = label ?: NO_LABEL,
        )
    }

    /** Read the runtime's own estate into the rendered state (used at start, and after every command). */
    fun refresh() {
        scope.launch { refreshDurable() }
    }

    /** Send: the runtime's own author -> durable enqueue, and the committed `msg_id` rendered from the row. */
    fun send(recipient: String, body: String) {
        scope.launch {
            if (recipient !in recipients) {
                refreshDurable(
                    extraOutcome = "refused: '"+recipient+"' is not a recipient this runtime carrieth",
                )
                return@launch
            }
            val result = runtime.sendDirectResult(author, recipient, body.toByteArray(Charsets.UTF_8))
            refreshDurable(extraOutcome = result.detail)
        }
    }

    /** Arm the distress call through the node's own `.author` arm. */
    fun armSos() {
        scope.launch {
            val result = runtime.sosCommand(author, SosCommand.Author(SOS_BODY.toByteArray(Charsets.UTF_8)))
            refreshDurable(extraOutcome = describeSos(result))
        }
    }

    /**
     * Cancel the standing call through the node's own `.cancel` arm, named by the DURABLE `msg_id`.
     *
     * *The id is read from the durable projection HERE rather than remembered from the arm: a view's memory of an id
     * could name a message the estate no longer carrieth.*
     */
    fun cancelSos() {
        scope.launch {
            val msgId = runtime.activeSosMsgIdOf(author)
            if (msgId == null) {
                refreshDurable(extraOutcome = "refused: no standing distress call to cancel")
                return@launch
            }
            val result = runtime.sosCommand(author, SosCommand.Cancel(msgId))
            refreshDurable(extraOutcome = describeSos(result))
        }
    }

    /** Resume the SAME authored bytes through the node's own `.retry` arm (never a re-authoring). */
    fun retry() {
        scope.launch {
            val msgId = runtime.activeSosMsgIdOf(author)
            if (msgId == null) {
                refreshDurable(extraOutcome = "refused: no standing distress call to retry")
                return@launch
            }
            val result = runtime.sosCommand(author, SosCommand.Retry(msgId))
            refreshDurable(extraOutcome = describeSos(result))
        }
    }

    private fun describeSos(result: SosCommandResult?): String = when (result) {
        null -> "refused: this runtime carrieth no node '"+author+"'"
        is SosCommandResult.Enqueued -> "sos:" + result.dispatch
        is SosCommandResult.Cancelled -> "sos:" + result.cancel
    }

    companion object {
        const val NOTHING_SENT: String = "nothing sent yet"
        const val NO_LABEL: String = "UNAVAILABLE"

        /** The distress payload this journey armeth. */
        const val SOS_BODY: String = "the mill road is cut at both ends; send boats and a medic"

        fun hexOf(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    }
}

/**
 * *** THE SHARED VOCABULARY, SPOKEN FROM A DURABLE ROW. ***
 *
 * *The screen may not invent a status word (`AccessibilityContract.STATE_WORDS` is the one table), and a durable row
 * speaketh a `DeliveryState`. This is the correspondence -- ONE place, so the screen and the court cannot disagree.*
 */
fun stateWordsForState(state: DeliveryState?): String = when (state) {
    DeliveryState.QUEUED_DURABLY -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("QUEUED")
    DeliveryState.HANDED_TO_RELAY -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("ATTEMPTING")
    DeliveryState.ACKNOWLEDGED_BY_RECIPIENT -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("DELIVERED")
    DeliveryState.EXPIRED -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("EXPIRED")
    DeliveryState.CANCELLED_LOCALLY, DeliveryState.UNAVAILABLE, null ->
        io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("CANCELLED")
}

/** The shared word for an honest [io.godstone.mesh.delivery.DeliveryLabel] name, or the failed word where none standeth. */
fun stateWordsForLabel(label: String?): String = when (label) {
    "QUEUED" -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("QUEUED")
    "OFFERED" -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("ATTEMPTING")
    "DELIVERED" -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("DELIVERED")
    "EXPIRED" -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("EXPIRED")
    "CANCELLED" -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("CANCELLED")
    else -> io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("FAILED")
}
