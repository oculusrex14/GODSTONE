package io.godstone.labmesh

import android.content.Context
import io.godstone.mesh.lab.LabEstateWipeAuthority
import io.godstone.mesh.lab.LabProfile
import io.godstone.mesh.lab.LabRuntime
import io.godstone.mesh.lab.RealEstateComposition

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

    /**
     * *** GS-FINAL-003 `same-estate` (review A6): THE LAUNCHABLE LAB APPLICATION'S OWN COMPOSITION ROAD. ***
     *
     * *THE OBLIGATION: "Use production normal owner with actual on-disk stores/real identity and same runtime authority
     * Send/SOS operate. No fake in-memory under real app."* **SO THE ESTATE IS NOT A PARAMETER WITH A NULLABLE DEFAULT:
     * it is the REQUIRED capability whose files the send road writes and the wipe erases.** *A caller cannot reach this
     * road without naming the estate -- which is exactly the A6 defect made unexpressible.*
     *
     * The same-estate recovery owner is consulted BEFORE any normal private composition (inside
     * `LabRuntime.composeRealEstateOrRefuse`), so a REQUESTED/corrupt/terminal record yields a runtime-less
     * [RealEstateComposition] and a rendered recovery-only projection.
     */
    fun composeRealEstate(
        ctx: Context,
        estate: LabEstateWipeAuthority,
    ): RealEstateComposition = LabRuntime.composeRealEstateOrRefuse(ctx, estate)

    /** Compose the host resource-model runtime (pure JVM tests only; explicitly NOT on the application path). */
    fun compose(): LabRuntime = LabRuntime.composeForHostTests()

    /** Compose the host resource-model runtime with caller's own peer labels. */
    fun compose(labels: List<String>): LabRuntime = LabRuntime.composeForHostTests(labels)
    /** The honest readiness statement (all platform fields false). */
    fun readiness() = LabRuntime.readinessStatement()
}
