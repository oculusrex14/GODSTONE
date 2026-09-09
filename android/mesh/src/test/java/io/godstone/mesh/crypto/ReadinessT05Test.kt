package io.godstone.mesh.crypto

import io.godstone.mesh.MeshIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T05: commit Android replay state only after authentication.
 *
 * Regression targets: the previous path advanced the replay window BEFORE the
 * AEAD verification (so a forged far-future nonce poisoned the window and
 * every legitimate retransmission was then rejected as a replay) and narrowed
 * unchecked nonce differences to Int (so a 2^32+3 forward jump wrapped to 3).
 *
 * Every session-level case executes through [NoiseSession.openWithResult] -
 * the real session operation, not a lower-level driver.
 */
class ReadinessT05Test {

    private fun establishPair(): Pair<NoiseSession, NoiseSession> {
        val initiator = NoiseSession.initiator(MeshIdentity.generate())
        val responder = NoiseSession.responder(MeshIdentity.generate())
        // readHandshakeMessage returns the INCOMING payload; each side
        // writes its own next message explicitly.
        val hs1 = initiator.writeHandshakeMessage()
        responder.readHandshakeMessage(hs1)
        val hs2 = responder.writeHandshakeMessage()
        initiator.readHandshakeMessage(hs2)
        val hs3 = initiator.writeHandshakeMessage()
        responder.readHandshakeMessage(hs3)
        assertTrue(initiator.isEstablished)
        assertTrue(responder.isEstablished)
        return initiator to responder
    }

    private fun frame(session: NoiseSession, plaintext: String): ByteArray =
        session.encrypt(plaintext.toByteArray())

    private fun forged(nonce: Long): ByteArray {
        val bytes = ByteArray(8 + 16) // nonce || (empty plaintext + MAC)
        java.nio.ByteBuffer.wrap(bytes).putLong(0, nonce)
        return bytes
    }

    private fun corrupted(frame: ByteArray): ByteArray = frame.copyOf().also {
        it[it.size - 1] = (it[it.size - 1].toInt() xor 0x55).toByte()
    }

    @Test
    fun testForgedHighNonceThenValidFrame_SecondFrameStillAuthenticates() {
        val (sender, receiver) = establishPair()
        val frames = (0..8).map { frame(sender, "m$it") }
        for ((index, current) in frames.withIndex()) {
            val result = receiver.openWithResult(current)
            assertTrue("frame $index must authenticate",
                result is NoiseSession.CryptoOpenResult.Authenticated)
        }
        // A forged frame claiming a far-future nonce: the parser rejects the
        // reserved/out-of-policy region before any subtraction, the window
        // does not move, and nothing is committed.
        val outcome = receiver.openWithResult(forged(1L shl 40))
        assertTrue(outcome is NoiseSession.CryptoOpenResult.Expired ||
            outcome is NoiseSession.CryptoOpenResult.Rejected)
        // The next legitimate frame must still authenticate: the forged frame
        // mutated nothing ("forged-high-then-valid" must fail).
        assertTrue(receiver.openWithResult(frame(sender, "m9")) is
            NoiseSession.CryptoOpenResult.Authenticated)
    }

    @Test
    fun testForgedInPolicyNonce_AuthenticationFailureCommitsNothing() {
        val (sender, receiver) = establishPair()
        for (n in 0..4) {
            assertTrue(receiver.openWithResult(frame(sender, "m$n")) is
                NoiseSession.CryptoOpenResult.Authenticated)
        }
        // A forged frame inside the nonce policy but never legitimately sent:
        // preview may plan a shift, but AEAD fails and the commit must not run.
        // T07 moved the budget boundary to >= 2^20; forging at the last
        // in-budget nonce still exercises preview + AEAD failure.
        assertEquals(NoiseSession.CryptoOpenResult.Rejected,
            receiver.openWithResult(
                forged(UnsignedNonce.POLICY_CEILING - 1)))
        // Window untouched: the sender's real next frame (nonce 5) works.
        assertTrue(receiver.openWithResult(frame(sender, "m5")) is
            NoiseSession.CryptoOpenResult.Authenticated)
    }

    @Test
    fun testFailedAuthenticationConsumesNothing_RetransmissionRecovers() {
        val (sender, receiver) = establishPair()
        val good = frame(sender, "retransmit-me")
        // Corrupted in transit: rejected, and the nonce is NOT consumed.
        assertEquals(NoiseSession.CryptoOpenResult.Rejected,
            receiver.openWithResult(corrupted(good)))
        // The legitimate retransmission carries the SAME nonce and must
        // authenticate - proof that the failed authenticate mutated nothing.
        assertTrue(receiver.openWithResult(good) is
            NoiseSession.CryptoOpenResult.Authenticated)
        // A genuine replay (already committed nonce) is still rejected.
        assertEquals(NoiseSession.CryptoOpenResult.Expired,
            receiver.openWithResult(good))
    }

    @Test
    fun testUnsignedNonceParser_ReserveAndPolicy() {
        val buffer = java.nio.ByteBuffer.allocate(8)
        buffer.putLong(0, -1L) // unsigned 2^64-1, the classic sentinel
        assertTrue(UnsignedNonce.parse(buffer) is UnsignedNonce.Result.Rejected)
        // T07: the budget boundary is strict - the last in-budget nonce
        // is ceiling-1; the ceiling itself is out of budget.
        buffer.putLong(0, UnsignedNonce.POLICY_CEILING)
        assertTrue(UnsignedNonce.parse(buffer) is UnsignedNonce.Result.Rejected)
        buffer.putLong(0, UnsignedNonce.POLICY_CEILING - 1)
        val parsed = UnsignedNonce.parse(buffer)
        assertTrue(parsed is UnsignedNonce.Result.Valid)
        assertEquals(UnsignedNonce.POLICY_CEILING - 1,
            (parsed as UnsignedNonce.Result.Valid).value)
    }

