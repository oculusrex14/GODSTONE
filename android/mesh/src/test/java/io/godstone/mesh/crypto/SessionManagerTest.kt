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

    /**
     * CRYPTO-002 STEP 4 ON THIS ISLE: "Arm an IMMUTABLE RELATION-OWNED AGE TIMER at trusted establishment. Idle expiry
     * must enter the same slot transition; OLD TIMER CALLBACKS CANNOT RETIRE A REPLACEMENT."
     *
     * ITS HONEST STATUS: a CONTROL for the machinery landed in the same round (as the iOS isle's timer arms were at
     * round 352) -- an arm that cannot be red proves the law still holds, not that it was ever broken.
     */
    @Test
    fun crypto002AnAgeTimerIsArmedAtEstablishmentAndItsFiringCannotTouchASuccessor() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val smB = SessionManager(identityB, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        var fired: (() -> Unit)? = null
        var firedAdmission: RelationKey? = null
        smB.scheduleAgeDeadline = { admission, _, f -> firedAdmission = admission; fired = f }
        val peerB = identityB.nodeId
        val peerA = identityA.nodeId
        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!
        assertTrue("the handshake completes", smB.responderProcessHs3(peerA, hs3, identityA.nodeHint))

        // THE TIMER MUST EXIST, AND IT MUST HAVE REACHED WHOEVER OWNETH THE RUN LOOP.
        assertEquals("EXACTLY ONE AGE TIMER, ARMED AT TRUSTED ESTABLISHMENT", 1, smB.armedAgeDeadlinesForTest().size)
        assertNotNull("and the armed deadline must reach the scheduler that owneth the run loop", fired)
        assertTrue("the control: nothing has expired yet", smB.isReady(peerA))

        // FIRE IT: it must enter THE SAME SLOT TRANSITION the read path entereth.
        fired!!.invoke()
        assertFalse("the fired deadline must retire the session", smB.isReady(peerA))
        assertEquals("and release the exact slot", 0, smB.slotCountForTest())

        // *** THE OLD-CALLBACK CLAUSE: a LATE callback findeth no such incarnation and retireth NOTHING. This is why
        // the callback carrieth the EXACT admission rather than a peer. ***
        val stale = firedAdmission!!
        assertNull("the incarnation is gone, so the old token matches nothing", smB.slotForTest(peerA))
        smB.fireAgeDeadline(stale)
        assertEquals("an OLD callback leaveth the world exactly as it found it", 0, smB.slotCountForTest())
    }

    // MARK: - CRYPTO-002's REQUIRED CLOSURE CLAUSES ON THIS ISLE (the twins of the iOS isle's)

    /**
     * The audit's clause: "EXACT AGE/COUNT BOUNDARIES ... retire correctly". Run through the REAL manager, pinning the
     * boundary's side: the limit BELONGETH to the retirement.
     *
     * ITS HONEST STATUS: a CONTROL for the repair landed earlier (the defect it guards was closed by that repair), and
     * an arm that cannot be red proves the law still holds -- written because the audit LISTS it as a required closure
     * test, and a clause never exercised is a clause nobody can trust.
     */
    @Test
    fun crypto002TheRecordBudgetRetirethAtItsBoundaryThroughTheManager() {
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
        ctrl.noiseSession.recordBudgetForTest = 2

        for (i in 0 until 2) {
            val cipher = smA.seal(peerB, "record $i".toByteArray(Charsets.UTF_8))!!
            assertTrue(
                "record $i must authenticate: the budget is 2 and only $i preceded it",
                smB.openWithResult(peerA, cipher) is NoiseSession.CryptoOpenResult.Authenticated,
            )
        }
        assertTrue("the budget's LAST permitted record doth not retire the session", smB.isReady(peerA))

        val beyond = smA.seal(peerB, "beyond the budget".toByteArray(Charsets.UTF_8))!!
        assertEquals(
            "the RECORD BUDGET's boundary belongeth to the retirement -- a TERMINAL answer, not a rejection",
            NoiseSession.CryptoOpenResult.Expired, smB.openWithResult(peerA, beyond),
        )
        assertFalse("and readiness stoppeth with it", smB.isReady(peerA))
        assertEquals("and the exact slot is released", 0, smB.slotCountForTest())
    }


    /**
     * The audit's clause: "ASYMMETRIC DIRECTIONAL TRAFFIC retireth correctly" -- the direction that mattereth most is
     * the one an attacker controlleth: A's inbound traffic must NOT consume B's outbound budget, OR A TALKATIVE (OR
     * HOSTILE) PEER COULD SILENCE ITS NEIGHBOUR BY MERELY TALKING.
     *
     * *** A CORRECTION CARRIED IN THE ARM ITSELF, BECAUSE THE FIRST VERSION OF IT CLAIMED A DEFECT THAT DID NOT EXIST:
     * the first draft ended with `smB.seal(peerB, ...)`, WHILE `peerB` IS **B's OWN NODE ID** -- so B asked for a
     * session keyed by ITSELF, received null, and the arm reported "a talkative peer silences its neighbour" AGAINST A
     * PRODUCTION THAT WAS INNOCENT. Each manager's key is ITS OWN name for the relation (`peerA` for smB), and the
     * primitive's counters were then READ to settle it: `messageCount` is incremented ONLY by `encrypt` and checked
     * ONLY by `enforceSendBudget`, while `receiveCount` incremented by the receive path and checked only by
     * `enforceReceiveBudget` -- THE DIRECTIONS NEVER SHARED A COUNTER. ***
     */
    @Test
    fun crypto002InboundTrafficDoesNotConsumeTheOutboundBudget() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val smA = SessionManager(identityA, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val smB = SessionManager(identityB, RecordingTrustAuthority(PeerTrustApplyResult.Accepted))
        val peerB = identityB.nodeId      // SM-A's name for the relation
        val peerA = identityA.nodeId      // SM-B's name for it
        val hs1 = smA.initiatorStart(peerB, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(peerA, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(peerB, hs2, identityB.nodeHint)!!
        assertTrue("the handshake completes", smB.responderProcessHs3(peerA, hs3, identityA.nodeHint))
        val ctrlB = smB.slotForTest(peerA)!!.controller!!
        ctrlB.noiseSession.recordBudgetForTest = 3

        for (i in 0 until 2) {
            val cipher = smA.seal(peerB, "in $i".toByteArray(Charsets.UTF_8))!!
            assertTrue(
                "A's record $i must authenticate",
                smB.openWithResult(peerA, cipher) is NoiseSession.CryptoOpenResult.Authenticated,
            )
        }
        for (i in 0 until 3) {
            assertNotNull(
                "INBOUND traffic must not consume the OUTBOUND budget -- else a talkative peer could silence its " +
                    "neighbour by merely talking (record $i of 3)",
                smB.seal(peerA, "out $i".toByteArray(Charsets.UTF_8)),
            )
        }
    }
}
