// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.app.ui.oracle

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.godstone.llm.rag.Citation

/**
 * Constraint C3: when retrieval fails the confidence gate the UI surfaces a
 * refusal and the closest related material, never a fabricated answer.
 * Constraint C7: large text, high contrast, streaming indicator.
 */
@Composable
fun OracleScreen() {
    val vm: OracleViewModel = hiltViewModel()
    val state by vm.state.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Text(
            text = "Ask the Oracle",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground
        )

        if (!state.modelReady && !state.streaming) {
            Text(
                text = "Warming the model…",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onBackground
            )
        }

        OutlinedTextField(
            value = state.question,
            onValueChange = vm::onQuestionChanged,
            label = { Text("Question") },
            modifier = Modifier.fillMaxWidth(),
            textStyle = MaterialTheme.typography.bodyLarge,
            singleLine = false,
            minLines = 2
        )

        Button(
            onClick = vm::ask,
            enabled = !state.streaming && state.question.isNotBlank(),
            modifier = Modifier
                .fillMaxWidth()
                .height(64.dp)
        ) {
            Text(if (state.streaming) "Thinking…" else "Ask", style = MaterialTheme.typography.titleLarge)
        }

        if (state.streaming) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator()
                Spacer(Modifier.padding(start = 12.dp))
                Text("Generating…", style = MaterialTheme.typography.bodyLarge)
            }
        }

        if (state.refused) {
            RefusalCard(reason = state.refusalReason, nearMisses = state.citations)
        }

        if (state.answer.isNotBlank() && !state.refused) {
            Text(
                text = state.answer,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onBackground
            )
            if (state.citations.isNotEmpty()) {
                Text("Sources", style = MaterialTheme.typography.titleLarge)
                state.citations.forEach { CitationCard(it) }
            }
        }
    }
}

@Composable
private fun RefusalCard(reason: String?, nearMisses: List<Citation>) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Refused", style = MaterialTheme.typography.titleLarge)
            reason?.let { Text(it, style = MaterialTheme.typography.bodyLarge) }
            if (nearMisses.isNotEmpty()) {
                Text("Closest related material:", style = MaterialTheme.typography.bodyMedium)
                nearMisses.forEach { CitationCard(it) }
            }
        }
    }
}

@Composable
private fun CitationCard(c: Citation) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface,
            contentColor = MaterialTheme.colorScheme.onSurface
        )
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(c.title, style = MaterialTheme.typography.titleLarge)
            Text(c.domain, style = MaterialTheme.typography.bodyMedium)
            Text(c.snippet, style = MaterialTheme.typography.bodyLarge)
        }
    }
}