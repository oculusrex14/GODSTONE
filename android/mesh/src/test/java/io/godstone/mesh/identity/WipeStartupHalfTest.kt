package io.godstone.mesh.identity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * GS-STORE-006: **THE STARTUP HALF, MEASURED** -- the Android counterpart of what `CrashStartupResumeTests` proved on iOS
 * (rounds 412 and 416: the startup resumes ONLY what needs no platform resource and STOPS, erasing nothing).
 *
 * WHY IT IS PURE JVM AND WHY THAT IS NOT A WEAKNESS: the coordinator is built from the SAME five seams the production roots
 * build it from (round 412's barrier, round 415's runtime-side authority) -- here with an in-memory journal so the assertion
 * can be about the LADDER rather than about a device. The claim under test is the one the card's step 6 makes: "on restart,
 * resume from the durable compatible journal BEFORE opening keys, databases, discovery or a new identity."
 */
class WipeStartupHalfTest {

    /** The smallest honest journal: one typed state, exactly the contract `WipeJournal` declares. */
    private class MemoryJournal(private var state: PanicWipe.WipeState = PanicWipe.WipeState.IDLE) : WipeJournal {
        override fun read(): PanicWipe.WipeState = state
        override fun write(state: PanicWipe.WipeState) { this.state = state }
        override fun clear() { this.state = PanicWipe.WipeState.IDLE }
        fun current(): PanicWipe.WipeState = state
    }

    /** The production startup composition, verbatim: the mapping plus the FOUR DEFERRED SEAMS (MeshModule.kt, round 412). */
    private fun startupCoordinator(journal: WipeJournal) = CrashResumableWipe(
        store = WipeJournalDurabilityAdapter(journal),
        vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
        filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
        runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
        authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
    )

    @Test
    fun theStartupHalfStopsAtRequestedAndErasesNothing() {
        val journal = MemoryJournal(PanicWipe.WipeState.REQUESTED)

        val result = startupCoordinator(journal).resume()

        // THE SUBJECT'S OWN ANSWER FIRST (the lesson iOS paid for at round 376): the DEFERRED TRANSPORT must refuse the
        // drain, so the ladder stops AT `REQUESTED` rather than advancing toward the erasure.
        assertTrue("the deferred transport must refuse the drain -- its answer was $result",
            result is WipeStepResult.RetryLater)
        assertEquals("the deferred transport must stop the ladder AT REQUESTED",
            WipeJournalState.REQUESTED, (result as WipeStepResult.RetryLater).at)
        // *** AND THE SAFE HALF, WHICH IS THE FINDING'S WHOLE POINT: THE JOURNAL HAS NOT MOVED, WHICH MEANS NO KEY WAS
        // ERASED AND NO ARTIFACT DELETED. ***
        assertEquals("NO KEY MAY BE ERASED AT THE STARTUP BARRIER", PanicWipe.WipeState.REQUESTED, journal.current())
    }

    /**
     * *** AND THIS ARM IS STRONGER THAN THE ONE I FIRST WROTE, BECAUSE THE CODE TOLD ME SO: an EMPTY journal and a journal
     * STANDING AT `IDLE` ARE NOT THE SAME STATE, AND THE COORDINATOR DISTINGUISHES THEM -- "nothing was ever requested"
     * (Refused) versus "a wipe ran and finished" (AlreadyAtOrPast). MY FIRST DRAFT ASSERTED AlreadyAtOrPast FOR THE EMPTY
     * CASE AND THE LANE REFUSED IT IN ONE LINE; the expectation was mine and the code was right. ***
     */
    @Test
    fun anEmptyJournalIsRefusedBecauseNothingWasEverRequested() {
        val journal = MemoryJournal()
        val result = startupCoordinator(journal).resume()
        assertTrue("an EMPTY journal must be REFUSED -- nothing was ever requested -- its answer was $result",
            result is WipeStepResult.Refused)
        assertTrue("and the refusal must SAY why: '${(result as WipeStepResult.Refused).reason}'",
            (result as WipeStepResult.Refused).reason.contains("nothing to resume"))
        assertEquals(PanicWipe.WipeState.IDLE, journal.current())
    }

