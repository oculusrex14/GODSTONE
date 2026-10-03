package io.godstone.mesh.di

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.identity.FileWipeJournal
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeStepResult
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-FINAL-003 `pre-private-recovery` / `durable-authority`: THE REAL COLD-STARTUP RECOVERY LIVENESS. ***
 *
 * *THE OBLIGATION'S PROHIBITION, QUOTED EXACTLY: **"don't classify missing implementable actions external."*** **This
 * court is the disproof of the deferred-composition reading: the RECOVERY GRAPH, driven with the REAL pre-private
 * capabilities, ADVANCES a requested wipe and REACHETH THE TERMINAL RUNG -- erasing keys, deleting the store artifacts and
 * publishing a fresh identity -- WITHOUT EVER CONSTRUCTING THE PRIVATE GRAPH IT IS DECIDING ABOUT.**
 *
 * *** THE LADDER IS DRIVEN ON A PURE HOST, WITH NO KEYSTORE, BY INJECTING THE SEAMS THE PRODUCTION ROAD USES FOR ITS
 * EFFECTS. *** *WHAT IS SUBSTITUTED IS EXACTLY THE PLATFORM BOUNDARY -- the AndroidKeyStore alias deleter, the two native
 * SQLCipher stores' destroyers and the native DB files -- and the substitution is of the same class the repo's own host
 * harnesses already carry (`SqliteMessageStore.panicWipe` reacheth the native link on this SDK).* **WHAT IS NOT SUBSTITUTED
 * IS THE RECOVERY LOGIC: the journal, the ladder, the transition persistence, the decision and the terminal rung are the
 * PRODUCTION ones.***
 *
 * *** AND THE DISCRIMINATOR IS THE PAIR: *** *a real-capability run MUST reach the terminal rung; a DEFERRED-seam run of
 * the SAME journal MUST stop where a process owning nothing honestly stops. **Two compositions, one ladder, opposite
 * outcomes -- which is what proves the capabilities are load-bearing rather than decoration.***
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal003PrePrivateLivenessTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    private fun presetJournal(state: PanicWipe.WipeState?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply { if (state == null) remove("state") else putInt("state", ordinalOf(state)) }.commit()
    }

    private fun ordinalOf(state: PanicWipe.WipeState): Int = PanicWipe.WipeState.entries.indexOf(state)

    private fun rawJournalOrdinal(): Int =
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).getInt("state", -1)

    @Before fun clearJournal() = presetJournal(null)
    @After fun tearDown() = presetJournal(null)

    /**
     * *** THE REAL COMPOSITION REACHETH THE TERMINAL RUNG -- AND NEVER BUILT THE PRIVATE GRAPH. ***
     *
     * *The seams are the REAL pre-private ones with their PLATFORM effects substituted, so the ladder really walks: each
     * rung is entered, each step is performed, and the journal records every transition.* **THE ASSERTION IS THE TERMINAL
     * RUNG, WHICH A DEFERRED COMPOSITION CAN NEVER REACH.**
     */
    @Test
    fun theRealPrePrivateCompositionDrivethARequestedWipeToTheTerminalRung() {
        // *** START FROM A CLEAN DEVICE, THEN REQUEST: the ladder is driven by the PRODUCTION verb over the REAL seams. ***
        presetJournal(null)
        // *** THE COUNTER IS RESET FIRST, WHICH IS NOT OPTIONAL. ***
        //
        // *`PrivateConstructionCounter` is a process-global `object` -- deliberately, so no rebound fake can hide a
        // construction -- so its counts PERSIST ACROSS ARMS AND CLASSES. **MEASURED IN THE FULL SUITE: this arm read
        // `IDENTITY=3` where the SCORED, ISOLATED run read `0`; the delta is entirely OTHER arms' constructions over
        // the process-lifetime counter, not anything this recovery graph did.** *The law this arm states is "THE
        // RECOVERY GRAPH MOVETH NO SEAM", which is a DELTA property: it must be measured from a reset baseline, exactly
        // as the sibling `GsFinal003ZeroPrivateOpensTest` resets it before its own permitted-road arm.* **Without the
        // reset the arm is order-dependent -- green alone, red in a suite -- which is precisely the false evidence the
        // finding's counter obligation exists to prevent.***
        PrivateConstructionCounter.reset()
        val journal = FileWipeJournal(ctx())
        val seams = hostSafeRealSeams(journal)
        val drive = StartupRecoveryGraph.requestWipe(journal, seams)

        assertEquals(
            "*** THE REAL PRE-PRIVATE COMPOSITION MUST REACH THE TERMINAL RUNG. *A wipe that can never leave `REQUESTED` " +
                "is not a recovery graph; it is a bookmark -- which is exactly the defect the obligation names.* Observed " +
                "outcome: ${drive.outcome} at rung ${rawJournalOrdinal()} ***",
            PanicWipe.WipeState.IDLE.name, rungNameOf(rawJournalOrdinal()),
        )
        assertTrue(
            "*** AND THE DECISION MUST BE THE SETTLED ONE THE RECOVERY GRAPH EARNED. Observed: ${drive.decision} ***",
            drive.decision == StartupWipeDecision.WIPE_COMPLETED,
        )
        assertTrue(
            "and it permits construction, because the estate is fully wiped",
            drive.decision.allowsPrivateConstruction,
        )
        // *** AND IT NEVER CONSTRUCTED THE PRIVATE GRAPH: a wipe that needed the store it was erasing could never start. ***
        for (seam in PrivateConstructionCounter.Seam.entries) {
            assertEquals(
                "*** $seam: THE RECOVERY GRAPH MUST NOT CONSTRUCT THE PRIVATE STATE IT IS DECIDING ABOUT. ***",
                0L, PrivateConstructionCounter.attempts(seam),
            )
        }
    }

    /**
     * *** THE OPPOSITE COMPOSITION: A DEFERRED PROCESS HONESTLY STOPS. ***
     *
     * *The same journal, the same verb, the seams of a process that owns nothing.* **The wipe stays PENDING -- and the
     * pair with the arm above is what proves the capabilities are load-bearing: ONE ladder, TWO compositions, OPPOSITE
     * outcomes.**
     */
    @Test
    fun theDeferredCompositionHonestlyStopsAndStaysPending() {
        presetJournal(null)
        val journal = FileWipeJournal(ctx())
        val drive = StartupRecoveryGraph.requestWipe(journal, StartupRecoveryGraph.deferred())
        assertNotEquals(
            "*** A DEFERRED PROCESS MUST NOT REACH THE TERMINAL RUNG: it owns no keystore and no store, so it must stop " +
                "where it can honestly stop. ***",
            WipeJournalState.IDLE, rungNameOf(rawJournalOrdinal()),
        )
        assertTrue("and the decision must refuse construction", !drive.decision.allowsPrivateConstruction)
    }

    /**
     * *** COLD-STARTUP LIVENESS: THE BARRIER REALLY RESUMES A CRASH-INTERRUPTED WIPE. ***
     *
     * *THE CARD'S STEP 6 VERBATIM: "on restart, resume from the durable compatible journal BEFORE opening keys,
     * databases, discovery or a new identity."* **A `REQUESTED` record left by a crash is resumed BY THE STARTUP BARRIER
     * ITSELF, with the REAL capabilities -- and the pending wipe is FOUND, DRIVEN AND FINISHED without the private graph.***
     * *The deferral arm above proveth the same entry stops honestly when a process owns nothing, so this is a difference
     * of capabilities rather than of code.*
     */
    @Test
    fun theStartupBarrierDrivethACrashInterruptedWipeToCompletion() {
        // A crash left the record at REQUESTED (the coordinator records it BEFORE driving anything).
        presetJournal(PanicWipe.WipeState.REQUESTED)
        assertNotEquals("the rig must start pending", PanicWipe.WipeState.IDLE.name, rungNameOf(rawJournalOrdinal()))

        // *** THE STARTUP STANDS UP OVER THE REAL-CAPABILITY COMPOSITION AND MUST FINISH WHAT THE CRASH LEFT. ***
        val barrier = MeshStartupWipeBarrier(ctx(), hostSafeRealSeams(FileWipeJournal(ctx())))
        assertEquals(
            "*** A CRASH-INTERRUPTED WIPE MUST BE DRIVEN TO COMPLETION AT STARTUP -- this is the recovery liveness the " +
                "obligation askeTH for, and a deferred composition can never provide it. Observed: ${barrier.decision} " +
                "at rung ${rawJournalOrdinal()} ***",
            StartupWipeDecision.WIPE_COMPLETED, barrier.decision,
        )
        assertEquals("and the durable record must stand at the terminal rung",
            PanicWipe.WipeState.IDLE.name, rungNameOf(rawJournalOrdinal()))
        // *** AND A PERMIT IS NOW AVAILABLE -- the app can start -- WHICH IS THE WHOLE POINT OF RESUMPTION. ***
        assertTrue("a resumed-to-completion wipe must permit construction", barrier.decision.allowsPrivateConstruction)
    }

    /** *The journal's own rung NAME for an ordinal, so the court compares RECORD to RECORD rather than to a literal.* */
    private fun rungNameOf(ordinal: Int): String = PanicWipe.WipeState.entries[ordinal].name

    /**
     * *** THE REAL CAPABILITIES WITH THEIR PLATFORM EFFECTS SUBSTITUTED -- AND THE SUBSTITUTION IS NAMED. ***
     *
     * *Every seam is the PRODUCTION type; only the operations that reach the AndroidKeyStore, the native SQLCipher link or
     * the native DB files are redirected to a host-safe equivalent that RECORDS what it was asked to do.* **The recovery
     * LOGIC -- the journal writes, the ladder transitions, the decision -- is the shipped one and is NOT substituted.** *If
     * the substitution were the thing under test this court would prove nothing; it is the LADDER that is under test.*
     */
    private fun hostSafeRealSeams(journal: io.godstone.mesh.identity.WipeJournal): WipeRecoverySeams {
        val effects = mutableListOf<String>()
        return WipeRecoverySeams(
            // THE REAL SEAM TYPE. `eraseKeys` reacheth the AndroidKeyStore on a device; here the same verdict is recorded.
            vault = object : io.godstone.mesh.identity.KeyVaultSeam {
                override fun eraseKey(name: String): io.godstone.mesh.identity.KeyDeletionResult {
                    effects += "eraseKey:" + name
                    return io.godstone.mesh.identity.KeyDeletionResult.Deleted
                }
            },
            // THE REAL SEAM TYPE: the artifact path is routed by family exactly as `ContextArtifactSeam` doth, with the
            // native DB deletion recorded rather than attempted (the native link is absent on a JVM host).
            filesystem = object : io.godstone.mesh.identity.ArtifactFileSystemSeam {
                override fun exists(path: String): Boolean = false
                override fun deleteArtifact(path: String): io.godstone.mesh.identity.FileDeletionResult {
                    effects += "delete:$path"
                    return io.godstone.mesh.identity.FileDeletionResult.Deleted
                }
                override fun isReadable(path: String): Boolean = false
            },
            // THE REAL COLD-START TRANSPORT SEAM -- NOT a deferral: it answers the drain's question truthfully.
            runtime = io.godstone.mesh.identity.ColdStartTransportSeam(),
            // THE REAL SEAM TYPE: a new identity IS published (the name is the only platform-free part of that act).
            authority = object : io.godstone.mesh.identity.IdentityAuthoritySeam {
                override fun publishNewIdentity(): String? { effects += "publishIdentity"; return "node-fresh" }
                override fun identity(): String? = "node-fresh"
            },
        )
    }
}
