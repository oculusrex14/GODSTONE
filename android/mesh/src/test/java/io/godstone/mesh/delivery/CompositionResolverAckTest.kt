package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.crypto.RepositoryPeerBindingTrustAuthority
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.IdentityBindingV1
import io.godstone.mesh.identity.IdentityBindingValidationResult
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.JdbcPeerIdentityStore
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.PeerTrustLevel
import io.godstone.mesh.identity.RotationApprovalResult
import io.godstone.mesh.identity.RuntimeGatedPeerBindingTrustAuthority
import io.godstone.mesh.identity.RuntimeGatedPeerIdentityLookupSource
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.wire.v2.FrameV2
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.security.SecureRandom

class CompositionResolverAckTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    private val seedA = ByteArray(32) { 0x11 }
    private val staticPrivA = ByteArray(32) { 0x33 }
    private val staticPrivA2 = ByteArray(32) { 0x44 }

    private fun random16(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

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

    private fun setupRepository(): Triple<PeerIdentityRepository, BoundRecipientKeyResolver, JdbcPeerIdentityStore> {
        val file = tempFolder.newFile("comp_ack_${System.nanoTime()}.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(store)
        val gate = DefaultRuntimeLifecycleGate()
        val lookup = RuntimeGatedPeerIdentityLookupSource(RepositoryPeerIdentityLookupSource(repo), gate)
        val resolver = BoundRecipientKeyResolver(lookup)
        return Triple(repo, resolver, store)
    }

    @Test
    fun testComposition_ActiveTofuPeer_ResolvesSigningKey_AndValidAckSucceeds() {
        val (repo, resolver, _) = setupRepository()
        val binding = makeBinding(seedA, 0L, staticPrivA)

        val applyResult = repo.applyValidatedBinding(binding)
        assertTrue(applyResult is PeerTrustApplyResult.FirstSeenPinned)

        val resolvedPub = resolver.publicSigningKey(binding.nodeId)
        assertNotNull(resolvedPub)
        assertArrayEquals(binding.signingPublicKey, resolvedPub)

        val msgId = random16()
        val routingTag = binding.nodeId.copyOf(4)
        val ackFrame = AckFrame.build(msgId, seedA, binding.nodeId, routingTag)

        val auth = Ed25519AckAuthenticator(resolver)
        val valid = auth.verify(msgId, binding.nodeId, ackFrame)
        assertTrue(valid)
    }

    @Test
    fun testComposition_UserVerifiedPeer_ResolvesSigningKey_AndValidAckSucceeds() {
        val (repo, resolver, _) = setupRepository()
        val binding1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(binding1)

        val binding2 = makeBinding(seedA, 1L, staticPrivA2)
        repo.applyValidatedBinding(binding2)

        val approveResult = repo.approvePendingRotation(binding1.nodeId, 1L, binding2.staticDhPublicKey)
        assertTrue(approveResult is RotationApprovalResult.Approved)
        assertEquals(PeerTrustLevel.TOFU_PINNED, (approveResult as RotationApprovalResult.Approved).identity.trustLevel)

        val resolvedPub = resolver.publicSigningKey(binding1.nodeId)
        assertNotNull(resolvedPub)
        assertArrayEquals(binding1.signingPublicKey, resolvedPub)

        val msgId = random16()
        val routingTag = binding1.nodeId.copyOf(4)
        val ackFrame = AckFrame.build(msgId, seedA, binding1.nodeId, routingTag)

        val auth = Ed25519AckAuthenticator(resolver)
        val valid = auth.verify(msgId, binding1.nodeId, ackFrame)
        assertTrue(valid)
    }

    @Test
    fun testComposition_QuarantinedPeer_ResolverReturnsNull_AndAckFails() {
        val (repo, resolver, _) = setupRepository()
        val binding1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(binding1)

        // Rotate to generation 1 with new DH key but same signing key
        val binding2 = makeBinding(seedA, 1L, staticPrivA2)
        val applyResult = repo.applyValidatedBinding(binding2)
        assertTrue(applyResult is PeerTrustApplyResult.KeyChangedQuarantined)

        // Quarantined peer returns NULL from resolver
        val resolvedPub = resolver.publicSigningKey(binding1.nodeId)
        assertNull(resolvedPub)

        val msgId = random16()
        val routingTag = binding1.nodeId.copyOf(4)
        val ackFrame = AckFrame.build(msgId, seedA, binding1.nodeId, routingTag)

        val auth = Ed25519AckAuthenticator(resolver)
        val valid = auth.verify(msgId, binding1.nodeId, ackFrame)
        assertFalse(valid)
    }

    @Test
    fun testComposition_RevokedPeer_ResolverReturnsNull_AndAckFails() {
        val (repo, resolver, _) = setupRepository()
        val binding = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(binding)

        repo.revokePeer(binding.nodeId)

        val resolvedPub = resolver.publicSigningKey(binding.nodeId)
        assertNull(resolvedPub)

        val msgId = random16()
        val routingTag = binding.nodeId.copyOf(4)
        val ackFrame = AckFrame.build(msgId, seedA, binding.nodeId, routingTag)

        val auth = Ed25519AckAuthenticator(resolver)
        val valid = auth.verify(msgId, binding.nodeId, ackFrame)
        assertFalse(valid)
    }

    @Test
    fun testComposition_UnseenPeer_ResolverReturnsNull_AndAckFails() {
        val (_, resolver, _) = setupRepository()
        val signingPub = Ed25519Keys.publicKeyFromPrivate(seedA)
        val nodeId = IdentityBindingV1.deriveNodeId(signingPub)

        val resolvedPub = resolver.publicSigningKey(nodeId)
        assertNull(resolvedPub)

        val msgId = random16()
        val routingTag = nodeId.copyOf(4)
        val ackFrame = AckFrame.build(msgId, seedA, nodeId, routingTag)

        val auth = Ed25519AckAuthenticator(resolver)
        val valid = auth.verify(msgId, nodeId, ackFrame)
        assertFalse(valid)
    }

    @Test
    fun testComposition_ApprovedPendingRotation_RestoresAckResolution() {
        val (repo, resolver, _) = setupRepository()
        val binding1 = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(binding1)

        val binding2 = makeBinding(seedA, 1L, staticPrivA2)
        repo.applyValidatedBinding(binding2)

        assertNull(resolver.publicSigningKey(binding1.nodeId))

        // Approve rotation
        val approveResult = repo.approvePendingRotation(binding1.nodeId, 1L, binding2.staticDhPublicKey)
        assertTrue(approveResult is RotationApprovalResult.Approved)

        // Restored resolution
        val resolvedPub = resolver.publicSigningKey(binding1.nodeId)
        assertNotNull(resolvedPub)
        assertArrayEquals(binding1.signingPublicKey, resolvedPub)

        val msgId = random16()
        val routingTag = binding1.nodeId.copyOf(4)
        val ackFrame = AckFrame.build(msgId, seedA, binding1.nodeId, routingTag)

        val auth = Ed25519AckAuthenticator(resolver)
        assertTrue(auth.verify(msgId, binding1.nodeId, ackFrame))
    }

    @Test
    fun testComposition_TamperedAckSignature_FailsVerification() {
        val (repo, resolver, _) = setupRepository()
        val binding = makeBinding(seedA, 0L, staticPrivA)
        repo.applyValidatedBinding(binding)

        val msgId = random16()
        val routingTag = binding.nodeId.copyOf(4)
        val ackFrame = AckFrame.build(msgId, seedA, binding.nodeId, routingTag)

        // Tamper signature byte
        val tamperedPayload = ackFrame.payload.copyOf()
        tamperedPayload[0] = (tamperedPayload[0].toInt() xor 0xFF).toByte()

        val tamperedFrame = FrameV2(
            type = ackFrame.type,
            flags = ackFrame.flags,
            ttl = ackFrame.ttl,
            hopCount = ackFrame.hopCount,
            msgId = ackFrame.msgId,
            routingTag = ackFrame.routingTag,
            payload = tamperedPayload
        )

        val auth = Ed25519AckAuthenticator(resolver)
        val valid = auth.verify(msgId, binding.nodeId, tamperedFrame)
        assertFalse(valid)
    }

    @Test
    fun testComposition_SameRepositoryBacksResolverAndTrustAuthority() {
        val file = tempFolder.newFile("comp_same_${System.nanoTime()}.db").also { it.delete() }
        val store = JdbcPeerIdentityStore(file)
        val repo = PeerIdentityRepository(store)
        val gate = DefaultRuntimeLifecycleGate()
        val lookup = RuntimeGatedPeerIdentityLookupSource(RepositoryPeerIdentityLookupSource(repo), gate)
        val resolver = BoundRecipientKeyResolver(lookup)
        val trustAuthority = RuntimeGatedPeerBindingTrustAuthority(RepositoryPeerBindingTrustAuthority(repo), gate)

        val binding = makeBinding(seedA, 0L, staticPrivA)

        // Ingest via trustAuthority
        val applyResult = trustAuthority.applyValidatedBinding(binding)
        assertTrue(applyResult is PeerTrustApplyResult.FirstSeenPinned)

        // Query via resolver
        val resolvedKey = resolver.publicSigningKey(binding.nodeId)
        assertNotNull(resolvedKey)
        assertArrayEquals(binding.signingPublicKey, resolvedKey)
    }
}
