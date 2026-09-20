package io.godstone.mesh.identity

import io.godstone.mesh.di.StartupWipeDecision
import io.godstone.mesh.di.decide
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** GS-FINAL-003, THE ANDROID HALF: THE STARTUP DECISION IS TYPED, AND THE GATE BRANCHES ON THE CAUSE. ***
 *
 * THE DEFECT THIS FILE EXISTS FOR, WHICH WAS SHIPPED AND MEASURED: `MeshStartupWipeBarrier` decided whether private
 * stores may be opened by MATCHING A SUBSTRING OF PROSE --
 *
 *     is WipeStepResult.Refused -> r.reason.contains("nothing to resume")
 *
 * That is the exact defect `AUDIT-B1-CTRL-001` retired on the control plane: **A DECISION THAT MOVES WITH THE
 * VOCABULARY OF ITS INPUT MEASURES THE CLASSIFIER, NOT THE REPOSITORY.** Rename the reason text and a MALFORMED
 * JOURNAL reads as a CLEAN FIRST LAUNCH, opening private stores over material that may be mid-erasure.
 *
 * *** THE ARM THAT MATTERS IS `aRewordedRefusalDoesNotChangeTheDecision`. ***
 * *It is the mutation proof: under the old string form, changing the message text CHANGED what the gate permitted.
 * Under the typed cause it cannot, and the arm asserts exactly that by driving a refusal whose PROSE says one thing and
 * whose CAUSE says another.*
 */
class GsFinal003StartupDecisionTest {

    /**
     * *** THE CAUSE, NOT THE PROSE, DECIDES. ***
     *
     * *A `Refused` whose reason TEXT mentions a clean first launch -- but whose typed cause is `MALFORMED_JOURNAL` --
     * must be judged CORRUPT. The old form, `reason.contains("nothing to resume")`, would have judged it CLEAN had the
     * wording matched; this arm pins the property that the wording is NOT what is read.*
     */
    @Test
    fun aRewordedRefusalDoesNotChangeTheDecision() {
        val misleading = WipeStepResult.Refused(
            WipeRefusalCause.MALFORMED_JOURNAL,
            "nothing to resume; no wipe was ever requested",   // prose that LIES about the cause
        )

        // The prose says clean. The cause says corrupt. THE CAUSE WINS -- and no string comparison happens anywhere.
        assertNotEquals(
            "the prose is for humans; a gate that reads it can be reworded into permitting the unsound case",
            StartupWipeDecision.CLEAN_START,
            decisionFor(misleading),
        )
        assertEquals(StartupWipeDecision.CORRUPT_JOURNAL, decisionFor(misleading))
        assertTrue("a malformed record needs a human", StartupWipeDecision.CORRUPT_JOURNAL.requiresOperator)
    }

    /**
     * *** THE REWORDING ARM, POINTED AT THE BRANCH THAT ACTUALLY CARRIES THE RISK. ***
     *
     * *My first version of this arm used a `MALFORMED_JOURNAL` cause carrying clean-sounding prose -- which tests the
     * branch that is ALREADY typed, and left the dangerous one unmeasured. A mutation reintroducing
     * `reason.contains("nothing to resume")` on the `NOTHING_TO_RESUME` branch SURVIVED it.*
     *
     * **THE REAL RISK IS THE OTHER DIRECTION**: the branch that PERMITS. A genuine clean estate whose prose has been
     * REWORDED -- as any message could be -- must still be permitted, because the CAUSE is clean. Under the string form
     * this arm dies: `"no wipe was ever pending here"` does not contain `"nothing to resume"`, so the old code would
     * have judged a legitimate clean first launch as CORRUPT and refused it.
     */
    @Test
    fun aRewordedCleanStartIsStillClean() {
        assertEquals(
            "the CAUSE is clean, so the decision is CLEAN_START -- under the old string form, any rewording of this " +
                "message would have refused every legitimate first launch",
            StartupWipeDecision.CLEAN_START,
            decisionFor(WipeStepResult.Refused(WipeRefusalCause.NOTHING_TO_RESUME, "no wipe was ever pending here")),
        )
    }

    /**
     * *** AND THE GENUINE CLEAN START IS STILL PERMITTED. ***
     *
     * *The positive control. Without it, the arm above would pass trivially if the gate refused EVERYTHING -- the
     * mirror-image defect. A proven clean estate is the ONLY case that may open private stores.*
     */
    @Test
    fun theOnlyCleanEstateIsNothingToResume() {
        val clean = WipeStepResult.Refused(WipeRefusalCause.NOTHING_TO_RESUME, "nothing to resume; ...")
        assertEquals(StartupWipeDecision.CLEAN_START, decisionFor(clean))
        assertTrue(
            "and CLEAN_START is the ONLY case that may open private stores",
            StartupWipeDecision.CLEAN_START.allowsPrivateConstruction,
        )
        assertFalse("and it needs no operator", StartupWipeDecision.CLEAN_START.requiresOperator)
    }

