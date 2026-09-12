package io.godstone.mesh.readiness

import io.godstone.mesh.identity.ArtifactFileSystemSeam
import io.godstone.mesh.identity.CrashResumableWipe
import io.godstone.mesh.identity.FileDeletionResult
import io.godstone.mesh.identity.IdentityAuthoritySeam
import io.godstone.mesh.identity.KeyDeletionResult
import io.godstone.mesh.identity.KeyVaultSeam
import io.godstone.mesh.identity.RuntimeDrainReceipt
import io.godstone.mesh.identity.TransportRuntimeSeam
import io.godstone.mesh.identity.WipeCrashException
import io.godstone.mesh.identity.WipeDurabilityStore
import io.godstone.mesh.identity.WipeHooks
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeScope
import io.godstone.mesh.identity.WipeStepResult
import org.junit.Assert
import org.junit.Test

/**
 * T34 readiness court (android isle): the crash-resumable wipe ladder across
 * transport and storage. Drives the injected seams with deterministic fakes and
 * a crash hook that throws BEFORE a journal write lands, so each required
 * boundary is exercised the way the card names: crash at every journal boundary,
 * key deletion failure, database file busy, late radio callback, stale UI send,
 * reboot mid-wipe, old files unreadable after key erasure.
 */
public class ReadinessT34Test {

    // ---- durable store: append-only journal lines --------------------------------------
    private class FakeStore : WipeDurabilityStore {
        val lines = mutableListOf<String>()
        override fun readJournal(): List<String> = lines.toMutableList()
        override fun appendJournal(stateName: String) { lines.add(stateName) }
    }

    // ---- key vault: scripted failures; absent keys are satisfied -----------------------
    private class FakeVault : KeyVaultSeam {
        val alive = WipeScope.PRIVATE_KEYS.toMutableList()
        val failedOnce = mutableSetOf<String>()          // retryable, then succeeds
        val permanent = mutableSetOf<String>()            // non-retryable
        val eraseCalls = mutableMapOf<String, Int>()
        override fun eraseKey(name: String): KeyDeletionResult {
            eraseCalls[name] = (eraseCalls[name] ?: 0) + 1
            if (!alive.contains(name)) return KeyDeletionResult.Absent
            if (name in permanent) return KeyDeletionResult.Failed(name, false, "keystore entry stuck")
            if (name in failedOnce) { failedOnce.remove(name); return KeyDeletionResult.Failed(name, true, "transient") }
            alive.remove(name)
            return KeyDeletionResult.Deleted
        }
    }

    // ---- file system: busy scripting; readable iff some key still lives ---------------
    private class FakeFs(private val vault: FakeVault) : ArtifactFileSystemSeam {
        val files = mutableMapOf<String, Boolean>()
        val busyOnce = mutableSetOf<String>()
        val deleteCalls = mutableMapOf<String, Int>()
        override fun deleteArtifact(path: String): FileDeletionResult {
            deleteCalls[path] = (deleteCalls[path] ?: 0) + 1
            if (path in busyOnce) { busyOnce.remove(path); return FileDeletionResult.Failed(path, "database file busy") }
            if (files[path] != true) return FileDeletionResult.Absent
            files[path] = false
            return FileDeletionResult.Deleted
        }
        override fun exists(path: String): Boolean = files[path] == true
        override fun isReadable(path: String): Boolean = files[path] == true && vault.alive.isNotEmpty()
    }

    // ---- transport: drain proof + quiesced radio ---------------------------------------
    private class FakeRuntime : TransportRuntimeSeam {
        var quiesced = false
        var drainCalls = 0
        val delivered = mutableListOf<String>()
        val sends = mutableListOf<String>()
        override fun drainTransport(): RuntimeDrainReceipt {
            drainCalls += 1
            quiesced = true
            return RuntimeDrainReceipt.Drained(3, true)
        }
        override fun isQuiesced(): Boolean = quiesced
        override fun fireRadio(msg: String): Boolean { if (!quiesced) return false; delivered.add(msg); return true }
        override fun sendVia(msg: String): Boolean { if (!quiesced) return false; sends.add(msg); return true }
    }

    // ---- identity authority: one publication per completed wipe ------------------------
    private class FakeAuthority : IdentityAuthoritySeam {
        var current: String? = null
        val published = mutableListOf<String>()
        override fun publishNewIdentity(): String { val id = "node-${published.size + 1}"; published.add(id); current = id; return id }
        override fun identity(): String? = current
    }

    // ---- crash hook: throws BEFORE the named state is written --------------------------
    private class CrashHook(var crashBefore: String? = null) : WipeHooks {
        var crashes = 0
        override fun beforeWrite(stateName: String) {
            if (crashBefore != null && stateName == crashBefore) { crashBefore = null; crashes += 1; throw WipeCrashException("power loss at $stateName") }
        }
    }

