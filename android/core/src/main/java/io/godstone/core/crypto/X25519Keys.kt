// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.core.crypto

import org.bouncycastle.crypto.generators.X25519KeyPairGenerator
import org.bouncycastle.crypto.params.X25519KeyGenerationParameters
import java.security.SecureRandom

/**
 * X25519 key generation backed by BouncyCastle, used for the static Noise
 * Diffie-Hellman key.
 */
object X25519Keys {
    fun generate(rng: SecureRandom): KeyPair {
        val gen = X25519KeyPairGenerator()
        gen.init(X25519KeyGenerationParameters(rng))
        val pair = gen.generateKeyPair()
        val pub = pair.public.encoded    // X25519PublicKeyParameters, 32 bytes
        val priv = pair.private.encoded  // X25519PrivateKeyParameters, 32 bytes
        return KeyPair(pub, priv)
    }
}