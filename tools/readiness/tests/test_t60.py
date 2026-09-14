#! /usr/bin/env python3
"""T60 readiness court: the automated accessibility and restoration checks.

The card's law, one witness each where the rule speaketh:

  W01 the conductor's journeys and assertions carrieth a REQUIREMENT class, and
      the automated ones are decided by the conductor itself
  W02 CONTRAST: the WCAG ratio is computed for real, and a body pair below 4.5:1
      is refused while a large-text pair at 3:1 passeth
  W03 THE NAMED NEGATIVE, first limb: an essential control that loseth its label is
      refused BY NAME
  W04 THE NAMED NEGATIVE, second limb: a status CLIPPED at the largest text scale
      is refused BY NAME
  W05 no colour-only state: every pair of states carrieth different WORDS, and a
      node with a colour and no words is refused
  W06 the platform touch-target minimums differ (48dp / 44pt) and a control below
      its platform's minimum is refused
  W07 the reading order is contiguous and complete, so a switch user can walk it
  W08 RTL: the mirror may move the layout but never a control's MEANING
  W09 LONG CONTENT: the locale fixtures fit, and an essential label is never
      clipped
  W10 the RESTORATION checkpoints: the durable ones are automated, the screen-reader
      one is HUMAN_REQUIRED, and airplane-mode cold start surviveth
  W11 the human-required checks are DISTINGUISHED, never claimed as automated
  W12 the verification-matrix prose agreeth with the conductor: the accessibility
      rows are the ones this conductor owneth, and the device rows stay external
  W13 every ACTIVE profile is covered, and the LIGHT profile carrieth no radio
      control to label in the first place

No external gate is closed; readiness stays false; the human audit stays the human
audit (T74), and no automated result standeth in for it.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

from accessibility import (  # noqa: E402
    CONTRAST_BODY_MIN, CONTRAST_LARGE_MIN, ESSENTIAL_CONTROLS, JOURNEY_CASES,
    LARGEST_TEXT_SCALE, LONG_CONTENT_FIXTURES, STATE_COLOUR_TOKEN, STATE_WORDS,
    TOUCH_TARGET_MIN, AccessibilityAssertion, ControlRole, DeliveryState,
    JourneyCase, Platform, Profile, Requirement, RestorationCheckpoint, TextScale,
    UiNode, check_assertion, conductor_report, contrast_ratio,
)


def healthy_nodes(platform: Platform = Platform.ANDROID) -> list[UiNode]:
    """A screen that passeth every automated assertion."""
    minimum = TOUCH_TARGET_MIN[platform]
    nodes = [
        UiNode("compose_send", ControlRole.BUTTON, "Send", "Send the message",
               minimum, minimum, 1, enabled=True),
        UiNode("sos_arm", ControlRole.BUTTON, "Distress call", "Hold to place a distress call",
               minimum + 8, minimum + 8, 2),
        UiNode("sos_cancel", ControlRole.BUTTON, "Cancel the distress call",
               "Cancel the distress call", minimum + 8, minimum + 8, 3),
        UiNode("retry", ControlRole.BUTTON, "Retry", "Retry the message", minimum, minimum, 4),
        UiNode("recipient_select", ControlRole.BUTTON, "Choose a recipient",
               "Choose a recipient", minimum, minimum, 0),
        UiNode("status_row", ControlRole.STATIC_TEXT, STATE_WORDS[DeliveryState.ATTEMPTING],
               STATE_WORDS[DeliveryState.ATTEMPTING], 0, 0, 5,
               state_words=STATE_WORDS[DeliveryState.ATTEMPTING],
               colour_token=STATE_COLOUR_TOKEN[DeliveryState.ATTEMPTING]),
    ]
    return nodes


def assertion(assertion_id: str, platform: Platform = Platform.ANDROID,
              profile: Profile = Profile.LABMESH,
              scale: TextScale = LARGEST_TEXT_SCALE, **kw) -> AccessibilityAssertion:
    return AccessibilityAssertion(assertion_id=assertion_id, requirement=Requirement.AUTOMATED,
                                  detail=assertion_id, platform=platform, profile=profile,
                                  text_scale=scale, **kw)


class T60ConductorTest(unittest.TestCase):
    """W01-W02 -- the conductor's shape, and the contrast math."""

    def test_w01_the_conductor_carrieth_requirement_classes(self):
        self.assertTrue(JOURNEY_CASES)
        for case in JOURNEY_CASES:
            self.assertIsInstance(case, JourneyCase)
            self.assertTrue(case.steps)
            self.assertTrue(case.assertions, f"{case.case_id} carrieth no assertion")
            self.assertTrue(case.checkpoints, f"{case.case_id} carrieth no checkpoint")
            for check in case.assertions:
                self.assertIn(check.requirement,
                              (Requirement.AUTOMATED, Requirement.HUMAN_REQUIRED))
            for checkpoint in case.checkpoints:
                self.assertIsInstance(checkpoint, RestorationCheckpoint)
                self.assertTrue(checkpoint.durable_fact)
        # the automated core is the SAME set on every journey: one law, every lane
        ids = {frozenset(a.assertion_id for a in case.assertions) for case in JOURNEY_CASES}
        self.assertEqual(len(ids), 1, "every journey must carry the one automated law set")
        # and the conductor decideth the automated ones itself
        passed, reason = check_assertion(assertion("essential_control_labelled"),
                                         healthy_nodes())
        self.assertTrue(passed, reason)

    def test_w02_contrast_is_computed_for_real(self):
        # white on black is the maximum: 21:1
        self.assertAlmostEqual(contrast_ratio("#ffffff", "#000000"), 21.0, places=1)
        # a body pair below the AA threshold is refused by the arithmetic
        weak = contrast_ratio("#777777", "#888888")
        self.assertLess(weak, CONTRAST_BODY_MIN)
        # a large-text pair AT 3:1 is acceptable for large text
        large = contrast_ratio("#949494", "#ffffff")
        self.assertGreaterEqual(large, CONTRAST_LARGE_MIN)
        self.assertLess(large, CONTRAST_BODY_MIN)
        # the repository's own tokens: the error colour on a light surface
        self.assertGreaterEqual(contrast_ratio("#b3261e", "#ffffff"), CONTRAST_BODY_MIN)
        with self.assertRaises(ValueError):
            contrast_ratio("#zzz", "#fff")


