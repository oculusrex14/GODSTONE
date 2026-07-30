package io.godstone.mesh.crypto

import com.southernstorm.noise.protocol.CipherStatePair
import com.southernstorm.noise.protocol.HandshakeState
import io.godstone.mesh.identity.Identity
import java.util.concurrent.atomic.AtomicLong

/**
 * Pairwise encrypted session, Noise_XX_25519_ChaChaPoly_BLAKE2s.
 *
 * XX is used because neither side knows the other in advance: any stranger may
 * be a relay. It provides mutual authentication and responder identity hiding.
 *
 *   -> e
 *   <- e, ee, s, es
 *   -> s, se
 *
 * The prologue binds the handshake to the protocol version and both advertised
 * node hints, defeating downgrade and cross-protocol attacks.
 */
class NoiseSession private constructor(
    private val handshake: HandshakeState,
    private val identity: Identity
) {

    private var ciphers: CipherStatePair? = null
    private val messageCount = AtomicLong(0)
    private val createdAt = System.currentTimeMillis()

    var remoteStaticKey: ByteArray? = null
        private set

    val isEstablished: Boolean get() = ciphers != null

    /** Rekey after 2^20 messages or 30 minutes, whichever comes first. */
    val needsRekey: Boolean
        get() = messageCount.get() > REKEY_MESSAGE_LIMIT ||
            (System.currentTimeMillis() - createdAt) > REKEY_TIME_LIMIT_MS

    fun writeHandshakeMessage(payload: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteArray(MAX_HANDSHAKE)
        val len = handshake.writeMessage(out, 0, payload, 0, payload.size)
        maybeSplit()
        return out.copyOf(len)
    }

    fun readHandshakeMessage(message: ByteArray): ByteArray {
        val out = ByteArray(MAX_HANDSHAKE)
        val len = handshake.readMessage(message, 0, message.size, out, 0)
        maybeSplit()
        return out.copyOf(len)
    }

    private fun maybeSplit() {
        if (handshake.action == HandshakeState.SPLIT && ciphers == null) {
            remoteStaticKey = ByteArray(32).also {
                handshake.remotePublicKey.getPublicKey(it, 0)
            }
            ciphers = handshake.split()
        }
    }

    fun encrypt(plaintext: ByteArray): ByteArray {
        val c = ciphers ?: error("session not established")
        val out = ByteArray(plaintext.size + MAC_LEN)
        val len = c.sender.encryptWithAd(null, plaintext, 0, out, 0, plaintext.size)
        messageCount.incrementAndGet()
        return out.copyOf(len)
    }

    /**
     * Returns null on authentication failure. A failed MAC is dropped silently
     * and charged against the peer's trust score: it is either corruption or an
     * active attacker, and in both cases we simply do not process the frame.
     */
    fun decrypt(ciphertext: ByteArray): ByteArray? = try {
        val c = ciphers ?: error("session not established")
        val out = ByteArray(ciphertext.size)
        val len = c.receiver.decryptWithAd(null, ciphertext, 0, out, 0, ciphertext.size)
        out.copyOf(len)
    } catch (e: javax.crypto.BadPaddingException) {
        null
    } catch (e: javax.crypto.ShortBufferException) {
        null
    }

    fun destroy() {
        ciphers?.destroy()
        handshake.destroy()
    }

    companion object {
        const val PATTERN = "Noise_XX_25519_ChaChaPoly_BLAKE2s"
        private const val MAX_HANDSHAKE = 2048
        private const val MAC_LEN = 16
        private const val REKEY_MESSAGE_LIMIT = 1L shl 20
        private const val REKEY_TIME_LIMIT_MS = 30 * 60 * 1000L

        fun initiator(identity: Identity, localHint: ByteArray, remoteHint: ByteArray) =
            create(identity, HandshakeState.INITIATOR, localHint, remoteHint)

        fun responder(identity: Identity, remoteHint: ByteArray, localHint: ByteArray) =
            create(identity, HandshakeState.RESPONDER, remoteHint, localHint)

        private fun create(
            identity: Identity,
            role: Int,
            initiatorHint: ByteArray,
            responderHint: ByteArray
        ): NoiseSession {
            val hs = HandshakeState(PATTERN, role)

            // prologue = "GMP1" || initiator_hint || responder_hint
            val prologue = "GMP1".toByteArray() + initiatorHint + responderHint
            hs.setPrologue(prologue, 0, prologue.size)

            hs.localKeyPair.setPrivateKey(identity.staticDhPriv, 0)
            hs.start()

            return NoiseSession(hs, identity)
        }
    }
}
