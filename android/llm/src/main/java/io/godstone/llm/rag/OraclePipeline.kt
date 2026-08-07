package io.godstone.llm.rag

import kotlinx.coroutines.flow.Flow

// Oracle orchestration seam.
//
// The OracleViewModel depends on this interface, not on the concrete
// llama.cpp-backed RagPipeline, so the retrieve -> generate -> validate state
// machine can be compiled and JVM-unit-tested against a deterministic fake
// with NO native model on the classpath. The production RagPipeline (which
// drives ModelManager / the llama.cpp bridge) is the only implementation that
// touches a native model; tests inject a fake.
//
// Validation is NOT duplicated by this seam: a fake reuses the production
// AnswerValidator (the single source of the fail-closed rules) by composing it,
// exactly as RagPipeline does. The interface returns AnswerValidationResult so
// the same validator output flows through both production and tests.
interface OraclePipeline {
    /** Bring the model to a ready state. False => the ViewModel degrades truthfully. */
    suspend fun warmUp(): Boolean

    /** Retrieve + confidence-gate. A result that never went through the gate fails closed. */
    suspend fun retrieve(question: String): RetrievalResult

    /**
     * A stream of PRIVATE draft tokens. UI code must never bind this directly to
     * visible state; it is consumed into a local draft that is only published
     * after [validate] succeeds.
     */
    fun generate(question: String, retrieval: RetrievalResult): Flow<String>

    /** Fail-closed validation of a complete private draft. */
    fun validate(answer: String, retrieval: RetrievalResult): AnswerValidationResult

    /** Release native resources. */
    fun release()
}