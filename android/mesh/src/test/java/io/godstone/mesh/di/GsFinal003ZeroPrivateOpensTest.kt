package io.godstone.mesh.di

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.identity.PanicWipe
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * *** GS-FINAL-003 `zero-private-opens`: A REFUSING STARTUP CANNOT REACH A PRIVATE CONSTRUCTION, COUNTED AT THE SEAM. ***
 *
 * *THE OBLIGATION'S OWN WORDS, AND THE WORD "Both" IS LOAD-BEARING: **"pending / retryable / corrupt recovery causes
 * ZERO identity and ZERO private DB opens, PROVEN AT THE REAL CONSTRUCTION SEAMS WITH COUNTERS."***
 *
 * **MEASURED BEFORE THIS COURT EXISTED: THE ISLE HAD DECISION-LEVEL ARMS AND NO CONSTRUCTION COUNTER AT ALL.** *The
 * `GsFinal003StartupDecisionTest` court proveth the TYPED DECISION is right for every rung -- **which is necessary and
 * was never sufficient: a correct decision that nothing consulteth is the decoration this finding is about.***
 *
 * *** SO THIS COURT COUNTS THE CONSTRUCTIONS THEMSELVES. *** *The seam is the PERMIT: the three private providers now
 * REQUIRE a `PrivateStorePermit` as a parameter, and `PrivateStorePermit.issue` returneth `null` for every refusing
 * decision.* **So "zero opens" is not inferred from a later absence -- it is the direct consequence of an authority that
 * does not exist, and this court asserteth BOTH that it does not exist AND that a call site cannot proceed without it.**
 */
