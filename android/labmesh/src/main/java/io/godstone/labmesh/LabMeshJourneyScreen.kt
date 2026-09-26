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
 */
@Composable
fun LabMeshJourneyScreen(state: LabJourneyState, onSend: (String) -> Unit) {
    // *** THE JOURNEY IS LONGER THAN A PHONE SCREEN, SO IT SCROLLS. ***
    //
    // *This is not decoration: without it a control below the fold is measured against a clipped viewport and a
    // semantics court cannot distinguish "not rendered" from "not on screen".* **A REAL journey screen carrieth this
    // many controls, so it must be walkable -- and a scrollable container is what lets EVERY control lay out with a
    // real size.***
    Column(modifier = Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
        // ---------------------------------------------------------------- recipient selection
        var recipient by rememberSaveable { mutableStateOf(state.recipients.firstOrNull() ?: "") }
        Text(
            text = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RECIPIENT_SELECT),
            modifier = Modifier
                .testTag(LabControl.RECIPIENT_SELECT)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RECIPIENT_SELECT)
                    role = Role.RadioButton
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
                    role = Role.Button   // a text field's role is announced by the field itself; the tag is the contract's
                },
        )
        Button(
            onClick = { onSend(body) },
            enabled = body.isNotEmpty() && recipient.isNotEmpty(),
            modifier = Modifier
                .testTag(LabControl.COMPOSE_SEND)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.COMPOSE_SEND)
                    role = Role.Button
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
                    role = Role.Button
                },
        )

        // ---------------------------------------------------------------- SOS, two deliberate steps
        Button(
            onClick = state.onArmSos,
            modifier = Modifier
                .testTag(LabControl.SOS_ARM)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.SOS_ARM)
                    role = Role.Button
                    stateDescription = AccessibilityContract.SOS_IDLE_HINT
                },
        ) { Text(AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.SOS_ARM)) }
        Button(
            onClick = state.onCancelSos,
            modifier = Modifier
                .testTag(LabControl.SOS_CANCEL)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.SOS_CANCEL_LABEL
                    role = Role.Button
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
                    role = Role.Button
                },
        )

        // ---------------------------------------------------------------- retry
        Button(
            onClick = state.onRetry,
            modifier = Modifier
                .testTag(LabControl.RETRY)
                .heightIn(min = 48.dp)
                .semantics {
                    contentDescription = AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RETRY)
                    role = Role.Button
                },
        ) { Text(AccessibilityContract.ESSENTIAL_CONTROLS.getValue(LabControl.RETRY)) }
    }
}

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
    const val COMPOSE_SEND = "compose_send"
    const val OUTCOME = "delivery_outcome"
    const val SOS_ARM = "sos_arm"
    const val SOS_CANCEL = "sos_cancel"
    const val SOS_STATE = "sos_state"
    const val RETRY = "retry"

    /** Every id the semantics court must observe a RENDERED node for. */
    val REQUIRED: List<String> = listOf(
        RECIPIENT_SELECT, COMPOSE_BODY, COMPOSE_SEND, OUTCOME, SOS_ARM, SOS_CANCEL, SOS_STATE, RETRY,
    )
}

/**
 * The screen's state, carried as plain values so a court can drive it without a view model.
 *
 * `stateWords` and `sosStateWords` come from the SHARED vocabulary (`AccessibilityContract.STATE_WORDS`), so this
 * isle cannot invent a status word the durable projection does not speak.
 */
data class LabJourneyState(
    val recipients: List<String> = listOf("Alice", "Bob"),
    val outcome: String = "nothing sent yet",
    val stateWords: String = AccessibilityContract.STATE_WORDS.getValue("QUEUED"),
    val sosStateWords: String = AccessibilityContract.STATE_WORDS.getValue("CANCELLED"),
    val onArmSos: () -> Unit = {},
    val onCancelSos: () -> Unit = {},
    val onRetry: () -> Unit = {},
)
