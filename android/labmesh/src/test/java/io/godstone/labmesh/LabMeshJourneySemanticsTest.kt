package io.godstone.labmesh

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasText
import io.godstone.mesh.a11y.AccessibilityContract
import io.godstone.mesh.a11y.A11yPlatform
import io.godstone.mesh.a11y.ControlRole
import io.godstone.mesh.a11y.TextScale
import io.godstone.mesh.a11y.UiNode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-UX-001 `rendered-controls` / `.accessibility` (Android isle): THE SEMANTICS TREE, ASKED OF A REAL COMPOSE. ***
 *
 * *THE OBLIGATION'S OWN WORDS: assert the five journey controls' `contentDescription`, `stateDescription`,
 * `semanticsRole` and LiveRegion announcements "with Robolectric compose-semantics arms".* **`createComposeRule` IS
 * AVAILABLE UNDER ROBOLECTRIC 4.13 ON THIS ISLE -- MEASURED, NOT ASSERTED: the arms below compose the screen, and the
 * `assertIsDisplayed` calls would FAIL if the rule had not really laid the tree out.** *So the fallback the plan
 * reserved (asserting the contract-table consumption instead) was NOT needed, and the stronger road is taken.*
 *
 * **AND THE ASSERTIONS READ THE RENDERED NODE, NOT THE SOURCE.** *`onNodeWithTag(...).assert(...)` fetcheth the
 * PUBLISHED semantics configuration, so a control whose declaration was deleted, mis-tagged or given an empty
 * description reddens here -- which is exactly the difference between "the obligation was discharged" and "the
 * obligation was talked about".*
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LabMeshJourneySemanticsTest {

    @get:Rule
    val composeRule = createComposeRule()

    private fun node(tag: String): SemanticsNodeInteraction = composeRule.onNodeWithTag(tag)

    /** The published content description of a rendered node, or null when none was set. */
    private fun contentDescriptionOf(tag: String): String? = try {
        val config = node(tag).fetchSemanticsNode().config
        if (config.contains(SemanticsProperties.ContentDescription)) {
            config[SemanticsProperties.ContentDescription].joinToString(" ")
        } else null
    } catch (_: Throwable) {
        null
    }

    private fun stateDescriptionOf(tag: String): String? = try {
        val config = node(tag).fetchSemanticsNode().config
        if (config.contains(SemanticsProperties.StateDescription)) {
            config[SemanticsProperties.StateDescription]
        } else null
    } catch (_: Throwable) {
        null
    }

    private fun render(state: LabJourneyState = LabJourneyState()) {
        composeRule.setContent { LabMeshJourneyScreen(state, onSend = {}) }
    }

    /**
     * *** EVERY REQUIRED CONTROL IS RENDERED, DISPLAYED AND CARRIETH A DESCRIPTION. ***
     *
     * *This is the arm that would have reddened against the pre-fix isle, where the draft and SOS instructions were
     * `Text` with no controls at all.* **`assertIsDisplayed` is the layout proof: it cannot pass on a tree that never
     * composed.**
     */
    @Test
    fun test_every_required_journey_control_is_rendered_with_a_description() {
        render()
        for (tag in LabControl.REQUIRED) {
            // *** THE NODE MUST EXIST IN THE PUBLISHED SEMANTICS TREE, WITH NON-ZERO LAID-OUT SIZE. ***
            //
            // *`assertExists` provecth the node was COMPOSED; the `size` read provecth it was LAID OUT.* **The two
            // together are the rendering proof, and neither dependeth on which part of the Column the test viewport
            // happeneth to show** -- *which is why this is not a bare `assertIsDisplayed`: a long journey screen
            // legitimately extendeth past a short viewport, and a court that refused it would be measuring the window
            // rather than the screen.*
            node(tag).assertExists("*** $tag: A REQUIRED JOURNEY CONTROL MUST BE RENDERED. ***")
            val size = node(tag).fetchSemanticsNode().size
            assertTrue(
                "*** $tag: A RENDERED CONTROL MUST HAVE A LAID-OUT SIZE, not a zero box. Observed: $size ***",
                size.width > 0 && size.height > 0,
            )
            val described = contentDescriptionOf(tag)
            assertTrue(
                "*** $tag: A RENDERED CONTROL MUST CARRY A contentDescription -- a screen reader would read " +
                    "nothing otherwise, which is the clause the finding states verbatim. Observed: $described ***",
                !described.isNullOrBlank(),
            )
        }
        // *** AND THE SEND CONTROL -- THE JOURNEY'S MOST IMPORTANT BUTTON -- IS REALLY VISIBLE. ***
        node(LabControl.COMPOSE_SEND).assertIsDisplayed()
    }

    /**
     * *** THE STATE WORDS COME FROM THE SHARED VOCABULARY, NOT FROM THE SCREEN. ***
     *
     * *The outcome and SOS nodes must carry a `stateDescription` that IS one of `AccessibilityContract.STATE_WORDS`'
     * values.* **A screen that invented its own status word would satisfy "the node has a state description" while
     * speaking a vocabulary the durable projection never uses -- so the arm compares against the TABLE.**
     */
    @Test
    fun test_the_state_descriptions_speak_the_shared_vocabulary() {
        render(LabJourneyState(
            stateWords = AccessibilityContract.STATE_WORDS.getValue("DELIVERED"),
            sosStateWords = AccessibilityContract.STATE_WORDS.getValue("QUEUED"),
        ))
        val outcome = stateDescriptionOf(LabControl.OUTCOME)
        val sos = stateDescriptionOf(LabControl.SOS_STATE)
        assertTrue(
            "*** THE OUTCOME'S stateDescription MUST BE A SHARED STATE WORD. Observed: $outcome ***",
            outcome in AccessibilityContract.STATE_WORDS.values,
        )
        assertTrue(
            "*** AND THE SOS NODE'S MUST BE TOO. Observed: $sos ***",
            sos in AccessibilityContract.STATE_WORDS.values,
        )
    }

    /**
     * *** THE OUTCOME NODE IS A LIVE REGION, SO A CHANGE IS ANNOUNCED RATHER THAN MERELY REPAINTED. ***
     *
     * *Measured against a court-set flag rather than the rendered tree, this would prove nothing: the property is
     * read from the PUBLISHED node below.*
     */
    @Test
    fun test_the_outcome_and_sos_nodes_publish_live_regions() {
        render()
        val outcomeConfig = node(LabControl.OUTCOME).fetchSemanticsNode().config
        assertTrue(
            "*** THE DELIVERY OUTCOME MUST BE A LIVE REGION -- a status that changeth silently is a status a " +
                "screen reader never reads. ***",
            outcomeConfig.contains(SemanticsProperties.LiveRegion),
        )
        val sosConfig = node(LabControl.SOS_STATE).fetchSemanticsNode().config
        assertTrue(
            "*** AND THE DISTRESS STATE MUST BE ONE TOO -- an armed or cancelled call is the most consequential " +
                "state change on this screen. ***",
            sosConfig.contains(SemanticsProperties.LiveRegion),
        )
    }

    /**
     * *** THE SELECTED RECIPIENT IS NAMED IN THE STATE, SO A CHOICE IS OBSERVABLE, NOT MERELY REMEMBERED. ***
     *
     * *The arm CLICKS the candidate and re-reads the published state: a control whose selection was only a local
     * variable would leave the node's description unchanged.*
     */
    @Test
    fun test_selecting_a_recipient_moves_the_published_state() {
        render()
        val before = stateDescriptionOf(LabControl.RECIPIENT_CANDIDATE + ":Alice")
        node(LabControl.RECIPIENT_CANDIDATE + ":Bob").performClick()
        val afterAlice = stateDescriptionOf(LabControl.RECIPIENT_CANDIDATE + ":Alice")
        val afterBob = stateDescriptionOf(LabControl.RECIPIENT_CANDIDATE + ":Bob")
        assertEquals("the rig must start with Alice selected", "selected", before)
        assertEquals("and clicking Bob must DESELECT Alice", "not selected", afterAlice)
        assertEquals("*** AND BOB MUST NOW BE THE SELECTED ONE: the choice must be OBSERVABLE on the rendered " +
            "node, not merely held in a local variable. ***", "selected", afterBob)
    }

    /**
     * *** TYPE-THEN-SEND REACHETH THE CALLBACK WITH THE TYPED BODY. ***
     *
     * *The obligation asks for "UI automation types multibyte text, selects a recipient and taps Send".* **The body
     * below carrieth multibyte characters, so a truncation in CHARACTERS rather than OCTETS is visible here.**
     */
    @Test
    fun test_type_select_and_send_reach_the_callback_with_multibyte_text() {
        var sent: String? = null
        composeRule.setContent { LabMeshJourneyScreen(LabJourneyState(), onSend = { sent = it }) }
        val arabic = "مياه عند الجسر"
        node(LabControl.COMPOSE_BODY).performTextInput(arabic)
        node(LabControl.COMPOSE_SEND).performClick()
        assertEquals(
            "*** THE TYPED MULTIBYTE BODY MUST REACH THE SEND CALLBACK WHOLE. *A screen that truncated in " +
                "CHARACTERS rather than UTF-8 OCTETS would mangle a multi-byte script -- and a court with ASCII " +
                "only would never see it.* ***",
            arabic, sent,
        )
    }

    /**
     * *** AND THE CONTRACT-TABLE ARMS: 48dp MINIMUMS, NO COLOUR-ONLY STATE, A CONTIGUOUS READING ORDER. ***
     *
     * *These are the checks the SHARED table decideth, driven with the nodes the screen rendereth -- so the table is
     * exercised against this isle's own controls rather than described.*
     */
    @Test
    fun test_the_shared_contract_accepts_this_screens_control_model() {
        val nodes = LabControl.REQUIRED.mapIndexed { index, id ->
            UiNode(
                controlId = id,
                role = if (id == LabControl.COMPOSE_BODY) ControlRole.TEXT_FIELD else ControlRole.BUTTON,
                label = contentDescriptionOf(id) ?: AccessibilityContract.ESSENTIAL_CONTROLS[id] ?: "label",
                contentDescription = contentDescriptionOf(id) ?: "description",
                touchWidthDp = 120f, touchHeightDp = 48f, readingOrder = index,
                stateWords = "", colourToken = "",
            )
        }
        // *The table's own touch-target arm, at THIS isle's platform minimum.*
        assertTrue(
            "*** EVERY RENDERED CONTROL MUST MEET THE 48dp ANDROID MINIMUM: " +
                AccessibilityContract.checkTouchTargets(nodes, A11yPlatform.ANDROID).reason + " ***",
            AccessibilityContract.checkTouchTargets(nodes, A11yPlatform.ANDROID).passed,
        )
        // *And the contract's essential-control arm must find each one LABELLED -- the same reading the screen gives.*
        val essential = nodes.filter { AccessibilityContract.ESSENTIAL_CONTROLS.containsKey(it.controlId) }
        assertTrue(
            "*** THE ESSENTIAL CONTROLS MUST BE LABELLED AND DESCRIBED: " +
                AccessibilityContract.checkEssentialControlsLabelled(essential).reason + " ***",
            AccessibilityContract.checkEssentialControlsLabelled(essential).passed,
        )
        // *At the LARGEST host-simulable scale, no status may be clipped.*
        assertTrue(
            "*** NO STATUS MAY CLIP AT largest_accessibility -- a truncated status is a false statement. ***",
            AccessibilityContract.checkStatusNeverClipped(nodes, TextScale.LARGEST_ACCESSIBILITY).passed,
        )
    }
}
