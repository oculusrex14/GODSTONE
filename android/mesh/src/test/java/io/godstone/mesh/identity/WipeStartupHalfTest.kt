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

    // MARK: - THE CARD'S FIRST CLOSURE CLAUSE: A HELD WRITE

    /** A transport seam whose work stands until the test RELEASES it -- the held write completion, in seam form. */
    private class HeldTransport(var inFlight: Int) : TransportRuntimeSeam {
        var drains = 0
        override fun drainTransport(): RuntimeDrainReceipt {
            drains += 1
            return if (inFlight > 0) RuntimeDrainReceipt.NotDrained("$inFlight write(s) still in flight at the bound")
            else RuntimeDrainReceipt.Drained(closedTransports = 1, quiescedRuntime = true)
        }
        override fun isQuiesced(): Boolean = inFlight == 0
        override fun fireRadio(msg: String): Boolean = false
        override fun sendVia(msg: String): Boolean = false
    }

    /** A vault seam that COUNTS what it was asked to erase -- so "blocked" is a number rather than a claim. */
    private class RecordingVault : KeyVaultSeam {
        var erasures = 0
        override fun eraseKey(name: String): KeyDeletionResult {
            erasures += 1
            return KeyDeletionResult.Deleted
        }
    }

    /**
     * *** THE CARD'S FIRST CLOSURE CLAUSE, MEASURED: "Drive the real runtime wipe entry point with a HELD WRITE COMPLETION.
     * KEY DELETION MUST REMAIN BLOCKED UNTIL TRANSPORT DRAIN COMPLETETH." ***
     *
     * AND ITS HONEST SCOPE, STATED RATHER THAN IMPLIED: this arm holds a write at the SEAM, which is where the coordinator
     * can see it -- it does NOT drive a real `BleTransport` (that is a concrete class needing a device or an instrumented
     * harness, and the isle's own `w.inFlightForTest()` seam is what an instrumented arm would use). WHAT IT PROVES IS THE
     * ORDER, WHICH IS THE CLAUSE'S SUBSTANCE: no key is touched while the drain is refused, and keys are touched only after.
     */
    @Test
    fun keyDeletionRemainsBlockedUntilTheHeldWriteCompletes() {
        val journal = MemoryJournal(PanicWipe.WipeState.REQUESTED)
        val transport = HeldTransport(inFlight = 1)          // a write IS in flight
        val vault = RecordingVault()
        val coordinator = CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(journal),
            vault = vault,
            filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
            runtime = transport,
            authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
        )

        val held = coordinator.resume()

        assertTrue("the ladder must stop while the write is in flight -- its answer was $held",
            held is WipeStepResult.RetryLater)
        assertEquals("and it must stop AT REQUESTED, before the erasure rung",
            WipeJournalState.REQUESTED, (held as WipeStepResult.RetryLater).at)
        // *** THE CLAUSE ITSELF, AS A NUMBER: NOT ONE KEY WAS TOUCHED. ***
        assertEquals("KEY DELETION MUST REMAIN BLOCKED UNTIL TRANSPORT DRAIN COMPLETES", 0, vault.erasures)
        assertEquals(PanicWipe.WipeState.REQUESTED, journal.current())

        transport.inFlight = 0                                // the held write COMPLETES

        val after = coordinator.resume()

        // *** AND HERE A THIRD EXPECTATION OF MINE WAS CORRECTED BY THE LANE, WHICH IS WHY THIS ARM IS NOW MORE INFORMATIVE
        // THAN THE ONE I WROTE: WITH THE DRAIN GRANTED THE LADDER ADVANCES **TO THE ERASURE** AND THEN STOPS AT THE NEXT
        // UNMET NEED -- the DEFERRED FILESYSTEM in this composition -- SO THE ANSWER IS RetryLater AT `KEY_ERASED`, NOT
        // `Advanced`. THE CLAUSE'S SUBSTANCE IS UNTOUCHED AND IS NOW VISIBLE IN THE JOURNAL ITSELF: THE KEYS WERE ERASED
        // **ONLY AFTER** THE DRAIN, AND THE WIPE DID NOT CLAIM A COMPLETION IT HAD NOT PERFORMED. ***
        assertTrue("with the write released the ladder must ADVANCE PAST THE DRAIN -- its answer was $after",
            after is WipeStepResult.RetryLater)
        // *** AND A DETAIL OF THIS ISLE THAT IS WORTH THE LINE IT COSTS: THE **COORDINATOR'S** ENUM SPELLS IT
        // `KEYS_ERASED` WHILE THE **JOURNAL'S** ENUM SPELLS IT `KEY_ERASED` -- TWO VOCABULARIES WITHIN THE SAME ISLE, WITH
        // `fromWire("KEY_ERASED") -> KEYS_ERASED` BRIDGING THEM. THE MIRROR LAW IS THEREFORE NOT MERELY ABOUT ISLES. ***
        assertEquals("and it must now stand AT the erasure it just reached (the COORDINATOR's spelling)",
            WipeJournalState.KEYS_ERASED, (after as WipeStepResult.RetryLater).at)
        assertEquals("so the KEYS WERE ERASED -- but only after the drain",
            PanicWipe.WipeState.KEY_ERASED, journal.current())
        assertTrue("and ONLY THEN were keys erased (erasures = ${vault.erasures})", vault.erasures > 0)
        assertEquals("so the drain was asked twice and refused once", 2, transport.drains)
    }
}
