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
 * *** AND IT NAMES ITS OWN FAILURE IN THE SEAM'S OWN TYPED VOCABULARY RATHER THAN INVENTING A SUCCESS. ***
 *
 * THE `IdentityAuthoritySeam` CONTRACT WAS WIDENED TO `String?` FOR EXACTLY THIS CASE, AND ITS OWN DOCSTRING SAYETH SO:
 * *"`null` MEANS **NOT PUBLISHED**, and the ladder must therefore STAY PENDING rather than reach `IDLE`."* **THIS
 * PRODUCTION SEAM USED TO ANSWER A NON-NULL SENTINEL (`"identity-generation-failed"`) ON EVERY FAILURE PATH -- SO THE
 * COORDINATOR'S `publishNewIdentity() == null` GUARD COULD NEVER FIRE HERE, AND THE WIPE ADVANCED TO `IDLE` BELIEVING A
 * NEW IDENTITY STOOD WHEN NONE DID.** *A name that "says what happened" is honest PROSE, but it is not the seam's
 * NEGATIVE CHANNEL, and prose is what the ladder cannot branch on -- the SAME defect class this finding retired on the
 * startup decision (`reason.contains(...)` for `cause`).*
 *
 * *** THE TWO DISTINCT FAILURES ARE NOW BOTH `null`, AND BOTH KEEP THE WIPE PENDING. ***
 *   * the REGENERATION threw, or
 *   * the regeneration succeeded and `Identity.loadOrCreate` could read back NO identity (or no name).
 * *A LATER COMPOSITION WITH A LIVE KEYSTORE RESUMES AND PUBLISHETH A REAL NAME; the durable journal keeps the truth
 * (`ARTIFACTS_DELETED`, not `NEW_IDENTITY`), which is what "preserve errors for resume" requires here.*
 */
class WipeIdentityAuthoritySeam(
    private val ctx: Context,
    private val artifacts: WipeArtifacts,
) : IdentityAuthoritySeam {

    /**
     * *** THE RECOVERY-ONLY MATERIAL OPS: THE LAST RUNG WITHOUT A NORMAL-IDENTITY CONSTRUCTION. ***
     *
     * *THE PARENT'S RULING, EXECUTED: **"Recovery identity publication must NOT instantiate normal Identity before
     * permit."*** *What stood here called `artifacts.regenerateIdentity()` -- which for the production artifacts IS
     * `Identity.loadOrCreate`, **the NORMAL private-identity factory** -- and then called it a SECOND time to read back a
     * name.* **AND THE ERASE THAT MUST PRECEDE A REPLACEMENT WAS NEVER ON THIS ROAD AT ALL: no artifact name addressed
     * `godstone_identity`, so an existing encrypted identity survived the master-KEK deletion and the replacement could not
     * decrypt or replace it (review finding A4).**
     *
     * *** SO THE RUNG IS NOW: ERASE (verified) -> REGENERATE-AND-NAME (via the isle's own generator, not the permit-gated
     * factory) -> NAME-OR-NULL. *** *And `Identity.loadOrCreate` is reached only INSIDE
     * [`RecoveryIdentityMaterial.regenerateAndName`], as a recovery EFFECT rather than as a normal construction.*
     */
    private val material = RecoveryIdentityMaterial(ctx)

    override fun publishNewIdentity(): String? {
        // *** (1) THE ERASE THAT WAS MISSING: if the surviving identity material cannot be destroyed, the wipe must NOT
        // advance -- a replacement published over surviving ciphertext is the false success finding A4 names. ***
        if (!material.erase()) return null
        // *** (2) REGENERATE AND NAME. `artifacts.regenerateIdentity()` is KEPT so the runtime-side artifacts' own
        // invalidation ordering (the `RuntimeAwareWipeArtifacts` wrapper) is not bypassed -- *it is the caller's delegate
        // that decides whether that act is a normal construction, and on the recovery road it is not.*
        //
        // *** AND ITS THROW IS THE SEAM'S OWN NEGATIVE CHANNEL, NOT AN ESCAPE: *** *`WipeArtifacts.regenerateIdentity()`
        // is documented to throw (the fake the court supplies driveth a keystore-shaped `IllegalStateException`), and a
        // throw that escaped this method was NOT the typed `null` the coordinator's `publishNewIdentity() == null` guard
        // branches on -- it was an exception leaving a `String?` method, so the ladder's last rung crashed the wipe
        // instead of holding it PENDING.* **The design's negative is `null`; a regeneration that did not produce an
        // identity IS that negative, and the journal therefore stays at `ARTIFACTS_DELETED` and RESUMES honestly.***
        // *The throwable is NOT swallowed: its own class and message are the prose this seam's companion keeps for the
        // log, so a genuinely-unexpected error class stays VISIBLE even as the ladder gets its typed refusal.*
        try {
            artifacts.regenerateIdentity()
        } catch (e: Throwable) {
            android.util.Log.w(TAG, "$GENERATION_FAILED_REASON: the artifacts' regeneration threw", e)
            return null
        }
        // *** (3) NAME-OR-NULL: the seam's own typed negative channel, never a sentinel string. ***
        return material.regenerateAndName()
    }

    /**
     * *** `identity()` HAS NO CALLER, AND THE HONEST ANSWER HERE IS A READ THE OWNER WILL SUPPLY. ***
     *
     * *IT USED TO CALL `Identity.loadOrCreate(ctx)` -- **a CREATION dressed as a READ**, and the very normal-identity road
     * the parent ruled must not be instantiated on the recovery surface.* **AND THE COORDINATOR NEVER ASKETH THIS METHOD:
     * `grep -n "authority.identity()"` across `:mesh` returneth NOTHING (`CrashResumableWipe` calls only
     * `publishNewIdentity()`), so this body is unreachable from every production road today.**
     *
     * *** SO IT ANSWERS `null` -- "NO IDENTITY IS CLAIMED" -- RATHER THAN INVENTING ONE BY READING A CREATION. *** *When a
     * NON-creating read factory lands (a genuine `Identity.load`), this is the one line to point at it; until then, `null`
     * is the only answer that is not a lie, and the `IdentityAuthoritySeam` contract already spells `null` as NOT
     * PUBLISHED.*
     */
    override fun identity(): String? = null

    companion object {
        /**
         * *The log tag for the seam's own failure records; the `GENERATION_FAILED_REASON` prose liveth below.*
         */
        private const val TAG = "GodstoneWipeIdentity"

        /**
         * *** THE HUMAN-READABLE RECORD OF A FAILED PUBLICATION -- AND IT IS NOT A WIPE-JOURNAL NAME. ***
         *
         * *It USED to be returned by [publishNewIdentity] on every failure path, WHICH IS THE DEFECT IT NOW NAMETH: a
         * sentinel `String` satisfied the coordinator's `!= null` check, so the ladder advanced to `NEW_IDENTITY`/`IDLE`
         * over an identity that was never created.* **It is retained ONLY as the prose a ring or a log may carry; the
         * TYPED negative channel (`null`) is what the ladder branches on.**
         */
        const val GENERATION_FAILED_REASON: String = "identity-generation-failed"
    }
}
