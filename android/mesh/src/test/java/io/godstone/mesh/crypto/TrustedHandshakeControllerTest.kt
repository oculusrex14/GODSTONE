package io.godstone.mesh.crypto

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityBindingV1
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.IdentityStorage
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.identity.LegacyIdentityMaterial
import io.godstone.mesh.identity.LocalIdentityStateV1
import io.godstone.mesh.identity.PeerIdentityLookup
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.PeerTrustLevel
import io.godstone.mesh.identity.PeerTrustRejectReason
import io.godstone.mesh.identity.PeerTrustRepositoryCorruptionReason
import io.godstone.mesh.identity.RotationApprovalResult
import io.godstone.mesh.identity.ValidatedPeerBinding
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
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.sql.SQLException

class TrustedHandshakeControllerTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private class CountingTrustAuthority(
        private val delegate: PeerBindingTrustAuthority
    ) : PeerBindingTrustAuthority {
        var applyCalls = 0
        var lastBinding: ValidatedPeerBinding? = null

        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            applyCalls++
            lastBinding = binding
            return delegate.applyValidatedBinding(binding)
        }
    }

    private class InMemoryIdentityStorage : IdentityStorage {
        var v1State: ByteArray? = null

        override fun readV1State(): ByteArray? = v1State?.copyOf()
        override fun readLegacyMaterial(): LegacyIdentityMaterial? = null
        override fun hasPartialLegacy(): Boolean = false
        override fun writeV1State(state: ByteArray): Boolean {
            v1State = state.copyOf()
            return true
        }
        override fun migrateLegacyToV1(state: ByteArray): Boolean {
            v1State = state.copyOf()
            return true
        }
        override fun clear(): Boolean {
            v1State = null
            return true
        }
    }

    private fun createIdentity(seedByte: Byte, staticPrivByte: Byte, generation: Long = 0L): Identity {
        val signPriv = ByteArray(32) { seedByte }
        val staticDhPriv = ByteArray(32) { staticPrivByte }
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(generation, signPriv, staticDhPriv).encode()
        }
        return Identity.loadOrCreate(storage)
    }

    private fun createTestBinding(
        identity: Identity,
        signingPriv: ByteArray,
        generation: Long = identity.bindingGeneration,
        staticDhPub: ByteArray = identity.staticDhPub
    ): IdentityBindingV1 {
        val signPub = Ed25519Keys.publicKeyFromPrivate(signingPriv)
        val preimage = IdentityBindingV1.signaturePreimage(
            generation = generation,
            signingPublicKey = signPub,
            staticDhPublicKey = staticDhPub
        )
        val sig = Ed25519Keys.sign(preimage, signingPriv)
        return IdentityBindingV1.create(
            generation = generation,
            signingPublicKey = signPub,
            staticDhPublicKey = staticDhPub,
            signature = sig
        )
    }

    @Test
    fun testTrustedHandshake_H_A01_FullFirstSeenHandshake_SucceedsAndReachesReady() {
        val fileA = tempFolder.newFile("h_a01_a.db").also { it.delete() }
        val fileB = tempFolder.newFile("h_a01_b.db").also { it.delete() }

        JdbcPeerIdentityStore(fileA).use { storeA ->
            JdbcPeerIdentityStore(fileB).use { storeB ->
                val repoA = PeerIdentityRepository(storeA)
                val repoB = PeerIdentityRepository(storeB)

                val aliceId = createIdentity(0x11, 0x22)
                val bobId = createIdentity(0x33, 0x44)

                val aliceAuth = CountingTrustAuthority(RepositoryPeerBindingTrustAuthority(repoA))
                val bobAuth = CountingTrustAuthority(RepositoryPeerBindingTrustAuthority(repoB))

                val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, aliceAuth)
                val bob = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, bobAuth)

                // Step 1: Alice writes HS1 (32 bytes)
                val hs1 = alice.initiatorWriteMessage1()
                assertEquals(32, hs1.size)
                assertEquals(HandshakeTrustState.HANDSHAKE_IN_PROGRESS, alice.state)

                // Step 2: Bob reads HS1, issues local binding, writes HS2 (229 bytes)
                val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)
                assertNotNull(hs2)
                assertEquals(229, hs2!!.size)
                assertEquals(HandshakeTrustState.HANDSHAKE_IN_PROGRESS, bob.state)

                // Step 3: Alice reads HS2, validates Bob, writes HS3 (197 bytes)
                val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
                assertNotNull(hs3)
                assertEquals(197, hs3!!.size)
                assertEquals(HandshakeTrustState.READY, alice.state)
                assertTrue(alice.isReady)
                assertEquals(1, aliceAuth.applyCalls)

                // Timing check: Alice has Bob's remote static immediately after HS2
                assertNotNull(alice.authenticatedRemoteStaticKey)
                assertArrayEquals(bobId.staticDhPub, alice.authenticatedRemoteStaticKey)

                // Step 4: Bob reads HS3, validates Alice, advances to READY
                val bobReady = bob.responderProcessMessage3(hs3, aliceId.nodeHint)
                assertTrue(bobReady)
                assertEquals(HandshakeTrustState.READY, bob.state)
                assertTrue(bob.isReady)
                assertEquals(1, bobAuth.applyCalls)
                assertNotNull(bob.authenticatedRemoteStaticKey)
                assertArrayEquals(aliceId.staticDhPub, bob.authenticatedRemoteStaticKey)

                // Verify durable rows are TOFU_PINNED (code 1)
                val aliceLookup = repoA.lookup(bobId.nodeId)
                assertTrue(aliceLookup is PeerIdentityLookup.Verified)
                assertEquals(PeerTrustLevel.TOFU_PINNED, (aliceLookup as PeerIdentityLookup.Verified).identity.trustLevel)

                val bobLookup = repoB.lookup(aliceId.nodeId)
                assertTrue(bobLookup is PeerIdentityLookup.Verified)
                assertEquals(PeerTrustLevel.TOFU_PINNED, (bobLookup as PeerIdentityLookup.Verified).identity.trustLevel)
            }
        }
    }

    @Test
    fun testTrustedHandshake_H_A02_RepeatHandshake_AcceptedAndReachesReady() {
        val fileA = tempFolder.newFile("h_a02_a.db").also { it.delete() }
        val fileB = tempFolder.newFile("h_a02_b.db").also { it.delete() }

        JdbcPeerIdentityStore(fileA).use { storeA ->
            JdbcPeerIdentityStore(fileB).use { storeB ->
                val repoA = PeerIdentityRepository(storeA)
                val repoB = PeerIdentityRepository(storeB)

                val aliceId = createIdentity(0x11, 0x22)
                val bobId = createIdentity(0x33, 0x44)

                // Pre-populate TOFU
                repoA.applyValidatedBinding(createTestBinding(bobId, ByteArray(32) { 0x33 }).let {
                    val v = IdentityBindingValidator.validate(it.encode(), bobId.staticDhPub, bobId.nodeHint)
                    (v as IdentityBindingValidationResult.Valid).binding
                })
                repoB.applyValidatedBinding(createTestBinding(aliceId, ByteArray(32) { 0x11 }).let {
                    val v = IdentityBindingValidator.validate(it.encode(), aliceId.staticDhPub, aliceId.nodeHint)
                    (v as IdentityBindingValidationResult.Valid).binding
                })

                val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, RepositoryPeerBindingTrustAuthority(repoA))
                val bob = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, RepositoryPeerBindingTrustAuthority(repoB))

                val hs1 = alice.initiatorWriteMessage1()
                val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)!!
                val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)!!
                val bobReady = bob.responderProcessMessage3(hs3, aliceId.nodeHint)

                assertTrue(alice.isReady)
                assertTrue(bobReady)
                assertTrue(bob.isReady)
            }
        }
    }

    @Test
    fun testTrustedHandshake_H_A03_HS2MalformedLength_FailsValidation_NoHS3_NotReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        var applyCount = 0
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                applyCount++
                return PeerTrustApplyResult.Accepted
            }
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = alice.initiatorWriteMessage1()
        bobNoise.readHandshakeMessage(hs1)

        // Bob encrypts a malformed 100-byte payload into HS2 (valid length is 133)
        val malformedPayload = ByteArray(100) { 0x55 }
        val hs2 = bobNoise.writeHandshakeMessage(malformedPayload)

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must not be emitted for malformed binding length", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertEquals(0, applyCount)
    }

    @Test
    fun testTrustedHandshake_H_A04_HS2UnsupportedVersion_FailsValidation_NoHS3_NotReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        var applyCount = 0
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                applyCount++
                return PeerTrustApplyResult.Accepted
            }
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = alice.initiatorWriteMessage1()
        bobNoise.readHandshakeMessage(hs1)

        // Legitimate binding modified to have version 2
        val validBinding = createTestBinding(bobId, ByteArray(32) { 0x33 }).encode()
        validBinding[0] = 0x02 // version = 2
        val hs2 = bobNoise.writeHandshakeMessage(validBinding)

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must not be emitted for unsupported binding version", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertEquals(0, applyCount)
    }

    @Test
    fun testTrustedHandshake_H_A05_HS2InvalidSignature_FailsValidation_NoHS3_NotReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        var applyCount = 0
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                applyCount++
                return PeerTrustApplyResult.Accepted
            }
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = alice.initiatorWriteMessage1()
        bobNoise.readHandshakeMessage(hs1)

        // Tamper signature byte in the plaintext binding
        val tamperedBinding = createTestBinding(bobId, ByteArray(32) { 0x33 }).encode()
        tamperedBinding[69] = (tamperedBinding[69].toInt() xor 0xFF).toByte()
        val hs2 = bobNoise.writeHandshakeMessage(tamperedBinding)

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must not be emitted for invalid Ed25519 signature", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertEquals(0, applyCount)
    }

    @Test
    fun testTrustedHandshake_H_A06_HS2StaticMismatch_FailsValidation_NoHS3_NotReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        var applyCount = 0
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                applyCount++
                return PeerTrustApplyResult.Accepted
            }
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = alice.initiatorWriteMessage1()
        bobNoise.readHandshakeMessage(hs1)

        // Bob signs a binding that advertises a different static key than the one in Bob's Noise session
        val otherStatic = ByteArray(32) { 0x99.toByte() }
        val mismatchBinding = createTestBinding(bobId, ByteArray(32) { 0x33 }, staticDhPub = otherStatic).encode()
        val hs2 = bobNoise.writeHandshakeMessage(mismatchBinding)

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must not be emitted when binding static != Noise remote static", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertEquals(0, applyCount)
    }

    @Test
    fun testTrustedHandshake_H_A07_HS2AdvertisementHintMismatch_FailsValidation_NoHS3_NotReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        var applyCount = 0
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                applyCount++
                return PeerTrustApplyResult.Accepted
            }
        }

        val wrongHint = ByteArray(4) { 0xFE.toByte() }
        // Both sides use wrongHint in prologue
        val alice = TrustedHandshakeController(
            NoiseSession.initiator(aliceId, aliceId.nodeHint, wrongHint),
            fakeAuth,
            aliceId
        )
        val bob = TrustedHandshakeController(
            NoiseSession.responder(bobId, wrongHint, aliceId.nodeHint),
            fakeAuth,
            bobId
        )

        val hs1 = alice.initiatorWriteMessage1()
        val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)!!

        // Alice passes expected advertisedHint = wrongHint. Bob's genuine binding has nodeHint != wrongHint.
        val hs3 = alice.initiatorProcessMessage2(hs2, wrongHint)
        assertNull("HS3 must not be emitted on node hint mismatch", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertEquals(0, applyCount)
    }

    @Test
    fun testTrustedHandshake_H_A08_HS2KeyChangedQuarantined_NoHS3_NotReady() {
        val fileA = tempFolder.newFile("h_a08_a.db").also { it.delete() }
        JdbcPeerIdentityStore(fileA).use { storeA ->
            val repoA = PeerIdentityRepository(storeA)
            val aliceId = createIdentity(0x11, 0x22)
            val bobId0 = createIdentity(0x33, 0x44)

            // Step 1: Alice pins Bob at gen 0
            val b0 = createTestBinding(bobId0, ByteArray(32) { 0x33 })
            val v0 = IdentityBindingValidator.validate(b0.encode(), bobId0.staticDhPub, bobId0.nodeHint)
            repoA.applyValidatedBinding((v0 as IdentityBindingValidationResult.Valid).binding)

            // Step 2: Bob presents gen 5 with new static key 0x77
            val bobId5 = createIdentity(0x33, 0x77, generation = 5L)
            val alice = TrustedHandshakeController.initiator(aliceId, bobId0.nodeHint, RepositoryPeerBindingTrustAuthority(repoA))
            val bobNoise = NoiseSession.responder(bobId5, aliceId.nodeHint, bobId0.nodeHint)

            val hs1 = alice.initiatorWriteMessage1()
            bobNoise.readHandshakeMessage(hs1)
            val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId5, ByteArray(32) { 0x33 }).encode())

            val hs3 = alice.initiatorProcessMessage2(hs2, bobId0.nodeHint)
            assertNull("HS3 must NOT be emitted for quarantined rotation candidate", hs3)
            assertEquals(HandshakeTrustState.QUARANTINED, alice.state)
            assertFalse(alice.isReady)

            // Verify quarantine row exists in store
            val lookup = repoA.lookup(bobId0.nodeId)
            assertTrue(lookup is PeerIdentityLookup.Quarantined)
            val q = lookup as PeerIdentityLookup.Quarantined
            assertEquals(5L, q.identity.pendingGeneration)
            assertArrayEquals(bobId5.staticDhPub, q.identity.pendingStaticDhPublicKey)
        }
    }

    @Test
    fun testTrustedHandshake_H_A09_HS2OldAcceptedReplayWhilePending_NoHS3_NotReady() {
        val fileA = tempFolder.newFile("h_a09_a.db").also { it.delete() }
        JdbcPeerIdentityStore(fileA).use { storeA ->
            val repoA = PeerIdentityRepository(storeA)
            val aliceId = createIdentity(0x11, 0x22)
            val bobId0 = createIdentity(0x33, 0x44)
            val bobId5 = createIdentity(0x33, 0x77, generation = 5L)

            // Pin gen 0 and add pending gen 5
            val b0 = createTestBinding(bobId0, ByteArray(32) { 0x33 })
            val v0 = IdentityBindingValidator.validate(b0.encode(), bobId0.staticDhPub, bobId0.nodeHint)
            repoA.applyValidatedBinding((v0 as IdentityBindingValidationResult.Valid).binding)

            val b5 = createTestBinding(bobId5, ByteArray(32) { 0x33 })
            val v5 = IdentityBindingValidator.validate(b5.encode(), bobId5.staticDhPub, bobId0.nodeHint)
            repoA.applyValidatedBinding((v5 as IdentityBindingValidationResult.Valid).binding)

            // Replay gen 0 handshake while pending exists
            val alice = TrustedHandshakeController.initiator(aliceId, bobId0.nodeHint, RepositoryPeerBindingTrustAuthority(repoA))
            val bobNoise0 = NoiseSession.responder(bobId0, aliceId.nodeHint, bobId0.nodeHint)

            val hs1 = alice.initiatorWriteMessage1()
            bobNoise0.readHandshakeMessage(hs1)
            val hs2 = bobNoise0.writeHandshakeMessage(createTestBinding(bobId0, ByteArray(32) { 0x33 }).encode())

            val hs3 = alice.initiatorProcessMessage2(hs2, bobId0.nodeHint)
            assertNull("HS3 must NOT be emitted for old accepted replay while pending", hs3)
            assertEquals(HandshakeTrustState.QUARANTINED, alice.state)
            assertFalse(alice.isReady)
        }
    }

    @Test
    fun testTrustedHandshake_H_A10_HS2RevokedResponder_Rejected_NoHS3_NotReady() {
        val fileA = tempFolder.newFile("h_a10_a.db").also { it.delete() }
        JdbcPeerIdentityStore(fileA).use { storeA ->
            val repoA = PeerIdentityRepository(storeA)
            val aliceId = createIdentity(0x11, 0x22)
            val bobId0 = createIdentity(0x33, 0x44)

            // Pin and revoke Bob
            val b0 = createTestBinding(bobId0, ByteArray(32) { 0x33 })
            val v0 = IdentityBindingValidator.validate(b0.encode(), bobId0.staticDhPub, bobId0.nodeHint)
            repoA.applyValidatedBinding((v0 as IdentityBindingValidationResult.Valid).binding)
            repoA.revokePeer(bobId0.nodeId)

            val alice = TrustedHandshakeController.initiator(aliceId, bobId0.nodeHint, RepositoryPeerBindingTrustAuthority(repoA))
            val bobNoise0 = NoiseSession.responder(bobId0, aliceId.nodeHint, bobId0.nodeHint)

            val hs1 = alice.initiatorWriteMessage1()
            bobNoise0.readHandshakeMessage(hs1)
            val hs2 = bobNoise0.writeHandshakeMessage(createTestBinding(bobId0, ByteArray(32) { 0x33 }).encode())

            val hs3 = alice.initiatorProcessMessage2(hs2, bobId0.nodeHint)
            assertNull("HS3 must not be emitted for revoked peer", hs3)
            assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
            assertFalse(alice.isReady)
        }
    }

    @Test
    fun testTrustedHandshake_H_A11_HS2RepositoryCorrupt_NoHS3_NotReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        val corruptAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Corrupt(PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("test corruption"))
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, corruptAuth)
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = alice.initiatorWriteMessage1()
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull(hs3)
        assertEquals(HandshakeTrustState.CORRUPT, alice.state)
        assertFalse(alice.isReady)
    }

    @Test
    fun testTrustedHandshake_H_A12_HS2RepositoryStorageFailure_NoHS3_NotReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        val storageFailureAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.StorageFailure(SQLException("Disk I/O error"))
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, storageFailureAuth)
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = alice.initiatorWriteMessage1()
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull(hs3)
        assertEquals(HandshakeTrustState.STORAGE_FAILURE, alice.state)
        assertFalse(alice.isReady)
    }

    @Test
    fun testTrustedHandshake_H_A13_ResponderHS3Quarantine_NoiseEstablished_ControllerNotReady_SealDenied() {
        val fileB = tempFolder.newFile("h_a13_b.db").also { it.delete() }
        JdbcPeerIdentityStore(fileB).use { storeB ->
            val repoB = PeerIdentityRepository(storeB)
            val aliceId0 = createIdentity(0x11, 0x22)
            val bobId = createIdentity(0x33, 0x44)

            // Bob pins Alice at gen 0
            val b0 = createTestBinding(aliceId0, ByteArray(32) { 0x11 })
            val v0 = IdentityBindingValidator.validate(b0.encode(), aliceId0.staticDhPub, aliceId0.nodeHint)
            repoB.applyValidatedBinding((v0 as IdentityBindingValidationResult.Valid).binding)

            // Alice rotates to gen 5 (new static 0x88)
            val aliceId5 = createIdentity(0x11, 0x88.toByte(), generation = 5L)
            val aliceNoise = NoiseSession.initiator(aliceId5, aliceId0.nodeHint, bobId.nodeHint)
            val bob = TrustedHandshakeController.responder(bobId, aliceId0.nodeHint, RepositoryPeerBindingTrustAuthority(repoB))

            val hs1 = aliceNoise.writeHandshakeMessage(ByteArray(0))
            val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)!!
            aliceNoise.readHandshakeMessage(hs2)

            val hs3 = aliceNoise.writeHandshakeMessage(createTestBinding(aliceId5, ByteArray(32) { 0x11 }).encode())

            // Bob processes HS3
            val ready = bob.responderProcessMessage3(hs3, aliceId0.nodeHint)
            assertFalse("Quarantined initiator binding must NOT make responder READY", ready)
            assertEquals(HandshakeTrustState.QUARANTINED, bob.state)
            assertFalse(bob.isReady)

            // Underlying Noise is established, BUT application seal/open MUST be denied
            assertTrue("Noise session is established cryptographically", bob.noiseSession.isEstablished)
            assertNull("Application seal must return null when not READY", bob.seal("secret".toByteArray()))
            val ciphertext = aliceNoise.encrypt("inbound".toByteArray())
            assertNull("Application open must return null when not READY", bob.open(ciphertext))
        }
    }

    @Test
    fun testTrustedHandshake_H_A14_ResponderHS3InvalidSignature_RepoApplyCountZero_NotReady_SealDenied() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        var applyCount = 0
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                applyCount++
                return PeerTrustApplyResult.Accepted
            }
        }

        val aliceNoise = NoiseSession.initiator(aliceId, aliceId.nodeHint, bobId.nodeHint)
        val bob = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, fakeAuth)

        val hs1 = aliceNoise.writeHandshakeMessage(ByteArray(0))
        val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)!!
        aliceNoise.readHandshakeMessage(hs2)

        // Alice encrypts tampered signature binding in HS3
        val tamperedBinding = createTestBinding(aliceId, ByteArray(32) { 0x11 }).encode()
        tamperedBinding[69] = (tamperedBinding[69].toInt() xor 0xFF).toByte()
        val hs3 = aliceNoise.writeHandshakeMessage(tamperedBinding)

        val ready = bob.responderProcessMessage3(hs3, aliceId.nodeHint)
        assertFalse(ready)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, bob.state)
        assertFalse(bob.isReady)
        assertEquals(0, applyCount)
        assertNull(bob.seal("test".toByteArray()))
    }

    @Test
    fun testTrustedHandshake_H_A15_SealOpenBeforeReady_ReturnsNull() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        assertEquals(HandshakeTrustState.INITIAL, alice.state)
        assertNull(alice.seal("test".toByteArray()))
        assertNull(alice.open(ByteArray(32)))

        alice.initiatorWriteMessage1()
        assertEquals(HandshakeTrustState.HANDSHAKE_IN_PROGRESS, alice.state)
        assertNull(alice.seal("test".toByteArray()))
        assertNull(alice.open(ByteArray(32)))
    }

    @Test
    fun testTrustedHandshake_H_A16_ApplicationTransportRoundTrip_AfterBothReady_Succeeds() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        val bob = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, fakeAuth)

        val hs1 = alice.initiatorWriteMessage1()
        val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)!!
        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)!!
        val bobReady = bob.responderProcessMessage3(hs3, aliceId.nodeHint)

        assertTrue(alice.isReady)
        assertTrue(bobReady)

        val plain1 = "hello from alice".toByteArray()
        val sealed1 = alice.seal(plain1)!!
        val opened1 = bob.open(sealed1)!!
        assertArrayEquals(plain1, opened1)

        val plain2 = "hello from bob".toByteArray()
        val sealed2 = bob.seal(plain2)!!
        val opened2 = alice.open(sealed2)!!
        assertArrayEquals(plain2, opened2)
    }

    @Test
    fun testTrustedHandshake_H_A17_PostApprovalHandshakeWithNewStatic_AcceptedAndReachesReady() {
        val fileA = tempFolder.newFile("h_a17_a.db").also { it.delete() }
        JdbcPeerIdentityStore(fileA).use { storeA ->
            val repoA = PeerIdentityRepository(storeA)
            val aliceId = createIdentity(0x11, 0x22)
            val bobId0 = createIdentity(0x33, 0x44)
            val bobId5 = createIdentity(0x33, 0x77, generation = 5L)

            // Pin gen 0 and quarantine gen 5
            val b0 = createTestBinding(bobId0, ByteArray(32) { 0x33 })
            val v0 = IdentityBindingValidator.validate(b0.encode(), bobId0.staticDhPub, bobId0.nodeHint)
            repoA.applyValidatedBinding((v0 as IdentityBindingValidationResult.Valid).binding)

            val b5 = createTestBinding(bobId5, ByteArray(32) { 0x33 })
            val v5 = IdentityBindingValidator.validate(b5.encode(), bobId5.staticDhPub, bobId0.nodeHint)
            repoA.applyValidatedBinding((v5 as IdentityBindingValidationResult.Valid).binding)

            // Approve candidate
            val approval = repoA.approvePendingRotation(bobId0.nodeId, 5L, bobId5.staticDhPub)
            assertTrue(approval is RotationApprovalResult.Approved)

            // New handshake using approved static 0x77
            val alice = TrustedHandshakeController.initiator(aliceId, bobId0.nodeHint, RepositoryPeerBindingTrustAuthority(repoA))
            val bobNoise5 = NoiseSession.responder(bobId5, aliceId.nodeHint, bobId0.nodeHint)

            val hs1 = alice.initiatorWriteMessage1()
            bobNoise5.readHandshakeMessage(hs1)
            val hs2 = bobNoise5.writeHandshakeMessage(createTestBinding(bobId5, ByteArray(32) { 0x33 }).encode())

            val hs3 = alice.initiatorProcessMessage2(hs2, bobId0.nodeHint)
            assertNotNull("HS3 must succeed after candidate approval", hs3)
            assertEquals(HandshakeTrustState.READY, alice.state)
            assertTrue(alice.isReady)
        }
    }

    @Test
    fun testTrustedHandshake_H_A18_HS1NonEmptyPayload_RejectedByResponder() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }

        val aliceNoise = NoiseSession.initiator(aliceId, aliceId.nodeHint, bobId.nodeHint)
        val bob = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, fakeAuth)

        // Alice puts non-empty payload in HS1
        val hs1 = aliceNoise.writeHandshakeMessage(byteArrayOf(0x01, 0x02))
        val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)

        assertNull("Responder must reject non-empty HS1 payload", hs2)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, bob.state)
        assertFalse(bob.isReady)
    }

    @Test
    fun testTrustedHandshake_H_A19_RemoteStaticTiming() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        val bob = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, fakeAuth)

        assertNull("Alice remote static is null initially", alice.authenticatedRemoteStaticKey)
        assertNull("Bob remote static is null initially", bob.authenticatedRemoteStaticKey)

        val hs1 = alice.initiatorWriteMessage1()
        val hs2 = bob.responderProcessMessage1AndWriteMessage2(hs1)!!

        // Responder after HS1: remote static MUST be null
        assertNull("Bob remote static MUST be null after HS1", bob.authenticatedRemoteStaticKey)

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)!!

        // Initiator after HS2: remote static MUST be Bob's static
        assertNotNull("Alice remote static MUST be non-null after HS2", alice.authenticatedRemoteStaticKey)
        assertArrayEquals(bobId.staticDhPub, alice.authenticatedRemoteStaticKey)

        bob.responderProcessMessage3(hs3, aliceId.nodeHint)

        // Responder after HS3: remote static MUST be Alice's static
        assertNotNull("Bob remote static MUST be non-null after HS3", bob.authenticatedRemoteStaticKey)
        assertArrayEquals(aliceId.staticDhPub, bob.authenticatedRemoteStaticKey)
    }

    @Test
    fun testHandshakeReadResult_DefensiveImmutability() {
        val payloadIn = ByteArray(32) { 0xAA.toByte() }
        val staticIn = ByteArray(32) { 0xBB.toByte() }

        val result = HandshakeReadResult(payloadIn, staticIn)

        // 1. Mutating constructor inputs does not affect stored value
        payloadIn[0] = 0x00
        staticIn[0] = 0x00
        assertEquals(0xAA.toByte(), result.payload[0])
        assertEquals(0xBB.toByte(), result.authenticatedRemoteStaticKey!![0])

        // 2. Mutating getter return value does not affect subsequent getter calls
        val payloadOut = result.payload
        payloadOut[0] = 0xFF.toByte()
        assertEquals(0xAA.toByte(), result.payload[0])

        val staticOut = result.authenticatedRemoteStaticKey!!
        staticOut[0] = 0xFF.toByte()
        assertEquals(0xBB.toByte(), result.authenticatedRemoteStaticKey!![0])
    }

    @Test
    fun testTrustedHandshake_H_A20_NoLocalBindingIssuedOnInitiatorValidationOrTrustFailure() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        data class FailureTestCase(
            val name: String,
            val authResult: PeerTrustApplyResult?,
            val bindingPayload: ByteArray,
            val wrongHint: ByteArray?,
            val expectedState: HandshakeTrustState
        )

        val validBinding = createTestBinding(bobId, ByteArray(32) { 0x33 }).encode()

        // Tampered signature binding
        val tamperedSigBinding = createTestBinding(bobId, ByteArray(32) { 0x33 }).encode().also {
            it[69] = (it[69].toInt() xor 0xFF).toByte()
        }

        // Static mismatch binding (signed with bobId, but claims different static DH key)
        val wrongStaticDh = ByteArray(32) { 0x99.toByte() }
        val mismatchStaticBinding = createTestBinding(bobId, ByteArray(32) { 0x33 }, staticDhPub = wrongStaticDh).encode()

        val failureCases = listOf(
            FailureTestCase("F1_InvalidSignature", null, tamperedSigBinding, null, HandshakeTrustState.SECURITY_REJECT),
            FailureTestCase("F2_StaticMismatch", null, mismatchStaticBinding, null, HandshakeTrustState.SECURITY_REJECT),
            FailureTestCase("F3_HintMismatch", null, validBinding, ByteArray(4) { 0xFE.toByte() }, HandshakeTrustState.SECURITY_REJECT),
            FailureTestCase("F4_KeyChangedQuarantined", PeerTrustApplyResult.KeyChangedQuarantined, validBinding, null, HandshakeTrustState.QUARANTINED),
            FailureTestCase("F5_RejectedRevoked", PeerTrustApplyResult.Rejected(PeerTrustRejectReason.Revoked), validBinding, null, HandshakeTrustState.SECURITY_REJECT),
            FailureTestCase("F6_Corrupt", PeerTrustApplyResult.Corrupt(PeerTrustRepositoryCorruptionReason.MutationReadbackMismatch("test")), validBinding, null, HandshakeTrustState.CORRUPT),
            FailureTestCase("F7_StorageFailure", PeerTrustApplyResult.StorageFailure(SQLException("disk error")), validBinding, null, HandshakeTrustState.STORAGE_FAILURE)
        )

        for (tc in failureCases) {
            var issuerCalls = 0
            var hs3WriterCalls = 0
            val mockIssuer = LocalBindingIssuer {
                issuerCalls++
                aliceId.issueIdentityBinding().encode()
            }
            val mockHs3Writer = Hs3Writer { payload ->
                hs3WriterCalls++
                ByteArray(197)
            }
            val fakeAuth = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                    tc.authResult ?: PeerTrustApplyResult.Accepted
            }

            val alice = TrustedHandshakeController.initiator(
                identity = aliceId,
                remoteHint = bobId.nodeHint,
                trustAuthority = fakeAuth,
                localBindingIssuer = mockIssuer,
                hs3Writer = mockHs3Writer
            )

            val hs1 = alice.initiatorWriteMessage1()
            val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
            bobNoise.readHandshakeMessage(hs1)
            val hs2 = bobNoise.writeHandshakeMessage(tc.bindingPayload)

            val hs3 = alice.initiatorProcessMessage2(
                hs2 = hs2,
                advertisedRemoteHint = tc.wrongHint ?: bobId.nodeHint
            )

            assertNull("HS3 must be null for ${tc.name}", hs3)
            assertEquals("State must match for ${tc.name}", tc.expectedState, alice.state)
            assertFalse("isReady must be false for ${tc.name}", alice.isReady)
            assertEquals("issuerCalls must be 0 for ${tc.name}", 0, issuerCalls)
            assertEquals("hs3WriterCalls must be 0 for ${tc.name}", 0, hs3WriterCalls)
            assertFalse("Noise session must not be established for ${tc.name}", alice.noiseSession.isEstablished)
        }

        // Positive case: Accepted -> exactly 1/1
        run {
            var issuerCalls = 0
            var hs3WriterCalls = 0
            val mockIssuer = LocalBindingIssuer {
                issuerCalls++
                aliceId.issueIdentityBinding().encode()
            }
            lateinit var alice: TrustedHandshakeController
            val mockHs3Writer = Hs3Writer { payload ->
                hs3WriterCalls++
                alice.noiseSession.writeHandshakeMessage(payload)
            }
            val fakeAuth = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                    PeerTrustApplyResult.Accepted
            }
            alice = TrustedHandshakeController.initiator(
                identity = aliceId,
                remoteHint = bobId.nodeHint,
                trustAuthority = fakeAuth,
                localBindingIssuer = mockIssuer,
                hs3Writer = mockHs3Writer
            )
            val hs1 = alice.initiatorWriteMessage1()
            val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
            bobNoise.readHandshakeMessage(hs1)
            val hs2 = bobNoise.writeHandshakeMessage(validBinding)
            val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
            assertNotNull(hs3)
            assertEquals(HandshakeTrustState.READY, alice.state)
            assertTrue(alice.isReady)
            assertEquals("issuerCalls must be 1 for Accepted", 1, issuerCalls)
            assertEquals("hs3WriterCalls must be 1 for Accepted", 1, hs3WriterCalls)
            assertTrue(alice.noiseSession.isEstablished)
        }

        // Positive case: FirstSeenPinned -> exactly 1/1
        run {
            var issuerCalls = 0
            var hs3WriterCalls = 0
            val mockIssuer = LocalBindingIssuer {
                issuerCalls++
                aliceId.issueIdentityBinding().encode()
            }
            lateinit var alice: TrustedHandshakeController
            val mockHs3Writer = Hs3Writer { payload ->
                hs3WriterCalls++
                alice.noiseSession.writeHandshakeMessage(payload)
            }
            val fakeAuth = object : PeerBindingTrustAuthority {
                override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                    PeerTrustApplyResult.FirstSeenPinned
            }
            alice = TrustedHandshakeController.initiator(
                identity = aliceId,
                remoteHint = bobId.nodeHint,
                trustAuthority = fakeAuth,
                localBindingIssuer = mockIssuer,
                hs3Writer = mockHs3Writer
            )
            val hs1 = alice.initiatorWriteMessage1()
            val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
            bobNoise.readHandshakeMessage(hs1)
            val hs2 = bobNoise.writeHandshakeMessage(validBinding)
            val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
            assertNotNull(hs3)
            assertEquals(HandshakeTrustState.READY, alice.state)
            assertTrue(alice.isReady)
            assertEquals("issuerCalls must be 1 for FirstSeenPinned", 1, issuerCalls)
            assertEquals("hs3WriterCalls must be 1 for FirstSeenPinned", 1, hs3WriterCalls)
            assertTrue(alice.noiseSession.isEstablished)
        }
    }

    @Test
    fun testResponder_NoiseEstablishedObservedDuringTrustApply_AcceptedAdvancesToReady() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        lateinit var bobController: TrustedHandshakeController
        var observedInCallback = false

        val observingAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                observedInCallback = true
                assertTrue("Noise session must be established during apply", bobController.noiseSession.isEstablished)
                assertEquals("Controller state must be NOISE_ESTABLISHED during apply", HandshakeTrustState.NOISE_ESTABLISHED, bobController.state)
                assertFalse("isReady must be false during apply", bobController.isReady)
                assertNull("seal must return null during NOISE_ESTABLISHED", bobController.seal(ByteArray(10)))
                assertNull("open must return null during NOISE_ESTABLISHED", bobController.open(ByteArray(10)))
                return PeerTrustApplyResult.Accepted
            }
        }

        bobController = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, observingAuth)
        val aliceNoise = NoiseSession.initiator(aliceId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = aliceNoise.writeHandshakeMessage()
        val hs2 = bobController.responderProcessMessage1AndWriteMessage2(hs1)!!
        aliceNoise.readHandshakeMessage(hs2)

        val aliceBinding = createTestBinding(aliceId, ByteArray(32) { 0x11 }).encode()
        val hs3 = aliceNoise.writeHandshakeMessage(aliceBinding)

        val ready = bobController.responderProcessMessage3(hs3, aliceId.nodeHint)
        assertTrue(ready)
        assertTrue("Callback must have executed", observedInCallback)
        assertEquals("Controller must advance to READY after Accepted", HandshakeTrustState.READY, bobController.state)
        assertTrue(bobController.isReady)
        assertNotNull(bobController.seal(ByteArray(10)))
    }

    @Test
    fun testResponder_NoiseEstablishedObservedDuringTrustApply_QuarantineDeniesReadyAndSeal() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)

        lateinit var bobController: TrustedHandshakeController
        var observedInCallback = false

        val observingAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                observedInCallback = true
                assertTrue("Noise session must be established during apply", bobController.noiseSession.isEstablished)
                assertEquals("Controller state must be NOISE_ESTABLISHED during apply", HandshakeTrustState.NOISE_ESTABLISHED, bobController.state)
                assertFalse("isReady must be false during apply", bobController.isReady)
                assertNull("seal must return null during NOISE_ESTABLISHED", bobController.seal(ByteArray(10)))
                return PeerTrustApplyResult.KeyChangedQuarantined
            }
        }

        bobController = TrustedHandshakeController.responder(bobId, aliceId.nodeHint, observingAuth)
        val aliceNoise = NoiseSession.initiator(aliceId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = aliceNoise.writeHandshakeMessage()
        val hs2 = bobController.responderProcessMessage1AndWriteMessage2(hs1)!!
        aliceNoise.readHandshakeMessage(hs2)

        val aliceBinding = createTestBinding(aliceId, ByteArray(32) { 0x11 }).encode()
        val hs3 = aliceNoise.writeHandshakeMessage(aliceBinding)

        val ready = bobController.responderProcessMessage3(hs3, aliceId.nodeHint)
        assertFalse(ready)
        assertTrue("Callback must have executed", observedInCallback)
        assertEquals("Controller must be QUARANTINED after quarantine", HandshakeTrustState.QUARANTINED, bobController.state)
        assertFalse(bobController.isReady)
        assertNull(bobController.seal(ByteArray(10)))
    }

    @Test
    fun testTrustedHandshake_TamperedHandshakeCiphertext_NoiseAuthFails_NoValidation_NoRepoApply() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        var applyCalls = 0
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
                applyCalls++
                return PeerTrustApplyResult.Accepted
            }
        }

        val alice = TrustedHandshakeController.initiator(aliceId, bobId.nodeHint, fakeAuth)
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)

        val hs1 = alice.initiatorWriteMessage1()
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        // Tamper ciphertext byte directly in HS2
        val tamperedHs2 = hs2.copyOf().also { it[100] = (it[100].toInt() xor 0xFF).toByte() }

        val hs3 = alice.initiatorProcessMessage2(tamperedHs2, bobId.nodeHint)
        assertNull("Tampered Noise ciphertext must fail authentication and return null", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertEquals(0, applyCalls)
    }

    // MARK: - A-HS3-FAIL Battery (C8.4A.2)

    @Test
    fun testInitiator_A_HS3_FAIL_01_WriterThrows_FailsClosed() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        var issuerCalls = 0
        var writerCalls = 0
        val mockIssuer = LocalBindingIssuer {
            issuerCalls++
            aliceId.issueIdentityBinding().encode()
        }
        val throwingWriter = Hs3Writer { payload ->
            writerCalls++
            throw RuntimeException("Simulated HS3 write failure")
        }
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }
        val alice = TrustedHandshakeController.initiator(
            identity = aliceId,
            remoteHint = bobId.nodeHint,
            trustAuthority = fakeAuth,
            localBindingIssuer = mockIssuer,
            hs3Writer = throwingWriter
        )
        val hs1 = alice.initiatorWriteMessage1()
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must be null when writer throws", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertFalse(alice.noiseSession.isEstablished)
        assertEquals(1, issuerCalls)
        assertEquals(1, writerCalls)
    }

    @Test
    fun testInitiator_A_HS3_FAIL_02_WriterReturnsWrongLength_NoNoiseWrite_FailsClosed() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        var issuerCalls = 0
        var writerCalls = 0
        val mockIssuer = LocalBindingIssuer {
            issuerCalls++
            aliceId.issueIdentityBinding().encode()
        }
        val shortWriter = Hs3Writer { payload ->
            writerCalls++
            ByteArray(196)
        }
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }
        val alice = TrustedHandshakeController.initiator(
            identity = aliceId,
            remoteHint = bobId.nodeHint,
            trustAuthority = fakeAuth,
            localBindingIssuer = mockIssuer,
            hs3Writer = shortWriter
        )
        val hs1 = alice.initiatorWriteMessage1()
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must be null when writer returns wrong length", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertFalse(alice.noiseSession.isEstablished)
        assertEquals(1, issuerCalls)
        assertEquals(1, writerCalls)
    }

    @Test
    fun testInitiator_A_HS3_FAIL_03_WriterReturns197FakeBytes_NoNoiseWrite_FailsClosed() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        var issuerCalls = 0
        var writerCalls = 0
        val mockIssuer = LocalBindingIssuer {
            issuerCalls++
            aliceId.issueIdentityBinding().encode()
        }
        val fake197Writer = Hs3Writer { payload ->
            writerCalls++
            ByteArray(197)
        }
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }
        val alice = TrustedHandshakeController.initiator(
            identity = aliceId,
            remoteHint = bobId.nodeHint,
            trustAuthority = fakeAuth,
            localBindingIssuer = mockIssuer,
            hs3Writer = fake197Writer
        )
        val hs1 = alice.initiatorWriteMessage1()
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must be null when writer returns 197 fake bytes without establishing Noise", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertFalse(alice.noiseSession.isEstablished)
        assertEquals(1, issuerCalls)
        assertEquals(1, writerCalls)
    }

    @Test
    fun testInitiator_A_HS3_FAIL_04_RealNoiseSplit_ThenMalformedReturnedLength_FailsClosed() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        var issuerCalls = 0
        var writerCalls = 0
        val mockIssuer = LocalBindingIssuer {
            issuerCalls++
            aliceId.issueIdentityBinding().encode()
        }
        lateinit var alice: TrustedHandshakeController
        val splitThenMalformedWriter = Hs3Writer { payload ->
            writerCalls++
            alice.noiseSession.writeHandshakeMessage(payload)
            ByteArray(196)
        }
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }
        alice = TrustedHandshakeController.initiator(
            identity = aliceId,
            remoteHint = bobId.nodeHint,
            trustAuthority = fakeAuth,
            localBindingIssuer = mockIssuer,
            hs3Writer = splitThenMalformedWriter
        )
        val hs1 = alice.initiatorWriteMessage1()
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must be null when returned length is malformed even if Noise split occurred", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertTrue("Noise session was split in mock", alice.noiseSession.isEstablished)
        assertEquals(1, issuerCalls)
        assertEquals(1, writerCalls)
    }

    @Test
    fun testInitiator_A_HS3_FAIL_05_IssuerThrows_FailsClosed() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        var issuerCalls = 0
        var writerCalls = 0
        val throwingIssuer = LocalBindingIssuer {
            issuerCalls++
            throw RuntimeException("Simulated local binding issuance failure")
        }
        val mockWriter = Hs3Writer { payload ->
            writerCalls++
            ByteArray(197)
        }
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }
        val alice = TrustedHandshakeController.initiator(
            identity = aliceId,
            remoteHint = bobId.nodeHint,
            trustAuthority = fakeAuth,
            localBindingIssuer = throwingIssuer,
            hs3Writer = mockWriter
        )
        val hs1 = alice.initiatorWriteMessage1()
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must be null when issuer throws", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertFalse(alice.noiseSession.isEstablished)
        assertEquals(1, issuerCalls)
        assertEquals(0, writerCalls)
    }

    @Test
    fun testInitiator_A_HS3_FAIL_06_IssuerReturnsNon133Bytes_FailsClosed() {
        val aliceId = createIdentity(0x11, 0x22)
        val bobId = createIdentity(0x33, 0x44)
        var issuerCalls = 0
        var writerCalls = 0
        val shortIssuer = LocalBindingIssuer {
            issuerCalls++
            ByteArray(132)
        }
        val mockWriter = Hs3Writer { payload ->
            writerCalls++
            ByteArray(197)
        }
        val fakeAuth = object : PeerBindingTrustAuthority {
            override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult =
                PeerTrustApplyResult.Accepted
        }
        val alice = TrustedHandshakeController.initiator(
            identity = aliceId,
            remoteHint = bobId.nodeHint,
            trustAuthority = fakeAuth,
            localBindingIssuer = shortIssuer,
            hs3Writer = mockWriter
        )
        val hs1 = alice.initiatorWriteMessage1()
        val bobNoise = NoiseSession.responder(bobId, aliceId.nodeHint, bobId.nodeHint)
        bobNoise.readHandshakeMessage(hs1)
        val hs2 = bobNoise.writeHandshakeMessage(createTestBinding(bobId, ByteArray(32) { 0x33 }).encode())

        val hs3 = alice.initiatorProcessMessage2(hs2, bobId.nodeHint)
        assertNull("HS3 must be null when issuer returns non-133 bytes", hs3)
        assertEquals(HandshakeTrustState.SECURITY_REJECT, alice.state)
        assertFalse(alice.isReady)
        assertFalse(alice.noiseSession.isEstablished)
        assertEquals(1, issuerCalls)
        assertEquals(0, writerCalls)
    }
}