    @Test
    fun testNarrowingRegression_LargeJumpIsClassifiedByComparison() {
        // 2^32 + 3 would narrow to 3 under unchecked Int narrowing. At
        // the window layer it is classified by Long comparison as a
        // clear-all jump; at the session layer the parser rejects it
        // before the window is ever consulted.
        val window = ReplayWindow()
        window.commit(window.preview(5L) as ReplayWindow.Plan.Accept)
        val jumpDistance = (1L shl 32) + 3L
        val jumpPlan = window.preview(5L + jumpDistance)
        assertTrue(jumpPlan is ReplayWindow.Plan.Accept)
        assertEquals(-1, (jumpPlan as ReplayWindow.Plan.Accept).forwardShift)
        val buffer = java.nio.ByteBuffer.allocate(8)
        buffer.putLong(0, 5L + jumpDistance)
        assertTrue(UnsignedNonce.parse(buffer) is
            UnsignedNonce.Result.Rejected)
        // A jump past the window but inside policy still clears the
        // bitmap, classified with Long comparisons (no Int narrowing).
        val past = 5L + ReplayWindow.DEFAULT_WINDOW + 1
        val pastPlan = window.preview(past)
        assertTrue(pastPlan is ReplayWindow.Plan.Accept)
        assertEquals(-1, (pastPlan as ReplayWindow.Plan.Accept).forwardShift)
    }

    @Test
    fun testWindowPreviewIsPure_UntilCommit() {
        val window = ReplayWindow()
        val first = window.preview(10L)
        assertTrue(first is ReplayWindow.Plan.Accept)
        // Previewing again yields the same plan: nothing was mutated.
        assertEquals(first, window.preview(10L))
        assertEquals(-1L, window.highest())
        window.commit(first as ReplayWindow.Plan.Accept)
        assertEquals(10L, window.highest())
        assertTrue(window.preview(10L) is ReplayWindow.Plan.Reject)
    }

    @Test
    fun testReorderWithinWindow_Accepted() {
        val window = ReplayWindow()
        for (nonce in longArrayOf(10L, 8L, 9L, 7L, 11L)) {
            val plan = window.preview(nonce)
            assertTrue("nonce $nonce must be accepted", plan is
                ReplayWindow.Plan.Accept)
            window.commit(plan as ReplayWindow.Plan.Accept)
        }
        assertTrue(window.preview(10L) is ReplayWindow.Plan.Reject)
    }

    @Test
    fun testLargeForwardJumpClearsBoundedBitmap() {
        val window = ReplayWindow()
        window.commit(window.preview(5L) as ReplayWindow.Plan.Accept)
        val past = 5L + ReplayWindow.DEFAULT_WINDOW + 1
        window.commit(window.preview(past) as ReplayWindow.Plan.Accept)
        // The bitmap was cleared: an old nonce is outside the window now.
        assertTrue(window.preview(4L) is ReplayWindow.Plan.Reject)
        // The predecessor of the new highest is still in-window.
        assertTrue(window.preview(past - 1L) is ReplayWindow.Plan.Accept)
    }

    @Test
    fun testTypedRejectionDoesNotTerminateCollector() {
        val (sender, receiver) = establishPair()
        // Stream shape: valid, forged, valid, corrupted-in-transit, valid.
        // The corrupted frame burns nonce 2; nonce 3 ('c') still authenticates
        // afterwards, proving the failed open committed nothing.
        val corruptMe = frame(sender, "corrupt")
        val stream = listOf(
            frame(sender, "a"),
            forged(1L shl 40),
            frame(sender, "b"),
            corrupted(corruptMe),
            frame(sender, "c"),
        )
        val expectations = listOf(true, false, true, false, true)
        var authenticated = 0
        var rejected = 0
        for ((index, bytes) in stream.withIndex()) {
            when (val outcome = receiver.openWithResult(bytes)) {
                is NoiseSession.CryptoOpenResult.Authenticated -> {
                    assertTrue("frame $index", expectations[index])
                    authenticated++
                }
                is NoiseSession.CryptoOpenResult.Rejected -> {
                    assertFalse("frame $index", expectations[index])
                    rejected++
                }
                is NoiseSession.CryptoOpenResult.Expired -> {
                    assertFalse("frame $index", expectations[index])
                    rejected++
                }
            }
        }
        assertEquals(3, authenticated)
        assertEquals(2, rejected)
    }

    @Test
    fun testLegacyDecryptWrapper_StillFailsHard() {
        val (sender, receiver) = establishPair()
        val good = frame(sender, "legacy")
        assertTrue(receiver.decrypt(good).contentEquals("legacy".toByteArray()))
        val before = good.copyOf()
        try {
            receiver.decrypt(corrupted(good))
            throw AssertionError("tampered frame must throw")
        } catch (expected: NoiseSession.AuthenticationException) {
            // typed hard failure preserved for existing callers
        }
        assertEquals(before.toList(), good.toList())
    }
}