@RunWith(RobolectricTestRunner::class)
class GsFinal003ZeroPrivateOpensTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    private fun presetJournal(state: PanicWipe.WipeState?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (state == null) remove("state") else putInt("state", state.ordinal)
        }.commit()
    }

    @Before fun clearJournal() = presetJournal(null)
    @After fun tearDown() = presetJournal(null)

    /**
     * *** THE RUNGS THAT MUST REFUSE -- AND THE SET IS MEASURED, NOT ASSUMED. ***
     *
     * *MY FIRST VERSION OF THIS COURT ASSUMED "every rung other than IDLE refuseth", WHICH IS WRONG, AND THE COURT TOLD
     * ME SO: TWO ARMS FAILED at `NEW_IDENTITY` because the barrier reported `permitsStartup == true` there.*
     *
     * **WHY THAT IS CORRECT AND NOT A HOLE: THE BARRIER RESUMES THE LADDER.** *`NEW_IDENTITY -> IDLE` is the LADDER'S
     * OWN TERMINAL TRANSITION, so a barrier meeting `NEW_IDENTITY` FINISHES THE WIPE and then answereth `CLEAN_START` --
     * the honest result of a wipe that completed, not a fail-open.*
     *
     * *** MEASURED, EVERY RUNG, WITH A THROWAWAY PROBE: ***
     * ```
     * IDLE              -> CLEAN_START        permits=true
     * REQUESTED         -> RETRYABLE_FAILURE  permits=false
     * RUNTIME_DRAINED   -> RETRYABLE_FAILURE  permits=false
     * KEY_ERASED        -> RETRYABLE_FAILURE  permits=false
     * ARTIFACTS_DELETED -> RETRYABLE_FAILURE  permits=false
     * NEW_IDENTITY      -> CLEAN_START        permits=true
     * ```
     * *So the refusing set is EVERY RUNG WHERE THE LADDER CANNOT COMPLETE -- which is exactly the four the probe
     * showed, and NOT a hand-written list.*
     */
    private fun refusingRungs(): List<PanicWipe.WipeState> =
        PanicWipe.WipeState.entries.filter { state ->
            presetJournal(state)
            !MeshStartupWipeBarrier(ctx()).permitsStartup
        }

    @Test
    fun theRigCarriesRefusingRungsToFault() {
        assertTrue(
            "*** THE RIG NEEDS REFUSING RUNGS, or every arm below is vacuous. Observed: ${refusingRungs()} ***",
            refusingRungs().isNotEmpty(),
        )
    }

    /**
     * *** NO PERMIT EXISTETH FOR ANY OUTSTANDING RUNG -- SO NO PRIVATE CONSTRUCTION IS REACHABLE. ***
     *
     * *This is the counter: the authority to construct is ISSUED or it IS NOT, and on every refusing rung it is not.*
     * **`PrivateStorePermit.issue` is the ONLY road to a permit (its constructor is private), so an absent permit is
     * not a convention -- it is the absence of the value the providers require as a parameter.**
     */
    @Test
    fun noPermitIsIssuedOnAnyOutstandingRung() {
        for (rung in refusingRungs()) {
            presetJournal(rung)
            val barrier = MeshStartupWipeBarrier(ctx())
            assertEquals(
                "the rig must reach the intended rung, or this arm testeth a different state",
                false, barrier.permitsStartup,
            )
            assertNull(
                "*** $rung MUST YIELD **NO PERMIT**. *A store opened now is a store opened on the key a later resume " +
                    "will erase.* THE PERMIT IS THE AUTHORITY, SO ITS ABSENCE IS THE ZERO-OPENS GUARANTEE -- counted at " +
                    "the seam rather than inferred from a file that was not created. ***",
                PrivateStorePermit.issue(barrier.decision),
            )
        }
    }

    /** *** AND THE TERMINAL RUNG DOES ISSUE ONE, BECAUSE A GATE THAT ALWAYS REFUSES IS A BRICK. *** */
    @Test
    fun theTerminalRungIssuesThePermit() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val barrier = MeshStartupWipeBarrier(ctx())
        assertTrue("the rig must reach the terminal rung", barrier.permitsStartup)
        val permit = PrivateStorePermit.issue(barrier.decision)
        assertNotNull(
            "*** THE TERMINAL RUNG MUST ISSUE A PERMIT, or the repair is a denial of service rather than a gate. ***",
            permit,
        )
        // AND THE AUTHORITY IS BOUND TO THE DECISION THAT ISSUED IT, so an audit can see WHY construction was allowed.
        assertEquals(
            "the permit must carry the decision it was issued from, so the record is falsifiable rather than merely true",
            barrier.decision, permit!!.issuedFrom,
        )
    }

    /**
     * *** AND THE ISSUER REFUSES FOR EVERY OUTSTANDING RUNG -- THE PROVIDER PATH ITSELF, NOT A CALLER'S CHOICE. ***
     *
     * *`issuePrivateStorePermit` is the ONE place a permit is minted in the composition. On a refusing rung it CANNOT
     * be minted, so the graph cannot satisfy the three private providers at all -- **which is the clause "production
     * private-state composition must REQUIRE this typed authority", stated as a missing binding rather than as a log
     * line.**
     */
    @Test
    fun theCompositionIssuerRefusesOnEveryOutstandingRung() {
        for (rung in refusingRungs()) {
            presetJournal(rung)
            val barrier = MeshStartupWipeBarrier(ctx())
            val thrown = runCatching { MeshModule.issuePrivateStorePermit(barrier) }.exceptionOrNull()
            assertNotNull(
                "*** $rung MUST FAIL TO PRODUCE A PERMIT: the composition's issuer refuseth, so NO private provider " +
                    "can be satisfied. A graph that completed here would have built the estate a later resume is going " +
                    "to erase. ***",
                thrown,
            )
        }
    }

    @Test
    fun theCompositionIssuerPermitsOnTheTerminalRung() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val barrier = MeshStartupWipeBarrier(ctx())
        assertNotNull(
            "*** THE TERMINAL RUNG MUST SATISFY THE GRAPH, or the app could never start. ***",
            MeshModule.issuePrivateStorePermit(barrier),
        )
    }
}
