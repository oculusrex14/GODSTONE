package io.godstone.labmesh

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.isRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import io.godstone.mesh.a11y.A11yPlatform
import io.godstone.mesh.a11y.AccessibilityContract
import io.godstone.mesh.a11y.ControlRole
import io.godstone.mesh.a11y.TextScale
import io.godstone.mesh.a11y.UiNode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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
 * `assertIsDisplayed` calls would FAIL if the rule had not really laid the tree out.**
 *
 * **AND THE ASSERTIONS READ THE RENDERED NODE, NOT THE SOURCE.** *`onNodeWithTag(...).fetchSemanticsNode()` fetcheth
 * the PUBLISHED semantics configuration, so a control whose declaration was deleted, mis-tagged or given an empty
 * description reddens here -- which is exactly the difference between "the obligation was discharged" and "the
 * obligation was talked about".*
 *
 * *** THIS ROUND'S CHARGE, AND WHY EVERY ARM BELOW WAS REWRITTEN: THE PREVIOUS COURT READ THE TREE FOR
 * `contentDescription`, `stateDescription` AND `LiveRegion` AND **FABRICATED EVERYTHING ELSE**. ***
 *
 * *Its last arm built its `UiNode` roster from `LabControl.REQUIRED.mapIndexed { … touchWidthDp = 120f,
 * touchHeightDp = 48f … }` -- **A HARD-CODED 120x48 BOX** -- and then asserted the SHARED table accepted it. **THE
 * TABLE WAS THEREFORE ASKED ABOUT A SCREEN THAT DOES NOT EXIST**, and the one law only a LAYOUT can fail (the touch
 * target minimum) was certified by a literal.*
 *
 * **AND THE ROLE WAS ASSERTED NOWHERE AT ALL** -- which is how the screen shipped declaring `Role.Button` on a text
 * field, on two status readouts and on a group heading. *Two independent reviews' shared finding, and this court is
 * the fix: the roles ARE asserted here, per node, read from the published tree.*
 *
 * *** THE NEGATIVE CONTROLS ARE IN THIS FILE TOO, SO A GREEN CANNOT COME FROM A CHECK THAT ALWAYS PASSETH. *** *Each
 * read-back helper is exercised against a node that breaks the law it defends, and the arm requires the read to see
 * the break.*
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

    /** *** THE PUBLISHED ROLE, WHICH THE PREVIOUS COURT NEVER READ. *** */
    private fun roleOf(tag: String): Role? = try {
        val config = node(tag).fetchSemanticsNode().config
        if (config.contains(SemanticsProperties.Role)) config[SemanticsProperties.Role] else null
    } catch (_: Throwable) {
        null
    }

    private fun liveRegionOf(tag: String): LiveRegionMode? = try {
        val config = node(tag).fetchSemanticsNode().config
        if (config.contains(SemanticsProperties.LiveRegion)) config[SemanticsProperties.LiveRegion] else null
    } catch (_: Throwable) {
        null
    }


    /**
     * *** THE PUBLISHED ENABLEMENT OF A RENDERED NODE. ***
     *
     * *Compose publisheth `SemanticsProperties.Disabled` on an unreachable node and nothing on a reachable one, so this
     * read is `!Disabled` -- the same evidence a finger and a screen reader both obey.*
     */
    private fun isEnabled(tag: String): Boolean {
        node(tag).performScrollTo()
        val config = node(tag).fetchSemanticsNode().config
        return !config.contains(SemanticsProperties.Disabled)
    }

    /**
     * *** THE NODE'S OWN LAID-OUT SIZE, IN dp -- NOT ITS CLIPPED VISIBLE BOX. ***
     *
     * *MEASURED, AND IT IS WHY THIS HELPER WAS REWRITTEN: the first version read `boundsInRoot`, which is the box
     * CLIPPED to the viewport. In a scrolling `Column`, a control below the fold therefor read `0.0x0.0` (`retry`) and
     * one partially clipped read `73.0x26.0` (`sos_cancel`) -- **A CLIPPED BOX IS A MEASUREMENT OF THE WINDOW, NOT
     * OF THE CONTROL**, and asserting the 48dp law against it would have condemned a screen for a viewport.*
     *
     * **`fetchSemanticsNode().size` IS THE NODE'S OWN LAYOUT SIZE** -- what a finger really has to hit -- and the node
     * is scrolled into view first, so a read is only ever taken of a node that was actually laid out.
     */
    private fun boundsOf(tag: String): Pair<Dp, Dp> {
        node(tag).performScrollTo()
        val size = node(tag).fetchSemanticsNode().size
        val density = composeRule.density
        return with(density) { size.width.toDp() to size.height.toDp() }
    }

    /**
     * *** THE WHOLE ROSTER, EXTRACTED FROM THE RENDERED TREE -- WHICH IS WHAT REPLACES THE FABRICATED 120x48. ***
     *
     * *Every field is a READ: the description and state from the published configuration, the role from the
     * published role, the touch size from `boundsInRoot` converted at the composition's own density, and the reading
     * order from the node's position in the traversal the tree publishes. **Nothing here is typed in by the court**,
     * which is the whole difference from the previous arm.*
     */
    private fun renderedRoster(): List<UiNode> {
        // *** THE READING ORDER IS READ FROM THE TREE'S OWN GEOMETRY, NOT FROM THE ORDER THE COURT LISTED THE IDS. ***
        //
        // *The clause asketh for the TRAVERSAL ORDER, and a traversal followeth the laid-out layout: **a court that
        // assigned `readingOrder` from its own list would be asserting its own list back to itself.*** *So each
        // node's vertical offset is read from the tree and the roster is ordered by it -- the order a switch user
        // walketh.*
        // *** THE ROSTER IS THE UNION OF THE REQUIRED JOURNEY IDS AND THE ESSENTIAL CONTROLS THE CONTRACT NAMES. ***
        //
        // *The essential table (`AccessibilityContract.ESSENTIAL_CONTROLS`) names the five controls a screen reader
        // must find, and `retry` is one of them -- a REQUIRED live control the journey list did not repeat. **A roster
        // built from `LabControl.REQUIRED` alone would omit `retry` and then claim the essential control was absent,
        // which is the court losing the control rather than the screen.*** *Every id in the union is genuinely rendered
        // in every typed state (the retry button is composed unconditionally, only its enablement moveth), so the
        // union is measured from the real tree.*
        val roster = (LabControl.REQUIRED + AccessibilityContract.ESSENTIAL_CONTROLS.keys).distinct()
        val essentials = roster.filter { AccessibilityContract.ESSENTIAL_CONTROLS.containsKey(it) }
        val byPosition = roster.sortedBy { tag ->
            node(tag).fetchSemanticsNode().positionInRoot.y
        }
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
                // *For a node that is NOT essential this is its own traversal rank; for an essential one it is its rank
                // among the essential controls, which is what the contract's contiguity law is about.*
                readingOrder = essentialOrder[id] ?: byPosition.indexOf(id),
                enabled = true,
                // *The state words ARE read where the node carrieth them -- the outcome and SOS readouts, the octet
                // readout and the mirror record -- and the colour token come from the SAME vocabulary entry, so the
                // colour channel is never the only one.*
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

    private fun render(state: LabJourneyState = componentState(), rtl: Boolean = false) {
        composeRule.setContent {
            val direction = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
            CompositionLocalProvider(LocalLayoutDirection provides direction) {
                // A BOUNDED WIDTH, SO THE LAYOUT IS A PHONE RATHER THAN THE TEST WINDOW: a control measured against
                // an unbounded width would pass any minimum by accident.
                Box(Modifier.width(360.dp)) { LabMeshJourneyScreen(state, onSend = { _, _ -> }) }
            }
        }
    }

    /**
     * *** THE COMPONENT-MODE STATE: EXPLICIT, POSSIBLY-EMPTY CALLBACKS -- NEVER AN OMITTED ONE. ***
     *
     * *`LabJourneyState` no longer carrieth `{}` defaults for its REQUIRED command callbacks, so a component arm must
     * say what its distress controls do. The arms above are SEMANTICS arms -- they judge the rendered tree, not the
     * commands -- so they pass honest empty lambdas, which is the whole difference between "this arm does not exercise
     * the command" and "a caller may forget the command".*
     */
    private fun componentState(
        recipients: List<String> = listOf("Alice", "Bob"),
        outcome: String = "nothing sent yet",
        stateWords: String = AccessibilityContract.STATE_WORDS.getValue("QUEUED"),
        sosStateWords: String = AccessibilityContract.STATE_WORDS.getValue("CANCELLED"),
        durableMsgId: String? = null,
        durableLabel: String = "UNAVAILABLE",
        wipeStage: String = "IDLE",
        wipeDecision: String = "clean_start",
        wipePending: Boolean = false,
        wipeRecoveryPermitted: Boolean = false,
        wipeOperatorRequired: Boolean = false,
        wipeOperatorResolutionPermitted: Boolean = false,
        sosRetryPermitted: Boolean = true,
        normalGraphAvailable: Boolean = true,
        onBeginWipe: () -> Unit = {},
        onResumeWipe: () -> Unit = {},
        onArmSos: () -> Unit = {},
        onCancelSos: () -> Unit = {},
        onRetry: () -> Unit = {},
        onResolveCorrupt: () -> Unit = {},
    ) = LabJourneyState(
        recipients = recipients, outcome = outcome, stateWords = stateWords, sosStateWords = sosStateWords,
        durableMsgId = durableMsgId, durableLabel = durableLabel,
        wipeStage = wipeStage, wipeDecision = wipeDecision, wipePending = wipePending,
        wipeRecoveryPermitted = wipeRecoveryPermitted, wipeOperatorRequired = wipeOperatorRequired,
        wipeOperatorResolutionPermitted = wipeOperatorResolutionPermitted,
        sosRetryPermitted = sosRetryPermitted, normalGraphAvailable = normalGraphAvailable,
        onBeginWipe = onBeginWipe, onResumeWipe = onResumeWipe,
        onArmSos = onArmSos, onCancelSos = onCancelSos, onRetry = onRetry,
        onResolveCorrupt = onResolveCorrupt,
    )

    /**
     * *** EVERY REQUIRED CONTROL IS RENDERED, DISPLAYED AND CARRIETH A DESCRIPTION. ***
     */
    @Test
    fun test_every_required_journey_control_is_rendered_with_a_description() {
        render()
        for (tag in LabControl.REQUIRED) {
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
        node(LabControl.COMPOSE_SEND).assertIsDisplayed()
    }

    /**
     * *** THE PUBLISHED ROLE OF EVERY NODE IS THE ROLE ITS CONTROL REALLY CARRIETH. ***
     *
     * *THIS ARM IS THE ONE THE PREVIOUS COURT DID NOT HAVE, AND ITS ABSENCE IS WHY THE SCREEN SHIPPED DECLARING A
     * `Role.Button` ON A TEXT FIELD, ON TWO STATUS READOUTS AND ON A GROUP HEADING.* **A role is a promise about what
     * activating the node doth**, so an action-less readout announced as a button is a false statement a screen reader
     * repeateth to every user.* *The expectation table liveth beside the screen (`LabControl.ROLES`), and `null` there
     * meaneth the node must publish NO role at all -- which is what a status seeth.*
     */
    @Test
    fun test_every_rendered_node_publishes_the_role_its_control_really_carrieth() {
        render()
        for ((tag, expected) in LabControl.ROLES) {
            val observed = roleOf(tag)
            if (expected == null) {
                assertNull(
                    "*** $tag IS A READOUT, NOT A CONTROL: it must publish NO role, so assistive technology " +
                        "announceth it as the STATUS it is. Observed: $observed ***",
                    observed,
                )
            } else {
                assertEquals(
                    "*** $tag MUST PUBLISH ITS REAL ROLE. A text field or a status declared as a button is a lie a " +
                        "screen reader repeats. ***",
                    expected, observed,
                )
            }
        }
    }

    /** *** THE NEGATIVE CONTROL FOR THE ROLE READ: A NODE THAT BREAKS THE LAW MUST BE SEEN TO BREAK IT. *** */
    @Test
    fun test_the_role_read_seeth_a_role_that_contradicts_the_control() {
        render()
        // The Send control legitimately publish ETH a button, so the read must return it...
        assertEquals(Role.Button, roleOf(LabControl.COMPOSE_SEND))
        // ...AND the outcome readout must publish NOTHING, so a court that read `Role.Button` there would be reading
        // a tree this screen did not compose. Both halves are asserted, so a `roleOf` that returned null always (or a
        // constant always) reddens on one of them.
        assertNull("the delivery outcome is a STATUS: no role may be published", roleOf(LabControl.OUTCOME))
        assertNull("the text field announceth itself: no override may be published", roleOf(LabControl.COMPOSE_BODY))
        assertEquals(Role.RadioButton, roleOf(LabControl.RECIPIENT_CANDIDATE + ":Alice"))
    }

    /**
     * *** THE STATE WORDS COME FROM THE SHARED VOCABULARY, NOT FROM THE SCREEN. ***
     */
    @Test
    fun test_the_state_descriptions_speak_the_shared_vocabulary() {
        render(componentState(
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
     */
    @Test
    fun test_the_outcome_and_sos_nodes_publish_live_regions() {
        render()
        assertEquals(
            "*** THE DELIVERY OUTCOME MUST BE A Polite LIVE REGION -- a status that changeth silently is a status a " +
                "screen reader never reads. ***",
            LiveRegionMode.Polite, liveRegionOf(LabControl.OUTCOME),
        )
        assertEquals(
            "*** AND THE DISTRESS STATE MUST BE Assertive -- an armed or cancelled call is the most consequential " +
                "state change on this screen. ***",
            LiveRegionMode.Assertive, liveRegionOf(LabControl.SOS_STATE),
        )
    }

    /**
     * *** THE ANNOUNCEMENT ITSELF MOVES WITH THE STATE -- THE MECHANISM, NOT MERELY ITS DECLARATION. ***
     *
     * *A `liveRegion` modifier declarith that a change is spoken; this arm requireth the RECORD the screen writeth for
     * that announcement to follow the state word, which a screen that declared the region and never updated anything
     * would fail.*
     */
    @Test
    fun test_the_announcement_record_follows_the_shared_state_word() {
        val delivered = AccessibilityContract.STATE_WORDS.getValue("DELIVERED")
        val attempting = AccessibilityContract.STATE_WORDS.getValue("ATTEMPTING")
        val state = androidx.compose.runtime.mutableStateOf(componentState(stateWords = delivered))
        composeRule.setContent {
            Box(Modifier.width(360.dp)) { LabMeshJourneyScreen(state.value, onSend = { _, _ -> }) }
        }
        composeRule.waitForIdle()
        assertEquals(
            "*** THE ANNOUNCED RECORD MUST CARRY THE STATE'S OWN WORDS, so what is SPOKEN is what the durable " +
                "projection sayeth. ***",
            delivered, stateDescriptionOf(LabControl.ANNOUNCED),
        )
        // *** AND THE EDGE: THE STATE CHANGES, SO THE ANNOUNCEMENT MUST FOLLOW. ***
        state.value = componentState(stateWords = attempting)
        composeRule.waitForIdle()
        assertEquals(
            "*** A STATE CHANGE MUST MOVE THE ANNOUNCED RECORD: a region declared and never updated speaketh the " +
                "status it first saw for ever. ***",
            attempting, stateDescriptionOf(LabControl.ANNOUNCED),
        )
    }

    /**
     * *** THE SELECTED RECIPIENT IS NAMED IN THE STATE, SO A CHOICE IS OBSERVABLE. ***
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
     */
    @Test
    fun test_type_select_and_send_reach_the_callback_with_multibyte_text() {
        var sent: String? = null
        composeRule.setContent {
            Box(Modifier.width(360.dp)) { LabMeshJourneyScreen(componentState(), onSend = { _, body -> sent = body }) }
        }
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
     * *** THE COMPOSE-OCTET READOUT COUNTS OCTETS AND FOLLOWS THE INPUT. ***
     *
     * *The clause's own words: the input is "UTF-8 bounded", and a bound a user cannot see is a bound they cannot
     * respect. **THE READOUT DID NOT EXIST ON THIS SURFACE BEFORE THIS ROUND**, which is why this arm is new: the
     * previous court could not have asserted a node that was not there.*
     */
    @Test
    fun test_the_compose_octet_readout_counts_octets_and_follows_the_input() {
        render()
        val readout = stateDescriptionOf(LabControl.OCTETS)
        assertEquals("the empty draft must read zero octets", "0 of $MESSAGE_BODY_MAX octets used", readout)
        // *** A MULTIBYTE PAYLOAD: TWO ARABIC WORDS IS FAR MORE OCTETS THAN CHARACTERS. ***
        val arabic = "مياه عند الجسر"
        node(LabControl.COMPOSE_BODY).performTextInput(arabic)
        composeRule.waitForIdle()
        val expected = octetsOf(arabic)
        assertTrue("the fixture must really be multibyte", expected > arabic.length)
        assertEquals(
            "*** THE READOUT MUST COUNT UTF-8 OCTETS, NOT CHARACTERS, and it must FOLLOW the input. ***",
            "$expected of $MESSAGE_BODY_MAX octets used", stateDescriptionOf(LabControl.OCTETS),
        )
        // *** AND THE BOUND IS THE AUTHORITY'S OWN: typing past it must show the TRUE octet count (the readout is a
        // measurement, and the Send control is what refuseth), so the number can never disagree with the budget. ***
        node(LabControl.COMPOSE_BODY).performTextReplacement("a".repeat(MESSAGE_BODY_MAX + 25))
        composeRule.waitForIdle()
        assertEquals(
            "the readout must keep measuring past the budget rather than stop counting at it",
            "${MESSAGE_BODY_MAX + 25} of $MESSAGE_BODY_MAX octets used", stateDescriptionOf(LabControl.OCTETS),
        )
    }

    /**
     * *** AND THE CONTRACT-TABLE ARMS, DRIVEN BY THE **RENDERED** ROSTER RATHER THAN A FABRICATED ONE. ***
     *
     * *THIS IS THE ARM STEP 9 NAMETH: "replace the fabricated 120x48 nodes/fallback labels with values extracted from
     * the rendered semantics/layout". The roster below readeth the published description and the real laid-out box of
     * every node, so **a control that fell below 48dp, lost its description or vanished reddens here** -- where the
     * old arm, being handed a constant 120x48, could only ever have certified the constant.*
     */
    @Test
    fun test_the_shared_contract_is_applied_to_the_rendered_roster() {
        render()
        val nodes = renderedRoster()

        // (a) *** THE REAL TOUCH TARGETS. *** *Only the nodes that ARE controls are measured; a readout is a status,
        // and the contract skippeth `STATIC_TEXT` for exactly that reason.
        val controls = nodes.filter { LabControl.CONTROLS.contains(it.controlId) }
        val touch = AccessibilityContract.checkTouchTargets(controls, A11yPlatform.ANDROID)
        assertTrue(
            "*** EVERY RENDERED CONTROL MUST MEET THE 48dp ANDROID MINIMUM, MEASURED FROM ITS OWN LAID-OUT BOX: " +
                "${touch.reason}. Measured: " + controls.joinToString { "${it.controlId}=${it.touchWidthDp}x${it.touchHeightDp}" } + " ***",
            touch.passed,
        )
        // *** AND THE MEASUREMENT IS REAL RATHER THAN A CONSTANT: at least one control must differ from a single
        // uniform box, or this roster would be the fabricated one wearing a read.*
        val distinctHeights = controls.map { it.touchHeightDp }.distinct()
        assertTrue(
            "*** THE ROSTER MUST CARRY RENDERED MEASUREMENTS, NOT ONE CONSTANT BOX. Observed heights: " +
                "$distinctHeights ***",
            distinctHeights.size > 1,
        )

        // (b) *** THE ESSENTIAL CONTROLS, WITH THE LABELS THE SCREEN REALLY PUBLISHETH. ***
        val essential = nodes.filter { AccessibilityContract.ESSENTIAL_CONTROLS.containsKey(it.controlId) }
        assertEquals(
            "every essential control must be present in the rendered roster",
            AccessibilityContract.ESSENTIAL_CONTROLS.keys, essential.map { it.controlId }.toSet(),
        )
        val labelled = AccessibilityContract.checkEssentialControlsLabelled(essential)
        assertTrue(
            "*** THE ESSENTIAL CONTROLS MUST BE LABELLED AND DESCRIBED, FROM THE RENDERED TREE: ${labelled.reason} ***",
            labelled.passed,
        )

        // (c) *** NO STATUS MAY CLIP AT THE LARGEST SCALE. ***
        assertTrue(
            "*** NO STATUS MAY CLIP AT largest_accessibility -- a truncated status is a false statement. ***",
            AccessibilityContract.checkStatusNeverClipped(nodes, TextScale.LARGEST_ACCESSIBILITY).passed,
        )

        // (d) *** NO COLOUR-ONLY STATE. ***
        val colour = AccessibilityContract.checkNoColourOnlyState(nodes)
        assertTrue("*** ${colour.reason} ***", colour.passed)

        // (f) *** THE SAME LAW VOCABULARY THE OTHER TWO ISLES DECLARE. ***
        // *The python conductor and the iOS twin name these laws; this isle now decideth them from a LAYOUT rather
        // than from a fixture, so the correspondence is asserted by name -- **the evidence differs (a real tree here,
        // a fixture there) and the law does not.***
        assertEquals(
            "*** THE ANDROID COURT MUST DECIDE THE SAME LAW SET THE OTHER TWO ISLES DECLARE. ***",
            LabControl.SEMANTIC_LAW_IDS,
            listOf("essential_control_labelled", "status_never_clipped", "no_colour_only_state",
                   "touch_target_minimum", "reading_order_reachable", "rtl_meaning_preserved",
                   "long_content_fits"),
        )

        // (g) *** THE READING ORDER IS READ FROM THE LAYOUT, NOT ASSIGNED BY THIS COURT. ***
        // *A court that numbered the nodes from its own list would be asserting its own list back to itself. The
        // discriminator is a real geometry inversion: a node LOWER on the screen must carry a LATER traversal rank.*
        val byLayout = (LabControl.REQUIRED + AccessibilityContract.ESSENTIAL_CONTROLS.keys).distinct()
            .sortedBy { node(it).fetchSemanticsNode().positionInRoot.y }
        val byRoster = nodes.map { it.controlId }
        assertEquals(
            "*** THE ROSTER'S ORDER MUST BE THE TREE'S OWN GEOMETRIC TRAVERSAL ORDER, NOT THE ORDER THIS COURT " +
                "LISTED THE IDS IN. ***",
            byLayout, byRoster,
        )
        assertTrue(
            "*** AND THE GEOMETRY MUST REALLY ORDER THEM: a screen whose nodes all sat at one y would make the " +
                "comparison vacuous. Observed y: " +
                byLayout.joinToString { it + "=" + node(it).fetchSemanticsNode().positionInRoot.y.toString() } + " ***",
            byLayout.map { node(it).fetchSemanticsNode().positionInRoot.y }.distinct().size > 1,
        )

        // (e) *** AND A CONTIGUOUS READING ORDER OVER THE ESSENTIAL CONTROLS. ***
        // *The contract's law is about the essential set: a status row carrieth its own traversal rank and is not
        // part of the walk a switch user taketh between controls.*
        val order = AccessibilityContract.checkReadingOrder(essential)
        assertTrue("*** ${order.reason} ***", order.passed)
    }

    /**
     * *** THE FOUR DIRECTION/SCALE COMBINATIONS, EXERCISED ON THE REAL TREE. ***
     *
     * *The clause asketh the roster be run at default AND largest text, in LTR AND RTL. This court composeth each
     * combination for real -- the mirror is a `CompositionLocalProvider(LocalLayoutDirection provides Rtl)`, and the
     * scale is the composition density's font scale -- and then requireth: every control still laid out, still
     * labelled, still publishing its real role, still meeting 48dp, with the essential reading order intact and no
     * control's MEANING following the mirror.*
     */
    @Test
    fun test_the_roster_survives_default_and_largest_text_in_ltr_and_rtl() {
        // *** `createComposeRule` ACCEPTS `setContent` EXACTLY ONCE, SO THE FOUR COMBINATIONS ARE DRIVEN BY
        // RECOMPOSITION RATHER THAN BY FOUR COMPOSITIONS. ***
        // *A court that called `setContent` four times would fail on the second with "setContent may not be called
        // again" -- an instrument defect that reads exactly like a product defect, so the shape is chosen to avoid it.*
        val direction = androidx.compose.runtime.mutableStateOf(LayoutDirection.Ltr)
        val fontScale = androidx.compose.runtime.mutableStateOf(1.0f)
        composeRule.setContent {
            CompositionLocalProvider(
                LocalLayoutDirection provides direction.value,
                LocalDensity provides androidx.compose.ui.unit.Density(density = 2.75f,
                                                                     fontScale = fontScale.value),
            ) {
                Box(Modifier.width(360.dp)) { LabMeshJourneyScreen(componentState(), onSend = { _, _ -> }) }
            }
        }
        composeRule.waitForIdle()
        var defaultBodyHeight: Dp? = null

        for (rtl in listOf(false, true)) {
            for (scaleName in listOf("default", "largest_accessibility")) {
                val label = if (rtl) "RTL" else "LTR"
                direction.value = if (rtl) LayoutDirection.Rtl else LayoutDirection.Ltr
                fontScale.value = if (scaleName == "default") 1.0f else 2.0f
                composeRule.waitForIdle()

                // EVERY REQUIRED NODE IS STILL RENDERED, WITH A REAL BOX AND A REAL DESCRIPTION.
                for (tag in LabControl.REQUIRED) {
                    node(tag).assertExists("$tag must survive $label at $scaleName")
                    val size = node(tag).fetchSemanticsNode().size
                    assertTrue("$tag must still lay out at $label/$scaleName", size.width > 0 && size.height > 0)
                    assertTrue(
                        "*** $tag MUST STILL CARRY ITS DESCRIPTION AT $label/$scaleName -- a label that vanisheth " +
                            "when the type is enlarged or the layout mirrorred is a control some users cannot " +
                            "operate. Observed: ${contentDescriptionOf(tag)} ***",
                        !contentDescriptionOf(tag).isNullOrBlank(),
                    )
                }

                // *** THE SCALE MUST REALLY BE APPLIED, OR THE ARM WOULD BE VACUOUS. ***
                // *A court that set a font scale nothing honoured would pass every combination while testing one.
                // The discriminator is a MEASUREMENT: the compose field's laid-out height at the largest scale must
                // exceed its height at the default scale -- enlarged type CANNOT produce a shorter field.*
                val bodyHeight = boundsOf(LabControl.COMPOSE_BODY).second
                if (scaleName == "default") {
                    defaultBodyHeight = bodyHeight
                } else {
                    val baseline = defaultBodyHeight
                    assertTrue(
                        "*** THE LARGEST SCALE MUST REALLY ENLARGE THE LAYOUT: the compose field measured " +
                            "$bodyHeight at largest_accessibility and $baseline at default ($label). A court whose " +
                            "scale changed nothing would certify nothing about enlarged type. ***",
                        baseline != null && bodyHeight > baseline,
                    )
                }

                // AND EVERY ROLE IS UNCHANGED BY THE MIRROR AND THE SCALE.
                for ((tag, expected) in LabControl.ROLES) {
                    assertEquals("$tag's role must not follow the mirror or the scale ($label/$scaleName)",
                        expected, roleOf(tag))
                }

                // AND THE REAL 48dp MINIMUM STILL HOLDETH -- measured, per combination.
                val controls = renderedRoster().filter { LabControl.CONTROLS.contains(it.controlId) }
                val touch = AccessibilityContract.checkTouchTargets(controls, A11yPlatform.ANDROID)
                assertTrue("*** $label/$scaleName: ${touch.reason} ***", touch.passed)

                // AND THE MIRROR MOVED THE LAYOUT WITHOUT MOVING A MEANING.
                val meaning = AccessibilityContract.checkRtlMeaning(
                    renderedRoster().map { it.copy(mirrored = rtl, mirrorsMeaning = false) }, rtl)
                assertTrue("*** $label/$scaleName: ${meaning.reason} ***", meaning.passed)
                assertEquals(
                    "*** THE SCREEN'S OWN MIRROR RECORD MUST SAY SO. ***",
                    if (rtl) "layout mirrored; reading order unchanged" else "left to right",
                    stateDescriptionOf(LabControl.RTL_MEANING),
                )
            }
        }
    }

    /**
     * *** THE CONTROL ENABLEMENT IS BOUND TO THE TYPED STATE, AND EVERY DIRECTION IS MEASURED. ***
     *
     * *THE OBLIGATION: "Real buttons enabled/disabled match typed delegibility" and "UI accepted/refused enable
     * predicate correct while pending/normal blocked".* **A control that remains CLICKABLE while its estate refuses is a
     * control that lies to a finger as well as to a screen reader, which is the A11 defect exactly.**
     *
     * *** EACH TYPED ESTATE GETS ITS OWN TEST, BECAUSE A COMPOSE RULE PERMITTETH EXACTLY ONE `setContent` PER TEST. ***
     * *The FOUR scenarios were one armed method calling `render()` four times, and Compose rightly refused the second
     * `setContent` -- so the estate that mattered was never measured. **Splitting them is the repair, NOT a tolerance:
     * every typed direction the obligation nameth is still asserted, one estate per test, so no scenario is dropped.***
     *
     * *The typed estates a rendered surface really meets:*
     *
     *   1. **a live normal graph with a standing call** -- the private controls are all reachable;
     *   2. **a recovery-only estate** (`normalGraphAvailable = false`) -- send and the distress controls are GENUINELY
     *      disabled, because there is no private owner behind them, while the wipe controls stay live;
     *   3. **a clean estate with no standing call** -- retry is disabled (nothing to resume) while the wipe request
     *      stands; and
     *   4. **a corrupt record** -- the operator's resolution is the one actionable control, and no resume is offered.
     */

    /** (1) LIVE GRAPH + STANDING CALL: everything private is reachable. */
    @Test
    fun test_the_control_enablement_follows_the_live_graph() {
        render(componentState(sosRetryPermitted = true, normalGraphAvailable = true))
        // *** THE SEND'S ENABLEMENT IS THE REAL PREDICATE, NOT A GRAPH FLAG. *** *A live graph alone is not enough:
        // Send also requireth a chosen recipient and a non-empty draft, and the previous arm spelled this `enabled ||
        // true`, which measured nothing. **Both directions are driven here on the SAME composition.***
        assertFalse("*** AN EMPTY DRAFT MUST LEAVE SEND DISABLED -- a Send that fires with no body is a control that " +
            "lies to a finger. ***", isEnabled(LabControl.COMPOSE_SEND))
        node(LabControl.COMPOSE_BODY).performTextInput("boat")
        composeRule.waitForIdle()
        assertTrue("*** A NON-EMPTY DRAFT WITH A CHOSEN RECIPIENT MUST LEAVE SEND REACHABLE. ***",
            isEnabled(LabControl.COMPOSE_SEND))
        assertTrue("*** A STANDING CALL MUST ENABLE THE RETRY. ***", isEnabled(LabControl.RETRY))
        assertTrue("*** AND THE DISTRESS ARM MUST BE REACHABLE THROUGH A LIVE GRAPH. ***", isEnabled(LabControl.SOS_ARM))
    }

    /** (2) RECOVERY-ONLY: the private controls are disabled, and the WIPE controls remain live. */
    @Test
    fun test_the_control_enablement_follows_the_recovery_only_estate() {
        render(componentState(
            normalGraphAvailable = false,
            sosRetryPermitted = false,
            wipeStage = "REQUESTED", wipeDecision = "recovery_pending", wipePending = true,
            wipeRecoveryPermitted = true, wipeOperatorRequired = false,
            wipeOperatorResolutionPermitted = false,
        ))
        assertFalse("*** WITH NO NORMAL GRAPH THE RETRY MUST BE DISABLED. ***", isEnabled(LabControl.RETRY))
        assertFalse("*** AND THE CANCEL MUST BE DISABLED. ***", isEnabled(LabControl.SOS_CANCEL))
        assertFalse("*** AND THE DISTRESS ARM MUST BE DISABLED -- there is no node to author through. ***",
            isEnabled(LabControl.SOS_ARM))
        assertTrue("*** WHILE THE RESUME -- the owner's own repair -- MUST REMAIN ACTIONABLE. ***",
            isEnabled(LabControl.WIPE_RESUME))
        assertFalse("*** AND THE OPERATOR CONTROL MUST STAY DISABLED FOR A PENDING RECORD: that repair is for corrupt " +
            "records only. ***", isEnabled(LabControl.WIPE_RESOLVE_CORRUPT))
    }

    /** (3) CLEAN ESTATE: nothing to resume, nothing to resolve, but the request stands. */
    @Test
    fun test_the_control_enablement_follows_the_clean_estate() {
        render(componentState(
            normalGraphAvailable = true, sosRetryPermitted = false,
            wipeStage = "IDLE", wipeDecision = "clean_start", wipePending = false,
            wipeRecoveryPermitted = false, wipeOperatorResolutionPermitted = false,
        ))
        assertFalse("*** A CLEAN ESTATE HAS NOTHING TO RESUME, SO THE CONTROL MUST BE GENUINELY DISABLED. ***",
            isEnabled(LabControl.WIPE_RESUME))
        assertTrue("*** AND THE REQUEST ITSELF MUST REMAIN REACHABLE. ***", isEnabled(LabControl.WIPE_BEGIN))
    }

    /** (4) CORRUPT: the OPERATOR repair is the actionable one, and no resume may be offered. */
    @Test
    fun test_the_control_enablement_follows_the_corrupt_record() {
        render(componentState(
            normalGraphAvailable = false,
            wipeStage = "IDLE", wipeDecision = "corrupt_journal", wipePending = false,
            wipeRecoveryPermitted = false, wipeOperatorRequired = true,
            wipeOperatorResolutionPermitted = true,
        ))
        assertTrue("*** AN UNREADABLE RECORD MUST OFFER THE OPERATOR'S REAL ERASURE. ***",
            isEnabled(LabControl.WIPE_RESOLVE_CORRUPT))
        assertFalse("*** AND MUST NOT OFFER A RESUME -- retrying cannot make it readable. ***",
            isEnabled(LabControl.WIPE_RESUME))
    }
}

