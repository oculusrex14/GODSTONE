package io.godstone.labmesh

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import io.godstone.mesh.a11y.AccessibilityContract
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.lab.LabRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-UX-001 `rendered-controls` (Android isle): THE RENDERED JOURNEY, BOUND TO THE REAL RUNTIME. ***
 *
 * *THE GAP THIS COURT CLOSES, STATED PLAINLY: `LabMeshJourneySemanticsTest` proveth the SCREEN's semantics -- it drives
 * `LabJourneyState` values and reads the rendered tree -- and it sayeth nothing about whether a rendered journey REACHES
 * DURABLE AUTHORITY. A screen whose callbacks were `{}` would pass every arm there, because those arms judged the tree,
 * not the commands. **AND THAT WAS THE SHIPPING STATE: `LabMainActivity` showed a `TextView`, and `LabJourneyState`'s
 * `= {}` defaults meaned a caller could render the whole journey with every command silently absent.***
 *
 * THIS COURT DRIVES THE REAL BINDING: `LabJourneyBindings` over the LAUNCHABLE application's own retained
 * `io.godstone.mesh.lab.LabRuntime` (composed by `LabMeshApplication` over its real `ProductionLabEstate`, whose two
 * unavailable platform doors -- the AndroidKeyStore identity factory and the SQLCipher engine -- this court substitutes
 * through the application's ONE named `estatePlatform` door with real on-disk SQLite).
 * Then it reads the RENDERED tree, and the discriminator in every arm is that **the rendered value is a READ OF THE
 * RUNTIME'S OWN ROW**: the message id on screen is the `msg_id` the durable enqueue committed, and the label is
 * `MeshNode.deliveryProjection`'s honest `DeliveryLabel`.
 *
 * *** WHY A VIEW-LOCAL STRING CANNOT SATISFY IT. *** *Every arm asserteth the rendered value AGAINST the runtime's own
 * estate (`heldMsgIdOf`/`deliveryLabelOf`/`activeSosStateOf`). A screen that remembered its own sentence would render a
 * string the estate does not carry, and the equality would fail -- which is the whole difference between "the obligation
 * was discharged" and "the obligation was talked about".*
 *
 * *** AND THE DISPATCHER IS THE COURT'S OWN, UNCONFINED. *** *`LabJourneyBindings` launches its writes on the scope it
 * was handed; the activity handeth it `lifecycleScope`. Here the scope is backed by `Dispatchers.Unconfined`, so a
 * command's `suspend` write runs TO COMPLETION inline and the surface can be read the moment the control is clicked --
 * a queued dispatcher would leave the court reading the surface BEFORE the command landed.*
 *
 * THE EXTERNAL BOUNDARY IS NAMED RATHER THAN WEAKENED: the lab composes over a deterministic clock and a recording radio
 * (`LinkFacade`), so this court proves a RENDERED journey reaching the DURABLE authority; the AndroidKeyStore/device
 * boundary and the physical radio remain EXTERNAL, exactly as `LabProfile` stateth.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33], application = LabHostApplication::class)
class LabMeshJourneyBoundTest {

    @get:Rule
    val composeRule = createComposeRule()

    private fun node(tag: String): SemanticsNodeInteraction = composeRule.onNodeWithTag(tag)

    private fun stateDescriptionOf(tag: String): String? = try {
        val config = node(tag).fetchSemanticsNode().config
        if (config.contains(SemanticsProperties.StateDescription)) {
            config[SemanticsProperties.StateDescription]
        } else null
    } catch (_: Throwable) {
        null
    }

    private fun textOf(tag: String): String? = try {
        val config = node(tag).fetchSemanticsNode().config
        if (config.contains(SemanticsProperties.Text)) {
            config[SemanticsProperties.Text].joinToString(" ") { it.text }
        } else null
    } catch (_: Throwable) {
        null
    }

    /** The runtime's own `suspend` reads, awaited from a host court. */
    private fun <T> awaited(block: suspend () -> T): T = runBlocking { block() }

