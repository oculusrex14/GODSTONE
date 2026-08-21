package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.identity.IdentityBindingV1
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.identity.PeerIdentityLookup
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustLevel
import io.godstone.mesh.identity.PeerTrustRepositoryCorruptionReason
import io.godstone.mesh.identity.RotationApprovalResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.sql.SQLException
import java.util.concurrent.Callable
import java.util.concurrent.Executors

class BoundRecipientKeyResolverTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private val seedA = ByteArray(32) { 0x11 }
    private val staticPrivA = ByteArray(32) { 0x33 }
    private val staticPrivB = ByteArray(32) { 0x44 }

    private fun makeBinding(
        seed: ByteArray,
        generation: Long,
        staticDhPriv: ByteArray
    ): ValidatedPeerBinding {
        val signingPub = Ed25519Keys.publicKeyFromPrivate(seed)
        val staticPub = X25519Keys.publicKeyFromPrivate(staticDhPriv)
        val preimage = IdentityBindingV1.signaturePreimage(
            generation = generation,
            signingPublicKey = signingPub,
            staticDhPublicKey = staticPub
        )
        val sig = Ed25519Keys.sign(preimage, seed)
        val binding = IdentityBindingV1.create(
            generation = generation,
            signingPublicKey = signingPub,
            staticDhPublicKey = staticPub,
            signature = sig
        )
        val res = IdentityBindingValidator.validate(
            serialized = binding.encode(),
            authenticatedRemoteStaticKey = staticPub,
            advertisedNodeHint = IdentityBindingV1.deriveNodeHint(IdentityBindingV1.deriveNodeId(signingPub))
        )
        require(res is IdentityBindingValidationResult.Valid) { "Validation failed" }
        return res.binding
    }

    @Test
    fun testBoundResolver_ActiveTofu_ReturnsSigningKey() {
        val file = tempFolder.newFile("active_tofu.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b0)

            val key = resolver.publicSigningKey(b0.nodeId)
            assertNotNull(key)
            assertEquals(32, key!!.size)
            assertArrayEquals(b0.signingPublicKey, key)
            assertFalse(b0.staticDhPublicKey.contentEquals(key))
        }
    }

    @Test
    fun testBoundResolver_UserVerified_ReturnsSigningKey() {
        val file = tempFolder.newFile("user_verified.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b0)

            // Test SQL seam: promote to USER_VERIFIED (code 2)
            store.execRawSqlForTest("UPDATE peer_identities SET trust_level = 2")

            val key = resolver.publicSigningKey(b0.nodeId)
            assertNotNull(key)
            assertArrayEquals(b0.signingPublicKey, key)
        }
    }

    @Test
    fun testBoundResolver_Unseen_ReturnsNull() {
        val file = tempFolder.newFile("unseen.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val unseenNodeId = ByteArray(16) { 0x99.toByte() }
            val key = resolver.publicSigningKey(unseenNodeId)
            assertNull(key)

            // No row created
            assertNull(store.readRaw(unseenNodeId))
        }
    }

    @Test
    fun testBoundResolver_Quarantined_ReturnsNull() {
        val file = tempFolder.newFile("quarantine.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            val b5 = makeBinding(seedA, 5L, staticPrivB)
            repo.applyValidatedBinding(b0)
            repo.applyValidatedBinding(b5)

            val key = resolver.publicSigningKey(b0.nodeId)
            assertNull("Quarantined peer must return null", key)
        }
    }

    @Test
    fun testBoundResolver_OldAcceptedReplayWhilePending_ReturnsNull() {
        val file = tempFolder.newFile("old_replay.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            val b5 = makeBinding(seedA, 5L, staticPrivB)
            repo.applyValidatedBinding(b0)
            repo.applyValidatedBinding(b5)

            // Replay old accepted binding
            repo.applyValidatedBinding(b0)

            val key = resolver.publicSigningKey(b0.nodeId)
            assertNull("Replay while pending must still return null", key)
        }
    }

    @Test
    fun testBoundResolver_ApprovalRestoresResolution() {
        val file = tempFolder.newFile("approval_restores.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            val b5 = makeBinding(seedA, 5L, staticPrivB)
            repo.applyValidatedBinding(b0)
            repo.applyValidatedBinding(b5)

            assertNull(resolver.publicSigningKey(b0.nodeId))

            val approval = repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
            assertTrue(approval is RotationApprovalResult.Approved)

            val key = resolver.publicSigningKey(b0.nodeId)
            assertNotNull(key)
            assertArrayEquals(b0.signingPublicKey, key)
        }
    }

    @Test
    fun testBoundResolver_Revoked_ReturnsNull() {
        val file = tempFolder.newFile("revoked.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b0)

            assertNotNull(resolver.publicSigningKey(b0.nodeId))

            repo.revokePeer(b0.nodeId)
            assertNull(resolver.publicSigningKey(b0.nodeId))

            // Subsequent binding rejected
            val b5 = makeBinding(seedA, 5L, staticPrivB)
            repo.applyValidatedBinding(b5)
            assertNull(resolver.publicSigningKey(b0.nodeId))
        }
    }

    @Test
    fun testBoundResolver_InvalidNodeLength_NoLookup() {
        var lookupCalls = 0
        val fakeSource = PeerIdentityLookupSource {
            lookupCalls++
            PeerIdentityLookup.NotFound
        }
        val resolver = BoundRecipientKeyResolver(fakeSource)

        assertNull(resolver.publicSigningKey(ByteArray(15)))
        assertNull(resolver.publicSigningKey(ByteArray(17)))
        assertNull(resolver.publicSigningKey(ByteArray(0)))
        assertEquals(0, lookupCalls)

        assertNull(resolver.publicSigningKey(ByteArray(16)))
        assertEquals(1, lookupCalls)
    }

    @Test
    fun testBoundResolver_Corrupt_ReturnsNull() {
        val fakeSource = PeerIdentityLookupSource {
            PeerIdentityLookup.Corrupt(PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("test corruption"))
        }
        val resolver = BoundRecipientKeyResolver(fakeSource)
        assertNull(resolver.publicSigningKey(ByteArray(16)))
    }

    @Test
    fun testBoundResolver_StorageFailure_ReturnsNull() {
        val fakeSource = PeerIdentityLookupSource {
            PeerIdentityLookup.StorageFailure(SQLException("Disk I/O error"))
        }
        val resolver = BoundRecipientKeyResolver(fakeSource)
        assertNull(resolver.publicSigningKey(ByteArray(16)))
    }

    @Test
    fun testBoundResolver_NoCacheAcrossLifecycle() {
        val file = tempFolder.newFile("no_cache.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            val b5 = makeBinding(seedA, 5L, staticPrivB)

            // Step A: Active TOFU
            repo.applyValidatedBinding(b0)
            val keyA = resolver.publicSigningKey(b0.nodeId)
            assertNotNull(keyA)

            // Step B: Quarantined
            repo.applyValidatedBinding(b5)
            assertNull(resolver.publicSigningKey(b0.nodeId))

            // Step C: Approved
            repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
            val keyC = resolver.publicSigningKey(b0.nodeId)
            assertNotNull(keyC)
            assertArrayEquals(keyA, keyC)

            // Step D: Revoked
            repo.revokePeer(b0.nodeId)
            assertNull(resolver.publicSigningKey(b0.nodeId))
        }
    }

    @Test
    fun testBoundResolver_DefensiveCopy() {
        val file = tempFolder.newFile("defensive_copy.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b0)

            val key1 = resolver.publicSigningKey(b0.nodeId)!!
            key1[0] = (key1[0].toInt() xor 0xFF).toByte()

            val key2 = resolver.publicSigningKey(b0.nodeId)!!
            assertArrayEquals(b0.signingPublicKey, key2)
            assertFalse(key1.contentEquals(key2))
        }
    }

    @Test
    fun testBoundResolver_ConcurrentRevoke_NoStalePostCommitKey() {
        val file = tempFolder.newFile("concurrent_revoke.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            repo.applyValidatedBinding(b0)

            val executor = Executors.newFixedThreadPool(2)
            try {
                val f1 = executor.submit(Callable { resolver.publicSigningKey(b0.nodeId) })
                val f2 = executor.submit(Callable { repo.revokePeer(b0.nodeId) })

                val r1 = f1.get()
                val r2 = f2.get()
                // r1 could be either key or null depending on interleaving
                if (r1 != null) {
                    assertArrayEquals(b0.signingPublicKey, r1)
                }

                // After both complete, any new resolution MUST be null
                val postRevokeKey = resolver.publicSigningKey(b0.nodeId)
                assertNull("Post-commit resolution must be null", postRevokeKey)
            } finally {
                executor.shutdown()
            }
        }
    }

    @Test
    fun testBoundResolver_AckIntegrationLifecycle() {
        val file = tempFolder.newFile("ack_integration.db").also { it.delete() }
        JdbcPeerIdentityStore(file).use { store ->
            val repo = PeerIdentityRepository(store)
            val resolver = BoundRecipientKeyResolver(repo)
            val authenticator = Ed25519AckAuthenticator(resolver)

            val b0 = makeBinding(seedA, 0L, staticPrivA)
            val b5 = makeBinding(seedA, 5L, staticPrivB)
            val msgId = ByteArray(16) { 0x55.toByte() }
            val routingTag = ByteArray(4) { 0x12.toByte() }

            // Step A1: Active TOFU verified ACK succeeds
            repo.applyValidatedBinding(b0)
            val ackFrame = AckFrame.build(msgId, seedA, b0.nodeId, routingTag)
            assertTrue("Active TOFU ACK must verify", authenticator.verify(msgId, b0.nodeId, ackFrame))

            // Step A2: Quarantine blocks ACK verification
            repo.applyValidatedBinding(b5)
            assertFalse("Quarantined peer ACK must fail verification", authenticator.verify(msgId, b0.nodeId, ackFrame))

            // Step A3: Approval restores ACK verification
            repo.approvePendingRotation(b0.nodeId, 5L, b5.staticDhPublicKey)
            assertTrue("Approved peer ACK must verify", authenticator.verify(msgId, b0.nodeId, ackFrame))

            // Step A4: Revocation permanently blocks ACK verification
            repo.revokePeer(b0.nodeId)
            assertFalse("Revoked peer ACK must fail verification", authenticator.verify(msgId, b0.nodeId, ackFrame))

            // Negative controls
            val wrongRecipient = ByteArray(16) { 0xAA.toByte() }
            val wrongMsgId = ByteArray(16) { 0xBB.toByte() }
            val tamperedPayload = ackFrame.payload.copyOf().also { it[0] = (it[0].toInt() xor 0xFF).toByte() }
            val tamperedAck = FrameV2(
                type = TypeV2.ACK,
                msgId = msgId,
                routingTag = routingTag,
                ttl = 4,
                hopCount = 0,
                flags = 0,
                payload = tamperedPayload
            )

            assertFalse("Wrong expected recipient must fail", authenticator.verify(msgId, wrongRecipient, ackFrame))
            assertFalse("Wrong msgId must fail", authenticator.verify(wrongMsgId, b0.nodeId, ackFrame))
            assertFalse("Tampered signature must fail", authenticator.verify(msgId, b0.nodeId, tamperedAck))
            assertFalse("Unseen recipient must fail", authenticator.verify(msgId, wrongRecipient, ackFrame))
        }
    }

    @Test
    fun testBoundResolver_ReadOnlyAdapter_SingleLookupCall() {
        var lookupCount = 0
        val fakeSource = PeerIdentityLookupSource {
            lookupCount++
            PeerIdentityLookup.NotFound
        }
        val resolver = BoundRecipientKeyResolver(fakeSource)

        val validNode = ByteArray(16) { 0x01 }
        val invalidNode = ByteArray(10)

        assertEquals(0, lookupCount)

        resolver.publicSigningKey(validNode)
        assertEquals(1, lookupCount)

        resolver.publicSigningKey(invalidNode)
        assertEquals(1, lookupCount) // No extra call for invalid node id
    }
}
