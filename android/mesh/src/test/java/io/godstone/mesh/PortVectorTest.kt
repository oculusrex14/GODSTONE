package io.godstone.mesh

import io.godstone.mesh.crypto.NoiseSession
import org.bouncycastle.crypto.digests.Blake2sDigest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PortVectorTest {
    private fun blake(input: ByteArray, length: Int): String {
        val d = Blake2sDigest(null, length, null, null)
        d.update(input, 0, input.size)
        val out = ByteArray(length)
        d.doFinal(out, 0)
        return out.joinToString("") { "%02x".format(it) }
    }

    @Test
    fun `bouncycastle port matches generated vectors`() {
        val cases = listOf(
            Triple(ByteArray(0), 32, "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"),
            Triple("abc".toByteArray(), 32, "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"),
            Triple("abc".toByteArray(), 16, "aa4938119b1dc7b87cbad0ffd200d0ae"),
            Triple("abc".toByteArray(), 8, "972e9d2cd6de6402"),
            Triple(ByteArray(64) { 0xA5.toByte() }, 32, "f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e"),
            Triple(ByteArray(65) { 0xA5.toByte() }, 32, "65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d")
        )
        for ((input, length, expected) in cases) assertEquals(expected, blake(input, length))
    }

    @Test
    fun `noise xx emits canonical empty-payload message sizes`() {
        val alice = NoiseSession.initiator(MeshIdentity.generate())
        val bob = NoiseSession.responder(MeshIdentity.generate())
        val m1 = alice.writeMessage()
        bob.readMessage(m1)
        val m2 = bob.writeMessage()
        alice.readMessage(m2)
        val m3 = alice.writeMessage()
        bob.readMessage(m3)

        assertEquals(listOf(32, 96, 64), listOf(m1.size, m2.size, m3.size))
        assertTrue(alice.isEstablished)
        assertTrue(bob.isEstablished)
        assertContentEquals(alice.handshakeHash, bob.handshakeHash)
    }
}
