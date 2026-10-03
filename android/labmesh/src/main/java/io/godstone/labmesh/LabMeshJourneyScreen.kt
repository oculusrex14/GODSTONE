package io.godstone.labmesh

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import io.godstone.mesh.a11y.AccessibilityContract


/**
 * *** GS-UX-001 `rendered-controls` / `.accessibility` (Android isle): THE RENDERED JOURNEY. ***
 *
 * *THE FINDING'S OWN CHARGE, ON THIS ISLE: "MeshScreens renders draft and SOS instructions as Text without editable
 * controls, gesture callbacks or onCommand wiring."* **THE REPAIR IS A SCREEN THE SEMANTICS TREE CAN BE ASKED ABOUT
 * -- NOT A SCREEN THAT LOOKS RIGHT IN A SCREENSHOT.** *Every control below carrieth a `testTag` equal to its
 * `controlId` in the SHARED `AccessibilityContract` table, a `contentDescription`, a `stateDescription` drawn from the
 * SAME `STATE_WORDS` vocabulary the durable projection speaketh, and a `role`.*
 *
 * *** AND THE OUTCOME IS ANNOUNCED, NOT MERELY RENDERED. *** *A delivery outcome that changes silently is a status a
 * screen reader never reads; the `liveRegion` on the outcome node is what makes the change SPOKEN rather than merely
 * present.*
 *
 * **EVERY STRING THE USER READETH COMETH FROM THE CONTRACT TABLE**, so the screen cannot invent a status and the iOS
 * twin cannot drift into different words for the same state.
 *
 * *** ROLES ARE THE CONTROL'S REAL ONES, WHICH IS THIS ROUND'S SECOND REPAIR. *** *Every node used to declare
 * `Role.Button` -- including the two STATUS READOUTS and the recipient label -- because the role was asserted nowhere
 * and therefore never checked. **A TEXT FIELD ANNOUNCED AS A BUTTON, AND A STATUS ANNOUNCED AS A BUTTON, ARE BOTH
 * LIES A SCREEN READER REPEATS**, and the court below now reads the PUBLISHED role of each node against this table,
 * so the lie can no longer pass.*
 */
