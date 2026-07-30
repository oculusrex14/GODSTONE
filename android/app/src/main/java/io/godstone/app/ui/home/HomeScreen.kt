// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.app.ui.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import io.godstone.app.ui.Dest

/**
 * Constraint C7: large tap targets, generous type, no nested menus. The four
 * primary actions are each one tap away; SOS is visually distinct and red.
 */
@Composable
fun HomeScreen(onNavigate: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Short status header -- intentionally free of live data for now.
        Text(
            text = "Godstone",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground
        )
        Text(
            text = "Offline first. No network calls.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onBackground
        )

        Spacer(Modifier.height(8.dp))

        HomeAction(
            label = "Ask the Oracle",
            icon = { Icon(Icons.Filled.Chat, contentDescription = null) },
            onClick = { onNavigate(Dest.Oracle.route) }
        )
        HomeAction(
            label = "Archive",
            icon = { Icon(Icons.Filled.Book, contentDescription = null) },
            onClick = { onNavigate(Dest.Browse.route) }
        )
        HomeAction(
            label = "Mesh",
            icon = { Icon(Icons.Filled.Hub, contentDescription = null) },
            onClick = { onNavigate(Dest.Mesh.route) }
        )
        HomeAction(
            label = "SOS",
            icon = { Icon(Icons.Filled.Warning, contentDescription = null) },
            containerColor = MaterialTheme.colorScheme.error,
            contentColor = MaterialTheme.colorScheme.onError,
            onClick = { onNavigate(Dest.Sos.route) }
        )
    }
}

@Composable
private fun HomeAction(
    label: String,
    icon: @Composable () -> Unit,
    containerColor: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.primary,
    contentColor: androidx.compose.ui.graphics.Color = MaterialTheme.colorScheme.onPrimary,
    onClick: () -> Unit
) {
    Button(
        onClick = onClick,
        modifier = Modifier
            .widthIn(min = 280.dp)
            .height(72.dp) // C7: large tap target
            .semantics { contentDescription = label },
        colors = ButtonDefaults.buttonColors(
            containerColor = containerColor,
            contentColor = contentColor
        )
    ) {
        icon()
        Spacer(Modifier.size(12.dp))
        Text(label, style = MaterialTheme.typography.titleLarge)
    }
}