class T60NamedNegativeTest(unittest.TestCase):
    """W03-W05 -- the two limbs of the named negative, and the colour law."""

    def test_w03_an_essential_control_without_a_label_is_refused(self):
        nodes = healthy_nodes()
        nodes[0] = UiNode("compose_send", ControlRole.BUTTON, "", "Send the message",
                          TOUCH_TARGET_MIN[Platform.ANDROID], TOUCH_TARGET_MIN[Platform.ANDROID], 1)
        passed, reason = check_assertion(assertion("essential_control_labelled"), nodes)
        self.assertFalse(passed, "a control with no visible label must be refused")
        self.assertIn("compose_send", reason)
        self.assertIn("label is empty", reason)

        # a control a screen reader cannot describe is refused too
        nodes2 = healthy_nodes()
        nodes2[3] = UiNode("retry", ControlRole.BUTTON, "Retry", "",
                           TOUCH_TARGET_MIN[Platform.ANDROID], TOUCH_TARGET_MIN[Platform.ANDROID], 4)
        passed2, reason2 = check_assertion(assertion("essential_control_labelled"), nodes2)
        self.assertFalse(passed2)
        self.assertIn("read nothing", reason2)

        # an ABSENT essential control is refused by name
        nodes3 = [n for n in healthy_nodes() if n.control_id != "sos_cancel"]
        passed3, reason3 = check_assertion(assertion("essential_control_labelled"), nodes3)
        self.assertFalse(passed3)
        self.assertIn("sos_cancel", reason3)
        self.assertIn("absent", reason3)

    def test_w04_a_clipped_status_is_refused_at_large_text(self):
        nodes = healthy_nodes()
        nodes[5] = UiNode("status_row", ControlRole.STATIC_TEXT, "On its way; no ans",
                          "On its way; no answer yet", 0, 0, 5,
                          state_words=STATE_WORDS[DeliveryState.ATTEMPTING],
                          colour_token=STATE_COLOUR_TOKEN[DeliveryState.ATTEMPTING],
                          truncated=True)
        passed, reason = check_assertion(assertion("status_never_clipped"), nodes)
        self.assertFalse(passed, "a clipped status must be refused")
        self.assertIn("CLIPPED", reason)
        self.assertIn("largest_accessibility", reason)

        # ... and the SAME screen at the default scale is still refused: the law
        # is about the text surviving, not about which scale was simulated
        passed_default, _ = check_assertion(
            assertion("status_never_clipped", scale=TextScale.DEFAULT), nodes)
        self.assertFalse(passed_default)

    def test_w05_no_colour_only_state(self):
        words = set(STATE_WORDS.values())
        self.assertEqual(len(words), len(DeliveryState),
                         "two states share the same words: colour would be the only channel")
        # two states MAY share a colour token; they may never share words
        self.assertNotEqual(STATE_WORDS[DeliveryState.QUEUED], STATE_WORDS[DeliveryState.CANCELLED])
        self.assertEqual(STATE_COLOUR_TOKEN[DeliveryState.QUEUED],
                         STATE_COLOUR_TOKEN[DeliveryState.CANCELLED])

        nodes = healthy_nodes()
        nodes[5] = UiNode("status_row", ControlRole.STATIC_TEXT, "On its way", "On its way",
                          0, 0, 5, state_words=STATE_WORDS[DeliveryState.ATTEMPTING],
                          colour_token="")
        passed, reason = check_assertion(assertion("no_colour_only_state"), nodes)
        self.assertFalse(passed)
        self.assertIn("no colour token", reason)

        # the reverse: a colour with no words is worse -- the screen would say
        # nothing at all to a screen reader
        nodes2 = healthy_nodes()
        nodes2[5] = UiNode("status_row", ControlRole.STATIC_TEXT, "", "",
                           0, 0, 5, state_words="", colour_token="error")
        passed2, reason2 = check_assertion(assertion("no_colour_only_state"), nodes2)
        self.assertFalse(passed2)
        self.assertIn("NO words", reason2)


