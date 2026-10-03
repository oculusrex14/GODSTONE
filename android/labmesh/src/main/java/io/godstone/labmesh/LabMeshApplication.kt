package io.godstone.labmesh

import android.app.Application
import io.godstone.mesh.lab.LabEstatePlatform
import io.godstone.mesh.lab.LabEstateWipeAuthority
import io.godstone.mesh.lab.LabRuntime
import io.godstone.mesh.lab.LabWipeJourney
import io.godstone.mesh.lab.ProductionLabEstate
import io.godstone.mesh.lab.ProductionLabPlatform
import io.godstone.mesh.lab.RealEstateComposition
import io.godstone.mesh.runtime.ComposedEstateFactories

/**
 * T54 / GS-LAB-001 step 1 + GS-FINAL-003 `same-estate` (review A6/A6-expanded):
 * THE RETAINED LAB RUNTIME'S OWNER, GATED BY THE DURABLE RECOVERY AUTHORITY.
 *
 * *** THE REVIEW'S CHARGE: `LabMeshApplication.onCreate -> compose` must consult real same-estate startup authority
 * BEFORE normal identity/messages/acks/peer nodes; no test convenience always allow MeshNode on app path. ***
 *
 * *** AND THE CHARGE IS ANSWERED BY THE ORDER OF THE TWO LINES BELOW, NOT BY A COMMENT. *** *The recovery authority is
 * asked FIRST (`wipeJourney.progress()`), and only a SETTLED estate (`clean_start` / `wipe_completed`) reacheth
 * `composeRealEstate`; a REQUESTED/corrupt/terminal record therefore returns a `RealEstateComposition` whose `runtime`
 * is `null`, and NO identity, NO store, NO ACK row and NO peer node is created.*
 *
 * Under a typed nonterminal/corrupt estate the surface rendereth the RECOVERY-ONLY projection: the SAME durable record's
 * decision plus the real resume/operator-confirmed erasure verbs of [LabEstateWipeAuthority], never a cleared marker
 * pretending a clean start.
 */
open class LabMeshApplication : Application() {

    /**
     * *** THE SINGLE NAMED PLATFORM SUBSTITUTION POINT: THE TWO DOORS A JVM GENUINELY LACKS. ***
     *
     * *The production estate needs exactly two on-device facilities: the AndroidKeyStore-backed identity factory
     * (`EncryptedSharedPreferences`) and the SQLCipher native engine (whose `.so` a JVM lacketh).* **Those two doors
     * are the WHOLE of [LabEstatePlatform]; every other thing the estate doth -- the durable permit, the per-label
     * context view, the real file resolution, the retirement and the verification -- is the estate's own and is NEVER
     * substitutable.**
     *
     * *** A HOST PROCESS OVERRIDES THIS ONE METHOD WITH ITS OWN REAL ON-DISK PLATFORM -- its OWN temp-dir databases
     * and real files, never an in-memory stand-in -- AND LABELS ITSELF HOST RATHER THAN PHYSICAL. *** *The default is
     * the device's own doors, so an UNOVERRIDDEN lab walks the AndroidKeyStore and the SQLCipher engine and stays
     * fail-closed exactly as a device does.*
     */
    open fun estatePlatform(ctx: android.content.Context): LabEstatePlatform = ProductionLabPlatform

    /**
     * *** THE PLATFORM BOUNDARY, DECLARED AT THE OWNER RATHER THAN BURIED IN THE COMPOSITION. ***
     *
     * *The launchable lab's estate is the DEVICE's own: the isle's real identity factory (AndroidKeyStore-backed), the
     * real `SqliteMessageStore` (SQLCipher), the real ACK namespace and the real peer store -- each role over its own
     * real files.* **The ONLY substituted part is [estatePlatform], so a host proof cannot accidentally swap the
     * permit, the file resolution or the verification -- only the two unavailable doors.**
     */
    open fun estateFactories(ctx: android.content.Context): ProductionLabEstate =
        ProductionLabEstate(ctx, ProductionLabEstate.LABELS, estatePlatform(ctx))

    /** The ONE estate this process owns. Retained so the wipe and the send reach the SAME files. */
    val estate: LabEstateWipeAuthority by lazy { estateFactories(this) }

    /** The ONE durable recovery owner of this lab, over this application's own record and estate. */
    val wipeJourney: LabWipeJourney by lazy {
        // *** THE LIVE ESTATE IS RESOLVED AT *USE*, NEVER AT CONSTRUCTION (review A6). *** *Building the journey must
        // not compose the private graph: the provider below is the ONLY road by which the journey reacheth the runtime,
        // and it is touched only inside a wipe verb.*
        LabWipeJourney(
            this,
            estate = estate,
            liveEstateProvider = { composition.runtime },
        )
    }

    /**
     * *** THE ONE RETAINED COMPOSITION OF THIS LAB -- COMPUTED ONCE, BY THIS OWNER, NEVER BY A VIEW. ***
     *
     * *The consultation in [onCreate] precedes every private effect, and this road reckoneth the SAME decision from
     * the SAME durable owner once per node, before any identity, store, ACK row or peer node is created
     * (`LabRuntime.composeRealEstateOrRefuse`), re-reading it at each raw construction (`requireLiveFor`). A lazy
     * `val` at the OWNER is a once-only memo -- which is the difference between a retained runtime and a view
     * recomposing one on every frame (review A6: the runtime is the application's, never a view's).*
     */
    val composition: RealEstateComposition by lazy {
        LabMeshApp.composeRealEstate(this, estate)
    }

    /**
     * The normal private runtime, present iff the durable recovery authority admitted normal private composition.
     * When the estate stands at REQUESTED/corrupt/terminal-failure, this is `null` and a recovery-only projection
     * is rendered instead -- exactly zero private stores or keys exist.
     */
    val runtime: LabRuntime?
        get() = composition.runtime

    /** True once a normal private runtime hath been admitted and composed. */
    val hasRuntime: Boolean get() = composition.admitted

    override fun onCreate() {
        super.onCreate()
        // *** GS-FINAL-003 same-estate / review A6: CONSULT THE RECOVERY OWNER FIRST. ***
        // *`wipeJourney.progress()` reads this application's own `FileWipeJournal` through the SAME production
        // decision function the startup barrier uses -- and this consultation is the WHOLE of what process birth may
        // do. A private owner is created by exactly one road, the retained [composition], and EVERY such road consults
        // the same decision once per node BEFORE any identity, store, ACK row or peer node is created
        // (`LabRuntime.composeRealEstateOrRefuse`), re-reading it at each construction (`requireLiveFor`). So the
        // process can never reach a private effect that the durable record did not permit -- and the boot of a JVM
        // court is never the thing that walks a device-only door: the device doors (the AndroidKeyStore identity
        // factory, the SQLCipher engine) stand behind [estateFactories], fail-closed, exactly on a device.*
        val step = wipeJourney.progress()
        recoveredDecision = step.decisionName
        // *The record's OWN answer is retained for a reader (a court asserts the two agree). When a surface first
        // asketh for the runtime, the retained composition recomputeth the SAME answer through the SAME owner:
        // `composition.admitted` can be true only where this reading permitted.*
        admittedNormalGraph = step.permitsNormalComposition
    }

    /** The durable decision this process started on, in the isles' shared wire spelling. */
    var recoveredDecision: String = "clean_start"
        private set

    /** True iff the same-estate owner admitted a normal private graph at process start. */
    var admittedNormalGraph: Boolean = false
        private set
}
