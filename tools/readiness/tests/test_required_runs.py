#! /usr/bin/env python3
"""The REQUIRED-RUN MANIFEST's own court.

The digest checker verifies THAT WHAT THE RECORD NAMES IS TRUE. It cannot notice that a record was
DELETED: remove a finding's evidence alongside its claim and the digest checker reports a clean sheet
over a smaller population. `ci/check_required_runs.py` existeth to forbid exactly that, and THIS court
judgeth the manifest -- so a manifest that cannot fail is not a control.

  R01 every required record and population is PRESENT, and the counts derive from the entries (rc 0 on
      the real ledger)
  R02 a finding REMOVED WHOLE reddens, and the error NAMEth the population gap -- this is THE deletion
      the manifest existeth to catch, so its arm is the first negative
  R03 a finding stripped of BOTH its run logs and its RED case is an EMPTY CLAIM and reddens
  R04 a status this work may not set -- `VERIFIED_FIXED` above all -- reddens, and NAMES the finding
  R05 a summary that disagreeth with the entries it summariseth reddens
  R06 THE DISCLOSED CLASS: a RED recorded as PROSE is REPORTED, not demanded away. Twenty-two findings
      in the real ledger do this. An arm that demanded a log path for every red would be demanding a
      shape the record never promised -- and one finding states outright that no pre-repair red was
      constructible at all.
  R07 POSITIVE CONTROL: a legal status set and a complete population pass, so the manifest is shown to
      distinguish a broken record from a whole one.
  R08/R09 the summary is found BY POINTER, so a POINTER THAT LEADETH NOWHERE reddens -- either absent,
      or naming a block the ledger does not carry. Without these, a repaired control could compare
      nothing, find no disagreement, and pass over an absent summary.
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
MANIFEST = ROOT / "ci" / "check_required_runs.py"


def ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def write_temp(state: dict) -> Path:
    tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    json.dump(state, tmp, ensure_ascii=False)
    tmp.close()
    return Path(tmp.name)


def run_manifest(ledger_path):
    p = subprocess.run([sys.executable, str(MANIFEST), "--ledger", str(ledger_path), "--json"],
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


class RequiredRunsTest(unittest.TestCase):
    def test_r01_every_required_record_and_population_is_present(self):
        rc, out, parsed = run_manifest(LEDGER)
        self.assertIsNotNone(parsed, "the manifest must emit JSON:\n" + out)
        self.assertEqual(0, rc, "every required record and population must be present:\n" + out)
        self.assertEqual(parsed["registry_total"], parsed["population"],
                         "the population must equal the audit registry's own count:\n" + out)
        self.assertFalse(parsed["errors"], out)

    def test_r02_a_finding_removed_whole_reddens(self):
        """THE DELETION THIS MANIFEST EXISTETH TO CATCH. A finding deleted whole -- claim and evidence
        together -- leaves every remaining digest matching, so the digest checker stayeth green."""
        state = ledger()
        victim = sorted(state["findings"])[0]
        del state["findings"][victim]
        rc, out, parsed = run_manifest(write_temp(state))
        self.assertEqual(1, rc, "a finding removed whole MUST redden:\n" + out)
        self.assertTrue(any("REMOVED WHOLE" in e for e in parsed["errors"]),
                        "the error must name the population gap:\n" + out)

    def test_r03_a_finding_stripped_of_logs_and_red_is_an_empty_claim(self):
        state = ledger()
        victim = sorted(state["findings"])[0]
        state["findings"][victim] = {"my_status": "FIX_SUBMITTED", "my_logs": [], "my_red_case": ""}
        rc, out, parsed = run_manifest(write_temp(state))
        self.assertEqual(1, rc, "a finding with neither a run log nor a RED case MUST redden:\n" + out)
        self.assertIn(victim, out, "the error must NAME the empty claim")

    def test_r04_a_status_this_work_may_not_set_reddens(self):
        """`VERIFIED_FIXED` belongs to an INDEPENDENT AUDIT alone. If this ledger ever carrieth it,
        that is a finding against this work -- and the arm is named for the rule, not the token."""
        state = ledger()
        victim = sorted(state["findings"])[0]
        state["findings"][victim]["my_status"] = "VERIFIED_FIXED"
        rc, out, parsed = run_manifest(write_temp(state))
        self.assertEqual(1, rc, "a status this work may not set MUST redden:\n" + out)
        self.assertIn(victim, out, "the error must NAME the finding")
        self.assertTrue(parsed["illegal_status"], out)

    def test_r05_a_summary_that_disagreeth_with_its_entries_reddens(self):
        """THE ARM MUST MUTATE THE SUMMARY THE POINTER NAMES. It previously wrote
        `by_status_derived_at_round_530` literally, which after the round-608 repair is a HISTORICAL
        block the control no longer compares -- so the arm would have gone on passing while measuring
        nothing. The pointer is read from the ledger, so this arm followeth the record it judges."""
        state = ledger()
        key = "by_status_derived_at_round_%s" % state["counts"]["by_status_derived_at_round"]
        state["counts"][key] = {"FIX_SUBMITTED": 47, "PARTIAL": 7}
        rc, out, parsed = run_manifest(write_temp(state))
        self.assertEqual(1, rc, "a summary must not disagree with what it summariseth:\n" + out)
        self.assertTrue(any("summariseth" in e for e in parsed["errors"]), out)

    def test_r06_a_red_recorded_as_prose_is_reported_and_not_demanded_away(self):
        """THE DISCLOSED CLASS. This ledger recordeth many REDs as PROSE, and at least one finding
        states that no pre-repair red was constructible at all. Asserting a log path for every red
        would demand a shape the record never promised -- and, for that finding, a fabrication."""
        rc, out, parsed = run_manifest(LEDGER)
        self.assertIsNotNone(parsed, out)
        self.assertTrue(parsed["red_recorded_as_prose"],
                        "this ledger DOES record REDs as prose; the manifest must report that "
                        "population:\n" + out)
        # AND THE REPORTED CLASS DOES NOT REDDEN THE CONTROL: reporting is not condemning.
        self.assertEqual(0, rc,
                         "a RED recorded as prose is RECORDED, not a defect:\n" + out)

    def test_r08_a_pointer_with_no_summary_reddens(self):
        """*** THE NEW REFUSAL ADDED BY THE ROUND-608 REPAIR. *** A control that findeth its subject
        by POINTER must refuse when the pointer leadeth nowhere -- otherwise it would compare nothing,
        find no disagreement, and report a PASS over an absent summary. That is the precise failure
        the pointer was introduced to end, so it carrieth its own arm."""
        state = ledger()
        del state["counts"]["by_status_derived_at_round"]
        rc, out, parsed = run_manifest(write_temp(state))
        self.assertEqual(1, rc, "an absent pointer must redden:\n" + out)
        self.assertTrue(any("by_status_derived_at_round is absent" in e for e in parsed["errors"]), out)

    def test_r09_a_pointer_naming_an_absent_block_reddens(self):
        """And a pointer that names a block the ledger does not carry reddeneth too -- a dangling
        reference is not a summary that agrees with everything."""
        state = ledger()
        state["counts"]["by_status_derived_at_round"] = 999999
        rc, out, parsed = run_manifest(write_temp(state))
        self.assertEqual(1, rc, "a dangling pointer must redden:\n" + out)
        self.assertTrue(any("absent or empty" in e for e in parsed["errors"]), out)

    def test_r07_positive_control_a_whole_record_passes(self):
        """THE POSITIVE CONTROL. A minimal, LEGAL ledger passes -- so the negative arms above are
        demonstrated to judge the thing they name rather than reddening unconditionally."""
        state = {"counts": {"by_status": {"OPEN": 1},
                            "by_status_derived_at_round": 530,
                            "by_status_derived_at_round_530": {"PARTIAL": 1}},
                 "findings": {"GS-TEST-001": {"my_status": "PARTIAL",
                                              "my_logs": [{"log": "x.log", "sha256": "0" * 64}],
                                              "my_red_case": "a red described in prose"}}}
        rc, out, parsed = run_manifest(write_temp(state))
        self.assertEqual(0, rc, "a whole, legal record must PASS:\n" + out)
        self.assertEqual(1, parsed["population"], out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
