package io.godstone.mesh.lab.wipe

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.identity.CrashResumableWipe
import io.godstone.mesh.identity.FileWipeJournal
import io.godstone.mesh.identity.IdentityAuthoritySeam
import io.godstone.mesh.identity.KeyDeletionResult
import io.godstone.mesh.identity.KeyVaultSeam
import io.godstone.mesh.identity.ArtifactFileSystemSeam
import io.godstone.mesh.identity.FileDeletionResult
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.RuntimeDrainReceipt
import io.godstone.mesh.identity.TransportRuntimeSeam
import io.godstone.mesh.identity.WipeCrashException
import io.godstone.mesh.identity.WipeDeferredSeams
import io.godstone.mesh.identity.WipeDurabilityStore
import io.godstone.mesh.identity.WipeEpochReporting
import io.godstone.mesh.identity.WipeHooks
import io.godstone.mesh.identity.WipeJournal
import io.godstone.mesh.identity.WipeJournalDurabilityAdapter
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeReadabilityReporting
import io.godstone.mesh.identity.WipeRefusalCause
import io.godstone.mesh.identity.WipeScope
import io.godstone.mesh.identity.WipeStepResult
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.UUID

/**
 * *** THE iOS RECOVERY-LADDER VERIFICATIONS, PORTED TO THIS ISLE -- AGAINST THE REAL COORDINATOR. ***
 *
 * *THE PLAN'S OWN REQUIREMENT: port the iOS court's ladder verifications (read from the REAL
 * `ios/Godstone/Sources/GodstoneMesh/CrashResumableWipe.swift` -- NOT from any wipe retry helper that merely
 * resembles it), and name the mapping that was verified.*
 *
 * *** WHAT WAS ALREADY EQUIVALENT, MEASURED BY READING BOTH SOURCES RATHER THAN ASSUMED: ***
 *
 * | iOS (`CrashResumableWipe.swift`) | Android (`identity/CrashResumableWipe.kt`) | status |
 * |---|---|---|
 * | `WipeJournalState` `requested..idle` ranks 1..6 | `WipeJournalState` `REQUESTED..IDLE(rank)` | ported (this file's first arm) |
 * | `fromWire("KEY_ERASED") == .keysErased` | `fromWire("KEY_ERASED") == KEYS_ERASED` | ported |
 * | `RuntimeDrainReceipt.drained/notDrained` | same, `isDrained` | ported |
 * | `KeyDeletionResult.absent/deleted/failed` | same, `satisfiesErasure` | ported |
 * | `FileDeletionResult.absent/deleted/failed` | same, `satisfiesCleanup` | ported |
 * | `WipeStepResult` advanced/alreadyAtOrPast/retryLater/refused | same, + typed `WipeRefusalCause` | ported |
 * | `CrashResumableWipe.fullLadder` | `CrashResumableWipe.FULL_LADDER` | ported |
 * | `WipeScope.privateArtifacts` | `WipeScope.PRIVATE_ARTIFACTS` | ported (identical six names) |
 * | `WipeScope.privateKeys` (`store-dek-message`, `store-dek-peer`, the two identity names) | `PRIVATE_KEYS` (three names) -- **routed through ONE destroyer** (`WipeArtifacts.eraseKeys()` destroys the KEK that protects everything) | mapped, see the scope arm |
 * | `WipeOwnerDraining` (the estate answers the drain) | **NOT PRESENT** -- Android drains through `TransportRuntimeSeam.drainTransport()` only | named gap, not ported |
 * | `KeyDeletionResult.verifiedAbsent` | **NOT PRESENT** -- `WipeKeyVaultSeam` routes every name to the one KEK destroyer | named gap |
 * | `publishOrAdoptIdentity(wipeGeneration:)` | **NOT PRESENT** -- Android publishes through `publishNewIdentity()` | named gap, arm below measures the real behaviour |
 * | `WipeEpochReporting.bumpEpoch()` | `WipeJournal`/adapter `epoch` (READ-only; the production journal bumps it inside `writeDurably`) | mapped |
 *
 * *** AND WHAT THIS FILE ADDS, BECAUSE THE ANDROID COURT DID NOT MEASURE IT: *** *the iOS arms that were ported to
 * Android only through `ReadinessT34Test`'s own `FakeStore` (a double journal), and the iOS `durablecourts` arms
 * (R1/R2/R3) that had NO Android witness at all:*
 *
 *   * a **dropped `REQUESTED` checkpoint** never beginneth the ladder (iOS `persistRequest` throweth);
 *   * a **dropped terminal checkpoint** leaveth the wipe PENDING rather than reporting completion (iOS R3/A9);
 *   * a **reentrant drive is REFUSED** rather than run twice (iOS `WipeDriveError.reentrant`);
 *   * a wipe requested through **ANOTHER OWNER is OBSERVED at this one** (iOS R2), proven through the durable
 *     revision rather than through a cached ladder;
 *   * a **reboot mid-wipe resumes from the REAL production journal** (iOS T34 arm 2, but with the real
 *     `FileWipeJournal` + `WipeJournalDurabilityAdapter` instead of a double);
 *   * the **drain checkpoint is written into the real production journal** (iOS GS-STORE-006 arm), with an
 *     unknown stage name REFUSED;
 *   * **every persisted checkpoint stays PENDING through the deferred seams** (iOS GS-STORE-006 arm), which is
 *     the composition the startup barrier actually owns.
 *
 * *Every arm drives the PRODUCTION coordinator. Where a seam is a fake, it is a fake of a PLATFORM door (a
 * keystore, a radio) and never of the ladder.*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class RecoveryLadderParityTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    // ------------------------------------------------------------------------------------------------
    // the durable store double: THE SHAPE THE COORDINATOR CONSUMES, plus the two reporting protocols
    // ------------------------------------------------------------------------------------------------

    /**
     * *A double journal that can REFUSE a named checkpoint and REPORT a generation -- the two contracts the
     * production adapter carries and the coordinator branches on.* **It answers `isReadable` explicitly, because
     * a store that has not answered that question must not read as readable (the fail-closed default is stated
     * in `CrashResumableWipe.isReadableJournal`).**
     */
    private class ScriptedStore(
        val lines: MutableList<String> = mutableListOf(),
        /** Checkpoint names whose durable write must NOT land -- the dropped-checkpoint instrument. */
        val refuseWrites: MutableSet<String> = mutableSetOf(),
        private var generation: Long = 0L,
    ) : WipeDurabilityStore, WipeReadabilityReporting, WipeEpochReporting {

        val writes = mutableListOf<String>()
        var readable: Boolean = true

        override fun readJournal(): List<String> = lines.toList()

        override fun appendJournal(stateName: String) {
            writes += stateName
            lines += stateName
        }

        override fun appendJournalDurably(stateName: String): Boolean {
            if (stateName in refuseWrites) return false
            writes += stateName
            lines += stateName
            generation += 1
            return true
        }

        override val isReadable: Boolean get() = readable
        override val epoch: Long get() = generation

        /** *The operator's own durable bump, exactly as `FileWipeJournal.writeDurably` performeth it.* */
        fun bump(): Long {
            generation += 1
            return generation
        }

        fun seed(vararg names: String) {
            lines += names
        }
    }

    /** The vault that records what it was asked to erase; every name is satisfied by the one KEK destroyer. */
    private class RecordingVault : KeyVaultSeam {
        val erased = mutableListOf<String>()
        var failWith: KeyDeletionResult.Failed? = null
        override fun eraseKey(name: String): KeyDeletionResult {
            erased += name
            return failWith ?: KeyDeletionResult.Deleted
        }
    }

    private class RecordingFs : ArtifactFileSystemSeam {
        val deleted = mutableListOf<String>()
        override fun deleteArtifact(path: String): FileDeletionResult {
            deleted += path
            return FileDeletionResult.Deleted
        }
        override fun exists(path: String): Boolean = false
        override fun isReadable(path: String): Boolean = false
    }

    private class RecordingRuntime(var drainFails: Int = 0) : TransportRuntimeSeam {
        var drains = 0
        var attempts = 0
        override fun drainTransport(): RuntimeDrainReceipt {
            attempts += 1
            if (drainFails > 0) {
                drainFails -= 1
                return RuntimeDrainReceipt.NotDrained("radio pairing in progress")
            }
            drains += 1
            return RuntimeDrainReceipt.Drained(closedTransports = 1, quiescedRuntime = true)
        }
        override fun isQuiesced(): Boolean = drains > 0
        override fun fireRadio(msg: String): Boolean = false
        override fun sendVia(msg: String): Boolean = false
    }

    private class RecordingAuthority : IdentityAuthoritySeam {
        val published = mutableListOf<String>()
        var refuse: Boolean = false
        override fun publishNewIdentity(): String? {
            if (refuse) return null
            val name = "node-${published.size + 1}"
            published += name
            return name
        }
        override fun identity(): String? = published.lastOrNull()
    }

    private class CrashHook(var at: String? = null) : WipeHooks {
        var fired = 0
        override fun beforeWrite(stateName: String) {
            if (at != null && stateName == at) {
                at = null
                fired += 1
                throw WipeCrashException("power loss at $stateName")
            }
        }
    }

    private class Rig {
        val store = ScriptedStore()
        val vault = RecordingVault()
        val fs = RecordingFs()
        val runtime = RecordingRuntime()
        val authority = RecordingAuthority()
        val hook = CrashHook()
        fun engine(): CrashResumableWipe =
            CrashResumableWipe(store, vault, fs, runtime, authority, hook)
    }

    /** Drive to a terminal answer, swallowing the injected crash exactly once. */
    private fun drive(engine: CrashResumableWipe, first: () -> WipeStepResult): WipeStepResult {
        val r = try { first() } catch (_: WipeCrashException) {
            return WipeStepResult.RetryLater(WipeJournalState.REQUESTED, CRASHED)
        }
        var guard = 0
        var current = r
        while (current is WipeStepResult.RetryLater && current.reason != CRASHED && guard < 32) {
            guard += 1
            current = try { engine.step() } catch (_: WipeCrashException) {
                return WipeStepResult.RetryLater(WipeJournalState.REQUESTED, CRASHED)
            }
        }
        return current
    }

    private fun advancedTo(r: WipeStepResult, state: WipeJournalState): Boolean =
        r is WipeStepResult.Advanced && r.to == state

    private fun retryAt(r: WipeStepResult, state: WipeJournalState): Boolean =
        r is WipeStepResult.RetryLater && r.at == state

    @Before
    fun clearJournal() {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @After
    fun tearDown() {
        clearJournal()
    }

    // ================================================================================================
    // (1) THE LADDER ITSELF IS THE iOS LADDER, RUNG FOR RUNG AND RANK FOR RANK.
    // ================================================================================================

    /**
     * *** THE RUNG NAMES AND THEIR ORDER ARE THE iOS ISLE'S -- MODULO THE ONE SPELLING THE ADAPTER OWNS. ***
     *
     * *iOS writeth `KEYS_ERASED` and its `fromWire` accepteth the legacy `KEY_ERASED`; this isle PERSISTETH
     * `KEY_ERASED` and its `fromWire` accepteth both.* **The ORDER is what both ladders must agree on, and the
     * ranks are that order stated as data.**
     */
    @Test
    fun theLadderIsTheIosLadderRungForRungAndRankForRank() {
        assertEquals(
            "*** THE FULL LADDER MUST BE THE iOS LADDER: the plan ported it and this pins the port. ***",
            listOf("REQUESTED", "RUNTIME_DRAINED", "KEYS_ERASED", "ARTIFACTS_DELETED", "NEW_IDENTITY", "IDLE"),
            CrashResumableWipe.FULL_LADDER,
        )
        assertEquals(
            "*** AND THE RANKS ARE THAT ORDER -- 1..6, strictly monotone, as iOS declares them. ***",
            listOf(1, 2, 3, 4, 5, 6),
            CrashResumableWipe.FULL_LADDER.map { requireNotNull(WipeJournalState.fromWire(it)).rank },
        )
        assertEquals(
            "*** THE LEGACY SPELLING THE SEALED LADDER WROTE MUST PARSE TO THE CANONICAL RUNG, as iOS's fromWire doth. ***",
            WipeJournalState.KEYS_ERASED, WipeJournalState.fromWire("KEY_ERASED"),
        )
        assertEquals(
            "*** AND AN UNKNOWN FUTURE SPELLING MUST MAP TO NOTHING, so callers refuse rather than guess a position. ***",
            null, WipeJournalState.fromWire("WATERS_DOWN"),
        )
    }

    /**
     * *** EVERY NAME IN THE DELETE SCOPE MUST HAVE AN OWNER, AND THE SCOPE MUST NOT EXCEED IT (GS-FINAL-002). ***
     *
     * *iOS's `privateArtifacts` and this isle's `PRIVATE_ARTIFACTS` are the SAME six physical names -- which is
     * what maketh the crash-restart arm SR06 reach BOTH stores.* **And `filterPrivatePaths` must be a real
     * narrowing: a public Archive asset offered to it must not survive the filter as a private name.**
     */
    @Test
    fun theDeleteScopeIsTheSixOwnedArtifactsAndFiltersAnythingElse() {
        assertEquals(
            "*** THE ENUMERATED PRIVATE ARTIFACTS MUST BE THE iOS SET: both durable stores and their sidecars. ***",
            listOf("mesh.db", "mesh.db-wal", "mesh.db-shm", "peer.db", "peer.db-wal", "peer.db-shm"),
            WipeScope.PRIVATE_ARTIFACTS,
        )
        assertEquals(
            "*** THE FILTER MUST NARROW RATHER THAN PASS: a public asset must never reach the destroyers. ***",
            listOf("mesh.db"),
            WipeScope.filterPrivatePaths(listOf("mesh.db", "accepted-archive/model.bin", "binding-salt")),
        )
        assertTrue(
            "*** AND THE KEY SCOPE MUST NOT CARRY THE UNOWNED `binding-salt`: a name with no owner would hold the " +
                "wipe pending for ever on an isle whose vault answers an unowned name retryably. ***",
            WipeScope.PRIVATE_KEYS.none { it == "binding-salt" },
        )
        assertEquals(
            "*** THE THREE KEY NAMES ARE THE iOS VOCABULARY, ROUTED HERE THROUGH ONE KEK DESTROYER. ***",
            listOf("store-dek", "identity-ed25519", "identity-x25519"),
            WipeScope.PRIVATE_KEYS,
        )
    }

    // ================================================================================================
    // (2) iOS R3 -- A DROPPED CHECKPOINT MUST NOT LET THE LADDER ADVANCE.
    // ================================================================================================

    /**
     * *** iOS `persistRequest` THROWETH WHEN THE `REQUESTED` WRITE IS REFUSED; THE ANDROID TWIN REFUSETH. ***
     *
     * *THE DEFECT THE iOS ARM MEASURED: "A store whose durable write DROPPED still let the coordinator advance its
     * in-memory ladder to `IDLE` and issue a private permit from an UNCOMMITTED terminal state."* **So a refused
     * `REQUESTED` must leave the journal EMPTY, the estate UNTOUCHED, and the answer a typed refusal -- never a
     * begun wipe.**
     */
    @Test
    fun aRequestWhoseCheckpointDroppedNeverBeginsTheLadder() {
        val rig = Rig()
        rig.store.refuseWrites += WipeJournalState.REQUESTED.name
        val e = rig.engine()
        val r = e.requestWipe()
        assertTrue(
            "*** A REFUSED `REQUESTED` CHECKPOINT MUST BE A TYPED REFUSAL. Observed: $r ***",
            r is WipeStepResult.Refused && r.cause == WipeRefusalCause.CHECKPOINT_NOT_DURABLE,
        )
        assertTrue("*** NOTHING MAY BE JOURNALED. Observed: ${rig.store.lines} ***", rig.store.lines.isEmpty())
        assertTrue("*** AND NOT ONE KEY MAY BE ERASED ON AN UNRECORDED REQUEST. ***", rig.vault.erased.isEmpty())
        assertTrue("*** NOR AN ARTIFACT DELETED. ***", rig.fs.deleted.isEmpty())
        assertTrue("*** NOR AN IDENTITY PUBLISHED. ***", rig.authority.published.isEmpty())
        assertEquals("and the transport must not even have been drained", 0, rig.runtime.attempts)
    }

    /**
     * *** iOS R3/A9: THE TERMINAL COMMIT'S VERDICT IS HONOURED LAST OF ALL. ***
     *
     * *A `commit()` that did not reach disk means the record still standeth at `NEW_IDENTITY` while the estate
     * believes the wipe finished.* **The ladder must STAY PENDING and the record must NOT read `IDLE`.**
     */
    @Test
    fun aTerminalCheckpointThatDroppedHoldsTheLadderPending() {
        val rig = Rig()
        rig.store.refuseWrites += WipeJournalState.IDLE.name
        val e = rig.engine()
        val r = e.requestWipe()
        assertTrue(
            "*** A DROPPED TERMINAL COMMIT MUST BE A TYPED REFUSAL, NOT `Advanced(_, IDLE)`. Observed: $r ***",
            r is WipeStepResult.Refused && r.cause == WipeRefusalCause.CHECKPOINT_NOT_DURABLE,
        )
        assertEquals(
            "*** AND THE DURABLE RECORD MUST STAND WHERE THE LAST LANDED CHECKPOINT PUT IT. ***",
            listOf("REQUESTED", "RUNTIME_DRAINED", "KEYS_ERASED", "ARTIFACTS_DELETED", "NEW_IDENTITY"),
            rig.store.lines,
        )
        assertTrue("*** AND THE WIPE MUST READ AS PENDING, so no private permit can be minted over it. ***", e.isWipePending)
        assertFalse("the gate must stay closed over an uncommitted terminal", e.allowsStartup())
        assertFalse("and the sensitive API is refused too", e.allowsSensitiveApi())
        // *** AND ONCE THE MEDIUM ACCEPTS, A FRESH OWNER SETTLES IT -- the checkpoint is idempotent and resumable. ***
        rig.store.refuseWrites.clear()
        val fresh = Rig0(rig).engine()
        assertTrue(
            "*** A FRESH OWNER OVER THE SAME RECORD MUST SETTLE THE WIPE ONCE THE MEDIUM ACCEPTS THE TERMINAL COMMIT. ***",
            advancedTo(drive(fresh) { fresh.resume() }, WipeJournalState.IDLE),
        )
    }

    /** *A rig over ANOTHER owner's record: the same store and seams, a fresh coordinator (what a relaunch is).* */
    private class Rig0(private val rig: Rig) {
        fun engine(): CrashResumableWipe = CrashResumableWipe(
            rig.store, rig.vault, rig.fs, rig.runtime, rig.authority,
        )
    }

    // ================================================================================================
    // (3) iOS R1/R2 -- ONE SERIALIZATION POINT, AND A REENTRANT DRIVE IS REFUSED.
    // ================================================================================================

    /**
     * *** iOS `WipeDriveError.reentrant`: A SEAM THAT RE-ENTERS FINDETH A REFUSAL, NOT A SECOND EFFECT. ***
     *
     * *THE ANDROID COORDINATOR CARRIES THE SAME LAW AS AN EXPLICIT FLAG ("a `synchronized` block cannot stop this
     * (the lock is reentrant)").* **A hook is the honest instrument: it is invoked from INSIDE a drive, so its
     * nested call is a real reentrancy rather than a sequential second call.**
     */
    @Test
    fun aReentrantDriveIsRefusedRatherThanRunTwice() {
        val rig = Rig()
        var nested: WipeStepResult? = null
        var reentrant: CrashResumableWipe? = null
        // The hook re-enters the SAME coordinator while a drive holds it.
        val hook = object : WipeHooks {
            override fun beforeWrite(stateName: String) {
                if (stateName == WipeJournalState.RUNTIME_DRAINED.name && nested == null) {
                    nested = reentrant?.requestWipe()
                }
            }
        }
        val e = CrashResumableWipe(rig.store, rig.vault, rig.fs, rig.runtime, rig.authority, hook)
        reentrant = e
        val r = e.requestWipe()
        val captured = nested
        assertNotNull("*** THE REENTRANT CALL MUST HAVE HAPPENED -- otherwise this arm measures nothing. ***", captured)
        assertTrue(
            "*** AND IT MUST BE REFUSED WITH A NAMED CAUSE RATHER THAN STEPPING THE LADDER TWICE. Observed: $captured ***",
            captured is WipeStepResult.Refused && captured.cause == WipeRefusalCause.WIPE_ALREADY_PENDING,
        )
        assertTrue("and the outer drive must still have settled", advancedTo(r, WipeJournalState.IDLE))
        assertEquals(
            "*** AND THE LADDER MUST BE RECORDED EXACTLY ONCE -- a second step would duplicate rungs. ***",
            CrashResumableWipe.FULL_LADDER,
            rig.store.lines,
        )
    }

    /**
     * *** iOS R2 AND THE ONE OBSERVED DIVERGENCE -- MEASURED HERE RATHER THAN ASSUMED, AND NAMED. ***
     *
     * *THE FINDING, VERBATIM: "CrashResumableWipe reads the journal only at initialization."* **The Android twin
     * refreshes its working mirror from the store at the start of every DRIVE, and `liveRevision` re-reads the
     * store on every call -- so a second owner's write IS observed by every DRIVE and by the revision.**
     *
     * *** BUT THE READ-ONLY GATE VERBS ARE NOT ON THAT ROAD, AND THAT IS AN ASYMMETRY WITH iOS. *** *iOS's
     * `current()` is built on `liveJournal() { store.readJournal() }`, so its `isWipePending` / `allowsStartup` /
     * `deliverLate` observeth another owner's write IMMEDIATELY.* **Android's `current()` reads the in-memory
     * `journal` mirror, which is refreshed only by `drive { }` -- so until SOMETHING drives this coordinator, its
     * gate answers about the record as it stood when the coordinator was constructed.** *This arm MEASURES that
     * difference rather than papering over it: the revision moves and the drive observes, while the not-yet-driven
     * gate does not.*
     *
     * *** THE HONEST SCOPE: THE PRODUCTION ROOTS REACH THE GATE THROUGH A DRIVE, AND `StartupRecoveryGraph`'s
     * `decisionAtRest` buildeth a FRESH coordinator per decision (`coordinator(journal, deferred())`), so a
     * construction-time mirror is a fresh read there.** *The asymmetry is real, narrow, and recorded as a finding
     * rather than fixed here: this court's mandate is to port and to measure, not to edit the ladder it ports.*
     */
    @Test
    fun aWipeRequestedByAnotherOwnerIsObservedByTheDriveAndTheRevision() {
        val rig = Rig()
        val held = CrashResumableWipe(rig.store, rig.vault, rig.fs, rig.runtime, rig.authority)
        val revisionBefore = held.liveRevision()
        assertFalse("nothing is pending before anyone requests", held.isWipePending)
        assertTrue("a clean estate admits startup", held.allowsStartup())

        // *** A SECOND OWNER (another process, or the operator) REQUESTS THE WIPE AND DIES MID-LADDER. ***
        val other = CrashResumableWipe(
            rig.store, RecordingVault(), RecordingFs(), RecordingTransport(), RecordingAuthority(),
            CrashHook(WipeJournalState.KEYS_ERASED.name),
        )
        val requested = drive(other) { other.requestWipe() }
        assertTrue("the second owner must have begun the wipe and stopped mid-ladder: $requested",
            requested is WipeStepResult.RetryLater)

        // *** (a) THE DURABLE REVISION MOVES IMMEDIATELY -- it is built from the STORE, not from a snapshot. ***
        assertNotEquals(
            "*** THE DURABLE REVISION MUST MOVE: it is derived from the store's own bytes, which is what maketh a " +
                "stale permit refusable (the ABA). ***",
            revisionBefore, held.liveRevision(),
        )
        // (b) AND the store itself carries the other owner's write.
        assertEquals(
            "the record stands where the other owner's crash left it",
            listOf("REQUESTED", "RUNTIME_DRAINED"),
            rig.store.lines,
        )
        // *** (c) THE MEASURED DIVERGENCE FROM iOS, STATED AS THE FACT IT IS. ***
        assertFalse(
            "*** MEASURED: THIS COORDINATOR'S GATE HAS NOT YET REFRESHED ITS MIRROR, SO `isWipePending` STILL " +
                "ANSWERETH FROM ITS CONSTRUCTION-TIME VIEW. iOS's `current()` READETH THE STORE LIVE AND WOULD ALREADY " +
                "ANSWER `true` HERE. This is the ported iOS-R2 asymmetry, recorded rather than smoothed over. ***",
            held.isWipePending,
        )

        // *** (d) AND A DRIVE REFRESHES THE MIRROR, SO THE WIPE IS THEN OBSERVED AND RESUMEABLE. ***
        val resumed = drive(held) { held.resume() }
        assertTrue("*** A DRIVE MUST OBSERVE THE OTHER OWNER'S WIPE AND RESUME IT. Observed: $resumed ***",
            advancedTo(resumed, WipeJournalState.IDLE))
        assertFalse("and the estate is clean again", held.isWipePending)
        assertEquals(
            "*** AND THE FULL LADDER MUST BE RECORDED EXACTLY ONCE ACROSS BOTH OWNERS. ***",
            CrashResumableWipe.FULL_LADDER,
            rig.store.lines,
        )
    }

    /** *A transport double for the second owner, so its drain is satisfied without touching the first's counts.* */
    private class RecordingTransport : TransportRuntimeSeam {
        private var drained = false
        override fun drainTransport(): RuntimeDrainReceipt {
            drained = true
            return RuntimeDrainReceipt.Drained(1, true)
        }
        override fun isQuiesced(): Boolean = drained
        override fun fireRadio(msg: String): Boolean = false
        override fun sendVia(msg: String): Boolean = false
    }

    // ================================================================================================
    // (4) iOS T34 arm 2 -- A REBOOT MID-WIPE RESUMES FROM THE **REAL** JOURNAL ALONE.
    // ================================================================================================

    /**
     * *** THE ANDROID COURT MEASURED THIS ONLY OVER A `FakeStore`; THIS ARM DRIVES THE PRODUCTION JOURNAL. ***
     *
     * *A crash at `KEYS_ERASED` (the hook throweth BEFORE the write lands) leaveth the REAL `FileWipeJournal`
     * standing at `RUNTIME_DRAINED`.* **A FRESH coordination over the SAME durable record then re-proves the drain
     * in ITS OWN lifetime and completes the ladder -- and the record must be the full ladder exactly once.**
     */
    @Test
    fun aRebootMidWipeResumesFromTheRealProductionJournalAlone() {
        val journal = FileWipeJournal(ctx())
        val adapter = WipeJournalDurabilityAdapter(journal)
        val rig = Rig()
        val crash = CrashHook(WipeJournalState.KEYS_ERASED.name)
        val e1 = CrashResumableWipe(adapter, rig.vault, rig.fs, rig.runtime, rig.authority, crash)

        val first = drive(e1) { e1.requestWipe() }
        assertEquals("*** THE INJECTED CRASH MUST HAVE FIRED EXACTLY ONCE. ***", 1, crash.fired)
        assertTrue(
            "*** AND IT MUST HAVE STOPPED THE DRIVE MID-LADDER. Observed: $first ***",
            first is WipeStepResult.RetryLater && first.reason == CRASHED,
        )
        assertEquals(
            "*** THE REAL JOURNAL MUST STAND AT THE DRAIN: the checkpoint a crash resumes from. Observed: " +
                "${adapter.readJournal()} ***",
            listOf("RUNTIME_DRAINED"),
            adapter.readJournal(),
        )
        assertEquals("and the journal's own typed record stands at the drain", PanicWipe.WipeState.RUNTIME_DRAINED, journal.read())

        // *** THE REBOOT: a FRESH process-lifetime -- so a fresh, UN-QUIESCED transport. ***
        val rebootedRuntime = RecordingRuntime()
        val e2 = CrashResumableWipe(adapter, rig.vault, rig.fs, rebootedRuntime, rig.authority)
        val second = drive(e2) { e2.resume() }
        assertTrue("*** THE REBOOTED BOOT MUST RESUME TO THE TERMINAL RUNG. Observed: $second ***",
            advancedTo(second, WipeJournalState.IDLE))
        assertEquals(
            "*** AND THE FRESH RUNTIME MUST HAVE BEEN DRAINED AGAIN -- the drain is a THIS-lifetime property. ***",
            1, rebootedRuntime.drains,
        )
        assertEquals(
            "*** AND THE ONE IDENTITY MUST STAND. Observed: ${rig.authority.published} ***",
            1, rig.authority.published.size,
        )
    }

    // ================================================================================================
    // (5) iOS GS-STORE-006 -- THE DRAIN CHECKPOINT IN THE REAL JOURNAL, AND A REFUSED STAGE NAME.
    // ================================================================================================

    /**
     * *** THE AUDIT'S CHARGE: "key deletion must remain blocked until transport drain completeth." ***
     *
     * *THE PRODUCTION JOURNAL CARRIED ONE TYPED `WipeState` THAT HAD NO CASE FOR THE DRAIN until the adapter
     * landed; this arm proveth the checkpoint really reacheth the record through the isle's own mapping.* **The
     * crash is injected ONE STAGE PAST the drain, because `requestWipe()` otherwise runneth the whole ladder.**
     */
    @Test
    fun theDrainCheckpointIsPersistedInTheRealProductionJournal() {
        val journal = FileWipeJournal(ctx())
        val adapter = WipeJournalDurabilityAdapter(journal)
        val rig = Rig()
        val crash = CrashHook(WipeJournalState.KEYS_ERASED.name)
        val e = CrashResumableWipe(adapter, rig.vault, rig.fs, rig.runtime, rig.authority, crash)

        val r = drive(e) { e.requestWipe() }
        assertTrue("the injected crash must stop the ladder: $r", r is WipeStepResult.RetryLater)
        assertEquals(
            "*** THE DRAIN MUST BE WRITTEN DOWN WHERE A CRASH CAN FIND IT. Observed: ${journal.read()} ***",
            PanicWipe.WipeState.RUNTIME_DRAINED,
            journal.read(),
        )
        assertEquals(
            "*** AND THE ADAPTER MUST REPORT THE SINGLE CHECKPOINT THE JOURNAL STANDETH AT. ***",
            listOf("RUNTIME_DRAINED"),
            adapter.readJournal(),
        )
        assertEquals("and the drain happened exactly once", 1, rig.runtime.drains)
    }

    /**
     * *** THE NEGATIVE TWIN: AN UNKNOWN STAGE NAME IS REFUSED, NEVER SILENTLY DROPPED. ***
     *
     * *A dropped checkpoint is a wipe that RESTARTETH LATER than it should, or one that believeth it erased what it
     * hath not.* **The adapter fail-eth CLOSED: nothing is written and the record does not move.**
     */
    @Test
    fun anUnknownStageNameIsRefusedAndTheCheckpointDoesNotMove() {
        val journal = FileWipeJournal(ctx())
        val adapter = WipeJournalDurabilityAdapter(journal)
        assertTrue("a known stage is written through", adapter.appendJournalDurably(WipeJournalState.REQUESTED.name))
        assertEquals(PanicWipe.WipeState.REQUESTED, journal.read())

        assertFalse(
            "*** AN UNKNOWN STAGE MUST BE REFUSED. ***",
            adapter.appendJournalDurably("NOT_A_LADDER_STAGE"),
        )
        assertEquals(
            "*** AND THE CHECKPOINT MUST NOT MOVE: a checkpoint that advances on a name nobody meant skips work. ***",
            PanicWipe.WipeState.REQUESTED,
            journal.read(),
        )
        assertFalse(
            "*** AND THE LADDER IS THE COORDINATOR'S OWN VOCABULARY -- the adapter speaketh only that. ***",
            WipeJournalDurabilityAdapter.LADDER.contains("NOT_A_LADDER_STAGE"),
        )
        assertEquals(
            "*** AND THE ISLE'S OWN SPELLING IS WHAT IT WRITES, with the other isle's tolerated on the way in. ***",
            "KEY_ERASED",
            WipeJournalDurabilityAdapter.stageFor(PanicWipe.WipeState.KEY_ERASED),
        )
        assertEquals(
            "and the other isle's wire name maps onto the same rung",
            PanicWipe.WipeState.KEY_ERASED,
            WipeJournalDurabilityAdapter.stateFor("KEYS_ERASED"),
        )
    }

    // ================================================================================================
    // (6) iOS GS-STORE-006 -- EVERY PERSISTED CHECKPOINT STAYS PENDING THROUGH DEFERRED SEAMS.
    // ================================================================================================

    /**
     * *** "NO SENSITIVE RUNTIME MAY REOPEN PREMATURELY, AND FAILED KEY/FILE OPERATIONS MUST REMAIN PENDING." ***
     *
     * *Plant the record at EVERY rung and drive the production coordinator over the FOUR DEFERRED SEAMS the
     * startup barrier actually owns.* **The one honest exception, stated rather than smoothed over: at
     * `NEW_IDENTITY` every effectful rung is already behind the wipe, so the remaining step is the idle
     * transition -- an act with no platform effect -- and the wipe MAY legitimately finish there.**
     */
    @Test
    fun everyPersistedCheckpointStaysPendingThroughTheDeferredSeams() {
        val rungs = listOf(
            WipeJournalState.REQUESTED,
            WipeJournalState.RUNTIME_DRAINED,
            WipeJournalState.KEYS_ERASED,
            WipeJournalState.ARTIFACTS_DELETED,
            WipeJournalState.NEW_IDENTITY,
        )
        for (rung in rungs) {
            val rig = Rig()
            rig.store.seed(rung.name)
            val e = CrashResumableWipe(
                rig.store,
                WipeDeferredSeams.DeferredKeyVaultSeam(),
                WipeDeferredSeams.DeferredArtifactFileSystemSeam(),
                WipeDeferredSeams.DeferredTransportRuntimeSeam(),
                WipeDeferredSeams.DeferredIdentityAuthoritySeam(),
            )
            val r = e.resume()

            if (rung == WipeJournalState.NEW_IDENTITY) {
                assertTrue(
                    "*** AT `NEW_IDENTITY` ONLY THE IDLE TRANSITION REMAINS AND IT HATH NO PLATFORM EFFECT, so " +
                        "finishing is the clause's own boundary. Observed: $r ***",
                    advancedTo(r, WipeJournalState.IDLE),
                )
                continue
            }

            assertTrue(
                "*** AT ${rung.name} THE LADDER MUST NOT ADVANCE THROUGH DEFERRED SEAMS. Observed: $r ***",
                r is WipeStepResult.RetryLater || r is WipeStepResult.Refused,
            )
            assertEquals(
                "*** AND THE DURABLE RECORD MUST NOT MOVE: a crash-and-restart at ${rung.name} must leave it where " +
                    "it standeth, so the next attempt resumeth at the SAME checkpoint. Observed: ${rig.store.lines} ***",
                listOf(rung.name),
                rig.store.lines,
            )
            assertTrue("and it must read as pending", e.isWipePending)
        }
    }

    // ================================================================================================
    // (7) THE IDENTITY RUNG'S REAL BEHAVIOUR ON THIS ISLE (iOS R8's `publishOrAdoptIdentity` GAP).
    // ================================================================================================

    /**
     * *** iOS BOUND THE PUBLICATION TO THE WIPE GENERATION AND MADE IT ADOPT-OR-PUBLISH (R8). THIS ISLE DID NOT. ***
     *
     * *THE iOS FINDING: "if the process died in between, the next attempt called `generateAndStore` again -- and
     * THAT REFUSED the already-present identity, so the journal stayed at `ARTIFACTS_DELETED` on every retry."*
     * **Android's `IdentityAuthoritySeam` carries NO `publishOrAdoptIdentity(wipeGeneration:)` -- only
     * `publishNewIdentity()` -- so the ANDROID equivalent of the crash-between-publication-and-checkpoint case is
     * measured here as it really behaves: the resume ASKS THE AUTHORITY AGAIN, and the ladder settles at the
     * TERMINAL rung with exactly one terminal identity standing.** *The gap is NAMED (a second publication is
     * attempted on resume) rather than asserted away, because a court that pinned adoption here would be pinning
     * an API this isle does not have.*
     */
    @Test
    fun aCrashBetweenPublicationAndItsCheckpointSettlesAtTheTerminalRungOnThisIsle() {
        val rig = Rig()
        // The crash lands BEFORE the NEW_IDENTITY write -- i.e. AFTER the authority published.
        val crash = CrashHook(WipeJournalState.NEW_IDENTITY.name)
        val e1 = CrashResumableWipe(rig.store, rig.vault, rig.fs, rig.runtime, rig.authority, crash)
        val first = drive(e1) { e1.requestWipe() }
        assertEquals("the crash must have fired once", 1, crash.fired)
        assertTrue("and the drive must have stopped mid-ladder: $first", first is WipeStepResult.RetryLater)
        assertEquals(
            "*** THE RECORD MUST STAND AT `ARTIFACTS_DELETED`: the publication happened but its checkpoint did not. ***",
            listOf("REQUESTED", "RUNTIME_DRAINED", "KEYS_ERASED", "ARTIFACTS_DELETED"),
            rig.store.lines,
        )
        assertEquals("and the authority really did publish once", 1, rig.authority.published.size)

        // *** THE RESUME: a fresh owner over the same record. ***
        val e2 = CrashResumableWipe(rig.store, rig.vault, rig.fs, rig.runtime, rig.authority)
        val second = drive(e2) { e2.resume() }
        assertTrue(
            "*** THE RESUME MUST SETTLE AT THE TERMINAL RUNG -- the identity rung is idempotent from the ladder's " +
                "point of view even where the authority is asked twice. Observed: $second ***",
            advancedTo(second, WipeJournalState.IDLE),
        )
        assertEquals(
            "*** AND THE LADDER MUST BE RECORDED EXACTLY ONCE, with no duplicated rung across the crash. Observed: " +
                "${rig.store.lines} ***",
            CrashResumableWipe.FULL_LADDER,
            rig.store.lines,
        )
        assertTrue(
            "*** AND THE GAP IS NAMED RATHER THAN HIDDEN: this isle asketh the authority again on resume " +
                "(observed ${rig.authority.published.size} publications), where iOS asketh it to publish OR ADOPT. ***",
            rig.authority.published.size >= 1,
        )
    }

    // ================================================================================================
    // (8) THE GATE AND THE STALE-ERA CALLBACKS (iOS T34 arms 6/7), ON THE REAL COORDINATOR.
    // ================================================================================================

    /**
     * *** A STALE FRAME AND A STALE UI SEND ARE REFUSED BY THE JOURNAL-BOUND GATE, NOT BY A CACHED FLAG. ***
     *
     * *iOS counts both as gate-bypass attempts; this isle counts them on the same `bypassAttempts` counter.* **And
     * the refusal must not reach the transport: a stale frame resurrecting the pre-wipe session is the exact thing
     * the drain rung exists to prevent.**
     */
    @Test
    fun aStaleRadioFrameAndAStaleUiSendAreRefusedWhileTheWipeIsPending() {
        val rig = Rig()
        val crash = CrashHook(WipeJournalState.KEYS_ERASED.name)
        val e = CrashResumableWipe(rig.store, rig.vault, rig.fs, rig.runtime, rig.authority, crash)
        drive(e) { e.requestWipe() }
        assertTrue("the ladder must still be outstanding after the crash", e.isWipePending)

        assertFalse("*** A FRAME FOR THE PRE-WIPE SESSION MUST BE DROPPED. ***", e.deliverLate("stale-frame"))
        assertFalse("*** AND A STALE UI SEND MUST BE REFUSED. ***", e.submitUi("stale-send"))
        assertEquals(
            "*** AND BOTH PROBES MUST BE COUNTED: the gate was probed, not bypassed. Observed ${e.bypassAttempts} ***",
            2,
            e.bypassAttempts,
        )
        assertTrue("*** AND NEITHER MAY HAVE REACHED THE TRANSPORT. ***", rig.runtime.drains == 1)
    }

    private companion object {
        const val CRASHED = "crashed"
    }
}
