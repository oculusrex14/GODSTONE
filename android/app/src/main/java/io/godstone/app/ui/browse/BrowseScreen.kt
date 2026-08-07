package io.godstone.app.ui.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchivePassage

/** Search and document browsing remain available even when the model and radios do not. */
@Composable
fun BrowseScreen(vm: BrowseViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(state.openedTitle ?: "Archive", style = MaterialTheme.typography.titleLarge)
            if (state.openedTitle != null || state.passages.isNotEmpty()) {
                Button(onClick = vm::backToDocuments) { Text("All documents") }
            }
        }

        OutlinedTextField(
            value = state.query,
            onValueChange = vm::onQueryChanged,
            label = { Text("Search every document") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { vm.search() })
        )
        Button(onClick = vm::search, modifier = Modifier.fillMaxWidth()) { Text("Search offline") }

        state.error?.let {
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer
                )
            ) { Text(it, modifier = Modifier.padding(16.dp)) }
        }

        if (state.loading) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
        } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(state.documents, key = { it.id }) { DocumentCard(it, vm::open) }
                items(state.passages, key = { it.chunkId }) { PassageCard(it) }
            }
        }
    }
}

@Composable
private fun DocumentCard(document: ArchiveDocument, onOpen: (ArchiveDocument) -> Unit) {
    Card(
        onClick = { onOpen(document) },
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(document.title, fontWeight = FontWeight.Bold)
            Text(document.domain, style = MaterialTheme.typography.bodyMedium)
            if (document.isCritical) Text("Critical procedure", color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun PassageCard(passage: ArchivePassage) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(passage.documentTitle, fontWeight = FontWeight.Bold)
            if (passage.section.isNotBlank()) Text(passage.section, style = MaterialTheme.typography.bodyMedium)
            Text(passage.text, style = MaterialTheme.typography.bodyLarge)
        }
    }
}
