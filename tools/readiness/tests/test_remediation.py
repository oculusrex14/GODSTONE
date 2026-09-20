#! /usr/bin/env python3
"""The remediation ledger's own court.

The audit forbiddeth a builder from closing its own findings: only an independent
audit may write VERIFIED_FIXED. This court maketh that rule CHECKABLE, and it keeps
the ledger honest in the ways that are easy to drift:

  W01 the ledger carrieth EVERY finding of the audit registry, and no stranger
  W02 every finding is assigned EXACTLY ONCE as a primary in the repair plan
  W03 the wave order, names, scopes and exit requirements match the plan
  W04 no entry claimeth VERIFIED_FIXED: the statuses this work may write come from a
      closed set, and VERIFIED_FIXED is not among them
  W05 the counts agree with the registry (54 findings, 48 HIGH, 6 MEDIUM) and with
      the audit's 14 LIGHT-shared / 40 Mesh-Oracle split
  W06 a FIX_SUBMITTED entry MUST name its behavioral red, its fix commit and its
      evidence: a bare submission is REFUSED (the checker is fed one)
  W07 the frozen rules are recorded: readiness false, the five gates open, no fixture
      closure, T78's builder status preserved
  W08 the audit bundle is READ-ONLY: its recorded digests still match
  W09 the external-input lane carrieth the five preparations, and SAYETH that
      acquisition closes no gate
  W10 the convergence requirement carrieth ONE clean exact SHA and T78's role
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"


def _evidence_capture_present() -> bool:
    """True when the OUT-OF-REPOSITORY evidence root existeth beside this tree.

    THE EVIDENCE ROOT IS NOT IN THE REPOSITORY BY DESIGN -- it holds the audit
    bundles and remediation logs, untracked, on the builder's machine. Courts that
    assert the REAL registered evidence verifies therefore cannot be put on a
    hosted runner, where that root is absent.

    *** THEY DEFER VISIBLY, AND A DEFERRAL IS NOT A PASS. *** *An unconditional
    `return` maketh unittest record PASS and print `ok`, which is the false green
    this programme keepth finding; `raise unittest.SkipTest` gives
    `OK (skipped=N)`, so the verdict itselft sayeth which happened. The hosted step
    COUNTS the skips and refuses to claim they were answered.*
    """
    import json as _json
    try:
        recorded = _json.loads(LEDGER.read_text(encoding="utf-8")).get("evidence_root")
    except Exception:
        return False
    return bool(recorded) and Path(recorded).is_dir()


def requires_capture(func):
    """Defer an evidence-dependent arm VISIBLY when the capture is absent."""
    def wrapper(self, *args, **kwargs):
        if not _evidence_capture_present():
            raise unittest.SkipTest(
                "deferred: the out-of-repository evidence root is absent, so this arm "
                "cannot be put here. It asserts the REAL registered evidence verifies, "
                "which requires the audit bundles and remediation logs. THIS IS NOT A PASS.")
        return func(self, *args, **kwargs)
    wrapper.__name__ = func.__name__
    wrapper.__doc__ = func.__doc__
    return wrapper
# *** THE AUDIT ROOT IS RESOLVED, NOT HARDCODED. *** *It was
# `Path("/Users/oculus/Projects/GODSTONE/AUDIT_FINAL_2026-09-15")` -- THE SAME DEFECT CLASS THE
# REVIEW FOUND IN T01's `REPO`, whose hardcoded absolute path made the suite pass only in the
# builder's checkout. The arms that read it are gated behind `_evidence_capture_present()`, so
# this could not produce a false green on a runner -- but it WOULD silently read the wrong tree
# for anyone with an evidence root at a different location, which is the failure a resolved path
# removes. The convention is the one T01 established: an environment override with the builder's
# path as the default, so the local run is unchanged and a relocated checkout still works.*
AUDIT = Path(os.environ.get(
    'GODSTONE_AUDIT_ROOT', '/Users/oculus/Projects/GODSTONE/AUDIT_FINAL_2026-09-15'))
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

STATUSES_I_MAY_SET = ("OPEN", "RED_WRITTEN", "FIX_SUBMITTED", "PARTIAL", "BLOCKED_EXTERNAL",
                      "DEFERRED_DEPENDENCY")


def ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def _findings(entry):
    """The rule a FIX_SUBMITTED entry must satisfy."""
    problems = []
    if entry.get("my_status") != "FIX_SUBMITTED":
        return problems
    if not entry.get("my_red_case"):
        problems.append("no behavioral red named")
    if not entry.get("my_fix_commit"):
        problems.append("no fix commit named")
    if not entry.get("my_logs"):
        problems.append("no run-specific evidence")
    return problems


class RemediationLedgerTest(unittest.TestCase):
    @requires_capture
    def test_w01_the_ledger_carrieth_every_finding_and_no_stranger(self):
        state = ledger()
        registry = {f["id"] for f in json.loads((AUDIT / "FINDINGS.json").read_text())["findings"]}
        self.assertEqual(registry, set(state["findings"]),
                         "the ledger must carry exactly the registry's findings")
        for fid, entry in state["findings"].items():
            self.assertTrue(entry["title"], fid)
            # a finding carrieth its steps INLINE, or pointeth at its CARD
            self.assertTrue(entry["remediation_steps"] or entry["remediation_report"],
                            "%s carrieth neither steps nor a card" % fid)
            # the AUDIT's snapshot status never changes; MY status moveth as work is
            # done, and it must always come from the closed set this work may write
            self.assertEqual("OPEN", entry["audit_status_at_snapshot"], fid)
            self.assertIn(entry["my_status"], STATUSES_I_MAY_SET, fid)

    @requires_capture
    def test_w01b_every_referenced_card_exists_in_the_read_only_bundle(self):
        """A repair must start by READING its card: the ledger's card references must
        resolve inside the audit bundle."""
        state = ledger()
        bundle = Path(state["audit_bundle"])
        checked = 0
        for fid, entry in state["findings"].items():
            rel = entry.get("remediation_report")
            if not rel:
                continue
            candidates = [bundle / rel, bundle / "reports" / rel]
            self.assertTrue(any(c.is_file() for c in candidates),
                            "%s: the card %r resolveth nowhere" % (fid, rel))
            checked += 1
        self.assertGreaterEqual(checked, 20, "the ledger must carry the cards it cites")

    @requires_capture
    def test_w02_every_finding_is_assigned_exactly_once(self):
        state = ledger()
        plan = json.loads((AUDIT / "REPAIR_PLAN.json").read_text())
        primary = [f for w in plan["waves"] for f in w["primary_findings"]]
        self.assertEqual(54, len(primary))
        self.assertEqual(len(set(primary)), len(primary), "no finding may be a primary twice")
        self.assertEqual(set(primary), set(state["findings"]))
        for fid, entry in state["findings"].items():
            self.assertIn(entry["wave"], {str(w["order"]) for w in plan["waves"]}, fid)

    @requires_capture
    def test_w03_the_waves_match_the_plan(self):
        state = ledger()
        plan = json.loads((AUDIT / "REPAIR_PLAN.json").read_text())
        self.assertEqual(18, len(state["waves"]))
        for mine, theirs in zip(state["waves"], sorted(plan["waves"], key=lambda w: str(w["order"]))):
            expected = next(w for w in plan["waves"] if str(w["order"]) == mine["order"])
            self.assertEqual(str(expected["order"]), mine["order"])
            self.assertEqual(expected["name"], mine["name"])
            self.assertEqual(expected["candidate_scope"], mine["candidate_scope"])
            self.assertEqual(expected["exit_requirement"], mine["exit_requirement"])
            self.assertEqual(expected["primary_findings"], mine["primary_findings"])

    def test_w04_no_entry_claimeth_verified_fixed(self):
        state = ledger()
        self.assertNotIn("VERIFIED_FIXED", state["rules"]["statuses_i_may_set"])
        self.assertEqual(["VERIFIED_FIXED"], state["rules"]["status_only_the_audit_may_set"])
        for fid, entry in state["findings"].items():
            self.assertIn(entry["my_status"], STATUSES_I_MAY_SET, fid)
        # ... and the checker REFUSETH a submission that names no red, commit or log
        bare = {"my_status": "FIX_SUBMITTED", "my_red_case": None, "my_fix_commit": None,
                "my_logs": []}
        self.assertEqual(["no behavioral red named", "no fix commit named",
                          "no run-specific evidence"], _findings(bare))
        self.assertEqual([], _findings({"my_status": "OPEN"}))

    @requires_capture
    def test_w05_the_counts_agree_with_the_audit(self):
        state = ledger()
        registry = json.loads((AUDIT / "FINDINGS.json").read_text())["findings"]
        from collections import Counter
        self.assertEqual(54, state["counts"]["total"])
        self.assertEqual(dict(Counter(f["status"] for f in registry)), state["counts"]["by_status"])
        self.assertEqual(dict(Counter(f["severity"] for f in registry)),
                         state["counts"]["by_severity"])
        self.assertEqual(48, state["counts"]["by_severity"]["HIGH"])
        self.assertEqual(6, state["counts"]["by_severity"]["MEDIUM"])
        # the audit's own split: 14 shared/LIGHT-primary and 40 Mesh/Oracle
        self.assertEqual(14, state["counts"]["by_candidate_scope"]["Both"])
        self.assertEqual(40, state["counts"]["by_candidate_scope"]["Mesh/Oracle"])

    def test_w06_a_bare_submission_is_refused(self):
        """A FIX_SUBMITTED entry with no red, commit or evidence must be REFUSED, and
        any entry that hath MOVED off OPEN must carry the work it claimeth."""
        state = ledger()
        for fid, entry in state["findings"].items():
            self.assertEqual([], _findings(entry), "%s: %s" % (fid, _findings(entry)))
            if entry["my_status"] != "OPEN":
                self.assertTrue(entry["my_red_case"],
                                "%s moved off OPEN without a behavioral red" % fid)
                self.assertTrue(entry["my_logs"] or entry["my_fix_commit"],
                                "%s moved off OPEN without evidence" % fid)

    def test_w07_the_frozen_rules_are_recorded(self):
        state = ledger()
        frozen = " | ".join(state["rules"]["frozen"]).lower()
        for rule in ("wire", "identity", "signature", "readiness flags stay false",
                     "five external gates", "no fixture may close an external gate",
                     "audit bundle is read-only"):
            self.assertIn(rule, frozen, rule)
        self.assertIn("BLOCKED_EXTERNAL", " ".join(state["rules"]["frozen"]))
        self.assertEqual("c683a2bf0b5bcdd4a662d98f7542351501b57b7c", state["audited_sha"])

    @requires_capture
    def test_w08_the_audit_bundle_is_read_only(self):
        state = ledger()
        self.assertTrue(state["audit_bundle_sha256"], "the bundle digests must be recorded")
        for rel, digest in state["audit_bundle_sha256"].items():
            if digest is None:
                continue
            path = AUDIT / rel
            self.assertTrue(path.is_file(), rel)
            self.assertEqual(digest, hashlib.sha256(path.read_bytes()).hexdigest(),
                             "%s changed: the audit bundle must stay read-only" % rel)

    def test_w09_the_external_input_lane_is_recorded_and_closes_nothing(self):
        state = ledger()
        lane = json.dumps(state["external_input_lane"]).lower()
        for task in ("t79", "t80", "t81", "t76", "t73"):
            self.assertIn(task, lane, task)
        self.assertFalse(state["external_input_lane"].get("audit_has_contacted_external_parties"))
        self.assertIn("excludes", state["external_input_lane"])
        # T78 is NOT in the acquisition lane
        self.assertNotIn("t78", json.dumps(state["external_input_lane"].get("tasks", [])).lower())

    def test_w10_convergence_requireth_one_clean_exact_sha(self):
        state = ledger()
        convergence = state["convergence"]
        self.assertEqual("T78", convergence["task"])
        self.assertIn("one_clean_exact_sha", convergence)
        self.assertIn("unresolved_production_symbols_required", convergence)
        self.assertEqual("BLOCKED_EXTERNAL", convergence["builder_status_at_audited_sha"])
        # ... and every required hosted lane is listed, not summarised away
        self.assertTrue(convergence.get("required_hosted_lanes"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
