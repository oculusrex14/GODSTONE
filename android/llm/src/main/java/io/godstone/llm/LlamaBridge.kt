package io.godstone.llm

import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.Dispatchers
import io.godstone.llm.provenance.CancellationToken
import io.godstone.llm.provenance.StreamGate

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
        // ABSENCE IS CHECKED BEFORE THE CALL. Without this the JNI symbol lookup
        // would throw inside the class that is already failing to initialize,
        // which is how a missing library became a crash instead of a false.
        if (!libraryLoaded) return false
        return try {
            handle = nativeLoadModel(modelPath, contextTokens, threads)
            isLoaded
        } catch (failure: UnsatisfiedLinkError) {
            // the library loaded but the symbol did not resolve: same contract, same
            // honest false.
            handle = 0L
            false
        }
    }

    fun release() {
        if (!isLoaded) return
        nativeFreeModel(handle)
        handle = 0L
    }

    /**
     * Streams generated tokens as they are produced. T61: an optional
     * cancellation token is held by the consumer and standeth independent of
     * this flow's own queue -- striking it stoppeth the forwarding between
     * pieces; the single native worker handle is never disturbed.
     */
    fun generate(prompt: String, maxTokens: Int, token: CancellationToken? = null): Flow<String> = callbackFlow {
        check(isLoaded) { "model not loaded" }

        val gate = StreamGate(token)
        val cb = TokenCallback { piece -> if (gate.forward(piece)) trySend(piece) }
        val produced = nativeGenerate(handle, prompt, maxTokens, cb)

        when (produced) {
            -1 -> close(IllegalStateException("native context lost"))
            -2 -> close(PromptTooLongException())
            else -> close()
        }

        awaitClose { }
    }.flowOn(Dispatchers.Default)

    /**
     * Mean-pooled, L2-normalised embedding from the loaded model.
     * Used ONLY with a BGE embedding model -- see rag/Embedder.kt.
     */
    fun embed(text: String): FloatArray? {
        if (!isLoaded) return null
        return nativeEmbed(handle, text)
    }

    private external fun nativeEmbed(handle: Long, text: String): FloatArray?

    private external fun nativeLoadModel(
        path: String, nCtx: Int, nThreads: Int
    ): Long

    private external fun nativeFreeModel(handle: Long)

    private external fun nativeGenerate(
        handle: Long, prompt: String, maxTokens: Int, callback: TokenCallback
    ): Int

    companion object {
        /**
         * THE NATIVE LIBRARY IS LOADED LAZILY AND ITS ABSENCE IS A VALUE, NOT A CRASH.
         *
         * THIS WAS `init { System.loadLibrary("godstone_llm") }`, AND THAT DEFEATED THE
         * CLASS'S OWN CONTRACT. A static initializer that throws does not fail the one
         * call that needed the library -- **it poisons the WHOLE CLASS**: every later
         * touch, including `isLoaded`, `release()` and even constructing the bridge,
         * throws `NoClassDefFoundError: Could not initialize class LlamaBridge` from
         * then on.
         *
         * The consequence was measured, not reasoned: `ModelManager.load()` is a
         * `Boolean` whose own documentation promiseth that when it returneth false
         * *"the Oracle is disabled but the Archive stays fully browsable (C5)"*. **That
         * degradation was unreachable.** A device without `libgodstone_llm.so` (the
         * LIGHT shipping tier, which excludes the native stack) could not merely fail to
         * load a model -- it could not CONSTRUCT the bridge at all, so the exception
         * escaped before any caller could honour the false.
         *
         * The repair makes absence readable: the load is attempted once, the outcome is
         * recorded, and `load()` returneth false exactly as its signature already
         * promised. No behaviour changes when the library IS present.
         */
        private val libraryLoaded: Boolean = try {
            System.loadLibrary("godstone_llm")
            true
        } catch (failure: UnsatisfiedLinkError) {
            // expected on any host without the native artefact, including the LIGHT
            // tier and every JVM unit test
            false
        }

        /** True when the native library is present. Askable WITHOUT loading a model. */
        val isNativeLibraryAvailable: Boolean get() = libraryLoaded

        /** The reason the native stack is unusable, or null when it is available. */
        val nativeUnavailableReason: String?
            get() = if (libraryLoaded) null
                    else "the native library 'godstone_llm' is absent from this build"
    }
}

class PromptTooLongException : Exception(
    "The question plus retrieved context exceeds the model's window."
)
