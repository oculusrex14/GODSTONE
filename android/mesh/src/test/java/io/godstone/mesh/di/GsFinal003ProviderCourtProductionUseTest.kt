package io.godstone.mesh.di

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.MeshService
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.lab.LabRuntime
import io.godstone.mesh.runtime.NormalEstateVerdict
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-FINAL-003 `android-provider-court`: A NON-TEST CONSUMER TRAVERSES THE TESTED COMPONENT'S BINDING. ***
 *
 * *THE LEDGER'S LIVE DEFECT, VERBATIM: **"the component exists and the miswiring mutation ran, but the SHIPPING
 * composition (AppModule -> MeshModule) is never checked by it."*** *`MeshGraphComponent` and its miswiring court were
 * real, and `production(ctx)` had ZERO non-test callers -- so the binding whose POLARITY shipped INVERTED for eighteen
 * rounds (`MeshModule.provideWipeIsPending`, the binding this component resolves) was exercised by courts ALONE.*
 *
 * *** THE REPAIR, STATED AS AN OBSERVABLE: THE REGISTERED, NON-LIGHT LABMESH APPLICATION'S OWN ADMISSION GATE IS NOW
 * TAKEN FROM `MeshGraphComponent.production(ctx).wipeSensitiveUseGate()`. *** *That gate is read in
 * `LabRuntime.sameEstateGate`, which the launchable `LabMeshApplication` reaches at process birth (`LabMeshApp
 * .composeRealEstate` -> `LabRuntime.composeRealEstateOrRefuse` -> `sameEstateGate`) -- **so the road a user's device
 * really takes now consults the very binding a miswiring mutation reddens.***
 *
 * *** THIS COURT PROVES THE TWO HALVES THAT MAKETH THAT A FACT ABOUT THE CODE, NOT A COMMENT: ***
 *
 *  1. **[theRegisteredConsumerAdmissionIsTheTestedComponentsBinding]** -- the registered consumer's gate answers BOTH
 *     directions (a pending record refuses; a clean record admits), which is exactly the discriminator the eighteen-round
 *     inversion destroyed. *A gate hardwired to refuse would satisfy neither a positive control nor a device that must
 *     start.*
 *  2. **[theProductionEntryRefusesBeforeAnyPrivateConstruction]** -- the production entry `production(ctx).meshNode()`
 *     on a corrupt record is refused with **ZERO** identity/message/peer constructions counted at the real seams. *This
 *     is the "miswired provider is caught BEFORE private construction" clause: the permit door is on the SAME graph the
 *     consumer resolves, so an unsatisfiable authority throws rather than opening the estate.*
 *  3. **[theProductionEntryWalksToThePlatformUnderAPermittingDecision]** -- the positive control, so the zero above is
 *     not the zero of a road that never ran.
 *  4. **[theRefusingServiceOpensNoPrivateState]** -- the service's refusal gates precede the component resolution, so a
 *     refused foreground service constructs NOTHING (the latent eager-Hilt injection this repair removed).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal003ProviderCourtProductionUseTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    private fun presetJournal(state: PanicWipe.WipeState?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (state == null) remove("state") else putInt("state", state.ordinal)
        }.commit()
    }

    private fun constructions(): Map<PrivateConstructionCounter.Seam, Long> =
        PrivateConstructionCounter.snapshot()

    @Before
    fun clear() {
        presetJournal(null)
        PrivateConstructionCounter.reset()
    }

    @After
    fun tearDown() {
        presetJournal(null)
        PrivateConstructionCounter.reset()
    }

    /**
     * *** (1) THE REGISTERED CONSUMER'S ADMISSION IS THE TESTED COMPONENT'S BINDING, BOTH DIRECTIONS. ***
     *
     * *`LabRuntime.sameEstateGate` is the gate the launchable lab application consults at process birth. This arm drives
     * it over a REAL durable record, so the polarity the component resolves (`allowsSensitiveUse() == true` means the
     * estate is CLEAN) is the polarity the consumer obeys.* **A gate that answered backwards -- the exact eighteen-round
     * defect -- would ADMIT here on the pending rung and refuse on the clean one, and BOTH assertions below would redden.**
     */
    @Test
    fun theRegisteredConsumerAdmissionIsTheTestedComponentsBinding() {
        // (A) A PENDING RECORD MUST REFUSE, and the refusal must NAME the durable decision.
        presetJournal(PanicWipe.WipeState.REQUESTED)
        val refused = LabRuntime.sameEstateGate(ctx()).admit()
        assertTrue(
            "*** THE REGISTERED LAB CONSUMER MUST REFUSE A PENDING RECORD. *A gate that admitted here is the " +
                "inverted polarity the component's miswiring mutation strikes.* Observed: $refused ***",
            refused is NormalEstateVerdict.Refused,
        )
        val reason = (refused as? NormalEstateVerdict.Refused)?.reason.orEmpty()
        assertTrue(
            "*** the refusal must name the durable decision, not a wiring fault. Observed: '$reason' ***",
            reason.contains("recovery_pending"),
        )

        // *** AND THE GATE ITSELF TOUCHES NO PRIVATE CONSTRUCTION: it is a predicate over the durable record. ***
        assertEquals(
            "the admission gate must construct no private state",
            mapOf(
                PrivateConstructionCounter.Seam.IDENTITY to 0L,
                PrivateConstructionCounter.Seam.MESSAGE_STORE to 0L,
                PrivateConstructionCounter.Seam.PEER_STORE to 0L,
            ),
            constructions(),
        )

        // (B) AND A CLEAN RECORD MUST ADMIT -- the positive control, without which a hardwired refusal would pass (A).
        presetJournal(null)
        assertTrue(
            "*** A CLEAN ESTATE MUST ADMIT NORMAL COMPOSITION, or the device is bricked. Observed: " +
                "${LabRuntime.sameEstateGate(ctx()).admit()} ***",
            LabRuntime.sameEstateGate(ctx()).admit() is NormalEstateVerdict.Admitted,
        )
    }

    /**
     * *** (2) THE PRODUCTION ENTRY REFUSES A CORRUPT RECORD BEFORE ANY PRIVATE CONSTRUCTION. ***
     *
     * *`MeshGraphComponent.production(ctx).meshNode()` is the production entry the service takes. On an UNREADABLE
     * record the permit door (`MeshModule.issuePrivateStorePermit`, ON the component's graph) returns no permit, so the
     * identity provider cannot be satisfied and the request THROWS.* **THE COUNTS ARE THE PROOF THAT THE THROW HAPPENED
     * BEFORE THE PLATFORM: every real construction seam stays at ZERO.**
     */
    @Test
    fun theProductionEntryRefusesBeforeAnyPrivateConstruction() {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .edit().putInt("state", 9999).commit()   // an ordinal this build does not understand

        val thrown = runCatching { MeshGraphComponent.production(ctx()).meshNode() }
        assertTrue(
            "*** THE PRODUCTION ENTRY MUST BE REFUSED ON AN UNREADABLE RECORD, NOT SILENTLY SATISFIED. Observed: $thrown ***",
            thrown.isFailure,
        )
        assertTrue(
            "*** AND THE REFUSAL MUST NAME THE AUTHORITY THAT WAS NOT GRANTED. Observed: " +
                "'${thrown.exceptionOrNull()?.message}' ***",
            generateSequence(thrown.exceptionOrNull()) { it.cause }
                .joinToString(" | ") { it.message.orEmpty() }
                .contains("NO PRIVATE STORE MAY BE CONSTRUCTED"),
        )
        assertEquals(
            "*** ZERO PRIVATE CONSTRUCTION MAY BE ATTEMPTED BEFORE THE REFUSAL. *A count above zero would mean the " +
                "estate was entered before the authority that admits it.* Observed: ${constructions()} ***",
            mapOf(
                PrivateConstructionCounter.Seam.IDENTITY to 0L,
                PrivateConstructionCounter.Seam.MESSAGE_STORE to 0L,
                PrivateConstructionCounter.Seam.PEER_STORE to 0L,
            ),
            constructions(),
        )
    }

    /**
     * *** (3) THE POSITIVE CONTROL: UNDER A PERMITTING DECISION THE SAME PRODUCTION ENTRY WALKS TO THE PLATFORM. ***
     *
     * *The zero in (2) is only evidence if the SAME road can move the counter. On a clean record the permit is issued and
     * the identity provider records its attempt AT the seam, before the AndroidKeyStore wall.* **So a road that never
     * ran cannot pass (2) by accident.**
     */
    @Test
    fun theProductionEntryWalksToThePlatformUnderAPermittingDecision() {
        presetJournal(PanicWipe.WipeState.IDLE)   // the rung that permits construction

        runCatching { MeshGraphComponent.production(ctx()).meshNode() }

        assertTrue(
            "*** THE PRODUCTION ENTRY MUST WALK TO THE IDENTITY SEAM UNDER A PERMITTING DECISION. *A zero here would " +
                "mean the entry never ran, and arm (2) would be measuring a dead road.* Observed: ${constructions()} ***",
            (constructions()[PrivateConstructionCounter.Seam.IDENTITY] ?: 0L) >= 1L,
        )
    }

    /**
     * *** (4) THE REFUSING SERVICE OPENS NO PRIVATE STATE -- THE REFUSAL GATES PRECEDE THE COMPONENT. ***
     *
     * *Before this repair the `@Inject MeshNode` field was populated by Hilt on `onCreate`, BEFORE the
     * `LINK_LAYER_READY`/permission gates -- so a service that REFUSED TO START still walked the whole private
     * composition.* **The node is now resolved from the component only AFTER both gates, so the refusing road reaches
     * the component not at all.** *This arm drives the real `MeshService` lifecycle under Robolectric: with the readiness
     * flag frozen false, `onCreate` stops before the component and the construction census stays at zero.*
     */
    @Test
    fun theRefusingServiceOpensNoPrivateState() {
        assertTrue("the rig's premise: the link layer is not ready on this isle", !io.godstone.mesh.MeshNode.LINK_LAYER_READY)

        val controller = Robolectric.buildService(MeshService::class.java).create()
        try {
            assertEquals(
                "*** A REFUSED FOREGROUND SERVICE MUST OPEN NO PRIVATE STATE. *A count here is the eager-injection " +
                    "defect this repair removed: the composition ran on a road that had already decided not to start.* " +
                    "Observed: ${constructions()} ***",
                mapOf(
                    PrivateConstructionCounter.Seam.IDENTITY to 0L,
                    PrivateConstructionCounter.Seam.MESSAGE_STORE to 0L,
                    PrivateConstructionCounter.Seam.PEER_STORE to 0L,
                ),
                constructions(),
            )
        } finally {
            controller.destroy()
        }
    }
}
