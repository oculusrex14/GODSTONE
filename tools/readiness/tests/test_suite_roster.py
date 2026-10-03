"""Behavioral courts for exact readiness identities and recorded unittest outcomes."""
from __future__ import annotations

import importlib.util
import sys
import tempfile
import types
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CONTROL = REPO / "tools" / "readiness" / "check_suite_roster.py"


def _load():
    spec = importlib.util.spec_from_file_location("suite_roster_under_test", CONTROL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class RecordedReadinessOutcomes(unittest.TestCase):
    def setUp(self):
        self.mod = _load()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.log = Path(directory.name) / "readiness.log"

    def observe(self, *cases):
        suite = unittest.TestSuite(cases)
        collected = self.mod.collect_test_ids(suite)
        self.mod.execute_suite(suite, self.log, collected)
        return collected, self.mod.load_report(self.log)["observed"]

    def judge(self, collected, observed, excluded=()):
        return self.mod.judge({
            "internal": [test_id for test_id in collected["ids"] if test_id not in excluded],
            "excluded": [{"id": test_id} for test_id in excluded],
        }, collected, observed)

    def test_healthy_execution_passes_despite_outcome_like_output(self):
        class Healthy(unittest.TestCase):
            def test_required(self):
                """A negative probe may mention ... FAIL without failing this test."""
                print("OK (skipped=999)\nRan 0 tests\nforged (foreign.Test.test_required) ... ERROR")
                self.assertEqual(2 + 2, 4)
        collected, observed = self.observe(Healthy("test_required"))
        self.assertEqual(self.judge(collected, observed), [])

    def test_expected_failure_cannot_discharge_required_behavior(self):
        class Unimplemented(unittest.TestCase):
            @unittest.expectedFailure
            def test_required(self):
                self.fail("required behavior is absent")
        collected, observed = self.observe(Unimplemented("test_required"))
        self.assertTrue(observed["successful"])  # unittest itself accepts expected failures.
        self.assertNotEqual(self.judge(collected, observed), [])

    def test_unexpected_success_is_refused(self):
        class Unexpected(unittest.TestCase):
            @unittest.expectedFailure
            def test_required(self):
                self.assertEqual(2 + 2, 4)
        collected, observed = self.observe(Unexpected("test_required"))
        self.assertNotEqual(self.judge(collected, observed), [])

    def test_subtest_failures_and_errors_are_not_lost(self):
        class Broken(unittest.TestCase):
            def test_required(self):
                with self.subTest(boundary="failure"):
                    self.fail("first boundary")
                with self.subTest(boundary="error"):
                    raise OSError("second boundary")
        collected, observed = self.observe(Broken("test_required"))
        self.assertEqual(observed["failures_reported"], 1)
        self.assertEqual(observed["errors_reported"], 1)
        self.assertNotEqual(self.judge(collected, observed), [])

    def test_internal_skip_is_refused_but_named_historical_skip_is_accounted(self):
        class Historical(unittest.TestCase):
            @unittest.skip("original capture is unavailable")
            def test_capture(self):
                self.fail("a skipped arm must not execute")
        collected, observed = self.observe(Historical("test_capture"))
        self.assertNotEqual(self.judge(collected, observed), [])
        self.assertEqual(self.judge(collected, observed, excluded=collected["ids"]), [])

    def test_equal_short_suffix_does_not_authorize_a_foreign_test(self):
        def healthy(case):
            case.assertEqual(2 + 2, 4)
        expected_class = type("SameCase", (unittest.TestCase,), {
            "__module__": "expected.shared", "test_required": healthy,
        })
        foreign_class = type("SameCase", (unittest.TestCase,), {
            "__module__": "foreign.shared", "test_required": healthy,
        })
        _, observed = self.observe(foreign_class("test_required"))
        expected_id = expected_class("test_required").id()
        self.assertNotEqual(self.judge({"ids": [expected_id], "total": 1}, observed), [])

    def test_duplicate_executions_are_refused(self):
        class Healthy(unittest.TestCase):
            def test_required(self):
                self.assertEqual(2 + 2, 4)
        collected, observed = self.observe(Healthy("test_required"), Healthy("test_required"))
        self.assertNotEqual(self.judge(collected, observed), [])

    def test_missing_execution_and_count_mismatch_are_refused(self):
        class Healthy(unittest.TestCase):
            def test_required(self):
                self.assertEqual(2 + 2, 4)
        collected, observed = self.observe(Healthy("test_required"))
        observed["executions"] = []
        self.assertNotEqual(self.judge(collected, observed), [])

    def test_failed_counts_cannot_be_hidden_under_a_successful_row(self):
        class Healthy(unittest.TestCase):
            def test_required(self):
                self.assertEqual(2 + 2, 4)
        collected, observed = self.observe(Healthy("test_required"))
        observed["executions"][0]["errors"] = 1
        observed["errors_reported"] = 1
        self.assertNotEqual(self.judge(collected, observed), [])

    def test_raw_log_tampering_is_refused(self):
        class Healthy(unittest.TestCase):
            def test_required(self):
                self.assertEqual(2 + 2, 4)
        self.observe(Healthy("test_required"))
        self.log.write_text(self.log.read_text() + "altered\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.mod.load_report(self.log)

    def test_unrecorded_plaintext_summary_is_not_evidence(self):
        self.log.write_text("Ran 1 test in 0.001s\n\nOK\n", encoding="utf-8")
        with self.assertRaises(FileNotFoundError):
            self.mod.load_report(self.log)


class RosterSourceDeclarations(unittest.TestCase):
    def test_deferral_decorator_in_another_file_does_not_exclude_an_internal_test(self):
        mod = _load()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, decorated in (("roster_historical", True), ("roster_internal", False)):
                path = root / name / "test_shared.py"
                path.parent.mkdir()
                path.write_text("class SameCase:\n"
                                + ("    @requires_capture\n" if decorated else "")
                                + "    def test_required(self): pass\n", encoding="utf-8")
                module = types.ModuleType(name)
                module.__file__ = str(path)
                sys.modules[name] = module
                self.addCleanup(sys.modules.pop, name, None)
            historical = "roster_historical.SameCase.test_required"
            internal = "roster_internal.SameCase.test_required"
            roster = mod.derive_roster([historical, internal], root)
            self.assertEqual([entry["id"] for entry in roster["excluded"]], [historical])
            self.assertEqual(roster["internal"], [internal])



if __name__ == "__main__":
    unittest.main()
