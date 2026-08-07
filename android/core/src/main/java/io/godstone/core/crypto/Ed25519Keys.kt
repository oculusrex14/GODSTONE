package io.godstone.core.crypto

import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.security.SecureRandom

/** Raw Ed25519 public/private key material (32 bytes each). */
class KeyPair(val pub: ByteArray, val priv: ByteArray)

/** Long-term identity signing-key generation + sign/verify backed by Bouncy Castle. */
object Ed25519Keys {
    fun generate(rng: SecureRandom): KeyPair {
        val generator = Ed25519KeyPairGenerator().apply {
            init(Ed25519KeyGenerationParameters(rng))
        }
        val pair = generator.generateKeyPair()
        val publicKey = (pair.public as Ed25519PublicKeyParameters).encoded
        val privateKey = (pair.private as Ed25519PrivateKeyParameters).encoded
        check(publicKey.size == 32 && privateKey.size == 32)
        return KeyPair(publicKey.copyOf(), privateKey.copyOf())
    }

    /**
     * Sign `message` with a raw 32-byte Ed25519 private key. Returns the 64-byte
     * signature. Byte-identical operation to iOS
     * `Curve25519.Signing.PrivateKey.signature(for:)` -- both are RFC 8032 Ed25519
     * over the raw message bytes (no prehash), so a signature made on one
     * platform verifies on the other.
     */
    fun sign(message: ByteArray, privateKey: ByteArray): ByteArray {
        require(privateKey.size == 32) { "Ed25519 private key must be 32 bytes" }
        val signer = Ed25519Signer()
        signer.init(true, Ed25519PrivateKeyParameters(privateKey, 0))
        signer.update(message, 0, message.size)
        return signer.generateSignature()
    }

    /**
     * Verify a 64-byte Ed25519 `signature` over `message` against a raw 32-byte
     * public key. Returns false (never throws) on a bad signature, a wrong key,
     * a malformed key/signature, or any other verification failure -- callers
     * treat ACK authentication as a boolean. Byte-identical operation to iOS
     * `Curve25519.Signing.PublicKey.isValidSignature(_:for:)`.
     */
    fun verify(message: ByteArray, signature: ByteArray, publicKey: ByteArray): Boolean {
        if (publicKey.size != 32 || signature.size != 64) return false
        return try {
            val signer = Ed25519Signer()
            signer.init(false, Ed25519PublicKeyParameters(publicKey, 0))
            signer.update(message, 0, message.size)
            signer.verifySignature(signature)
        } catch (_: Throwable) {
            false
        }
    }
}
