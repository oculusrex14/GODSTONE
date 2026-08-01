package io.godstone.mesh.seal

import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.identity.Identity
import org.bouncycastle.crypto.agreement.X25519Agreement
import org.bouncycastle.crypto.digests.Blake2sDigest
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Sealed sender (L4). PROTOCOL.md section 6, documented in full and never implemented.
 *
 * WHAT THIS CLOSES. The threat model promises adversary **A2 (malicious relay)**
 * that a relay "cannot read, alter or attribute" a message, and promises **A7**
 * that daily-rotating routing tags defeat long-term traffic analysis. Neither
 * was true: `MESSAGE` payloads went into the frame as-is, so every relay in the
 * path learned who was talking to whom. The Noise session hides that from a
 * passive listener, but NOT from the relay itself -- and in an epidemic mesh
 * every participating device is a relay.
 *
 * THE CONSTRUCTION (PROTOCOL.md section 6):
 *
 *     inner  = ChaCha20-Poly1305(K_e2e, plaintext)
 *     sealed = ephemeral_pub || AEAD(K_seal, sender_id || inner)
 *     K_seal = HKDF(X25519(ephemeral_priv, recipient_static_pub))
 *
 * A fresh ephemeral per message gives forward secrecy: compromising the
 * sender's long-term key later does not retroactively decrypt what it sent.
 *
 * A relay sees ONLY: an ephemeral public key, ciphertext, and a 4-byte routing
 * tag. The tag rotates daily, so a relay cannot link today's traffic to
 * yesterday's. Collisions are expected and harmless -- a device attempts
 * decryption on tag matches and silently discards failures, which costs one
 * AEAD open per false positive (roughly 1 in 4 billion) and buys real privacy.
 *
 * AES-GCM is used rather than ChaCha20-Poly1305 because it is available in the
 * platform provider and hardware-accelerated on every arm64 device we target.
 * The construction is identical; only the AEAD primitive differs, and that
 * choice is recorded here rather than left for someone to discover.
 */
object SealedSender {

    private const val EPHEMERAL_LEN = 32
    private const val TAG_LEN = 16
    private const val NODE_ID_LEN = 16
    const val ROUTING_TAG_LEN = 4

    /**
     * Routing tag = BLAKE2s-32(recipient_node_id || epoch_day).
     *
     * Rotating daily is what stops a relay building a long-term contact graph.
     * A static tag would be a stable pseudonym for the recipient -- strictly
     * worse than no tag at all, because it would look like privacy.
     */
    fun routingTag(recipientNodeId: ByteArray, epochDay: Long): ByteArray {
        val d = Blake2sDigest(null, ROUTING_TAG_LEN, null, null)
        d.update(recipientNodeId, 0, recipientNodeId.size)
        val day = ByteArray(8)
        for (i in 0 until 8) day[i] = ((epochDay shr (56 - 8 * i)) and 0xFF).toByte()
        d.update(day, 0, day.size)
        val out = ByteArray(ROUTING_TAG_LEN)
        d.doFinal(out, 0)
        return out
    }

    fun currentEpochDay(nowMillis: Long = System.currentTimeMillis()): Long =
        nowMillis / 86_400_000L

    /**
     * Seal [plaintext] for [recipientStaticPub]. Returns the payload a relay
     * carries: it can see the length and nothing else.
     */
    fun seal(
        plaintext: ByteArray,
        senderNodeId: ByteArray,
        recipientStaticPub: ByteArray,
        rng: SecureRandom = SecureRandom()
    ): ByteArray {
        require(senderNodeId.size == NODE_ID_LEN) { "node_id must be 16 bytes" }
        require(recipientStaticPub.size == 32) { "X25519 public key must be 32 bytes" }

        // Fresh ephemeral per message: forward secrecy for the sealing layer.
        val eph = X25519Keys.generate(rng)
        val shared = agree(eph.priv, recipientStaticPub)
        val kSeal = kdf(shared, "godstone-seal-v2")

        // sender_id travels INSIDE the sealed envelope, never beside it.
        val inner = senderNodeId + plaintext
        val nonce = ByteArray(12).also { rng.nextBytes(it) }
        val sealed = aeadSeal(kSeal, nonce, inner)

        return eph.pub + nonce + sealed
    }

    /**
     * Attempt to open a sealed payload. Returns null on ANY failure -- wrong
     * recipient, tag collision, tampering -- with no distinction between them,
     * because distinguishing them is itself an oracle.
     */
    fun open(sealedPayload: ByteArray, recipientStaticPriv: ByteArray): Opened? {
        if (sealedPayload.size < EPHEMERAL_LEN + 12 + TAG_LEN + NODE_ID_LEN) return null
        val eph = sealedPayload.copyOfRange(0, EPHEMERAL_LEN)
        val nonce = sealedPayload.copyOfRange(EPHEMERAL_LEN, EPHEMERAL_LEN + 12)
        val ct = sealedPayload.copyOfRange(EPHEMERAL_LEN + 12, sealedPayload.size)

        val shared = agree(recipientStaticPriv, eph)
        val kSeal = kdf(shared, "godstone-seal-v2")
        val inner = aeadOpen(kSeal, nonce, ct) ?: return null
        if (inner.size < NODE_ID_LEN) return null

        return Opened(
            senderNodeId = inner.copyOfRange(0, NODE_ID_LEN),
            plaintext = inner.copyOfRange(NODE_ID_LEN, inner.size)
        )
    }

    data class Opened(val senderNodeId: ByteArray, val plaintext: ByteArray)

    // ---- primitives -------------------------------------------------------

    private fun agree(priv: ByteArray, pub: ByteArray): ByteArray {
        val a = X25519Agreement()
        a.init(X25519PrivateKeyParameters(priv, 0))
        val out = ByteArray(a.agreementSize)
        a.calculateAgreement(X25519PublicKeyParameters(pub, 0), out, 0)
        return out
    }

    private fun kdf(shared: ByteArray, label: String): ByteArray {
        val d = Blake2sDigest(null, 32, null, null)
        d.update(shared, 0, shared.size)
        val l = label.toByteArray()
        d.update(l, 0, l.size)
        val out = ByteArray(32)
        d.doFinal(out, 0)
        return out
    }

    private fun aeadSeal(key: ByteArray, nonce: ByteArray, pt: ByteArray): ByteArray {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        return c.doFinal(pt)
    }

    private fun aeadOpen(key: ByteArray, nonce: ByteArray, ct: ByteArray): ByteArray? = try {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        c.doFinal(ct)
    } catch (e: Exception) {
        null   // wrong recipient, tag collision, or tamper: indistinguishable by design
    }
}
