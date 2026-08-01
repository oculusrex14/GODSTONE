package io.godstone.app.ui.mesh

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.godstone.mesh.MeshNode

/** Honest status surface. Radio enablement remains blocked until M1-wire/M2-link close. */
@Composable
fun MeshScreen(meshNode: MeshNode) {
    val status by meshNode.statusFlow.collectAsStateWithLifecycle()
    Column(
        modifier = Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text("Mesh", style = MaterialTheme.typography.titleLarge)
        Card(modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(if (status.linkLayerReady) "Control plane ready" else "Transport not field-ready")
                Text(status.detail, style = MaterialTheme.typography.bodyLarge)
                Text("Nearby peers: ${status.peerCount}", style = MaterialTheme.typography.bodyMedium)
            }
        }
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
                contentColor = MaterialTheme.colorScheme.onErrorContainer
            )
        ) {
            Text(
                "Godstone will not activate radios or claim encrypted delivery until the canonical GMP/2.1 wire format, BLE record reassembly, and Noise handshake driver pass real two-device tests.",
                modifier = Modifier.padding(16.dp)
            )
        }
    }
}
