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
    /**
     * *** THE REFUSING ROSTER IS AN **EXPECTATION**, NOT A SELECTION -- OR A RUNG THAT FLIPS LEAVETH COVERAGE SILENTLY. ***
     *
     * *MY FIRST VERSION SELECTED the roster with `!barrier.permitsStartup` and THEN asserted `permitsStartup == false`.
     * **THAT IS TAUTOLOGICAL TWICE OVER:** the selection criterion IS the assertion, and `permitsStartup` IS `issue`'s
     * gate -- so `assertNull(issue(decision))` merely restateth the criterion that chose the rung.*
     *
     * *** WORSE, IT IS NOT FALSIFIABLE: if a future edit made `REQUESTED` report `CLEAN_START`, the roster would simply
     * DROP that rung, every loop would shrink, and `theRigCarriesRefusingRungsToFault` would still pass because it only
     * checketh the list is NON-EMPTY -- four rungs becoming three is still non-empty. THE COVERAGE WOULD VANISH WHILE
     * THE COURT STAYED GREEN.*** *And the flip is LIVE, not hypothetical: the probe showed `NEW_IDENTITY` already
     * permits.*
     *
     * **SO THE ROSTER IS A LITERAL, AND IT IS ASSERTED AGAINST WHAT THE BARRIER ACTUALLY SAYETH.** *A rung that
     * changed behaviour now REDDENETH instead of disappearing.*
     */
    private val expectedRefusingRungsPinned: Set<PanicWipe.WipeState> = setOf(
        PanicWipe.WipeState.REQUESTED,
        PanicWipe.WipeState.RUNTIME_DRAINED,
        PanicWipe.WipeState.KEY_ERASED,
        PanicWipe.WipeState.ARTIFACTS_DELETED,
    )

    /**
     * *The rungs the barrier ACTUALLY refuses, read through the ADMISSION GATE rather than the predicate under test.*
     *
     * *** AND THE GATE MUST BE ASKED AFTER THE BARRIER, WHICH A PROBE SETTLED: AT `NEW_IDENTITY` THE BARRIER RESUMES
     * THE LADDER AND **PERSISTS THE COMPLETION** -- `before=5, after=0` -- SO THE DURABLE JOURNAL REACHETH `IDLE` AND
     * THE GATE THEN PERMITS. MY FIRST VERSION ASKED THE GATE **BEFORE** BUILDING THE BARRIER, WHICH READ THE STALE
     * RUNG, AND THE ROSTER DISAGREED WITH `permitsStartup` ON EXACTLY THAT ONE RUNG.***
     *
     * *So this is not a hole in the product: two readers asked at the WRONG MOMENT look like two authorities. Asked
     * after the barrier -- which is when a caller would ask -- they agree on every rung.* **THE ORDER IS THE WHOLE
     * SUBTLETY, AND THE PROBE IS WHY IT IS WRITTEN DOWN RATHER THAN ASSUMED.**
     *
     * *** AND "after=0" ALONE WOULD HAVE BEEN AMBIGUOUS, WHICH A SECOND PROBE SETTLED -- BECAUSE `FileWipeJournal.read()`
     * COERCES AN INVALID ORDINAL TO `IDLE`, SO A LOST RECORD AND A COMPLETED WIPE BOTH READ AS `IDLE`.*** **THAT IS THE
     * FAIL-OPEN THIS FINDING EXISTETH TO CATCH, SO THE DISCRIMINATION WAS MADE ON THE **RAW** ORDINAL (`isReadable`
     * readeth it uncoerced):**
     *
     * ```
     *   NEW_IDENTITY  rawBefore=5  rawAfter=0  readable=true  outcome=Advanced
     * ```
     *
     * *** A GENUINE COMPLETION: the raw value MOVED to the terminal ordinal and the record remaineth READABLE, and the
     * ladder reported `Advanced` -- not `Refused(JOURNAL_LOST)`, which is what a lost record would have produced with
     * `rawAfter` UNCHANGED.*** *A COERCED DEFAULT WOULD HAVE LEFT THE RAW ORDINAL WHERE IT STOOD. So the permissive
     * reading at `NEW_IDENTITY` is a completed wipe, and NOT the fail-open.*
     *
     * *** AND `isSupportedJournal` CANNOT BE THE DISCRIMINATOR HERE, WHICH I CHECKED RATHER THAN ASSUMED. *** *On this
     * isle the durability store carrieth ONE state, and the adapter sayeth so itself: `readJournal()` returneth
     * `emptyList()` for `IDLE` and **`listOf(stageFor(state))` OTHERWISE -- A LIST OF AT MOST ONE ELEMENT.***
     *
     * **SO THE APPEND-ONLY SEGMENT HISTORY THAT `isSupportedJournal` WALKETH CANNOT EXIST HERE:** *a rung at
     * `NEW_IDENTITY` presenteth `["NEW_IDENTITY"]` (rank 5, accepted) and a completed one presenteth `[]` (the loop
     * never runs, accepted) -- **BOTH TRUE, AND THEREFORE INDISTINGUISHABLE BY THAT ORACLE.*** *Its terminal-rung rule
     * ("IDLE may only close a full ladder") would fire only on a list containing a LONE `IDLE`, which this adapter
     * never produceth -- it produceth an EMPTY list for `IDLE` instead.*
     *
     * *So the raw-ordinal read IS the strongest discriminator available on this isle: it observeth the write itself
     * (`5 -> 0`) and the record's readability, which together separate a completion from a loss. THE LIMIT IS RECORDED
     * BECAUSE IT IS REAL: `read()` cannot see a lossy read, and on this isle neither can any list-walk.*
     */
    private fun refusingRungs(): List<PanicWipe.WipeState> =
        PanicWipe.WipeState.entries.filter { state ->
            presetJournal(state)
            val barrier = MeshStartupWipeBarrier(ctx())   // THE BARRIER RUNS FIRST: it may COMPLETE the ladder
            !MeshModule.provideWipeIsPending(ctx()).allowsSensitiveUse()
        }

    @Test
    fun theRefusingRosterMatchesItsPinnedExpectation() {
        // *** THIS IS THE FALSIFIABILITY GATE. *** *If any rung FLIPS to permissive, it leaveth the roster -- and a
        // non-empty check would not notice. Comparing the SET to a PINNED EXPECTATION means a flip REDDENETH here,
        // BEFORE the loops below quietly shrink.*
        assertEquals(
            "*** THE REFUSING ROSTER MUST EQUAL ITS PINNED EXPECTATION. *A rung that began permitting would SILENTLY " +
                "LEAVE the roster otherwise, and every loop below would shrink while this court stayed green -- THE " +
                "COVERAGE WOULD VANISH WITHOUT A RED.* Observed: ${refusingRungs()} ***",
            expectedRefusingRungsPinned, refusingRungs().toSet(),
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

    // =================================================================================================================
    // *** GS-FINAL-003 `zero-private-opens`: THE CONSTRUCTION COUNTERS, DRIVEN THROUGH THE REAL COMPONENT. ***
    //
    // *THE ARMS ABOVE ARE DECISION- AND PERMIT-LEVEL. **THE OBLIGATION'S OWN WORDS ASK FOR SOMETHING STRONGER:
    // "PROVEN AT THE REAL CONSTRUCTION SEAMS WITH COUNTERS."** *A correct decision that nothing consulteth, or a
    // permit a provider taketh and then ignoreth, satisfies every arm above while constructing the estate a later
    // resume is going to erase.*
    //
    // *** SO THESE ARMS RESOLVE THE PRIVATE PROVIDERS THROUGH `DaggerMeshGraphComponent` AND COUNT WHAT WALKED. ***
    // **ON A HOST THE PLATFORM THROWS** (AndroidKeyStore / the SQLCipher native library), *and that throw is
    // EVIDENCE, not an obstacle: `PrivateConstructionCounter.noteAttempt` runneth BEFORE the platform constructor, so
    // the count proveth the body REACHED the platform and the message proveth WHICH wall it hit -- rather than a
    // court-side short circuit.*
    // =================================================================================================================

    /** *Every private seam, with the component accessor that must walk to it.* */
    private val privateSeams: List<Pair<PrivateConstructionCounter.Seam, (MeshGraphComponent) -> Any>> = listOf(
        PrivateConstructionCounter.Seam.IDENTITY to { g: MeshGraphComponent -> g.identity() },
        PrivateConstructionCounter.Seam.MESSAGE_STORE to { g: MeshGraphComponent -> g.messageStore() },
        PrivateConstructionCounter.Seam.PEER_STORE to { g: MeshGraphComponent -> g.peerIdentityStore() },
    )

    private fun graph(): MeshGraphComponent =
        DaggerMeshGraphComponent.builder().applicationContext(ctx()).build()

    private fun failureChain(t: Throwable?): String =
        generateSequence(t) { it.cause }.joinToString(" | ") { it::class.java.name + ": " + it.message }

    /**
     * *** (a) THE PERMITTED ROAD: EVERY SEAM IS ATTEMPTED EXACTLY ONCE, UNDER `CLEAN_START`. ***
     *
     * *The `IDLE` journal is the one rung that permits construction, so each accessor must (1) move its counter by
     * exactly one, (2) record `CLEAN_START` as the authority, and (3) fail at a REAL PLATFORM wall rather than a DI
     * fault.* **A court-side short circuit would construct successfully and read as green -- so the throw is asserted,
     * not tolerated.**
     */
    @Test
    fun thePermittedRoadCountsOneAttemptPerSeamAtThePlatform() {
        presetJournal(PanicWipe.WipeState.IDLE)
        PrivateConstructionCounter.reset()
        val g = graph()

        for ((seam, accessor) in privateSeams) {
            val before = PrivateConstructionCounter.attempts(seam)
            val thrown = runCatching { accessor(g) }.exceptionOrNull()
            val after = PrivateConstructionCounter.attempts(seam)
            assertEquals(
                "*** $seam: THE PERMITTED ROAD MUST ATTEMPT PRIVATE CONSTRUCTION EXACTLY ONCE. *A delta of 0 would " +
                    "mean the provider never walked to its own constructor -- the counter would be asleep and every " +
                    "refusal arm below would be measuring nothing.* Observed delta=${after - before}, thrown=$thrown ***",
                1L, after - before,
            )
            assertEquals(
                "*** $seam: THE ATTEMPT MUST CARRY THE AUTHORITY THAT PERMITTED IT. *A count alone sayeth " +
                    "'something was constructed' -- this sayeth WHAT AUTHORISED IT, so a construction under a REFUSING " +
                    "decision could never satisfy this arm.* ***",
                StartupWipeDecision.CLEAN_START, PrivateConstructionCounter.lastAuthorizedBy(seam),
            )
            assertNotNull(
                "*** $seam: REACHING PRIVATE STATE ON A HOST MUST FAIL AT THE REAL PLATFORM, NOT CONSTRUCT. " +
                    "*A successful construction would mean the graph is NOT carrying the production providers, or that " +
                    "the body was short-circuited.* Observed: $thrown ***",
                thrown,
            )
            val chain = failureChain(thrown)
            assertTrue(
                "*** $seam: THE FAILURE MUST NAME A PLATFORM BOUNDARY (AndroidKeyStore / SQLCipher / " +
                    "UnsatisfiedLinkError), not a DI wiring fault. Observed chain: $chain ***",
                chain.contains("AndroidKeyStore") || chain.contains("KeyStoreException")
                    || chain.contains("sqlcipher") || chain.contains("UnsatisfiedLinkError"),
            )
        }
    }

    /**
     * *** (b) EVERY REFUSING RUNG: THE COUNTER MOVES FOR NO SEAM AT ALL. ***
     *
     * *And the refusal must be the GATE's own message, not a court-side short circuit:* **`NO PRIVATE STORE MAY BE
     * CONSTRUCTED` cometh from `issuePrivateStorePermit`'s `requireNotNull` -- i.e. from the composition's own issuer,
     * reached through the real binding -- so the arm proveth the ROAD reached the gate rather than that a test
     * declined to take it.**
     */
    @Test
    fun noRefusingRungMovesAnyConstructionCounter() {
        for (rung in expectedRefusingRungsPinned) {
            presetJournal(rung)
            PrivateConstructionCounter.reset()
            val g = graph()
            for ((seam, accessor) in privateSeams) {
                val before = PrivateConstructionCounter.attempts(seam)
                val thrown = runCatching { accessor(g) }.exceptionOrNull()
                val after = PrivateConstructionCounter.attempts(seam)
                assertEquals(
                    "*** $rung / $seam: A REFUSING RUNG MUST MOVE THE COUNTER BY ZERO. *Any increment here is a " +
                        "private construction attempted on an estate a later resume is going to erase -- the exact " +
                        "clause this obligation states.* Observed delta=${after - before} ***",
                    0L, after - before,
                )
                assertNull(
                    "*** $rung / $seam: no attempt may be recorded, so no authority may be recorded either. ***",
                    PrivateConstructionCounter.lastAuthorizedBy(seam),
                )
                assertTrue(
                    "*** $rung / $seam: THE RESOLUTION MUST FAIL WITH THE GATE'S OWN MESSAGE, so the road provably " +
                        "reached the composition's issuer rather than being declined by the court. Observed: " +
                        failureChain(thrown).take(400) + " ***",
                    thrown?.message?.contains("NO PRIVATE STORE MAY BE CONSTRUCTED") == true
                        || failureChain(thrown).contains("NO PRIVATE STORE MAY BE CONSTRUCTED"),
                )
            }
        }
    }

    /**
     * *** (c) THE SAME-RUN CROSS-CHECK: THE COUNTER IS NEITHER STUCK AT ZERO NOR RUNAWAY. ***
     *
     * *A counter hardwired to zero satisfies every refusal arm; a counter that increments on refusal satisfies every
     * permitted arm. **ONLY A SAME-RUN COMPARISON OF BOTH DIRECTIONS can see either defect, which is why this arm
     * exists beside the two above rather than trusting them separately.***
     */
    @Test
    fun theCounterMovesOnThePermittedRoadAndNowhereOnARefusingOne() {
        presetJournal(PanicWipe.WipeState.IDLE)
        PrivateConstructionCounter.reset()
        val permitted = graph()
        runCatching { permitted.identity() }
        val permittedDelta = PrivateConstructionCounter.attempts(PrivateConstructionCounter.Seam.IDENTITY)

        presetJournal(PanicWipe.WipeState.REQUESTED)
        val refusing = graph()
        runCatching { refusing.identity() }
        val refusingDelta = PrivateConstructionCounter.attempts(PrivateConstructionCounter.Seam.IDENTITY)

        assertTrue(
            "*** THE COUNTER MUST MOVE ON THE PERMITTED ROAD (delta=$permittedDelta) AND NOT ON A REFUSING ONE " +
                "(delta=$refusingDelta). *An always-zero counter would fail this direction; an increment-on-refusal " +
                "counter would pass it while constructing on a wiped estate -- so the conjunction is the assertion.* ***",
            permittedDelta >= 1L && refusingDelta == permittedDelta,
        )
    }
}