    /**
     * *** THE RETAINED COMPOSITION, OVER THIS COURT'S OWN CLEAN RECORD. ***
     *
     * *The durable record is the premise, so the helper clears it BEFORE the application's retained composition
     * first runs -- a REQUESTED record would (correctly) leave `runtime` null, and the send/SOS arms need the admitted
     * graph.* **`LabHostApplication` is installed by `@Config(application = ...)`, so Robolectric really calls
     * `onCreate` on the LAUNCHABLE owner and the ONE retained composition is the application's, never this court's.**
     */
    private fun admittedRuntime(ctx: android.content.Context): LabRuntime {
        val app = androidx.test.core.app.ApplicationProvider.getApplicationContext<LabHostApplication>()
        ctx.getSharedPreferences("godstone_wipe_journal", android.content.Context.MODE_PRIVATE)
            .edit().remove("state").remove("epoch").commit()
        val runtime = app.runtime
        org.junit.Assert.assertNotNull(
            "*** A CLEAN HOST RECORD MUST ADMIT THE REAL ESTATE'S NORMAL PRIVATE COMPOSITION. ***",
            runtime,
        )
        return runtime!!
    }

    /**
     * Bind the REAL runtime to the REAL screen and hand back the bindings.
     *
     * *The screen is rendered with the SAME `StateFlow` the activity collecteth; the court reads the bound values
     * directly, which is what maketh the assertion about the RUNTIME rather than about a composition detail.*
     */
    private fun bind(runtime: LabRuntime): LabJourneyBindings {
        // *** THE DURABLE WIPE OWNER IS THE PRODUCTION ONE, OVER THIS COURT'S REAL CONTEXT. *** *`ApplicationProvider`
        // gives the Robolectric application, so `LabWipeJourney` opens the isle's OWN `FileWipeJournal` -- the same file
        // the startup barrier uses -- and the wipe arms below are therefore about the durable record rather than about
        // a register this court kept.*
        val bindings = LabJourneyBindings(
            runtime,
            CoroutineScope(Dispatchers.Unconfined),
            io.godstone.mesh.lab.LabWipeJourney(
                androidx.test.core.app.ApplicationProvider.getApplicationContext(),
                liveEstate = runtime,
            ),
        )
        bindings.refresh()
        composeRule.setContent {
            Box(Modifier.width(360.dp)) {
                LabMeshJourneyScreen(state = composeValueOf(bindings.state), onSend = bindings::send)
            }
        }
        composeRule.waitForIdle()
        return bindings
    }

    /**
     * *** THE FULL RENDERED JOURNEY: SELECT, TYPE, SEND -- AND THE RENDERED ID COMES FROM THE RUNTIME'S ROW. ***
     */
    @Test
    fun test_the_rendered_journey_sendeth_and_renders_the_runtimes_own_durable_id() {
        val runtime = admittedRuntime(androidx.test.core.app.ApplicationProvider.getApplicationContext())
        val bindings = bind(runtime)

        // (a) THE RECIPIENT LIST IS THE RUNTIME'S OWN LABEL SET (never a list the screen invented).
        assertEquals(
            "*** THE RECIPIENTS ON SCREEN MUST BE THE RUNTIME'S OWN LABELS. ***",
            runtime.labels.filter { it != bindings.author }, bindings.recipients,
        )

        // (b) SELECT THE RECIPIENT, AND TYPE.
        val recipient = bindings.recipients.last()
        node(LabControl.RECIPIENT_CANDIDATE + ":" + recipient).performClick()
        composeRule.waitForIdle()
        val body = "the river riseth at dawn and the bridge at Harrow is under two feet of water"
        node(LabControl.COMPOSE_BODY).performTextInput(body)
        composeRule.waitForIdle()
        assertEquals(
            "the octet readout must measure the typed body",
            "${octetsOf(body)} of $MESSAGE_BODY_MAX octets used",
            stateDescriptionOf(LabControl.OCTETS),
        )

        // (c) SEND: the rendered control's callback drives the runtime's own durable enqueue.
        node(LabControl.COMPOSE_SEND).performScrollTo().performClick()
        composeRule.waitForIdle()

        // (d) *** THE DURABLE WITNESS: THE RENDERED ID IS THE STORE'S OWN `msg_id`. ***
        val durableId = awaited { runtime.heldMsgIdOf(bindings.author) }
        assertNotNull("*** A SEND MUST COMMIT A HELD FRAME TO THE REAL STORE. ***", durableId)
        val rendered = textOf(LabControl.DURABLE)
        val expectedId = LabJourneyBindings.hexOf(durableId!!)
        assertTrue(
            "*** THE ID RENDERED MUST BE THE ID THE DURABLE ENQUEUE COMMITTED -- A VIEW-LOCAL STRING CANNOT " +
                "SATISFY THIS. Rendered: $rendered, durable: $expectedId ***",
            rendered != null && rendered.contains(expectedId),
        )
        assertEquals(
            "*** AND THE SEND MUST COMMIT EXACTLY ONE MESSAGE. ***",
            1, awaited { runtime.heldMsgIdsOf(bindings.author) }.size,
        )

        // (e) *** AND THE LABEL IS THE RUNTIME'S OWN PROJECTION OF THAT ROW. ***
        val expectedLabel = runtime.deliveryLabelOf(bindings.author, durableId)
        assertEquals(
            "*** THE RENDERED LABEL MUST BE THE HONEST LABEL THE DURABLE ROW SUPPORTETH. ***",
            expectedLabel, stateDescriptionOf(LabControl.DURABLE),
        )
        assertEquals(
            "*** AND THE STATE WORDS MUST BE THE SHARED VOCABULARY'S WORD FOR THAT LABEL. ***",
            stateWordsForLabel(expectedLabel), stateDescriptionOf(LabControl.OUTCOME),
        )
        assertEquals(
            "*** A DIRECTED MESSAGE HANDED TO A RELAY IS QUEUED, NEVER DELIVERED BEFORE ITS ACK. ***",
            DeliveryState.QUEUED_DURABLY, runtime.durableStateOf(bindings.author, durableId),
        )

        // (f) *** AND THE OUTCOME THE SCREEN RENDERETH IS THE COMPOSITION'S OWN VERDICT. ***
        assertTrue(
            "*** THE OUTCOME MUST CARRY THE COMPOSITION'S OWN VERDICT. Observed: ${textOf(LabControl.OUTCOME)} ***",
            textOf(LabControl.OUTCOME)?.startsWith("applied:") == true,
        )
    }

