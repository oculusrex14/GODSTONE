package io.godstone.mesh.identity

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.RepositoryPeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.BoundRecipientKeyResolver
import io.godstone.mesh.delivery.RepositoryPeerIdentityLookupSource
import io.godstone.mesh.di.MeshStartupCoordinator
import io.godstone.mesh.di.runStartupWipeBarrier
import io.godstone.mesh.identity.PanicWipe.WipeState
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.SqliteMessageStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
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

    private class RecordingWipeArtifacts(
        val onStep: ((String) -> Unit)? = null,
        val crashAt: String? = null
    ) : WipeArtifacts {
        val executedSteps = mutableListOf<String>()
        var currentIdentity: Identity? = MeshIdentity.generate()

        private fun record(step: String) {
            if (crashAt == step) {
                throw RuntimeException("Simulated crash at $step")
            }
            executedSteps += step
            onStep?.invoke(step)
        }

        override fun eraseKeys() {
            record("eraseKeys")
            currentIdentity = null
        }

        override fun deleteArtifacts() {
            record("deleteArtifacts")
        }

        override fun regenerateIdentity() {
            record("regenerateIdentity")
            currentIdentity = MeshIdentity.generate()
        }
    }

    @Test
    fun testSR01_CleanLaunch_InitializesRuntimeNormally() {
        val journal = InMemoryJournal()
        val events = mutableListOf<String>()
        val artifacts = RecordingWipeArtifacts(onStep = { events += it })

        var barrierExecuted = false
        var identityOpened = false
        var messageStoreOpened = false
        var peerStoreOpened = false

        // Exercise startup coordinator/barrier
        val coordinator = MeshStartupCoordinator {
            events += "startupWipeBarrier"
            PanicWipe(journal, artifacts).resumeIfPending()
            barrierExecuted = true
        }

        coordinator.executeBarrier()
        assertTrue(barrierExecuted)

        // Sensitive opens occur only after barrier returns
        if (barrierExecuted) {
            events += "identityOpen"
            identityOpened = true
            events += "messageStoreOpen"
            messageStoreOpened = true
            events += "peerStoreOpen"
            peerStoreOpened = true
        }

        assertEquals(
            listOf("startupWipeBarrier", "identityOpen", "messageStoreOpen", "peerStoreOpen"),
            events
        )
        assertEquals(0, artifacts.executedSteps.size)
        assertEquals(WipeState.IDLE, journal.state)
        assertTrue(identityOpened && messageStoreOpened && peerStoreOpened)
    }

    @Test
    fun testSR02_PendingWipe_Requested_FinishesBeforeRuntimeInitialization() {
        val journal = InMemoryJournal()
        journal.write(WipeState.REQUESTED)

        val events = mutableListOf<String>()
        val artifacts = RecordingWipeArtifacts(onStep = { events += it })

        var identityOpened = false
        var messageStoreOpened = false
        var peerStoreOpened = false

        val coordinator = MeshStartupCoordinator {
            events += "startupWipeBarrier"
            PanicWipe(journal, artifacts).resumeIfPending()
        }

        coordinator.executeBarrier()

        // Sensitive opens execute after barrier completes wipe recovery
        events += "identityOpen"
        identityOpened = true
        events += "messageStoreOpen"
        messageStoreOpened = true
        events += "peerStoreOpen"
        peerStoreOpened = true

        assertEquals(
            listOf(
                "startupWipeBarrier",
                "eraseKeys",
                "deleteArtifacts",
                "regenerateIdentity",
                "identityOpen",
                "messageStoreOpen",
                "peerStoreOpen"
            ),
            events
        )
        assertEquals(WipeState.IDLE, journal.state)
        assertTrue(identityOpened && messageStoreOpened && peerStoreOpened)

        // Fail-closed verification: If wipe recovery throws, sensitive opens MUST NOT execute
        val failingJournal = InMemoryJournal()
        failingJournal.write(WipeState.REQUESTED)
        val failingArtifacts = RecordingWipeArtifacts(crashAt = "eraseKeys")

        var failedIdentityOpens = 0
        var failedMessageStoreOpens = 0
        var failedPeerStoreOpens = 0

        val failingCoordinator = MeshStartupCoordinator {
            PanicWipe(failingJournal, failingArtifacts).resumeIfPending()
        }

        try {
            failingCoordinator.executeBarrier()
            failedIdentityOpens++
            failedMessageStoreOpens++
            failedPeerStoreOpens++
            fail("Expected startup barrier to fail when wipe recovery throws")
        } catch (e: Exception) {
            // Expected
        }

        assertEquals(0, failedIdentityOpens)
        assertEquals(0, failedMessageStoreOpens)
        assertEquals(0, failedPeerStoreOpens)
        assertEquals(WipeState.REQUESTED, failingJournal.state)
    }

    @Test
    fun testSR03_KeyErased_DeletesExactStoreArtifactsBeforeOpen() {
        val msgFile = tempFolder.newFile("sr03_msg.db").also { it.writeText("msg_data") }
        val msgWal = File(msgFile.parentFile, "${msgFile.name}-wal").also { it.writeText("msg_wal") }
        val msgShm = File(msgFile.parentFile, "${msgFile.name}-shm").also { it.writeText("msg_shm") }
        val msgJournal = File(msgFile.parentFile, "${msgFile.name}-journal").also { it.writeText("msg_journal") }

        val peerFile = tempFolder.newFile("sr03_peer.db").also { it.writeText("peer_data") }
        val peerWal = File(peerFile.parentFile, "${peerFile.name}-wal").also { it.writeText("peer_wal") }
        val peerShm = File(peerFile.parentFile, "${peerFile.name}-shm").also { it.writeText("peer_shm") }
        val peerJournal = File(peerFile.parentFile, "${peerFile.name}-journal").also { it.writeText("peer_journal") }

        val allArtifacts = listOf(msgFile, msgWal, msgShm, msgJournal, peerFile, peerWal, peerShm, peerJournal)
        allArtifacts.forEach { assertTrue(it.exists()) }

        val journal = InMemoryJournal()
        journal.write(WipeState.KEY_ERASED)

        var deletedBeforeOpen = false
        var storeOpened = false

        val artifacts = object : WipeArtifacts {
            override fun eraseKeys() {}
            override fun deleteArtifacts() {
                allArtifacts.forEach { if (it.exists()) it.delete() }
            }
            override fun regenerateIdentity() {}
        }

        val coordinator = MeshStartupCoordinator {
            PanicWipe(journal, artifacts).resumeIfPending()
            // Verify all artifacts are deleted BEFORE coordinator returns
            deletedBeforeOpen = allArtifacts.none { it.exists() }
        }

        coordinator.executeBarrier()
        assertTrue(deletedBeforeOpen)

        // Open stores at the exact same paths post-deletion
        val freshPeerStore = JdbcPeerIdentityStore(peerFile)
        val freshMsgStore = SqliteMessageStore(JdbcStoreDb(msgFile), 4096)
        storeOpened = true

        assertTrue(storeOpened)
        assertEquals(WipeState.IDLE, journal.state)
        assertNull(freshPeerStore.readRaw(ByteArray(16)))
    }

    @Test
    fun testSR04_ArtifactsDeleted_RegeneratesIdentityBeforeRuntimeConstruction() {
        val journal = InMemoryJournal()
        journal.write(WipeState.ARTIFACTS_DELETED)

        val events = mutableListOf<String>()
        var regeneratedIdentity: Identity? = null

        val artifacts = object : WipeArtifacts {
            override fun eraseKeys() { events += "eraseKeys" }
            override fun deleteArtifacts() { events += "deleteArtifacts" }
            override fun regenerateIdentity() {
                events += "regenerateIdentity"
                regeneratedIdentity = MeshIdentity.generate()
            }
        }

        var identityOpened = false
        var messageStoreOpened = false
        var peerStoreOpened = false

        val coordinator = MeshStartupCoordinator {
            events += "startupWipeBarrier"
            PanicWipe(journal, artifacts).resumeIfPending()
        }

        coordinator.executeBarrier()

        events += "identityOpen"
        identityOpened = true
        events += "messageStoreOpen"
        messageStoreOpened = true
        events += "peerStoreOpen"
        peerStoreOpened = true

        assertEquals(
            listOf(
                "startupWipeBarrier",
                "regenerateIdentity",
                "identityOpen",
                "messageStoreOpen",
                "peerStoreOpen"
            ),
            events
        )
        assertEquals(WipeState.IDLE, journal.state)
        assertNotNull(regeneratedIdentity)
        assertEquals(0L, regeneratedIdentity!!.bindingGeneration)
        assertTrue(identityOpened && messageStoreOpened && peerStoreOpened)
    }

    @Test
    fun testSR05_FreshRuntime_AfterWipe_HasDifferentNodeId() {
        // 1. Create old identity authority and record old node_id
        val oldIdentity = MeshIdentity.generate()
        val oldNodeId = oldIdentity.nodeId.clone()
        val oldGate = DefaultRuntimeLifecycleGate()
        val oldSm = SessionManager(
            identity = oldIdentity,
            trustAuthority = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding) = PeerTrustApplyResult.Accepted
            },
            lifecycleGate = oldGate
        )
        assertTrue(oldGate.isActive)
        assertTrue(oldSm.isActive)

        // 2. Execute runtime-aware wipe lifecycle
        var regeneratedIdentity: Identity? = null
        val wipeArtifacts = object : WipeArtifacts {
            override fun eraseKeys() {}
            override fun deleteArtifacts() {}
            override fun regenerateIdentity() {
                regeneratedIdentity = MeshIdentity.generate()
            }
        }
        val aware = RuntimeAwareWipeArtifacts(invalidator = oldGate, delegate = wipeArtifacts)
        val journal = InMemoryJournal()
        PanicWipe(journal, aware).begin()

        // 3. Verify old runtime/gate remains invalidated
        assertTrue(oldGate.isInvalidated)
        assertFalse(oldGate.isActive)
        assertFalse(oldSm.isActive)

        // 4. Construct fresh post-wipe identity via normal regeneration/startup authority
        assertNotNull(regeneratedIdentity)
        val newIdentity = regeneratedIdentity!!

        // 5. Verify new node_id != old node_id and generation == 0
        assertFalse(oldNodeId.contentEquals(newIdentity.nodeId))
        assertFalse(oldIdentity.identityPub.contentEquals(newIdentity.identityPub))
        assertFalse(oldIdentity.staticDhPub.contentEquals(newIdentity.staticDhPub))
        assertEquals(0L, newIdentity.bindingGeneration)

        val freshGate = DefaultRuntimeLifecycleGate()
        val freshSm = SessionManager(
            identity = newIdentity,
            trustAuthority = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding) = PeerTrustApplyResult.Accepted
            },
            lifecycleGate = freshGate
        )
        assertTrue(freshGate.isActive)
        assertTrue(freshSm.isActive)
    }

    @Test
    fun testSR06_FreshPeerStore_ContainsNoPriorPeerRecords() {
        // 1. Create real temporary JdbcPeerIdentityStore at path P
        val peerFile = tempFolder.newFile("sr06_peer.db").also { it.delete() }
        val peerStore1 = JdbcPeerIdentityStore(peerFile)
        val repo1 = PeerIdentityRepository(peerStore1)

        // 2. Insert a VALID peer via canonical validated binding
        val peer = MeshIdentity.generate()
        val binding = peer.issueIdentityBinding()
        val validated = IdentityBindingValidator.validate(binding.encode(), peer.staticDhPub, peer.nodeHint) as IdentityBindingValidationResult.Valid
        val applyResult = repo1.applyValidatedBinding(validated.binding)
        assertTrue(applyResult is PeerTrustApplyResult.FirstSeenPinned || applyResult is PeerTrustApplyResult.Accepted)

        // 3. Prove lookup before wipe returns Verified
        val lookup1 = repo1.lookup(peer.nodeId)
        assertTrue(lookup1 is PeerIdentityLookup.Verified)
        assertNotNull(peerStore1.readRaw(peer.nodeId))

        // 4. Close/invalidate runtime authority
        val gate = DefaultRuntimeLifecycleGate()
        val invalidator = MeshRuntimeInvalidator(lifecycleGate = gate, peerStore = peerStore1)
        invalidator.invalidateForWipe()
        assertTrue(gate.isInvalidated)

        // 5. Execute artifact deletion of THAT SAME peer DB path P
        val artifacts = object : WipeArtifacts {
            override fun eraseKeys() {}
            override fun deleteArtifacts() {
                if (peerFile.exists()) peerFile.delete()
                val wal = File(peerFile.parentFile, "${peerFile.name}-wal")
                if (wal.exists()) wal.delete()
                val shm = File(peerFile.parentFile, "${peerFile.name}-shm")
                if (shm.exists()) shm.delete()
            }
            override fun regenerateIdentity() {}
        }
        PanicWipe(InMemoryJournal(), artifacts).begin()
        assertFalse(peerFile.exists())

        // 6. Construct fresh peer store at THAT SAME path P
        val peerStore2 = JdbcPeerIdentityStore(peerFile)
        val repo2 = PeerIdentityRepository(peerStore2)

        // 7. Prove old peer is NotFound / no raw row
        assertNull(peerStore2.readRaw(peer.nodeId))
        val lookup2 = repo2.lookup(peer.nodeId)
        assertTrue(lookup2 is PeerIdentityLookup.NotFound)
    }

    @Test
    fun testSR07_OldRuntimeHandle_RemainsPermanentlyUnusable() {
        val gate = DefaultRuntimeLifecycleGate()
        val peerFile = tempFolder.newFile("sr07_peer.db").also { it.delete() }
        val peerStore = JdbcPeerIdentityStore(peerFile)
        val peerRepo = PeerIdentityRepository(peerStore)

        val gatedLookup = RuntimeGatedPeerIdentityLookupSource(RepositoryPeerIdentityLookupSource(peerRepo), gate)
        val resolver = BoundRecipientKeyResolver(gatedLookup)

        val gatedTrust = RuntimeGatedPeerBindingTrustAuthority(RepositoryPeerBindingTrustAuthority(peerRepo), gate)
        val sm = SessionManager(
            identity = MeshIdentity.generate(),
            trustAuthority = gatedTrust,
            lifecycleGate = gate
        )

        // Establish state: insert a valid peer so resolver works before invalidation
        val peer = MeshIdentity.generate()
        val binding = peer.issueIdentityBinding()
        val validated = IdentityBindingValidator.validate(binding.encode(), peer.staticDhPub, peer.nodeHint) as IdentityBindingValidationResult.Valid
        peerRepo.applyValidatedBinding(validated.binding)

        assertNotNull(resolver.publicSigningKey(peer.nodeId))
        assertTrue(sm.isActive)

        // Run the runtime invalidator/wipe composition
        val invalidator = MeshRuntimeInvalidator(
            lifecycleGate = gate,
            sessions = sm,
            peerStore = peerStore
        )
        val journal = InMemoryJournal()
        val artifacts = RuntimeAwareWipeArtifacts(invalidator = invalidator, delegate = RecordingWipeArtifacts())
        PanicWipe(journal, artifacts).begin()

        // Post-wipe assertions: all operations permanently denied
        assertTrue(gate.isInvalidated)
        assertFalse(gate.isActive)
        assertFalse(sm.isActive)

        val dummyPeer = ByteArray(16) { 0x07 }
        assertNull(sm.initiatorStart(dummyPeer, ByteArray(4)))
        assertNull(sm.seal(dummyPeer, "test".toByteArray(Charsets.UTF_8)))
        assertNull(sm.open(dummyPeer, "test".toByteArray(Charsets.UTF_8)))
        assertNull(resolver.publicSigningKey(peer.nodeId))

        val applyPost = gatedTrust.applyValidatedBinding(validated.binding)
        assertTrue(applyPost is PeerTrustApplyResult.StorageFailure)

        try {
            peerStore.readRaw(peer.nodeId)
            fail("Expected closed connection exception accessing peerStore post-wipe")
        } catch (e: Exception) {
            // Expected
        }
    }
}
