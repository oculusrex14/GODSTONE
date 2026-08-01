package io.godstone.mesh

import io.godstone.mesh.crypto.NoiseSession
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * Noise XX handshake and transport tests.
 *
 * Crypto is composed, not invented (C6), so these tests are not verifying the
 * primitives - they verify that we wired them together correctly, which is
 * where real systems actually break.
 */
class NoiseSessionTest {

    private fun handshake(): Pair<NoiseSession, NoiseSession> {
        val alice = NoiseSession.initiator(MeshIdentity.generate())
        val bob = NoiseSession.responder(MeshIdentity.generate())

        // XX is three messages: -> e, <- e ee s es, -> s se
        bob.readMessage(alice.writeMessage(ByteArray(0)))
        alice.readMessage(bob.writeMessage(ByteArray(0)))
        bob.readMessage(alice.writeMessage(ByteArray(0)))

        assertTrue(alice.isEstablished)
        assertTrue(bob.isEstablished)
        return alice to bob
    }

    @Test
    fun `handshake completes and both sides derive the same keys`() {
        val (alice, bob) = handshake()
        assertContentEquals(alice.handshakeHash, bob.handshakeHash)
    }

    @Test
    fun `each side learns the other's static key`() {
        val alice = NoiseSession.initiator(MeshIdentity.generate())
        val bobIdentity = MeshIdentity.generate()
        val bob = NoiseSession.responder(bobIdentity)

        bob.readMessage(alice.writeMessage(ByteArray(0)))
        alice.readMessage(bob.writeMessage(ByteArray(0)))
        bob.readMessage(alice.writeMessage(ByteArray(0)))

        // This is what makes QR contact verification meaningful: the key the
        // user scanned must be the key that completed the handshake.
        // remoteStaticKey comes out of the Noise handshake, whose static is
        // X25519 (staticDhPriv). identityPub is Ed25519 -- a different key, so
        // this assertion could never pass. The QR flow must pin staticDhPub.
        assertContentEquals(bobIdentity.staticDhPub, alice.remoteStaticKey)
    }

    @Test
    fun `transport messages round trip`() {
        val (alice, bob) = handshake()
        val plaintext = "water is safe after 1 minute rolling boil".toByteArray()

        assertContentEquals(plaintext, bob.decrypt(alice.encrypt(plaintext)))
        assertContentEquals(plaintext, alice.decrypt(bob.encrypt(plaintext)))
    }

    @Test
    fun `ciphertext is not plaintext and repeats differ`() {
        val (alice, _) = handshake()
        val plaintext = ByteArray(64) { 0x41 }

        val first = alice.encrypt(plaintext)
        val second = alice.encrypt(plaintext)

        assertFalse(first.contentEquals(plaintext))
        // Nonce advances, so identical plaintexts must not produce identical
        // ciphertexts. If they do, the nonce is stuck and the session is unsafe.
        assertNotEquals(first.toList(), second.toList())
    }

    @Test
    fun `tampered ciphertext is rejected`() {
        val (alice, bob) = handshake()
        val sealed = alice.encrypt("apply the tourniquet high and tight".toByteArray())

        sealed[sealed.size / 2] = (sealed[sealed.size / 2].toInt() xor 0x01).toByte()

        assertFailsWith<NoiseSession.AuthenticationException> { bob.decrypt(sealed) }
    }

    @Test
    fun `replayed message is rejected`() {
        val (alice, bob) = handshake()
        val sealed = alice.encrypt(ByteArray(16))

        bob.decrypt(sealed)
        // Replaying a relayed frame must not work. In a flooding mesh every
        // frame is seen many times by design.
        assertFailsWith<NoiseSession.AuthenticationException> { bob.decrypt(sealed) }
    }

    @Test
    fun `out of order delivery within the window is accepted`() {
        val (alice, bob) = handshake()

        val one = alice.encrypt(byteArrayOf(1))
        val two = alice.encrypt(byteArrayOf(2))
        val three = alice.encrypt(byteArrayOf(3))

        // Multi-hop paths reorder constantly. A strict counter would drop most
        // of a real conversation.
        assertContentEquals(byteArrayOf(3), bob.decrypt(three))
        assertContentEquals(byteArrayOf(1), bob.decrypt(one))
        assertContentEquals(byteArrayOf(2), bob.decrypt(two))
    }

    @Test
    fun `message far outside the replay window is rejected`() {
        val (alice, bob) = handshake()
        val stale = alice.encrypt(byteArrayOf(9))

        repeat(2048) { alice.encrypt(ByteArray(8)).let(bob::decrypt) }

        assertFailsWith<NoiseSession.AuthenticationException> { bob.decrypt(stale) }
    }

    @Test
    fun `sessions with different peers do not interoperate`() {
        val (alice, _) = handshake()
        val (_, otherBob) = handshake()

        assertFailsWith<NoiseSession.AuthenticationException> {
            otherBob.decrypt(alice.encrypt(ByteArray(16)))
        }
    }

    @Test
    fun `transport use before handshake completes is refused`() {
        val alice = NoiseSession.initiator(MeshIdentity.generate())
        assertFailsWith<IllegalStateException> { alice.encrypt(ByteArray(4)) }
    }
}