    private class Rig(crashBefore: String? = null) {
        val store = FakeStore()
        val vault = FakeVault()
        val fs = FakeFs(vault)
        val runtime = FakeRuntime()
        val authority = FakeAuthority()
        val hook = CrashHook(crashBefore)
        fun engine(): CrashResumableWipe = CrashResumableWipe(store, vault, fs, runtime, authority, hook)
        init {
            for (p in WipeScope.PRIVATE_ARTIFACTS) fs.files[p] = true
            fs.files["accepted-archive/model.bin"] = true   // approved public asset: must NEVER be touched
            fs.files["accepted-archive/voices.bin"] = true
        }
    }

    /** Drive the engine to a terminal state, swallowing the injected crash exactly once. */
    private fun driveToTerminal(engine: CrashResumableWipe, first: () -> WipeStepResult): WipeStepResult {
        var r = try { first() } catch (_e: WipeCrashException) { return WipeStepResult.RetryLater(WipeJournalState.REQUESTED, "crashed") }
        var guard = 0
        while (r is WipeStepResult.RetryLater && r.reason != "crashed" && guard < 32) {
            guard += 1
            r = try { engine.step() } catch (_e: WipeCrashException) { return WipeStepResult.RetryLater(WipeJournalState.REQUESTED, "crashed") }
        }
        return r
    }

    // (1) crash at every journal boundary: resume lands the FULL monotone ladder exactly once
    @Test
    fun testCrashAtEveryJournalBoundaryResumesToIdle() {
        for (boundary in CrashResumableWipe.FULL_LADDER) {
            val rig = Rig(crashBefore = boundary)
            val e1 = rig.engine()
            val r1 = driveToTerminal(e1) { e1.requestWipe() }
            Assert.assertTrue("the crash boundary $boundary really fired", rig.hook.crashes == 1)
            val crashed = r1 is WipeStepResult.RetryLater && r1.reason == "crashed"
            Assert.assertTrue("the run stopped at the crash of $boundary", crashed)
            val e2 = rig.engine()                                   // fresh instance -- no memory carried
            var r2 = driveToTerminal(e2) { e2.resume() }
            if (rig.store.lines.isEmpty()) {
                // crashed BEFORE the first write: the request itself never landed, so a re-request is the honest restart
                Assert.assertTrue("nothing was journaled before the first write", e2.resume() is WipeStepResult.Refused)
                r2 = driveToTerminal(e2) { e2.requestWipe() }
            }
            Assert.assertTrue("resume from the $boundary crash reaches IDLE", r2 is WipeStepResult.Advanced && r2.to == WipeJournalState.IDLE)
            Assert.assertSame("the journal is exactly the ladder once", CrashResumableWipe.FULL_LADDER.size, rig.store.lines.size)
            Assert.assertEquals("the journal records the full ladder", CrashResumableWipe.FULL_LADDER.map { WipeJournalState.fromWire(it) }, e2.journalView())
            Assert.assertTrue("ranks strictly increase", e2.journalView().map { it!!.rank } == listOf(1, 2, 3, 4, 5, 6))
        }
    }

    // (2) reboot mid-wipe: a fresh runtime is drained again; the journal alone drives progress
    @Test
    fun testRebootMidWipeResumesFromJournalAlone() {
        val rig = Rig(crashBefore = WipeJournalState.KEYS_ERASED.name)   // die after the drain was journaled, before erasure
        val e1 = rig.engine()
        driveToTerminal(e1) { e1.requestWipe() }
        Assert.assertEquals("the journal holds REQUESTED and RUNTIME_DRAINED", listOf("REQUESTED", "RUNTIME_DRAINED"), rig.store.lines)
        val freshRuntime = FakeRuntime()                                  // the process rebooted: volatile runtime gone
        val rebooted = CrashResumableWipe(rig.store, rig.vault, rig.fs, freshRuntime, rig.authority, rig.hook)
        val r = driveToTerminal(rebooted) { rebooted.resume() }
        Assert.assertTrue("the rebooted boot resumes to IDLE", r is WipeStepResult.Advanced && r.to == WipeJournalState.IDLE)
        Assert.assertTrue("the fresh runtime was drained again (idempotent drain)", freshRuntime.drainCalls == 1)
        Assert.assertEquals("no duplicate journal writes across the reboot", CrashResumableWipe.FULL_LADDER, rig.store.lines)
    }

