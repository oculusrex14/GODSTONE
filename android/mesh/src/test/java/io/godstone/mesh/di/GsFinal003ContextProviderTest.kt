package io.godstone.mesh.di

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.identity.PanicWipe
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** ANDROID-05 (round 589): THE CONTEXT-BEARING HARNESS, WHICH THE CARD DEMANDED AND THE RECORD CALLED A WALL. ***
 *
 * THE CARD'S REMAINING WORK, VERBATIM: *"Build a Context-bearing composition harness and inject OS facades; execute
 * start-fail-retry and teardown results."*
 *
 * *** AND THE WALL WAS RECORDED AS "no host test can supply a Context". MEASURED, THAT WAS TOO BROAD, AND THIS COURT
 * IS THE DISPROOF. *** The truth was narrower and it was already visible on this repo:
 *   * `MeshModule` IS AN `internal object`, SO ITS PROVIDERS ARE ORDINARY CALLABLE FUNCTIONS -- round 571 called
 *     `provideBoundRecipientKeyResolver` directly from a court and it WORKED. Only the providers whose signatures
 *     LITERALLY take `@ApplicationContext ctx` need a real Context;
 *   * AND THE ROUTE TO A REAL CONTEXT WAS ALREADY PROVEN ON THIS REPO: the `:app` isle carries Robolectric plus a
 *     `testOptions { unitTests { isIncludeAndroidResources = true } }` block (round 564), with its artifacts pinned in
 *     `gradle/verification-metadata.xml`. **THE SAME MOVE IS APPLIED TO `:mesh` THIS ROUND** -- and the artifacts were
 *     ALREADY PINNED (the component count stayed at 533), so it cost no new supply-chain surface.
 *
 * WHAT THIS COURT DRIVES, AND WHY IT IS THE RIGHT SUBJECT: `MeshModule.provideWipeIsPending(ctx)` IS THE ONE PROVIDER
 * THAT BOTH TAKES A `Context` AND READS THE PLATFORM THROUGH IT -- `FileWipeJournal(ctx).read()`, i.e. the REAL
 * `SharedPreferences("godstone_wipe_journal").getInt("state")`. **SO THESE ARMS MEASURE THE REAL PROVIDER, THE REAL
 * JOURNAL FILE AND THE REAL ANSWER -- NOT A STAND-IN FOR ANY OF THEM.**
 *
 * AND IT IS THE SUBJECT OF GS-FINAL-003's REPAIR, SO THE ARMS BELOW ALSO SETTLE A QUESTION THAT WAS PREVIOUSLY
 * ANSWERED ONLY BY INSPECTION: **DOES THE SHIPPED PROVIDER REALLY ROUTE THE DURABLE RECORD, FOR EACH OF THE REAL
 * JOURNAL STATES?**
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal003ContextProviderTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** Preset the REAL journal, through the same `SharedPreferences` file `FileWipeJournal` readeth. */
    private fun presetJournal(state: PanicWipe.WipeState?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (state == null) remove("state") else putInt("state", state.ordinal)
        }.commit()
    }

    /**
     * *** AN ABSENT JOURNAL IS A CLEAN FIRST LAUNCH, AND THE PROVIDER MUST SAY SO. ***
     *
     * THE POSITIVE CONTROL, AND IT IS THE ONE THAT KEEPETH THE REFUSAL ARMS FROM BEING SATISFIED BY A GATE HARDWIRED
     * TO REFUSE. `FileWipeJournal` readeth an out-of-range or absent ordinal as `IDLE`, so a first launch permits.
     */
    @Test
    fun testGF003TheProviderPermitsOnAnAbsentJournal() {
        presetJournal(null)
        val gate = MeshModule.provideWipeIsPending(ctx())
        assertTrue(
            "*** A CLEAN FIRST LAUNCH MUST PERMIT: `FileWipeJournal` readeth an absent entry as IDLE, so the provider's " +
                "gate must ALLOW, or the app could never start. ***",
            gate.allowsSensitiveUse(),
        )
    }

    /** AND A COMPLETED WIPE PERMITS TOO -- a finished wipe is a legitimate state to work from, not a permanent refusal. */
    @Test
    fun testGF003TheProviderPermitsOnACompletedWipe() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val gate = MeshModule.provideWipeIsPending(ctx())
        assertTrue("*** A COMPLETED WIPE MUST OPEN THE GATE AGAIN -- a permanent refusal would brick the device after " +
            "every wipe. ***", gate.allowsSensitiveUse())
    }

    /**
     * *** AND A PENDING WIPE IS REFUSED -- THROUGH THE REAL PROVIDER, THE REAL JOURNAL AND THE REAL CONTEXT. ***
     *
     * **EVERY STATE THE CARD LISTETH IS EXERCISED**, because the ladder carrieth five rungs between REQUESTED and
     * IDLE and each is a state a crash can leave behind. **A PROVIDER THAT ASKED ONLY ONE OF THEM WOULD BE RIGHT
     * ABOUT THE ONE AND SILENT ABOUT THE REST.**
     */
    @Test
    fun testGF003TheProviderRefusesOnEveryPendingRungOfTheLadder() {
        val pending = PanicWipe.WipeState.entries.filter { it != PanicWipe.WipeState.IDLE }
        assertTrue(
            "*** THE RIG NEEDS PENDING RUNGS TO FAULT: the ladder must carry more than IDLE. Observed: $pending ***",
            pending.isNotEmpty(),
        )
        for (state in pending) {
            presetJournal(state)
            val gate = MeshModule.provideWipeIsPending(ctx())
            assertFalse(
                "*** A JOURNAL STANDING AT $state MUST REFUSE: the record sayeth a wipe is outstanding, and a " +
                    "sensitive read against a store MID-ERASURE is precisely what GS-FINAL-003 forbids. Observed " +
                    "allowsSensitiveUse: ${gate.allowsSensitiveUse()} ***",
                gate.allowsSensitiveUse(),
            )
        }
    }

    /**
     * *** AND THE ANSWER IS READ PER CALL, NOT CACHED -- THE COORDINATOR'S OWN RULE, MEASURED. ***
     *
     * `provideWipeIsPending`'s docstring saith *"READ, NEVER CACHED: ... the answer CHANGES when the wipe completes."*
     * **A PROVIDER THAT CAPTURED THE ANSWER AT CONSTRUCTION WOULD LOOK IDENTICAL IN EVERY ARM ABOVE** -- those arms
     * each build a FRESH provider. THIS ARM BUILDS ONE PROVIDER AND MOVES THE JOURNAL UNDERNEATH IT, which is the only
     * observation that can tell a per-call read from a cached one.
     */
    @Test
    fun testGF003TheProvidersAnswerIsReadPerCallRatherThanCached() {
        presetJournal(PanicWipe.WipeState.REQUESTED)
        val gate = MeshModule.provideWipeIsPending(ctx())   // ONE provider, built while the wipe standeth pending
        assertFalse(
            "the rig must first stand refused, or the re-read below proves nothing",
            gate.allowsSensitiveUse(),
        )

        // THE WIPE COMPLETES: the journal returneth to IDLE while the SAME provider object standeth.
        presetJournal(PanicWipe.WipeState.IDLE)

        assertTrue(
            "*** THE ANSWER MUST BE READ PER CALL: the SAME provider object must now PERMIT, because the durable " +
                "record changed underneath it. A provider that captured its answer at construction would still " +
                "refuse -- and EVERY OTHER ARM IN THIS COURT WOULD STILL PASS, because each buildeth a fresh " +
                "provider. Observed: ${gate.allowsSensitiveUse()} ***",
            gate.allowsSensitiveUse(),
        )
    }
}
