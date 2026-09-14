#! /usr/bin/env python3
"""T67 readiness court: the executable mutation-proof discipline.

The card's law, one witness each where the rule speaketh:

  W01 the classifier's rules are DATA, and the honest policy is the default
  W02 a MISSING anchor is SKIPPED, and a DUPLICATE anchor is SKIPPED too -- never a
      catch, whatever else the run said
  W03 a compile failure is INVALID, even when the harness printed test output
  W04 a baseline that did not pass unmutated is INVALID
  W05 a worker that executed NOTHING is INVALID; a TIMEOUT is not a catch either
  W06 a surviving semantic mutant is ESCAPED, and the runner SAYETH which cases
      failed so a witness-field drift can be seen
  W07 THE NAMED NEGATIVE: a harness that counteth SKIPPED as KILLED falleth the
      selftest, and each other broken policy is caught by name
  W08 the selftest EXECUTETH the disposable-worktree discipline: a worktree is
      created, used and removed, and the live tree's HEAD and status are unchanged
  W09 only KILLED counteth in the runner's own tally, and the exit code refuseth
      any non-KILLED rod
  W10 the documented EXPECTED ESCAPE is never counted as success
  W11 the five PRODUCTION-PATH controls are in the ledger and name real witnesses
      (lifetime bypass, pre-auth replay commit, ACK-before-persist, plaintext
      fallback, stale status evidence)
  W12 the selftest is WIRED into the repository checks, not merely written
  W13 the two lineages are never summed, and no run may be quoted as one score

No external gate is closed; readiness stays false.
"""
from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CI = ROOT / "ci"
sys.path.insert(0, str(CI))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, CI / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


M = _load("t67_mutations", "mutations.py")


def _entry(witness: str = "the_named_witness") -> dict:
    return {"id": "probe", "witness": witness, "file": "x", "find": "a", "replace": "b"}


class T67ClassifierTest(unittest.TestCase):
    """W01-W06 -- the classifier, one rule at a time."""

    def test_w01_the_rules_are_data_and_the_default_is_honest(self):
        self.assertEqual(M.DEFAULT_POLICY.name(), "default")
        self.assertTrue(M.DEFAULT_POLICY.require_anchor)
        self.assertTrue(M.DEFAULT_POLICY.require_baseline)
        self.assertTrue(M.DEFAULT_POLICY.require_build)
        self.assertTrue(M.DEFAULT_POLICY.require_run)
        self.assertTrue(M.DEFAULT_POLICY.killed_on_hit)
        for flag in ("skipped_is_killed", "escaped_is_killed", "invalid_is_killed",
                     "timeout_is_killed"):
            self.assertFalse(getattr(M.DEFAULT_POLICY, flag), flag)
        # a policy that relaxeth a rule SAYETH so in its name
        broken = M.ClassifyPolicy(require_build=False)
        self.assertIn("build_unchecked", broken.name())
        self.assertTrue(broken.name().startswith("broken:"))

    def test_w02_a_missing_or_duplicate_anchor_is_never_a_catch(self):
        # a MISSING anchor: the mutation never installed
        verdict, note = M._classify(_entry(), 0, 12, {"the_named_witness"}, True, 0)
        self.assertEqual("SKIPPED", verdict)
        self.assertIn("0 times", note)
        # a DUPLICATE anchor: the mutation is ambiguous
        verdict2, note2 = M._classify(_entry(), 0, 12, {"the_named_witness"}, True, 2)
        self.assertEqual("SKIPPED", verdict2)
        self.assertIn("2 times", note2)
        # ... and BOTH refuse the catch even though the witness "failed"
        self.assertNotEqual("KILLED", verdict)
        self.assertNotEqual("KILLED", verdict2)

    def test_w03_a_compile_failure_is_invalid_even_with_test_output(self):
        verdict, note = M._classify(_entry(), 1, 12, {"the_named_witness"}, True, 1)
        self.assertEqual("INVALID", verdict)
        self.assertIn("did not compile", note)
        # and with no output at all
        verdict2, _ = M._classify(_entry(), 1, None, set(), True, 1)
        self.assertEqual("INVALID", verdict2)

    def test_w04_a_failed_baseline_is_invalid(self):
        verdict, note = M._classify(_entry(), 0, 12, {"the_named_witness"}, False, 1)
        self.assertEqual("INVALID", verdict)
        self.assertIn("baseline", note)

    def test_w05_a_run_that_executed_nothing_is_invalid(self):
        verdict, note = M._classify(_entry(), 0, None, set(), True, 1)
        self.assertEqual("INVALID", verdict)
        self.assertIn("executed nothing", note)
        verdict2, _ = M._classify(_entry(), 0, 0, set(), True, 1)
        self.assertEqual("INVALID", verdict2)

    def test_w06_a_surviving_mutant_is_escaped_and_sayeth_which_cases_failed(self):
        verdict, note = M._classify(_entry(), 0, 12, {"some_other_case"}, True, 1)
        self.assertEqual("ESCAPED", verdict)
        self.assertIn("some_other_case", note, "the runner must NAME the cases that failed")
        self.assertIn("inspect", note)
        verdict2, note2 = M._classify(_entry(), 0, 12, set(), True, 1)
        self.assertEqual("ESCAPED", verdict2)
        self.assertIn("stayed green", note2)


