// T60 / GS-UX-001 step 9 -- the LIVE roster's own court (android isle, model level).
//
// `LiveAccessibilityRoster` decideth the SAME laws the contract owneth, but ONCE PER RUNTIME MODE. This court proveth:
//
//   * the roster takes its FOUR modes FROM THE CONTRACT ([TextScale.entries]) rather than declaring its own --
//     a second enum would be the drift the contract existeth to prevent;
//   * every one of the four modes is DECIDED, and a healthy screen passeth ALL of them;
//   * a POST-TRANSFORM defect (the shape the runtime produceth, not the initial render) is REFUSED in the mode that
//     carrieth it -- a clipped status at the largest scale, a control that folded below 48dp, a lost description;
//   * the `received`/`trace` logging NAMETH WHAT THE USER ACTUALLY GETS (the published words, the reachability and the
//     laid-out size), so a failing mode readeth like the screen rather than like the model it was supposed to be.
//
// NO rendering is claimed HERE: this court decideth the roster's own logic from a semantic model, exactly as
// `ReadinessT60Test` decideth the contract's. The RENDERED live roster is the lab court's, where a real Compose tree
// exists. Keeping them separate is the difference between "a model-contract test" and "a rendered witness" -- and the
// plan says the first must be labelled as such, never passed off as the second.
package io.godstone.mesh.readiness

import io.godstone.mesh.a11y.A11yPlatform
import io.godstone.mesh.a11y.AccessibilityContract
import io.godstone.mesh.a11y.ControlRole
import io.godstone.mesh.a11y.LiveAccessibilityRoster
import io.godstone.mesh.a11y.TextScale
import io.godstone.mesh.a11y.UiNode
import org.junit.Assert
import org.junit.Test

class ReadinessT60LiveRosterTest {

    private val min = A11yPlatform.ANDROID.touchTargetMinDp
    private val roster = LiveAccessibilityRoster()

    private fun words(state: String) = AccessibilityContract.STATE_WORDS.getValue(state)
    private fun token(state: String) = AccessibilityContract.STATE_COLOUR_TOKEN.getValue(state)

    /** The POST-TRANSFORM nodes a healthy screen produceth in EVERY mode. */
    private fun healthy(): List<UiNode> = listOf(
        UiNode("recipient_select", ControlRole.BUTTON, "Choose a recipient",
            "Choose a recipient", min, min, 0),
        UiNode("compose_send", ControlRole.BUTTON, "Send", "Send the message", min, min, 1),
        UiNode("sos_arm", ControlRole.BUTTON, "Distress call",
            AccessibilityContract.SOS_IDLE_HINT, min + 8, min + 8, 2),
        UiNode("sos_cancel", ControlRole.BUTTON, AccessibilityContract.SOS_CANCEL_LABEL,
            AccessibilityContract.SOS_CANCEL_LABEL, min + 8, min + 8, 3),
        UiNode("retry", ControlRole.BUTTON, "Retry", "Retry the message", min, min, 4),
        UiNode("status_row", ControlRole.STATIC_TEXT, words("ATTEMPTING"), words("ATTEMPTING"),
            0f, 0f, 5, stateWords = words("ATTEMPTING"), colourToken = token("ATTEMPTING")),
    )

    // ---------------------------------------------------------------- the four modes COME FROM the contract

    /**
     * *** THE ROSTER'S MODES ARE THE CONTRACT'S, NOT ITS OWN. ***
     *
     * *A second four-valued enum here would be a second declaration of the same modes, and the two would drift the
     * moment one is edited -- the exact defect the contract's "one vocabulary across both isles" law preventeth.*
     */
    @Test
    fun test_the_roster_takes_its_four_modes_from_the_contract() {
        Assert.assertEquals(
            "*** THE ROSTER'S MODES MUST BE THE CONTRACT'S OWN FOUR. ***",
            TextScale.entries.toList(), roster.modes,
        )
        Assert.assertEquals("the contract carrieth exactly four modes", 4, roster.modes.size)
        // and the largest the roster runneth IS the contract's largest
        Assert.assertEquals(TextScale.LARGEST_ACCESSIBILITY, LiveAccessibilityRoster.LARGEST)
        Assert.assertTrue(LiveAccessibilityRoster.LARGEST.isLargest)
    }

