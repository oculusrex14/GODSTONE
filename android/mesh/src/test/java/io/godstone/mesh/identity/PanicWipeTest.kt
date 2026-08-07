package io.godstone.mesh.identity

import io.godstone.mesh.identity.PanicWipe.WipeState
import kotlin.test.assertFailsWith
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test

/**
 * Resumable cryptographic-erasure state machine (ADR-004 criterion 5,
 * GST-WIPE-001, Stage 3 Phase F).
 *
 * These tests drive the PURE [PanicWipe] machine with in-memory fakes -- no
 * Android Context, no Keystore, no disk. A "crash" is modelled as the configured
 * [FakeArtifacts] method throwing on its first invocation (the call did not
 * complete, so the journal still reflects the last completed step); "resume" is
 * a fresh [PanicWipe] sharing the same journal + artifacts, which is exactly the
 * reboot-then-resumeIfPending path. The assertions prove:
 *
 *   - a no-crash wipe runs every step once, in the crypto-erasure-first order;
 *   - a crash before ANY step resumes to full completion;
 *   - the journal after each crash is the last COMPLETED step (so resume neither
 *     skips nor double-runs a destroying step);
 *   - resumeIfPending is a no-op when no wipe is pending, and completes a pending
 *     one.
 *
 * The platform glue ([FileWipeJournal], [AndroidWipeArtifacts]) is not exercised
 * here -- the Keystore master-key deletion + file deletion are on-device
 * concerns. What is proven here is the coordination, ordering and resumability,
 * which are the bug-prone parts and the part that must not silently skip a
 * destroying step.
 */
class PanicWipeTest {

    /** In-memory journal; mirrors FileWipeJournal's IDLE-on-absent semantics. */
    private class FakeJournal : WipeJournal {
        var state: WipeState = WipeState.IDLE
        var writes = 0
        var clears = 0
        override fun read(): WipeState = state
        override fun write(s: WipeState) { state = s; writes++ }
        override fun clear() { state = WipeState.IDLE; clears++ }
    }

    /**
     * Records the order of completed step calls. `crashBefore` makes the NAMED
     * step throw on its FIRST invocation only (the call does not complete and is
     * NOT recorded); subsequent invocations succeed -- modelling "the crash
     * happened, then the process restarted and re-runs the step successfully".
     */
    private class FakeArtifacts(val crashBefore: String? = null) : WipeArtifacts {
        val calls = mutableListOf<String>()
        private val crashed = mutableSetOf<String>()
        private fun step(name: String, block: () -> Unit) {
            if (crashBefore == name && name !in crashed) {
                crashed += name
                throw CrashException(name)
            }
            block()
            calls += name
        }
        override fun eraseKeys() = step("eraseKeys") {}
        override fun deleteArtifacts() = step("deleteArtifacts") {}
        override fun regenerateIdentity() = step("regenerateIdentity") {}
    }

    private class CrashException(step: String) : RuntimeException("crash before $step")

    // --- no crash: full wipe, every step once, in order, journal cleared ---

    @Test
    fun `begin with no crash runs every step once in crypto-erasure-first order`() {
        val j = FakeJournal(); val a = FakeArtifacts()
        PanicWipe(j, a).begin()
        assertEquals(WipeState.IDLE, j.state, "journal cleared back to IDLE")
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), a.calls)
    }

    @Test
    fun `crypto erasure happens before artifact deletion`() {
        val a = FakeArtifacts()
        PanicWipe(FakeJournal(), a).begin()
        assertTrue(a.calls.indexOf("eraseKeys") < a.calls.indexOf("deleteArtifacts"),
            "KEK must be destroyed before ciphertext files are deleted")
        assertTrue(a.calls.indexOf("deleteArtifacts") < a.calls.indexOf("regenerateIdentity"),
            "artifacts deleted before a new identity is generated")
    }

    // --- crash before each step: journal reflects last COMPLETED step, resume completes ---

    @Test
    fun `resumes after a crash before eraseKeys -- REQUESTED persisted, eraseKeys runs once`() {
        val j = FakeJournal(); val a = FakeArtifacts(crashBefore = "eraseKeys")
        assertFailsWith<CrashException> { PanicWipe(j, a).begin() }
        assertEquals(WipeState.REQUESTED, j.state, "nothing destroyed yet -> REQUESTED")
        // Resume on a "fresh" coordinator sharing journal + artifacts.
        PanicWipe(j, a).resumeIfPending()
        assertEquals(WipeState.IDLE, j.state)
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), a.calls)
        // eraseKeys was NOT recorded on the crashed first attempt, so it appears
        // exactly once -- the destroying step was not double-run, just retried.
    }

    @Test
    fun `resumes after a crash before deleteArtifacts -- KEY_ERASED persisted, eraseKeys NOT re-run`() {
        val j = FakeJournal(); val a = FakeArtifacts(crashBefore = "deleteArtifacts")
        assertFailsWith<CrashException> { PanicWipe(j, a).begin() }
        assertEquals(WipeState.KEY_ERASED, j.state,
            "KEK destroyed and persisted -> KEY_ERASED (point of no return)")
        PanicWipe(j, a).resumeIfPending()
        assertEquals(WipeState.IDLE, j.state)
        // eraseKeys ran once (before the crash) and is NOT re-run on resume,
        // because the journal says KEY_ERASED. This is the property that matters:
        // the crypto-erasure step is not re-attempted and the cleanup continues.
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), a.calls)
    }

    @Test
    fun `resumes after a crash before regenerateIdentity -- ARTIFACTS_DELETED persisted`() {
        val j = FakeJournal(); val a = FakeArtifacts(crashBefore = "regenerateIdentity")
        assertFailsWith<CrashException> { PanicWipe(j, a).begin() }
        assertEquals(WipeState.ARTIFACTS_DELETED, j.state,
            "artifacts deleted and persisted -> ARTIFACTS_DELETED")
        PanicWipe(j, a).resumeIfPending()
        assertEquals(WipeState.IDLE, j.state)
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), a.calls)
    }

    // --- resumeIfPending contract ---

    @Test
    fun `resumeIfPending is a no-op when no wipe is pending`() {
        val j = FakeJournal(); val a = FakeArtifacts()
        PanicWipe(j, a).resumeIfPending()
        assertEquals(WipeState.IDLE, j.state)
        assertEquals(emptyList<String>(), a.calls, "nothing destroyed with no pending wipe")
        assertEquals(0, j.clears)
    }

    @Test
    fun `resumeIfPending completes a wipe interrupted at KEY_ERASED`() {
        val j = FakeJournal().apply { state = WipeState.KEY_ERASED }
        val a = FakeArtifacts()
        PanicWipe(j, a).resumeIfPending()
        assertEquals(WipeState.IDLE, j.state)
        // eraseKeys must NOT run -- the journal already says the KEK is gone.
        assertEquals(listOf("deleteArtifacts", "regenerateIdentity"), a.calls)
    }
}