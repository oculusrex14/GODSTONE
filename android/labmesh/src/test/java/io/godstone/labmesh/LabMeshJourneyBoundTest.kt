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
import io.godstone.mesh.lab.LabRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
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
 * THIS COURT DRIVES THE REAL BINDING: `LabJourneyBindings` over a real `io.godstone.mesh.lab.LabRuntime` (composed by
 * `LabMeshApp.compose()` -- the production `MeshNode` over the real router, store, tracker, inbox and ACK authority).
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
@Config(sdk = [33])
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
     * Bind the REAL runtime to the REAL screen and hand back the bindings.
     *
     * *The screen is rendered with the SAME `StateFlow` the activity collecteth; the court reads the bound values
     * directly, which is what maketh the assertion about the RUNTIME rather than about a composition detail.*
     */
    private fun bind(runtime: LabRuntime): LabJourneyBindings {
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined))
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
        val runtime = LabMeshApp.compose()
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
        val runtime = LabMeshApp.compose()
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
        val runtime = LabMeshApp.compose()
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