    /** Every mode is DECIDED, and a healthy screen passeth ALL of them. */
    @Test
    fun test_every_mode_is_decided_and_a_healthy_screen_passes_all_of_them() {
        val records = roster.roster({ _, _ -> healthy() })
        Assert.assertEquals("four modes x two directions", 8, records.size)
        Assert.assertEquals(
            "every mode and direction is represented",
            TextScale.entries.toSet(),
            records.map { it.mode }.toSet(),
        )
        for (record in records) {
            Assert.assertTrue(
                "*** A HEALTHY SCREEN MUST PASS EVERY MODE: ${record.mode}/${record.rtl} refused " +
                    "by ${record.refusal()} ***",
                record.passed,
            )
            // every law is decided, by the SAME names the contract and the other two isles declare
            Assert.assertEquals(
                setOf("essential_control_labelled", "status_never_clipped", "no_colour_only_state",
                    "touch_target_minimum", "reading_order_reachable", "rtl_meaning_preserved",
                    "long_content_fits"),
                record.verdicts.keys,
            )
        }
    }

    // ---------------------------------------------------------------- a POST-TRANSFORM defect is refused in its mode

    /**
     * *** A CLIPPED STATUS IS REFUSED IN THE MODE THAT CLIPPED IT -- THE SHAPE THE RUNTIME PRODUCETH. ***
     *
     * *THE INITIAL RENDER is whole; it is the state machinery (a longer status word arriving, the largest scale
     * reflowing) that clips it. That is why the roster decideth the POST-transform nodes: a check against the first
     * render would certify the very frame a user never keeps.*
     */
    @Test
    fun test_a_post_transform_status_clip_is_refused_in_its_mode() {
        val clipped = healthy().map { node ->
            if (node.controlId == "status_row") {
                node.copy(label = "On its way; no ans", truncated = true)
            } else node
        }
        val record = roster.decide(TextScale.LARGEST_ACCESSIBILITY, clipped)
        Assert.assertFalse("*** A CLIPPED STATUS MUST BE REFUSED. ***", record.passed)
        val refusal = record.refusal()
        Assert.assertNotNull(refusal)
        Assert.assertEquals("status_never_clipped", refusal!!.first)
        Assert.assertTrue(refusal.second.contains("CLIPPED"))
        // and the log NAMETH the clipped node and its size, so a reader seeth what the user got
        Assert.assertTrue(
            "*** THE LOG MUST NAME THE CLIPPED NODE. ***",
            record.received.any { it.contains("status_row") && it.contains("CLIPPED") },
        )
    }

    /** A control the runtime folded below the minimum is refused, and the refusal NAMETH the measured size. */
    @Test
    fun test_a_control_folded_below_the_minimum_is_refused_with_its_size() {
        val folded = healthy().map { node ->
            if (node.controlId == "compose_send") node.copy(touchHeightDp = 32f) else node
        }
        val record = roster.decide(TextScale.DEFAULT, folded)
        Assert.assertFalse(record.passed)
        Assert.assertEquals("touch_target_minimum", record.refusal()!!.first)
        Assert.assertTrue(record.refusal()!!.second.contains("compose_send"))
        Assert.assertTrue(record.refusal()!!.second.contains("32.0"))
    }

