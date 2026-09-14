// T60 readiness court (android isle) -- the automated accessibility and
// restoration checks, the twin of the python conductor and the iOS contract.
//
// The card's law: "Remove an essential control label or clip status at large text:
// UI/accessibility check fails." Every witness below drives the REAL
// `AccessibilityContract` and asserts a VERDICT WITH ITS REASON, so a refusal is
// never a bare false.
//
// No device behaviour is claimed: this court decideth the semantic model, and the
// human T74 audit owneth what a person alone can see.
package io.godstone.mesh.readiness

import io.godstone.mesh.a11y.A11yPlatform
import io.godstone.mesh.a11y.AccessibilityAssertion
import io.godstone.mesh.a11y.AccessibilityContract
import io.godstone.mesh.a11y.ControlRole
import io.godstone.mesh.a11y.Requirement
import io.godstone.mesh.a11y.TextScale
import io.godstone.mesh.a11y.UiNode
import org.junit.Assert
import org.junit.Test

class ReadinessT60Test {
    private val min = A11yPlatform.ANDROID.touchTargetMinDp

    /** A screen that passeth every automated check. */
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

    private fun words(state: String) = AccessibilityContract.STATE_WORDS.getValue(state)
    private fun token(state: String) = AccessibilityContract.STATE_COLOUR_TOKEN.getValue(state)

    // ------------------------------------------------------------ W01

    /** W01 -- the contract carrieth requirement classes, and decideth its own. */
    @Test
    fun test_w01_the_contract_carrieth_requirement_classes() {
        val assertion = AccessibilityAssertion(
            "essential_control_labelled", Requirement.AUTOMATED, A11yPlatform.ANDROID,
            TextScale.LARGEST, journey = "cold_launch_airplane")
        Assert.assertEquals(Requirement.AUTOMATED, assertion.requirement)
        Assert.assertTrue("the largest scale is the accessibility one",
            TextScale.LARGEST_ACCESSIBILITY.isLargest)
        Assert.assertFalse(TextScale.DEFAULT.isLargest)
        val pass = AccessibilityContract.checkEssentialControlsLabelled(healthy())
        Assert.assertTrue(pass.reason, pass.passed)
        // the same words the durable projection speaketh, on both channels
        Assert.assertEquals(6, AccessibilityContract.STATE_WORDS.size)
        Assert.assertEquals(6, AccessibilityContract.STATE_COLOUR_TOKEN.size)
    }

    // ------------------------------------------------------------ W02

    /** W02 -- contrast is computed for real (WCAG 2.1). */
    @Test
    fun test_w02_contrast_is_computed_for_real() {
        Assert.assertEquals(21.0, AccessibilityContract.contrastRatio("#ffffff", "#000000"), 0.1)
        val weak = AccessibilityContract.contrastRatio("#777777", "#888888")
        Assert.assertTrue("a weak body pair must fall below AA: $weak",
            weak < AccessibilityContract.CONTRAST_BODY_MIN)
        val large = AccessibilityContract.contrastRatio("#949494", "#ffffff")
        Assert.assertTrue("a large-text pair at >= 3:1: $large",
            large >= AccessibilityContract.CONTRAST_LARGE_MIN)
        Assert.assertTrue(large < AccessibilityContract.CONTRAST_BODY_MIN)
        Assert.assertTrue(
            AccessibilityContract.contrastRatio("#b3261e", "#ffffff") >=
                AccessibilityContract.CONTRAST_BODY_MIN)
        var refused = false
        try {
            AccessibilityContract.contrastRatio("#zzz", "#fff")
        } catch (_e: IllegalArgumentException) {
            refused = true
        }
        Assert.assertTrue("a malformed colour is refused", refused)
    }

    // ------------------------------------------------------------ W03

    /** W03 -- THE NAMED NEGATIVE, first limb: a label-less essential control. */
    @Test
    fun test_w03_an_essential_control_without_a_label_is_refused() {
        val blank = healthy().toMutableList()
        blank[1] = UiNode("compose_send", ControlRole.BUTTON, "", "Send the message", min, min, 1)
        val verdict = AccessibilityContract.checkEssentialControlsLabelled(blank)
        Assert.assertFalse(verdict.passed)
        Assert.assertTrue(verdict.reason, verdict.reason.contains("compose_send"))
        Assert.assertTrue(verdict.reason.contains("label is empty"))

        val undescribed = healthy().toMutableList()
        undescribed[4] = UiNode("retry", ControlRole.BUTTON, "Retry", "", min, min, 4)
        val verdict2 = AccessibilityContract.checkEssentialControlsLabelled(undescribed)
        Assert.assertFalse(verdict2.passed)
        Assert.assertTrue(verdict2.reason.contains("read nothing"))

        val absent = healthy().filter { it.controlId != "sos_cancel" }
        val verdict3 = AccessibilityContract.checkEssentialControlsLabelled(absent)
        Assert.assertFalse(verdict3.passed)
        Assert.assertTrue(verdict3.reason.contains("sos_cancel"))
        Assert.assertTrue(verdict3.reason.contains("absent"))
    }