    /**
     * *** A NEGATIVE CONTROL: A SCREEN THAT REMEMBERED ITS OWN STRING WOULD FAIL THIS COURT. ***
     *
     * *The absent half is asserted beside the present one: before any command, the runtime carrieth no message and the
     * rendered readout must SAY so. **A court whose equality could be satisfied by any nonempty string would certify
     * nothing**, which is why an unsubmitted journey is asserted here.*
     */
    @Test
    fun test_the_durable_readout_is_absent_until_the_runtime_committeth() {
        val runtime = admittedRuntime(androidx.test.core.app.ApplicationProvider.getApplicationContext())
        val bindings = bind(runtime)
        assertNull(
            "nothing was authored, so the runtime carrieth no message",
            awaited { runtime.heldMsgIdOf(bindings.author) },
        )
        assertTrue(
            "*** AND THE RENDERED READOUT MUST SAY SO -- a screen that rendered an id here would be remembering " +
                "something the estate never committed. Observed: ${textOf(LabControl.DURABLE)} ***",
            textOf(LabControl.DURABLE)?.contains("none") == true,
        )
        assertEquals(
            "the label must be the honest absence, not a status",
            LabJourneyBindings.NO_LABEL, stateDescriptionOf(LabControl.DURABLE),
        )
    }

    /**
     * *** THE SOS JOURNEY: ARM THROUGH THE NODE'S OWN COMMAND DOOR, THEN CANCEL -- BOTH DURABLE. ***
     */
    @Test
    fun test_the_rendered_sos_arm_and_cancel_reach_the_nodes_own_durable_row() {
        val runtime = admittedRuntime(androidx.test.core.app.ApplicationProvider.getApplicationContext())
        val bindings = bind(runtime)

        node(LabControl.SOS_ARM).performScrollTo().performClick()
        composeRule.waitForIdle()

        // *** ARMED: THE MESSAGE ID COMES FROM THE NODE'S OWN DURABLE SOS PROJECTION. ***
        val armedId = awaited { runtime.activeSosMsgIdOf(bindings.author) }
        assertNotNull("*** ARMING THROUGH THE RENDERED CONTROL MUST COMMIT A DURABLE SOS ROW. ***", armedId)
        assertEquals(
            "*** THE SOS STATE WORDS MUST BE THE SHARED WORD FOR THE ROW'S OWN STATE. ***",
            stateWordsForState(awaited { runtime.activeSosStateOf(bindings.author) }),
            stateDescriptionOf(LabControl.SOS_STATE),
        )

        // *** AND CANCEL: THE ROW MOVETH TERMINAL, AND THE RENDERED WORDS FOLLOW IT. ***
        node(LabControl.SOS_CANCEL).performScrollTo().performClick()
        composeRule.waitForIdle()
        assertEquals(
            "*** CANCELLING THROUGH THE RENDERED CONTROL MUST MOVE THE DURABLE ROW TERMINAL. ***",
            DeliveryState.CANCELLED_LOCALLY,
            runtime.durableStateOf(bindings.author, armedId!!),
        )
        assertNull(
            "*** AND NO ACTIVE PROJECTION MAY STAND AFTER A CANCELLATION. ***",
            awaited { runtime.activeSosStateOf(bindings.author) },
        )
        assertEquals(
            "*** THE RENDERED SOS WORDS MUST FOLLOW THE DURABLE ROW INTO ITS TERMINAL STATE. ***",
            AccessibilityContract.STATE_WORDS.getValue("CANCELLED"),
            stateDescriptionOf(LabControl.SOS_STATE),
        )
    }