@Composable
fun LabMeshJourneyScreen(state: LabJourneyState, onSend: (String, String) -> Unit) {
    // *** THE JOURNEY IS LONGER THAN A PHONE SCREEN, SO IT SCROLLS. ***
    //
    // *This is not decoration: without it a control below the fold is measured against a clipped viewport and a
    // semantics court cannot distinguish "not rendered" from "not on screen".* **A REAL journey screen carrieth this
    // many controls, so it must be walkable -- and a scrollable container is what lets EVERY control lay out with a
    // real size.***
    // *** AND THE RTL MIRROR IS TAKEN FROM THE COMPOSITION LOCALE, SO THE COURT CAN ASK FOR IT. ***
    // *Compose resolves `LocalLayoutDirection` from the configuration; the court wraps the screen in a
    // `CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Rtl)` for the RTL arms, which is how the
    // mirror is obtained without a second copy of the screen.*
    val rtl = androidx.compose.ui.platform.LocalLayoutDirection.current == androidx.compose.ui.unit.LayoutDirection.Rtl
    val layoutDirectionWords = if (rtl) "layout mirrored; reading order unchanged" else "left to right"
    // *** THE ANNOUNCEMENT RECORD: WHERE THIS SCREEN'S LIVE REGION MESSAGE IS WRITTEN. ***
    // *The `liveRegion` modifier is what maketh a change SPOKEN; this record is where the message written for that
    // announcement liveth, so the court can bind the mechanism rather than trust a declaration. It is updated through
    // `LaunchedEffect`, which is the moment the value CHANGETH -- the same edge iOS's `.onChange` fires on.*
    var announced by remember { mutableStateOf("nothing yet") }
    LaunchedEffect(state.stateWords) { announced = state.stateWords }
    Column(modifier = Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
        // ---------------------------------------------------------------- recipient selection
        var recipient by rememberSaveable { mutableStateOf(state.recipients.firstOrNull() ?: "") }
        Text(
            text = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RECIPIENT_SELECT),
            modifier = Modifier
                .testTag(LabControl.RECIPIENT_SELECT)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RECIPIENT_SELECT)
                    // *** NO ROLE: THIS IS THE GROUP'S HEADING, NOT A CONTROL. *** *The old declaration called it a
                    // `Role.RadioButton`, so a screen reader announced "Choose a recipient, radio button" with no
                    // action and no selection state behind it. **A ROLE THAT NAMETH AN ACTION THE NODE CANNOT TAKE IS
                    // A LIE REPEATED TO EVERY USER OF ASSISTIVE TECHNOLOGY.***
                },
        )
        Row {
            for (candidate in state.recipients) {
                Button(
                    onClick = { recipient = candidate },
                    modifier = Modifier
                        .testTag(LabControl.RECIPIENT_CANDIDATE + ":" + candidate)
                        .heightIn(min = 48.dp)
                        .semantics {
                            // *The CANDIDATE's description nameth who is chosen -- a listener must hear the choice,
                            // not merely the button's label.*
                            contentDescription = "Recipient " + candidate
                            role = Role.RadioButton
                            stateDescription = if (candidate == recipient) "selected" else "not selected"
                        },
                ) { Text(candidate) }
            }
        }

        // ---------------------------------------------------------------- compose + send
        var body by rememberSaveable { mutableStateOf("") }
        OutlinedTextField(
            value = body,
            onValueChange = { body = it },
            label = { Text(AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.COMPOSE_SEND)) },
            modifier = Modifier
                .fillMaxWidth()
                .testTag(LabControl.COMPOSE_BODY)
                .semantics {
                    contentDescription = "Message text"
                    // *** NO ROLE, SO THE FIELD ANNOUNCETH ITSELF. *** *The old modifier declared `Role.Button` on an
                    // `OutlinedTextField` **WHILE ITS OWN COMMENT CLAIMED THE FIELD ANNOUNCETH ITSELF** -- so the
                    // declaration contradicted its note and a screen reader read "Send, button" for a text field a
                    // user must type into. Removing the override restores the editable-field semantics Compose
                    // publisheth, which is what the court below now reads.*
                },
        )
        // *** THE OCTET READOUT, BECAUSE A BOUND A USER CANNOT SEE IS A BOUND THEY CANNOT RESPECT. ***
        //
        // *THIS READOUT WAS ABSENT FROM THE LIVE SURFACE ON BOTH ISLES -- the iOS view carrieth `composeOctetsReadout`
        // and the Android screen carrieth nothing -- so the Android bound was invisible to a user. It is the SAME
        // measurement the AUTHORITY enforcecth (`SignedMessageV1.BODY_MAX`), and it is computed from the field's own
        // value rather than a constant typed here, so a change to the budget moveth the readout.*
        val octets = octetsOf(body)
        Text(
            text = "$octets/$MESSAGE_BODY_MAX octets",
            modifier = Modifier
                .testTag(LabControl.OCTETS)
                .semantics {
                    contentDescription = "Message size"
                    // *A READOUT, NOT A CONTROL: no role, so it is announced as the status it is.*
                    stateDescription = "$octets of $MESSAGE_BODY_MAX octets used"
                },
        )
        Button(
            onClick = { onSend(recipient, body) },
            enabled = body.isNotEmpty() && recipient.isNotEmpty() && octets <= MESSAGE_BODY_MAX &&
                state.normalGraphAvailable,
            modifier = Modifier
                .testTag(LabControl.COMPOSE_SEND)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.COMPOSE_SEND)
                    role = Role.Button
                    stateDescription = if (state.normalGraphAvailable) "ready to send"
                    else "no normal private graph stands"
                },
        ) { Text(AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.COMPOSE_SEND)) }

        // ---------------------------------------------------------------- the OUTCOME, ANNOUNCED
        Text(
            text = state.outcome,
            modifier = Modifier
                .testTag(LabControl.OUTCOME)
                .semantics {
                    contentDescription = "Delivery status"
                    // *** THE LIVE REGION IS THE WHOLE POINT: a status that changeth must be SPOKEN. ***
                    liveRegion = LiveRegionMode.Polite
                    stateDescription = state.stateWords
                    // *** A STATUS IS NOT A BUTTON. *** *The old declaration said `Role.Button` on a readout the user
                    // cannot activate -- the same lie the text field carrieth, repeated on the node that carryeth the
                    // most consequential words. No role: it is announced as a status.*
                },
        )
        // *** AND THE ANNOUNCEMENT RECORD ITSELF, SO THE COURT CAN BIND THE MECHANISM. ***
        //
        // *The `liveRegion` above maketh the change SPOKEN; this node carrieth the exact words written for that
        // announcement at the moment the state changed. **A SCREEN THAT RENDERED A STATUS AND ANNOUNCED NOTHING
        // READETH `nothing yet` HERE.***
        Text(
            text = "announced: " + announced,
            modifier = Modifier
                .testTag(LabControl.ANNOUNCED)
                .semantics {
                    contentDescription = "Last announced status"
                    stateDescription = announced
                },
        )
        // *** AND THE DURABLE PROJECTION ITSELF, ON SCREEN: THE MESSAGE ID AND LABEL THE RUNTIME'S OWN ROW CARRIETH. ***
        //
        // *This is the node a view-local string CANNOT satisfy. `msgId` is the `msg_id` the durable enqueue committed and
        // `label` is the honest label the delivery row supporteth (`DeliveryProjection.of`); both are READ from the
        // runtime through `LabJourneyState.durableMsgId`/`durableLabel`, so a screen that remembered its own sentence --
        // or a court that asserted one -- would see `none` here while the estate carried a row.*
        Text(
            text = "durable: " + (state.durableMsgId ?: "none") + " / " + state.durableLabel,
            modifier = Modifier
                .testTag(LabControl.DURABLE)
                .semantics {
                    contentDescription = "Durable message state"
                    stateDescription = state.durableLabel
                },
        )

        // ---------------------------------------------------------------- the DURABLE WIPE, read from the record
        //
        // *** GS-FINAL-003 `durable-authority`: THE WIPE IS RENDERED FROM THE PRODUCTION DURABLE RECORD. ***
        //
        // *THE OBLIGATION'S WORDS: "rendered wipe UI uses SAME durable production wipe owner (no composition harness
        // local state register)".* **EVERY WORD BELOW COMETH FROM `state.wipeStage`/`state.wipeDecision`, which
        // `LabJourneyBindings` reads from `LabWipeJourney` -> `FileWipeJournal` -> the SAME `SharedPreferences` file the
        // startup barrier and the runtime-side wipe use.** *A surface with its own register would render a stage the
        // durable record does not carry, and the relaunch arm of `LabWipeJourneyTest` would find it.*
        //
        // *** AND THE STATUS WORDS ARE DERIVED, NOT INVENTED: *** *the stage is a ladder RUNG, the decision is a typed
        // case, and the two CONSEQUENCES (`retryable`, `operatorRequired`) are the production projections -- so the
        // screen cannot tell a user a wipe may be retried when the record says it cannot, or hide a case that needs a
        // person. **THE STATUS NODE CARRIETH NO ROLE, because it is a readout rather than an action (this screen's own
        // law).***
        Text(
            text = "wipe: " + state.wipeStage + " / " + state.wipeDecision +
                if (state.wipeOperatorRequired) " (needs you)" else "",
            modifier = Modifier
                .testTag(LabControl.WIPE_STATE)
                .semantics {
                    contentDescription = "Wipe status"
                    liveRegion = LiveRegionMode.Polite
                    stateDescription = state.wipeStage
                },
        )
        Button(
            onClick = state.onBeginWipe,
            modifier = Modifier
                .testTag(LabControl.WIPE_BEGIN)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = "Wipe this device"
                    role = Role.Button
                    stateDescription = state.wipeStage
                },
        ) { Text("Wipe this device") }
        Button(
            onClick = state.onResumeWipe,
            // *** AND THE CONTROL THAT MUST NOT LIE: IT IS ACTUALLY DISABLED WHEN THE CONTRACT SAYS SO. ***
            // *Its `stateDescription` alone was not enough -- a button that SAYETH "nothing here may be resumed" while
            // remaining CLICKABLE is a control that lies to a finger as well as to a screen reader.* **Compose's own
            // `enabled` flag is bound to the PRODUCTION typed decision, so `SemanticsProperties.Disabled` is published and
            // the node is genuinely unreachable -- which is what a semantics court can read and what a user's tap obeys.**
            enabled = state.wipeRecoveryPermitted,
            modifier = Modifier
                .testTag(LabControl.WIPE_RESUME)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = "Resume the wipe"
                    role = Role.Button
                    stateDescription = if (state.wipeRecoveryPermitted) "a wipe may be resumed" else "nothing here may be resumed"
                },
        ) { Text("Resume the wipe") }
        Button(
            onClick = state.onResolveCorrupt,
            // *** review A7/A11: OPERATOR CORRUPT RESOLUTION -- ENABLED ONLY FOR AN UNREADABLE RECORD ***
            enabled = state.wipeOperatorResolutionPermitted,
            modifier = Modifier
                .testTag(LabControl.WIPE_RESOLVE_CORRUPT)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = "Resolve corrupt wipe record"
                    role = Role.Button
                    stateDescription = if (state.wipeOperatorResolutionPermitted)
                        "corrupt record requires operator full erasure"
                    else "no corrupt record to resolve"
                },
        ) { Text("Resolve corrupt record") }

        // ---------------------------------------------------------------- SOS, two deliberate steps
        Button(
            onClick = state.onArmSos,
            // *** review A6/A11: WITH NO NORMAL PRIVATE GRAPH THERE IS NO NODE TO AUTHOR A CALL -- THE CONTROL IS
            // RENDERED DISABLED RATHER THAN REFUSING AFTER A TAP. ***
            enabled = state.normalGraphAvailable,
            modifier = Modifier
                .testTag(LabControl.SOS_ARM)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.SOS_ARM)
                    role = Role.Button
                    stateDescription = if (state.normalGraphAvailable) AccessibilityContract.SOS_IDLE_HINT
                    else "no normal private graph stands"
                },
        ) { Text(AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.SOS_ARM)) }
        Button(
            onClick = state.onCancelSos,
            // *** AND THE CANCEL IS BOUND TO A STANDING CALL, NOT MERELY TO A LIVE GRAPH: there is nothing to
            // cancel until a call stands, so a clickable cancel here would be a control that lies. ***
            enabled = state.normalGraphAvailable && state.sosRetryPermitted,
            modifier = Modifier
                .testTag(LabControl.SOS_CANCEL)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.SOS_CANCEL_LABEL
                    role = Role.Button
                    stateDescription = if (state.sosRetryPermitted) "a standing call may be cancelled"
                    else "no standing distress call to cancel"
                },
        ) { Text(AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.SOS_CANCEL)) }
        Text(
            text = state.sosStateWords,
            modifier = Modifier
                .testTag(LabControl.SOS_STATE)
                .semantics {
                    contentDescription = "Distress call status"
                    liveRegion = LiveRegionMode.Assertive
                    stateDescription = state.sosStateWords
                    // *Assertive, because an armed call is the most consequential change on this screen -- still a
                    // status rather than a control, so no role.*
                },
        )

        // ---------------------------------------------------------------- retry
        Button(
            onClick = state.onRetry,
            // *** GS-UX-001 retry: STATE-AWARE REQUIRED LIVE CONTROL ***
            // Enabled ONLY when an active distress call stands to retry (never enabled as a no-op click), AND only
            // while a normal private graph standeth to resume it through.
            enabled = state.sosRetryPermitted && state.normalGraphAvailable,
            modifier = Modifier
                .testTag(LabControl.RETRY)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RETRY)
                    role = Role.Button
                    stateDescription = if (state.sosRetryPermitted) "retry standing distress call" else "no standing distress call to retry"
                },
        ) { Text(AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RETRY)) }

        // *** AND THE MIRROR'S OWN RECORD, WHICH IS WHAT LAW 5 CAN BE ASKED OF A LIVE SCREEN. ***
        //
        // *`RTL_MEANING` state says what the layout mirror did and what it did NOT move: under RTL the container
        // mirrors but no control's MEANING followeth it, because every label here is a shared word rather than a
        // directional glyph.*
        Text(
            text = layoutDirectionWords,
            modifier = Modifier
                .testTag(LabControl.RTL_MEANING)
                .semantics {
                    contentDescription = "Layout direction"
                    stateDescription = layoutDirectionWords
                },
        )
    }
}