    // ------------------------------------------------------------ W04

    /** W04 -- THE NAMED NEGATIVE, second limb: a status clipped at large text. */
    @Test
    fun test_w04_a_clipped_status_is_refused_at_large_text() {
        val clipped = healthy().toMutableList()
        clipped[5] = UiNode("status_row", ControlRole.STATIC_TEXT, "On its way; no ans",
            words("ATTEMPTING"), 0f, 0f, 5, stateWords = words("ATTEMPTING"),
            colourToken = token("ATTEMPTING"), truncated = true)
        val verdict = AccessibilityContract.checkStatusNeverClipped(
            clipped, TextScale.LARGEST_ACCESSIBILITY)
        Assert.assertFalse(verdict.passed)
        Assert.assertTrue(verdict.reason.contains("CLIPPED"))
        Assert.assertTrue(verdict.reason.contains("largest_accessibility"))
        // the law is about the text surviving, not about which scale was simulated
        Assert.assertFalse(
            AccessibilityContract.checkStatusNeverClipped(clipped, TextScale.DEFAULT).passed)
    }

    // ------------------------------------------------------------ W05

    /** W05 -- no colour-only state, in either direction. */
    @Test
    fun test_w05_no_colour_only_state() {
        Assert.assertEquals("two states must not share words",
            AccessibilityContract.STATE_WORDS.size,
            AccessibilityContract.STATE_WORDS.values.toSet().size)
        // two states MAY share a colour token
        Assert.assertEquals(token("QUEUED"), token("CANCELLED"))
        Assert.assertNotEquals(words("QUEUED"), words("CANCELLED"))

        val noColour = healthy().toMutableList()
        noColour[5] = UiNode("status_row", ControlRole.STATIC_TEXT, "On its way", "On its way",
            0f, 0f, 5, stateWords = words("ATTEMPTING"), colourToken = "")
        val verdict = AccessibilityContract.checkNoColourOnlyState(noColour)
        Assert.assertFalse(verdict.passed)
        Assert.assertTrue(verdict.reason.contains("no colour token"))

        val noWords = healthy().toMutableList()
        noWords[5] = UiNode("status_row", ControlRole.STATIC_TEXT, "", "", 0f, 0f, 5,
            stateWords = "", colourToken = "error")
        val verdict2 = AccessibilityContract.checkNoColourOnlyState(noWords)
        Assert.assertFalse(verdict2.passed)
        Assert.assertTrue(verdict2.reason.contains("NO words"))
    }

    // ------------------------------------------------------------ W06

    /** W06 -- the platform minimums differ, and 44 is enough for iOS only. */
    @Test
    fun test_w06_the_touch_target_minimums_differ_by_platform() {
        Assert.assertEquals(48f, A11yPlatform.ANDROID.touchTargetMinDp)
        Assert.assertEquals(44f, A11yPlatform.IOS.touchTargetMinDp)
        val small = healthy().toMutableList()
        small[1] = UiNode("compose_send", ControlRole.BUTTON, "Send", "Send", 44f, 44f, 1)
        Assert.assertTrue(
            AccessibilityContract.checkTouchTargets(small, A11yPlatform.IOS).passed)
        val androidVerdict = AccessibilityContract.checkTouchTargets(small, A11yPlatform.ANDROID)
        Assert.assertFalse(androidVerdict.passed)
        Assert.assertTrue(androidVerdict.reason.contains("48.0"))

        // a static text node is not a target
        val withText = healthy() + UiNode("caption", ControlRole.STATIC_TEXT, "note", "note",
            0f, 0f, 6)
        Assert.assertTrue(
            AccessibilityContract.checkTouchTargets(withText, A11yPlatform.ANDROID).passed)
    }

    // ------------------------------------------------------------ W07

    /** W07 -- the reading order is contiguous, and every node is described. */
    @Test
    fun test_w07_the_reading_order_is_contiguous_and_complete() {
        Assert.assertTrue(AccessibilityContract.checkReadingOrder(healthy()).passed)
        val gapped = healthy().toMutableList()
        gapped[3] = UiNode("sos_cancel", ControlRole.BUTTON, AccessibilityContract.SOS_CANCEL_LABEL,
            AccessibilityContract.SOS_CANCEL_LABEL, min + 8, min + 8, 9)
        val verdict = AccessibilityContract.checkReadingOrder(gapped)
        Assert.assertFalse(verdict.passed)
        Assert.assertTrue(verdict.reason.contains("not contiguous"))

        val undeclared = healthy() + UiNode("decorative", ControlRole.IMAGE_BUTTON, "", "",
            min, min, 6)
        val verdict2 = AccessibilityContract.checkReadingOrder(undeclared)
        Assert.assertFalse(verdict2.passed)
        Assert.assertTrue(verdict2.reason.contains("no description"))
    }