    // (3) retryable key deletion failure blocks the erase until it clears
    @Test
    fun testFailedKeyDeletionRetriesDurablyBeforeErase() {
        val rig = Rig()
        rig.vault.failedOnce.add("identity-x25519")
        val e = rig.engine()
        val first = e.requestWipe()
        Assert.assertTrue("the ladder parks at RUNTIME_DRAINED while a key erasure is pending", first is WipeStepResult.RetryLater && first.at == WipeJournalState.RUNTIME_DRAINED)
        Assert.assertEquals("KEYS_ERASED was NOT written while a key still lived", listOf("REQUESTED", "RUNTIME_DRAINED"), rig.store.lines)
        Assert.assertTrue("the gate stays closed across the retry", !e.allowsStartup())
        val second = e.step()
        Assert.assertTrue("after the retry clears, the erasure lands", second is WipeStepResult.Advanced && second.to == WipeJournalState.IDLE)
        Assert.assertTrue("the flaky key was attempted exactly twice", (rig.vault.eraseCalls["identity-x25519"] ?: 0) == 2)
    }

    // (4) permanent key failure refuses the wipe: no artifacts deleted, no new runtime
    @Test
    fun testPermanentKeyDeletionFailureRefusesAndKeepsArtifactsAndNoNewRuntime() {
        val rig = Rig()
        rig.vault.permanent.add("store-dek")
        val e = rig.engine()
        val r = e.requestWipe()
        Assert.assertTrue("a non-retryable key failure REFUSES", r is WipeStepResult.Refused)
        Assert.assertEquals("the journal never advances past the drain", listOf("REQUESTED", "RUNTIME_DRAINED"), rig.store.lines)
        Assert.assertTrue("the database file is NOT deleted while its key lives", rig.fs.exists("mesh.db"))
        Assert.assertTrue("no new identity was constructed on a refused wipe", rig.authority.published.isEmpty())
        Assert.assertTrue("the gate remains closed -- a refused wipe is retried, not bypassed", !e.allowsStartup())
    }

    // (5) busy database file is retryable; an already-absent copy is satisfaction, not failure
    @Test
    fun testBusyDatabaseFileIsRetriedAbsentIsNotFailure() {
        val rig = Rig()
        rig.fs.busyOnce.add("mesh.db")
        rig.fs.files["mesh.db-shm"] = false                              // a copy already removed by a former run
        val e = rig.engine()
        val first = e.requestWipe()
        Assert.assertTrue("the busy db parks the ladder at KEYS_ERASED", first is WipeStepResult.RetryLater && first.at == WipeJournalState.KEYS_ERASED)
        Assert.assertTrue("the stall names the busy copy as the sole failure", (first as WipeStepResult.RetryLater).reason.contains("mesh.db") && !first.reason.contains("shm"))
        Assert.assertEquals("ARTIFACTS_DELETED was NOT written while the db was busy", listOf("REQUESTED", "RUNTIME_DRAINED", "KEYS_ERASED"), rig.store.lines)
        val second = e.step()
        Assert.assertTrue("after the busy flag clears, cleanup lands", second is WipeStepResult.Advanced && second.to == WipeJournalState.IDLE)
        Assert.assertTrue("the busy db was attempted exactly twice", (rig.fs.deleteCalls["mesh.db"] ?: 0) == 2)
        Assert.assertTrue("the already-absent shm was treated as satisfied (never a stall cause) yet re-enumerated idempotently", (rig.fs.deleteCalls["mesh.db-shm"] ?: 0) >= 1)
    }

    // (6) a late radio callback while the ladder is pending is dropped, never delivered to the pre-wipe session
    @Test
    fun testLateRadioCallbackAfterDrainIsDropped() {
        val rig = Rig(crashBefore = WipeJournalState.KEYS_ERASED.name)    // die after the drain, mid-ladder: pending holds
        val e = rig.engine()
        driveToTerminal(e) { e.requestWipe() }
        Assert.assertTrue("the ladder is still outstanding after the crash", !e.allowsStartup())
        val before = rig.runtime.delivered.size
        Assert.assertFalse("a frame for the pre-wipe session is dropped while the wipe is pending", e.deliverLate("stale-frame"))
        Assert.assertSame("the delivered queue did not grow", before, rig.runtime.delivered.size)
        Assert.assertTrue("the drop was counted as a gate-bypass attempt", e.bypassAttempts == 1)
        // after the wipe completes, the quiesced transport legitimately delivers on the new era
        val r2 = driveToTerminal(e) { e.step() }
        Assert.assertTrue("the ladder completes", r2 is WipeStepResult.Advanced && r2.to == WipeJournalState.IDLE)
        Assert.assertTrue("post-completion a fresh frame is delivered", e.deliverLate("fresh-frame"))
        Assert.assertEquals("exactly the fresh frame reached the transport", listOf("fresh-frame"), rig.runtime.delivered)
    }