/** The budget the authority enforcecth, read from the wire contract rather than typed here. */
val MESSAGE_BODY_MAX: Int = io.godstone.mesh.wire.v2.SignedMessageV1.BODY_MAX

/** The UTF-8 octet count of a draft -- **never `String.length`**, which counteth UTF-16 units. */
fun octetsOf(text: String): Int = text.toByteArray(Charsets.UTF_8).size

/**
 * *** THE CONTRACT'S OWN CONTROL IDS, NAMED ONCE SO THE SCREEN AND THE COURT CANNOT DISAGREE. ***
 *
 * *The values are EXACTLY the keys of `AccessibilityContract.ESSENTIAL_CONTROLS`, so a control the table calls
 * essential is unreachable here if it is not rendered -- and the court asserteth the correspondence rather than
 * trusting it.*
 */
object LabControl {
    const val RECIPIENT_SELECT = "recipient_select"
    const val RECIPIENT_CANDIDATE = "recipient_candidate"
    const val COMPOSE_BODY = "compose_body"
    const val OCTETS = "compose_octets"
    const val COMPOSE_SEND = "compose_send"
    const val OUTCOME = "delivery_outcome"
    const val ANNOUNCED = "delivery_announced"
    const val DURABLE = "durable_message_state"
    /** *** GS-FINAL-003 `durable-authority`: THE WIPE'S OWN CONTROLS, RENDERED FROM THE DURABLE RECORD. *** */
    const val WIPE_STATE = "wipe_state"
    const val WIPE_BEGIN = "wipe_begin"
    const val WIPE_RESUME = "wipe_resume"
    const val WIPE_RESOLVE_CORRUPT = "wipe_resolve_corrupt"
    const val SOS_ARM = "sos_arm"
    const val SOS_CANCEL = "sos_cancel"
    const val SOS_STATE = "sos_state"
    const val RETRY = "retry"
    const val RTL_MEANING = "layout_direction"

