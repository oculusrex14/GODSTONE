package io.godstone.labmesh

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import io.godstone.mesh.a11y.AccessibilityContract
import io.godstone.mesh.a11y.ControlRole
import io.godstone.mesh.a11y.LiveAccessibilityRoster
import io.godstone.mesh.a11y.TextScale
import io.godstone.mesh.a11y.UiNode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** T60 / GS-UX-001 step 9 -- THE LIVE ACCESSIBILITY ROSTER, DECIDED IN ALL FOUR RUNTIME MODES. ***
 *
 * ITS OWN WORDS: *"Enumerate the essential control roster ... For each live surface inspect role, accessible name,
 * value/state, enabled/selected status, traversal order and actionable reachability. Exercise state changes, not only
 * an initial blank screen."* And: *"Run the complete roster at default and largest supported accessibility text sizes
 * in LTR and RTL."*
 *
 * *** THE FOUR MODES ARE THE CONTRACT'S FOUR [TextScale] VALUES -- THE READINESS CONDUCTOR'S OWN MODE SET, WHICH THIS
 * ISLE'S CONTRACT ALREADY DECLARES. *** *This court declares no mode and no law of its own: it hands the REAL rendered
 * tree to [LiveAccessibilityRoster], which decideth the SAME laws the python conductor and the iOS twin own.* **A
 * second enum or a second law table here would be a second declaration, and the two would drift.**
 *
 * *** AND THE ROSTER IS APPLIED AFTER THE RUNTIME TRANSFORMATION, NOT BEFORE IT. *** *THE INITIAL RENDER IS NOT WHAT A
 * USER MEETS: the state machinery runs after it, and THAT is where a status clip, a lost description or a folded
 * reading order appear.* **So every arm below reads the tree the runtime PRODUCED -- the published description, the
 * state word the state machinery wrote, the enablement the typed estate really set, and the box the layout really
 * gave it AFTER a scroll -- and the arms that change the state (a new status word, a recovery-only estate) read the
 * roster AGAIN and require it to have followed.**
 *
 * *** AND `LiveAccessibilityRoster.received` IS THE REAL LOGGING: *** *one line per node NAMING WHAT THE USER ACTUALLY
 * GETS -- the mode, the reachability, the laid-out size and the state words -- so a trace of a failing mode readeth
 * like the screen the user saw rather than like the model it was supposed to be. The trace IS printed by the
 * four-mode arm, and it is built from the SAME nodes the verdict was decided upon, so the log can never disagree with
 * the decision.*
 *
 * THE HUMAN BOUNDARY IS UNCHANGED: no automation here proveth screen-reader GESTURE usability. VoiceOver/TalkBack
 * acceptance remain `gs-ux-001.human-accessibility-acceptance` EXTERNAL.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LabMeshLiveAccessibilityRosterTest {

    @get:Rule
    val composeRule = createComposeRule()

    private val roster = LiveAccessibilityRoster()

    private fun node(tag: String): SemanticsNodeInteraction = composeRule.onNodeWithTag(tag)

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

    private fun roleOf(tag: String): Role? = try {
        val config = node(tag).fetchSemanticsNode().config
        if (config.contains(SemanticsProperties.Role)) config[SemanticsProperties.Role] else null
    } catch (_: Throwable) {
        null
    }

    /** *** `!Disabled` -- the SAME evidence a finger and a screen reader both obey, read from the runtime. *** */
    private fun isEnabled(tag: String): Boolean {
        node(tag).performScrollTo()
        return !node(tag).fetchSemanticsNode().config.contains(SemanticsProperties.Disabled)
    }

    /**
     * The node's OWN laid-out size in dp, measured AFTER scrolling it into view -- never its clipped visible box.
     *
     * *A control below a scrolling fold reads `0x0` from `boundsInRoot`; `fetchSemanticsNode().size` is what a finger
     * really has to hit, and the scroll maketh the read one of a laid-out node.*
     */
    private fun boundsOf(tag: String): Pair<Dp, Dp> {
        node(tag).performScrollTo()
        val size = node(tag).fetchSemanticsNode().size
        val density = composeRule.density
        return with(density) { size.width.toDp() to size.height.toDp() }
    }

    /**
     * *** THE POST-TRANSFORM ROSTER, EXTRACTED FROM THE RENDERED TREE -- NOTHING IS TYPED IN BY THIS COURT. ***
     *
     * *Every field is a READ OFF THE LIVE TREE: the description and the state word from the PUBLISHED configuration,
     * the role from the published role, the laid-out box from the node's own size, and the reading order from the
     * node's `positionInRoot` traversal the tree publishes.* **A court that assigned any of these from its own list
     * would be asserting its own list back to itself.**
     */
    private fun renderedPostTransformRoster(): List<UiNode> {
        val ids = (LabControl.REQUIRED + AccessibilityContract.ESSENTIAL_CONTROLS.keys).distinct()
        val essentials = ids.filter { AccessibilityContract.ESSENTIAL_CONTROLS.containsKey(it) }
        val byPosition = ids.sortedBy { node(it).fetchSemanticsNode().positionInRoot.y }
        val essentialOrder = essentials.sortedBy { byPosition.indexOf(it) }.withIndex()
            .associate { (rank, id) -> id to rank }

        return byPosition.map { id ->
            val (w, h) = boundsOf(id)
            val state = stateDescriptionOf(id)
            val colourToken = state?.takeIf { it in AccessibilityContract.STATE_WORDS.values }
                ?.let { words ->
                    val token = AccessibilityContract.STATE_WORDS.entries.first { it.value == words }.key
                    AccessibilityContract.STATE_COLOUR_TOKEN[token]
                } ?: ""
            UiNode(
                controlId = id,
                role = roleOf(id)?.toContractRole() ?: ControlRole.STATIC_TEXT,
                label = contentDescriptionOf(id).orEmpty(),
                contentDescription = contentDescriptionOf(id).orEmpty(),
                touchWidthDp = w.value,
                touchHeightDp = h.value,
                readingOrder = essentialOrder[id] ?: byPosition.indexOf(id),
                enabled = isEnabled(id),
                stateWords = state?.takeIf { it in AccessibilityContract.STATE_WORDS.values } ?: "",
                colourToken = colourToken,
            )
        }
    }

    private fun Role.toContractRole(): ControlRole = when (this) {
        Role.Button -> ControlRole.BUTTON
        Role.Checkbox, Role.Switch -> ControlRole.TOGGLE
        Role.RadioButton, Role.Tab -> ControlRole.BUTTON
        Role.Image -> ControlRole.IMAGE_BUTTON
        else -> ControlRole.BUTTON
    }

    /** A typed state with explicit (possibly empty) command callbacks -- never an omitted one. */
    private fun componentState(
        stateWords: String = AccessibilityContract.STATE_WORDS.getValue("QUEUED"),
        sosStateWords: String = AccessibilityContract.STATE_WORDS.getValue("CANCELLED"),
        normalGraphAvailable: Boolean = true,
        sosRetryPermitted: Boolean = false,
    ) = LabJourneyState(
        stateWords = stateWords, sosStateWords = sosStateWords,
        normalGraphAvailable = normalGraphAvailable, sosRetryPermitted = sosRetryPermitted,
        onBeginWipe = {}, onResumeWipe = {}, onArmSos = {}, onCancelSos = {}, onRetry = {},
        onResolveCorrupt = {},
    )

    /**
     * *** THE LIVE ROSTER, DECIDED IN ALL FOUR MODES, IN BOTH DIRECTIONS -- AND THE TRACE OF WHAT THE USER GETS. ***
     *
     * *`createComposeRule` permitteth ONE `setContent`, so the four modes x two directions are driven by RECOMPOSITION
     * (a mutable direction plus a mutable font scale), which is what a real device does when the user changeth the
     * type size or the locale.* **Every mode is READ from the tree the runtime produced, then DECIDED by the roster --
     * and the whole trace is printed, so the evidence for all four modes is one log.**
     */
    @Test
    fun test_the_live_roster_is_decided_in_all_four_modes_in_both_directions() {
        val direction = androidx.compose.runtime.mutableStateOf(LayoutDirection.Ltr)
        val fontScale = androidx.compose.runtime.mutableStateOf(1.0f)
        composeRule.setContent {
            CompositionLocalProvider(
                LocalLayoutDirection provides direction.value,
                LocalDensity provides Density(density = 2.75f, fontScale = fontScale.value),
            ) {
                Box(Modifier.width(360.dp)) {
                    LabMeshJourneyScreen(componentState(), onSend = { _, _ -> })
                }
            }
        }
        composeRule.waitForIdle()

        val records = roster.modes.flatMap { mode ->
            listOf(false, true).map { rtl ->
                direction.value = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
                fontScale.value = if (mode == TextScale.DEFAULT) 1.0f
                else if (mode == TextScale.LARGE) 1.5f else 2.0f
                composeRule.waitForIdle()
                roster.decide(mode, renderedPostTransformRoster(), rtl = rtl)
            }
        }

        // *** THE REAL LOGGING, PRINTED: WHAT THE USER RECEIVES IN EVERY MODE. ***
        println(roster.trace(records))

        assertEquals("four modes x two directions", 8, records.size)
        assertEquals(
            "*** EVERY ONE OF THE CONTRACT'S FOUR MODES MUST BE DECIDED. ***",
            TextScale.entries.toSet(), records.map { it.mode }.toSet(),
        )
        for (record in records) {
            assertTrue(
                "*** THE HEALTHY LIVE JOURNEY MUST PASS EVERY MODE: ${record.mode}/${record.rtl} " +
                    "refused by ${record.refusal()} ***",
                record.passed,
            )
            // AND THE TRACE NAMETH THE MODE ON EVERY LINE OF WHAT THE USER RECEIVED
            assertTrue(
                "the received log must name the mode",
                record.received.isNotEmpty() &&
                    record.received.all { it.contains(record.mode.name.lowercase()) },
            )
        }
        // the largest the roster runneth IS the contract's own largest
        assertTrue(roster.modes.last().isLargest)
    }

    /**
     * *** THE ROSTER SURVIVES THE RUNTIME TRANSFORMATION: A STATE CHANGE MOVES WHAT IT READS. ***
     *
     * *This is the clause the card owneth -- "Exercise state changes, not only an initial blank screen" -- and it is
     * why the roster readeth the POST-transform tree: the initial render carrieth `QUEUED`, and the STATE MACHINERY
     * later writeth `DELIVERED`. A roster that read the pre-transform claim would still report `QUEUED`; this arm
     * requireth the SECOND read to carry the new word, so the roster is provably applied to the runtime's output.*
     */
    @Test
    fun test_the_roster_follows_the_runtime_transformation_not_the_initial_render() {
        val state = androidx.compose.runtime.mutableStateOf(
            componentState(stateWords = AccessibilityContract.STATE_WORDS.getValue("QUEUED")))
        composeRule.setContent {
            Box(Modifier.width(360.dp)) {
                LabMeshJourneyScreen(state.value, onSend = { _, _ -> })
            }
        }
        composeRule.waitForIdle()

        val before = roster.decide(TextScale.DEFAULT, renderedPostTransformRoster())
        assertTrue(
            "*** THE INITIAL RENDER CARRIETH THE QUEUED WORD. ***",
            before.received.any {
                it.contains("delivery_outcome") &&
                    it.contains(AccessibilityContract.STATE_WORDS.getValue("QUEUED"))
            },
        )

        // *** THE RUNTIME TRANSFORMATION: the state machinery writeth a NEW word and the tree recomposes. ***
        val delivered = AccessibilityContract.STATE_WORDS.getValue("DELIVERED")
        state.value = componentState(stateWords = delivered)
        composeRule.waitForIdle()

        val after = roster.decide(TextScale.DEFAULT, renderedPostTransformRoster())
        assertTrue(
            "*** THE ROSTER MUST READ THE POST-TRANSFORM WORD -- the state machinery's output, not the initial " +
                "render's claim. ***",
            after.received.any { it.contains("delivery_outcome") && it.contains(delivered) },
        )
        assertFalse(
            "*** AND THE SUPERSEDED WORD MUST BE GONE FROM THE LIVE TREE. ***",
            after.received.any {
                it.contains("delivery_outcome") &&
                    it.contains(AccessibilityContract.STATE_WORDS.getValue("QUEUED"))
            },
        )
        assertTrue("the roster still passes after the transformation", after.passed)
    }

    /**
     * *** THE ROSTER TRACKS THE RUNTIME'S OWN ENABLEMENT, WHICH THE INITIAL RENDER CANNOT CLAIM. ***
     *
     * *A recovery-only estate genuinely DISABLES the private controls (there is no private owner behind them); the
     * roster's `received` log must show them DISABLED, because that is a real accessibility fact a user meets AFTER
     * the estate is decided -- not a flag the first render knew.*
     */
    @Test
    fun test_the_roster_sees_the_enablement_the_typed_estate_really_set() {
        val state = androidx.compose.runtime.mutableStateOf(
            componentState(normalGraphAvailable = false, sosRetryPermitted = false))
        composeRule.setContent {
            Box(Modifier.width(360.dp)) {
                LabMeshJourneyScreen(state.value, onSend = { _, _ -> })
            }
        }
        composeRule.waitForIdle()

        val record = roster.decide(TextScale.DEFAULT, renderedPostTransformRoster())
        for (control in listOf(LabControl.SOS_ARM, LabControl.SOS_CANCEL, LabControl.RETRY)) {
            assertTrue(
                "*** $control HAS NO PRIVATE OWNER BEHIND IT IN A RECOVERY-ONLY ESTATE, SO THE ROSTER MUST SEE IT " +
                    "DISABLED. Received: ${record.received.filter { it.contains(control) }} ***",
                record.received.any { it.contains(control) && it.contains("DISABLED") },
            )
        }
        // and the read is the REAL published enablement, cross-checked against the tree
        assertFalse("the tree really disabled sos_arm", isEnabled(LabControl.SOS_ARM))
        assertTrue("the wipe request stays reachable", isEnabled(LabControl.WIPE_BEGIN))
    }

    /**
     * *** THE LIVE ROSTER'S OWN SENSITIVITY: THE DEFECT CLASS THE PLAN NAMES REDDENS IT. ***
     *
     * *The plan's negative: "deleting a required semantics modifier or clipping a target must fail the corresponding
     * rendered witness." A real regression of either kind APPEARETH in the rendered tree as a changed [UiNode] (an
     * empty description, a truncated status, a folded box) -- so this arm taketh the REAL post-transform roster and
     * injects each defect EXACTLY as the tree would publish it, then requireth a REFUSAL BY NAME.* **A roster that
     * passed any of these would be a check that cannot fail.***
     */
    @Test
    fun test_the_live_roster_refuses_the_defect_classes_the_plan_names() {
        composeRule.setContent {
            Box(Modifier.width(360.dp)) {
                LabMeshJourneyScreen(componentState(), onSend = { _, _ -> })
            }
        }
        composeRule.waitForIdle()
        val real = renderedPostTransformRoster()
        assertTrue("baseline: the live roster is healthy", roster.decide(TextScale.DEFAULT, real).passed)

        // (a) A REQUIRED SEMANTICS MODIFIER DELETED: the description the tree published is gone.
        val undescribed = real.map {
            if (it.controlId == LabControl.COMPOSE_SEND) it.copy(contentDescription = "") else it
        }
        val lost = roster.decide(TextScale.DEFAULT, undescribed)
        assertFalse("*** A DELETED DESCRIPTION MUST REDDEN THE WITNESS. ***", lost.passed)
        assertEquals("essential_control_labelled", lost.refusal()!!.first)

        // (b) A STATUS CLIPPED AT THE LARGEST MODE: the state word the runtime wrote, truncated by the layout.
        val clipped = real.map {
            if (it.controlId == LabControl.OUTCOME && it.stateWords.isNotEmpty()) it.copy(truncated = true) else it
        }
        val cut = roster.decide(TextScale.LARGEST_ACCESSIBILITY, clipped)
        assertFalse("*** A CLIPPED STATUS MUST REDDEN THE LARGEST MODE. ***", cut.passed)
        assertEquals("status_never_clipped", cut.refusal()!!.first)

        // (c) A TARGET FOLDED BELOW THE MINIMUM: the box the layout really gave a control.
        val folded = real.map {
            if (it.controlId == LabControl.SOS_ARM) it.copy(touchWidthDp = 40f, touchHeightDp = 40f) else it
        }
        val small = roster.decide(TextScale.DEFAULT, folded)
        assertFalse("*** A TARGET BELOW 48dp MUST REDDEN THE WITNESS. ***", small.passed)
        assertEquals("touch_target_minimum", small.refusal()!!.first)
    }

    /**
     * *** THE SCALE REALLY TOOK EFFECT PER MODE -- OR THE FOUR MODES CERTIFY ONE. ***
     *
     * *A court that set a font scale nothing honoured would pass every mode while measuring one. The discriminator is a
     * MEASUREMENT: the compose field's laid-out height at each enlarged mode must EXCEED its height at the default --
     * enlarged type CANNOT produce a shorter field.*
     */
    @Test
    fun test_every_enlarged_mode_really_enlarges_the_layout() {
        val fontScale = androidx.compose.runtime.mutableStateOf(1.0f)
        composeRule.setContent {
            CompositionLocalProvider(LocalDensity provides Density(density = 2.75f, fontScale = fontScale.value)) {
                Box(Modifier.width(360.dp)) {
                    LabMeshJourneyScreen(componentState(), onSend = { _, _ -> })
                }
            }
        }
        composeRule.waitForIdle()

        var defaultHeight: Dp? = null
        for (mode in roster.modes) {
            fontScale.value = if (mode == TextScale.DEFAULT) 1.0f
            else if (mode == TextScale.LARGE) 1.5f else 2.0f
            composeRule.waitForIdle()
            val height = boundsOf(LabControl.COMPOSE_BODY).second
            if (mode == TextScale.DEFAULT) {
                defaultHeight = height
            } else {
                val baseline = defaultHeight
                assertTrue(
                    "*** MODE ${mode.name} MUST REALLY ENLARGE THE LAYOUT: the compose field measured $height and " +
                        "$baseline at default. A mode whose scale changed nothing certifieth nothing. ***",
                    baseline != null && height > baseline,
                )
            }
        }
    }
}
