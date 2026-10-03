package io.godstone.labmesh

import io.godstone.mesh.lab.HostLabPlatform
import io.godstone.mesh.lab.LabEstatePlatform

/**
 * *** GS-FINAL-003 `same-estate`: THE LAUNCHABLE LAB APPLICATION, OVER THE SHARED HOST PLATFORM. ***
 *
 * *THE A6 CHARGE WAS EXACTLY A HOST-SIDE SUBSTITUTION THAT SWAPPED THE REAL GRAPH FOR AN IN-MEMORY ONE; this is its
 * clean-cutover answer, living in the LAB COURT's own source set so the LAB MADE NO SECOND PLATFORM.*
 *
 * *** IT OVERRIDES THE ONE NAMED DOOR ([LabMeshApplication.estatePlatform]) WITH [`HostLabPlatform`] -- WHICH SUBSTITUTES
 * ONLY THE TWO FACILITIES A JVM LACKS: THE ANDROIDKEYSTORE IDENTITY FACTORY AND THE SQLCIPHER NATIVE ENGINE. ***
 * Everything else -- the durable permit minted over the app's own `FileWipeJournal`, the per-label real files, the
 * retirement and the verification -- is the PRODUCTION estate's, on the SAME road a device takes. **A REQUESTED/corrupt
 * record therefore leaves `runtime` null exactly as on a device, and the recovery-only surface is rendered.**
 *
 * *The `:mesh` `testFixtures` source set is the single home of [`HostLabPlatform`], so the `:mesh` estate court and these
 * journey courts drive ONE host platform rather than two that could drift.*
 */
class LabHostApplication : LabMeshApplication() {
    override fun estatePlatform(ctx: android.content.Context): LabEstatePlatform = HostLabPlatform()
}