    /** Every id the semantics court must observe a RENDERED node for. */
    val REQUIRED: List<String> = listOf(
        RECIPIENT_SELECT, COMPOSE_BODY, OCTETS, COMPOSE_SEND, OUTCOME, ANNOUNCED, DURABLE,
        WIPE_STATE, WIPE_BEGIN, WIPE_RESUME, WIPE_RESOLVE_CORRUPT, SOS_ARM, SOS_CANCEL,
    )

    /**
     * *** THE SEMANTIC LAWS OF THE CONTRACT, IN THE FORM THE ANDROID TREE CAN BE ASKED. ***
     *
     * *The python conductor and the iOS twin declare their laws as a STRING vocabulary (`"essential_control_labelled"`,
     * `"touch_target_minimum"`, ...) and a court decideth them from a `UiNode` model. **THIS ISLE NOW READS THE
     * RENDERED TREE INSTEAD**, so those models are no longer the input -- and this table is the correspondence, so the
     * same law is named the same way on all three isles while the EVIDENCE differs (a fixture there, a laid-out tree
     * here). **A table of law NAMES is honest; a table of node DIMENSIONS beside a screen that really lays out would
     * be a second declaration, which is the fabrication this round removes.***
     */
    val SEMANTIC_LAW_IDS: List<String> = listOf(
        "essential_control_labelled",
        "status_never_clipped",
        "no_colour_only_state",
        "touch_target_minimum",
        "reading_order_reachable",
        "rtl_meaning_preserved",
        "long_content_fits",
    )

