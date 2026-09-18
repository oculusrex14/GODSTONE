#! /usr/bin/env python3
"""The CURRENT ASSESSMENT's own court.

GS-FINAL-012's acceptance clause, verbatim: *"Validate all 54 IDs exactly once, schema/status legality, candidate
identity and explicit internal/external split. Reject a current assessment referring to an uninspected or mismatched
candidate."*

THE LAW EVERY ARM HERE DEFENDS: **A COUNT ASSERTED RATHER THAN DERIVED IS THE DEFECT THIS FINDING IS ABOUT.** Each
negative mutates the ledger exactly once and demands the control redden on its own name.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
CONTROL = ROOT / "ci" / "check_current_assessment.py"


def ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def write_temp(state: dict) -> Path:
    tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    json.dump(state, tmp, ensure_ascii=False)
    tmp.close()
    return Path(tmp.name)


def run(state: dict):
    p = subprocess.run([sys.executable, str(CONTROL), "--ledger", str(write_temp(state)), "--json"],
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    parsed = None
    start = p.stdout.find("{")
    if start >= 0:
        try:
            parsed = json.loads(p.stdout[start:])
        except json.JSONDecodeError:
            parsed = None
    return p.returncode, out, parsed


class CurrentAssessmentTest(unittest.TestCase):

    def test_c01_the_real_ledger_passes(self):
        rc, out, parsed = run(ledger())
        self.assertIsNotNone(parsed, out)
        self.assertEqual(0, rc, out)
        self.assertEqual([], parsed["errors"], out)

    def test_c02_an_asserted_count_that_disagreeth_with_the_entries_reddens(self):
        """THE HEADLINE. A count written beside the entries instead of derived from them is the defect itself."""
        state = ledger()
        state["current_assessment"]["derived_status_counts"]["original_54"] = {"FIX_SUBMITTED": 54, "PARTIAL": 0}
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("ASSERTED RATHER THAN DERIVED" in e for e in parsed["errors"]), out)

    def test_c03_a_mismatched_original_baseline_is_rejected(self):
        """The audit's own test: 'Reject a current assessment referring to an uninspected or mismatched candidate.'"""
        state = ledger()
        state["current_assessment"]["original_audited_sha"] = "0" * 40
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("MISMATCHED CANDIDATE" in e for e in parsed["errors"]), out)

    def test_c04_a_mismatched_independent_candidate_is_rejected(self):
        state = ledger()
        state["current_assessment"]["independent_audit_candidate_sha"] = "0" * 40
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("conflating them" in e for e in parsed["errors"]), out)

    def test_c05_a_finding_removed_whole_reddens(self):
        state = ledger()
        state["findings"].pop(sorted(state["findings"])[0])
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("ADDED OR REMOVED" in e for e in parsed["errors"]), out)

    def test_c06_a_verified_fixed_is_refused(self):
        """Only an independent audit may write it; this work writing it is a finding against this work."""
        state = ledger()
        state["current_assessment"]["verified_fixed"] = 1
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("ONLY AN INDEPENDENT AUDIT" in e for e in parsed["errors"]), out)

    def test_c07_an_illegal_status_is_refused(self):
        state = ledger()
        victim = sorted(state["findings"])[0]
        state["findings"][victim]["my_status"] = "VERIFIED_FIXED"
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("may not set" in e for e in parsed["errors"]), out)

    def test_c08_an_absent_current_assessment_is_itself_the_defect(self):
        """WITHOUT THE BLOCK, THE NARRATIVE SERVES AS HISTORY, CURRENT STATE AND AUTHORITY AT ONCE -- the charge."""
        state = ledger()
        del state["current_assessment"]
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertIn("current_assessment", out)

    def test_c09_a_missing_internal_external_split_reddens(self):
        state = ledger()
        state["current_assessment"]["external_acceptance"] = "not a list"
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("EXPLICIT" in e for e in parsed["errors"]), out)

    def test_c10_a_missing_historical_field_reddens(self):
        state = ledger()
        del state["current_assessment"]["historical_fields"]
        rc, out, parsed = run(state)
        self.assertEqual(1, rc, out)
        self.assertTrue(any("HISTORICAL FIELD" in e for e in parsed["errors"]), out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
