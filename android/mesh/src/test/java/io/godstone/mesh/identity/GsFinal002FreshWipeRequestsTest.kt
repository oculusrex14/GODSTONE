package io.godstone.mesh.identity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GS-FINAL-002 (the independent audit, 2026-09-18): **A FRESH WIPE MUST REQUEST; ONLY STARTUP RECOVERY RESUMES.**
 *
 * THE AUDIT'S MEASUREMENT, VERBATIM: "Android `MeshPanicWipe.begin` constructs the coordinator and calls `resume`;
 * resume refuses an empty journal." AND THE CONSEQUENCE IT NAMES: "A fresh Android wipe may do no wipe at all."
 *
 * THAT IS THE WHOLE DEFECT, AND IT IS A TWO-LINE ONE WITH A USER-VISIBLE CONSEQUENCE: `CrashResumableWipe.resume()`
 * REFUSES AN EMPTY JOURNAL -- `Refused("nothing to resume; no wipe was ever requested")` -- so the runtime-side wipe
 * entry point, WHICH IS THE ONE A USER'S WIPE TRAVELS THROUGH, DID NOTHING AT ALL for a wipe never requested before.
 *
 * THE BOARD'S OWN TEST PINS THE REFUSAL AS CORRECT FOR `resume` (`anEmptyJournalIsRefusedBecauseNothingWasEverRequested`),
 * AND IT IS CORRECT: `resume` IS THE CRASH PATH. THE DEFECT IS THAT THE FRESH PATH WAS ROUTED THROUGH IT. These arms
 * separate the two verbs and are run RED FIRST.
 */
class GsFinal002FreshWipeRequestsTest {

    /** A journal that remembers EVERY record, so the ORDER of the ladder is readable. */
    private class RecordingJournal : WipeJournal {
        private var current = PanicWipe.WipeState.IDLE
        val writes = mutableListOf<String>()
        override fun read(): PanicWipe.WipeState = current
        override fun write(state: PanicWipe.WipeState) { current = state; writes.add(state.name) }
        override fun clear() { current = PanicWipe.WipeState.IDLE }
    }

    /** A vault whose erasure always succeeds; every OTHER key besides `store-dek` is not this arm's subject. */
    private class PassingVault : KeyVaultSeam {
        val erased = mutableListOf<String>()
        override fun eraseKey(name: String): KeyDeletionResult { erased.add(name); return KeyDeletionResult.Deleted }
    }

    /** A vault whose erasure FAILS RETRYABLY, so the ladder answereth `RetryLater` rather than advancing. */
    private class RefusingVault : KeyVaultSeam {
        override fun eraseKey(name: String): KeyDeletionResult =
            KeyDeletionResult.Failed(name, retryable = true, reason = "the key store is busy")
    }

    /** A filesystem whose deletions always succeed. */
    private class PassingFileSystem : ArtifactFileSystemSeam {
        val deleted = mutableListOf<String>()
        override fun deleteArtifact(path: String): FileDeletionResult { deleted.add(path); return FileDeletionResult.Deleted }
        override fun exists(path: String): Boolean = false
        override fun isReadable(path: String): Boolean = false
    }

    /** A transport that reports a completed drain, so the ladder reaches the erasure. */
    private class DrainedTransport : TransportRuntimeSeam {
        override fun drainTransport(): RuntimeDrainReceipt = RuntimeDrainReceipt.Drained(1, true)
        override fun isQuiesced(): Boolean = true
        override fun fireRadio(msg: String): Boolean = false
        override fun sendVia(msg: String): Boolean = false
    }

    /** An authority that publishes an identity. */
    private class PublishingAuthority : IdentityAuthoritySeam {
        override fun publishNewIdentity(): String? = "a-fresh-node-hint"
        override fun identity(): String? = "a-fresh-node-hint"
    }