    // ------------------------------------------------------------ W08

    /** W08 -- the mirror may move the layout, never a meaning. */
    @Test
    fun test_w08_rtl_mirror_may_not_move_a_meaning() {
        val mirrored = healthy().map { it.copy(mirrored = true, mirrorsMeaning = false) }
        Assert.assertTrue("a mirrored LAYOUT is fine",
            AccessibilityContract.checkRtlMeaning(mirrored, rtl = true).passed)

        val flipped = healthy().toMutableList()
        flipped[1] = flipped[1].copy(mirrored = true, mirrorsMeaning = true)
        val verdict = AccessibilityContract.checkRtlMeaning(flipped, rtl = true)
        Assert.assertFalse(verdict.passed)
        Assert.assertTrue(verdict.reason.contains("mirrored with the layout"))
    }

    // ------------------------------------------------------------ W09

    /** W09 -- long content fitteth, and an essential label is never clipped. */
    @Test
    fun test_w09_long_content_locale_fixtures_fit() {
        val long = "Zugestellt: Die Empfangerin hat den Empfang bestatigt"
        val overflowing = healthy().toMutableList()
        overflowing[0] = overflowing[0].copy(label = long, contentDescription = long,
            containerWidthDp = 200f, contentWidthDp = 260f)
        Assert.assertTrue("an overflowing container is fine while the label standeth whole",
            AccessibilityContract.checkLongContent(overflowing, locale = "de").passed)

        val clipped = healthy().toMutableList()
        clipped[0] = clipped[0].copy(label = long.take(20), contentDescription = long,
            containerWidthDp = 200f, contentWidthDp = 260f, truncated = true)
        val verdict = AccessibilityContract.checkLongContent(clipped, locale = "de")
        Assert.assertFalse(verdict.passed)
        Assert.assertTrue(verdict.reason.contains("recipient_select"))
        Assert.assertTrue(verdict.reason.contains("clipped"))

        // an RTL fixture is one of the fixtures, and the ARABIC words are spoken too
        val arabic = "\u062a\u0645 \u0627\u0644\u062a\u0633\u0644\u064a\u0645"
        val rtl = healthy().toMutableList()
        rtl[5] = rtl[5].copy(stateWords = arabic, contentDescription = arabic,
            colourToken = token("DELIVERED"))
        Assert.assertTrue(
            AccessibilityContract.checkLongContent(rtl, locale = "ar").passed)
        Assert.assertTrue(AccessibilityContract.checkStatusNeverClipped(
            rtl, TextScale.LARGEST_ACCESSIBILITY).passed)
    }

    // ------------------------------------------------------------ W10

    /** W10 -- the restoration checkpoints distinguish the human ones. */
    @Test
    fun test_w10_the_restoration_checkpoints_distinguish_human_checks() {
        val durable = io.godstone.mesh.a11y.RestorationCheckpoint(
            "cold_launch_airplane.durable_estate", Requirement.AUTOMATED,
            "the held rows and their authority status", survivesAirplaneMode = true)
        val human = io.godstone.mesh.a11y.RestorationCheckpoint(
            "cold_launch_airplane.human_screenreader", Requirement.HUMAN_REQUIRED,
            "none: this is a human observation, not durable state", survivesAirplaneMode = true)
        Assert.assertEquals(Requirement.AUTOMATED, durable.requirement)
        Assert.assertEquals(Requirement.HUMAN_REQUIRED, human.requirement)
        Assert.assertTrue(durable.survivesAirplaneMode)
        Assert.assertTrue(human.durableFact.contains("human observation"))
        Assert.assertNotEquals(durable.requirement, human.requirement)
    }

    // ------------------------------------------------------------ W11

    /** W11 -- the SOS hold gesture is SPOKEN, because a reader cannot hold it. */
    @Test
    fun test_w11_the_hold_gesture_is_spoken() {
        Assert.assertNotEquals(AccessibilityContract.SOS_IDLE_HINT,
            AccessibilityContract.SOS_ARMED_HINT)
        Assert.assertTrue(AccessibilityContract.SOS_IDLE_HINT.contains("Hold"))
        Assert.assertTrue(AccessibilityContract.SOS_ARMED_HINT.contains("Confirm"))
        Assert.assertTrue(AccessibilityContract.SOS_CANCEL_LABEL.contains("Cancel"))
        Assert.assertTrue(AccessibilityContract.SOS_CONFIRM_LABEL.contains("Confirm"))
        // every hint is a full sentence a reader can act on, not a colour word
        for (hint in listOf(AccessibilityContract.SOS_IDLE_HINT,
            AccessibilityContract.SOS_ARMED_HINT, AccessibilityContract.SOS_CANCEL_LABEL,
            AccessibilityContract.SOS_CONFIRM_LABEL)
        ) {
            Assert.assertTrue("a hint carrieth words: $hint", hint.length > 8)
        }
    }

