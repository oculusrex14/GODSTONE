package io.godstone.core.crypto

import org.bouncycastle.crypto.generators.Ed25519KeyPairGenerator
import org.bouncycastle.crypto.params.Ed25519KeyGenerationParameters
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import java.security.SecureRandom

/** Raw Ed25519 public/private key material (32 bytes each). */
class KeyPair(val pub: ByteArray, val priv: ByteArray)

/** Long-term identity signing-key generation backed by Bouncy Castle. */
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
}