    private fun coordinator(journal: WipeJournal, vault: KeyVaultSeam = PassingVault(),
                            filesystem: ArtifactFileSystemSeam = PassingFileSystem()) =
        CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(journal),
            vault = vault,
            filesystem = filesystem,
            runtime = DrainedTransport(),
            authority = PublishingAuthority(),
        )

    /**
     * *** THE ARM FOR THE AUDIT'S OWN SENTENCE: "A fresh Android wipe may do no wipe at all." ***
     *
     * *** AND IT JUDGES THE **ROUTING DECISION**, NOT THE COORDINATOR -- BECAUSE MY FIRST THREE ARMS WERE DEFECTIVE. ***
     *
     * Those arms drove `CrashResumableWipe` directly, so they passed against the UNREPAIRED CALL SITE: a mutation
     * restoring `.resume()` at `MeshPanicWipe.begin` left the whole suite GREEN. They justified the coordinator, which
     * was never in doubt, and said NOTHING about the verb the entry point chose. THE FIX IS THAT THE CHOICE IS NOW ITS
     * OWN FUNCTION (`MeshPanicWipe.runRuntimeSideWipe`), and this arm exercises THAT -- so the decision is the subject.
     *
     * THE ASSERTION IS THE AUDIT'S OWN SENTENCE: an empty journal, the live entry, and the wipe must RECORD `REQUESTED`
     * rather than being refused as "nothing to resume". `resume` is the crash path and its refusal on a clean journal is
     * CORRECT -- which is exactly why routing the FRESH path through it did nothing at all.
     */
    @Test
    fun aFreshWipeRecordsRequestedRatherThanBeingRefusedAsNothingToResume() {
        val journal = RecordingJournal()
        val result = io.godstone.mesh.di.MeshPanicWipe.runRuntimeSideWipe(coordinator(journal))

        assertTrue(
            "*** GS-FINAL-002: A FRESH WIPE MUST NOT BE REFUSED AS 'nothing to resume' -- THAT REFUSAL IS THE DEFECT, " +
                "AND IT MEANS THE USER'S WIPE DID NOTHING. Observed: $result ***",
            result !is WipeStepResult.Refused,
        )
        assertTrue(
            "AND IT MUST HAVE RECORDED `REQUESTED` DURABLY FIRST, which is what makes it resumable after a crash. " +
                "Observed writes: ${journal.writes}",
            journal.writes.contains("REQUESTED"),
        )
        assertTrue(
            "and it must have PASSED THROUGH THE DRAIN, whose checkpoint is the stage the old machine lacked: " +
                "${journal.writes}",
            journal.writes.contains("RUNTIME_DRAINED"),
        )
        if (journal.writes.indexOf("RUNTIME_DRAINED") >= 0 && journal.writes.indexOf("KEY_ERASED") >= 0) {
            assertTrue(
                "AND THE ORDER IS THE SAFETY PROPERTY: THE DRAIN CHECKPOINT MUST PRECEDE THE ERASURE. " +
                    "Observed: ${journal.writes}",
                journal.writes.indexOf("RUNTIME_DRAINED") < journal.writes.indexOf("KEY_ERASED"),
            )
        }
    }

    // *** NOTE (round 707): AN ARM FOR THE TYPED-OUTCOME CLAUSE STOOD HERE AND WAS DELETED, DELIBERATELY. ***
    // *It drove the STATIC helper `MeshPanicWipe.runRuntimeSideWipe(...)`, which ALREADY returned `WipeStepResult`
    // before this round -- so it was green while `begin()` still returned `Unit`, and it stayed green when I reverted
    // ONLY the propagation. An independent review caught it, and the mutation confirmed it: an arm about the helper is
    // not an arm about the entry.* **The clause is now evidenced by
    // `GsFinal003ContextProviderTest.testGF002TheInstanceEntryHandethTheTypedOutcomeToItsCaller`, which drives the REAL
    // instance entry over a Robolectric Context and couples the answer to the DURABLE JOURNAL -- and which REDDENS when
    // only the propagation is reverted.**
    /**
     * *** AND THE REFUSAL IS PINNED AS CORRECT **FOR `resume`**, SO THE TWO VERBS STAY DISTINGUISHABLE. ***
     *
     * This arm stands ADJACENT TO the fresh-wipe arm so a future reader cannot "fix" the fresh path by relaxing
     * `resume`: an empty journal genuinely has nothing to resume, and a crash path that invented a wipe would be a far
     * worse defect than the one being repaired.
     */
    @Test
    fun resumeStillRefusesAnEmptyJournalBecauseThatIsTheCrashPath() {
        val journal = RecordingJournal()
        val result = coordinator(journal).resume()

        assertTrue("resume on an empty journal must stay Refused: $result", result is WipeStepResult.Refused)
        assertTrue(
            "and the refusal must SAY why: ${(result as WipeStepResult.Refused).reason}",
            result.reason.contains("nothing to resume"),
        )
        assertEquals("and nothing may have been written", emptyList<String>(), journal.writes)
    }

    /**
     * A REQUESTED-BUT-UNSTARTED WIPE IS THE CRASH PATH'S OWN CASE: `resume` MUST DRIVE IT.
     *
     * This is the complement the first arm needs -- `requestWipe` for a NEW operation, `resume` for one that already
     * exists -- and it fails if a future change routes BOTH through one verb in either direction.
     */
    @Test
    fun resumeDrivesAWipeThatWasAlreadyRequested() {
        val journal = RecordingJournal()
        journal.write(PanicWipe.WipeState.RUNTIME_DRAINED)   // requested and drained in a previous process
        val result = coordinator(journal).resume()

        assertTrue("resume must drive an outstanding wipe: $result", result !is WipeStepResult.Refused)
        // THE SPELLING IS THE LEGACY ONE: `PanicWipe.WipeState` nameTH the stage `KEY_ERASED`, while the coordinator's
        // own `WipeJournalState` calls it `KEYS_ERASED` and maps between them on read. My first draft asserted the
        // coordinator's spelling against a journal written in the legacy one and failed on its own wording -- so the
        // assertion now reads the LEGACY name the journal actually carries.
        assertTrue(
            "and it must ADVANCE from where the journal stood rather than restarting: ${journal.writes}",
            journal.writes.contains(PanicWipe.WipeState.KEY_ERASED.name),
        )
    }
}
