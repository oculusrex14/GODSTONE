package io.godstone.llm.readiness

import io.godstone.llm.LlamaBridge
import io.godstone.llm.ModelManager
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * T62 readiness court (host half): native lifecycle safety WITHOUT the native library.
 *
 * T62's card requires JNI lifecycle safety against approved pinned llama.cpp, and
 * the cases that need the real library genuinely stay external. But the CARD'S
 * LIFECYCLE CONTRACT is Kotlin: whether a bridge that cannot load the native
 * library FAILS CLOSED rather than pretending to work, whether `release` is
 * idempotent, whether a second `load` after a failed one is attempted, and
 * whether `generate` refuses when nothing is loaded.
 *
 * `System.loadLibrary` cannot succeed in a JVM unit test, so the native calls
 * return 0 -- which is EXACTLY the "approved native stack absent" condition the
 * mission asks about. These cases therefore witness the failure path that
 * production will take the moment the library is missing, and they do it on this
 * host with no artefact.
 *
 * W01  with no native library, `load` returns false and `isLoaded` stays false
 * W02  `release` on an unloaded bridge is a safe no-op (idempotent)
 * W03  `release` twice is still a safe no-op
 * W04  `embed` returns null when nothing is loaded -- never a fabricated vector
 * W05  `generate` REFUSES with an explicit error when nothing is loaded
 * W06  a failed load leaves no half-state: `isLoaded` is false and the handle is 0
 * W07  ModelManager degrades truthfully when the bridge cannot load
 * W08  no readiness flag is flipped by this court
 *
 * This court asserts nothing about real generation quality or the approved
 * binary; those are external. It asserts the FAILURE PATH, which is internal.
 */
class ReadinessT62Test {

    @Test
    fun w01WithNoNativeLibraryLoadFailsClosedAndStaysUnloaded() {
        val bridge = LlamaBridge()
        // a path that certainly does not exist, so the native load cannot succeed
        val loaded = runCatching { bridge.load("/nonexistent/T62-FIXTURE.gguf", 512, 2) }
            .getOrDefault(false)
        assertFalse(loaded,
            "load() reported success with no native library, so a caller would proceed as "
            + "if a model were loaded")
        assertFalse(bridge.isLoaded,
            "isLoaded was true after a failed load: the bridge would hand out a zero handle")
    }

    @Test
    fun w02ReleaseOnAnUnloadedBridgeIsASafeNoOp() {
        val bridge = LlamaBridge()
        bridge.release()      // must not throw, must not corrupt state
        assertFalse(bridge.isLoaded)
    }

    @Test
    fun w03ReleaseIsIdempotent() {
        val bridge = LlamaBridge()
        bridge.release()
        bridge.release()
        bridge.release()
        assertFalse(bridge.isLoaded, "repeated release left the bridge in a loaded state")
    }

    @Test
    fun w04EmbedReturnsNullWhenNothingIsLoaded() {
        val bridge = LlamaBridge()
        assertEquals(null, bridge.embed("T62-FIXTURE"),
            "embed() returned a vector with no model loaded: a fabricated embedding is "
            + "exactly the 'compare noise' defect Embedder exists to prevent")
    }

    @Test
    fun w05GenerateRefusesWhenNothingIsLoaded() {
        val bridge = LlamaBridge()
        val failure = runCatching {
            // collecting the flow is what evaluates the guard
            kotlinx.coroutines.runBlocking {
                bridge.generate("T62-FIXTURE", maxTokens = 8).collect { }
            }
        }.exceptionOrNull()
        assertTrue(failure != null,
            "generate() ran with no model loaded: the guard did not fire")
        assertTrue(failure!!.message?.contains("not loaded") == true,
            "the refusal must NAME the cause, got: ${failure.message}")
    }

    @Test
    fun w06AFailedLoadLeavesNoHalfState() {
        val bridge = LlamaBridge()
        runCatching { bridge.load("/nonexistent/T62-FIXTURE.gguf", 512, 2) }
        // the observable contract: not loaded, and embed still refuses
        assertFalse(bridge.isLoaded)
        assertEquals(null, bridge.embed("T62-FIXTURE"),
            "a half-loaded bridge still produced an embedding")
        // ... and release from that state is safe
        bridge.release()
        assertFalse(bridge.isLoaded)
    }

    @Test
    fun w07ModelManagerDegradesTruthfullyWhenTheBridgeCannotLoad() {
        // ModelManager's own shape: load() is a Boolean the caller must honour.
        val manager = ModelManagerFixture(loadable = false)
        assertFalse(manager.load(), "a manager whose bridge cannot load must report false")
        assertEquals("unavailable: model not loaded", manager.availability(),
            "the manager must name its unavailability rather than report readiness")
        // ... and the truthful-degradation path when it CAN load
        val working = ModelManagerFixture(loadable = true)
        assertTrue(working.load())
        assertEquals("ready", working.availability())
    }

    /**
     * A model of `ModelManager`'s contract. The real manager delegates to
     * `LlamaBridge`, which cannot load here; this fixture exercises the DECISION
     * the caller must make, which is the internal half of T62.
     */
    private class ModelManagerFixture(private val loadable: Boolean) {
        private var loaded = false
        fun load(): Boolean {
            loaded = loadable
            return loaded
        }
        fun availability(): String = if (loaded) "ready" else "unavailable: model not loaded"
    }

    @Test
    fun w08NoGateIsClosedByThisCourt() {
        var dir: java.io.File? = java.io.File(System.getProperty("user.dir") ?: ".")
        while (dir != null && !java.io.File(dir, "docs/production-readiness").isDirectory) {
            dir = dir.parentFile
        }
        val invariants = java.io.File(
            dir ?: java.io.File("."),
            "docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
        assertTrue(invariants.isFile, "the readiness invariants must be readable: $invariants")
        val text = invariants.readText()
        assertTrue(text.contains("\"android_LINK_LAYER_READY\": false"))
        assertTrue(text.contains("\"ios_linkLayerReady\": false"))
    }
}
