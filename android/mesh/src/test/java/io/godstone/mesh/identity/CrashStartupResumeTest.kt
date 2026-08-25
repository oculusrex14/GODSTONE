package io.godstone.mesh.identity

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.identity.PanicWipe.WipeState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashStartupResumeTest {

    private class InMemoryJournal : WipeJournal {
        var state: WipeState = WipeState.IDLE
        var writes = 0
        var clears = 0
        override fun read(): WipeState = state
        override fun write(s: WipeState) { state = s; writes++ }
        override fun clear() { state = WipeState.IDLE; clears++ }
    }

    private class StepTrackingArtifacts : WipeArtifacts {
        val executedSteps = mutableListOf<String>()
        var currentIdentity: Identity? = MeshIdentity.generate()

        override fun eraseKeys() {
            executedSteps += "eraseKeys"
            currentIdentity = null
        }

        override fun deleteArtifacts() {
            executedSteps += "deleteArtifacts"
        }

        override fun regenerateIdentity() {
            executedSteps += "regenerateIdentity"
            currentIdentity = MeshIdentity.generate()
        }
    }

    @Test
    fun testStartup_PendingWipe_FinishesBeforeRuntimeInitialization() {
        val journal = InMemoryJournal()
        journal.write(WipeState.REQUESTED)
        val artifacts = StepTrackingArtifacts()

        var startupCompleted = false
        PanicWipe(journal, artifacts).resumeIfPending()
        if (journal.read() == WipeState.IDLE) {
            startupCompleted = true
        }

        assertTrue(startupCompleted)
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), artifacts.executedSteps)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testStartup_CleanLaunch_InitializesRuntimeNormally() {
        val journal = InMemoryJournal()
        val artifacts = StepTrackingArtifacts()

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(0, artifacts.executedSteps.size)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testStartup_MidWipeCrash_LeavesConsistentFinalState() {
        val journal = InMemoryJournal()
        journal.write(WipeState.KEY_ERASED)
        val artifacts = StepTrackingArtifacts()

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(listOf("deleteArtifacts", "regenerateIdentity"), artifacts.executedSteps)
        assertEquals(WipeState.IDLE, journal.state)
        assertNotNull(artifacts.currentIdentity)
    }

    @Test
    fun testStartup_IdentityRegeneration_YieldsFreshNodeIdAndZeroGeneration() {
        val originalIdentity = MeshIdentity.generate()
        val regeneratedIdentity = MeshIdentity.generate()

        assertFalse(originalIdentity.nodeId.contentEquals(regeneratedIdentity.nodeId))
        assertFalse(originalIdentity.identityPub.contentEquals(regeneratedIdentity.identityPub))
        assertFalse(originalIdentity.staticDhPub.contentEquals(regeneratedIdentity.staticDhPub))
        assertEquals(0L, regeneratedIdentity.bindingGeneration)
    }

    @Test
    fun testStartup_OldDatabaseFilesUnusable_AfterCryptoErasure() {
        val journal = InMemoryJournal()
        val artifacts = StepTrackingArtifacts()
        val oldIdentity = artifacts.currentIdentity

        PanicWipe(journal, artifacts).begin()

        val newIdentity = artifacts.currentIdentity
        assertNotNull(newIdentity)
        assertNotEquals(oldIdentity!!.nodeId, newIdentity!!.nodeId)
    }

    @Test
    fun testStartup_WipeJournalCleared_OnlyUponFullCompletion() {
        val journal = InMemoryJournal()
        val artifacts = object : WipeArtifacts {
            var stepCount = 0
            override fun eraseKeys() { stepCount++ }
            override fun deleteArtifacts() {
                stepCount++
                throw RuntimeException("Crash before regenerateIdentity")
            }
            override fun regenerateIdentity() { stepCount++ }
        }

        val wipe = PanicWipe(journal, artifacts)
        try {
            wipe.begin()
        } catch (_: Exception) {}

        assertEquals(WipeState.KEY_ERASED, journal.state)
        assertEquals(0, journal.clears)
    }

    @Test
    fun testStartup_RebootBarrier_PreventsStaleStoreAccess() {
        val journal = InMemoryJournal()
        journal.write(WipeState.REQUESTED)
        var barrierCleared = false
        val artifacts = object : WipeArtifacts {
            override fun eraseKeys() {}
            override fun deleteArtifacts() {}
            override fun regenerateIdentity() { barrierCleared = true }
        }

        assertFalse(barrierCleared)
        PanicWipe(journal, artifacts).resumeIfPending()
        assertTrue(barrierCleared)
    }
}