class T60LayoutTest(unittest.TestCase):
    """W06-W09 -- targets, order, RTL and long content."""

    def test_w06_the_touch_target_minimums_differ_by_platform(self):
        self.assertEqual(TOUCH_TARGET_MIN[Platform.ANDROID], 48.0)
        self.assertEqual(TOUCH_TARGET_MIN[Platform.IOS], 44.0)
        # a 44-unit control PASSETH on iOS and FAILETH on Android
        nodes = healthy_nodes()
        nodes[0] = UiNode("compose_send", ControlRole.BUTTON, "Send", "Send",
                          44.0, 44.0, 1)
        ios_passed, _ = check_assertion(
            assertion("touch_target_minimum", platform=Platform.IOS), nodes)
        android_passed, android_reason = check_assertion(
            assertion("touch_target_minimum", platform=Platform.ANDROID), nodes)
        self.assertTrue(ios_passed)
        self.assertFalse(android_passed)
        self.assertIn("48.0", android_reason)

    def test_w07_the_reading_order_is_contiguous_and_complete(self):
        passed, _ = check_assertion(assertion("reading_order_reachable"), healthy_nodes())
        self.assertTrue(passed)
        # a gap in the order is refused: a switch user could not walk it
        nodes = healthy_nodes()
        nodes[2] = UiNode("sos_cancel", ControlRole.BUTTON, "Cancel the distress call",
                          "Cancel the distress call", 56, 56, 9)
        passed2, reason2 = check_assertion(assertion("reading_order_reachable"), nodes)
        self.assertFalse(passed2)
        self.assertIn("not contiguous", reason2)
        # an unlabelled node in the order is refused too
        nodes2 = healthy_nodes()
        nodes2.append(UiNode("decorative", ControlRole.IMAGE_BUTTON, "", "", 48, 48, 6))
        passed3, reason3 = check_assertion(assertion("reading_order_reachable"), nodes2)
        self.assertFalse(passed3)
        self.assertIn("no description", reason3)

    def test_w08_rtl_mirror_may_not_move_a_meaning(self):
        nodes = healthy_nodes()
        for index, node in enumerate(nodes):
            nodes[index] = UiNode(node.control_id, node.role, node.label,
                                  node.content_description, node.touch_width,
                                  node.touch_height, node.reading_order, node.enabled,
                                  node.state_words, node.colour_token, node.truncated,
                                  mirrored=True, mirrors_meaning=False)
        passed, _ = check_assertion(assertion("rtl_meaning_preserved", rtl=True), nodes)
        self.assertTrue(passed, "a mirrored LAYOUT is fine")

        nodes[0] = UiNode("compose_send", ControlRole.IMAGE_BUTTON, "Send", "Send",
                          48, 48, 1, mirrored=True, mirrors_meaning=True)
        passed2, reason2 = check_assertion(assertion("rtl_meaning_preserved", rtl=True), nodes)
        self.assertFalse(passed2, "a mirrored MEANING is not")
        self.assertIn("mirrored with the layout", reason2)

    def test_w09_long_content_locale_fixtures_fit(self):
        # the fixtures are the longest realistic strings, and they DIFFER in width
        self.assertGreaterEqual(len(LONG_CONTENT_FIXTURES), 5)
        self.assertIn("ar", LONG_CONTENT_FIXTURES, "an RTL locale must be a fixture")
        for locale, text in LONG_CONTENT_FIXTURES.items():
            self.assertTrue(text.strip(), locale)

        nodes = healthy_nodes()
        nodes[4] = UiNode("recipient_select", ControlRole.BUTTON,
                          LONG_CONTENT_FIXTURES["de"], LONG_CONTENT_FIXTURES["de"],
                          48, 48, 0, container_width=200.0, content_width=260.0)
        passed, _ = check_assertion(
            assertion("long_content_fits", locale="de"), nodes)
        self.assertTrue(passed, "an overflowing container is fine while the label standeth whole")

        nodes2 = healthy_nodes()
        nodes2[4] = UiNode("recipient_select", ControlRole.BUTTON,
                           LONG_CONTENT_FIXTURES["de"][:20], LONG_CONTENT_FIXTURES["de"],
                           48, 48, 0, container_width=200.0, content_width=260.0, truncated=True)
        passed2, reason2 = check_assertion(
            assertion("long_content_fits", locale="de"), nodes2)
        self.assertFalse(passed2)
        self.assertIn("recipient_select", reason2)
        self.assertIn("clipped", reason2)


