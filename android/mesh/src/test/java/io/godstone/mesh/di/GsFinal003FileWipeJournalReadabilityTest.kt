package io.godstone.mesh.di

import io.godstone.mesh.identity.CrashResumableWipe
import io.godstone.mesh.identity.FileWipeJournal
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeDeferredSeams
import io.godstone.mesh.identity.WipeJournalDurabilityAdapter
import io.godstone.mesh.identity.WipeReadabilityReporting

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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

    // =================================================================================================================
    // (A2/A8) THE DURABLE GENERATION -- THE HALF THE LADDER ALONE CANNOT PROVE.
    // =================================================================================================================

    /**
     * *** THE KILLING ARM FOR THE ABA: `IDLE -> wipe -> IDLE` MUST YIELD A DIFFERENT REVISION. ***
     *
     * *THE TICKET: **"currentdurablegeneration … freshreopen/epoch"** and **"noABA snapshots/wrongestate/stale/reuse"**.*
     * **THE LADDER ALONE FAILETH HERE, AND IT IS MEASURED, NOT ARGUED:** *a completed wipe returneth the record to the
     * rung it started at, so a revision built only from the ladder is BYTE-IDENTICAL before and after the wipe, and a
     * permit minted over the earlier estate would be accepted over the later one.* **A mutation that dropped the epoch
     * from `liveRevision()` would leave these two strings equal and REDDEN this arm.**
     */
    @Test
    fun aCompletedWipeIsADifferentRevisionNotTheSameRungAgain() {
        clear()
        val journal = FileWipeJournal(ctx)
        val coordinator = CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(journal),
            vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
            filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
            runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
            authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
        )
        val before = coordinator.liveRevision()
        // The record is driven across the WHOLE ladder, each rung durably recorded exactly as the coordinator would.
        for (rung in listOf(
            PanicWipe.WipeState.REQUESTED,
            PanicWipe.WipeState.RUNTIME_DRAINED,
            PanicWipe.WipeState.KEY_ERASED,
            PanicWipe.WipeState.ARTIFACTS_DELETED,
            PanicWipe.WipeState.NEW_IDENTITY,
            PanicWipe.WipeState.IDLE,
        )) {
            assertTrue("the rig must land each checkpoint durably", journal.writeDurably(rung))
        }
        val after = coordinator.liveRevision()
        assertNotEquals(
            "*** A COMPLETED WIPE MUST NOT REPRODUCE THE REVISION IT STARTED FROM. *The ladder returneth to the same rung; " +
                "only the durable generation can tell the two estates apart, and this is the ABA the obligation names.* ***",
            before, after,
        )
        assertTrue(
            "*** AND THE GENERATION ITSELF MUST BE READABLE OFF THE RECORD. Observed: $after ***",
            journal.epoch > 0L,
        )
    }

    /**
     * *** A FRESH REOPEN READS THE GENERATION IT ACTUALLY STANDS AT -- NEVER A SNAPSHOT. ***
     *
     * *A NEW `FileWipeJournal` over the SAME preferences (the reopen a process death produceth) must see the SAME
     * generation the write landed, and an independent write must move it for BOTH readers.* **A cached epoch -- the T65
     * `StateRecorder` defect class -- would leave the second reader stale and REDDEN this arm.**
     */
    @Test
    fun aFreshReopenReadsTheGenerationItStandsAt() {
        clear()
        val first = FileWipeJournal(ctx)
        first.writeDurably(PanicWipe.WipeState.REQUESTED)
        val landed = first.epoch
        assertTrue("the rig must land a generation", landed > 0L)

        // THE REOPEN: a second journal over the same durable file, exactly as a new process would build.
        val reopened = FileWipeJournal(ctx)
        assertEquals("a reopen must see the generation the record actually carrieth", landed, reopened.epoch)

        // AND A WRITE THROUGH THE REOPENED HANDLE MOVES IT FOR BOTH READERS.
        assertTrue(reopened.writeDurably(PanicWipe.WipeState.RUNTIME_DRAINED))
        assertEquals(
            "*** THE GENERATION IS READ FRESH, SO THE FIRST HANDLE MUST SEE THE SECOND'S WRITE. A cached value would " +
                "leave it stale, and a stale generation is a permit that outliveth the estate it judged. ***",
            reopened.epoch, first.epoch,
        )
        assertTrue("and it strictly advanced", first.epoch > landed)
        clear()
    }

    /**
     * *** AND A STORE THAT CANNOT NAME A GENERATION CONTRIBUTES ZERO -- WHICH MATCHETH NO MINTED REVISION. ***
     *
     * *The fail-closed direction, on the REAL wire: `EstateRevision.of` over a store that is not a `WipeEpochReporting`
     * must yield epoch `0`, and a revision with epoch `0` must never equal one read from a real record.* **A fabricated
     * default (or a silently-skipped epoch) would make the two indistinguishable and REDDEN this arm.**
     */
    @Test
    fun aStoreThatCannotNameAGenerationFailsClosedToZero() {
        clear()
        // A journal that answers readability and a rung but NOT a generation -- the courts' own in-memory shape.
        val rungOnly = object : io.godstone.mesh.identity.WipeJournal, WipeReadabilityReporting {
            override fun read(): PanicWipe.WipeState = PanicWipe.WipeState.IDLE
            override fun write(state: PanicWipe.WipeState) {}
            override fun clear() {}
            override val isReadable: Boolean get() = true
        }
        val coordinator = CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(rungOnly),
            vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
            filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
            runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
            authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
        )
        assertTrue(
            "*** A STORE THAT CANNOT SAY MUST CONTRIBUTE ZERO. Observed: ${coordinator.liveRevision()} ***",
            coordinator.liveRevision().endsWith("|0"),
        )
        assertEquals(
            "and the typed revision must carry that zero rather than invent one",
            0L, EstateRevision.of(coordinator).epoch,
        )

        // AND THE CONTRAST: the REAL journal, at its own generation, must NOT read as zero.
        val real = FileWipeJournal(ctx)
        real.writeDurably(PanicWipe.WipeState.REQUESTED)
        val realCoordinator = CrashResumableWipe(
            store = WipeJournalDurabilityAdapter(real),
            vault = WipeDeferredSeams.DeferredKeyVaultSeam(),
            filesystem = WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
            runtime = WipeDeferredSeams.DeferredTransportRuntimeSeam(),
            authority = WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
        )
        assertNotEquals(
            "*** THE REAL RECORD'S REVISION MUST DIFFER FROM THE GENERATION-LESS ONE, or the fail-closed zero proves " +
                "nothing. ***",
            "|true|0", realCoordinator.liveRevision(),
        )
        assertTrue(realCoordinator.liveRevision().endsWith("|1"))
        clear()
    }
}