    /**
     * *** EVERY OTHER CAUSE REFUSES, AND NONE OF THEM IS MISTAKEN FOR CLEAN. ***
     *
     * *This is the exhaustiveness the enum buys: each cause maps to a DIFFERENT decision, so an operator (and a court)
     * can tell a recoverable refusal from a corrupt record from a terminal failure -- which a bare Boolean could never
     * express, and which is why the audit names a Boolean as forbidden here.*
     */
    @Test
    fun everyCauseMapsToItsOwnRefusalAndNoneIsClean() {
        val expected = mapOf(
            WipeRefusalCause.MALFORMED_JOURNAL to StartupWipeDecision.CORRUPT_JOURNAL,
            WipeRefusalCause.WIPE_ALREADY_PENDING to StartupWipeDecision.RECOVERY_PENDING,
            WipeRefusalCause.TERMINAL_STEP_FAILURE to StartupWipeDecision.TERMINAL_FAILURE,
            WipeRefusalCause.JOURNAL_LOST to StartupWipeDecision.CORRUPT_JOURNAL,
        )
        for ((cause, decision) in expected) {
            val actual = decisionFor(WipeStepResult.Refused(cause, "text is irrelevant: $cause"))
            assertEquals("cause $cause must map to $decision", decision, actual)
            assertFalse("nothing but CLEAN_START may open private stores; $cause did", actual.allowsPrivateConstruction)
        }
        assertEquals("every cause is covered", WipeRefusalCause.values().size, expected.size + 1)
    }

    /**
     * *** `AlreadyAtOrPast` IS NOT SYNONYMOUS WITH CLEAN -- THE SECOND DEFECT IN THE SAME GATE. ***
     *
     * *The shipped arm returned `true` UNCONDITIONALLY for `AlreadyAtOrPast`. But that result answers at ANY rung
     * already passed -- including a mid-ladder one, when the journal's last durable entry is a rung reached before a
     * crash. So the old gate permitted private stores over an OUTSTANDING WIPE on the strength of the result's TYPE
     * alone. Only a terminal IDLE rank is a clean estate.*
     */
    @Test
    fun alreadyAtOrPastIsCleanOnlyAtTheTerminalRung() {
        assertEquals(
            "a terminal IDLE rank is a clean estate",
            StartupWipeDecision.CLEAN_START,
            decisionFor(WipeStepResult.AlreadyAtOrPast(WipeJournalState.IDLE)),
        )
        for (rung in WipeJournalState.values().filter { it != WipeJournalState.IDLE }) {
            assertEquals(
                "a wipe parked at $rung is OUTSTANDING, not clean -- the old arm said `true` for this",
                StartupWipeDecision.RECOVERY_PENDING,
                decisionFor(WipeStepResult.AlreadyAtOrPast(rung)),
            )
        }
    }

    /** *** AND AN ADVANCE IS CLEAN ONLY IF IT LANDED ON THE TERMINAL RUNG. *** */
    @Test
    fun anAdvanceIsCleanOnlyWhenItReachesIdle() {
        assertEquals(
            StartupWipeDecision.CLEAN_START,
            decisionFor(WipeStepResult.Advanced(WipeJournalState.NEW_IDENTITY, WipeJournalState.IDLE)),
        )
        assertEquals(
            StartupWipeDecision.RECOVERY_PENDING,
            decisionFor(WipeStepResult.Advanced(WipeJournalState.REQUESTED, WipeJournalState.KEYS_ERASED)),
        )
    }

    /** *** A RETRYABLE FAILURE REFUSES BUT DOES NOT ALARM AN OPERATOR: A LATER COMPOSITION MAY FINISH IT. *** */
    @Test
    fun aRetryableFailureRefusesWithoutRequiringAnOperator() {
        val d = decisionFor(WipeStepResult.RetryLater(WipeJournalState.REQUESTED, "transport busy"))
        assertEquals(StartupWipeDecision.RETRYABLE_FAILURE, d)
        assertFalse("a later composition with live seams may finish it", d.allowsPrivateConstruction)
        assertFalse("so it does not need a human yet", d.requiresOperator)
    }

    /**
     * *** THE READABILITY DISTINCTION, WHICH THE LADDER CANNOT EXPRESS. ***
     *
     * *An UNREADABLE durable record and a record saying "nothing was ever requested" both leave the ladder EMPTY, so a
     * caller asking only "is a wipe pending?" sees a clean estate for BOTH -- and they must permit OPPOSITE things.
     * This is the iOS `WipeJournal.isReadable` distinction, ported fail-closed.*
     *
     * DRIVEN AT THE STORE, NOT THE JOURNAL ADAPTER: `WipeJournalDurabilityAdapter` maps onto the typed
     * `PanicWipe.WipeState`, so it CANNOT carry a line no build understands -- which is exactly why the defect could
     * not be reached through the adapter and has to be planted where the raw durable text lives.
     */
    @Test
    fun anUnreadableRecordIsNotAnEmptyOne() {
        val corrupt = TextStore(listOf("REQUESTED", "NOT_A_REAL_STAGE"))
        assertFalse("a record carrying an unparseable line is NOT readable", authorityOver(corrupt).isReadableJournal)
    }