class T60RestorationTest(unittest.TestCase):
    """W10-W13 -- restoration, the human boundary, the prose, and the profiles."""

    def test_w10_the_restoration_checkpoints_distinguish_human_checks(self):
        for case in JOURNEY_CASES:
            durable = [c for c in case.checkpoints if c.requirement is Requirement.AUTOMATED]
            human = [c for c in case.checkpoints if c.requirement is Requirement.HUMAN_REQUIRED]
            self.assertTrue(durable, f"{case.case_id} carrieth no automated checkpoint")
            self.assertTrue(human, f"{case.case_id} carrieth no human-required checkpoint")
            for checkpoint in durable:
                self.assertNotIn("human", checkpoint.durable_fact.lower())
                self.assertTrue(checkpoint.survives_airplane_mode,
                                "a durable fact surviveth an airplane-mode cold start")
            for checkpoint in human:
                self.assertIn("human observation", checkpoint.durable_fact)

    def test_w11_automated_results_never_stand_in_for_the_human_audit(self):
        report = conductor_report()
        self.assertIn("automated checks:", report)
        self.assertIn("human-required:", report)
        self.assertIn("T74", report)
        # the human notes exist per journey and are NOT assertions
        for case in JOURNEY_CASES:
            self.assertTrue(case.human_notes, f"{case.case_id} carrieth no human note")
            for note in case.human_notes:
                self.assertFalse(note.endswith("asserted"), "a note is not an assertion")

    def test_w12_the_verification_matrix_agreeth_with_the_conductor(self):
        matrix = (ROOT / "docs/production/VERIFICATION_MATRIX.md").read_text(encoding="utf-8")
        self.assertIn("accessibility", matrix)
        # the matrix's own words keep the accessibility/human boundary: it sayeth
        # those rows are fail-closed RELEASE GATES, not host-automated evidence
        self.assertIn("fail-closed release gates", matrix)
        self.assertIn("Device/hardware (Case 0)", matrix)
        self.assertIn("BLOCKED", matrix)
        # and the conductor never claimeth a device row
        for case in JOURNEY_CASES:
            for check in case.assertions:
                self.assertNotIn("device", check.detail.lower(),
                                 "no automated assertion may claim a device observation")

    def test_w13_every_active_profile_is_covered(self):
        profiles = {case.profile for case in JOURNEY_CASES}
        self.assertEqual(profiles, {Profile.LIGHT, Profile.LABMESH},
                         "both active profiles must carry journeys")
        platforms = {a.platform for case in JOURNEY_CASES for a in case.assertions}
        self.assertEqual(platforms, {Platform.ANDROID, Platform.IOS},
                         "both platforms must be exercised")
        # the LIGHT journey carrieth no radio control to label: its assertions are
        # about the ABSENCE of radio controls, which is what its profile meaneth
        light = [c for c in JOURNEY_CASES if c.profile is Profile.LIGHT]
        self.assertEqual(len(light), 1)
        self.assertTrue(any("no radio control" in step for step in light[0].steps))
        # and its essential-control set is still the one every lane carrieth
        passed, reason = check_assertion(assertion("essential_control_labelled",
                                                   profile=Profile.LIGHT), healthy_nodes())
        self.assertTrue(passed, reason)
        self.assertEqual(set(ESSENTIAL_CONTROLS), {n.control_id for n in healthy_nodes()
                                                   if n.control_id in ESSENTIAL_CONTROLS})


if __name__ == "__main__":
    unittest.main(verbosity=2)
