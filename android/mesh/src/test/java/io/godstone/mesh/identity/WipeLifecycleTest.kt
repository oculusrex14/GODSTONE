package io.godstone.mesh.identity

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.RepositoryPeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.BoundRecipientKeyResolver
import io.godstone.mesh.delivery.RepositoryPeerIdentityLookupSource
import io.godstone.mesh.identity.PanicWipe.WipeState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class WipeLifecycleTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private class InMemoryJournal : WipeJournal {
        var state: WipeState = WipeState.IDLE
        override fun read(): WipeState = state
        override fun write(s: WipeState) { state = s }
        override fun clear() { state = WipeState.IDLE }
    }

    private class RecordingArtifacts(val crashBefore: String? = null) : WipeArtifacts {
        val calls = mutableListOf<String>()
        private val crashed = mutableSetOf<String>()

        private fun step(name: String, block: () -> Unit) {
            if (crashBefore == name && name !in crashed) {
                crashed += name
                throw RuntimeException("Simulated crash at $name")
            }
            block()
            calls += name
        }

        override fun eraseKeys() = step("eraseKeys") {}
        override fun deleteArtifacts() = step("deleteArtifacts") {}
        override fun regenerateIdentity() = step("regenerateIdentity") {}
    }

    @Test
    fun testWipe_CleanIdle_NoOp() {
        val journal = InMemoryJournal()
        val artifacts = RecordingArtifacts()
        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(0, artifacts.calls.size)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testWipe_FullExecution_ErasesKeysAndDeletesArtifactsAndRegeneratesIdentity() {
        val journal = InMemoryJournal()
        val artifacts = RecordingArtifacts()
        val wipe = PanicWipe(journal, artifacts)
        wipe.begin()

        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), artifacts.calls)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testWipe_InvalidatesRuntimeHandles_BeforeKeyErasure() {
        val events = mutableListOf<String>()
        val invalidator = object : RuntimeInvalidator {
            override fun invalidateForWipe() {
                events += "invalidated"
            }
        }
        val delegateArtifacts = object : WipeArtifacts {
            override fun eraseKeys() { events += "eraseKeys" }
            override fun deleteArtifacts() { events += "deleteArtifacts" }
            override fun regenerateIdentity() { events += "regenerateIdentity" }
        }
        val awareArtifacts = RuntimeAwareWipeArtifacts(invalidator, delegateArtifacts)
        val journal = InMemoryJournal()
        val wipe = PanicWipe(journal, awareArtifacts)
        wipe.begin()

        assertEquals(listOf("invalidated", "eraseKeys", "deleteArtifacts", "regenerateIdentity"), events)
    }

    @Test
    fun testWipe_SessionManagerInvalidated_RefusesAllOperations() {
        val identity = MeshIdentity.generate()
        val gate = DefaultRuntimeLifecycleGate()
        val sm = SessionManager(
            identity,
            object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding) = PeerTrustApplyResult.Accepted
            },
            lifecycleGate = gate
        )
        val peer = MeshIdentity.generate()
        val hs1 = sm.initiatorStart(peer.nodeId, peer.nodeHint)
        assertNotNull(hs1)

        gate.invalidateForWipe()
        assertTrue(sm.isInvalidated)
        assertFalse(sm.isActive)
        assertFalse(sm.isReady(peer.nodeId))
        assertNull(sm.seal(peer.nodeId, "data".toByteArray(Charsets.UTF_8)))
        assertNull(sm.open(peer.nodeId, "data".toByteArray(Charsets.UTF_8)))
        assertNull(sm.initiatorStart(MeshIdentity.generate().nodeId, ByteArray(4)))
    }

    @Test
    fun testWipe_ResolverReturnsNull_AfterInvalidation() {
        val file = tempFolder.newFile("wipe_res_${System.nanoTime()}.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(store)
        val gate = DefaultRuntimeLifecycleGate()
        val lookup = RuntimeGatedPeerIdentityLookupSource(RepositoryPeerIdentityLookupSource(repo), gate)
        val resolver = BoundRecipientKeyResolver(lookup)

        val peer = MeshIdentity.generate()
        val binding = peer.issueIdentityBinding()
        val validated = IdentityBindingValidator.validate(binding.encode(), peer.staticDhPub, peer.nodeHint) as IdentityBindingValidationResult.Valid
        repo.applyValidatedBinding(validated.binding)

        assertNotNull(resolver.publicSigningKey(peer.nodeId))

        gate.invalidateForWipe()
        assertNull(resolver.publicSigningKey(peer.nodeId))
    }

    @Test
    fun testWipe_TrustAuthorityReturnsStorageFailure_AfterInvalidation() {
        val file = tempFolder.newFile("wipe_trust_${System.nanoTime()}.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(store)
        val gate = DefaultRuntimeLifecycleGate()
        val trustAuthority = RuntimeGatedPeerBindingTrustAuthority(RepositoryPeerBindingTrustAuthority(repo), gate)

        val peer = MeshIdentity.generate()
        val binding = peer.issueIdentityBinding()
        val validated = IdentityBindingValidator.validate(binding.encode(), peer.staticDhPub, peer.nodeHint) as IdentityBindingValidationResult.Valid

        gate.invalidateForWipe()
        val res = trustAuthority.applyValidatedBinding(validated.binding)
        assertTrue(res is PeerTrustApplyResult.StorageFailure)
    }

    @Test
    fun testWipe_PeerStoreClosed_AfterInvalidation() {
        val file = tempFolder.newFile("wipe_peer_store_${System.nanoTime()}.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val gate = DefaultRuntimeLifecycleGate()
        val invalidator = MeshRuntimeInvalidator(gate, peerStore = store)
        invalidator.invalidateForWipe()

        assertTrue(gate.isInvalidated)
    }

    @Test
    fun testWipe_MessageStoreClosed_AfterInvalidation() {
        val gate = DefaultRuntimeLifecycleGate()
        val invalidator = MeshRuntimeInvalidator(gate)
        invalidator.invalidateForWipe()
        assertTrue(gate.isInvalidated)
    }

    @Test
    fun testWipe_CrashAtRequested_ResumesWipeAndCompletes() {
        val journal = InMemoryJournal()
        val artifacts = RecordingArtifacts(crashBefore = "eraseKeys")
        val wipe = PanicWipe(journal, artifacts)
        try {
            wipe.begin()
            fail("Expected crash")
        } catch (_: Exception) {}

        assertEquals(WipeState.REQUESTED, journal.state)
        assertEquals(0, artifacts.calls.size)

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), artifacts.calls)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testWipe_CrashAtKeyErased_ResumesWipeAndCompletes() {
        val journal = InMemoryJournal()
        val artifacts = RecordingArtifacts(crashBefore = "deleteArtifacts")
        val wipe = PanicWipe(journal, artifacts)
        try {
            wipe.begin()
            fail("Expected crash")
        } catch (_: Exception) {}

        assertEquals(WipeState.KEY_ERASED, journal.state)
        assertEquals(listOf("eraseKeys"), artifacts.calls)

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), artifacts.calls)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testWipe_CrashAtArtifactsDeleted_ResumesWipeAndCompletes() {
        val journal = InMemoryJournal()
        val artifacts = RecordingArtifacts(crashBefore = "regenerateIdentity")
        val wipe = PanicWipe(journal, artifacts)
        try {
            wipe.begin()
            fail("Expected crash")
        } catch (_: Exception) {}

        assertEquals(WipeState.ARTIFACTS_DELETED, journal.state)
        assertEquals(listOf("eraseKeys", "deleteArtifacts"), artifacts.calls)

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), artifacts.calls)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testWipe_CrashAtNewIdentity_ResumesWipeAndCompletes() {
        val journal = InMemoryJournal()
        journal.write(WipeState.NEW_IDENTITY)
        val artifacts = RecordingArtifacts()

        PanicWipe(journal, artifacts).resumeIfPending()
        assertEquals(0, artifacts.calls.size)
        assertEquals(WipeState.IDLE, journal.state)
    }

    @Test
    fun testWipe_OldRuntimeHandleRemainsInvalid_AfterWipeCompletes() {
        val gate = DefaultRuntimeLifecycleGate()
        val invalidator = MeshRuntimeInvalidator(gate)
        val delegate = RecordingArtifacts()
        val awareArtifacts = RuntimeAwareWipeArtifacts(invalidator, delegate)
        val journal = InMemoryJournal()
        val wipe = PanicWipe(journal, awareArtifacts)
        wipe.begin()

        assertTrue(gate.isInvalidated)
        assertFalse(gate.isActive)
    }

    @Test
    fun testWipe_FreshRuntimeInstance_AfterWipeWorksNormally() {
        val journal = InMemoryJournal()
        val artifacts = RecordingArtifacts()
        PanicWipe(journal, artifacts).begin()

        val freshGate = DefaultRuntimeLifecycleGate()
        assertTrue(freshGate.isActive)
        assertFalse(freshGate.isInvalidated)
    }

    @Test
    fun testWipe_InvalidationException_PreventsKeyErasure() {
        val invalidator = object : RuntimeInvalidator {
            override fun invalidateForWipe() {
                throw IllegalStateException("Pre-wipe invalidator failure")
            }
        }
        val delegateArtifacts = RecordingArtifacts()
        val awareArtifacts = RuntimeAwareWipeArtifacts(invalidator, delegateArtifacts)
        val journal = InMemoryJournal()
        val wipe = PanicWipe(journal, awareArtifacts)

        try {
            wipe.begin()
            fail("Expected exception")
        } catch (_: IllegalStateException) {}

        assertEquals(0, delegateArtifacts.calls.size)
    }
}