    /**
     * *** AND THIS ARM RECORDS A PROPERTY OF MY OWN ADAPTER THAT THE LANE TAUGHT ME, RATHER THAN ONE I ASSUMED: THE MAPPING
     * REPORTS `.IDLE` AS **NO CHECKPOINT AT ALL**, so an IDLE journal and an EMPTY one are INDISTINGUISHABLE THROUGH IT --
     * and the coordinator therefore REFUSES both ("nothing to resume"), which is the SAME sentence it gives a fresh install.
     *
     * IS THAT RIGHT? IT IS DEFENSIBLE AND IT IS NOW RECORDED RATHER THAN HIDDEN: THE LADDER'S CHECKPOINTS MATTER ONLY WHILE
     * A WIPE IS PENDING, and `IDLE` meaneth "no wipe is pending" -- the isle's own `FileWipeJournal` doc says a leftover IDLE
     * marker "is harmless". iOS's adapter makes the SAME collapse (`state == .idle ? [] : [stage]`), so the two isles agree.
     * WHAT WOULD BE WRONG IS PRETENDING THE TWO STATES DIFFER IN A WAY A READER COULD RELY ON. ***
     */
    @Test
    fun theMappingReportsIdleAsNoCheckpointAndTheCoordinatorRefusesIt() {
        val journal = MemoryJournal(PanicWipe.WipeState.IDLE)
        val adapter = WipeJournalDurabilityAdapter(journal)

        assertEquals("the mapping must report IDLE as NO checkpoint", emptyList<String>(), adapter.readJournal())

        val result = startupCoordinator(journal).resume()
        assertTrue("and the coordinator must refuse it, because no wipe is pending -- its answer was $result",
            result is WipeStepResult.Refused)
        assertEquals(PanicWipe.WipeState.IDLE, journal.current())
    }

    @Test
    fun anUnknownStageNameIsRefusedAndTheCheckpointDoesNotMove() {
        val journal = MemoryJournal()
        val adapter = WipeJournalDurabilityAdapter(journal)

        adapter.appendJournal("REQUESTED")
        assertEquals(PanicWipe.WipeState.REQUESTED, journal.current())

        // THE NEGATIVE CONTROL: a stage the isle's own vocabulary does not contain must be REFUSED rather than dropped,
        // because a dropped checkpoint is a wipe that restarts LATER than it should.
        adapter.appendJournal("NOT_A_LADDER_STAGE")
        assertEquals("AN UNKNOWN STAGE MUST BE REFUSED: the checkpoint must NOT move",
            PanicWipe.WipeState.REQUESTED, journal.current())
        assertTrue("and the isle's own spelling is what the ladder names",
            WipeJournalDurabilityAdapter.LADDER.contains("RUNTIME_DRAINED"))
    }

    @Test
    fun theIslesOwnSpellingIsKeyErasedAndTheOtherIslesIsTolerated() {
        // THE MIRROR LAW, AS A MEASURABLE CLAIM: this isle WRITES `KEY_ERASED` and TOLERATES `KEYS_ERASED`, so a wire name
        // from the other side is not silently dropped while this isle's own vocabulary is what it emits.
        assertEquals(PanicWipe.WipeState.KEY_ERASED, WipeJournalDurabilityAdapter.stateFor("KEY_ERASED"))
        assertEquals(PanicWipe.WipeState.KEY_ERASED, WipeJournalDurabilityAdapter.stateFor("KEYS_ERASED"))
        assertEquals("KEY_ERASED", WipeJournalDurabilityAdapter.stageFor(PanicWipe.WipeState.KEY_ERASED))
        assertEquals("RUNTIME_DRAINED", WipeJournalDurabilityAdapter.stageFor(PanicWipe.WipeState.RUNTIME_DRAINED))
    }
}