    /**
     * *** GS-FINAL-003 `durable-authority`: THE RENDERED WIPE CONTROL REACHES THE PRODUCTION DURABLE RECORD. ***
     *
     * *THE OBLIGATION'S WORDS: **"rendered wipe UI uses SAME durable production wipe owner (no composition harness
     * local state register)"** -- and the discriminator is a REOPEN.* **A RENDERED click must move the isle's own
     * `FileWipeJournal`, and a FRESH OWNER over the same file must see it.** *A screen (or a harness) keeping its own
     * register would render a stage while the durable record stood at `IDLE`, which is what this arm forbids.*
     */
    @Test
    fun test_the_rendered_wipe_reaches_the_durable_record_and_survives_a_reopen() {
        val ctx = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.content.Context>()
        // *** START FROM A KNOWN CLEAN RECORD: the record IS the premise, so the arm sets it rather than assuming it.
        ctx.getSharedPreferences("godstone_wipe_journal", android.content.Context.MODE_PRIVATE)
            .edit().remove("state").commit()
        val runtime = admittedRuntime(androidx.test.core.app.ApplicationProvider.getApplicationContext())
        val bindings = bind(runtime)

        // (a) CLEAN: the rendered stage is the DURABLE record's rung, not a placeholder.
        assertEquals(
            "*** A CLEAN DEVICE MUST RENDER THE CLEAN RUNG, READ FROM THE RECORD. Observed: " +
                "${stateDescriptionOf(LabControl.WIPE_STATE)} ***",
            "IDLE", stateDescriptionOf(LabControl.WIPE_STATE),
        )

        // (b) WIPE: the RENDERED control drives the production graph, which advances the real ladder.
        node(LabControl.WIPE_BEGIN).performScrollTo().performClick()
        composeRule.waitForIdle()
        // *** THE RUNG IS WHATEVER THE REAL CAPABILITIES REACHED -- NOT A PINNED ONE. *** *The pre-private vault
        // reacheth the AndroidKeyStore, which a JVM lacks, so the ladder stops at the rung whose owner refused and STAYS
        // PENDING -- the honest, crash-resumable answer. Pinning `REQUESTED` would be a claim that the graph CANNOT
        // advance, which is the very defect the obligation names; the recorded run reached `RUNTIME_DRAINED`.* **The
        // laws that hold on BOTH the host and a device are: the record MOVED off `IDLE`, and the rendered status AGREES
        // with the record.**
        val movedOrdinal = ctx.getSharedPreferences("godstone_wipe_journal", android.content.Context.MODE_PRIVATE)
            .getInt("state", -1)
        assertNotEquals(
            "*** THE RENDERED REQUEST MUST MOVE THE DURABLE RECORD OFF `IDLE` -- a register cannot produce it. ***",
            PanicWipe.WipeState.IDLE.ordinal, movedOrdinal,
        )
        assertEquals(
            "*** AND THE RENDERED STATUS MUST BE THE RECORD'S OWN RUNG -- the stage is a READING, not a message the " +
                "screen composed. ***",
            PanicWipe.WipeState.entries[movedOrdinal].name, stateDescriptionOf(LabControl.WIPE_STATE),
        )

        // (c) REOPEN: a FRESH owner over the same durable record -- what a relaunch is.
        val reopened = io.godstone.mesh.lab.LabWipeJourney(ctx).progress()
        assertNotEquals(
            "*** A RELAUNCH MUST SEE THE PERSISTED WIPE. A surface with its own register would read CLEAN here. ***",
            WipeJournalState.IDLE, reopened.rung,
        )
        assertEquals(
            "*** AND THE REOPENED OWNER MUST AGREE WITH THE RECORD, not with a remembered stage. ***",
            PanicWipe.WipeState.entries[movedOrdinal].name, reopened.rung.name,
        )
        assertTrue(
            "*** AND THE PRODUCTION RETRY CONTRACT MUST PERMIT A RESUME OF A PARKED WIPE. ***",
            reopened.permitsResume,
        )

        // (d) RESUME: the rendered resume control re-drives the SAME persisted ladder and does not rewind it.
        node(LabControl.WIPE_RESUME).performScrollTo().performClick()
        composeRule.waitForIdle()
        assertNotEquals(
            "*** A RESUME MUST NOT REWIND THE DURABLE RECORD TO CLEAN: a wipe that 'resumed' by forgetting itself " +
                "would be the worst lie this surface could tell. ***",
            PanicWipe.WipeState.IDLE.ordinal,
            ctx.getSharedPreferences("godstone_wipe_journal", android.content.Context.MODE_PRIVATE).getInt("state", -1),
        )
    }