    /** A description the state machinery dropped is refused. */
    @Test
    fun test_a_description_lost_in_the_runtime_is_refused() {
        val lost = healthy().map { node ->
            if (node.controlId == "retry") node.copy(contentDescription = "") else node
        }
        val record = roster.decide(TextScale.LARGE, lost)
        Assert.assertFalse(record.passed)
        Assert.assertEquals("essential_control_labelled", record.refusal()!!.first)
        Assert.assertTrue(
            "the log must name the undescribed node",
            record.received.any { it.contains("retry") && it.contains("<NO DESCRIPTION>") },
        )
    }

    /**
     * *** A MEANING FLIP IS REFUSED IN BOTH DIRECTIONS -- WHICH IS WHAT THE CONTRACT REALLY DOTH. ***
     *
     * *MEASURED AGAINST THE REAL `checkRtlMeaning`: the refusal is `mirrored && mirrorsMeaning`, and the `rtl` flag
     * only appeareth in the MESSAGE -- because a control whose MEANING followed the layout is wrong whether the
     * layout is mirrored or not, and gating on the flag would let the same lie pass in the un-mirrored mode.* **An
     * arm asserting LTR passes would be asserting a behaviour the contract does not have.***
     */
    @Test
    fun test_a_meaning_flip_is_refused_in_both_directions() {
        val flipped = healthy().map { node ->
            if (node.controlId == "compose_send") node.copy(mirrored = true, mirrorsMeaning = true) else node
        }
        for (rtl in listOf(false, true)) {
            val record = roster.decide(TextScale.DEFAULT, flipped, rtl = rtl)
            Assert.assertFalse("*** A MEANING FLIP MUST BE REFUSED (rtl=$rtl). ***", record.passed)
            Assert.assertEquals("rtl_meaning_preserved", record.refusal()!!.first)
        }
        // and a node that mirrored the LAYOUT without moving the MEANING is fine in either direction
        for (rtl in listOf(false, true)) {
            val honest = healthy().map { it.copy(mirrored = true, mirrorsMeaning = false) }
            Assert.assertTrue(
                "a layout-only mirror is lawful (rtl=$rtl)",
                roster.decide(TextScale.DEFAULT, honest, rtl = rtl).passed,
            )
        }
    }

    // ---------------------------------------------------------------- the logging

    /**
     * *** THE LOG NAMETH WHAT THE USER ACTUALLY RECEIVES -- NOT THE COMPONENT'S INTENT. ***
     *
     * *Each line carrieth the mode, the reachability, the laid-out size and the state word the runtime wrote; a trace
     * of a failing mode therefore readeth like the screen the user saw.*
     */
    @Test
    fun test_the_log_reports_the_post_transform_values_the_user_receives() {
        val disabled = healthy().map { node ->
            if (node.controlId == "sos_arm") node.copy(enabled = false) else node
        }
        val record = roster.decide(TextScale.LARGEST, disabled)
        Assert.assertTrue(
            "*** THE LOG MUST SHOW THE DISABLED CONTROL AS DISABLED. ***",
            record.received.any { it.contains("sos_arm") && it.contains("DISABLED") },
        )
        Assert.assertTrue(
            "*** AND THE STATE WORD THE STATE MACHINERY WROTE. ***",
            record.received.any { it.contains("status_row") && it.contains(words("ATTEMPTING")) },
        )
        // and the mode is named on every line, so a trace across four modes is unambiguous
        Assert.assertTrue(record.received.all { it.contains("largest") })
    }

    /** The whole-roster trace carrieth each mode's verdict and its refusal, by name. */
    @Test
    fun test_the_trace_names_each_mode_and_its_refusal() {
        val records = roster.roster({ mode, _ ->
            if (mode == TextScale.LARGEST_ACCESSIBILITY) {
                healthy().map { if (it.controlId == "status_row") it.copy(truncated = true) else it }
            } else healthy()
        })
        val text = roster.trace(records)
        Assert.assertTrue(text.contains("mode=default LTR PASS"))
        Assert.assertTrue(text.contains("mode=largest_accessibility RTL FAIL"))
        Assert.assertTrue(text.contains("refused by status_never_clipped"))
    }
}