    /**
     * *** THE ROLE EACH RENDERED NODE REALLY CARRIETH, READ FROM THE PUBLISHED TREE. ***
     *
     * *`null` meaneth the node must publish NO role at all -- which is what a status READOUT seeth, and what an
     * editable field publishes for itself.*
     *
     * *** AND THE TAGS ARE THE ONES THE SCREEN REALLY PUBLISHES: `RECIPIENT_CANDIDATE` ALONE IS NOT A RENDERED TAG. ***
     * *The candidates are `recipient_candidate:<name>`. MEASURED while writing the court: keying the bare constant
     * read `null` off the tree, and the failure then looked exactly like a missing role on the screen.*
     */
    val ROLES: Map<String, Role?> = linkedMapOf(
        RECIPIENT_SELECT to null,        // *a heading: it nameth the group, it is not an action*
        RECIPIENT_CANDIDATE + ":Alice" to Role.RadioButton,
        RECIPIENT_CANDIDATE + ":Bob" to Role.RadioButton,
        COMPOSE_BODY to null,            // *an editable field announceth ITSELF; a role override would replace that*
        OCTETS to null,                  // *a readout*
        COMPOSE_SEND to Role.Button,
        OUTCOME to null,                 // *a live-region STATUS, not an action*
        ANNOUNCED to null,               // *the announcement record: a readout*
        DURABLE to null,                 // *the durable projection: a readout, never an action*
        WIPE_STATE to null,              // *the wipe's own status: a readout of the DURABLE record*
        WIPE_BEGIN to Role.Button,
        WIPE_RESUME to Role.Button,
        WIPE_RESOLVE_CORRUPT to Role.Button,
        SOS_ARM to Role.Button,
        SOS_CANCEL to Role.Button,
        SOS_STATE to null,               // *a live-region STATUS*
        RETRY to Role.Button,
        RTL_MEANING to null,             // *a readout*
    )

