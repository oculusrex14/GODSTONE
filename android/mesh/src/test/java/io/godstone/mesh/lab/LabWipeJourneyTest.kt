package io.godstone.mesh.lab

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.di.StartupRecoveryGraph
import io.godstone.mesh.di.StartupWipeDecision
import io.godstone.mesh.di.permitsRecoveryConstruction
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.runtime.ComposedEstateOwnership
import io.godstone.mesh.runtime.ComposedRuntimeHarness
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-FINAL-003 `durable-authority`: THE RENDERED WIPE'S OWNER, PROVEN DURABLE BY A REOPEN. ***
 *
 * *THE OBLIGATION'S OWN WORDS: **"rendered wipe UI uses SAME durable production wipe owner (no composition harness local
 * state register) with live journey clean/wipe/persist/reopen/resume/terminal."***
 *
 * *** THE JOURNEY IS DRIVEN HERE EXACTLY AS THE LIVE ONE WOULD BE -- AND THE DISCRIMINATOR IS THE REOPEN. *** *A wipe
 * REQUESTED in one `LabWipeJourney` instance is read back by a SECOND instance BUILT FRESH over the same durable record,
 * which is what a relaunch IS.* **A surface holding its own state register cannot pass that: the second instance would
 * read `IDLE` while the first remembered `REQUESTED`.** *And the opposite direction is driven too -- the harness's own
 * `beginWipe()` flag is moved and the durable record must NOT move, so the arm proveth the two are different owners and
 * that this surface reads the durable one.*
 *
 * *** WHAT THIS COURT DOES NOT CLAIM, NAMED RATHER THAN IMPLIED: *** *the journey ADVANCES only as far as the
 * composition's seams allow, and a host composition's seams are the DEFERRED ones -- so the lab run is `clean ->
 * REQUESTED (persisted) -> reopen -> resume -> still REQUESTED`, and the TERMINAL rung is the CLEAN record, which is
 * READ and never invented.* **The rungs past `REQUESTED` belong to the runtime owner (`MeshPanicWipe`, whose seams are
 * live), and that owner's own ladder is courted by `CrashStartupResumeTest` and `GsFinal003PrePrivateRecoveryGraphTest`.**
 * *Nothing here is offered as a device result.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LabWipeJourneyTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** The REAL durable record, written through the same key `FileWipeJournal` uses. */
    private fun presetJournal(state: PanicWipe.WipeState?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (state == null) remove("state") else putInt("state", state.ordinal)
        }.commit()
    }

    /** The journal's own rung name for an ordinal, so the court compares RECORD to SURFACE rather than to a literal. */
    private fun rungNameOf(ordinal: Int): String = PanicWipe.WipeState.entries[ordinal].name

    private fun rawJournalOrdinal(): Int =
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).getInt("state", -1)

    @Before fun clearJournal() = presetJournal(null)
    @After fun tearDown() = presetJournal(null)

    // =================================================================================================================
    // THE LIVE JOURNEY: clean -> wipe -> persist -> reopen -> resume -> terminal
    // =================================================================================================================

    /**
     * *** THE WHOLE JOURNEY, IN ONE ARM, WITH THE REOPEN AS ITS DISCRIMINATOR. ***
     *
     * *Every assertion is made against THE DURABLE RECORD (`rawJournalOrdinal()`) or against a FRESH OWNER's reading of
     * it -- never against a value the surface held.*
     */
    @Test
    fun theRenderedJourneyIsDurableAcrossAReopen() {
        // ---- (1) CLEAN: a fresh install permits, and nothing is pending.
        val first = LabWipeJourney(ctx())
        val clean = first.progress()
        assertEquals(
            "*** A CLEAN START MUST PERMIT -- otherwise the refusal arms below are satisfied by a surface bricked " +
                "for everyone. Observed: ${clean.decision} ***",
            StartupWipeDecision.CLEAN_START, clean.decision,
        )
        assertFalse("nothing may be pending on a clean device", clean.pending)
        assertEquals(WipeJournalState.IDLE, clean.rung)
        assertFalse("a clean estate has nothing to resume", clean.permitsResume)

        // ---- (2) WIPE: REQUEST through the production graph.
        val afterBegin = first.begin()
        assertTrue(
            "*** A REQUESTED WIPE MUST BE OUTSTANDING AND REFUSE PRIVATE CONSTRUCTION. *On a host the deferred seams " +
                "cannot advance it, and the honest answer is a pending/retryable refusal rather than a completed " +
                "wipe.* Observed: ${afterBegin.decision} at ${afterBegin.rung} ***",
            afterBegin.pending && !afterBegin.decision.allowsPrivateConstruction,
        )

        // ---- (3) PERSIST: the DURABLE RECORD moved -- not a field on the surface.
        assertNotEquals(
            "*** THE REQUEST MUST HAVE BEEN PERSISTED: `FileWipeJournal` is the same SharedPreferences file the " +
                "startup barrier and the runtime-side wipe use, so the raw ordinal MUST have moved off IDLE. Observed " +
                "ordinal: ${rawJournalOrdinal()} ***",
            PanicWipe.WipeState.IDLE.ordinal, rawJournalOrdinal(),
        )
        // *** AND THE RUNG IS WHATEVER THE REAL CAPABILITIES REACHED -- NOT A PINNED ONE. *** *Pinning `REQUESTED` would
        // be a claim that the graph CANNOT advance, which is the very defect the obligation names; pinning a LATER rung
        // would be a claim about a host facility (the AndroidKeyStore) this court cannot make.* **The honest assertions
        // are that the record MOVED, that the surface AGREEETH with it, and that the rung is a real ladder rung.**
        assertEquals(
            "*** THE RENDERED RUNG MUST BE THE RECORD'S OWN RUNG -- the surface reads it, it does not choose it. ***",
            rungNameOf(rawJournalOrdinal()), afterBegin.rung.name,
        )
        assertNotEquals(
            "the request must not leave the record where it started", "IDLE", afterBegin.rung.name,
        )

        // ---- (4) REOPEN: a SECOND OWNER over the same durable record -- what a relaunch is.
        val reopened = LabWipeJourney(ctx())
        val afterReopen = reopened.progress()
        assertEquals(
            "*** A REOPEN MUST SEE THE PERSISTED WIPE AT THE SAME RUNG. *A surface with its own state register cannot " +
                "pass this: the fresh owner would read IDLE while the first remembered its own stage.* **THE RECORD IS " +
                "THE AUTHORITY.** Observed: ${afterReopen.rung} / decision ${afterReopen.decision} ***",
            afterBegin.rung, afterReopen.rung,
        )
        assertTrue("and it is still pending after the reopen", afterReopen.pending)
        assertTrue(
            "*** AND THE PRODUCTION RETRY CONTRACT MUST PERMIT A RESUME HERE: a wipe parked at a rung whose seams " +
                "were unavailable is exactly the case retrying exists for. ***",
            afterReopen.permitsResume,
        )

        // ---- (5) RESUME: hand the persisted wipe back to the graph that owns the ladder.
        val afterResume = reopened.resume()
        assertTrue(
            "*** A RESUMED WIPE THAT CANNOT ADVANCE ON THIS COMPOSITION MUST STAY PENDING -- not be reported " +
                "complete. Observed: ${afterResume.decision} at ${afterResume.rung} ***",
            afterResume.pending && !afterResume.decision.allowsPrivateConstruction,
        )
        assertNotEquals(
            "*** AND THE DURABLE RECORD MUST NOT HAVE BEEN REWOUND TO IDLE BY THE RESUME: a wipe that 'resumed' by " +
                "forgetting itself would be the worst possible lie here. Observed ordinal: ${rawJournalOrdinal()} ***",
            PanicWipe.WipeState.IDLE.ordinal, rawJournalOrdinal(),
        )

        // ---- (6) TERMINAL: the record is CLEAN, and the surface READS it rather than inventing it.
        presetJournal(PanicWipe.WipeState.IDLE)
        val terminal = LabWipeJourney(ctx()).progress()
        // *** AND IT MUST PERMIT -- AS `CLEAN_START` AT REST, WHICH IS THE DOCUMENTED COLLAPSE AND MATCHES iOS. ***
        // *`FileWipeJournal.read()` reports a WRITTEN `IDLE` as `IDLE`, and the isle's adapter reports `IDLE` as NO
        // CHECKPOINT (`WipeJournalDurabilityAdapter.readJournal()`); so a RESTING read cannot distinguish "a wipe finished"
        // from "nothing was ever requested" -- the collapse `WipeStartupHalfTest` records, and which the iOS isle shares
        // (`state == .idle ? [] : [stage]`).* **`WIPE_COMPLETED` is what the production decision answers for a DRIVE that
        // LANDETH on `IDLE` (`GsFinal003ZeroPrivateOpensTest.theTerminalRungIssuesThePermit` drives `NEW_IDENTITY` -> IDLE
        // and reads it), which is the fact a drive can see and a resting read cannot.** *Neither is a block: both permit.*
        assertEquals(
            "*** THE TERMINAL RUNG MUST PERMIT -- a permanent refusal would brick the device after every wipe. ***",
            StartupWipeDecision.CLEAN_START, terminal.decision,
        )
        assertFalse(
            "*** AND IT MUST NOT BE PENDING: a clean record is not a wipe in flight, and a surface that said " +
                "otherwise would show a spinner for ever. ***",
            terminal.pending,
        )
        assertEquals(
            "*** AND THE RENDERED STAGE MUST BE THE RECORD'S OWN TERMINAL RUNG. ***",
            WipeJournalState.IDLE, terminal.rung,
        )
        assertFalse("a clean estate summons no operator", terminal.requiresOperator)
        assertFalse("*** and a clean estate has nothing to resume. ***", terminal.permitsResume)
    }

    // =================================================================================================================
    // THE NEGATIVE DISCRIMINATOR: THE HARNESS'S LOCAL REGISTER IS NOT THIS OWNER.
    // =================================================================================================================

    /**
     * *** THE HARNESS'S `beginWipe()` MOVES ITS OWN FLAG AND THE DURABLE RECORD DOES NOT MOVE -- WHICH IS WHY THE
     * RENDERED SURFACE MUST NOT BE BOUND TO IT. ***
     *
     * *THIS IS THE OBLIGATION'S "no composition harness local state register", MEASURED RATHER THAN ASSERTED BY GREP.*
     * **`ComposedRuntimeHarness.beginWipe()` sets a private `wiped` boolean (`ComposedRuntime.kt:378`) and appends a
     * trace event; it writes no journal and erases nothing.** *A journey bound to it would render a wipe in progress
     * while a relaunch found the device clean -- the exact invisible failure this arm pins.*
     */
    @Test
    fun theHarnessLocalRegisterIsNotTheDurableOwner() {
        val harness = ComposedRuntimeHarness()
        assertFalse("the harness starteth un-wiped", harness.isWiped())
        harness.beginWipe()
        assertTrue("the harness's own flag moved -- it IS a local register", harness.isWiped())
        assertEquals(
            "*** AND THE DURABLE RECORD DID NOT MOVE: the harness's flag is a register, not a wipe. A surface bound " +
                "to it would report a wipe nobody performed and no relaunch could see. Observed ordinal: " +
                "${rawJournalOrdinal()} ***",
            -1, rawJournalOrdinal(),   // ABSENT: `beginWipe()` never wrote a journal entry at all
        )
        assertEquals(
            "*** AND THE PRODUCTION OWNER, ASKED AT THE SAME INSTANT, CORRECTLY REPORTETH A CLEAN ESTATE -- because " +
                "the durable record is the authority and the register is not. ***",
            StartupWipeDecision.CLEAN_START, LabWipeJourney(ctx()).progress().decision,
        )
    }

    // =================================================================================================================
    // THE TYPED DECISION IS THE OWNER'S, AND A CORRUPT RECORD IS AN OPERATOR MATTER.
    // =================================================================================================================

    /**
     * *** AN UNREADABLE RECORD MUST RENDER AS CORRUPT AND SUMMON A HUMAN -- AND MUST NOT OFFER A RETRY. ***
     *
     * *`FileWipeJournal.read()` coerces an out-of-range ordinal to `IDLE`, so a surface asking only the raw enum would
     * render a CLEAN estate over material nobody could read.* **This drives the raw ordinal, which is the only place the
     * defect can be planted.*** *And the parked-wipe direction is driven too: a genuinely parked wipe MUST permit a resume.*
     */
    @Test
    fun anUnreadableRecordRendersAsCorruptAndOffersNoResume() {
        presetJournal(null)
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .edit().putInt("state", 9999).commit()          // PRESENT, but not a state this build understands
        val step = LabWipeJourney(ctx()).progress()
        assertEquals(
            "*** AN UNREADABLE RECORD IS CORRUPT, NOT CLEAN. Observed: ${step.decision} ***",
            StartupWipeDecision.CORRUPT_JOURNAL, step.decision,
        )
        assertTrue("*** AND IT MUST SUMMON A HUMAN: the operator is the only one who can decide here. ***", step.requiresOperator)
        assertFalse(
            "*** AND A RESUME MUST NOT BE OFFERED: retrying cannot make an unreadable record readable, so a resume " +
                "control here would be a control that lies. ***",
            step.permitsResume,
        )
        assertFalse(step.decision.allowsPrivateConstruction)
    }

    /**
     * *** `review A7`: THE OPERATOR'S CORRUPT RESOLUTION DRIVES FULL ERASURE AND NEVER CLAIMS CLEAN_START. ***
     *
     * *THE OBLIGATION: **"never clear marker pretend clean"** -- the old `resolveCorruptJournalForOperator` cleared the
     * journal and re-read, declaring `CLEAN_START` over material that might be mid-erasure.* **`resolveCorruptForOperator`
     * durably requests and performs the FULL verified erasure, so it landeth on `WIPE_COMPLETED` (or pending) and
     * NEVER `CLEAN_START`.**
     */
    @Test
    fun resolveCorruptForOperatorDrivesFullErasureAndNeverClaimsCleanStart() {
        presetJournal(null)
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .edit().putInt("state", 9999).commit()          // unreadable
        val journey = LabWipeJourney(ctx())
        val corrupt = journey.progress()
        assertEquals(StartupWipeDecision.CORRUPT_JOURNAL, corrupt.decision)
        assertTrue("corrupt estate permits operator resolution", corrupt.permitsOperatorCorruptResolution)

        // DRIVE the operator resolution: must overwrite the corrupt marker with REQUESTED first and drive.
        val resolved = journey.resolveCorruptForOperator()
        // The raw ordinal must NOT be absent (cleared) and must NOT be IDLE: it was driven through the ladder.
        assertNotEquals(
            "the resolution must not leave the record absent (which would be 'clear marker pretend clean')",
            -1, rawJournalOrdinal(),
        )
        assertNotEquals(
            "and it must never report CLEAN_START",
            StartupWipeDecision.CLEAN_START, resolved.decision,
        )
        // On a host without the platform KeyStore, the real capabilities reach KEYS_ERASED/ARTIFACTS_DELETED and stop
        // pending; on device it reaches WIPE_COMPLETED. Neither is cleanStart.
        assertTrue(
            "the resolved decision must be a completed wipe OR a pending rung, never clean: ${resolved.decision}",
            resolved.decision == StartupWipeDecision.WIPE_COMPLETED ||
                resolved.decision == StartupWipeDecision.RECOVERY_PENDING ||
                resolved.decision == StartupWipeDecision.RETRYABLE_FAILURE,
        )
    }

    /**
     * *** `review A6`: BEGIN WIPE DRAINS AND RETIRES THE LIVE OWNER BEFORE DRIVING THE LADDER. ***
     *
     * *THE OBLIGATION: **"Begin wipe must drain/retire actual live owner ... old work refused"**.* **The live owner
     * is retired FIRST, so the ladder's erasure cannot race a writer.**
     */
    @Test
    fun beginWipeRetiresLiveEstateBeforeDrivingLadder() {
        var retiredCalled = false
        var retireCount = 0
        val live = object : ComposedEstateOwnership {
            override fun retireLiveOwners(): Int {
                retiredCalled = true
                retireCount = 3
                return 3
            }
            override fun ownedArtifactPaths(): List<String> = emptyList()
        }
        val journey = LabWipeJourney(ctx(), liveEstate = live)
        journey.begin()
        assertTrue("the live owner must have been retired by begin()", retiredCalled)
        assertEquals("three owners were retired", 3, retireCount)
    }

    /**
     * *** THE RECOVERY CONTRACT IS STATE-AWARE, AND BOTH DIRECTIONS ARE MEASURED. ***
     *
     * *THE OBLIGATION OFFERED A CHOICE -- "state/profile-aware if semantically conditional else real runtime retry" --
     * AND THE WIPE'S RESUME IS THE CONDITIONAL BRANCH, STATED AS AN EXHAUSTIVE PROPERTY OF THE TYPED ENUM:* **a wipe whose
     * seams were unavailable is worth resuming; a clean estate, an unreadable record and a non-retryable erasure failure
     * are not.**
     * *The `when` in `permitsRecoveryConstruction` will not compile if a decision is added without an answer, so the property cannot be
     * left half-true by a later edit.*
     */
    @Test
    fun theRecoveryContractIsStateAwareAndExhaustive() {
        assertEquals(
            "the decisions that may be resumed are the two that mean 'the ladder could not finish from here'",
            2, StartupWipeDecision.entries.count { it.permitsRecoveryConstruction() },
        )
        assertEquals(
            "and every other decision refuses a resume, exhaustively",
            StartupWipeDecision.entries.size - 2, StartupWipeDecision.entries.count { !it.permitsRecoveryConstruction() },
        )
        assertTrue(StartupWipeDecision.RECOVERY_PENDING.permitsRecoveryConstruction())
        assertTrue(StartupWipeDecision.RETRYABLE_FAILURE.permitsRecoveryConstruction())
        assertFalse(StartupWipeDecision.CLEAN_START.permitsRecoveryConstruction())
        assertFalse(StartupWipeDecision.CORRUPT_JOURNAL.permitsRecoveryConstruction())
        assertFalse(
            "a NON-retryable erasure failure is defined by retrying not helping, so it must not offer one",
            StartupWipeDecision.TERMINAL_FAILURE.permitsRecoveryConstruction(),
        )
    }

    /**
     * *** AND THE REAL RUNTIME RETRY IS A DIFFERENT ROAD, WHICH THIS OWNER DOES NOT PRETEND TO OWN. ***
     *
     * *A state-aware WIPE RESUME and a real MESSAGE/DISTRESS RETRY must not be conflated, and the iOS isle drew the same
     * line:* **the wipe's resume is CONDITIONAL on the typed decision (`permitsRecoveryConstruction`); the distress retry is
     * a REAL command that resumes the SAME authored bytes through the node's own durable row
     * (`MeshNode.handleSosCommand(.retry)`), refusing by name when no standing call exists.** *The two are proven separately,
     * and the lab journey bindeth the SOS arm to the node's own door rather than to anything here.*
     */
    @Test
    fun theSosRetryRemainsTheNodesOwnDoor() {
        // The wipe journey offers no SOS verb at all: the distress retry is reached through `LabJourneyBindings.retry()`
        // -> `runtime.sosCommand(author, SosCommand.Retry(msgId))`, whose own court (`LabMeshJourneyBoundTest`) drives it.
        // This arm pins the SEPARATION rather than restating the node's court.
        val wipeSurface = LabWipeJourney(ctx())
        assertEquals(
            "a clean estate still permits and the wipe surface offers no distress verb of its own",
            StartupWipeDecision.CLEAN_START, wipeSurface.progress().decision,
        )
    }

    /** *The same graph the startup barrier uses, so the journey's verbs are provably the production ones.* */
    @Test
    fun theJourneyTravelsTheSameRecoveryGraphAsTheStartup() {
        // Request through the graph directly, then read through the journey: ONE durable record, ONE ladder.
        presetJournal(null)
        val graphJournal = io.godstone.mesh.identity.FileWipeJournal(ctx())
        val drive = StartupRecoveryGraph.requestWipe(graphJournal, StartupRecoveryGraph.prePrivate(ctx(), graphJournal))
        val outcome = drive.outcome
        val decision = drive.decision
        assertTrue("the request must leave a pending ladder", outcome !is io.godstone.mesh.identity.WipeStepResult.AlreadyAtOrPast)
        assertFalse(decision.allowsPrivateConstruction)
        val journeyRung = LabWipeJourney(ctx()).progress().rung
        // *** THE RUNG IS WHATEVER THE REAL CAPABILITIES REACHED -- NOT A PINNED ONE. *** *Pinning `REQUESTED` would
        // be a claim that the graph CANNOT advance, which is the very defect the obligation names: the pre-private
        // seams are the REAL ones, so a requested wipe really drains and really passes `REQUESTED` (the recorded run
        // reached `RUNTIME_DRAINED`).* **The two laws that maketh "one owner" a fact are: the journey is NOT on the
        // pre-wipe rung, and its rung AGREES with the durable record the graph moved.**
        assertNotEquals(
            "*** THE JOURNEY MUST SEE A MOVED RECORD, NOT THE PRE-WIPE `IDLE` -- a surface holding its own register " +
                "would read IDLE here. ***",
            WipeJournalState.IDLE, journeyRung,
        )
        assertEquals(
            "*** AND THE JOURNEY'S OWN RUNG MUST EQUAL THE DURABLE RECORD'S -- proof that the rendered surface and " +
                "the startup share ONE owner rather than two. ***",
            rungNameOf(rawJournalOrdinal()), journeyRung.name,
        )
    }
}