    // (7) a stale UI send while the wipe is pending is refused by the gate
    @Test
    fun testStaleUiSendWhilePendingIsRefused() {
        val rig = Rig()
        val e = rig.engine()
        val r1 = e.requestWipe()
        Assert.assertTrue("the ladder advanced past REQUESTED", r1 is WipeStepResult.Advanced && r1.to == WipeJournalState.IDLE)
        // re-arm a fresh pending wipe and try to sneak a UI send through mid-ladder
        val rig2 = Rig(crashBefore = WipeJournalState.KEYS_ERASED.name)
        val e2 = rig2.engine()
        driveToTerminal(e2) { e2.requestWipe() }
        Assert.assertFalse("a UI send while a wipe is outstanding is REFUSED", e2.submitUi("stale-send"))
        Assert.assertTrue("the refused send never reached the transport", rig2.runtime.sends.isEmpty())
        Assert.assertTrue("the gate refused rather than allowed a bypass", !e2.allowsStartup() && e2.bypassAttempts == 1)
        // and after completion the UI may send again on the new identity
        val e3 = rig2.engine()
        driveToTerminal(e3) { e3.resume() }
        Assert.assertTrue("post-completion a fresh send is admitted", e3.submitUi("fresh-send"))
        Assert.assertEquals("the transport took exactly the fresh frame", listOf("fresh-send"), rig2.runtime.sends)
    }

    // (8) old ciphertext is unreadable once the keys are gone -- and public assets survive scoping
    @Test
    fun testOldCiphertextUnreadableAfterKeyErasureAndPublicAssetsSurvive() {
        val rig = Rig(crashBefore = WipeJournalState.KEYS_ERASED.name) // die right after the erasure succeeded, before its journaling
        val e = rig.engine()
        driveToTerminal(e) { e.requestWipe() }
        Assert.assertEquals("the journal still sits at the drain: the erasure was not yet journaled", listOf("REQUESTED", "RUNTIME_DRAINED"), rig.store.lines)
        Assert.assertTrue("every private key is gone from the vault", rig.vault.alive.isEmpty())
        for (p in WipeScope.PRIVATE_ARTIFACTS) {
            Assert.assertTrue("the ciphertext $p still EXISTS on flash (best-effort deletion has not run)", rig.fs.exists(p))
            Assert.assertFalse("yet it is UNREADABLE: the keys were erased BEFORE any file cleanup", rig.fs.isReadable(p))
        }
        val e2 = rig.engine()
        val r2 = driveToTerminal(e2) { e2.resume() }
        Assert.assertTrue("resume re-proves the idempotent erasure and completes the ladder", r2 is WipeStepResult.Advanced && r2.to == WipeJournalState.IDLE)
        for (p in WipeScope.PRIVATE_ARTIFACTS) Assert.assertFalse("after resume the copy $p is gone", rig.fs.exists(p))
        Assert.assertTrue("the approved public Archive asset was never touched (no glob delete)", rig.fs.exists("accepted-archive/model.bin"))
        Assert.assertTrue("the second public asset survived too", rig.fs.exists("accepted-archive/voices.bin"))
        Assert.assertTrue("deletions were scoped to the enumerated private artifacts only", rig.fs.deleteCalls.keys.all { WipeScope.PRIVATE_ARTIFACTS.contains(it) })
    }

    // (9) journal compatibility: legacy spellings map; unknown future versions refuse fail-closed
    @Test
    fun testLegacyJournalHonoredAndUnsupportedVersionRefused() {
        val rig = Rig()
        rig.store.lines.add("REQUESTED")
        rig.store.lines.add("RUNTIME_DRAINED")
        rig.store.lines.add("KEY_ERASED")            // the sealed ladder's legacy spelling for KEYS_ERASED
        val e = rig.engine()
        Assert.assertTrue("a legacy-spelled journal parses", e.isSupportedJournal())
        val r = driveToTerminal(e) { e.resume() }
        Assert.assertTrue("the legacy journal resumes to completion", r is WipeStepResult.Advanced && r.to == WipeJournalState.IDLE)
        Assert.assertTrue("the normalized view names the canonical state", e.journalView()[2] == WipeJournalState.KEYS_ERASED)
        // an unknown future state must be refused, never guessed
        val rig2 = Rig()
        rig2.store.lines.add("REQUESTED")
        rig2.store.lines.add("WATERS_DOWN")          // a future/unknown version line
        val e2 = rig2.engine()
        Assert.assertFalse("an unsupported journal is not well-formed", e2.isSupportedJournal())
        val r2 = e2.resume()
        Assert.assertTrue("resume REFUSES an unsupported journal fail-closed", r2 is WipeStepResult.Refused)
        Assert.assertEquals("nothing was appended to the unsupported journal", 2, rig2.store.lines.size)
    }
}
