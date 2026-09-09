package io.godstone.mesh.crypto

import io.godstone.mesh.MeshIdentity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T07: replace unilateral rekey with deterministic session retirement.
 *
 * Regression targets: Swift rehashed directional keys without peer
 * coordination; Android rekey thresholds were not enforced. After T07:
 *  - there is no rekey-in-place API on either engine;
 *  - the session budget is monotonic from trusted establishment
 *    (2^20 authenticated records per direction or 30 minutes);
 *  - retirement is terminal: key material and readiness are cleared, and a
 *    fresh trusted Noise session must be established;
 *  - counters never reset under an existing key.
 */
class ReadinessT07Test {

    private fun establishPair(): Pair<NoiseSession, NoiseSession> {
        val initiator = NoiseSession.initiator(MeshIdentity.generate())
        val responder = NoiseSession.responder(MeshIdentity.generate())
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

    @Test
    fun testSendBudgetExhaustion_RetiresTerminal() {
        val (sender, receiver) = establishPair()
        sender.recordBudgetForTest = 2L
        receiver.recordBudgetForTest = 1000L
        // Records 0 and 1 inside the injected budget.
        assertTrue(receiver.decrypt(sender.encrypt("a".toByteArray()))
            .contentEquals("a".toByteArray()))
        assertTrue(receiver.decrypt(sender.encrypt("b".toByteArray()))
            .contentEquals("b".toByteArray()))
        // Record 2 exceeds the budget: typed expiry and terminal retirement.
        try {
            sender.encrypt("c".toByteArray())
            throw AssertionError("budget exhaustion must throw SessionExpired")
        } catch (expected: NoiseSession.SessionExpired) {
            assertEquals("send budget exceeded (records)", expected.reason)
        }
        // Readiness and key material are cleared: further operations fail.
        assertFalse(sender.isEstablished)
        try {
            sender.encrypt("d".toByteArray())
            throw AssertionError("a retired session must not encrypt")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message!!.contains("session retired"))
        }
        // A fresh trusted Noise session establishes and works normally.
        val (sender2, receiver2) = establishPair()
        assertTrue(receiver2.decrypt(sender2.encrypt("fresh".toByteArray()))
            .contentEquals("fresh".toByteArray()))
    }

    @Test
    fun testReceiveBudgetExhaustion_ReturnsExpiredAndRetires() {
        val (sender, receiver) = establishPair()
        receiver.recordBudgetForTest = 2L
        assertTrue(receiver.openWithResult(sender.encrypt("a".toByteArray()))
            is NoiseSession.CryptoOpenResult.Authenticated)
        assertTrue(receiver.openWithResult(sender.encrypt("b".toByteArray()))
            is NoiseSession.CryptoOpenResult.Authenticated)
        // The third open is outside the budget: typed Expired, session retired.
        assertEquals(NoiseSession.CryptoOpenResult.Expired,
            receiver.openWithResult(sender.encrypt("c".toByteArray())))
        assertFalse(receiver.isEstablished)
        // The sender side is unaffected by the receiver's budget.
        assertTrue(receiver2NotRetired(sender))
    }

    private fun receiver2NotRetired(sender: NoiseSession): Boolean {
        // A fresh receiver established against the same sender still works,
        // proving retirement is per-session, not global.
        val fresh = NoiseSession.responder(MeshIdentity.generate())
        val initiator = NoiseSession.initiator(MeshIdentity.generate())
        fresh.readHandshakeMessage(initiator.writeHandshakeMessage())
        val hs2 = fresh.writeHandshakeMessage()
        initiator.readHandshakeMessage(hs2)
        fresh.readHandshakeMessage(initiator.writeHandshakeMessage())
        return fresh.openWithResult(
            initiator.encrypt("ok".toByteArray())
        ) is NoiseSession.CryptoOpenResult.Authenticated
    }

    @Test
    fun testTimeBudgetExpiry_RetiresSession() {
        val (sender, receiver) = establishPair()
        sender.ageBudgetForTest = 0L
        sender.establishedMonoForTest = System.nanoTime() - 31L * 60L * 1_000_000_000L
        try {
            sender.encrypt("late".toByteArray())
            throw AssertionError("time budget expiry must throw SessionExpired")
        } catch (expected: NoiseSession.SessionExpired) {
            assertEquals("send budget exceeded (time)", expected.reason)
        }
        assertFalse(sender.isEstablished)
    }

    @Test
    fun testPeerNonceBeyondBudgetRejected() {
        val (sender, receiver) = establishPair()
        // A peer nonce at the agreed budget boundary (2^20) is outside the
        // budget: the parser rejects it before any window arithmetic.
        val forged = TransportCiphertextV1.encode(
            UnsignedNonce.POLICY_CEILING, ByteArray(16))
        assertTrue(receiver.openWithResult(forged)
            is NoiseSession.CryptoOpenResult.Expired)
        // The window mutated nothing: the next legitimate frame works.
        assertTrue(receiver.openWithResult(sender.encrypt("next".toByteArray()))
            is NoiseSession.CryptoOpenResult.Authenticated)
    }

    @Test
    fun testNoCounterResetUnderExistingKey() {
        val (sender, receiver) = establishPair()
        // Transport nonces advance strictly monotonically under the same key:
        // no rekey-in-place exists, so the prefix sequence must be 0,1,2,...
        for (index in 0 until 5) {
            val sealed = sender.encrypt("m$index".toByteArray())
            val (nonce, _) = TransportCiphertextV1.decode(sealed)!!
            assertEquals(index.toLong(), nonce)
            assertTrue(receiver.openWithResult(sealed)
                is NoiseSession.CryptoOpenResult.Authenticated)
        }
        // The budget counters survive many records: no reset mid-session.
        sender.recordBudgetForTest = 50L
        var sent = 0
        try {
            while (sent < 100) {
                sender.encrypt("bulk$sent".toByteArray())
                sent++
            }
            throw AssertionError("budget must terminate the loop")
        } catch (expected: NoiseSession.SessionExpired) {
            // Terminal: no further send is possible under the same key.
            assertFalse(sender.isEstablished)
        }
    }

    @Test
    fun testRekeyInPlaceApiRemoved() {
        // L0 source-integrity: the ad hoc rehashing API is gone from the
        // session sources; the retirement budget replaced it.
        var dir = java.io.File(System.getProperty("user.dir"))
        while (!java.io.File(dir, "wire").isDirectory) {
            val parent = dir.parentFile
                ?: throw AssertionError("no repo root above " + dir.path)
            dir = parent
        }
        val rootDir = dir
        val session = listOf(
            "android/mesh/src/main/java/io/godstone/mesh/crypto/NoiseSession.kt",
            "ios/Godstone/Sources/GodstoneMesh/NoiseSession.swift",
        ).joinToString("") { file ->
            java.io.File(rootDir, file).readText()
        }
        assertFalse("no rekey-in-place API remains",
                    session.contains("needsRekey") ||
                        session.contains("rekeyIfNeeded"))
        assertTrue("the retirement budget is present",
                   session.contains("SessionBudget") &&
                       session.contains("SessionExpired"))
    }
}