// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.core.crypto

import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import java.security.SecureRandom

/**
 * Minimal holder for a generated public/private key pair. Both arrays are the
 * raw encoded forms (no ASN.1 wrapping) so callers can persist or transmit them
 * directly.
 */
class KeyPair(val pub: ByteArray, val priv: ByteArray)

/**
 * Ed25519 key generation backed by BouncyCastle, used for the long-term
 * identity signing key.
 */
object Ed25519Keys {
    fun generate(rng: SecureRandom): KeyPair {
        val gen = Ed25519KeyPairGenerator()
        gen.init(Ed25519KeyGenerationParameters(rng))
        val pair = gen.generateKeyPair()
        val pub = pair.public.encoded    // Ed25519PublicKeyParameters, 32 bytes
        val priv = pair.private.encoded  // Ed25519PrivateKeyParameters, 32 bytes
        return KeyPair(pub, priv)
    }
}