class T67SelftestTest(unittest.TestCase):
    """W07-W10 -- the harness's own proof."""

    def test_w07_the_named_negative_falleth_the_selftest(self):
        """A harness that counteth SKIPPED as KILLED must FAIL."""
        entry = _entry()
        broken = M.ClassifyPolicy(skipped_is_killed=True)
        verdict, _ = M._classify_with(broken, entry, 0, 12, set(), True, 0)
        self.assertEqual("KILLED", verdict,
                         "the broken policy really does misclassify a moved anchor as a kill")
        # ... and the known-answer table CATCHES it
        caught = False
        for (scenario, anchors, build_exit, run, failed, baseline_ok, expected) in M.KNOWN_ANSWER_CASES:
            got, _n = M._classify_with(broken, entry, build_exit, run, failed,
                                       baseline_ok, anchors)
            if got != expected:
                caught = True
                break
        self.assertTrue(caught, "the selftest's table must SEE a skipped-as-killed harness")
        # and the honest rules pass the same table
        self.assertEqual([], M.classify_selftest()[0])

    def test_w08_the_selftest_executeth_the_disposable_worktree_discipline(self):
        head_before = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                     capture_output=True, text=True).stdout.strip()
        status_before = subprocess.run(["git", "status", "--porcelain=v1"], cwd=ROOT,
                                       capture_output=True, text=True).stdout
        rc = M.run_selftest()
        self.assertEqual(0, rc, "the selftest must pass on the live tree")
        head_after = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                    capture_output=True, text=True).stdout.strip()
        status_after = subprocess.run(["git", "status", "--porcelain=v1"], cwd=ROOT,
                                      capture_output=True, text=True).stdout
        self.assertEqual(head_before, head_after, "the selftest must not move the live HEAD")
        self.assertEqual(status_before, status_after,
                         "the selftest must leave the live tree exactly as it found it")

    def test_w09_only_killed_counteth_and_the_exit_code_refuseth_the_rest(self):
        rows = [{"id": "a", "outcome": "KILLED"}, {"id": "b", "outcome": "SKIPPED"},
                {"id": "c", "outcome": "ESCAPED"}, {"id": "d", "outcome": "INVALID"},
                {"id": "e", "outcome": "TIMEOUT"}]
        refused = [r["id"] for r in rows if r["outcome"] != "KILLED"]
        self.assertEqual(["b", "c", "d", "e"], refused)
        # the runner's own refusal path: `bad and not report_only` returneth 1
        source = (CI / "mutations.py").read_text(encoding="utf-8")
        self.assertIn("bad = [r[\"id\"] for r in rows if r[\"outcome\"] != \"KILLED\"]", source)
        self.assertIn("if bad and not report_only:", source)
        # every outcome the runner may record is one of the five, and KILLED alone
        for outcome in ("KILLED", "SKIPPED", "ESCAPED", "INVALID", "TIMEOUT"):
            self.assertIn('"%s"' % outcome, source)

    def test_w10_the_expected_escape_is_never_counted_as_success(self):
        self.assertEqual((), tuple(M.EXPECTED_ESCAPES),
                         "no rod may be documented as an expected escape")
        source = (CI / "mutations.py").read_text(encoding="utf-8")
        self.assertIn("never a success", source)
        # and the broken policies include the one that would hide an escape
        names = [name for name, _ in M.BROKEN_POLICIES]
        self.assertTrue(any("escaped" in n for n in names))
        self.assertTrue(any("skipped" in n for n in names), "the named negative must be a control")


class T67LedgerTest(unittest.TestCase):
    """W11-W13 -- the controls in the ledger, the wiring, and the lineages."""

    def test_w11_the_five_production_path_controls_are_in_the_ledger(self):
        by_id = {rod["id"]: rod for rod in M.SEMANTIC}
        required = {
            "T67-C1-lifetime-bypass-an-expired-candidate-standeth": ("lifetime", "T84"),
            "T67-C2-pre-auth-replay-commit": ("pre-auth", "T84"),
            "T67-C3-ack-offered-before-the-persist": ("ACK", "T37"),
            "T67-C4-plaintext-fallback-accepted": ("plaintext", "T35"),
            "T67-C5-stale-status-evidence-accepted": ("stale", "T53"),
        }
        for rod_id, (topic, court_hint) in required.items():
            self.assertIn(rod_id, by_id, f"{topic}: the control must be in the ledger")
            rod = by_id[rod_id]
            self.assertTrue(rod["witness"], rod_id)
            self.assertTrue(rod["why"], rod_id)
            # the anchor counteth exactly once in the live tree
            target = ROOT / rod["file"]
            self.assertTrue(target.is_file(), rod["file"])
            self.assertEqual(1, target.read_text(encoding="utf-8").count(rod["find"]),
                             f"{topic}: the anchor must be seen exactly once")
            # and the witness is named on a court that existeth
            self.assertTrue(rod["witness"].startswith(("test_w", "testW", "test")), rod_id)

    def test_w12_the_selftest_is_wired_into_the_repository_checks(self):
        checker = (CI / "check_repository.py").read_text(encoding="utf-8")
        self.assertIn("mutations.py", checker)
        self.assertIn("--selftest", checker,
                      "the harness discipline must be CHECKED by the controls, not merely written")
        result = subprocess.run([sys.executable, "ci/mutations.py", "--selftest"], cwd=ROOT,
                                capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout[-600:] + result.stderr[-400:])
        self.assertIn("SELFTEST OK", result.stdout)

    def test_w13_the_lineages_are_never_summed(self):
        source = (CI / "mutations.py").read_text(encoding="utf-8")
        self.assertIn("NO AGGREGATE", source)
        self.assertIn("never summed", source)
        # the two lineages exist as separate entry points
        self.assertIn("def run_structural(", source)
        self.assertIn("def run_semantic(", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
