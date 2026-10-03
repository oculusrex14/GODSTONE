package io.godstone.mesh.lab

import android.content.Context
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.PrivateOwnerToken
import io.godstone.mesh.store.JdbcStoreDb
import io.godstone.mesh.store.SqliteMessageStore
import io.godstone.mesh.store.StoreSchema
import java.security.SecureRandom

/**
 * *** GS-FINAL-003 `same-estate`: THE HOST PLATFORM -- THE TWO UNAVAILABLE DOORS SUBSTITUTED, NOTHING ELSE. ***
 *
 * *A JVM genuinely lacks exactly two facilities the production estate needs: the AndroidKeyStore-backed identity factory
 * (`EncryptedSharedPreferences`) and the SQLCipher native engine (whose `.so` a JVM lacketh).* **This platform
 * substitutes THOSE TWO DOORS ALONE -- deterministic in-memory key material for the identity, and the REAL on-disk
 * SQLite engine ([`JdbcStoreDb`], the same real-SQLite host backend the `:mesh` courts already drive) for the store --
 * and supplies its OWN temp on-disk database, never an in-memory stand-in.** *It labels itself HOST, not physical.*
 *
 * *** IT LIVETH IN `:mesh`'s `testFixtures` SOURCE SET SO BOTH COURTS SHARE ONE HOST PLATFORM. *** *The `:mesh` estate
 * court and the `:labmesh` journey courts each need to compose the SAME `ProductionLabEstate` over a host; a copy in the
 * lab module would be a second platform that could drift from this one.* **Everything the estate doth BESIDE these two
 * doors -- the durable permit, the per-label context view, the real file resolution, the retirement and the verification
 * -- is the estate's own and is NEVER substituted.**
 */
class HostLabPlatform(
    private val rng: SecureRandom = SecureRandom(),
) : LabEstatePlatform {

    /**
     * *Per-label key material, generated ONCE per label so the identity is STABLE across accesses.*
     *
     * *The label is recovered from the label context's own database DIRECTORY name, which is the per-label fact the
     * estate's [`LabLabelContext`] supplies and no other context carrieth.*
     */
    private val identities = LinkedHashMap<String, Identity>()

    override fun identityFor(labelCtx: Context, token: PrivateOwnerToken): Identity =
        identities.getOrPut(labelCtx.getDatabasePath(".").parentFile!!.name) {
            val ed = io.godstone.core.crypto.Ed25519Keys.generate(rng)
            val dh = io.godstone.core.crypto.X25519Keys.generate(rng)
            Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv)
        }

    /**
     * *The production SQLCipher engine is replaced by the host's REAL SQLite backend, writing to the VERY FILE the
     * estate nameth (`labelCtx.getDatabasePath`), so the estate's own `ownedFiles()` verification is about files that
     * really exist.*
     */
    override fun storeFor(labelCtx: Context, token: PrivateOwnerToken, maxBytes: Long): SqliteMessageStore {
        val f = labelCtx.getDatabasePath(StoreSchema.DB_NAME)
        f.parentFile?.mkdirs()
        return SqliteMessageStore(JdbcStoreDb(f), maxBytes)
    }
}
