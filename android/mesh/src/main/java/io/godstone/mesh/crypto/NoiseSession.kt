package io.godstone.mesh.crypto

import com.southernstorm.noise.protocol.CipherStatePair
import com.southernstorm.noise.protocol.HandshakeState
import io.godstone.mesh.identity.Identity
import java.nio.ByteBuffer
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

    /** Monotonic 64-bit transport nonce, prepended to every ciphertext. */
    private val sendNonce = AtomicLong(0)

    /*
     * Sliding replay window over the last WINDOW nonces. Multi-hop flooding
     * reorders and duplicates every frame, so a strict "highest+1" counter
     * would drop most of a real conversation. The window accepts reasonable
     * reordering and rejects anything older or already seen.
     */
    private val replayLock = Any()
    private var highestReceived: Long = -1L
    private val replayWindow = java.util.BitSet(WINDOW)

    var remoteStaticKey: ByteArray? = null
        private set

    val isEstablished: Boolean get() = ciphers != null

    /** Current Noise handshake hash; equal on both sides once the handshake ends. */
    val handshakeHash: ByteArray
        get() = handshake.handshakeHash

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

    /** Alias matching the Noise verb-naming convention used in tests. */
    fun writeMessage(payload: ByteArray = ByteArray(0)): ByteArray = writeHandshakeMessage(payload)

    /** Alias matching the Noise verb-naming convention used in tests. */
    fun readMessage(message: ByteArray): ByteArray = readHandshakeMessage(message)

    private fun maybeSplit() {
        if (handshake.action == HandshakeState.SPLIT && ciphers == null) {
            remoteStaticKey = ByteArray(32).also {
                handshake.remotePublicKey.getPublicKey(it, 0)
            }
            ciphers = handshake.split()
        }
    }

    /**
     * Encrypt [plaintext] with an explicit, monotonically advancing nonce.
     *
     * Output layout: 8-byte big-endian nonce || ciphertext+MAC. The nonce is
     * prepended so the receiver can replay-protect without a transport header.
     *
     * @throws IllegalStateException if the handshake has not completed.
     */
    fun encrypt(plaintext: ByteArray): ByteArray {
        val c = ciphers ?: throw IllegalStateException("session not established")
        val nonce = sendNonce.getAndIncrement()
        c.sender.setNonce(nonce)
        val out = ByteArray(plaintext.size + MAC_LEN)
        val len = c.sender.encryptWithAd(null, plaintext, 0, out, 0, plaintext.size)
        messageCount.incrementAndGet()
        return ByteBuffer.allocate(8 + len).putLong(nonce).put(out, 0, len).array()
    }

    /**
     * Decrypt [ciphertext] (nonce || ciphertext+MAC), enforcing a 2048-message
     * sliding replay window.
     *
     * @throws IllegalStateException if the handshake has not completed.
     * @throws NoiseSession.AuthenticationException on tamper, replay, or any
     *   message outside the replay window. A failed frame is never returned to
     *   the caller: it is corruption or an active attacker, and in both cases
     *   we refuse to process it.
     */
    fun decrypt(ciphertext: ByteArray): ByteArray {
        val c = ciphers ?: throw IllegalStateException("session not established")
        if (ciphertext.size < 8 + MAC_LEN) throw AuthenticationException()

        val nonce = ByteBuffer.wrap(ciphertext, 0, 8).getLong()
        val rest = ciphertext.copyOfRange(8, ciphertext.size)

        synchronized(replayLock) {
            if (!recordNonce(nonce)) throw AuthenticationException()
        }

        val out = ByteArray(rest.size)
        val len = try {
            c.receiver.setNonce(nonce)
            c.receiver.decryptWithAd(null, rest, 0, out, 0, rest.size)
        } catch (e: javax.crypto.BadPaddingException) {
            throw AuthenticationException()
        } catch (e: javax.crypto.ShortBufferException) {
            throw AuthenticationException()
        }
        return out.copyOf(len)
    }

    /**
     * Sliding-window nonce tracker. Returns true when [nonce] is novel and
     * within the window, false when it is a replay or too old to consider.
     */
    private fun recordNonce(nonce: Long): Boolean {
        if (nonce > highestReceived) {
            val shift = (nonce - highestReceived).toInt()
            if (shift >= WINDOW) {
                replayWindow.clear()
            } else {
                for (i in 0 until WINDOW - shift) {
                    replayWindow[i] = replayWindow[i + shift]
                }
                for (i in WINDOW - shift until WINDOW) {
                    replayWindow[i] = false
                }
            }
            highestReceived = nonce
            replayWindow[WINDOW - 1] = true
            return true
        }
        val offset = (highestReceived - nonce).toInt()
        if (offset >= WINDOW) return false
        val idx = WINDOW - 1 - offset
        if (replayWindow[idx]) return false
        replayWindow[idx] = true
        return true
    }

    fun destroy() {
        ciphers?.destroy()
        handshake.destroy()
    }

    /** Authentication or replay-window failure on a transport message.
     *  Nested directly on NoiseSession (NOT inside the companion object) so the
     *  documented public name NoiseSession.AuthenticationException resolves
     *  from other files; a class nested in a companion is not promoted to the
     *  enclosing class name in Kotlin, which left the test's
     *  assertFailsWith<NoiseSession.AuthenticationException> unresolved. */
    class AuthenticationException : Exception("noise authentication failed")

    companion object {
        const val PATTERN = "Noise_XX_25519_ChaChaPoly_BLAKE2s"
        private const val MAX_HANDSHAKE = 2048
        private const val MAC_LEN = 16
        private const val WINDOW = 2048
        private const val REKEY_MESSAGE_LIMIT = 1L shl 20
        private const val REKEY_TIME_LIMIT_MS = 30 * 60 * 1000L

        /**
         * One-arg overloads: both peers bind the prologue with zero hints so the
         * handshake completes without out-of-band hint exchange. The 3-arg
         * prologue constructors below remain for the full advertised-hint flow.
         */
        fun initiator(identity: Identity) = initiator(identity, ByteArray(4), ByteArray(4))

        fun responder(identity: Identity) = responder(identity, ByteArray(4), ByteArray(4))

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

            // prologue = "GMP2" || initiator_hint || responder_hint
            val prologue = "GMP2".toByteArray() + initiatorHint + responderHint
            hs.setPrologue(prologue, 0, prologue.size)

            hs.localKeyPair.setPrivateKey(identity.staticDhPriv, 0)
            hs.start()

            return NoiseSession(hs, identity)
        }
    }
}
