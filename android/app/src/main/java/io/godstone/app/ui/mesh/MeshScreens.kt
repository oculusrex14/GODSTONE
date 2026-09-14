package io.godstone.app.ui.mesh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import io.godstone.app.mesh.LinkState
import io.godstone.app.mesh.MeshUiState
import io.godstone.app.mesh.MeshViewModel
import io.godstone.app.mesh.MessageProjection
import io.godstone.app.mesh.MessageStatus
import io.godstone.app.mesh.SosProjection

// ---------------------------------------------------------------------------
// T57 -- the Compose projections.
//
// Every screen is a pure function of [MeshUiState]: nothing here reacheth a port
// or a store. Three visible consequences of the laws the ViewModel owneth:
//
//   * THE STATUS WORD COMETH FROM THE ROW. [statusWords] never sayeth "Sent" for an
//     ATT acceptance; a relayed copy is "On its way", and only a recipient's
//     authenticated ACK earneth "Delivered".
//   * THE SECURITY CHIP IS HONEST. It readeth [MeshUiState.isSecure], which is true
//     only for a key the user confirmed -- a link that is up is NOT enough.
//   * THE SOS CONTROL IS HELD. [SosControl] rendereth the arm state and the cancel
//     explanation nameth what cannot be recalled.
// ---------------------------------------------------------------------------

const val MESH_LIST_TAG = "mesh-list"
const val SECURITY_CHIP_TAG = "mesh-security"
const val LINK_BANNER_TAG = "mesh-link"
const val SOS_CONTROL_TAG = "mesh-sos"
const val COMPOSE_TAG = "mesh-compose"

@Composable
fun MeshScreen(viewModel: MeshViewModel, modifier: Modifier = Modifier) {
    MeshContent(viewModel.uiState(), modifier)
}

/** The stateless projection: the court can inspect the SAME state the screen renders. */
@Composable
fun MeshContent(state: MeshUiState, modifier: Modifier = Modifier) {
    Column(modifier = modifier.padding(16.dp)) {
        LinkBanner(state)
        SecurityChip(state)
        state.error?.let { message ->
            Card(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                Text("Problem: $message", color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(12.dp))
            }
        }
        ComposeField(state)
        SosControl(state.sos, state.sosArmed)
        Conversation(state.messages)
    }
}

@Composable
private fun LinkBanner(state: MeshUiState) {
    val explanation = state.link.explanation ?: return
    Card(Modifier.fillMaxWidth().testTag(LINK_BANNER_TAG)) {
        Text(explanation, modifier = Modifier.padding(12.dp))
    }
}

@Composable
private fun SecurityChip(state: MeshUiState) {
    Card(Modifier.fillMaxWidth().testTag(SECURITY_CHIP_TAG)) {
        Column(Modifier.padding(12.dp)) {
            Text(
                if (state.isSecure) "Secure" else "Not secure",
                color = if (state.isSecure) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.tertiary,
                style = MaterialTheme.typography.titleSmall,
            )
            Text(state.securitySummary)
        }
    }
}

@Composable
private fun ComposeField(state: MeshUiState) {
    Column(Modifier.fillMaxWidth().testTag(COMPOSE_TAG)) {
        Text(state.selectedRecipient?.label?.let { "To: $it" } ?: "Choose a recipient")
        Text(state.draft)
        Text("${state.bytesRemaining} bytes left")
        if (!state.canSend) Text("Nothing to send yet.")
    }
}

@Composable
private fun SosControl(sos: SosProjection?, armed: Boolean) {
    Card(Modifier.fillMaxWidth().testTag(SOS_CONTROL_TAG)) {
        Column(Modifier.padding(12.dp)) {
            Text("Distress call", style = MaterialTheme.typography.titleSmall)
            if (sos == null) {
                Text(if (armed) "Release to place the call." else "Hold to place a call.")
            } else {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text("Active call: ${statusWords(sos.status)}")
                Text(sos.cancelExplanation)
            }
        }
    }
}

@Composable
private fun Conversation(messages: List<MessageProjection>) {
    Column(Modifier.fillMaxWidth().testTag(MESH_LIST_TAG)) {
        for (message in messages) {
            Card(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                Column(Modifier.padding(12.dp)) {
                    Text(message.peerLabel, style = MaterialTheme.typography.titleSmall)
                    Text(message.body)
                    Text(statusWords(message.status))
                    message.authorityNote?.let { Text(it) }
                }
            }
        }
    }
}

/**
 * The user-facing words for a status. "Sent" is deliberately absent: an ATT
 * acceptance is not a send, and only an authenticated ACK is a delivery.
 */
fun statusWords(status: MessageStatus): String = when (status) {
    MessageStatus.QUEUED -> "Queued on this phone; it will be retried."
    MessageStatus.ATTEMPTING -> "On its way; no answer yet."
    MessageStatus.DELIVERED -> "Delivered: the recipient confirmed it."
    MessageStatus.CANCELLED -> "Cancelled."
    MessageStatus.EXPIRED -> "Expired before it could be delivered."
    MessageStatus.FAILED -> "Failed: the phone could not queue it."
}
