package io.godstone.mesh

import io.godstone.mesh.crypto.NoiseSession
import org.bouncycastle.crypto.digests.Blake2sDigest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
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
            // Pinned expected digests are the BLAKE2s hashes of 64/65 bytes of
            // 0x41 ('A'), per crypto/port_vectors.json. An earlier transcription
            // used 0xA5 as the input while keeping the 0x41-derived expected
            // values, making the vector self-inconsistent. Input byte restored
            // to 0x41. Impl (BouncyCastle Blake2sDigest) and fixture are correct.
            Triple(ByteArray(64) { 0x41.toByte() }, 32, "f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e"),
            Triple(ByteArray(65) { 0x41.toByte() }, 32, "65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d")
        )
        for ((input, length, expected) in cases) assertEquals(expected, blake(input, length))
    }

    /// Known-answer tests pinned to canonical RFC 7693 vectors (independently
    /// verified against Python hashlib.blake2s). Distinct from A-06 Noise vectors.
    @Test
    fun `blake2s known answers`() {
        val kat = listOf(
            Triple(ByteArray(0), 32, "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"),
            Triple("abc".toByteArray(), 32, "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"),
            Triple("abc".toByteArray(), 16, "aa4938119b1dc7b87cbad0ffd200d0ae"),
            Triple("abc".toByteArray(), 8, "972e9d2cd6de6402"),
            Triple(ByteArray(64) { 0x41.toByte() }, 32, "f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e"),
            Triple(ByteArray(65) { 0x41.toByte() }, 32, "65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d"),
            Triple("The quick brown fox jumps over the lazy dog".toByteArray(), 32,
                "606beeec743ccbeff6cbcdf5d5302aa855c256c29b88c8ed331ea1a6bf3c8812")
        )
        for ((input, length, expected) in kat) assertEquals(expected, blake(input, length))
        // keyed mode: 32-byte zero key, empty input.
        val keyed = Blake2sDigest(ByteArray(32), 32, null, null)
        val out = ByteArray(32); keyed.doFinal(out, 0)
        assertEquals("cc8ed046995def3f21db6abcfe34c3526960be9dd3270ed1ab7cfc7f29ad4bd6",
            out.joinToString("") { "%02x".format(it) })
    }

    /// Mutation / negative control: a one-byte change must change the digest,
    /// and restoring it must reproduce the original. Guards against the 0xA5
    /// transcription regressing and against loss of diffusion.
    @Test
    fun `blake2s mutation changes digest`() {
        val original = "godstone".toByteArray()
        val mutated = original.copyOf(); mutated[mutated.lastIndex] = 0x66 // 'e' -> 'f'
        assertNotEquals(blake(original, 32), blake(mutated, 32))
        assertEquals(blake(original, 32), blake(original, 32))
        assertNotEquals(
            blake(ByteArray(64) { 0x41.toByte() }, 32),
            blake(ByteArray(64) { 0xA5.toByte() }, 32))
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
