package io.godstone.app.ui.sos

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.godstone.mesh.MeshNode
import io.godstone.mesh.SosDispatchResult
import kotlinx.coroutines.launch

sealed interface SosUiState {
    data object Idle : SosUiState
    data object Sending : SosUiState
    data class Unavailable(val reason: String) : SosUiState
    data object QueuedLocally : SosUiState
    data class HandedToRelays(val count: Int) : SosUiState
    data class Failed(val reason: String) : SosUiState
}

/** A transport write is never labelled recipient delivery. */
@Composable
fun SosScreen(meshNode: MeshNode) {
    var state by remember { mutableStateOf<SosUiState>(SosUiState.Idle) }
    val scope = rememberCoroutineScope()
    val linkReady = MeshNode.LINK_LAYER_READY
    val buttonColor = if (linkReady) MaterialTheme.colorScheme.error
        else MaterialTheme.colorScheme.surfaceVariant

    Column(
        modifier = Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text("SOS", style = MaterialTheme.typography.titleLarge)
        Text(
            if (linkReady) "Press and hold to queue a distress message."
            else "Mesh SOS is unavailable in this pre-alpha build.",
            style = MaterialTheme.typography.bodyLarge
        )
        Spacer(Modifier.height(24.dp))
        Box(
            modifier = Modifier
                .size(220.dp)
                .semantics { contentDescription = if (linkReady) "Hold to queue SOS" else "SOS unavailable" }
                .pointerInput(linkReady) {
                    if (linkReady) detectTapGestures(onLongPress = {
                        if (state is SosUiState.Sending) return@detectTapGestures
                        state = SosUiState.Sending
                        scope.launch {
                            state = when (val result = meshNode.broadcastSos("SOS".toByteArray())) {
                                is SosDispatchResult.Unavailable -> SosUiState.Unavailable(result.reason)
                                SosDispatchResult.QueuedLocally -> SosUiState.QueuedLocally
                                is SosDispatchResult.HandedToRelays -> SosUiState.HandedToRelays(result.count)
                                is SosDispatchResult.Failed -> SosUiState.Failed(result.reason)
                            }
                        }
                    })
                },
            contentAlignment = Alignment.Center
        ) {
            androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                drawCircle(color = buttonColor)
            }
            Text(
                when (state) {
                    SosUiState.Idle -> if (linkReady) "HOLD" else "DISABLED"
                    SosUiState.Sending -> "QUEUING"
                    is SosUiState.Unavailable -> "DISABLED"
                    SosUiState.QueuedLocally -> "QUEUED"
                    is SosUiState.HandedToRelays -> "RELAYED"
                    is SosUiState.Failed -> "RETRY"
                },
                style = MaterialTheme.typography.titleLarge
            )
        }
        Spacer(Modifier.height(24.dp))
        Text(
            when (val current = state) {
                SosUiState.Idle -> if (linkReady) {
                    "Queued means stored on this phone. Relayed means a nearby device accepted the encrypted record. Neither means a recipient acknowledged it."
                } else {
                    "The app refuses to show a success state while cross-platform encrypted transport is incomplete. Use local emergency services or another working communication method."
                }
                SosUiState.Sending -> "Writing to the local queue…"
                is SosUiState.Unavailable -> current.reason
                SosUiState.QueuedLocally -> "Stored on this phone; no relay accepted it yet."
                is SosUiState.HandedToRelays -> "Accepted by ${current.count} nearby relay(s); recipient acknowledgement has not been received."
                is SosUiState.Failed -> "Could not queue SOS: ${current.reason}"
            },
            style = MaterialTheme.typography.bodyMedium
        )
    }
}
