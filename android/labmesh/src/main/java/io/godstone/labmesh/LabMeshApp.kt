package io.godstone.labmesh

import io.godstone.mesh.lab.LabProfile
import io.godstone.mesh.lab.LabRuntime

// ---------------------------------------------------------------------------
// T54 -- the LabMesh Android target's application seam.
//
// This module carrieth the lab's OWN application identity (io.godstone.labmesh,
// declared in build.gradle.kts) and nothing else: the runtime it driveth is the
// canonical one, reached through `io.godstone.mesh.lab.LabRuntime`, which liveth
// in the nonshipping :mesh module. There is no lab-only copy of any authority,
// and no way to manufacture readiness from here.
// ---------------------------------------------------------------------------

/** The lab application's own marker, carrying the identity and profile a reader
 *  (and the profile gate) can inspect without starting a runtime. */
object LabMeshApp {
    /** This lab's application identity -- never the shipping one. */
    const val APPLICATION_ID: String = LabProfile.LAB_APPLICATION_ID

    /** The shipping identity the lab may never masquerade as. */
    const val SHIPPING_APPLICATION_ID: String = LabProfile.SHIPPING_APPLICATION_ID

    /** The profile this build carrieth. */
    const val PROFILE: String = LabProfile.NAME

    /** True iff this build is experimental. It is. */
    const val EXPERIMENTAL: Boolean = LabProfile.EXPERIMENTAL

    /** True iff this build can manufacture crypto readiness. It cannot. */
    const val MANUFACTURES_READINESS: Boolean = LabProfile.MANUFACTURES_READINESS

    /** Compose the real runtime the lab driveth (the default A <-> R <-> B chain). */
    fun compose(): LabRuntime = LabRuntime.compose()

    /** Compose the real runtime with the caller's own peer labels. */
    fun compose(labels: List<String>): LabRuntime = LabRuntime.compose(labels)

    /** The honest readiness statement (all platform fields false). */
    fun readiness() = LabRuntime.readinessStatement()
}