    // ------------------------------------------------------------ W12

    /** W12 -- the durable status vocabulary is the one T43 projects, not a copy. */
    @Test
    fun test_w12_the_words_are_the_durable_vocabulary() {
        // the six states the durable projection carrieth, by name
        for (state in listOf("QUEUED", "ATTEMPTING", "DELIVERED", "CANCELLED", "EXPIRED",
            "FAILED")
        ) {
            Assert.assertTrue("the vocabulary carrieth $state",
                AccessibilityContract.STATE_WORDS.containsKey(state))
            Assert.assertTrue("and a colour token for $state",
                AccessibilityContract.STATE_COLOUR_TOKEN.containsKey(state))
        }
        // the words the DELIVERED state carrieth require the recipient's ACK, and
        // the ATTEMPTING words say there is no answer: the two may never read alike
        Assert.assertTrue(words("DELIVERED").contains("confirmed"))
        Assert.assertTrue(words("ATTEMPTING").contains("no answer"))
        Assert.assertNotEquals(words("DELIVERED"), words("ATTEMPTING"))
        // and no state's words claim a colour alone
        for ((state, word) in AccessibilityContract.STATE_WORDS) {
            Assert.assertTrue("$state carrieth words", word.isNotBlank())
            Assert.assertFalse("$state is not a colour name", word.lowercase() in setOf("red", "green", "amber"))
        }
    }

    // ------------------------------------------------------------ W13

    /** W13 -- every automated check refuseth by NAME, and the human boundary holds. */
    @Test
    fun test_w13_every_check_refuseth_by_name() {
        val checks: List<Pair<String, () -> io.godstone.mesh.a11y.Verdict>> = listOf(
            "essential_control_labelled" to {
                AccessibilityContract.checkEssentialControlsLabelled(
                    healthy().toMutableList().also {
                        it[1] = it[1].copy(label = "")
                    })
            },
            "status_never_clipped" to {
                AccessibilityContract.checkStatusNeverClipped(
                    healthy().toMutableList().also { it[5] = it[5].copy(truncated = true) },
                    TextScale.LARGEST_ACCESSIBILITY)
            },
            "no_colour_only_state" to {
                AccessibilityContract.checkNoColourOnlyState(
                    healthy().toMutableList().also { it[5] = it[5].copy(colourToken = "") })
            },
            "touch_target_minimum" to {
                AccessibilityContract.checkTouchTargets(
                    healthy().toMutableList().also {
                        it[1] = it[1].copy(touchWidthDp = 20f, touchHeightDp = 20f)
                    }, A11yPlatform.ANDROID)
            },
            "reading_order_reachable" to {
                AccessibilityContract.checkReadingOrder(
                    healthy().toMutableList().also { it[0] = it[0].copy(readingOrder = 42) })
            },
            "rtl_meaning_preserved" to {
                AccessibilityContract.checkRtlMeaning(
                    healthy().map { it.copy(mirrored = true, mirrorsMeaning = true) }, rtl = true)
            },
            "long_content_fits" to {
                AccessibilityContract.checkLongContent(
                    healthy().toMutableList().also {
                        it[0] = it[0].copy(truncated = true, containerWidthDp = 10f,
                            contentWidthDp = 99f)
                    }, locale = "fi")
            },
        )
        for ((name, check) in checks) {
            val verdict = check()
            Assert.assertFalse("$name must refuse", verdict.passed)
            Assert.assertTrue("$name must refuse BY NAME: ${verdict.reason}", verdict.reason.length > 12)
        }
        // and the healthy screen passeth every one of them
        Assert.assertTrue(AccessibilityContract.checkEssentialControlsLabelled(healthy()).passed)
        Assert.assertTrue(AccessibilityContract.checkStatusNeverClipped(
            healthy(), TextScale.LARGEST_ACCESSIBILITY).passed)
        Assert.assertTrue(AccessibilityContract.checkNoColourOnlyState(healthy()).passed)
        Assert.assertTrue(AccessibilityContract.checkTouchTargets(
            healthy(), A11yPlatform.ANDROID).passed)
        Assert.assertTrue(AccessibilityContract.checkReadingOrder(healthy()).passed)
        Assert.assertTrue(AccessibilityContract.checkRtlMeaning(healthy(), rtl = false).passed)
        Assert.assertTrue(AccessibilityContract.checkLongContent(healthy(), "en").passed)
    }
}
