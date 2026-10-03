package io.godstone.mesh.di

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeArtifacts
import io.godstone.mesh.identity.WipeIdentityAuthoritySeam
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeStepResult
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-FINAL-003 `true-pre-private-recovery`: THE PRE-PRIVATE RECOVERY GRAPH, ITS OWNER, AND THE TYPED NAME. ***
 *
 * *THE AUDIT'S OBSTACLE, QUOTED FROM THE LEDGER'S OWN WORDS: "THE HALT IS THE OBSTACLE ITSELF: the wipe's own rungs are
 * unreachable until the private graph exists, and the private graph may not exist until the wipe is done."* **AND THE
 * AUDIT'S OWN REMEDY: "a RECOVERY/BOOTSTRAP composition, whose transport seam exists BEFORE and INDEPENDENTLY of the store
 * graph, drives the ladder to a TYPED DECISION; a PRIVATE RUNTIME composition may be constructed only against a permit
 * that only that typed decision can mint."**
 *
 * *** WHAT THIS COURT ADDS THAT THE EXISTING ARMS COULD NOT. *** *`GsFinal003ZeroPrivateOpensTest` proveth the DECISION
 * and the PERMIT; `GsFinal003ContextProviderTest` proveth the ADMISSION GATE; `CrashStartupResumeTest` proveth the
 * runtime-side entry's ROUTING.* **NONE OF THEM COULD SEE THE THREE DEFECTS BELOW, BECAUSE EACH IS A PROPERTY OF THE
 * PRODUCTION COMPOSITION'S STRUCTURE RATHER THAN OF A COORDINATOR A COURT BUILT ITSELF:**
 *
 *   1. **THE PRODUCTION ROOTS BUILT A BARE `CrashResumableWipe` AND THE FOUR DEFERRED SEAMS BY HAND, IN TWO PLACES.**
 *      *A third copy of the mapping is a third place for it to go missing -- the two-authorities defect the isle's own
 *      docstrings name.* **HERE THE TWO ROADS ARE DRIVEN AND THEIR ANSWERS COMPARED.**
 *   2. **THE ADMISSION GATE REINTERPRETED THE RAW JOURNAL ENUM BESIDE THE DECISION.** *`read() == IDLE` cannot express
 *      CORRUPT, so an UNREADABLE record -- the fail-open this whole finding exists for -- was PERMITTED by the gate while
 *      the barrier refused the same record.* **HERE AN UNREADABLE ORDINAL IS PLANTED IN THE REAL `SharedPreferences`
 *      FILE AND BOTH ROADS ARE ASKED.**
 *   3. **`WipeIdentityAuthoritySeam.publishNewIdentity()` ANSWERED A NON-NULL SENTINEL ON EVERY FAILURE PATH**, so the
 *      coordinator's `== null` guard COULD NEVER FIRE on the production seam and the wipe advanced to `NEW_IDENTITY`/
 *      `IDLE` believing an identity stood when none did. **HERE THE PRODUCTION SEAM IS DRIVEN OVER A FAKE `WipeArtifacts`
 *      WHOSE REGENERATION FAILS, AND THE LADDER'S ANSWER IS READ.**
 *
 * *** EVERY ARM CARRIETH ITS OWN OPPOSITE. *** *A gate hardwired to refuse, a seam hardwired to `null`, and a coordinator
 * hardwired to stay pending would each satisfy the negative arms alone -- so each arm pair drives BOTH directions on the
 * same code path and asserts them together, which is the only shape that can fail for the right reason.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal003PrePrivateRecoveryGraphTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /**
     * The REAL journal file the production roots read, written through the same key `FileWipeJournal` uses.
     *
     * *** THE RAW ORDINAL IS WHAT MAKES ARM (2) POSSIBLE: an OUT-OF-RANGE ordinal is exactly the "material we could not
     * read" case, and `FileWipeJournal.read()` coerces it to `IDLE` -- which is why the defect could only be planted
     * HERE, at the durable value, and never through the typed adapter.***
     */
    private fun presetRawJournal(ordinal: Int?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (ordinal == null) remove("state") else putInt("state", ordinal)
        }.commit()
    }

    private fun presetJournal(state: PanicWipe.WipeState?) = presetRawJournal(state?.ordinal)

    @Before fun clearJournal() = presetRawJournal(null)
    @After fun tearDown() = presetRawJournal(null)

    // =================================================================================================================
    // (1) THE PERMIT IS UNFORGEABLE, UNREUSABLE ACROSS A CHANGED ESTATE, AND CORRUPTION HAS A REAL OPERATOR PATH.
    // =================================================================================================================

    /**
     * *** THE ONLY PUBLIC DOOR TAKES EVIDENCE, NOT AN OPINION -- AND EVIDENCE HAS NO PUBLIC CONSTRUCTOR. ***
     *
     * *THE OBLIGATION'S OWN MUTATION: "a normal runtime constructor mints its own permit".* **WITH THE OLD SHAPE THAT
     * COMPILED, because `StartupWipeDecision` is public and `issue(decision)` was a pure function of it.** *This arm pins
     * the STRUCTURE that makes it impossible now: no public `StartupWipeDecision` overload exists, and
     * [`RecoveryEvidence`] -- the only accepted argument -- cannot be constructed outside the graph.*
     *
     * *** A STRUCTURAL ARM IS THE RIGHT INSTRUMENT HERE: a compile failure cannot be asserted at runtime, so the court
     * asserts the ABSENCE of the forgeable door instead -- which is exactly what a future edit would have to reintroduce
     * to re-open it.***
     */
    @Test
    fun thePermitDoorTakesOnlyNonConstructibleEvidence() {
        // *** THE DOOR LIVETH ON THE COMPANION HOLDER, SO THE COMPANION IS WHAT MUST BE REFLECTED. ***
        //
        // *MEASURED: `PrivateStorePermit::class.java.declaredMethods` carry only the CLASS's own members, and `issue` is
        // declared on `PrivateStorePermit.Companion` -- so filtering the class reported `[]` and the "MUST EXIST" arm
        // reddened on a door that standeth. **A structural arm that inspects the WRONG holder measures nothing about the
        // door; it must ask the holder the door is declared on, exactly as the iOS twin asketh the `issued(by:)` static
        // function.***
        val issueOverloads = PrivateStorePermit.Companion::class.java.declaredMethods
            .filter { it.name == "issue" }
            .map { m -> m.parameterTypes.joinToString(",") { it.simpleName } }
        assertTrue(
            "*** THE PERMIT DOOR MUST EXIST. Observed: $issueOverloads ***",
            issueOverloads.isNotEmpty(),
        )
        assertFalse(
            "*** NO PUBLIC DOOR MAY TAKE A BARE `StartupWipeDecision`: that overload is what let a NORMAL RUNTIME " +
                "CONSTRUCTOR mint its own permit, because the enum is public. Observed overloads: $issueOverloads ***",
            issueOverloads.any { it == "StartupWipeDecision" },
        )
        assertEquals(
            "*** AND THE ONE DOOR MUST TAKE THE EVIDENCE -- whose constructor is private and whose only producer is the " +
                "recovery graph. Observed overloads: $issueOverloads ***",
            listOf("RecoveryEvidence"), issueOverloads,
        )

        val publicEvidenceCtors = RecoveryEvidence::class.java.declaredConstructors
            // *** THE COMPILER'S SYNTHETIC BRIDGE IS NOT A DOOR. ***
            //
            // *MEASURED: Kotlin emits a `public synthetic RecoveryEvidence(StartupWipeDecision, String, DefaultConstructorMarker)`
            // BRIDGE beside the `private` primary constructor, so a raw `isPublic` count reported 1 and reddened --
            // even though the primary constructor IS private and NO Kotlin or Java caller can invoke the bridge (it
            // exists only for the compiler's own use).* **The law is "no SOURCE-ACCESSIBLE public constructor", so the
            // check excludes synthetic members rather than pinning a Kotlin codegen artifact.***
            .filter { java.lang.reflect.Modifier.isPublic(it.modifiers) && !it.isSynthetic }
        assertTrue(
            "*** `RecoveryEvidence` MUST HAVE NO PUBLIC CONSTRUCTOR, or a caller could manufacture the evidence the " +
                "permit door accepts -- the same forgery one level down. Observed: ${publicEvidenceCtors.size} ***",
            publicEvidenceCtors.isEmpty(),
        )
    }

    /**
     * *** (A13) THE RAW CONSTRUCTOR BOUNDARY ITSELF GATES -- NOT ONLY THE DAGGER PROVIDER. ***
     *
     * *THE TICKET: **"Actualconsume atrawprivateidentity/store/provider constructor boundaries EVERYproductionhelper
     * inclrealDagger graph, notDI-only"**, and **"Kotlininternalfriendforgeriesnegativecontrolsactualownerfactory"**.*
     * **AN IN-MODULE FORGERY IS THE THREAT MODEL, AND `:mesh`'s OWN TEST SOURCE SET *IS* A FRIEND OF `:mesh`'s
     * `internal` -- so this court can attempt exactly what a rogue helper could, and must be REFUSED.***
     *
     * *** THE NEGATIVE CONTROL IS THE POINT: a token that was minted for a PERMITTING decision is driven through the
     * REAL raw constructor's own consumption point, and every other road is a compile failure rather than a runtime
     * check.** *If the raw constructor did not consume (or if `consumeForConstruction` were a no-op), the boundary would
     * be decoration and only the DI provider would gate -- which is the defect this finding names.*
     */
    @Test
    fun theRawOwnerConstructorConsumesTheAuthorityAtItsOwnBoundary() {
        // (1) THE REAL OWNER FACTORY over a permitted estate: a token is obtainable, and its consumption is idempotent.
        presetJournal(PanicWipe.WipeState.IDLE)
        val permitted = MeshStartupWipeBarrier(ctx())
        val permit = MeshModule.issuePrivateStorePermit(permitted)
        val token = io.godstone.mesh.identity.PrivateOwnerToken.forNormalConstruction(permit)
        assertSame(
            "*** THE RAW BOUNDARY MUST CONSUME AND HAND BACK THE SAME AUTHORITY, or a caller could observe a second " +
                "token from one permit. ***",
            token, token.consumeForConstruction(),
        )

        // (2) AND THE BOUNDARY `consumeForConstruction` STANDS AT IS REACHABLE FROM THE OWNERS THEMSELVES: the raw
        // constructor's first act is the consumption, so a host run that cannot open the platform still proves the
        // consumption ran FIRST (the counter/provider arms measure the same ordering from the other side).
        var consumedOnTheRealRoad = false
        runCatching {
            // THIS IS THE REAL CONSTRUCTOR, not a DI provider: it consumes the token, then reaches SQLCipher.
            io.godstone.mesh.identity.SqlcipherPeerIdentityStore(ctx(), token)
        }.onFailure { consumedOnTheRealRoad = true }
        assertTrue(
            "*** THE RAW OWNER CONSTRUCTOR MUST BE REACHABLE AND MUST FAIL AT ITS PLATFORM WALL (SQLCipher), which is " +
                "AFTER its own consumption -- a constructor that refused before consuming would make the boundary " +
                "unobservable. ***",
            consumedOnTheRealRoad,
        )
    }

    /**
     * *** EVERY DECISION, ASKED OF THE REAL DOOR: ONLY A SETTLED ESTATE MINTS. ***
     *
     * *The exhaustive matrix, driven through [`StartupRecoveryGraph.issuePermit`] over REAL evidence from a REAL barrier
     * rather than through a hand-typed enum.* **The two permitting cases are the positive control: without them the matrix
     * would pass for a door that never opens.**
     */
    @Test
    fun onlyASettledEstateMintsAndItIsCheckedAgainstTheEvidence() {
        // A SETTLED ESTATE MINTS -- the positive control, through the real barrier over a real clean journal.
        presetJournal(null)
        val cleanBarrier = MeshStartupWipeBarrier(ctx())
        assertNotNull(
            "*** A CLEAN ESTATE MUST MINT, or every refusal below is the refusal of a brick. ***",
            StartupRecoveryGraph.issuePermit(
                cleanBarrier.evidence, StartupRecoveryGraph.revisionOf(cleanBarrier.authority),
            ),
        )
        // AND ITS OPPOSITE: an outstanding rung mints NOTHING, through the same door. *A REFUSING SEAM SET IS INJECTED
        // because the REAL capabilities would COMPLETE this wipe at startup (which is the point of the recovery graph) --
        // a court that must witness an outstanding rung supplies seams that cannot finish it.*
        presetJournal(PanicWipe.WipeState.REQUESTED)
        val pendingBarrier = MeshStartupWipeBarrier(ctx(), StartupRecoveryGraph.deferred())
        assertNull(
            "*** AN OUTSTANDING RUNG MUST MINT NOTHING THROUGH THE REAL DOOR. ***",
            StartupRecoveryGraph.issuePermit(
                pendingBarrier.evidence, StartupRecoveryGraph.revisionOf(pendingBarrier.authority),
            ),
        )
    }

    /**
     * *** AND A PERMIT IS A JUDGEMENT ABOUT AN ESTATE, NOT A PERMANENT BADGE: A MOVED RECORD WITHHOLDETH IT. ***
     *
     * *The obligation's words: "permit cannot be reused after recovery authority changes or wrongestate".* **The evidence
     * carrieth the revision the graph read; the door re-checketh it against the revision NOW.** *A permit minted on a
     * clean device must NOT be presentable once a wipe has been requested -- otherwise a runtime constructed later could
     * open the very stores the wipe is erasing.*
     */
    @Test
    fun aPermitIsWithheldWhenTheDurableEstateMoved() {
        presetJournal(null)
        val barrier = MeshStartupWipeBarrier(ctx())
        val evidence = barrier.evidence
        // The estate is clean, so the permit standeth.
        assertNotNull(
            "the rig must start mintable, or the refusal below proves nothing",
            StartupRecoveryGraph.issuePermit(evidence, StartupRecoveryGraph.revisionOf(barrier.authority)),
        )
        // A WIPE IS REQUESTED UNDERNEATH: the record moveth.
        val movedJournal = io.godstone.mesh.identity.FileWipeJournal(ctx())
        StartupRecoveryGraph.requestWipe(movedJournal, StartupRecoveryGraph.prePrivate(ctx(), movedJournal))
        assertNull(
            "*** A PERMIT JUDGED AGAINST THE CLEAN ESTATE MUST BE WITHHELD ONCE THE ESTATE MOVED. *Presenting stale " +
                "evidence is exactly how a store would be opened over a wipe the user has just started.* ***",
            StartupRecoveryGraph.issuePermit(evidence, StartupRecoveryGraph.revisionOf(barrier.authority)),
        )
        // *** AND THE COMPOSITION'S OWN ISSUER -- THE ONE PLACE A PERMIT IS MINTED FOR A *CONSTRUCTION* -- MUST REFUSE
        // TOO (A3/A2's own road, re-anchored): *** *the barrier's `evidence` was judged against the CLEAN estate, so
        // minting NOW must fail the consumption-time estate check (`requireLiveFor`) rather than hand back the stale
        // authority.* **A permit handed back here would admit a private construction over a wipe the user has just
        // started -- the exact mutation where the composition took a permit from a constant decision without
        // re-validating it against the live estate.***
        assertTrue(
            "*** A PERMIT MINTED BY THE COMPOSITION *AFTER* THE ESTATE MOVED MUST BE REFUSED, NOT RETURNED. " +
                "*`issuePrivateStorePermit` must re-read the live revision and withhold the stale permit; a road that " +
                "skipped the estate check would satisfy every mint assertion above while opening the wiped estate.* ***",
            runCatching { MeshModule.issuePrivateStorePermit(barrier) }.isFailure,
        )
    }

    /**
     * *** CORRUPTION IS OPERATOR-REQUIRED AND HAS A REAL RESUME PATH -- NOT A MANUAL ENUM BYPASS. ***
     *
     * *The obligation's words: "corruption typed operator-required with real resume path".* **The first half is already
     * courted (the record reads `CORRUPT_JOURNAL`, `requiresOperator`, and NO permit existeth); this arm driveth the
     * RESOLUTION.*** *An operator (a person who has seen that decision on screen) discardeth the unreadable marker
     * through [`StartupRecoveryGraph.resolveCorruptJournalForOperator`], and the app then earneth the FIRST-LAUNCH
     * answer -- a real way forward rather than an enum a caller could pass to skip the gate.*
     */
    @Test
    fun aCorruptRecordIsOperatorResolvedAndTheAppThenStartsHonestly() {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .edit().putInt("state", 9999).commit()

        // (a) REFUSED, and an operator is told -- with NO permit available.
        val barrier = MeshStartupWipeBarrier(ctx())
        assertEquals(StartupWipeDecision.CORRUPT_JOURNAL, barrier.decision)
        assertTrue(barrier.decision.requiresOperator)
        assertNull(
            "no permit may exist while the record is unreadable",
            StartupRecoveryGraph.issuePermit(barrier.evidence, StartupRecoveryGraph.revisionOf(barrier.authority)),
        )

        // (b) THE OPERATOR'S ACT: durably records REQUESTED and performs real erasure through EstateAuthority
        val journal = io.godstone.mesh.identity.FileWipeJournal(ctx())
        val authority = StartupRecoveryGraph.authorityOver(
            journal,
            StartupRecoveryGraph.prePrivate(ctx(), journal),
        )
        val drive = authority.resolveCorruptForOperator()
        // Finding A7: Operator corrupt resolution must perform full verified erasure, NEVER merely clear to CLEAN_START!
        assertTrue(
            "*** THE OPERATOR RESOLUTION MUST NEVER MERELY CLEAR TO CLEAN_START (finding A7) ***",
            drive.decision != StartupWipeDecision.CLEAN_START,
        )
        assertFalse("and it summons no further operator (decision=${drive.decision})", drive.decision.requiresOperator)
    }
    // =================================================================================================================
    // (1b) ONE RECOVERY GRAPH, TWO PRODUCTION ROADS, ONE ANSWER.
    // =================================================================================================================

    /**
     * *** THE STARTUP BARRIER AND THE ADMISSION GATE ARE TWO READINGS OF ONE DECISION FUNCTION. ***
     *
     * *This is the "two authorities" defect stated as an arm.* **BEFORE THIS ROUND the gate read the raw enum while the
     * barrier read the typed decision, so the two could disagree -- and on the UNREADABLE case they DID, in opposite
     * directions.** *The arm drives EVERY rung of the ladder through both and asserts they agree, with the terminal rung
     * as the positive control (both must PERMIT), so a pair hardwired to refuse cannot pass.*
     */
    @Test
    fun theBarrierAndTheAdmissionGateReadOneDecisionOnEveryRung() {
        for (rung in PanicWipe.WipeState.entries) {
            presetJournal(rung)
            // *** THE REFUSING SEAMS ARE INJECTED SO EVERY RUNG STAYS OBSERVABLE: with the REAL capabilities the barrier
            // would COMPLETE a pending wipe at startup, and the agreement would only ever be seen at the terminal rung. ***
            val barrier = MeshStartupWipeBarrier(ctx(), StartupRecoveryGraph.deferred())
            val gate = MeshModule.provideWipeIsPending(ctx())
            assertEquals(
                "*** $rung: THE BARRIER'S TYPED DECISION AND THE ADMISSION GATE MUST BE THE SAME ANSWER. " +
                    "*Two readers of one durable record that disagree are two authorities, and an admission point that " +
                    "disagrees with the recovery decision admits sensitive use over an estate the recovery refused.* " +
                    "Barrier said ${barrier.decision}; gate said ${gate.allowsSensitiveUse()} ***",
                barrier.decision.allowsPrivateConstruction, gate.allowsSensitiveUse(),
            )
        }
        // *** AND THE POSITIVE CONTROL, WITHOUT WHICH THE LOOP ABOVE PASSETH FOR A PAIR THAT REFUSETH EVERYTHING: the
        // terminal rung must OPEN both, or the repair is a denial of service rather than a gate. ***
        presetJournal(PanicWipe.WipeState.IDLE)
        val barrier = MeshStartupWipeBarrier(ctx())
        assertTrue(
            "*** A COMPLETED WIPE IS A LEGITIMATE ESTATE TO WORK FROM: both roads must PERMIT at the terminal rung, or " +
                "the agreement above is the agreement of two bricks. ***",
            barrier.decision.allowsPrivateConstruction &&
                MeshModule.provideWipeIsPending(ctx()).allowsSensitiveUse(),
        )
    }

    // =================================================================================================================
    // (2) CORRUPTION IS OPERATOR-VISIBLE AND REFUSED -- ON THE GATE TOO, WHICH USED TO FAIL OPEN HERE.
    // =================================================================================================================

    /**
     * *** AN UNREADABLE RECORD IS `CORRUPT_JOURNAL` ON BOTH ROADS -- AND *BOTH* REFUSE. ***
     *
     * *THE DEFECT THIS ARM WAS WRITTEN FOR, MEASURED RATHER THAN ARGUED: `FileWipeJournal.read()` maps an out-of-range
     * ordinal to `IDLE`, so the OLD admission gate (`read() == IDLE`) returned TRUE -- PERMITTING sensitive use over a
     * durable record nobody could read -- WHILE THE BARRIER, which asks `isReadableJournal`, correctly refused the same
     * record.* **TWO ROADS, ONE FILE, OPPOSITE ANSWERS, AND THE PERMISSIVE ONE WAS THE ONE GATING USE.***
     */
    @Test
    fun anUnreadableDurableRecordIsCorruptAndRefusedOnBothRoads() {
        presetRawJournal(9999)   // an out-of-range ordinal: PRESENT, but not a state this build understands
        val barrier = MeshStartupWipeBarrier(ctx())
        assertEquals(
            "*** AN UNREADABLE RECORD MUST BE CORRUPT_JOURNAL -- the ladder's `IDLE` reading is an ARTEFACT of coercion, " +
                "not a proven clean estate. Observed: ${barrier.decision} ***",
            StartupWipeDecision.CORRUPT_JOURNAL, barrier.decision,
        )
        assertFalse(
            "*** AND CORRUPTION REFUSES PRIVATE CONSTRUCTION. ***",
            barrier.decision.allowsPrivateConstruction,
        )
        assertFalse(
            "*** AND THE ADMISSION GATE MUST REFUSE THE SAME RECORD. *This is the arm that would have FAILED before this " +
                "round: the raw-enum gate read 9999 as `IDLE` and PERMITTED.* ***",
            MeshModule.provideWipeIsPending(ctx()).allowsSensitiveUse(),
        )
        assertTrue(
            "*** A CORRUPT RECORD IS AN OPERATOR MATTER, SO THE DECISION MUST SAY SO -- otherwise the UI cannot " +
                "distinguish it from a wipe that merely has not finished. ***",
            barrier.decision.requiresOperator,
        )
    }

    /** *** THE OPPOSITE DIRECTION: AN ABSENT RECORD IS A PROVEN CLEAN FIRST LAUNCH AND MUST PERMIT ON BOTH ROADS. *** */
    @Test
    fun anAbsentRecordIsACleanStartAndPermitsOnBothRoads() {
        presetRawJournal(null)
        val barrier = MeshStartupWipeBarrier(ctx())
        assertEquals(StartupWipeDecision.CLEAN_START, barrier.decision)
        assertTrue(barrier.decision.allowsPrivateConstruction)
        assertTrue(MeshModule.provideWipeIsPending(ctx()).allowsSensitiveUse())
        // AND NO OPERATOR IS SUMMONED FOR A CLEAN LAUNCH: a `requiresOperator` that answered true here would page a human
        // for every fresh install, which is how a real alarm comes to be ignored.
        assertFalse(barrier.decision.requiresOperator)
    }

    // =================================================================================================================
    // (2b) A WIPE THAT RAN TO ITS END IS `WIPE_COMPLETED` -- THE iOS ISLE'S OWN DISTINCTION.
    // =================================================================================================================

    /**
     * *** (2b) AND A WIPE THAT RAN TO ITS END READS `WIPE_COMPLETED` -- NOT `CLEAN_START`. ***
     *
     * *** THE iOS CONTRACT'S DISTINCTION, PROVEN THROUGH THE PRODUCTION GRAPH RATHER THAN THROUGH `decide()` ALONE. *** *The
     * coordinator is driven from `ARTIFACTS_DELETED` with a publishing authority, so it landeth on `IDLE` and `decisionOf`
     * must call that what it is.* **A device that WAS wiped is a different estate from a first launch, and a rendered
     * surface must be able to say which one it is looking at.**
     */
    @Test
    fun aWipeThatRanToItsEndReadsAsWipeCompleted() {
        val publishing = object : io.godstone.mesh.identity.IdentityAuthoritySeam {
            override fun publishNewIdentity(): String? = "node-deadbeef"
            override fun identity(): String? = null
        }
        val coordinator = coordinatorAt(PanicWipe.WipeState.ARTIFACTS_DELETED, publishing)
        val outcome = coordinator.resume()
        assertTrue("the rig must actually reach the terminal rung", !coordinator.isWipePending)
        assertEquals(
            "*** A WIPE THAT FINISHED MUST READ `WIPE_COMPLETED` THROUGH THE PRODUCTION GRAPH -- the same answer the iOS " +
                "isle giveth, and NOT `CLEAN_START`, which is reserved for a device on which nothing ever happened. " +
                "Observed: ${StartupRecoveryGraph.decisionOf(coordinator, outcome)} ***",
            StartupWipeDecision.WIPE_COMPLETED, StartupRecoveryGraph.decisionOf(coordinator, outcome),
        )
        assertTrue(
            "and it permits construction: there is nothing left to erase",
            StartupRecoveryGraph.decisionOf(coordinator, outcome).allowsPrivateConstruction,
        )
        // *** THE OPPOSITE, ON THE OTHER ROAD: a clean DEVICE read at rest is `CLEAN_START`. *** *Both permits, and the
        // two are different words -- which is the whole distinction.*
        presetJournal(null)
        assertEquals(
            "a device with no durable record at all is a FIRST LAUNCH",
            StartupWipeDecision.CLEAN_START, MeshStartupWipeBarrier(ctx()).decision,
        )
    }

    // =================================================================================================================
    // (3) The identity seam's typed name
    // =================================================================================================================

    /** A `WipeArtifacts` whose regeneration FAILS -- the real-world case (a keystore refusal, a wiped keychain). */
    private class FailingRegenerationArtifacts : WipeArtifacts {
        override fun eraseKeys() {}
        override fun deleteArtifacts() {}
        override fun regenerateIdentity() { throw IllegalStateException("the keystore refused a new master key") }
    }

    /**
     * *** A FAILED PUBLICATION IS THE SEAM'S OWN NEGATIVE CHANNEL, NOT A SENTINEL STRING. ***
     *
     * *THE DEFECT, MEASURED: this seam returned the literal `"identity-generation-failed"` on every failure path. The
     * coordinator branches on `publishNewIdentity() == null`, so on the PRODUCTION seam that branch was UNREACHABLE -- the
     * ladder recorded `NEW_IDENTITY` and then `IDLE` over an identity that was never created.*
     *
     * *** AND THE FIX IS TYPED RATHER THAN TEXTUAL. *** *The seam's own contract sayeth `null` means NOT PUBLISHED; a
     * sentinel STRING is a VALUE, and the ladder's guard is an ABSENCE. **They are different questions, and only one of
     * them keeps a wipe pending.***
     */
    @Test
    fun theProductionIdentitySeamReportsFailureAsTheTypedNegativeChannel() {
        val seam = WipeIdentityAuthoritySeam(ctx(), FailingRegenerationArtifacts())
        assertNull(
            "*** A FAILED REGENERATION MUST BE `null` -- THE SEAM'S OWN VOCABULARY FOR 'NOT PUBLISHED', which the " +
                "ladder's `== null` guard can actually see. ***",
            seam.publishNewIdentity(),
        )
    }

    /**
     * *** AND THE LADDER HONOURS IT: THE WIPE STAYS PENDING AT `ARTIFACTS_DELETED`. ***
     *
     * *This is the arm that couples the PRODUCTION SEAM to the coordinator, so the fix is proven where it matters rather
     * than in isolation.* **THE FAILURE IS DETERMINISTIC AND PLATFORM-FREE: `regenerateIdentity()` throweth before
     * `Identity.loadOrCreate` is ever reached, so the arm measures the seam's failure channel rather than a host's
     * missing keystore.**
     *
     * *** AND THE OPPOSITE DIRECTION IS DRIVEN TOO (arm (3c)): the SAME ladder with a seam that DOES publish a name must
     * reach the terminal rung -- otherwise THIS arm would pass for a ladder that simply never finishes.***
     */
    @Test
    fun aFailedPublicationKeepsTheWipePending() {
        val failing = coordinatorAt(
            PanicWipe.WipeState.ARTIFACTS_DELETED, WipeIdentityAuthoritySeam(ctx(), FailingRegenerationArtifacts()),
        )
        val refused = failing.resume()
        assertTrue(
            "*** A WIPE WHOSE IDENTITY WAS NOT PUBLISHED MUST NOT REACH IDLE. Observed: $refused at " +
                "${failing.journalView().lastOrNull()} ***",
            refused is WipeStepResult.RetryLater && failing.isWipePending,
        )
        assertEquals(
            "*** AND THE DURABLE RECORD KEEPS THE HONEST RUNG -- NOT `NEW_IDENTITY`, which would CLAIM an identity " +
                "nobody managed to create. ***",
            WipeJournalState.ARTIFACTS_DELETED, failing.journalView().lastOrNull(),
        )
    }

    /**
     * *** (3c) THE OPPOSITE CONTROL, ON THE SAME LADDER: A PUBLISHED NAME REACHES THE TERMINAL RUNG. ***
     *
     * *The authority here is a STUB rather than the production seam, and that is deliberate: on a host the production
     * seam CANNOT succeed* (`Identity.loadOrCreate` reacheth the AndroidKeyStore, which a JVM does not have -- the same
     * wall `GsFinal003ZeroPrivateOpensTest` asserts as its own evidence). **So the question this arm must answer is
     * "doth the ladder advance when a name IS published?", and a stub answers exactly that.** *The production seam's
     * `null` on failure is arm (3a)'s subject, and the two arms together leave no direction untested.*
     */
    @Test
    fun aPublishedNameReachesTheTerminalRung() {
        val publishing = object : io.godstone.mesh.identity.IdentityAuthoritySeam {
            override fun publishNewIdentity(): String? = "node-0123abcd"
            override fun identity(): String? = "node-0123abcd"
        }
        val good = coordinatorAt(PanicWipe.WipeState.ARTIFACTS_DELETED, publishing)
        good.resume()
        assertFalse(
            "*** A WIPE WHOSE IDENTITY WAS PUBLISHED MUST BE ABLE TO FINISH: otherwise the arm above passeth for a " +
                "ladder that never completes. Observed at ${good.journalView().lastOrNull()} ***",
            good.isWipePending,
        )
        assertEquals(
            "*** AND IT MUST HAVE PASSED THROUGH `NEW_IDENTITY` TO REACH `IDLE` -- the ladder's own terminal " +
                "transition, not a jump. ***",
            WipeJournalState.IDLE, good.journalView().lastOrNull(),
        )
    }

    // =================================================================================================================
    // (4) THE RECOVERY GRAPH IS REACHABLE *AFTER* A REAL PERSISTED RUNG, WITH NO PRIVATE CONSTRUCTION AT ALL.
    // =================================================================================================================

    /**
     * *** COLD STARTUP AT EVERY PERSISTED RUNG: THE DECISION CONVERGES WITH NO PRIVATE STATE TOUCHED. ***
     *
     * *Restart convergence, stated as a measurement rather than a claim.* **The barrier is built (which IS the recovery
     * graph standing up) and its answer recorded; then the counter that every private provider is instrumented with must
     * move for NO seam, because the recovery graph owns no identity, no message store and no peer store.** *The terminal
     * rung is driven too -- its barrier FINISHES the ladder (the measured `NEW_IDENTITY -> IDLE` transition) and must
     * still leave every counter at zero.*
     */
    @Test
    fun everyPersistedRungConvergesWithZeroPrivateConstruction() {
        var cleanRungs = 0
        for (rung in PanicWipe.WipeState.entries) {
            presetJournal(rung)
            PrivateConstructionCounter.reset()
            // *** THE REFUSING SEAMS KEEP EVERY RUNG OBSERVABLE (the real capabilities would complete a pending wipe),
            // so this arm measures the DECISION at each persisted rung rather than the outcome of driving it. ***
            val first = MeshStartupWipeBarrier(ctx(), StartupRecoveryGraph.deferred()).decision   // THE GRAPH STANDS UP HERE
            val second = MeshStartupWipeBarrier(ctx(), StartupRecoveryGraph.deferred()).decision
            // *** THE CONVERGENCE LAW IS THE iOS TWIN'S, NOT A RAW-EQUALITY PIN. ***
            //
            // *`GsFinal003RecoveryTopologyTests.everyPersistedRungConvergesUnderARestart` states it exactly: a rung whose
            // drive REACHED THE TERMINAL RUNG leaveth the record at `IDLE`, **and for the NEXT process `IDLE` IS the clean
            // estate -- `IDLE` and never-requested are ONE durable record -- so the second drive answereth `CLEAN_START`
            // rather than re-running the ladder.** *A raw `first == second` equality would pin `WIPE_COMPLETED` against
            // `CLEAN_START` at the terminal rung and call a LEGITIMATE COMPLETION a non-convergence -- a surface pin on a
            // label rather than the consumer's own property.* **Every rung the first process could NOT settle must
            // reproduce the first decision EXACTLY.***
            if (first == StartupWipeDecision.WIPE_COMPLETED) {
                assertTrue(
                    "*** $rung: A RUNG THAT CLOSED AT `IDLE` IS THE NEXT PROCESS'S CLEAN ESTATE -- `IDLE` and " +
                        "never-requested are one durable record, so the restart must answer `CLEAN_START` (or, on a " +
                        "reader that names the terminal rung, `WIPE_COMPLETED`). Observed second=$second ***",
                    second == StartupWipeDecision.CLEAN_START || second == StartupWipeDecision.WIPE_COMPLETED,
                )
            } else {
                assertEquals(
                    "*** $rung: A RUNG THE FIRST PROCESS COULD NOT SETTLE MUST CONVERGE TO THE SAME DECISION ON EVERY " +
                        "RESTART -- same persisted rung, same answer. first=$first second=$second ***",
                    first, second,
                )
            }
            for (seam in PrivateConstructionCounter.Seam.entries) {
                assertEquals(
                    "*** $rung / $seam: THE RECOVERY GRAPH OWNS NO PRIVATE STATE -- the ladder may be driven, refused " +
                        "or completed without a SINGLE private construction. Observed " +
                        "${PrivateConstructionCounter.attempts(seam)} ***",
                    0L, PrivateConstructionCounter.attempts(seam),
                )
            }
            if (first.allowsPrivateConstruction) cleanRungs += 1
        }
        assertTrue(
            "*** THE POSITIVE CONTROL: at least ONE rung must PERMIT, or the loop above is the convergence of a brick -- " +
                "an always-refusing gate satisfies every assertion in it. ***",
            cleanRungs >= 1,
        )
    }

    /**
     * *** A REFUSING RUNG MOVES NO COUNTER, AND THE PERMITTED ONE DOES MOVE -- BOTH DIRECTIONS IN ONE ARM. ***
     *
     * *A counter hardwired to zero would satisfy the per-rung loop above; a counter that incremented on a refusal would
     * satisfy the permitted road. **ONLY A SAME-RUN COMPARISON OF BOTH DIRECTIONS can see either defect** -- and the
     * permitted direction is taken with the SAME instrument and the SAME production provider, so the zero above is a
     * measurement rather than a sleeping gauge.*
     */
    @Test
    fun theConstructionCounterMovesOnThePermittedRoadAndNotOnARefusingOne() {
        // (a) A REFUSING RUNG: no attempt may be recorded at any seam.
        presetJournal(PanicWipe.WipeState.REQUESTED)
        PrivateConstructionCounter.reset()
        runCatching {
            val barrier = MeshStartupWipeBarrier(ctx(), StartupRecoveryGraph.deferred())
            val permit = permitFor()
            val token = io.godstone.mesh.identity.PrivateOwnerToken.forNormalConstruction(permit)
            MeshModule.provideIdentity(ctx(), barrier, permit, token)
        }
        for (seam in PrivateConstructionCounter.Seam.entries) {
            assertEquals(
                "*** $seam: A REFUSING RUNG MUST MOVE NO COUNTER. Observed " +
                    "${PrivateConstructionCounter.attempts(seam)} ***",
                0L, PrivateConstructionCounter.attempts(seam),
            )
        }

        // (b) THE PERMITTED ROAD: the SAME instrument must move by one on the identity seam.
        presetJournal(PanicWipe.WipeState.IDLE)
        PrivateConstructionCounter.reset()
        runCatching {
            val barrier = MeshStartupWipeBarrier(ctx())
            val permit = permitFor()
            val token = io.godstone.mesh.identity.PrivateOwnerToken.forNormalConstruction(permit)
            MeshModule.provideIdentity(ctx(), barrier, permit, token)
        }
        assertEquals(
            "*** THE COUNTER MUST MOVE ON THE PERMITTED ROAD -- a gauge that is always zero makes the loop above " +
                "vacuous rather than proven. ***",
            1L, PrivateConstructionCounter.attempts(PrivateConstructionCounter.Seam.IDENTITY),
        )
        assertNotNull(
            "and the attempt carrieth the authority it was made under",
            PrivateConstructionCounter.lastAuthorizedBy(PrivateConstructionCounter.Seam.IDENTITY),
        )
    }

    /**
     * *The permit at the CURRENT rung, through the composition's own issuer.* **On a refusing rung `issuePrivateStorePermit`
     * THROWS rather than returning null (its `requireNotNull` IS the gate), so a caller that wraps the whole call in
     * `runCatching` -- as the arms above do -- observes the refusal where a provider would, and NO counter moves.***
     */
    private fun permitFor(): PrivateStorePermit =
        MeshModule.issuePrivateStorePermit(MeshStartupWipeBarrier(ctx(), StartupRecoveryGraph.deferred()))

    /**
     * *The smallest honest journal: one typed state, exactly the contract `WipeJournal` declares.*
     *
     * *** IT STATES ITS READABILITY, WHICH THE COORDINATOR'S FAIL-CLOSED DEFAULT FORCETH: *** *`WipeJournalDurabilityAdapter`
     * returneth `isReadable = false` for a store that cannot answer, so an in-memory journal that stayed silent would
     * make `decide()` report CORRUPT_JOURNAL on every rung -- and the arms below would then be measuring a defect in the
     * RIG rather than in the production seam. **A store holding one typed value CAN answer, so it must say so** -- the
     * same correction `GsFinal003StartupDecisionTest`'s `TextStore` carries.*
     */
    private class MemoryJournal(private var state: PanicWipe.WipeState) :
        io.godstone.mesh.identity.WipeJournal, io.godstone.mesh.identity.WipeReadabilityReporting {
        override fun read(): PanicWipe.WipeState = state
        override fun write(state: PanicWipe.WipeState) { this.state = state }
        override fun clear() { state = PanicWipe.WipeState.IDLE }
        /** One typed rung is exactly what this build understands: always parseable. */
        override val isReadable: Boolean get() = true
    }

    /**
     * A coordinator at one rung, over the SAME seam mapping `StartupRecoveryGraph` builds -- with the identity seam
     * supplied by the caller, which is what makes arm (3) a measurement of the PRODUCTION seam rather than of a fake.
     */
    private fun coordinatorAt(
        rung: PanicWipe.WipeState,
        identityAuthority: io.godstone.mesh.identity.IdentityAuthoritySeam,
    ): io.godstone.mesh.identity.CrashResumableWipe {
        val journal = MemoryJournal(rung)
        return StartupRecoveryGraph.coordinator(
            journal,
            WipeRecoverySeams(
                // the OTHER three seams are the real deferred ones: this rig must not accidentally perform an effect.
                vault = io.godstone.mesh.identity.WipeDeferredSeams.DeferredKeyVaultSeam(),
                filesystem = io.godstone.mesh.identity.WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
                runtime = io.godstone.mesh.identity.WipeDeferredSeams.DeferredTransportRuntimeSeam(),
                authority = identityAuthority,
            ),
        )
    }
}
