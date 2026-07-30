package io.godstone.app.ui.oracle

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.godstone.llm.rag.Citation
import io.godstone.llm.rag.RagPipeline
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class OracleUiState(
    val question: String = "",
    val answer: String = "",
    val citations: List<Citation> = emptyList(),
    val streaming: Boolean = false,
    val refused: Boolean = false,
    val refusalReason: String? = null,
    val modelReady: Boolean = false
)

@HiltViewModel
class OracleViewModel @Inject constructor(
    private val rag: RagPipeline
) : ViewModel() {

    private val _state = MutableStateFlow(OracleUiState())
    val state: StateFlow<OracleUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            rag.warmUp()
            _state.value = _state.value.copy(modelReady = true)
        }
    }

    fun onQuestionChanged(q: String) {
        _state.value = _state.value.copy(question = q)
    }

    fun ask() {
        val q = _state.value.question.trim()
        if (q.isEmpty()) return

        _state.value = _state.value.copy(
            answer = "",
            citations = emptyList(),
            streaming = true,
            refused = false,
            refusalReason = null
        )

        viewModelScope.launch {
            // Constraint C3: retrieval gate runs BEFORE generation. If the archive
            // does not cover the question we refuse rather than invent.
            val retrieval = rag.retrieve(q)

            if (!retrieval.passesConfidenceGate) {
                _state.value = _state.value.copy(
                    streaming = false,
                    refused = true,
                    refusalReason = "The archive does not cover this. " +
                        "Closest related material is listed below.",
                    citations = retrieval.nearMisses
                )
                return@launch
            }

            val sb = StringBuilder()
            rag.generate(q, retrieval).collect { token ->
                sb.append(token)
                _state.value = _state.value.copy(answer = sb.toString())
            }

            _state.value = _state.value.copy(
                streaming = false,
                citations = rag.extractCitations(sb.toString(), retrieval)
            )
        }
    }

    override fun onCleared() {
        super.onCleared()
        // Return RAM to the system as soon as the Oracle is gone.
        rag.release()
    }
}
