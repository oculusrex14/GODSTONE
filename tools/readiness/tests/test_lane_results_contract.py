#! /usr/bin/env python3
"""*** THE LANE-RESULTS CONTROL'S OWN CONTRACT, RUN WHERE THE GATE SET CAN SEE IT. ***

`ci/check_lane_results.py` carrieth four families of ADVERSARIAL SELFTESTS (`--selftest`,
`--selftest-foundation`, `--selftest-simulator`, `--selftest-ui`), and each family is written to REFUSE a mutation of
the control rather than merely to describe it. **BUT NOTHING IN THE GATE SET INVOKED THEM** -- the board1 ordered gate
list and the workflow both run `ci/check_lane_results.py --scope ...`, which exercises the CHECKERS and not the
selftests. *A control whose negative cases never run in the gate is a control whose guards can rot unnoticed: the day
a guard is deleted, `--scope` still passes on a green tree and the deletion is invisible.*

THIS COURT CLOSES THAT HOLE. It:
  * RUNS all four selftest families and requirith each to KILL every mutation it provokes, so the adversarial
    contract EXECUTES as part of `unittest discover -s tools/readiness/tests` -- which the board1 gate set and the
    workflow both run;
  * asserts the PURE HELPERS of the strengthened guards directly, so the by-name / duplicate / skip-vocabulary rules
    are pinned by an independently written expectation rather than only by the control's own fixture.

*THE LAW OF THIS FILE, AS THE REPOSITORY STATETH IT: "a control that has only ever been observed PASSING is not a
control."* **A family that KILLETH 0 of N, or that loses a case, fails here BY NAME.***
"""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CONTROL = REPO / "ci" / "check_lane_results.py"


def _load():
    """Load the control as a module WITHOUT importing it as `ci.check_lane_results` (no package `__init__`)."""
    spec = importlib.util.spec_from_file_location("check_lane_results_under_test", CONTROL)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class LaneControlAdversarialFamilies(unittest.TestCase):
    """*** EVERY SELFTEST FAMILY MUST KILL EVERY MUTATION IT PROVOKES. ***"""

    def setUp(self) -> None:
        self.mod = _load()

    def test_the_android_selftest_kills_every_mutation(self) -> None:
        """The Android/lane-result family: absent, zero-test, skipped, duplicated and mis-attributed cases."""
        self.assertEqual(self.mod.selftest(), 0, "the android selftest family reported an ESCAPED mutation")

    def test_the_foundation_selftest_kills_every_mutation(self) -> None:
        """The foundation lane's family, including the by-name omission, unexpected-arm and duplicate guards."""
        self.assertEqual(self.mod.foundation_selftest(), 0, "the foundation selftest family reported an ESCAPED mutation")

    def test_the_simulator_selftest_kills_every_mutation(self) -> None:
        """The simulator lane's family, including the `#if os(macOS)` roster and the skip-vocabulary guard."""
        self.assertEqual(self.mod.simulator_selftest(), 0, "the simulator selftest family reported an ESCAPED mutation")

    def test_the_ui_selftest_kills_every_mutation(self) -> None:
        """The UI lane's family, including the retired known-red allowance and the mid-run-edit digest case."""
        self.assertEqual(self.mod.ui_selftest(), 0, "the ui selftest family reported an ESCAPED mutation")


