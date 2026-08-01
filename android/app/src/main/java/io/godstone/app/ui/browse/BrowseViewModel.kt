package io.godstone.app.ui.browse

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.godstone.llm.archive.ArchiveDocument
import io.godstone.llm.archive.ArchivePassage
import io.godstone.llm.archive.ArchiveRepository
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class BrowseUiState(
    val query: String = "",
    val loading: Boolean = true,
    val documents: List<ArchiveDocument> = emptyList(),
    val passages: List<ArchivePassage> = emptyList(),
    val openedTitle: String? = null,
    val error: String? = null
)

@HiltViewModel
class BrowseViewModel @Inject constructor(
    private val archive: ArchiveRepository
) : ViewModel() {
    private val _state = MutableStateFlow(BrowseUiState())
    val state: StateFlow<BrowseUiState> = _state.asStateFlow()

    init { loadDocuments() }

    fun onQueryChanged(value: String) {
        _state.value = _state.value.copy(query = value)
    }

    fun search() {
        val query = _state.value.query.trim()
        if (query.isEmpty()) {
            loadDocuments()
            return
        }
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null, openedTitle = null)
            val result = runCatching {
                withContext(Dispatchers.IO) { archive.search(query) }
            }
            _state.value = result.fold(
                onSuccess = { _state.value.copy(loading = false, passages = it, documents = emptyList()) },
                onFailure = { _state.value.copy(loading = false, error = "Archive search failed: ${it.message}") }
            )
        }
    }

    fun open(document: ArchiveDocument) {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null)
            val result = runCatching {
                withContext(Dispatchers.IO) { archive.passages(document.id) }
            }
            _state.value = result.fold(
                onSuccess = {
                    _state.value.copy(
                        loading = false,
                        documents = emptyList(),
                        passages = it,
                        openedTitle = document.title
                    )
                },
                onFailure = { _state.value.copy(loading = false, error = "Document failed to open: ${it.message}") }
            )
        }
    }

    fun backToDocuments() {
        _state.value = _state.value.copy(query = "")
        loadDocuments()
    }

    private fun loadDocuments() {
        viewModelScope.launch {
            _state.value = _state.value.copy(loading = true, error = null, openedTitle = null)
            val result = runCatching {
                withContext(Dispatchers.IO) { archive.listDocuments() }
            }
            _state.value = result.fold(
                onSuccess = {
                    _state.value.copy(
                        loading = false,
                        documents = it,
                        passages = emptyList(),
                        openedTitle = null
                    )
                },
                onFailure = { _state.value.copy(loading = false, error = "Archive unavailable: ${it.message}") }
            )
        }
    }
}