    /**
     * *** THE IDS THAT ARE TOUCH TARGETS, FOR LAW 4. ***
     *
     * *A heading and a status readout are NOT touch targets: nothing happeneth when they are touched, so holding them
     * to the 48dp minimum would condemn a screen for a law it never owed. **MEASURED WHILE WRITING THE COURT: with the
     * heading included it read `recipient_select=18.0x35.0` and the arm failed** -- a reading of the GROUP LABEL, not
     * of a control.*
     */
    val CONTROLS: List<String> = listOf(RECIPIENT_CANDIDATE, COMPOSE_BODY, COMPOSE_SEND,
        WIPE_BEGIN, WIPE_RESUME, WIPE_RESOLVE_CORRUPT, SOS_ARM, SOS_CANCEL, RETRY)

}

/**
 * The screen's state, carried as plain values so a court can drive it without a view model.
 *
 * `stateWords` and `sosStateWords` come from the SHARED vocabulary (`AccessibilityContract.STATE_WORDS`), so this
 * isle cannot invent a status word the durable projection does not speak.
 *
 * *** `durableMsgId`/`durableLabel` ARE READ FROM THE RUNTIME'S OWN ROW, WHICH IS WHAT MAKETH THE JOURNEY DURABLE. ***
 * *A view-local string cannot satisfy them: they are the committed `msg_id` and the honest `DeliveryLabel` the estate
 * supporteth, so a screen that remembered a sentence would render `none` while the store carried a row.*
 *
 * *** AND `onArmSos`/`onCancelSos`/`onRetry` CARRY NO NO-OP DEFAULT. *** *They are REQUIRED JOURNEY COMMANDS: a default
 * `{}` let a caller render a screen whose distress controls did nothing -- silently, with every semantics arm still
 * green -- which is precisely the "gesture callbacks or onCommand wiring" the finding's own charge nameth. A component
 * test passeth an explicit (possibly empty) lambda; a caller that omits one no longer compiles.*
 */