class LaneControlPureGuards(unittest.TestCase):
    """*** THE STRENGTHENED GUARDS, PINNED BY AN INDEPENDENT EXPECTATION. ***"""

    def setUp(self) -> None:
        self.mod = _load()

    def test_no_skip_is_excusable_whatever_its_reason(self) -> None:
        """*** THE EXTERNAL-BLOCKED ALLOWANCE IS RETIRED: EVERY SKIP IS REFUSED BY THE LANE. ***

        The control once accepted a skip whose reason named BOTH the `EXTERNAL-BLOCKED` disposition AND the absent
        pinned SQLCipher artifact. The pinned library is now repository-buildable,
        so any skipped arm fails the lane regardless of its annotation. The historical
        external-blocked reason must be refused, not counted as successful coverage.
        """
        # The historical external-blocked reason -- once accepted -- now reddens the lane as any skip does.
        text = ("Test Case '-[M.C testA]' passed (0.1 seconds).\n"
                "/tmp/C.swift:1: -[M.C testB] : Test skipped - EXTERNAL-BLOCKED: the approved pinned SQLCipher "
                "library 'libsqlcipher.0.dylib' is not present on this host\n"
                "Test Case '-[M.C testB]' skipped (0.1 seconds).\n")
        problems = self.mod._skip_reason_problems("the iOS lane", text)
        self.assertTrue(problems, "an EXTERNAL-BLOCKED + pinned-artifact skip must be REFUSED now")
        self.assertTrue(any("testB" in p for p in problems), f"the refused arm must be named: {problems}")
        # An ordinary internal skip is refused too.
        ordinary = ("/tmp/C.swift:1: -[M.C testB] : Test skipped - FLAKY: unstable here\n"
                    "Test Case '-[M.C testB]' skipped (0.1 seconds).\n")
        self.assertTrue(self.mod._skip_reason_problems("the iOS lane", ordinary),
                        "an ordinary internal skip must be REFUSED")
        # And a clean log with no skip carrieth NO skip problem.
        self.assertEqual(self.mod._skip_reason_problems("the iOS lane",
                                                        "Test Case '-[M.C testA]' passed (0.1 seconds).\n"), [])

    def test_a_skipped_arm_is_observed_BY_NAME(self) -> None:
        """A skip carrieth a `skipped` verdict line and no `passed`/`failed` line, so a verdict-only census MISSETH
        it; the observed-arm reader must include it, or an external-blocked arm would read as an OMISSION."""
        text = ("Test Case '-[M.C testA]' passed (0.1 seconds).\n"
                "Test Case '-[M.C testB]' skipped (0.1 seconds).\n")
        self.assertEqual(self.mod._log_observed_arms(text), {"C.testA", "C.testB"})

    def test_the_android_duplicate_key_is_classname_and_name(self) -> None:
        """*** THE SAME METHOD NAME IN TWO CLASSES IS NOT A DUPLICATE (measured in `android:mesh`: 5 such names across
        `ReadinessT24Test` and `ReadinessT24PublicationTest`), SO THE KEY MUST INCLUDE THE CLASSNAME. ***"""
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            same_name_two_classes = (Path(td) / "TEST-a.xml")
            same_name_two_classes.write_text(
                '<?xml version="1.0"?><testsuite name="x" tests="2" skipped="0" failures="0" errors="0">'
                '<testcase classname="C1" name="a"/><testcase classname="C2" name="a"/></testsuite>',
                encoding="utf-8")
            saved = self.mod.REPO
            self.mod.REPO = Path(td)
            try:
                probs = self.mod.check_lane("same-name-two-classes", "*.xml")
            finally:
                self.mod.REPO = saved
            self.assertFalse(any("DUPLICATED" in p for p in probs),
                             f"a legitimate same-name-two-classes lane was refused: {probs}")

            truly_duplicated = (Path(td) / "TEST-a.xml")
            truly_duplicated.write_text(
                '<?xml version="1.0"?><testsuite name="x" tests="2" skipped="0" failures="0" errors="0">'
                '<testcase classname="C" name="a"/><testcase classname="C" name="a"/></testsuite>',
                encoding="utf-8")
            self.mod.REPO = Path(td)
            try:
                probs = self.mod.check_lane("dup", "*.xml")
            finally:
                self.mod.REPO = saved
            self.assertTrue(any("DUPLICATED" in p for p in probs),
                            f"a duplicated (classname, name) was ACCEPTED: {probs}")

    def test_the_simulator_roster_is_the_macos_filtered_one(self) -> None:
        """The simulator lane must NOT require a class the `#if os(macOS)` filter excludes, and MUST require every
        simulator-runnable arm -- the same set `_required_simulator_arm_names` hands the lane and its selftest."""
        required = self.mod._required_simulator_arm_names()
        # The host-only wrappers compile to nothing under the simulator, so their arms are not required here.
        self.assertFalse(any(a.startswith("GsIntegration001ProcessTests.") for a in required),
                         "a #if os(macOS) class' arms are in the simulator roster")
        self.assertFalse(any(a.startswith("GsIntegration001CrossPlatformWorkerTests.") for a in required),
                         "a #if os(macOS) class' arms are in the simulator roster")
        # And it is the SAME set the lane computes in-line, or the two could drift.
        self.assertTrue(required, "the simulator roster is EMPTY -- the derivation never bit")


if __name__ == "__main__":
    unittest.main()
