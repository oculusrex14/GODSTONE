package io.godstone.app.ui.oracle

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.godstone.llm.rag.Citation
import io.godstone.llm.rag.RagPipeline
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import javax.inject.Inject

enum class OraclePhase { IDLE, RETRIEVING, GENERATING, ANSWERED, REFUSED, DEGRADED }

data class OracleUiState(
    val question: String = "",
    val answer: String = "",
    val citations: List<Citation> = emptyList(),
    val streaming: Boolean = false,
    val refused: Boolean = false,
    val refusalReason: String? = null,
    val modelReady: Boolean = false,
    val phase: OraclePhase = OraclePhase.IDLE
)

@HiltViewModel
class OracleViewModel @Inject constructor(private val rag: RagPipeline) : ViewModel() {
    private val _state = MutableStateFlow(OracleUiState())
    val state: StateFlow<OracleUiState> = _state.asStateFlow()
    private var generationJob: Job? = null

    init {
        viewModelScope.launch {
            val ready = runCatching { rag.warmUp() }.getOrDefault(false)
            _state.value = _state.value.copy(modelReady = ready)
        }
    }

    fun onQuestionChanged(q: String) {
        _state.value = _state.value.copy(question = q)
    }

    fun ask() {
        val question = _state.value.question.trim()
        if (question.isEmpty()) return
        generationJob?.cancel()
        generationJob = viewModelScope.launch {
            _state.value = OracleUiState(
                question = question,
                modelReady = _state.value.modelReady,
                streaming = true,
                phase = OraclePhase.RETRIEVING
            )
            try {
                val retrieval = rag.retrieve(question)
                if (!retrieval.passesConfidenceGate) {
                    refuse(
                        question,
                        retrieval.gateVerdict?.userMessage()
                            ?: "The archive does not support an answer.",
                        retrieval.nearMisses
                    )
                    return@launch
                }
                if (!_state.value.modelReady) {
                    degrade(question, "The model is unavailable. Browse the Archive sources directly.")
                    return@launch
                }

                // Critical safety boundary: draft bytes remain local to this coroutine.
                _state.value = _state.value.copy(phase = OraclePhase.GENERATING)
                val draft = StringBuilder()
                rag.generate(question, retrieval).collect { token -> draft.append(token) }
                val validation = rag.validate(draft.toString(), retrieval)
                if (!validation.isValid) {
                    refuse(
                        question,
                        "I could not verify the generated answer against the Archive.",
                        retrieval.nearMisses
                    )
                    return@launch
                }

                _state.value = OracleUiState(
                    question = question,
                    answer = draft.toString().trim(),
                    citations = validation.citations,
                    modelReady = true,
                    phase = OraclePhase.ANSWERED
                )
            } catch (cancelled: CancellationException) {
                // No partial answer was ever published or persisted.
                throw cancelled
            } catch (_: Throwable) {
                degrade(question, "Generation stopped. Browse the Archive sources directly.")
            }
        }
    }

    private fun refuse(question: String, reason: String, nearMisses: List<Citation>) {
        _state.value = OracleUiState(
            question = question,
            citations = nearMisses,
            refused = true,
            refusalReason = reason,
            modelReady = _state.value.modelReady,
            phase = OraclePhase.REFUSED
        )
    }

    private fun degrade(question: String, reason: String) {
        _state.value = OracleUiState(
            question = question,
            refused = true,
            refusalReason = reason,
            modelReady = false,
            phase = OraclePhase.DEGRADED
        )
    }

    override fun onCleared() {
        generationJob?.cancel()
        rag.release()
        super.onCleared()
    }
}
