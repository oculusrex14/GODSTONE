package io.godstone.llm

import android.app.ActivityManager
import android.content.Context
import java.io.File

/**
 * Owns the model lifecycle and the tier policy.
 *
 * Constraint C4: the model is resident only while the Oracle is in use. A cold
 * reload costs roughly 400 ms at LIGHT tier, which is a price worth paying to
 * hand hundreds of megabytes back to a system that may be under pressure.
 */
class ModelManager(
    private val context: Context,
    private val modelAsset: String,
    private val contextTokens: Int
) {

    private val bridge = LlamaBridge()

    val isLoaded: Boolean get() = bridge.isLoaded

    /** Resolve the model path without touching the weights. */
    fun prepareWithoutLoading(): File {
        val dest = File(context.filesDir, modelAsset)
        if (!dest.exists()) {
            context.assets.open(modelAsset).use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
        }
        return dest
    }

    /**
     * Load the model. Returns false when loading is impossible, in which case
     * the Oracle is disabled but the Archive stays fully browsable (C5).
     */
    fun load(): Boolean {
        if (bridge.isLoaded) return true
        val path = prepareWithoutLoading().absolutePath
        return bridge.load(path, contextTokens, optimalThreadCount())
    }

    fun release() = bridge.release()

    fun generate(prompt: String, maxTokens: Int) = bridge.generate(prompt, maxTokens)

    /**
     * Use the big cores only. Spawning a thread per core including efficiency
     * cores makes decode slower and hotter on nearly every ARM big.LITTLE SoC.
     */
    private fun optimalThreadCount(): Int {
        val cores = Runtime.getRuntime().availableProcessors()
        return (cores / 2).coerceIn(2, 6)
    }

    /** Whether this device can realistically run the tier it was sold. */
    fun deviceMeetsTierRequirements(): Boolean {
        val am = context.getSystemService(ActivityManager::class.java)
        val mi = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mi)
        val totalRamGb = mi.totalMem / (1024.0 * 1024.0 * 1024.0)

        return when (contextTokens) {
            2048 -> totalRamGb >= 3.0
            4096 -> totalRamGb >= 6.0
            else -> totalRamGb >= 8.0
        }
    }
}
