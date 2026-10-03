package io.godstone.mesh

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.identity.Identity
import java.security.SecureRandom

/**
 * *** THE IN-MEMORY IDENTITY FACADE THE COURTS AND THE iOS TWIN ALREADY NAME -- LANDED SO THE WORKER CLASSPATH
 * COMPILES. ***
 *
 * *MEASURED: two Android suites (`ReadinessT72Test`, `ReadinessT08Test`) call `MeshIdentity.generate()` and import
 * `io.godstone.mesh.MeshIdentity`, **AND THE SYMBOL DID NOT EXIST ANYWHERE IN `:mesh` MAIN** -- so
 * `:mesh:compileDebugUnitTestKotlin` could not resolve it and the whole Android worker classpath was red.* **The iOS
 * isle carrieth the twin of this name (`MeshIdentity.loadOrCreate(keychain:)` / `generateAndStore(keychain:)`), so the
 * Android omission was a two-isle asymmetry rather than a missing idea.**
 *
 * *** IT IS DELIBERATELY THE **LOW-LEVEL GENERATOR**, NOT A SECOND PRIVATE-OWNER ROAD. *** *Finding A13 closed the raw
 * constructors precisely so no new public surface could open private material beside the permit graph; therefore this
 * facade carrieth the ONE operation a court genuinely needs and that touches NO device resource, NO keystore and NO
 * durable store: **produce a fresh in-memory identity from the CSPRNG.***
 *
 *   * *it minteth nothing that outliveth the process* -- there is no persistence, no `Context` and no permit, so it
 *     cannot become a bypass of the estate authority;
 *   * *the persisted, permit-gated roads are named where they belong:* **`Identity.loadOrCreate(ctx, token)`** for a
 *     NORMAL private identity under a verified same-estate permit, and **`Identity.regenerateForRecovery(ctx)`** (behind
 *     `RecoveryIdentityMaterial`) for the wipe's last rung. *This facade is neither of those and must not grow into
 *     them.*
 */
object MeshIdentity {

    /**
     * *** A FRESH IN-MEMORY IDENTITY, DERIVED FROM THE ISLE'S OWN KEY GENERATORS. ***
     *
     * *The public key is DERIVED from the private seed inside [Identity.fromKeyMaterial], which REFUSETH a mismatch --
     * so this cannot mint an identity whose advertised public half disagrees with its secret half.*
     */
    fun generate(rng: SecureRandom = SecureRandom()): Identity {
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        return Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
    }
}
