package io.godstone.mesh.identity

import android.content.Context

/**
 * GS-STORE-006: **THE PRODUCTION `IdentityAuthoritySeam` FOR THIS ISLE** -- the ladder's last rung, `NEW_IDENTITY`, after
 * which the node rejoins the mesh as a STRANGER because the keys that made it who it was are gone.
 *
 * **IT USES THE ISLE'S OWN PATHS, BOTH OF THEM, RATHER THAN INVENTING EITHER:**
 *   * PUBLISHING is the isle's own wipe step -- `WipeArtifacts.regenerateIdentity()`, documented as "Generate + store a fresh
 *     identity (**and the KEK that protects it**)", which IS the operation the seam's verb names; and
 *   * NAMING is the isle's own identity path -- `Identity.loadOrCreate(ctx)`, whose `nodeHint` is the same four bytes this
 *     mesh elects on, so the name recorded in the wipe's journal is something the RUNTIME ITSELF COULD RECOGNISE rather than
 *     an opaque token invented here.
 *
 * **AND IT NAMES ITS OWN FAILURE RATHER THAN INVENTING A SUCCESS**: `regenerateIdentity()` can throw, and the seam's signature
 * demands a `String`; so a failed regeneration answers **A NAME THAT SAYS SO**, and the journal then carries the truth.
 * Returning a plausible-looking identifier for an identity that was never created would be the worst kind of lie in this
 * file: THE WIPE WOULD PROCEED TO `IDLE` BELIEVING THE NODE HAD A NEW IDENTITY WHEN IT HAD NONE.
 */
class WipeIdentityAuthoritySeam(
    private val ctx: Context,
    private val artifacts: WipeArtifacts,
) : IdentityAuthoritySeam {

    override fun publishNewIdentity(): String {
        return try {
            artifacts.regenerateIdentity()
            // THE ISLE'S OWN NAMING: the hint of the identity that now stands. If it cannot be read back, we do NOT claim
            // a name -- we say what happened.
            nameOf(Identity.loadOrCreate(ctx)) ?: GENERATION_FAILED
        } catch (e: Throwable) {
            GENERATION_FAILED
        }
    }

    override fun identity(): String? {
        return try {
            nameOf(Identity.loadOrCreate(ctx))
        } catch (e: Throwable) {
            // NO IDENTITY STANDS, AND `null` IS THE SEAM'S OWN VOCABULARY FOR THAT.
            null
        }
    }

    /** The identity's name for the wipe's journal: its node hint, hex-encoded -- the four bytes this mesh elects on. */
    private fun nameOf(identity: Identity): String? =
        identity.nodeHint.takeIf { it.isNotEmpty() }?.joinToString("") { "%02x".format(it) }

    companion object {
        /** The name recorded when the identity could not be published. IT SAYS WHAT HAPPENED; IT IS NOT AN IDENTIFIER. */
        const val GENERATION_FAILED: String = "identity-generation-failed"
    }
}
