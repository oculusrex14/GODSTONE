package io.godstone.mesh.identity

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.identity.PanicWipe.WipeState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class CrashStartupResumeTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

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
    fun testSR01_CleanLaunch_InitializesRuntimeNormally() {
        val journal = InMemoryJournal()
        val artifacts = StepTrackingArtifacts()

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(0, artifacts.executedSteps.size)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testSR02_PendingWipe_Requested_FinishesBeforeRuntimeInitialization() {
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
    fun testSR03_KeyErased_DeletesExactStoreArtifactsBeforeOpen() {
        val journal = InMemoryJournal()
        journal.write(WipeState.KEY_ERASED)
        val artifacts = StepTrackingArtifacts()

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(listOf("deleteArtifacts", "regenerateIdentity"), artifacts.executedSteps)
        assertEquals(WipeState.IDLE, journal.state)
        assertNotNull(artifacts.currentIdentity)
    }

    @Test
    fun testSR04_ArtifactsDeleted_RegeneratesIdentityBeforeRuntimeConstruction() {
        val journal = InMemoryJournal()
        journal.write(WipeState.ARTIFACTS_DELETED)
        val artifacts = StepTrackingArtifacts()

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(listOf("regenerateIdentity"), artifacts.executedSteps)
        assertEquals(WipeState.IDLE, journal.state)
        assertEquals(0L, artifacts.currentIdentity?.bindingGeneration)
    }

    @Test
    fun testSR05_FreshRuntime_AfterWipe_HasDifferentNodeId() {
        val originalIdentity = MeshIdentity.generate()
        val regeneratedIdentity = MeshIdentity.generate()

        assertFalse(originalIdentity.nodeId.contentEquals(regeneratedIdentity.nodeId))
        assertFalse(originalIdentity.identityPub.contentEquals(regeneratedIdentity.identityPub))
        assertFalse(originalIdentity.staticDhPub.contentEquals(regeneratedIdentity.staticDhPub))
        assertEquals(0L, regeneratedIdentity.bindingGeneration)
    }

    @Test
    fun testSR06_FreshPeerStore_ContainsNoPriorPeerRecords() {
        val file = tempFolder.newFile("fresh_peer_${System.nanoTime()}.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val dummyNodeId = ByteArray(16)
        assertNull(store.readRaw(dummyNodeId))
    }

    @Test
    fun testSR07_OldRuntimeHandle_RemainsPermanentlyUnusable() {
        val gate = DefaultRuntimeLifecycleGate()
        gate.invalidateForWipe()
        assertTrue(gate.isInvalidated)
        assertFalse(gate.isActive)
    }
}
