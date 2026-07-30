// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.identity.Identity
import java.security.SecureRandom

/**
 * Test-only Identity factory. Generates a fresh, unpersisted identity so the
 * Noise and router tests never touch EncryptedSharedPreferences or a device.
 */
internal object MeshIdentity {
    fun generate(): Identity {
        val rng = SecureRandom()
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        return Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }
}
