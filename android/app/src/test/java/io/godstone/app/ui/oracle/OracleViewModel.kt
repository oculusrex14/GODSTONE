package io.godstone.app.ui.oracle

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.godstone.llm.rag.Citation
import io.godstone.llm.rag.OraclePipeline
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

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

// OracleViewModel depends on OraclePipeline (a small interface), not on the
// concrete llama.cpp-backed RagPipeline, so the retrieve -> generate -> validate
// state machine compiles and JVM-unit-tests with a deterministic fake and NO
// native model on the classpath. Safety invariants enforced here, and asserted
// by OracleViewModelTest:
//   * generated tokens are accumulated into a LOCAL StringBuilder and never
//     present in _state (the GENERATING phase carries no answer payload);
//   * the whole draft is private until validate() returns isValid;
//   * a cancelled generation never publishes a partial answer; an explicit
//     cancel (cancelGeneration) restores the last validator-approved answer so
//     an unfinished draft cannot overwrite it. A new ask() that supersedes an
//     in-flight run does NOT restore -- it replaces the state with RETRIEVING,
//     so there is no race between a restored old answer and the new question.
//
// Stage 3 Phase I: the on-device Oracle feature is non-shipping (the LIGHT
// release links only :core). This ViewModel is therefore compiled ONLY in the
// test source set (constructed directly by OracleViewModelTest, not via Hilt),
// and the Oracle UI screen is dormant debt. The Hilt annotations were removed
// when it left the shipping graph.
class OracleViewModel(private val rag: OraclePipeline) : ViewModel() {
    private val _state = MutableStateFlow(OracleUiState())
    val state: StateFlow<OracleUiState> = _state.asStateFlow()
    private var generationJob: Job? = null
    private var lastAnswered: OracleUiState? = null
    private var restoreOnCancel = false

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
        // A new question supersedes any in-flight run. Do NOT restore on this
        // cancel: the new run publishes RETRIEVING below, and a restored old
        // answer must not race that transition.
        restoreOnCancel = false
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
                lastAnswered = _state.value
            } catch (cancelled: CancellationException) {
                // No partial answer was ever published or persisted. An explicit
                // cancel restores the last approved answer; a superseding ask
                // leaves the new run's state in place.
                if (restoreOnCancel) restore()
                restoreOnCancel = false
                throw cancelled
            } catch (_: Throwable) {
                degrade(question, "Generation stopped. Browse the Archive sources directly.")
            }
        }
    }

    /** Cancel an in-flight generation and restore the last approved answer (UI back). */
    fun cancelGeneration() {
        restoreOnCancel = true
        generationJob?.cancel()
    }

    private fun restore() {
        val prior = lastAnswered
        if (prior != null) _state.value = prior
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