package io.godstone.llm

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.Dispatchers

/**
 * Thin Kotlin surface over the JNI bridge. Owns no policy: loading decisions and
 * prompt construction live in ModelManager and PromptBuilder respectively.
 */
class LlamaBridge {

    private var handle: Long = 0L

    val isLoaded: Boolean get() = handle != 0L

    fun interface TokenCallback {
        fun onToken(token: String)
    }

    /** Returns false when the model could not be loaded; caller degrades (C5). */
    fun load(modelPath: String, contextTokens: Int, threads: Int): Boolean {
        if (isLoaded) return true
        handle = nativeLoadModel(modelPath, contextTokens, threads)
        return isLoaded
    }

    fun release() {
        if (!isLoaded) return
        nativeFreeModel(handle)
        handle = 0L
    }

    /** Streams generated tokens as they are produced. */
    fun generate(prompt: String, maxTokens: Int): Flow<String> = callbackFlow {
        check(isLoaded) { "model not loaded" }

        val cb = TokenCallback { token -> trySend(token) }
        val produced = nativeGenerate(handle, prompt, maxTokens, cb)

        when (produced) {
            -1 -> close(IllegalStateException("native context lost"))
            -2 -> close(PromptTooLongException())
            else -> close()
        }

        awaitClose { }
    }.flowOn(Dispatchers.Default)

    private external fun nativeLoadModel(
        path: String, nCtx: Int, nThreads: Int
    ): Long

    private external fun nativeFreeModel(handle: Long)

    private external fun nativeGenerate(
        handle: Long, prompt: String, maxTokens: Int, callback: TokenCallback
    ): Int

    companion object {
        init { System.loadLibrary("godstone_llm") }
    }
}

class PromptTooLongException : Exception(
    "The question plus retrieved context exceeds the model's window."
)
