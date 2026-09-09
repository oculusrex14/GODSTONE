package io.godstone.mesh.crypto

import com.southernstorm.noise.protocol.CipherStatePair
import com.southernstorm.noise.protocol.HandshakeState
import io.godstone.mesh.identity.Identity
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

internal class HandshakeReadResult(
    payload: ByteArray,
    authenticatedRemoteStaticKey: ByteArray? = null
) {
    private val _payload: ByteArray = payload.copyOf()
    private val _authenticatedRemoteStaticKey: ByteArray? = authenticatedRemoteStaticKey?.copyOf()

    val payload: ByteArray
        get() = _payload.copyOf()

    val authenticatedRemoteStaticKey: ByteArray?
        get() = _authenticatedRemoteStaticKey?.copyOf()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HandshakeReadResult) return false
        if (!_payload.contentEquals(other._payload)) return false
        if (_authenticatedRemoteStaticKey != null) {
            if (other._authenticatedRemoteStaticKey == null) return false
            if (!_authenticatedRemoteStaticKey.contentEquals(other._authenticatedRemoteStaticKey)) return false
        } else if (other._authenticatedRemoteStaticKey != null) return false
        return true
    }

    override fun hashCode(): Int {
        var result = _payload.contentHashCode()
        result = 31 * result + (_authenticatedRemoteStaticKey?.contentHashCode() ?: 0)
        return result
    }
}

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
    private val replayWindow = ReplayWindow(WINDOW)

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

    internal fun readHandshakeMessageWithResult(message: ByteArray): HandshakeReadResult {
        val out = ByteArray(MAX_HANDSHAKE)
        val len = handshake.readMessage(message, 0, message.size, out, 0)
        val payload = out.copyOf(len)
        val remoteStatic = if (handshake.remotePublicKey.hasPublicKey()) {
            val key = ByteArray(32).also {
                handshake.remotePublicKey.getPublicKey(it, 0)
            }
            remoteStaticKey = key.clone()
            key
        } else {
            null
        }
        maybeSplit()
        return HandshakeReadResult(
            payload = payload,
            authenticatedRemoteStaticKey = remoteStatic
        )
    }

    fun readHandshakeMessage(message: ByteArray): ByteArray =
        readHandshakeMessageWithResult(message).payload

    /** Alias matching the Noise verb-naming convention used in tests. */
    fun writeMessage(payload: ByteArray = ByteArray(0)): ByteArray = writeHandshakeMessage(payload)

    /** Alias matching the Noise verb-naming convention used in tests. */
    fun readMessage(message: ByteArray): ByteArray = readHandshakeMessage(message)

    private fun maybeSplit() {
        if (handshake.action == HandshakeState.SPLIT && ciphers == null) {
            if (remoteStaticKey == null && handshake.remotePublicKey.hasPublicKey()) {
                remoteStaticKey = ByteArray(32).also {
                    handshake.remotePublicKey.getPublicKey(it, 0)
                }
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
        // T06: explicit uint64_be(nonce) prefix via the shared codec.
        return TransportCiphertextV1.encode(nonce, out.copyOf(len))
    }

    /**
     * T05: one session operation = parse -> preview -> authenticate ->
     * commit. The unsigned nonce is parsed and policy-checked before any
     * subtraction; the window state is previewed WITHOUT mutation; the AEAD
     * authentication runs against that nonce; the previewed plan is committed
     * only on success. A failed authenticate mutates nothing, so a forged
     * frame can no longer poison the window ("forged-high-then-valid" fails).
     */
    fun openWithResult(ciphertext: ByteArray): CryptoOpenResult {
        val c = ciphers ?: throw IllegalStateException("session not established")
        val (nonceRaw, rest) = TransportCiphertextV1.decode(ciphertext)
            ?: return CryptoOpenResult.Rejected
        synchronized(replayLock) {
            when (val parsed = UnsignedNonce.parse(
                ByteBuffer.allocate(8).putLong(nonceRaw))) {
                is UnsignedNonce.Result.Rejected -> return CryptoOpenResult.Expired
                is UnsignedNonce.Result.Valid -> {
                    when (val plan = replayWindow.preview(parsed.value)) {
                        is ReplayWindow.Plan.Reject -> return CryptoOpenResult.Expired
                        is ReplayWindow.Plan.Accept -> {
                            val out = ByteArray(rest.size)
                            val len = try {
                                c.receiver.setNonce(parsed.value)
                                c.receiver.decryptWithAd(null, rest, 0, out, 0, rest.size)
                            } catch (e: javax.crypto.BadPaddingException) {
                                return CryptoOpenResult.Rejected
                            } catch (e: javax.crypto.ShortBufferException) {
                                return CryptoOpenResult.Rejected
                            }
                            replayWindow.commit(plan)
                            return CryptoOpenResult.Authenticated(out.copyOf(len))
                        }
                    }
                }
            }
        }
    }

    /**
     * Backward-compatible wrapper: hard failure on any non-authenticated
     * outcome, preserving the pre-T05 contract for existing callers.
     */
    fun decrypt(ciphertext: ByteArray): ByteArray =
        when (val result = openWithResult(ciphertext)) {
            is CryptoOpenResult.Authenticated -> result.plaintext
            is CryptoOpenResult.Rejected, is CryptoOpenResult.Expired ->
                throw AuthenticationException()
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

    /** T05: typed outcome of one authenticated-open session operation. */
    sealed class CryptoOpenResult {
        /** Frame authenticated and the previewed window plan committed. */
        data class Authenticated(val plaintext: ByteArray) : CryptoOpenResult()

        /** Malformed frame or failed AEAD verification; window untouched. */
        object Rejected : CryptoOpenResult()

        /** Reserved/out-of-policy nonce, replay, or outside the window. */
        object Expired : CryptoOpenResult()
    }

    companion object {
    /** T06 test hook: a sender-only session bound to a fixture transport key
     *  (documented test constant; never a real secret). */
    internal fun senderForTest(sendKey: ByteArray, identity: Identity): NoiseSession {
        val hs = HandshakeState(PATTERN, HandshakeState.INITIATOR)
        val sender = com.southernstorm.noise.protocol.Noise.createCipher(
            "ChaChaPoly")
        sender.initializeKey(sendKey, 0)
        val session = NoiseSession(hs, identity)
        session.ciphers = com.southernstorm.noise.protocol.CipherStatePair(sender, null)
        return session
    }

    /** T06 test hook: a receiver-only session bound to a recorded transport key. */
    internal fun receiverForTest(receiveKey: ByteArray, identity: Identity): NoiseSession {
        val hs = HandshakeState(PATTERN, HandshakeState.RESPONDER)
        val receiver = com.southernstorm.noise.protocol.Noise.createCipher(
            "ChaChaPoly")
        receiver.initializeKey(receiveKey, 0)
        val session = NoiseSession(hs, identity)
        session.ciphers = com.southernstorm.noise.protocol.CipherStatePair(null, receiver)
        return session
    }

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
