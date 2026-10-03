package io.godstone.labmesh

import io.godstone.mesh.SosCommand
import io.godstone.mesh.SosCommandResult
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.lab.LabRuntime
import io.godstone.mesh.lab.LabWipeJourney
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
 * *** AND WHEN THE SAME-ESTATE OWNER REFUSED NORMAL COMPOSITION, THIS BINDING RENDERETH RECOVERY-ONLY (review A6/A7). ***
 * *`runtime` is null exactly when the durable record stood at REQUESTED/corrupt/terminal-failure, so every private
 * command reports the owner's own decision and the wipe controls remain live and actionable -- a real resume, and a real
 * operator-confirmed full erasure for an unreadable record.*
 *
 * *** THE SCOPE IS THE OWNER'S. *** *The Activity hands its own lifecycle scope, so the flow is collected while the
 * owner liveth and cancelled with it -- an unowned scope here would outlive the surface that reads it.*
 */
class LabJourneyBindings(
    private val runtime: LabRuntime?,
    private val scope: CoroutineScope,
    /**
     * *** GS-FINAL-003 `durable-authority`: THE PRODUCTION DURABLE WIPE OWNER. ***
     *
     * *THE OBLIGATION: "rendered wipe UI uses SAME durable production wipe owner (no composition harness local state
     * register)".* **This is `LabWipeJourney`, which readeth the isle's own `FileWipeJournal` -- the SAME
     * `SharedPreferences` file the startup barrier and the runtime-side wipe use -- and driveth `requestWipe`/`resume`
     * through `StartupRecoveryGraph`, the graph the STARTUP itself is built from, with the estate's OWN files as the
     * ladder's artifact and identity seams.** *So a rendered `wipe_begin` retires and erases THE SAME files the send
     * road wrote -- never an unrelated Context estate.*
     */
    val wipeJourney: LabWipeJourney,
    /** The author this journey sendeth as -- the runtime's own first label by default. */
    val author: String = runtime?.labels?.firstOrNull() ?: "none",
) {
    /** The recipients the runtime's OWN label set offers (never a list this class invented). */
    val recipients: List<String> = runtime?.labels?.filter { it != author } ?: emptyList()

    private val _state = MutableStateFlow(
        LabJourneyState(
            recipients = recipients,
            outcome = NOTHING_SENT,
            stateWords = io.godstone.mesh.a11y.AccessibilityContract.STATE_WORDS.getValue("QUEUED"),
            sosStateWords = stateWordsForState(null),
            durableMsgId = null,
            durableLabel = NO_LABEL,
            normalGraphAvailable = runtime != null,
            onBeginWipe = ::beginWipe,
            onResumeWipe = ::resumeWipe,
            onArmSos = ::armSos,
            onCancelSos = ::cancelSos,
            onRetry = ::retry,
            onResolveCorrupt = ::resolveCorrupt,
        )
    )

    /** The rendered state, observed lifecycle-aware by the surface. */
    val state: StateFlow<LabJourneyState> = _state.asStateFlow()

    private suspend fun refreshDurable(extraOutcome: String? = null) {
        val msgId = runtime?.heldMsgIdOf(author)
        val label = msgId?.let { runtime?.deliveryLabelOf(author, it) }
        val sos = runtime?.activeSosStateOf(author)
        val wipe = wipeJourney.progress()
        val previous = _state.value
        val defaultOutcome = if (runtime == null) {
            "recovery-only projection: estate stands at ${wipe.decisionName}; no normal private graph is composed"
        } else {
            previous.outcome
        }
        _state.value = previous.copy(
            outcome = extraOutcome ?: defaultOutcome,
            // *The state word followeth a COMMITTED ROW; while no row standeth the surface keepeth the word it had,
            // so "nothing sent yet" is not silently relabelled a failure.*
            stateWords = if (label != null) stateWordsForLabel(label) else previous.stateWords,
            sosStateWords = stateWordsForState(sos),
            durableMsgId = msgId?.let { hexOf(it) },
            durableLabel = label ?: NO_LABEL,
            // *** THE WIPE IS A READING OF THE DURABLE RECORD, TAKEN ON EVERY REFRESH. *** *Nothing here is remembered:
            // `LabWipeJourney.progress()` opens the isle's own journal, so a stage this screen renders is a stage the
            // record carries -- and a relaunch renders the same words.*
            wipeStage = wipe.stage,
            wipeDecision = wipe.decisionName,
            wipePending = wipe.pending,
            wipeRecoveryPermitted = wipe.permitsResume,
            wipeOperatorRequired = wipe.requiresOperator,
            wipeOperatorResolutionPermitted = wipe.permitsOperatorCorruptResolution,
            // *** AND THE NORMAL GRAPH IS AVAILABLE EXACTLY WHILE A NORMAL PRIVATE RUNTIME STANDS. *** *A refused
            // estate leaveth `runtime` null, so the send and distress controls are DISABLED rather than silently
            // refused after a tap -- the enablement IS the admission.*
            normalGraphAvailable = runtime != null,
            // *** `GS-UX-001 retry`: THE RETRY'S OWN ENABLEMENT, FROM THE DURABLE ROW. *** *A standing call is the ONLY
            // thing a retry can resume; with no row there is nothing to retry, and the button must not lie.*
            sosRetryPermitted = sos != null && runtime?.activeSosMsgIdOf(author) != null,
        )
    }

    /**
     * *** `beginWipe()`: REQUEST through the production recovery graph -- NEVER a local state register. ***
     *
     * *The `ComposedRuntimeHarness.beginWipe()` flag is deliberately NOT bound here: it moveth a private boolean and
     * writeth no journal (`ComposedRuntime.kt:628`), so a journey bound to it would render a wipe nobody performed.*
     * **`LabWipeJourney.begin()` retires the live estate FIRST and then records `REQUESTED` DURABLY through
     * `StartupRecoveryGraph.requestWipe`, which is the SAME verb the startup and the runtime-side authority travel.**
     */
    fun beginWipe() {
        scope.launch {
            val step = wipeJourney.begin()
            refreshDurable(extraOutcome = "wipe: " + step.outcome::class.simpleName + " at " + step.stage)
        }
    }

    /** *** `resumeWipe()`: hand a PERSISTED pending wipe back to the graph that owns the ladder. *** */
    fun resumeWipe() {
        scope.launch {
            val step = wipeJourney.resume()
            refreshDurable(extraOutcome = "wipe: " + step.outcome::class.simpleName + " at " + step.stage)
        }
    }

    /**
     * *** `resolveCorrupt()`: review A7 operator-confirmed full verified erasure. ***
     *
     * *Durably requests and performs full verified erasure on an unreadable record; never clears marker pretend clean.*
     * **The result is the ladder's OWN vocabulary, so a surface that rendered "resolved" over a refusal would be
     * rendering a sentence the owner did not say.**
     */
    fun resolveCorrupt() {
        scope.launch {
            val step = wipeJourney.resolveCorruptForOperator()
            refreshDurable(extraOutcome = "operator resolve: " + step.outcome::class.simpleName + " at " + step.stage)
        }
    }

    /** Read the runtime's own estate into the rendered state (used at start, and after every command). */
    fun refresh() {
        scope.launch { refreshDurable() }
    }

    /** Send: the runtime's own author -> durable enqueue, and the committed `msg_id` rendered from the row. */
    fun send(recipient: String, body: String) {
        scope.launch {
            val graph = normalGraphOrRefuse() ?: return@launch
            if (recipient !in recipients) {
                refreshDurable(
                    extraOutcome = "refused: '"+recipient+"' is not a recipient this runtime carrieth",
                )
                return@launch
            }
            val result = graph.sendDirectResult(author, recipient, body.toByteArray(Charsets.UTF_8))
            refreshDurable(extraOutcome = result.detail)
        }
    }

    /** Arm the distress call through the node's own `.author` arm. */
    fun armSos() {
        scope.launch {
            val graph = normalGraphOrRefuse() ?: return@launch
            val result = graph.sosCommand(author, SosCommand.Author(SOS_BODY.toByteArray(Charsets.UTF_8)))
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
            val graph = normalGraphOrRefuse() ?: return@launch
            val msgId = graph.activeSosMsgIdOf(author)
            if (msgId == null) {
                refreshDurable(extraOutcome = "refused: no standing distress call to cancel")
                return@launch
            }
            val result = graph.sosCommand(author, SosCommand.Cancel(msgId))
            refreshDurable(extraOutcome = describeSos(result))
        }
    }

    /**
     * *** `retry()`: RESUME THE SAME AUTHORED BYTES through the node's own `.retry` arm. ***
     *
     * *THE OBLIGATION'S OWN WORDS: the retry "must resume the existing SOS in the SAME frame/msg_id -- never a fresh
     * author, never a cancel".* **The id is therefore READ from the durable projection at this instant and handed to
     * `SosCommand.Retry`, which loads the SAME held frame; nothing here re-authors and nothing here cancels.** *And
     * with no standing call the retry is a legitimately refused condition, NAMED as such rather than reported as a
     * success.*
     */
    fun retry() {
        scope.launch {
            val graph = normalGraphOrRefuse() ?: return@launch
            val msgId = graph.activeSosMsgIdOf(author)
            if (msgId == null) {
                refreshDurable(extraOutcome = "refused: no standing distress call to retry")
                return@launch
            }
            val result = graph.sosCommand(author, SosCommand.Retry(msgId))
            refreshDurable(extraOutcome = describeSos(result))
        }
    }

    /**
     * *** THE ONE REFUSAL FOR A RECOVERY-ONLY ESTATE -- THE OWNER'S OWN WORDS, RENDERED BEFORE THE NULL. ***
     *
     * *Every private command travelleth here FIRST, so "no normal private graph" is one sentence in one place rather
     * than four paraphrases that could drift -- and the caller receives the NON-NULL graph, so no command can reach a
     * private authority that the same-estate owner refused.*
     */
    private suspend fun normalGraphOrRefuse(): LabRuntime? {
        val graph = runtime
        if (graph == null) {
            refreshDurable(
                extraOutcome = "refused: estate stands at ${wipeJourney.progress().decisionName}; " +
                    "normal private graph is unavailable",
            )
        }
        return graph
    }

    /**
     * *** THE SOS RESULT, WITH A LEGITIMATE REFUSAL SEPARATED FROM A POSITIVE RESUME. ***
     *
     * *`SosCommandResult.Enqueued` carrieth the dispatch taxonomy, whose `HandedToRelays`/`QueuedLocally` are the
     * POSITIVE outcomes and whose `Failed`/`NotPersisted`/`Unavailable` are refusals with their own reasons.* **A
     * surface must be able to tell a resumed-and-offered call from a refused one, so the two are spelled differently
     * here rather than flattened into one string.**
     */
    private fun describeSos(result: SosCommandResult?): String = when (result) {
        null -> "refused: this runtime carrieth no node '"+author+"'"
        is SosCommandResult.Enqueued -> when (val d = result.dispatch) {
            is io.godstone.mesh.SosDispatchResult.HandedToRelays -> "sos:resumed; handed to "+d.count+" relay(s)"
            io.godstone.mesh.SosDispatchResult.QueuedLocally -> "sos:resumed; queued locally"
            io.godstone.mesh.SosDispatchResult.NotPersisted -> "refused:sos was not persisted"
            is io.godstone.mesh.SosDispatchResult.Unavailable -> "refused:sos unavailable: "+d.reason
            is io.godstone.mesh.SosDispatchResult.Failed -> "refused:sos: "+d.reason
        }
        is SosCommandResult.Cancelled -> when (val c = result.cancel) {
            is io.godstone.mesh.SosCancelResult.Cancelled -> "sos:cancelled"
            is io.godstone.mesh.SosCancelResult.AlreadyCancelled -> "sos:already cancelled"
            io.godstone.mesh.SosCancelResult.NotBroadcast -> "refused:not a broadcast call"
            io.godstone.mesh.SosCancelResult.UnknownMessage -> "refused:no such call"
            io.godstone.mesh.SosCancelResult.Corrupt -> "refused:the call's row is corrupt"
            io.godstone.mesh.SosCancelResult.StorageFailure -> "refused:the store refused the cancellation"
            io.godstone.mesh.SosCancelResult.InvalidArgument -> "refused:malformed call id"
            is io.godstone.mesh.SosCancelResult.RejectedTerminal -> "refused:already terminal ("+c.state+")"
        }
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