    /**
     * *** THE ARM THAT KILLS THE PRODUCTION FAIL-OPEN THE REVIEW FOUND. ***
     *
     * *`FileWipeJournal.read()` maps an out-of-range ordinal to `IDLE`; the adapter maps `IDLE` to an EMPTY ladder; the
     * coordinator therefore answers `Refused(NOTHING_TO_RESUME)` -- and the OLD barrier read that as CLEAN and PERMITTED
     * startup over a record nobody could read. **THE REFUSAL IS AN ARTEFACT OF COERCION, NOT A PROVEN CLEAN ESTATE.***
     *
     * This arm feeds exactly that pair -- a `NOTHING_TO_RESUME` refusal WITH an unreadable store -- and asserts the
     * decision is CORRUPT. `decide(outcome, readable = false)` is the only thing standing between the two.
     */
    @Test
    fun anUnreadableRecordOverridesACoercedNothingToResume() {
        val coerced = WipeStepResult.Refused(WipeRefusalCause.NOTHING_TO_RESUME, "nothing to resume; ...")
        // Readable: clean. Unreadable: CORRUPT -- same ladder answer, opposite decision.
        assertEquals(StartupWipeDecision.CLEAN_START, decisionFor(coerced, readable = true))
        assertEquals(
            "a refusal produced by a LOSSY READ is not a proven clean estate, and must not permit startup",
            StartupWipeDecision.CORRUPT_JOURNAL,
            decisionFor(coerced, readable = false),
        )
        assertFalse(decisionFor(coerced, readable = false).allowsPrivateConstruction)
    }

    /** *** AND A GENUINELY EMPTY JOURNAL IS READABLE -- THE POSITIVE CONTROL FOR THE ARM ABOVE. *** */
    @Test
    fun anEmptyJournalIsReadable() {
        assertTrue(
            "an empty journal is a proven clean estate, and must not be reported unreadable: the two must not collapse",
            authorityOver(TextStore(emptyList())).isReadableJournal,
        )
    }

    /** *** AND A WELL-FORMED LADDER IS READABLE, SO THE FAIL-CLOSED DEFAULT DID NOT BREAK THE HAPPY PATH. *** */
    @Test
    fun aWellFormedLadderIsReadable() {
        assertTrue(
            "a legal ladder must read as readable -- the third case, without which the two arms above would pass for a " +
                "property that simply answers `false` to everything",
            authorityOver(TextStore(listOf("REQUESTED", "RUNTIME_DRAINED"))).isReadableJournal,
        )
    }

    // ---------------------------------------------------------------- helpers

    /**
     * *** THE COURT CALLS PRODUCTION `decide()`, NOT A COPY OF IT. ***
     *
     * *My first version of this file replicated the mapping here. A mutation reintroducing `reason.contains(...)` in
     * the SHIPPED `decision` property then left every arm GREEN, because the arms were measuring this copy -- the
     * "a provider's body cannot be measured by a court that passes its own lambda" defect. The mapping is imported from
     * `io.godstone.mesh.di`, so a mutation to production DIES HERE.*
     *
     * `readable = true` models a journal whose durable record parsed; the readability arms below drive that separately.
     */
    private fun decisionFor(r: WipeStepResult, readable: Boolean = true): StartupWipeDecision = decide(r, readable)

    /**
     * The durable store as raw TEXT, so a court can plant a line no build understands.
     *
     * *** IT STATES ITS READABILITY EXPLICITLY, WHICH THE FAIL-CLOSED DEFAULT FORCED. *** *The first version omitted
     * `WipeReadabilityReporting` entirely and two arms went RED -- the default refusing to treat an unanswering store as
     * readable, exactly as intended. A store holding raw text CAN answer, so it must say so; a store that said nothing
     * would now (correctly) be reported unreadable.*
     */
    private class TextStore(lines: List<String> = emptyList()) : WipeDurabilityStore, WipeReadabilityReporting {
        private val lines = lines.toMutableList()
        override fun readJournal(): List<String> = lines
        override fun appendJournal(stateName: String) { lines.add(stateName) }
        /** Derived from the stored text on every call, never a cached flag: an unparseable line is unreadable. */
        override val isReadable: Boolean get() = lines.all { WipeJournalState.fromWire(it) != null }
    }

    /** The coordinator over a store, with the four deferred seams production uses at startup. */
    private fun authorityOver(store: WipeDurabilityStore) = CrashResumableWipe(
        store = store,
        vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
        filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
        runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
        authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
    )
}
