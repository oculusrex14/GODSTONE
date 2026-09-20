package io.godstone.mesh.di

import io.godstone.mesh.identity.CrashResumableWipe
import io.godstone.mesh.identity.FileWipeJournal
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeDeferredSeams
import io.godstone.mesh.identity.WipeJournalDurabilityAdapter

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * *** GS-FINAL-003: THE REAL PRODUCTION STORE, DRIVEN OVER A REAL `Context`. ***
 *
 * THE DEFECT THIS FILE EXISTS FOR, FOUND BY AN EXTERNAL REVIEW AFTER MY FIRST PORT *PASSED*:
 *
 *     FileWipeJournal.read():  val ord = prefs.getInt(KEY, -1)
 *                              return if (ord < 0 || ord >= entries.size) IDLE else entries[ord]
 *
 * **AN OUT-OF-RANGE ORDINAL BECAME `IDLE`** -- the same value an ABSENT record produces. The adapter maps `IDLE` to an
 * EMPTY ladder, the coordinator answers `Refused(NOTHING_TO_RESUME)`, and the startup barrier PERMITTED construction
 * over material that may have been mid-erasure. *That is the identical fail-open repaired on iOS the same day
 * (`UserDefaultsWipeJournal.read() ?? .idle`), one layer down and REACHABLE IN PRODUCTION.*
 *
 * *** WHY MY EARLIER COURTS COULD NOT CATCH IT. *** *They planted unparseable input via a FAKE store, and the fake fed
 * the coordinator's already-coerced `List<String>`. The lossy step is INSIDE `FileWipeJournal.read()`, so a check
 * derived from `read()`'s output is structurally blind to it -- the information is gone before it is asked for.*
 *
 * **THIS COURT DRIVES THE REAL `FileWipeJournal` FROM A REAL `Context` AND PLANTS A BAD ORDINAL IN ITS OWN
 * `SharedPreferences`.** *The mutation that matters: restore `?? IDLE` semantics for garbage (i.e. make `isReadable`
 * answer `true` for an out-of-range ordinal) and `aBadOrdinalIsNotACleanStart` DIES.*
 */
@RunWith(RobolectricTestRunner::class)
class GsFinal003FileWipeJournalReadabilityTest {

    private val ctx: Context get() = ApplicationProvider.getApplicationContext()

    /** The production preferences the real journal reads, so a plant lands where the store actually looks. */
    private val prefs get() = ctx.getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)

    private fun clear() { prefs.edit().clear().commit() }

    /**
     * *** AN OUT-OF-RANGE ORDINAL IS NOT A CLEAN START. ***
     *
     * *This is the killing arm. Before the repair, `read()` returned `IDLE` for this same input, the ladder was empty,
     * and the barrier permitted startup -- so the assertion `CORRUPT_JOURNAL` could not have been made.*
     */
    @Test
    fun aBadOrdinalIsNotACleanStart() {
        clear()
        // A durable ordinal no enum case corresponds to: the shape of a corrupt or downgraded record.
        prefs.edit().putInt("state", 9_999).commit()

        val journal = FileWipeJournal(ctx)
        assertFalse(
            "an out-of-range ordinal is material we cannot read -- reporting it readable is the fail-open",
            journal.isReadable,
        )
        // And the coordinator over the REAL journal must not answer clean either.
        val authority = CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(journal),
            vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
            filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
            runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
            authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
        )
        assertFalse("the coordinator must see it too", authority.isReadableJournal)
        assertEquals(
            "*** AND THE STARTUP DECISION MUST BE CORRUPT, NOT CLEAN *** -- the coercion made the ladder look empty, " +
                "and judging that emptiness as a proven clean estate is precisely the defect",
            StartupWipeDecision.CORRUPT_JOURNAL,
            decide(authority.resume(), authority.isReadableJournal),
        )
        assertFalse(decide(authority.resume(), authority.isReadableJournal).allowsPrivateConstruction)
        clear()
    }

    /** *** AN ABSENT RECORD IS A GENUINE FIRST LAUNCH AND MUST STAY PERMITTED. *** */
    @Test
    fun anAbsentRecordIsACleanStart() {
        clear()
        val journal = FileWipeJournal(ctx)
        assertTrue(
            "nothing was ever written -- a proven clean estate, NOT the same claim as an unreadable one",
            journal.isReadable,
        )
        assertEquals(PanicWipe.WipeState.IDLE, journal.read())
    }

    /** *** AND A REAL DURABLE WRITE ROUND-TRIPS AS READABLE. *** */
    @Test
    fun aWrittenStateIsReadable() {
        clear()
        val journal = FileWipeJournal(ctx)
        journal.write(PanicWipe.WipeState.REQUESTED)
        assertTrue("a value this build wrote must read back readable", journal.isReadable)
        assertEquals(PanicWipe.WipeState.REQUESTED, journal.read())
        clear()
    }

    /**
     * *** THE SHIPPED BARRIER, ASKED END TO END. ***
     *
     * *The court above judges the pieces; this one drives `MeshStartupWipeBarrier` exactly as production builds it --
     * real `Context`, real `FileWipeJournal` -- so the DECISION is measured through the shipped path and not only
     * through its parts. A clean device must be permitted; the barrier must also expose a TYPED decision, not a bare
     * Boolean, which is the audit's clause.*
     */
    @Test
    fun theShippedBarrierDecidesCleanOnACleanDevice() {
        clear()
        val barrier = MeshStartupWipeBarrier(ctx)
        assertEquals(
            "a device with no durable record is a clean first launch",
            StartupWipeDecision.CLEAN_START,
            barrier.decision,
        )
        assertTrue(barrier.permitsStartup)
        assertFalse("and it needs no operator", barrier.decision.requiresOperator)
        clear()
    }

    /** *** AND THE SAME SHIPPED BARRIER REFUSES OVER A CORRUPT RECORD. *** */
    @Test
    fun theShippedBarrierRefusesOverACorruptRecord() {
        clear()
        prefs.edit().putInt("state", 9_999).commit()

        val barrier = MeshStartupWipeBarrier(ctx)
        assertEquals(
            "a corrupt durable record must NOT be rendered as a clean launch by the shipped barrier",
            StartupWipeDecision.CORRUPT_JOURNAL,
            barrier.decision,
        )
        assertFalse("so private construction must not be permitted", barrier.permitsStartup)
        assertTrue("and an operator must be told", barrier.decision.requiresOperator)
        clear()
    }
}