data class LabJourneyState(
    val recipients: List<String> = listOf("Alice", "Bob"),
    val outcome: String = "nothing sent yet",
    val stateWords: String = AccessibilityContract.STATE_WORDS.getValue("QUEUED"),
    val sosStateWords: String = AccessibilityContract.STATE_WORDS.getValue("CANCELLED"),
    /** The committed `msg_id` of the last authored message, or null when nothing was committed. */
    val durableMsgId: String? = null,
    /** The honest label the durable row supporteth; `UNAVAILABLE` when no estate carrieth a row. */
    val durableLabel: String = "UNAVAILABLE",
    /**
     * *** GS-FINAL-003 `durable-authority`: THE WIPE'S OWN STAGE, READ FROM THE DURABLE RECORD. ***
     *
     * *A RUNG of the wipe ladder (`IDLE`, `REQUESTED`, ...) -- **NOT a word this screen or a view model invented**, and
     * not a field any surface may set.* **It is read from the SAME `FileWipeJournal` the startup barrier and the
     * runtime-side wipe use, through `LabWipeJourney`, so a relaunch renders what was PERSISTED rather than what was
     * remembered.**
     */
    val wipeStage: String = "IDLE",
    /** The production typed decision's name, so the surface renders the CAUSE rather than a local flag. */
    val wipeDecision: String = "clean_start",
    /** Whether a wipe is outstanding, read from the durable record. */
    val wipePending: Boolean = false,
    /** The production retry contract for the current decision (state-aware, never a local switch). */
    val wipeRecoveryPermitted: Boolean = false,
    /** Whether a human must look (`CORRUPT_JOURNAL` / `TERMINAL_FAILURE`). */
    val wipeOperatorRequired: Boolean = false,
    /** review A7/A11: whether an unreadable record exists that the operator can resolve via full verified erasure */
    val wipeOperatorResolutionPermitted: Boolean = false,
    /** GS-UX-001 retry: whether a standing distress call exists to retry */
    val sosRetryPermitted: Boolean = false,
    /**
     * *** GS-FINAL-003 `same-estate` (review A6): WHETHER A NORMAL PRIVATE GRAPH STANDS AT ALL. ***
     *
     * *A refused estate (`REQUESTED`/corrupt/terminal) composeth NO identity, NO store and NO peer node, so the send
     * and distress controls have NOTHING to reach.* **They are therefore RENDERED DISABLED rather than left clickable
     * and refused after the tap** -- the enablement IS the admission, which is what review A11 asketh of every control
     * whose action is conditional on the typed state.
     */
    val normalGraphAvailable: Boolean = true,
    /** *** `beginWipe()` -- REQUEST through the production recovery graph; no local state register. *** */
    val onBeginWipe: () -> Unit,
    /** *** `resumeWipe()` -- hand a PERSISTED pending wipe back to the graph that owns the ladder. *** */
    val onResumeWipe: () -> Unit,
    val onArmSos: () -> Unit,
    val onCancelSos: () -> Unit,
    val onRetry: () -> Unit,
    val onResolveCorrupt: () -> Unit,
)
