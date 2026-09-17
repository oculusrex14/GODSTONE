package io.godstone.mesh.crypto

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityBindingValidator
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.PeerTrustRejectReason
import io.godstone.mesh.identity.ValidatedPeerBinding
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom

class SessionManagerTest {

    private fun randomPeerId(): ByteArray = ByteArray(16).also { SecureRandom().nextBytes(it) }

    private class RecordingTrustAuthority(
        var resultToReturn: PeerTrustApplyResult = PeerTrustApplyResult.Accepted
    ) : PeerBindingTrustAuthority {
        var applyCount = 0
        var lastBinding: ValidatedPeerBinding? = null

        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            applyCount++
            lastBinding = binding
            return resultToReturn
        }
    }

    @Test
    fun testSessionManager_InitiatorStart_Returns32ByteHs1() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val smA = SessionManager(identityA, trustA)
        val peerB = identityB.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)
        assertNotNull(hs1)
        assertEquals(32, hs1!!.size)
        assertFalse(smA.isReady(peerB))
    }

    @Test
    fun testSessionManager_ResponderProcessHs1_Returns229ByteHs2() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val trustB = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)

        assertNotNull(hs2)
        assertEquals(229, hs2!!.size)
        assertFalse(smB.isReady(peerA))
    }

    @Test
    fun testSessionManager_InitiatorProcessHs2_Emits197ByteHs3_AndReachesReady() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val trustB = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!

        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)
        assertNotNull(hs3)
        assertEquals(197, hs3!!.size)
        assertTrue(smA.isReady(peerB))
        assertEquals(1, trustA.applyCount)
    }

    @Test
    fun testSessionManager_ResponderProcessHs3_ReachesReady() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val trustB = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!

        val ready = smB.responderProcessHs3(peerA, hs3, identityA.nodeHint)
        assertTrue(ready)
        assertTrue(smB.isReady(peerA))
        assertEquals(1, trustB.applyCount)
    }

    @Test
    fun testSessionManager_SealAndOpen_RoundTripSucceedsOnlyWhenReady() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val trustB = RecordingTrustAuthority(PeerTrustApplyResult.Accepted)
        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!
        val okB = smB.responderProcessHs3(peerA, hs3, identityA.nodeHint)
        assertTrue(okB)

        val payload = "Hello secure mesh runtime".toByteArray(Charsets.UTF_8)
        val cipherAtoB = smA.seal(peerB, payload)
        assertNotNull(cipherAtoB)

        val plainB = smB.open(peerA, cipherAtoB!!)
        assertNotNull(plainB)
        assertArrayEquals(payload, plainB)

        val reply = "Reply from B".toByteArray(Charsets.UTF_8)
        val cipherBtoA = smB.seal(peerA, reply)
        assertNotNull(cipherBtoA)

        val plainA = smA.open(peerB, cipherBtoA!!)
        assertNotNull(plainA)
        assertArrayEquals(reply, plainA)
    }

    @Test
    fun testSessionManager_SealBeforeReady_ReturnsNull() {
        val identityA = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority())
        val peerB = randomPeerId()

        assertNull(smA.seal(peerB, "cleartext".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun testSessionManager_OpenBeforeReady_ReturnsNull() {
        val identityA = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority())
        val peerB = randomPeerId()

        assertNull(smA.open(peerB, "ciphertext".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun testSessionManager_QuarantinedHandshake_NeverReachesReady_SealFails() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority(PeerTrustApplyResult.KeyChangedQuarantined)
        val trustB = RecordingTrustAuthority(PeerTrustApplyResult.KeyChangedQuarantined)
        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!

        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)
        assertNull(hs3)
        assertFalse(smA.isReady(peerB))
        assertNull(smA.seal(peerB, "data".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun testSessionManager_RejectedHandshake_NeverReachesReady_SealFails() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority(PeerTrustApplyResult.Rejected(PeerTrustRejectReason.Rollback))
        val smA = SessionManager(identityA, trustA)
        val peerB = identityB.nodeId

        val smB = SessionManager(identityB, RecordingTrustAuthority())
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!

        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)
        assertNull(hs3)
        assertFalse(smA.isReady(peerB))
        assertNull(smA.seal(peerB, "data".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun testSessionManager_DropPeer_CleansUpController_SealFails() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val smB = SessionManager(identityB, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!
        smB.responderProcessHs3(peerA, hs3, identityA.nodeHint)

        assertTrue(smA.isReady(peerB))
        smA.drop(peerB)
        assertFalse(smA.isReady(peerB))
        assertNull(smA.seal(peerB, "data".toByteArray(Charsets.UTF_8)))
    }

    @Test
    fun testSessionManager_DestroyAll_DestroysAllControllers() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val smB = SessionManager(identityB, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!

        assertTrue(smA.isReady(peerB))
        smA.destroyAll()
        assertFalse(smA.isReady(peerB))
    }

    @Test
    fun testSessionManager_InvalidateForWipe_PermanentlyRefusesNewAndExistingSessions() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val gate = DefaultRuntimeLifecycleGate()
        val smA = SessionManager(identityA, RecordingTrustAuthority(PeerTrustApplyResult.Accepted), lifecycleGate = gate)
        val smB = SessionManager(identityB, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))

        val peerB = identityB.nodeId
        val peerA = identityA.nodeId

        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!
        assertTrue(smA.isReady(peerB))

        smA.invalidateForWipe()
        assertTrue(smA.isInvalidated)
        assertFalse(smA.isActive)
        assertFalse(smA.isReady(peerB))
        assertNull(smA.seal(peerB, "data".toByteArray(Charsets.UTF_8)))
        assertNull(smA.open(peerB, "data".toByteArray(Charsets.UTF_8)))

        // Refuses new sessions
        assertNull(smA.initiatorStart(randomPeerId(), ByteArray(4)))
        assertNull(smA.responderProcessHs1(randomPeerId(), ByteArray(4), ByteArray(32)))
    }

    /**
     * CRYPTO-002, MIRRORED FROM THE iOS ISLE'S CANONICAL SUITE -- the audit's own two probes by name:
     * `AuditCryptoTests.testExpiredReadMustReachManagerAndClearReadiness` and
     * `testIdleExpiredSessionMustNotStillPublishReady`. The audit's evidence class sayeth WHY the existing courts
     * missed it: "ReadinessT07Tests acts directly on raw NoiseSession ... It does not exercise trusted controller,
     * manager, transport close/publication or idle timer ownership." SO THESE PROBES ACT ON THE MANAGER.
     *
     * NOTE ON THIS ISLE'S ASSERTION ORDER, WRITTEN DOWN BECAUSE IT COST A ROUND: **JUNIT TAKES (message, condition) --
     * THE REVERSE OF XCTEST'S (condition, message).** The compiler refused it in three lines, twice.
     */
    @Test
    fun crypto002AnAgedReadMustRetireThroughTheManagerAndClearReadiness() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val smB = SessionManager(identityB, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val peerB = identityB.nodeId
        val peerA = identityA.nodeId
        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!
        assertTrue("the handshake completes", smB.responderProcessHs3(peerA, hs3, identityA.nodeHint))
        assertTrue("the control: a completed handshake IS ready", smB.isReady(peerA))
        val before = smB.slotCountForTest()

        // AGE THE RECEIVER'S PRIMITIVE past its own budget: one second of budget, established two seconds ago.
        val ctrl = smB.slotForTest(peerA)!!.controller!!
        ctrl.noiseSession.ageBudgetForTest = 1L
        ctrl.noiseSession.establishedMonoForTest = System.nanoTime() - 2_000_000_000L

        val genuine = smA.seal(peerB, "a genuine in-policy packet".toByteArray(Charsets.UTF_8))!!
        assertEquals(
            "AGE IS A TERMINAL RETIREMENT, NOT A PACKET REJECTION -- the vocabulary existeth and is unreachable",
            NoiseSession.CryptoOpenResult.Expired, smB.openWithResult(peerA, genuine),
        )
        assertFalse(
            "and readiness must STOP: a session past its budget may not stay published as ready",
            smB.isReady(peerA),
        )
        assertEquals("and the EXACT slot must be gone (it was $before) -- else a slot leak", 0, smB.slotCountForTest())
    }

    @Test
    fun crypto002AnIdleAgedSessionMustNotStillPublishReady() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val smB = SessionManager(identityB, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val peerB = identityB.nodeId
        val peerA = identityA.nodeId
        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!
        assertTrue("the handshake completes", smB.responderProcessHs3(peerA, hs3, identityA.nodeHint))

        val ctrl = smB.slotForTest(peerA)!!.controller!!
        ctrl.noiseSession.ageBudgetForTest = 1L
        ctrl.noiseSession.establishedMonoForTest = System.nanoTime() - 2_000_000_000L
        assertFalse(
            "an IDLE expired session must not still publish ready -- NO PACKET SHOULD BE REQUIRED",
            smB.isReady(peerA),
        )
    }
}
