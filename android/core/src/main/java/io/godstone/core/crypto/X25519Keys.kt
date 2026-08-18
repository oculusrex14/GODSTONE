package io.godstone.core.crypto

import org.bouncycastle.crypto.generators.X25519KeyPairGenerator
import org.bouncycastle.crypto.params.X25519KeyGenerationParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import java.security.SecureRandom

/** Static Noise agreement-key generation backed by Bouncy Castle. */
object X25519Keys {
    fun generate(rng: SecureRandom): KeyPair {
        val generator = X25519KeyPairGenerator().apply {
            init(X25519KeyGenerationParameters(rng))
        }
        val pair = generator.generateKeyPair()
        val publicKey = (pair.public as X25519PublicKeyParameters).encoded
        val privateKey = (pair.private as X25519PrivateKeyParameters).encoded
        check(publicKey.size == 32 && privateKey.size == 32)
        return KeyPair(publicKey.copyOf(), privateKey.copyOf())
    }

    /**
     * Derive the 32-byte X25519 static DH public key from a raw 32-byte private key.
     */
    fun publicKeyFromPrivate(privateKey: ByteArray): ByteArray {
        require(privateKey.size == 32) { "X25519 private key must be 32 bytes" }
        val params = X25519PrivateKeyParameters(privateKey, 0)
        return params.generatePublicKey().encoded
    }
}