    /**
     * *** review A6/A7: A REFUSED ESTATE RENDERS RECOVERY-ONLY, AND THE PRIVATE CONTROLS ARE GENUINELY DEAD. ***
     *
     * *THE REVIEW'S CHARGE: with a REQUESTED/corrupt record the bootstrap must render a recovery-only projection from
     * the SAME durable owner rather than a normal journey.* **This drives the REAL binding with `runtime = null` -- what
     * the launchable application handeth a refused estate -- and requires: the rendered decision is the owner's own, the
     * send and distress controls are DISABLED (there is no private owner behind them), and the wipe request/resume
     * controls remain reachable so the user can repair the estate.**
     */
    @Test
    fun test_aRefusedEstateRendersRecoveryOnlyWithLiveWipeControls() {
        val ctx = androidx.test.core.app.ApplicationProvider.getApplicationContext<android.content.Context>()
        // *** THE PREMISE IS THE DURABLE RECORD ITSELF: a parked wipe. ***
        ctx.getSharedPreferences("godstone_wipe_journal", android.content.Context.MODE_PRIVATE)
            .edit().putInt("state", PanicWipe.WipeState.REQUESTED.ordinal).commit()

        val bindings = LabJourneyBindings(
            null,
            CoroutineScope(Dispatchers.Unconfined),
            io.godstone.mesh.lab.LabWipeJourney(ctx),
        )
        bindings.refresh()
        composeRule.setContent {
            Box(Modifier.width(360.dp)) {
                LabMeshJourneyScreen(state = composeValueOf(bindings.state), onSend = bindings::send)
            }
        }
        composeRule.waitForIdle()

        assertEquals(
            "*** A REFUSED ESTATE MUST RENDER THE OWNER'S OWN DECISION, NOT A PLACEHOLDER. ***",
            "REQUESTED", stateDescriptionOf(LabControl.WIPE_STATE),
        )
        assertFalse(
            "*** AND THE DISTRESS ARM MUST BE GENUINELY DISABLED: no normal private graph standeth to author through. ***",
            enabledOf(LabControl.SOS_ARM),
        )
        assertFalse("*** AND THE RETRY MUST BE DISABLED TOO. ***", enabledOf(LabControl.RETRY))
        assertTrue(
            "*** WHILE THE RESUME -- the owner's own repair of a parked wipe -- MUST STAY ACTIONABLE. ***",
            enabledOf(LabControl.WIPE_RESUME),
        )
        // *** AND A CLICKED SEND MUST REPORT THE OWNER'S DECISION RATHER THAN PRETENDING TO SEND. ***
        bindings.send("B", "a body that must never be durably enqueued")
        composeRule.waitForIdle()
        assertTrue(
            "*** A REFUSED SEND MUST SAY SO IN THE OWNER'S OWN WORDS. Observed: ${textOf(LabControl.OUTCOME)} ***",
            textOf(LabControl.OUTCOME)?.contains("normal private graph is unavailable") == true,
        )
    }

    /** *The published enablement of a rendered node: Compose publisheth `Disabled` on an unreachable control.*/
    private fun enabledOf(tag: String): Boolean {
        node(tag).performScrollTo()
        return !node(tag).fetchSemanticsNode().config.contains(SemanticsProperties.Disabled)
    }

}

/**
 * *** THE COURT'S OWN LIFECYCLE-FREE READ OF THE SAME `StateFlow` THE ACTIVITY COLLECTETH. ***
 *
 * *`collectAsStateWithLifecycle` needeth a `LifecycleOwner`; this court has none, so it collecteth the SAME flow
 * directly. **THE STATE IS THE SAME OBJECT THE ACTIVITY RENDERS** -- only the collection's lifecycle binding differs,
 * and the lifecycle binding itself remains the platform's own, exercised by the activity rather than re-implemented
 * here.*
 */
@androidx.compose.runtime.Composable
private fun composeValueOf(
    flow: kotlinx.coroutines.flow.StateFlow<LabJourneyState>,
): LabJourneyState {
    val value by flow.collectAsState()
    return value
}
