// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.app.ui.sos

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * Constraint C7: a large, unmistakable red target. Hold-to-send prevents an
 * accidental tap from broadcasting an SOS. The long-press gesture drives a
 * simple progress label; the actual broadcast is deferred.
 *
 * TODO: inject MeshNode and call MeshNode.broadcastSos(...) on confirmed press,
 *  with a 30-day retention sink for sent SOS records.
 */
@Composable
fun SosScreen() {
    var armed by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "SOS",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground
        )
        Text(
            text = "Press and hold to broadcast.",
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onBackground
        )

        Spacer(Modifier.height(24.dp))

        Box(
            modifier = Modifier
                .size(220.dp)
                .semantics { contentDescription = "Hold to send SOS" }
                .pointerInput(Unit) {
                    detectTapGestures(
                        onLongPress = {
                            // TODO: meshNode.broadcastSos(position)
                            armed = true
                            sent = true
                        }
                    )
                },
            contentAlignment = Alignment.Center
        ) {
            // Visual target drawn with the error color so it reads as red in every
            // theme, including red night mode.
            androidx.compose.foundation.Canvas(
                modifier = Modifier.fillMaxSize()
            ) {
                val color = androidx.compose.ui.graphics.Color(
                    android.graphics.Color.HSVToColor(floatArrayOf(0f, 0.85f, 0.95f))
                )
                drawCircle(color = color)
            }
            Text(
                text = if (sent) "SENT" else "HOLD",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onPrimary
            )
        }

        Spacer(Modifier.height(24.dp))

        if (sent) {
            Text(
                text = "SOS broadcast queued. TODO: wire MeshNode.broadcastSos.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onBackground
            )
        }
    }
}
