package io.godstone.mesh.identity

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.crypto.PeerBindingTrustAuthority
import io.godstone.mesh.crypto.RepositoryPeerBindingTrustAuthority
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.delivery.BoundRecipientKeyResolver
import io.godstone.mesh.delivery.RepositoryPeerIdentityLookupSource
import io.godstone.mesh.identity.PanicWipe.WipeState
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
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

    private fun makeTestFrame(msgIdHex: String = "0102030405060708090a0b0c0d0e0f10"): FrameV2 {
        val msgId = msgIdHex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        return FrameV2(
            type = TypeV2.MESSAGE,
            msgId = msgId,
            routingTag = ByteArray(16),
            ttl = 3,
            hopCount = 0,
            flags = 0,
            payload = "payload".toByteArray(Charsets.UTF_8)
        )
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
    fun testWipe_DeterministicOrdering_GateSessionsPeerMessageKeys() {
        val order = mutableListOf<String>()
        val gate = DefaultRuntimeLifecycleGate()
        val identity = MeshIdentity.generate()
        val sm = SessionManager(
            identity = identity,
            trustAuthority = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding) = PeerTrustApplyResult.Accepted
            },
            lifecycleGate = gate
        )
        val peerFile = tempFolder.newFile("peer_order.db").also { it.delete() }
        val peerStore = JdbcPeerIdentityStore(peerFile)
        val msgFile = tempFolder.newFile("msg_order.db").also { it.delete() }
        val msgStore = SqliteMessageStore(JdbcStoreDb(msgFile), 4096)

        val invalidator = object : RuntimeInvalidator {
            override fun invalidateForWipe() {
                order += "gateInvalidated"
                gate.invalidateForWipe()
                order += "sessionsInvalidated"
                sm.invalidateForWipe()
                order += "peerStoreClosed"
                peerStore.close()
                order += "messageStoreClosed"
                msgStore.close()
            }
        }

        val delegate = object : WipeArtifacts {
            override fun eraseKeys() {
                order += "platformEraseKeys"
            }
            override fun deleteArtifacts() {
                order += "deleteArtifacts"
            }
            override fun regenerateIdentity() {
                order += "regenerateIdentity"
            }
        }

        val wipe = PanicWipe(InMemoryJournal(), RuntimeAwareWipeArtifacts(invalidator, delegate))
        wipe.begin()

        assertEquals(
            listOf(
                "gateInvalidated",
                "sessionsInvalidated",
                "peerStoreClosed",
                "messageStoreClosed",
                "platformEraseKeys",
                "deleteArtifacts",
                "regenerateIdentity"
            ),
            order
        )
    }

    @Test
    fun testWipe_SessionManagerInvalidated_RefusesAllOperations() {
        val gate = DefaultRuntimeLifecycleGate()
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()

        val sm = SessionManager(
            identity = identityA,
            trustAuthority = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding) = PeerTrustApplyResult.Accepted
            },
            lifecycleGate = gate
        )

        val peerB = ByteArray(16) { 0x02 }
        val hs1 = sm.initiatorStart(peerB, identityB.nodeHint)
        assertNotNull(hs1)

        gate.invalidateForWipe()
        assertTrue(gate.isInvalidated)
        assertFalse(gate.isActive)

        // Session manager must refuse new operations post-invalidation
        val peerC = ByteArray(16) { 0x03 }
        assertNull(sm.initiatorStart(peerC, identityB.nodeHint))
        assertNull(sm.seal(peerB, "test".toByteArray()))
        assertNull(sm.open(peerB, "test".toByteArray()))
    }

    @Test
    fun testWipe_ResolverReturnsNull_AfterInvalidation() {
        val file = tempFolder.newFile("wipe_resolver_${System.nanoTime()}.db").also { it.delete() }
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
    fun testWipe_W04_PeerStoreClosed_AfterInvalidation() {
        val file = tempFolder.newFile("wipe_peer_store_${System.nanoTime()}.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val gate = DefaultRuntimeLifecycleGate()

        // 1. Verify store functions normally before invalidation
        val peer = MeshIdentity.generate()
        val record = store.readRaw(peer.nodeId)
        assertNull(record)

        // 2. Invalidate via MeshRuntimeInvalidator
        val invalidator = MeshRuntimeInvalidator(gate, peerStore = store)
        invalidator.invalidateForWipe()
        assertTrue(gate.isInvalidated)

        // 3. Post-invalidation: direct store operations fail closed because handle is closed
        try {
            store.readRaw(peer.nodeId)
            fail("Expected exception accessing closed database handle")
        } catch (e: Exception) {
            // Expected closed connection exception
        }
    }

    @Test
    fun testWipe_W05_MessageStoreClosed_AfterInvalidation() {
        val file = tempFolder.newFile("wipe_msg_store_${System.nanoTime()}.db").also { it.delete() }
        val store = SqliteMessageStore(JdbcStoreDb(file), 4096)
        val gate = DefaultRuntimeLifecycleGate()

        // 1. Verify store functions normally before invalidation
        val frame = makeTestFrame("0102030405060708090a0b0c0d0e0f10")
        val res1 = kotlinx.coroutines.runBlocking { store.persist(frame, ByteArray(16)) }
        assertEquals(PersistResult.HELD_NEW, res1)

        // 2. Invalidate via MeshRuntimeInvalidator
        val invalidator = MeshRuntimeInvalidator(gate, messageStore = store)
        invalidator.invalidateForWipe()
        assertTrue(gate.isInvalidated)

        // 3. Post-invalidation: persist returns FAILED_STORAGE
        val frame2 = makeTestFrame("0202030405060708090a0b0c0d0e0f10")
        val res2 = kotlinx.coroutines.runBlocking { store.persist(frame2, ByteArray(16)) }
        assertEquals(PersistResult.FAILED_STORAGE, res2)
    }

    @Test
    fun testWipe_W06_InvalidatorFailure_PreventsKeyErasure_PreservesRequestedState() {
        val journal = InMemoryJournal()
        val gate = DefaultRuntimeLifecycleGate()

        var erasedKeys = false
        val failingInvalidator = object : RuntimeInvalidator {
            override fun invalidateForWipe() {
                gate.invalidateForWipe()
                throw RuntimeException("Store closure I/O deadlock failure")
            }
        }
        val delegate = object : WipeArtifacts {
            override fun eraseKeys() { erasedKeys = true }
            override fun deleteArtifacts() {}
            override fun regenerateIdentity() {}
        }

        val wipe = PanicWipe(journal, RuntimeAwareWipeArtifacts(failingInvalidator, delegate))
        try {
            wipe.begin()
            fail("Expected wipe to fail when invalidator throws")
        } catch (e: Exception) {
            // Expected
        }

        assertFalse("Key erasure must NOT happen if invalidation fails", erasedKeys)
        assertEquals(WipeState.REQUESTED, journal.state)
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

        // Resume with non-crashing artifacts
        val resumeArtifacts = RecordingArtifacts()
        PanicWipe(journal, resumeArtifacts).resumeIfPending()

        assertEquals(listOf("eraseKeys", "deleteArtifacts", "regenerateIdentity"), resumeArtifacts.calls)
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

        val resumeArtifacts = RecordingArtifacts()
        PanicWipe(journal, resumeArtifacts).resumeIfPending()

        assertEquals(listOf("deleteArtifacts", "regenerateIdentity"), resumeArtifacts.calls)
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

        val resumeArtifacts = RecordingArtifacts()
        PanicWipe(journal, resumeArtifacts).resumeIfPending()

        assertEquals(listOf("regenerateIdentity"), resumeArtifacts.calls)
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
        val sm = SessionManager(
            identity = MeshIdentity.generate(),
            trustAuthority = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding) = PeerTrustApplyResult.Accepted
            },
            lifecycleGate = gate
        )
        val journal = InMemoryJournal()
        val artifacts = RecordingArtifacts()

        val wipe = PanicWipe(journal, RuntimeAwareWipeArtifacts(gate, artifacts))
        wipe.begin()

        assertTrue(gate.isInvalidated)
        assertFalse(gate.isActive)
        assertFalse(sm.isActive)
    }

    @Test
    fun testWipe_FreshRuntimeInstance_AfterWipeWorksNormally() {
        val journal = InMemoryJournal()
        var freshIdentity: Identity? = null
        val artifacts = object : WipeArtifacts {
            override fun eraseKeys() {}
            override fun deleteArtifacts() {}
            override fun regenerateIdentity() {
                freshIdentity = MeshIdentity.generate()
            }
        }

        PanicWipe(journal, artifacts).begin()

        assertNotNull(freshIdentity)
        val freshGate = DefaultRuntimeLifecycleGate()
        val freshSm = SessionManager(
            identity = freshIdentity!!,
            trustAuthority = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding) = PeerTrustApplyResult.Accepted
            },
            lifecycleGate = freshGate
        )

        assertTrue(freshGate.isActive)
        assertTrue(freshSm.isActive)
    }

    @Test
    fun testWipe_W15_RealDatabaseArtifactsAndSidecars_DeletedAfterClosure() {
        val peerFile = tempFolder.newFile("w15_peer.db")
        val peerWal = File(peerFile.parentFile, "${peerFile.name}-wal").also { it.writeText("wal") }
        val peerShm = File(peerFile.parentFile, "${peerFile.name}-shm").also { it.writeText("shm") }
        val msgFile = tempFolder.newFile("w15_msg.db")
        val msgWal = File(msgFile.parentFile, "${msgFile.name}-wal").also { it.writeText("wal") }
        val msgShm = File(msgFile.parentFile, "${msgFile.name}-shm").also { it.writeText("shm") }

        assertTrue(peerFile.exists())
        assertTrue(peerWal.exists())
        assertTrue(peerShm.exists())
        assertTrue(msgFile.exists())
        assertTrue(msgWal.exists())
        assertTrue(msgShm.exists())

        // Physical deletion step
        val artifacts = object : WipeArtifacts {
            override fun eraseKeys() {}
            override fun deleteArtifacts() {
                listOf(peerFile, peerWal, peerShm, msgFile, msgWal, msgShm).forEach {
                    if (it.exists()) it.delete()
                }
            }
            override fun regenerateIdentity() {}
        }

        PanicWipe(InMemoryJournal(), artifacts).begin()

        assertFalse(peerFile.exists())
        assertFalse(peerWal.exists())
        assertFalse(peerShm.exists())
        assertFalse(msgFile.exists())
        assertFalse(msgWal.exists())
        assertFalse(msgShm.exists())
    }
}
